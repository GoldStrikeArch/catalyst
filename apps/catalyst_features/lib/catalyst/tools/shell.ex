defmodule Catalyst.Tools.Shell do
  @moduledoc """
  Cross-turn PTY shell sessions: the API over `Catalyst.Tools.Shell.Server`
  processes supervised by `Catalyst.Tools.Shell.Supervisor` and registered in
  `Catalyst.Tools.Shell.Registry` (key: shell-session id, value: owning
  Catalyst session id).

  Every read is bounded by `max_bytes` and a `yield_ms` window, and ownership
  is enforced here: an id registered to a different Catalyst session returns
  `{:error, :not_owner}` rather than touching the shell. The concurrent-shell
  cap is `config :catalyst, :shell_session_max` (default 4, global — one
  machine, one pool of PTYs).

  `collect/3` runs its receive loop in the **caller**, mirroring
  `Catalyst.Tools.Exec`'s chunk-relay shape: the server streams
  `{ref, {:chunk, binary}}` messages (each offered to the crash-isolated
  `:on_chunk` observer) and finishes with `{ref, {:done, summary}}`; a server
  crash mid-collect is caught by monitor. Timeouts, exits, and denials are all
  tagged tuples.
  """

  alias Catalyst.Tools.Shell.Server

  @registry Catalyst.Tools.Shell.Registry
  @supervisor Catalyst.Tools.Shell.Supervisor
  @default_max_sessions 4
  @collect_slack_ms 5_000

  @typedoc "One live (or exited, not-yet-reaped) shell session's description."
  @type info :: %{
          id: String.t(),
          owner: String.t() | nil,
          shell: String.t(),
          os_pid: integer() | nil,
          alive: boolean(),
          exit_status: integer() | nil,
          pending_bytes: non_neg_integer()
        }

  @typedoc "The bounded output of one collect window."
  @type collected :: %{
          output: binary(),
          exit_status: integer() | nil,
          alive: boolean(),
          truncated: boolean(),
          dropped_bytes: non_neg_integer()
        }

  @doc "Registry name holding one entry per live shell session."
  @spec registry() :: module()
  def registry, do: @registry

  @doc "The configured cap on concurrent shell sessions."
  @spec max_sessions() :: pos_integer()
  def max_sessions,
    do: Application.get_env(:catalyst, :shell_session_max, @default_max_sessions)

  @doc """
  Start a new PTY shell owned by Catalyst session `owner` (a session id or
  `nil`). Options: `:shell`, `:cwd`, `:owner_pid` (test seam forwarded to the
  server). Returns `{:ok, id}`, or `{:error, {:limit_reached, max}}` /
  `{:error, reason}`.
  """
  @spec start_session(String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_session(owner, opts \\ []) do
    case Registry.count(@registry) < max_sessions() do
      true -> do_start(owner, opts)
      false -> {:error, {:limit_reached, max_sessions()}}
    end
  end

  defp do_start(owner, opts) do
    id = "sh-" <> Catalyst.Ids.hex(4)
    child_opts = Keyword.merge(opts, id: id, owner: owner)

    case DynamicSupervisor.start_child(@supervisor, {Server, child_opts}) do
      {:ok, _pid} -> {:ok, id}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send `chars` to the shell's stdin exactly as given — no newline is appended;
  the PTY line discipline will echo them back into the output stream.
  """
  @spec send_input(String.t(), String.t() | nil, binary()) :: :ok | {:error, term()}
  def send_input(id, owner, chars) when is_binary(chars) do
    with {:ok, pid} <- fetch_owned(id, owner) do
      call(pid, {:write, chars})
    end
  end

  @doc """
  Collect pending output for up to `yield_ms`, bounded by `max_bytes`.

  Options: `:yield_ms` (required), `:max_bytes` (required), `:on_chunk`
  (optional observer called in this process per chunk; crash-isolated).
  Finishes early when the byte budget fills or the shell exits. Returns
  `{:ok, collected}` or a tagged error (`:not_found`, `:not_owner`, `:busy`,
  `{:shell_down, reason}`, `:collect_timeout`).
  """
  @spec collect(String.t(), String.t() | nil, keyword()) ::
          {:ok, collected()} | {:error, term()}
  def collect(id, owner, opts) do
    yield_ms = Keyword.fetch!(opts, :yield_ms)
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    with {:ok, pid} <- fetch_owned(id, owner) do
      ref = make_ref()
      monitor = Process.monitor(pid)
      GenServer.cast(pid, {:collect, self(), ref, yield_ms, max_bytes})

      result =
        collect_loop(ref, monitor, [], Keyword.get(opts, :on_chunk), deadline(yield_ms))

      Process.demonitor(monitor, [:flush])
      drain(ref)
      result
    end
  end

  @doc "Close the shell session: process-group kill, port close, unregister."
  @spec close(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def close(id, owner) do
    with {:ok, pid} <- fetch_owned(id, owner) do
      call(pid, :close)
    end
  end

  @doc "Describe the shell sessions owned by Catalyst session `owner`."
  @spec list(String.t() | nil) :: [info()]
  def list(owner) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [{:==, :"$3", {:const, owner}}], [:"$2"]}])
    |> Enum.flat_map(&safe_info/1)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Live pid and info lookup honoring ownership."
  @spec fetch_owned(String.t(), String.t() | nil) :: {:ok, pid()} | {:error, term()}
  def fetch_owned(id, owner) do
    case Registry.lookup(@registry, id) do
      [{pid, ^owner}] -> {:ok, pid}
      [{_pid, _other_owner}] -> {:error, :not_owner}
      [] -> {:error, :not_found}
    end
  end

  defp call(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, {:noproc, _call} -> {:error, :not_found}
    :exit, {{:shutdown, _reason}, _call} -> {:error, :not_found}
  end

  defp safe_info(pid) do
    case call(pid, :info) do
      {:error, _gone} -> []
      info -> [info]
    end
  end

  defp deadline(yield_ms), do: System.monotonic_time(:millisecond) + yield_ms + @collect_slack_ms

  defp collect_loop(ref, monitor, acc, on_chunk, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, {:chunk, data}} ->
        safe_chunk(on_chunk, data)
        collect_loop(ref, monitor, [data | acc], on_chunk, deadline)

      {^ref, {:done, summary}} ->
        {:ok, Map.put(summary, :output, finish_output(acc))}

      {^ref, {:error, reason}} ->
        {:error, reason}

      {:DOWN, ^monitor, :process, _pid, reason} ->
        collect_down(acc, reason)
    after
      remaining -> {:error, :collect_timeout}
    end
  end

  # The server's terminate sends the pending summary before the DOWN arrives
  # in most shutdowns; a kill skips terminate, so salvage what was streamed.
  defp collect_down(acc, reason) do
    case drain_done() do
      {:ok, summary} -> {:ok, Map.put(summary, :output, finish_output(acc))}
      :error -> {:error, {:shell_down, reason, finish_output(acc)}}
    end
  end

  defp drain_done do
    receive do
      {_ref, {:done, summary}} -> {:ok, summary}
    after
      0 -> :error
    end
  end

  defp finish_output(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp safe_chunk(nil, _data), do: :ok

  defp safe_chunk(fun, data) when is_function(fun, 1) do
    fun.(data)
  rescue
    _observer_error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp drain(ref) do
    receive do
      {^ref, _late} -> drain(ref)
    after
      0 -> :ok
    end
  end
end
