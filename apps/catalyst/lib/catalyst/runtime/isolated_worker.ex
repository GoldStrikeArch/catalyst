defmodule Catalyst.Runtime.IsolatedWorker do
  @moduledoc """
  Candidate-owned host for one isolated permission-policy VM.

  Source is compiled only by the external Elixir process. Stopping the managed
  generation closes its port and terminates that VM. This provides VM/process
  crash isolation, not an OS sandbox: the worker still runs as the Catalyst user
  and can access that user's filesystem and network.
  """

  use GenServer

  alias Catalyst.Runtime.{ActivationId, IsolatedWorker.Protocol}

  @registry Catalyst.Runtime.IsolatedWorkerRegistry
  @default_start_timeout 30_000
  @default_wire_bytes 256 * 1_024

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :owner)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    activation_id = Keyword.fetch!(opts, :activation_id)
    owner = Keyword.fetch!(opts, :owner)
    GenServer.start_link(__MODULE__, opts, name: via(activation_id, owner))
  end

  @doc "Invoke one callback in the worker belonging to a pinned generation."
  @spec call(ActivationId.t() | nil, String.t(), term(), atom(), [term()], timeout()) ::
          {:ok, term()} | {:error, term()}
  def call(nil, _owner, _protocol, _callback, _args, _timeout),
    do: {:error, :isolated_worker_requires_generation}

  def call(%ActivationId{} = activation_id, owner, protocol, callback, args, timeout) do
    with {:ok, worker} <- lookup(activation_id, owner) do
      GenServer.call(worker, {:call, protocol, callback, args, timeout}, timeout + 100)
    end
  catch
    :exit, reason -> {:error, {:isolated_worker_call_exit, reason}}
  end

  @doc false
  @spec lookup(ActivationId.t(), String.t()) :: {:ok, pid()} | :error
  def lookup(%ActivationId{} = activation_id, owner) when is_binary(owner) do
    case Registry.lookup(@registry, registry_key(activation_id, owner)) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc false
  @spec port(pid()) :: {:ok, port()} | {:error, term()}
  def port(worker), do: GenServer.call(worker, :port)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, executable} <- executable(),
         {:ok, port} <- open_port(executable, opts),
         :ok <- await_ready(port, Keyword.fetch!(opts, :expected_artifact), start_timeout()) do
      {:ok, %{port: port, next_id: 1, status: :ready}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, {:ok, state.port}, state}

  def handle_call(
        {:call, _protocol, _callback, _args, _timeout},
        _from,
        %{status: status} = state
      )
      when status != :ready do
    {:reply, {:error, status}, state}
  end

  def handle_call({:call, :permission_policy_v1, callback, args, timeout}, _from, state) do
    id = state.next_id

    with {:ok, request} <- Protocol.request(id, callback, args, wire_bytes()),
         :ok <- send_request(state.port, request),
         {:ok, line} <- await_line(state.port, timeout),
         {:ok, result} <- Protocol.decode_response(line, id) do
      {:reply, {:ok, result}, %{state | next_id: id + 1}}
    else
      {:error, reason} -> worker_failed(state, reason)
    end
  rescue
    error in [ArgumentError, ErlangError] -> worker_failed(state, Exception.message(error))
  end

  def handle_call({:call, protocol, _callback, _args, _timeout}, _from, state),
    do: {:reply, {:error, {:unsupported_isolated_worker_protocol, protocol}}, state}

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:noreply, %{state | status: {:exited, status}}}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:noreply, %{state | status: {:exited, reason}}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    close_port(port)
  end

  defp worker_failed(state, reason) do
    close_port(state.port)
    {:reply, {:error, reason}, %{state | status: {:failed, reason}}}
  end

  defp open_port(executable, opts) do
    args =
      ["--erl", "+S 1:1 +SDcpu 1 +SDio 1"] ++
        code_path_args() ++
        [
          "-e",
          "Catalyst.Runtime.IsolatedWorker.Boot.main()",
          "--",
          Path.expand(Keyword.fetch!(opts, :source_path)),
          Keyword.fetch!(opts, :expected_artifact),
          Integer.to_string(wire_bytes())
        ]

    {:ok,
     Port.open(
       {:spawn_executable, executable},
       [
         :binary,
         :exit_status,
         :hide,
         :use_stdio,
         {:line, wire_bytes()},
         args: args
       ]
     )}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:isolated_worker_start_failed, Exception.message(error)}}
  end

  defp await_ready(port, expected_artifact, timeout) do
    with {:ok, line} <- await_line(port, timeout) do
      Protocol.decode_ready(line, expected_artifact)
    end
  end

  defp send_request(port, request) do
    Port.command(port, request)
    :ok
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:isolated_worker_send_failed, Exception.message(error)}}
  end

  defp await_line(port, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} -> {:ok, line}
      {^port, {:data, {:noeol, _line}}} -> {:error, :isolated_worker_response_limit}
      {^port, {:exit_status, status}} -> {:error, {:isolated_worker_exit, status}}
      {:EXIT, ^port, reason} -> {:error, {:isolated_worker_exit, reason}}
    after
      timeout -> {:error, :isolated_worker_timeout}
    end
  end

  defp executable do
    case Application.get_env(:catalyst, :isolated_worker_executable) ||
           System.find_executable("elixir") do
      nil -> {:error, :elixir_executable_not_found}
      path when is_binary(path) -> {:ok, path}
      path -> {:error, {:invalid_isolated_worker_executable, path}}
    end
  end

  defp code_path_args do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&["-pa", &1])
  end

  defp close_port(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp via(activation_id, owner),
    do: {:via, Registry, {@registry, registry_key(activation_id, owner)}}

  defp registry_key(activation_id, owner),
    do: {ActivationId.to_wire(activation_id), owner}

  defp start_timeout do
    configured_positive(:isolated_worker_start_timeout, @default_start_timeout)
  end

  defp wire_bytes do
    configured_positive(:isolated_worker_wire_bytes, @default_wire_bytes)
  end

  defp configured_positive(key, default) do
    case Application.get_env(:catalyst, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end
end
