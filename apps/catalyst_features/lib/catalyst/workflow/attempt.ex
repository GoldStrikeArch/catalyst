defmodule Catalyst.Workflow.Attempt do
  @moduledoc """
  Executes one workflow stage in an isolated child session.

  A worker owns one asynchronous stage run. With no `:session_id`, it creates
  an exclusively fresh transcript. Supplying a `:session_id` resumes that same
  transcript through `Session.Manager.start_session/1`, allowing a coordinator
  to retry without exposing the parent or implementation transcript.

  The owner receives:

    * `{:workflow_attempt, pid, {:started, details}}`
    * `{:workflow_attempt, pid, {:activity, details}}`
    * `{:workflow_attempt, pid, {:finished, outcome}}`

  `outcome` is `{:ok, result}` or `{:error, failure}`. Failures include a
  `:class` of `:recoverable` or `:terminal`; this worker never chooses whether
  to retry. The child is monitored and stopped after every outcome, while its
  persisted transcript remains available for a later resume.

  Required options are `:owner`, `:goal`, `:cwd`, `:model`, and `:provider`.
  `:artifacts` defaults to an empty map or list. Optional runtime controls are
  `:inactivity_timeout`, `:hard_timeout`, `:max_artifact_bytes`,
  `:system_prompt`, `:session_id`, and `:session_adapter`.
  """

  use GenServer

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Ids, Message, Tasks}
  alias Catalyst.Tools.Truncate
  alias Catalyst.Workflow.Attempt.Session

  @default_inactivity_timeout 120_000
  @default_hard_timeout 600_000
  @default_max_artifact_bytes 8 * 1_024
  @min_artifact_bytes 512
  @max_artifact_bytes 64 * 1_024
  @id_attempts 5
  @notice_reserve_bytes 256

  @typedoc "Coordinator-owned retry classification."
  @type error_class :: :recoverable | :terminal

  @typedoc "Successful bounded child artifact."
  @type result :: %{
          child_session_id: String.t(),
          artifact: String.t(),
          stop_reason: Message.Assistant.stop_reason(),
          incomplete: boolean(),
          truncated: boolean()
        }

  @typedoc "Classified stage failure."
  @type failure :: %{
          class: error_class(),
          reason: term(),
          child_session_id: String.t() | nil
        }

  @doc """
  Start one unregistered attempt worker.

  Startup validates all boundary input. Session creation and prompting happen
  asynchronously after `start_link/1` returns.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Return a temporary one-shot worker specification."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Supervisor.child_spec(%{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}},
      restart: :temporary
    )
  end

  @doc "Abort the active attempt. The owner receives one recoverable finished outcome."
  @spec abort(GenServer.server()) :: :ok
  def abort(server), do: GenServer.cast(server, :abort)

  @doc "Classify a child/session failure without making a retry decision."
  @spec classify_error(term()) :: error_class()
  def classify_error(reason)

  def classify_error(reason)
      when reason in [
             :aborted,
             :hard_timeout,
             :inactivity_timeout,
             :child_missing_assistant,
             :child_blank_assistant,
             :child_incomplete_assistant
           ],
      do: :recoverable

  def classify_error({kind, _detail})
      when kind in [
             :child_down,
             :child_prompt,
             :child_prompt_exit,
             :child_provider_error,
             :session_start,
             :session_start_exit,
             :subscribe
           ],
      do: :recoverable

  def classify_error(_reason), do: :terminal

  @impl true
  def init(opts) do
    with {:ok, state} <- validate(opts) do
      state = %{state | owner_monitor: Process.monitor(state.owner)}
      {:ok, start_timers(state), {:continue, :start}}
    end
  end

  @impl true
  def handle_continue(:start, state) do
    owner = self()
    token = make_ref()

    case Tasks.start_background(fn -> start_watchdog(owner, token, state) end) do
      {:ok, watchdog} ->
        monitor = Process.monitor(watchdog)

        {:noreply,
         %{state | start_watchdog: watchdog, start_monitor: monitor, start_token: token}}

      {:error, reason} ->
        finish(state, {:error, {:session_start, reason}})
    end
  end

  @impl true
  def handle_cast(:abort, %{finished?: false} = state) do
    cancel_start(state)
    abort_child(state)
    finish(state, {:error, :aborted})
  end

  def handle_cast(:abort, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:attempt_session_started, token, watchdog, session},
        %{start_token: token, start_watchdog: watchdog} = state
      ) do
    subscribe_and_prompt(state, session)
  end

  def handle_info(
        {:attempt_session_start_failed, token, watchdog, reason},
        %{start_token: token, start_watchdog: watchdog} = state
      ) do
    finish(clear_start(state), {:error, reason})
  end

  def handle_info(
        {:DOWN, monitor, :process, watchdog, reason},
        %{start_monitor: monitor, start_watchdog: watchdog} = state
      ) do
    finish(clear_start(state), {:error, {:session_start_exit, reason}})
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner_monitor: monitor, owner: owner} = state
      ) do
    cancel_start(state)
    abort_child(state)
    {:stop, :normal, %{state | finished?: true}}
  end

  def handle_info({:agent_event, child_id, %Event.AgentEnd{messages: messages}}, state)
      when child_id == state.child_id do
    finish(state, final_result(messages, state.max_artifact_bytes))
  end

  def handle_info({:agent_event, child_id, event}, state) when child_id == state.child_id do
    state = reset_inactivity_timer(state)
    notify(state, {:activity, activity(state, event)})
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state)
      when monitor == state.child_monitor and pid == state.child do
    finish(clear_child(state), {:error, {:child_down, reason}})
  end

  def handle_info({:attempt_timeout, :inactivity, token}, %{inactivity_token: token} = state) do
    cancel_start(state)
    abort_child(state)
    finish(state, {:error, :inactivity_timeout})
  end

  def handle_info({:attempt_timeout, :hard, token}, %{hard_token: token} = state) do
    cancel_start(state)
    abort_child(state)
    finish(state, {:error, :hard_timeout})
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp validate(opts) when is_list(opts) do
    values = %{
      owner: Keyword.get(opts, :owner),
      goal: Keyword.get(opts, :goal),
      artifacts: Keyword.get(opts, :artifacts, %{}),
      cwd: Keyword.get(opts, :cwd),
      model: Keyword.get(opts, :model),
      provider: Keyword.get(opts, :provider),
      session_id: Keyword.get(opts, :session_id),
      parent_id: Keyword.get(opts, :parent_id),
      root_id: Keyword.get(opts, :root_session_id),
      tools: Keyword.get(opts, :tools, :extensions),
      session_opts: Keyword.get(opts, :opts, []),
      system_prompt: Keyword.get(opts, :system_prompt),
      adapter: Keyword.get(opts, :session_adapter, Session),
      inactivity_timeout: Keyword.get(opts, :inactivity_timeout, @default_inactivity_timeout),
      hard_timeout: Keyword.get(opts, :hard_timeout, @default_hard_timeout),
      max_artifact_bytes: Keyword.get(opts, :max_artifact_bytes, @default_max_artifact_bytes)
    }

    with :ok <- validate_required(values),
         :ok <- validate_limits(values),
         {:ok, prompt} <- stage_prompt(values.goal, values.artifacts) do
      {:ok,
       Map.merge(values, %{
         prompt: prompt,
         child_id: nil,
         child: nil,
         child_monitor: nil,
         subscribed?: false,
         inactivity_timer: nil,
         inactivity_token: nil,
         hard_timer: nil,
         hard_token: nil,
         start_watchdog: nil,
         start_monitor: nil,
         start_token: nil,
         owner_monitor: nil,
         finished?: false
       })}
    end
  end

  defp validate(opts), do: {:stop, {:invalid_attempt_options, opts}}

  defp validate_required(values) do
    cond do
      not is_pid(values.owner) ->
        {:stop, {:invalid_owner, values.owner}}

      not nonblank?(values.goal) ->
        {:stop, {:invalid_goal, values.goal}}

      not nonblank?(values.cwd) ->
        {:stop, {:invalid_cwd, values.cwd}}

      is_nil(values.model) ->
        {:stop, :missing_model}

      is_nil(values.provider) ->
        {:stop, :missing_provider}

      not valid_session_id?(values.session_id) ->
        {:stop, {:invalid_session_id, values.session_id}}

      not Keyword.keyword?(values.session_opts) ->
        {:stop, {:invalid_session_opts, values.session_opts}}

      not is_atom(values.adapter) ->
        {:stop, {:invalid_session_adapter, values.adapter}}

      true ->
        :ok
    end
  end

  defp validate_limits(values) do
    cond do
      not positive_integer?(values.inactivity_timeout) ->
        {:stop, {:invalid_inactivity_timeout, values.inactivity_timeout}}

      not positive_integer?(values.hard_timeout) ->
        {:stop, {:invalid_hard_timeout, values.hard_timeout}}

      not is_integer(values.max_artifact_bytes) or
        values.max_artifact_bytes < @min_artifact_bytes or
          values.max_artifact_bytes > @max_artifact_bytes ->
        {:stop, {:invalid_max_artifact_bytes, values.max_artifact_bytes}}

      true ->
        :ok
    end
  end

  defp stage_prompt(goal, artifacts) do
    case Jason.encode(artifacts, pretty: true) do
      {:ok, encoded} ->
        {:ok,
         """
         Goal:
         #{goal}

         Explicit artifacts:
         #{encoded}

         Inspect the current workspace as needed. Return only the final stage artifact.
         """}

      {:error, reason} ->
        {:stop, {:invalid_artifacts, reason}}
    end
  end

  defp start_session(%{session_id: nil} = state, attempts) do
    start_fresh(state, attempts)
  end

  defp start_session(state, _attempts) do
    invoke(state.adapter, :resume, [session_opts(state, state.session_id)])
    |> normalize_start()
  end

  defp start_fresh(_state, 0), do: {:error, :session_id_retries_exhausted}

  defp start_fresh(state, attempts) do
    child_id = fresh_id(state.parent_id)

    case invoke(state.adapter, :start_fresh, [session_opts(state, child_id)]) do
      {:ok, %{id: ^child_id, pid: pid}} when is_pid(pid) ->
        {:ok, %{id: child_id, pid: pid}}

      {:error, reason} ->
        case collision?(reason) do
          true -> start_fresh(state, attempts - 1)
          false -> {:error, {:session_start, reason}}
        end

      other ->
        {:error, {:session_start, {:invalid_result, other}}}
    end
  end

  defp normalize_start({:ok, %{id: id, pid: pid}}) when is_binary(id) and is_pid(pid),
    do: {:ok, %{id: id, pid: pid}}

  defp normalize_start({:error, reason}), do: {:error, {:session_start, reason}}
  defp normalize_start(other), do: {:error, {:session_start, {:invalid_result, other}}}

  defp start_watchdog(owner, token, state) do
    owner_monitor = Process.monitor(owner)

    case start_session(state, @id_attempts) do
      {:ok, session} ->
        send(owner, {:attempt_session_started, token, self(), session})
        await_handoff(owner, owner_monitor, token, session, state.adapter)

      {:error, reason} ->
        send(owner, {:attempt_session_start_failed, token, self(), reason})
    end
  end

  defp await_handoff(owner, owner_monitor, token, session, adapter) do
    receive do
      {:accept_attempt_session, ^token} ->
        :ok

      {:cancel_attempt_session, ^token} ->
        invoke(adapter, :stop, [session.id])

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        invoke(adapter, :stop, [session.id])
    end
  end

  defp subscribe_and_prompt(state, %{id: child_id, pid: child}) do
    state = %{state | child_id: child_id, child: child, child_monitor: Process.monitor(child)}

    with :ok <- subscribe(state.adapter, child_id),
         state = %{state | subscribed?: true},
         :ok <- prompt(state.adapter, child, state.prompt) do
      accept_start(state)
      state = clear_start(state)
      notify(state, {:started, %{child_session_id: child_id, resumed: state.session_id != nil}})
      {:noreply, state}
    else
      {:error, reason} -> finish(state, {:error, reason})
    end
  end

  defp session_opts(state, child_id) do
    [
      id: child_id,
      cwd: state.cwd,
      system_prompt: state.system_prompt,
      model: state.model,
      provider: state.provider,
      tools: state.tools,
      opts: strip_parent_workflow(state.session_opts),
      parent_id: state.parent_id,
      root_session_id: state.root_id
    ]
  end

  defp strip_parent_workflow(opts) do
    opts
    |> Keyword.delete(:workflow)
    |> Keyword.delete(:loop)
  end

  defp start_timers(state) do
    hard_token = make_ref()

    hard_timer =
      Process.send_after(self(), {:attempt_timeout, :hard, hard_token}, state.hard_timeout)

    state
    |> Map.merge(%{hard_token: hard_token, hard_timer: hard_timer})
    |> reset_inactivity_timer()
  end

  defp reset_inactivity_timer(state) do
    cancel_timer(state.inactivity_timer)
    token = make_ref()

    timer =
      Process.send_after(self(), {:attempt_timeout, :inactivity, token}, state.inactivity_timeout)

    %{state | inactivity_token: token, inactivity_timer: timer}
  end

  defp final_result(messages, max_bytes) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&match?(%Message.Assistant{}, &1))
    |> classify_assistant(max_bytes)
  end

  defp final_result(_messages, _max_bytes), do: {:error, :child_missing_assistant}

  defp classify_assistant(nil, _max_bytes), do: {:error, :child_missing_assistant}

  defp classify_assistant(%Message.Assistant{stop_reason: :error} = assistant, _max_bytes),
    do: {:error, {:child_provider_error, assistant.error_message}}

  defp classify_assistant(%Message.Assistant{stop_reason: :aborted}, _max_bytes),
    do: {:error, :aborted}

  defp classify_assistant(%Message.Assistant{stop_reason: :length}, _max_bytes),
    do: {:error, :child_incomplete_assistant}

  defp classify_assistant(%Message.Assistant{} = assistant, max_bytes) do
    text = assistant.content |> Content.text_of() |> Truncate.scrub_utf8()

    case String.trim(text) do
      "" -> {:error, :child_blank_assistant}
      _content -> {:ok, bounded_artifact(text, assistant.stop_reason, max_bytes)}
    end
  end

  defp bounded_artifact(text, stop_reason, max_bytes) do
    body_bytes = max(1, max_bytes - @notice_reserve_bytes)

    {artifact, info} =
      Truncate.head_notice(text, max_bytes: body_bytes, max_lines: max(1, byte_size(text) + 1))

    %{
      artifact: artifact,
      stop_reason: stop_reason,
      incomplete: stop_reason == :length,
      truncated: info.truncated
    }
  end

  defp finish(%{finished?: true} = state, _outcome), do: {:noreply, state}

  defp finish(state, outcome) do
    result = attach_outcome_session(outcome, state.child_id)
    notify(state, {:finished, result})
    cleanup(state)

    {:stop, :normal,
     %{
       state
       | finished?: true,
         child_id: nil,
         child: nil,
         child_monitor: nil,
         subscribed?: false,
         start_watchdog: nil,
         start_monitor: nil,
         start_token: nil,
         inactivity_timer: nil,
         hard_timer: nil
     }}
  end

  defp attach_outcome_session({:ok, result}, child_id),
    do: {:ok, Map.put(result, :child_session_id, child_id)}

  defp attach_outcome_session({:error, reason}, child_id) do
    {:error, %{class: classify_error(reason), reason: reason, child_session_id: child_id}}
  end

  defp activity(state, event) do
    %{child_session_id: state.child_id, event: event_name(event)}
  end

  defp event_name(%module{}), do: module |> Module.split() |> List.last() |> Macro.underscore()
  defp event_name(_event), do: "unknown"

  defp abort_child(%{child: child, adapter: adapter}) when is_pid(child) do
    _result = invoke(adapter, :abort, [child])
    :ok
  end

  defp abort_child(_state), do: :ok

  defp cleanup(state) do
    cancel_start(state)
    cancel_timer(state.inactivity_timer)
    cancel_timer(state.hard_timer)
    demonitor(state.child_monitor)
    demonitor(state.owner_monitor)

    case state.subscribed? and is_binary(state.child_id) do
      true -> _result = invoke(state.adapter, :unsubscribe, [state.child_id])
      false -> :ok
    end

    case is_binary(state.child_id) do
      true -> _result = invoke(state.adapter, :stop, [state.child_id])
      false -> :ok
    end

    :ok
  end

  defp clear_child(state) do
    %{state | child: nil, child_monitor: nil}
  end

  defp accept_start(%{start_watchdog: watchdog, start_token: token})
       when is_pid(watchdog) and is_reference(token) do
    send(watchdog, {:accept_attempt_session, token})
  end

  defp accept_start(_state), do: :ok

  defp cancel_start(%{start_watchdog: watchdog, start_token: token})
       when is_pid(watchdog) and is_reference(token) do
    send(watchdog, {:cancel_attempt_session, token})
  end

  defp cancel_start(_state), do: :ok

  defp clear_start(state) do
    demonitor(state.start_monitor)
    %{state | start_watchdog: nil, start_monitor: nil, start_token: nil}
  end

  defp subscribe(adapter, child_id),
    do: normalize_adapter_result(invoke(adapter, :subscribe, [child_id]), :subscribe)

  defp prompt(adapter, child, prompt),
    do: normalize_adapter_result(invoke(adapter, :prompt, [child, prompt]), :child_prompt)

  defp normalize_adapter_result(:ok, _kind), do: :ok
  defp normalize_adapter_result({:error, reason}, kind), do: {:error, {kind, reason}}
  defp normalize_adapter_result(other, kind), do: {:error, {kind, {:invalid_result, other}}}

  defp invoke(adapter, function, arguments) do
    apply(adapter, function, arguments)
  catch
    :exit, reason -> {:error, {function, {:exit, reason}}}
  end

  defp notify(state, event), do: send(state.owner, {:workflow_attempt, self(), event})

  defp fresh_id(parent_id) do
    prefix =
      case nonblank?(parent_id) do
        true -> parent_id <> "_w"
        false -> "workflow_"
      end

    prefix <> Ids.hex(16)
  end

  defp collision?({:session_id_collision, _id}), do: true
  defp collision?({:session_exists, _id}), do: true
  defp collision?(_reason), do: false

  defp valid_session_id?(nil), do: true
  defp valid_session_id?(id), do: nonblank?(id) and id =~ ~r/\A[A-Za-z0-9_-]+\z/

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp demonitor(nil), do: :ok
  defp demonitor(monitor), do: Process.demonitor(monitor, [:flush])
end
