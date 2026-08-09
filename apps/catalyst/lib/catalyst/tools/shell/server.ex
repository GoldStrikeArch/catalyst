defmodule Catalyst.Tools.Shell.Server do
  @moduledoc """
  One PTY-backed shell session: a supervised GenServer owning a `script(1)`
  `Port`, registered by shell-session id in `Catalyst.Tools.Shell.Registry`
  (registry value = owning Catalyst session id).

  Lifecycle safety:

    * **Owner-bound teardown** — when the owning Catalyst session id resolves
      to a live `Session.Server`, that pid is monitored and the shell stops on
      its `:DOWN`, so shells never outlive their session.
    * **Idle timeout** — `config :catalyst, :shell_session_idle_ms` (default
      15 min) of no tool interaction closes the PTY.
    * **Group kill on close** — `Port.close/1` alone can orphan the shell that
      `script` spawned on the PTY slave, so terminate kills each direct child
      of `script` **by process group** (the shell is a session leader on the
      slave side), then `script` itself, then closes the port. Best-effort:
      a HUP-ignoring grandchild in its own process group can survive.

  Collection is non-blocking: `{:collect, caller, ref, ...}` streams buffered
  and arriving output to the caller as `{ref, {:chunk, binary}}` messages and
  finishes with `{ref, {:done, summary}}` after `yield_ms`, when `max_bytes`
  is reached, or when the shell exits — the server's mailbox stays free to
  service owner `:DOWN` and port exits throughout. The caller is monitored;
  an aborted caller cancels the pending collect while the shell lives on
  (shell sessions deliberately survive run aborts — that is their point).
  """

  use GenServer, restart: :temporary

  alias Catalyst.Tools.Shell.{Buffer, Pty}

  @registry Catalyst.Tools.Shell.Registry
  @buffer_cap 256 * 1024
  @default_idle_ms 15 * 60 * 1000

  defstruct [
    :id,
    :owner,
    :owner_ref,
    :port,
    :os_pid,
    :shell,
    :buffer,
    :exit_status,
    :pending,
    :idle_ref
  ]

  @typedoc "Summary returned when one collect window finishes."
  @type summary :: %{
          exit_status: integer() | nil,
          alive: boolean(),
          truncated: boolean(),
          dropped_bytes: non_neg_integer()
        }

  @doc """
  Start a shell server. Options: `:id` (required), `:owner` (owning Catalyst
  session id or `nil`), `:shell` (path; defaults per `Pty.default_shell/1`),
  `:cwd`, `:owner_pid` (test seam; defaults to resolving `:owner` via
  `Catalyst.Session.Manager.whereis/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    owner = Keyword.get(opts, :owner)
    name = {:via, Registry, {@registry, id, owner}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    shell = Keyword.get(opts, :shell) || Pty.default_shell()

    # Registration happened in start_link (:via), so counting here closes the
    # check-then-act window in `Shell.start_session/2`: with two concurrent
    # starts, whichever registrations pushed the count past the cap stop
    # before opening a PTY.
    with :ok <- enforce_cap() do
      case Pty.wrap(System.find_executable("script"), shell) do
        {:ok, {exe, args}} -> open_pty(opts, shell, exe, args)
        {:error, reason} -> {:stop, {:shutdown, reason}}
      end
    end
  end

  defp enforce_cap do
    max = Catalyst.Tools.Shell.max_sessions()

    case Registry.count(@registry) > max do
      true -> {:stop, {:shutdown, {:limit_reached, max}}}
      false -> :ok
    end
  end

  defp open_pty(opts, shell, exe, args) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()

    port =
      Port.open(
        {:spawn_executable, exe},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          {:args, args},
          {:cd, cwd},
          # A dumb terminal keeps prompt escape-sequence noise down; the PTY
          # still echoes input and emits \r\n line endings.
          {:env, [{~c"TERM", ~c"dumb"}]}
        ]
      )

    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      owner: Keyword.get(opts, :owner),
      owner_ref: monitor_owner(opts),
      port: port,
      os_pid: port_os_pid(port),
      shell: shell,
      buffer: Buffer.new(@buffer_cap),
      exit_status: nil,
      pending: nil
    }

    {:ok, arm_idle(state)}
  end

  @impl true
  def handle_call({:write, _chars}, _from, %__MODULE__{port: nil} = state),
    do: {:reply, {:error, {:shell_exited, state.exit_status}}, state}

  def handle_call({:write, chars}, _from, state) do
    # The port can die between our check and the write (its exit_status
    # message may still be in the mailbox); Port.command then raises.
    try do
      Port.command(state.port, chars)
      {:reply, :ok, arm_idle(state)}
    rescue
      ArgumentError ->
        {:reply, {:error, {:shell_exited, state.exit_status}}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      id: state.id,
      owner: state.owner,
      shell: state.shell,
      os_pid: state.os_pid,
      alive: state.port != nil,
      exit_status: state.exit_status,
      pending_bytes: Buffer.size(state.buffer)
    }

    {:reply, info, state}
  end

  def handle_call(:close, _from, state) do
    {:stop, {:shutdown, :closed}, :ok, state}
  end

  @impl true
  def handle_cast({:collect, caller, ref, yield_ms, max_bytes}, state) do
    case state.pending do
      nil -> {:noreply, state |> begin_collect(caller, ref, yield_ms, max_bytes) |> arm_idle()}
      _busy -> non_reply(caller, ref, {:error, :busy}, state)
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %__MODULE__{port: port} = state) do
    {:noreply, state |> Map.update!(:buffer, &Buffer.push(&1, data)) |> flush_pending()}
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    # The wrapper exited: record it and drop the reaped os_pid — the OS may
    # recycle that pid, so it must never remain a later kill target. The
    # server stays alive so the final buffered output can still be read; the
    # idle timeout reaps the rest.
    state = %{state | port: nil, os_pid: nil, exit_status: status}
    {:noreply, finish_pending_now(state)}
  end

  def handle_info({:EXIT, port, _reason}, %__MODULE__{port: port} = state) do
    {:noreply, finish_pending_now(%{state | port: nil, os_pid: nil})}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  def handle_info({:yield_done, ref}, %__MODULE__{pending: %{ref: ref}} = state),
    do: {:noreply, finish_pending_now(state)}

  def handle_info({:yield_done, _stale}, state), do: {:noreply, state}

  def handle_info({:idle_timeout, token}, %__MODULE__{idle_ref: {token, _timer}} = state),
    do: {:stop, {:shutdown, :idle_timeout}, state}

  def handle_info({:idle_timeout, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{owner_ref: ref} = state),
    do: {:stop, {:shutdown, :owner_down}, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case state.pending do
      %{caller_ref: ^ref} -> {:noreply, clear_pending(state)}
      _other -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # A pending collector gets its summary rather than waiting out its own
    # receive deadline (its monitor on this server is the crash-path backstop).
    _finished = finish_pending_now(state)
    kill_tree(state.os_pid)
    close_port(state.port)
    :ok
  end

  # -- collect ---------------------------------------------------------------

  defp begin_collect(state, caller, ref, yield_ms, max_bytes) do
    pending = %{
      caller: caller,
      ref: ref,
      caller_ref: Process.monitor(caller),
      timer: Process.send_after(self(), {:yield_done, ref}, yield_ms),
      remaining: max_bytes,
      truncated: false,
      dropped: 0
    }

    flush_pending(%{state | pending: pending})
  end

  # Stream buffered bytes to the pending caller; finish early at max_bytes or
  # when the shell has already exited and everything buffered was delivered.
  defp flush_pending(%__MODULE__{pending: nil} = state), do: state

  defp flush_pending(%__MODULE__{pending: pending, buffer: buffer} = state) do
    case Buffer.size(buffer) do
      0 -> maybe_finish_exited(state)
      _bytes -> deliver_chunk(state, pending, buffer)
    end
  end

  defp deliver_chunk(state, pending, buffer) do
    # The buffer is non-empty here (flush_pending dispatches on size), so
    # take/2 always yields a non-empty chunk.
    {chunk, buffer} = Buffer.take(buffer, pending.remaining)
    dropped = pending.dropped + Buffer.dropped(state.buffer)
    send_chunk(pending, chunk)

    # Buffer.take may overrun a 1-3 byte budget to keep a leading multibyte
    # character whole, so clamp at 0 rather than letting `remaining` go
    # negative (a negative budget would crash the next take).
    remaining = max(pending.remaining - byte_size(chunk), 0)
    pending = %{pending | remaining: remaining, dropped: dropped}
    state = %{state | buffer: buffer, pending: pending}

    case remaining do
      0 -> finish_pending_now(%{state | pending: %{pending | truncated: more?(buffer)}})
      _room -> maybe_finish_exited(state)
    end
  end

  defp send_chunk(pending, chunk), do: send(pending.caller, {pending.ref, {:chunk, chunk}})

  defp more?(buffer), do: Buffer.size(buffer) > 0

  defp maybe_finish_exited(%__MODULE__{port: nil} = state), do: finish_pending_now(state)
  defp maybe_finish_exited(state), do: state

  defp finish_pending_now(%__MODULE__{pending: nil} = state), do: state

  defp finish_pending_now(%__MODULE__{pending: pending} = state) do
    summary = %{
      exit_status: state.exit_status,
      alive: state.port != nil,
      truncated: pending.truncated,
      dropped_bytes: pending.dropped
    }

    send(pending.caller, {pending.ref, {:done, summary}})
    clear_pending(state)
  end

  defp clear_pending(%__MODULE__{pending: pending} = state) do
    Process.demonitor(pending.caller_ref, [:flush])
    Process.cancel_timer(pending.timer)
    %{state | pending: nil}
  end

  defp non_reply(caller, ref, message, state) do
    send(caller, {ref, message})
    {:noreply, state}
  end

  # -- lifecycle plumbing ----------------------------------------------------

  defp monitor_owner(opts) do
    case Keyword.fetch(opts, :owner_pid) do
      {:ok, pid} when is_pid(pid) -> Process.monitor(pid)
      :error -> monitor_session(Keyword.get(opts, :owner))
    end
  end

  defp monitor_session(nil), do: nil

  defp monitor_session(session_id) do
    case Catalyst.Session.Manager.whereis(session_id) do
      {:ok, pid} -> Process.monitor(pid)
      :error -> nil
    end
  end

  defp arm_idle(state) do
    case state.idle_ref do
      nil -> :ok
      {_token, timer} -> Process.cancel_timer(timer)
    end

    token = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, token}, idle_ms())
    %{state | idle_ref: {token, timer}}
  end

  defp idle_ms, do: Application.get_env(:catalyst, :shell_session_idle_ms, @default_idle_ms)

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _closed -> nil
    end
  end

  # `script`'s direct child is the shell, made a session leader on the PTY
  # slave — `kill -KILL -<pid>` takes its whole (foreground) process group.
  # Then kill `script` itself; closing the master additionally HUPs whatever
  # remains attached to the slave.
  defp kill_tree(nil), do: :ok

  defp kill_tree(os_pid) do
    os_pid |> os_children() |> Enum.each(&kill_group/1)
    _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp os_children(os_pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> Enum.flat_map(&parse_pid/1)
      _none -> []
    end
  end

  defp parse_pid(str) do
    case Integer.parse(str) do
      {pid, ""} -> [pid]
      _invalid -> []
    end
  end

  defp kill_group(pid) do
    case System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      _no_group -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    _already_closed -> :ok
  end
end
