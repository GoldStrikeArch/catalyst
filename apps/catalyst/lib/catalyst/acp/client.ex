defmodule Catalyst.ACP.Client do
  @moduledoc """
  Persistent ACP v1 stdio client owned by one Catalyst session.

  The GenServer owns the agent port, performs the initialize/session lifecycle
  handshake, correlates the active prompt, retains negotiated session metadata,
  forwards updates to its workflow process, auto-approves permission requests,
  and cancels when that caller dies.
  """

  use GenServer

  alias Catalyst.ACP.{Agent, Protocol}
  alias Catalyst.Session.Manager

  @registry Catalyst.ACP.Registry
  @max_line_bytes 2 * 1024 * 1024
  @handshake_timeout 10_000
  @close_timeout 500
  @default_cancel_timeout 2_000

  @type prompt_ref :: reference()

  @doc "Start a session-owned ACP client."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent = Keyword.fetch!(opts, :agent)
    name = {:via, Registry, {@registry, {session_id, agent.id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Begin one prompt and return the reference used for streamed messages."
  @spec prompt(pid(), String.t()) :: {:ok, prompt_ref()} | {:error, term()}
  def prompt(client, text), do: GenServer.call(client, {:prompt, text})

  @doc "Cancel the active prompt when its reference still matches."
  @spec cancel(pid(), prompt_ref()) :: :ok
  def cancel(client, ref), do: GenServer.cast(client, {:cancel, ref})

  @doc "Return negotiated capabilities and current ACP session metadata."
  @spec info(pid()) :: map()
  def info(client), do: GenServer.call(client, :info)

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id), Keyword.fetch!(opts, :agent).id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)
    agent = Keyword.fetch!(opts, :agent)
    cwd = Keyword.fetch!(opts, :cwd)
    resume_id = Keyword.get(opts, :resume_id)
    session_meta = Keyword.get(opts, :session_meta, %{})
    cancel_timeout = Keyword.get(opts, :cancel_timeout, @default_cancel_timeout)

    with {:ok, owner} <- Manager.whereis(session_id),
         {:ok, executable} <- Agent.executable(agent),
         {:ok, port} <- open_port(executable, agent, cwd) do
      finish_init(port, owner, agent, cwd, resume_id, session_meta, cancel_timeout)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, client_info(state), state}

  def handle_call({:prompt, _text}, _from, %{active: active} = state) when not is_nil(active),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:prompt, text}, {caller, _tag}, state) when is_binary(text) do
    id = state.next_id
    ref = make_ref()

    params = %{
      "sessionId" => state.acp_session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    }

    case send_port(state.port, Protocol.request(id, "session/prompt", params)) do
      :ok ->
        active = %{
          id: id,
          ref: ref,
          caller: caller,
          monitor: Process.monitor(caller),
          cancel_timer: nil
        }

        {:reply, {:ok, ref}, %{state | active: active, next_id: id + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prompt, text}, _from, state),
    do: {:reply, {:error, {:invalid_prompt, text}}, state}

  @impl true
  def handle_cast({:cancel, ref}, %{active: %{ref: ref}} = state) do
    case request_cancel(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> stop_protocol(reason, state)
    end
  end

  def handle_cast({:cancel, _stale_ref}, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Protocol.decode(line) do
      {:ok, message} -> handle_protocol(message, state)
      {:error, reason} -> stop_protocol(reason, state)
    end
  end

  def handle_info({port, {:data, {:noeol, _partial}}}, %{port: port} = state),
    do: stop_protocol(:line_too_large, state)

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    notify_active(state.active, {:error, {:process_exit, status}})
    {:stop, {:process_exit, status}, %{state | active: nil}}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{owner_monitor: monitor} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{active: %{monitor: monitor} = active} = state
      ) do
    state = %{state | active: %{active | caller: nil, monitor: nil}}

    case request_cancel(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> stop_protocol(reason, state)
    end
  end

  def handle_info(
        {:cancel_timeout, ref},
        %{active: %{ref: ref}} = state
      ) do
    notify_active(state.active, {:error, :cancellation_timeout})
    {:stop, :normal, %{state | active: nil}}
  end

  def handle_info({:cancel_timeout, _stale_ref}, state), do: {:noreply, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    notify_active(state.active, {:error, {:port_exit, reason}})
    {:stop, {:port_exit, reason}, %{state | active: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_session(state)
    close_port(Map.get(state, :port))
    :ok
  end

  defp handle_protocol({:notification, "session/update", params}, state) do
    state = retain_session_update(params, state)

    case {params["sessionId"], params["update"], state.active} do
      {session_id, update, active}
      when session_id == state.acp_session_id and is_map(update) and not is_nil(active) ->
        notify_active(active, {:update, update})

      _ignored ->
        :ok
    end

    {:noreply, state}
  end

  defp handle_protocol({:request, id, "session/request_permission", params}, state) do
    response = permission_response(params, state)
    :ok = send_port(state.port, Protocol.result(id, response))
    {:noreply, state}
  end

  defp handle_protocol({:request, id, method, _params}, state) do
    :ok = send_port(state.port, Protocol.method_not_found(id, method))
    {:noreply, state}
  end

  defp handle_protocol({:result, id, result}, %{active: %{id: id} = active} = state) do
    result =
      case result do
        result when is_map(result) -> Map.put_new(result, "sessionId", state.acp_session_id)
        other -> other
      end

    notify_active(active, {:result, result})
    {:noreply, clear_active(state)}
  end

  defp handle_protocol({:error, id, error}, %{active: %{id: id} = active} = state) do
    notify_active(active, {:error, {:jsonrpc_error, error}})
    {:noreply, clear_active(state)}
  end

  defp handle_protocol(_unmatched, state), do: {:noreply, state}

  defp permission_response(
         %{"sessionId" => session_id, "options" => options},
         %{active: active} = state
       )
       when session_id == state.acp_session_id and is_list(options) and not is_nil(active) do
    case choose_permission(options) do
      {:ok, option_id} ->
        %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}

      :error ->
        %{"outcome" => %{"outcome" => "cancelled"}}
    end
  end

  defp permission_response(_params, _state),
    do: %{"outcome" => %{"outcome" => "cancelled"}}

  defp choose_permission(options) do
    ["allow_always", "allow_once"]
    |> Enum.find_value(fn kind ->
      Enum.find_value(options, fn
        %{"kind" => ^kind, "optionId" => option_id} when is_binary(option_id) ->
          {:ok, option_id}

        _option ->
          nil
      end)
    end)
    |> case do
      {:ok, _option_id} = selected -> selected
      nil -> :error
    end
  end

  defp clear_active(%{active: %{monitor: monitor}} = state) do
    demonitor(monitor)
    cancel_timer(state.active.cancel_timer)
    %{state | active: nil}
  end

  defp request_cancel(%{active: %{cancel_timer: timer}} = state) when is_reference(timer),
    do: {:ok, state}

  defp request_cancel(state) do
    case send_cancel(state) do
      :ok ->
        timer =
          Process.send_after(self(), {:cancel_timeout, state.active.ref}, state.cancel_timeout)

        {:ok, put_in(state.active.cancel_timer, timer)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp send_cancel(state) do
    send_port(
      state.port,
      Protocol.notification("session/cancel", %{"sessionId" => state.acp_session_id})
    )
  end

  defp notify_active(%{caller: caller, ref: ref}, message) when is_pid(caller),
    do: send(caller, {__MODULE__, ref, message})

  defp notify_active(_active, _message), do: :ok

  defp stop_protocol(reason, state) do
    notify_active(state.active, {:error, {:protocol_error, reason}})
    {:stop, {:protocol_error, reason}, %{state | active: nil}}
  end

  defp initialize_agent(port) do
    params = %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{},
      "clientInfo" => %{"name" => "catalyst", "title" => "Catalyst", "version" => "0.1.0"}
    }

    sync_request(port, 0, "initialize", params)
  end

  defp open_session(port, cwd, id, nil, meta, _capabilities) do
    with {:ok, result, next_id} <-
           sync_request(port, id, "session/new", session_params(cwd, meta)),
         {:ok, session_id} <- session_id(result) do
      {:ok, result, session_id, next_id, :new}
    end
  end

  defp open_session(port, cwd, id, resume_id, meta, capabilities)
       when is_binary(resume_id) and byte_size(resume_id) > 0 do
    cond do
      resume_supported?(capabilities) ->
        recover_session(port, cwd, id, resume_id, meta, "session/resume", :resume)

      capabilities["loadSession"] == true ->
        recover_session(port, cwd, id, resume_id, meta, "session/load", :load)

      true ->
        {:error, {:session_recovery_unsupported, resume_id}}
    end
  end

  defp open_session(_port, _cwd, _id, resume_id, _meta, _capabilities),
    do: {:error, {:invalid_session_id, resume_id}}

  defp recover_session(port, cwd, id, session_id, meta, method, recovery) do
    params =
      cwd
      |> session_params(meta)
      |> Map.put("sessionId", session_id)

    with {:ok, result, next_id} <- sync_request(port, id, method, params),
         {:ok, result} <- recovery_result(result) do
      {:ok, result, session_id, next_id, recovery}
    end
  end

  defp sync_request(port, id, method, params, timeout \\ @handshake_timeout) do
    with :ok <- send_port(port, Protocol.request(id, method, params)),
         deadline = System.monotonic_time(:millisecond) + timeout,
         {:ok, result} <- await_response(port, id, deadline) do
      {:ok, result, id + 1}
    end
  end

  defp await_response(port, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_handshake_message(port, id, Protocol.decode(line), deadline)

      {^port, {:data, {:noeol, _partial}}} ->
        {:error, :line_too_large}

      {^port, {:exit_status, status}} ->
        {:error, {:process_exit, status}}

      {:EXIT, ^port, reason} ->
        {:error, {:port_exit, reason}}
    after
      remaining -> {:error, :handshake_timeout}
    end
  end

  defp handle_handshake_message(_port, id, {:ok, {:result, id, result}}, _deadline),
    do: {:ok, result}

  defp handle_handshake_message(_port, id, {:ok, {:error, id, error}}, _deadline),
    do: {:error, {:jsonrpc_error, error}}

  defp handle_handshake_message(
         port,
         id,
         {:ok, {:request, request_id, method, _params}},
         deadline
       ) do
    :ok = send_port(port, Protocol.method_not_found(request_id, method))
    await_response(port, id, deadline)
  end

  defp handle_handshake_message(port, id, {:ok, _notification}, deadline),
    do: await_response(port, id, deadline)

  defp handle_handshake_message(_port, _id, {:error, reason}, _deadline),
    do: {:error, {:protocol_error, reason}}

  defp finish_init(port, owner, agent, cwd, resume_id, session_meta, cancel_timeout) do
    with {:ok, initialized, next_id} <- initialize_agent(port),
         :ok <- validate_version(initialized),
         {:ok, capabilities} <- capabilities(initialized),
         {:ok, session, acp_session_id, next_id, recovery} <-
           open_session(port, cwd, next_id, resume_id, session_meta, capabilities),
         :ok <- cancel_timeout(cancel_timeout) do
      {:ok,
       %{
         port: port,
         owner: owner,
         owner_monitor: Process.monitor(owner),
         agent: agent,
         acp_session_id: acp_session_id,
         next_id: next_id,
         active: nil,
         cancel_timeout: cancel_timeout,
         capabilities: capabilities,
         agent_info: Map.get(initialized, "agentInfo"),
         session_metadata: session_metadata(session),
         recovery: recovery
       }}
    else
      {:error, reason} ->
        close_port(port)
        {:stop, reason}
    end
  end

  defp validate_version(%{"protocolVersion" => 1}), do: :ok
  defp validate_version(result), do: {:error, {:unsupported_protocol, result["protocolVersion"]}}

  defp capabilities(%{"agentCapabilities" => capabilities}) when is_map(capabilities),
    do: {:ok, capabilities}

  defp capabilities(%{"agentCapabilities" => capabilities}),
    do: {:error, {:invalid_agent_capabilities, capabilities}}

  defp capabilities(_initialized), do: {:ok, %{}}

  defp session_id(%{"sessionId" => id}) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp session_id(result), do: {:error, {:invalid_session, result}}

  defp recovery_result(result) when is_map(result), do: {:ok, result}
  defp recovery_result(nil), do: {:ok, %{}}
  defp recovery_result(result), do: {:error, {:invalid_recovery_result, result}}

  defp session_params(cwd, meta) do
    %{"cwd" => cwd, "mcpServers" => []}
    |> maybe_put_meta(meta)
  end

  defp maybe_put_meta(params, meta) when map_size(meta) == 0, do: params
  defp maybe_put_meta(params, meta), do: Map.put(params, "_meta", meta)

  defp resume_supported?(capabilities),
    do: is_map(get_in(capabilities, ["sessionCapabilities", "resume"]))

  defp session_metadata(result) do
    %{
      modes: Map.get(result, "modes"),
      config_options: Map.get(result, "configOptions"),
      available_commands: nil,
      session_info: nil,
      usage: nil,
      plan: nil
    }
  end

  defp retain_session_update(
         %{"sessionId" => session_id, "update" => update},
         %{acp_session_id: session_id} = state
       )
       when is_map(update) do
    %{state | session_metadata: update_session_metadata(state.session_metadata, update)}
  end

  defp retain_session_update(_params, state), do: state

  defp update_session_metadata(metadata, %{
         "sessionUpdate" => "config_option_update",
         "configOptions" => options
       })
       when is_list(options),
       do: %{metadata | config_options: options}

  defp update_session_metadata(metadata, %{
         "sessionUpdate" => "current_mode_update",
         "modeId" => mode_id
       })
       when is_binary(mode_id) do
    modes =
      case metadata.modes do
        modes when is_map(modes) -> Map.put(modes, "currentModeId", mode_id)
        _missing -> %{"currentModeId" => mode_id, "availableModes" => []}
      end

    %{metadata | modes: modes}
  end

  defp update_session_metadata(metadata, %{
         "sessionUpdate" => "available_commands_update",
         "availableCommands" => commands
       })
       when is_list(commands),
       do: %{metadata | available_commands: commands}

  defp update_session_metadata(metadata, %{"sessionUpdate" => "session_info_update"} = update),
    do: %{metadata | session_info: update}

  defp update_session_metadata(metadata, %{"sessionUpdate" => "usage_update"} = update),
    do: %{metadata | usage: update}

  defp update_session_metadata(metadata, %{"sessionUpdate" => "plan"} = update),
    do: %{metadata | plan: update}

  defp update_session_metadata(metadata, _update), do: metadata

  defp client_info(state) do
    %{
      session_id: state.acp_session_id,
      recovery: state.recovery,
      capabilities: state.capabilities,
      agent_info: state.agent_info,
      session: state.session_metadata
    }
  end

  defp close_session(%{active: nil, capabilities: capabilities} = state) do
    case is_map(get_in(capabilities, ["sessionCapabilities", "close"])) do
      true ->
        _result =
          sync_request(
            state.port,
            state.next_id,
            "session/close",
            %{"sessionId" => state.acp_session_id},
            @close_timeout
          )

        :ok

      false ->
        :ok
    end
  end

  defp close_session(_state), do: :ok

  defp cancel_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp cancel_timeout(timeout), do: {:error, {:invalid_cancel_timeout, timeout}}

  defp open_port(executable, agent, cwd) do
    options = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      {:line, @max_line_bytes},
      {:args, agent.args},
      {:cd, cwd},
      {:env, Enum.map(agent.env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)}
    ]

    {:ok, Port.open({:spawn_executable, executable}, options)}
  rescue
    error in ArgumentError -> {:error, {:process_launch, error}}
  end

  defp send_port(port, data) do
    true = Port.command(port, data)
    :ok
  rescue
    error in ArgumentError -> {:error, {:port_command, error}}
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp close_port(_port), do: :ok

  defp demonitor(monitor) when is_reference(monitor), do: Process.demonitor(monitor, [:flush])
  defp demonitor(_monitor), do: :ok

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: :ok
end
