defmodule Catalyst.Tools.Computer.Helper do
  @moduledoc """
  Supervised owner of the `catalyst-input` helper `Port` (plan §3).

  The helper is a long-lived native process speaking newline-delimited JSON on
  stdin/stdout (`Catalyst.Tools.Computer.Protocol`) — and it executes strictly
  serially. This GenServer is therefore **write-when-idle**: at most ONE op is
  ever in flight at the native helper; further requests queue server-side in a
  bounded FIFO and are written only when the in-flight response arrives. (The
  alternative — writing every submitted op to stdin immediately — lets a 25s
  `hold_key` starve queued callers past their own call timeouts and then fire
  their input physically much later, as ghost events.)

  The mailbox itself never blocks: the in-flight caller is parked
  (`{:noreply, …}`) and `:DOWN` / port exits are serviced immediately, which is
  exactly when the release invariant below is needed.

  ## Lazy port, permanent process

  The process is supervised from boot but opens **no Port until first use** —
  opening the helper at app start would fire a TCC prompt for a capability
  nobody asked for. A dead helper reopens on the next call.

  ## Cancellation and the wedge deadline

  Every `call/2,3,4` carries a client tag; when the caller's `GenServer.call`
  times out, the client casts `{:cancel, tag}` so a still-queued op is removed
  and never reaches the helper (a timed-out queued op must not fire later as a
  ghost event). An already-in-flight op cannot be cancelled — it is inside its
  own timeout budget.

  Each in-flight op also gets a **server-side deadline** (duration +
  #{15_000}ms slack, deliberately beyond the client's call timeout). If it
  fires, the helper is wedged: the Port is closed, the in-flight caller and all
  queued waiters fail with `{:error, :computer_helper_wedged}`, the Port
  reopens lazily on the next call, and the held-state compensation below runs.
  Without this, a hung-but-alive helper would brick the server once the bound
  filled — every call `:computer_helper_busy` forever.

  ## Abort safety (the release invariant)

  Catalyst aborts by killing the run task; this server is deliberately not
  linked into that cascade. Held-state bookkeeping:

    * A `mouse_down` records its button and holder **when the request is
      written** to the helper, not when the response arrives — if the helper
      dies after posting the physical press but before replying, compensation
      still knows about the button. An error response un-records it.
    * Every tool call runs in its own short-lived task that exits `:normal` on
      completion, so a NORMAL holder exit keeps the button held — that is what
      makes the advertised `left_mouse_down` / `left_mouse_up` pairing across
      tool calls work. An ABNORMAL holder exit (abort/kill) posts the
      compensating `mouse_up`.
    * A bounded hold watchdog (`:hold_cap_ms`, default #{60_000}ms) releases a
      button whose `left_mouse_up` never came and logs a warning that it did —
      a held button never stays down indefinitely.
    * An abnormal holder death while that holder's own *input* op is still in
      flight kills the helper OS process mid-op — the single-threaded native
      loop would otherwise keep posting physical input for up to 30s — and
      runs the lost-helper compensation below; the port reopens lazily.
      In-flight and queued waiters fail `{:error, :computer_helper_aborted}`.

  When the helper process itself dies (or is killed as wedged) the replacement
  has no memory of the old one's state, so after reopening the Helper posts
  the tracked explicit mouse-ups **and** a `release_all` sweep — the native op
  unconditionally posts mouse-up for all three buttons and releases all five
  modifiers at the current cursor, precisely because a fresh helper cannot
  know what a dead one latched. The sweep runs whenever any *input* op was in
  flight at death, not only when tracked held-state is non-empty, because a
  death mid-`drag`/mid-`hold_key` latches state no response ever reported.
  Best-effort caveat: the key held inside an in-flight `hold_key` stays
  physically down between the death and the reopen.
  `release_all/1` remains available as the explicit big hammer.

  ## Serialization and bounds

  There is one physical pointer, so ops serialise FIFO across all sessions
  through this single process — a global input lock. In-flight + queued ops are
  bounded (`:max_pending`, default #{32}); past the bound calls get
  `{:error, :computer_helper_busy}` instead of queueing unboundedly.

  ## Timeouts

  `duration_ms` args are capped at 30s and the `GenServer.call` timeout is
  derived per-op as `duration + slack` — a long `hold_key` neither crashes the
  caller on the default 5s timeout nor holds the key forever.

  Expected failures are tagged: `{:error, :helper_missing}`,
  `{:error, :computer_helper_busy}`, `{:error, :computer_helper_timeout}`,
  `{:error, :computer_helper_wedged}`, `{:error, :computer_helper_aborted}`,
  `{:error, {:helper_exited, reason}}`, `{:error, message}` (helper-reported).
  """

  use GenServer

  require Logger

  alias Catalyst.Tools.Computer.{Availability, Protocol}

  @max_duration_ms 30_000
  @call_slack_ms 10_000
  @wedge_slack_ms 15_000
  @default_max_pending 32

  # A held button whose paired mouse_up never arrives is force-released after
  # this cap: long enough for a down → screenshot → model turn → up cycle,
  # bounded so an abandoned hold cannot pin the button forever.
  @hold_cap_ms 60_000

  # Ops that post physical input and can therefore leave buttons/modifiers
  # latched when the helper dies mid-op. Observation ops (screens, windows,
  # cursor, trusted, …) cannot.
  @input_ops ~w(mouse_move mouse_down mouse_up click drag scroll type key hold_key release_all)

  @typedoc "A helper response: the decoded result map or a tagged error."
  @type response :: {:ok, map()} | {:error, term()}

  # ---- API ------------------------------------------------------------------

  @doc """
  Start the helper owner. Options: `:name` (default `#{inspect(__MODULE__)}`,
  `nil` for an unnamed test instance), `:helper_path` (override the resolved
  binary path), `:helper_args` (extra argv), `:max_pending` (queue bound),
  `:wedge_slack_ms` (server-side in-flight deadline slack; test override),
  `:hold_cap_ms` (watchdog cap on an unpaired mouse-button hold; test
  override).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Issue one helper op and await its response. `args` uses the wire arg names
  (`"coordinate"`, `"button"`, …). Durations are capped at #{@max_duration_ms}ms
  and the call timeout is derived from them (`opts[:timeout]` overrides). On a
  call timeout the op is cancelled server-side if it is still queued, so it can
  never fire later as a ghost event.

  Explicit clauses instead of two leading defaults: `call(op, args)` must mean
  "op + args on the named server", never "op as the server name".
  """
  @spec call(String.t()) :: response()
  def call(op) when is_binary(op), do: do_call(__MODULE__, op, %{}, [])

  @spec call(String.t(), map()) :: response()
  def call(op, args) when is_binary(op) and is_map(args), do: do_call(__MODULE__, op, args, [])

  @spec call(GenServer.server(), String.t()) :: response()
  def call(server, op) when is_binary(op) and not is_binary(server),
    do: do_call(server, op, %{}, [])

  @spec call(GenServer.server(), String.t(), map()) :: response()
  def call(server, op, args) when is_binary(op) and is_map(args),
    do: do_call(server, op, args, [])

  @spec call(GenServer.server(), String.t(), map(), keyword()) :: response()
  def call(server, op, args, opts) when is_binary(op) and is_map(args) and is_list(opts),
    do: do_call(server, op, args, opts)

  defp do_call(server, op, args, opts) do
    args = cap_durations(args)
    tag = make_ref()
    timeout = Keyword.get(opts, :timeout, call_timeout(args))

    try do
      GenServer.call(server, {:request, op, args, tag}, timeout)
    catch
      :exit, {:timeout, _call} ->
        # ToolRunner catches exits, so the caller stays alive — :DOWN never
        # fires for a mere timeout. Cancel explicitly so a still-queued op is
        # reaped instead of firing later as ghost input.
        GenServer.cast(server, {:cancel, tag})
        {:error, :computer_helper_timeout}

      :exit, {:noproc, _call} ->
        {:error, :computer_helper_unavailable}
    end
  end

  @doc "Release every held button and modifier (explicit compensation)."
  @spec release_all(GenServer.server()) :: response()
  def release_all(server \\ __MODULE__), do: call(server, "release_all", %{})

  @doc """
  Liveness/introspection snapshot: whether the Port is currently open, how many
  ops are pending (in flight + queued), and which buttons are held. Never opens
  the Port.
  """
  @spec status(GenServer.server()) ::
          %{port: :open | :closed, pending: non_neg_integer(), held: [String.t()]}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> %{port: :closed, pending: 0, held: []}
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       port: nil,
       buffer: "",
       next_id: 1,
       inflight: nil,
       queue: :queue.new(),
       queued: 0,
       internal: %{},
       held: %{},
       monitors: %{},
       helper_path: Keyword.get(opts, :helper_path),
       helper_args: Keyword.get(opts, :helper_args, []),
       max_pending: Keyword.get(opts, :max_pending, @default_max_pending),
       wedge_slack_ms: Keyword.get(opts, :wedge_slack_ms, @wedge_slack_ms),
       hold_cap_ms: Keyword.get(opts, :hold_cap_ms, @hold_cap_ms)
     }}
  end

  @impl true
  def handle_call({:request, op, args, tag}, {caller, _tag} = from, state) do
    entry = %{from: from, caller: caller, op: op, args: args, tag: tag, orphaned: false}

    cond do
      pending_count(state) >= state.max_pending ->
        {:reply, {:error, :computer_helper_busy}, state}

      state.inflight != nil ->
        {:noreply, enqueue(entry, state)}

      true ->
        case ensure_port(state) do
          {:ok, state} -> submit(entry, state)
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:status, _from, state) do
    snapshot = %{
      port: port_state(state.port),
      pending: pending_count(state),
      held: state.held |> Map.keys() |> Enum.sort()
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_cast({:cancel, tag}, state) do
    # An in-flight op cannot be cancelled (it is already at the helper); its
    # eventual reply is late-dropped by the caller. A queued op is removed so
    # it never reaches the helper.
    case state.inflight do
      %{tag: ^tag} -> {:noreply, state}
      _other -> {:noreply, drop_queued(&(&1.tag == tag), state)}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> chunk)
    state = Enum.reduce(lines, %{state | buffer: buffer}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, helper_lost({:error, {:helper_exited, {:exit_status, status}}}, state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:noreply, helper_lost({:error, {:helper_exited, reason}}, state)}
  end

  def handle_info({:inflight_deadline, id}, %{inflight: %{id: id}} = state) do
    # The client's own call timeout fired long ago (the deadline sits beyond
    # it); the helper is wedged — kill it, fail everyone, compensate. A mere
    # Port.close would leave a helper stuck inside a blocking native op alive
    # and still posting input until it next touches the dead pipe.
    kill_port(state.port)
    {:noreply, helper_lost({:error, :computer_helper_wedged}, state)}
  end

  def handle_info({:inflight_deadline, _stale_id}, state), do: {:noreply, state}

  # A tool-call task that finished normally: keep its held button — the paired
  # left_mouse_up arrives as a LATER tool call from a different task. Only the
  # monitor is dropped; the hold watchdog bounds an up that never comes.
  def handle_info({:DOWN, _ref, :process, pid, :normal}, state) do
    {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _abnormal_reason}, state) do
    {:noreply, caller_down(pid, state)}
  end

  def handle_info({:hold_deadline, button, token}, state) do
    case state.held do
      %{^button => %{token: ^token}} ->
        Logger.warning(
          "computer helper: #{button} mouse button held past the " <>
            "#{state.hold_cap_ms}ms cap without a paired mouse_up; releasing it"
        )

        {:noreply, force_release(button, state)}

      _released_or_superseded ->
        {:noreply, state}
    end
  end

  # Stale messages from an already-replaced port (both exit shapes can arrive).
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    release_held_best_effort(state)
    :ok
  end

  # ---- request path ---------------------------------------------------------

  defp pending_count(state) do
    case state.inflight do
      nil -> state.queued
      _entry -> state.queued + 1
    end
  end

  defp enqueue(entry, state) do
    state = ensure_monitor(entry.caller, state)
    %{state | queue: :queue.in(entry, state.queue), queued: state.queued + 1}
  end

  # Write the entry to the (open) port and park it as the single in-flight op.
  # The wire id is assigned at write time, so ids stay monotonic in write order.
  defp submit(entry, state) do
    id = state.next_id

    case send_line(state.port, Protocol.encode(id, entry.op, entry.args)) do
      :ok ->
        state = entry |> track_written(state) |> then(&ensure_monitor(entry.caller, &1))
        deadline = schedule_deadline(id, entry.args, state)
        inflight = entry |> Map.put(:id, id) |> Map.put(:deadline, deadline)
        {:noreply, %{state | next_id: id + 1, inflight: inflight}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Dequeue-and-write once the in-flight slot is free, skipping entries whose
  # caller has died (cancelled entries were already removed by the cast).
  defp pump_queue(%{inflight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, entry}, rest} ->
        state = %{state | queue: rest, queued: state.queued - 1}

        case Process.alive?(entry.caller) do
          false -> state |> maybe_demonitor(entry.caller) |> pump_queue()
          true -> write_queued(entry, state)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp pump_queue(state), do: state

  defp write_queued(entry, state) do
    case submit(entry, state) do
      {:noreply, state} ->
        state

      {:reply, error, state} ->
        GenServer.reply(entry.from, error)
        state |> maybe_demonitor(entry.caller) |> pump_queue()
    end
  end

  defp send_line(port, line) do
    Port.command(port, [line, "\n"])
    :ok
  rescue
    ArgumentError -> {:error, :helper_write_failed}
  end

  # Internal ops (compensating releases) are written immediately — they must
  # jump ahead of queued client ops, and the native helper serialises anyway —
  # and consume their response silently via the `internal` id set.
  defp post_internal(op, args, %{port: port} = state) when is_port(port) do
    id = state.next_id

    case send_line(port, Protocol.encode(id, op, args)) do
      :ok -> %{state | next_id: id + 1, internal: Map.put(state.internal, id, op)}
      {:error, _reason} -> state
    end
  end

  defp post_internal(_op, _args, state), do: state

  # ---- response path --------------------------------------------------------

  defp handle_line(line, state) do
    case Protocol.decode_response(line) do
      {:ok, id, response} -> resolve(id, response, state)
      {:error, _invalid} -> state
    end
  end

  defp resolve(id, response, %{inflight: %{id: id} = entry} = state) do
    cancel_deadline(entry.deadline)
    state = %{state | inflight: nil}
    state = track_held(entry, response, state)
    GenServer.reply(entry.from, response)
    state |> maybe_demonitor(entry.caller) |> pump_queue()
  end

  defp resolve(id, _response, state) when is_map_key(state.internal, id),
    do: %{state | internal: Map.delete(state.internal, id)}

  # Late reply for an op whose owner is gone (wedge/port churn): drop it.
  defp resolve(_id, _response, state), do: state

  # A mouse_down is the one op that leaves physical state behind, and the
  # press is posted BEFORE the helper replies — so the hold is recorded when
  # the request is WRITTEN (track_written), not when the response arrives.
  # A helper that dies mid-op then still has a hold to compensate.
  defp track_written(%{op: "mouse_down"} = entry, state),
    do: hold_button(held_button(entry.args), entry.caller, state)

  defp track_written(_entry, state), do: state

  # On the mouse_down response the hold is already recorded; a holder that died
  # (or timed out and returned) before the response gets the compensating up
  # immediately. An errored mouse_down never posted a press: un-record it.
  defp track_held(%{op: "mouse_down"} = entry, {:ok, _result}, state) do
    case entry.orphaned or not Process.alive?(entry.caller) do
      true -> force_release(held_button(entry.args), state)
      false -> state
    end
  end

  defp track_held(%{op: "mouse_down"} = entry, {:error, _reason}, state),
    do: release_button(held_button(entry.args), state)

  defp track_held(%{op: "mouse_up"} = entry, {:ok, _result}, state),
    do: release_button(held_button(entry.args), state)

  defp track_held(%{op: "release_all"}, {:ok, _result}, state), do: release_all_held(state)

  defp track_held(_entry, _response, state), do: state

  defp held_button(args), do: args |> Map.get("button", "left") |> String.downcase()

  # ---- held-state bookkeeping ----------------------------------------------

  # Record a hold and arm its watchdog. The token distinguishes this hold from
  # a later re-press of the same button, so a stale deadline message that
  # raced its cancellation cannot release the new hold.
  defp hold_button(button, holder, state) do
    state = release_button(button, state)
    token = make_ref()
    timer = Process.send_after(self(), {:hold_deadline, button, token}, state.hold_cap_ms)
    %{state | held: Map.put(state.held, button, %{holder: holder, timer: timer, token: token})}
  end

  # Drop the record and disarm the watchdog (the physical up was, or is being,
  # posted elsewhere — or never needs to be).
  defp release_button(button, state) do
    case Map.pop(state.held, button) do
      {nil, _held} ->
        state

      {%{timer: timer}, held} ->
        cancel_deadline(timer)
        %{state | held: held}
    end
  end

  defp release_all_held(state) do
    Enum.each(state.held, fn {_button, %{timer: timer}} -> cancel_deadline(timer) end)
    %{state | held: %{}}
  end

  # Un-record the hold AND post the compensating physical up.
  defp force_release(button, state) do
    button
    |> release_button(state)
    |> then(&post_internal("mouse_up", %{"button" => button}, &1))
  end

  # ---- caller death ---------------------------------------------------------

  # An ABNORMAL caller death is an abort: release everything the dead caller
  # left behind. When the dead caller's own *input* op is still in flight the
  # single-threaded native helper is inside a blocking loop, still posting
  # physical input — kill it mid-op and run the lost-helper compensation
  # (explicit ups + release_all sweep through a fresh helper); it reopens
  # lazily. Otherwise release the dead caller's held buttons in place.
  defp caller_down(pid, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}

    case input_inflight_from?(pid, state) do
      true ->
        kill_port(state.port)
        helper_lost({:error, :computer_helper_aborted}, state)

      false ->
        state
        |> release_stale_holds(pid)
        |> orphan_inflight(pid)
        |> drop_queued_from(pid)
    end
  end

  defp input_inflight_from?(pid, state),
    do: match?(%{caller: ^pid, op: op} when op in @input_ops, state.inflight)

  defp release_stale_holds(state, pid) do
    state.held
    |> Enum.filter(fn {_button, %{holder: holder}} -> holder == pid end)
    |> Enum.reduce(state, fn {button, _hold}, state -> force_release(button, state) end)
  end

  # An in-flight request from a dead caller still completes in the helper; its
  # mouse_down response must be compensated when it arrives (track_held).
  defp orphan_inflight(%{inflight: %{caller: pid} = entry} = state, pid),
    do: %{state | inflight: %{entry | orphaned: true}}

  defp orphan_inflight(state, _pid), do: state

  defp drop_queued_from(state, pid), do: drop_queued(&(&1.caller == pid), state)

  # Remove matching queued entries without replying (their callers are dead or
  # already returned with a timeout error).
  defp drop_queued(match?, state) do
    {dropped, kept} = state.queue |> :queue.to_list() |> Enum.split_with(match?)

    state = %{state | queue: :queue.from_list(kept), queued: length(kept)}
    Enum.reduce(dropped, state, fn entry, state -> maybe_demonitor(state, entry.caller) end)
  end

  defp ensure_monitor(caller, state) do
    case Map.has_key?(state.monitors, caller) do
      true -> state
      false -> %{state | monitors: Map.put(state.monitors, caller, Process.monitor(caller))}
    end
  end

  # Drop the monitor once the caller neither waits on a request nor holds input.
  defp maybe_demonitor(state, caller) do
    still_referenced? =
      match?(%{caller: ^caller}, state.inflight) or
        Enum.any?(:queue.to_list(state.queue), &(&1.caller == caller)) or
        Enum.any?(state.held, fn {_button, %{holder: holder}} -> holder == caller end)

    case {still_referenced?, Map.pop(state.monitors, caller)} do
      {false, {ref, monitors}} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: monitors}

      _keep ->
        state
    end
  end

  # ---- port lifecycle -------------------------------------------------------

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    path = state.helper_path || Availability.helper_path()

    case File.regular?(path) do
      false -> {:error, :helper_missing}
      true -> open_port(path, state)
    end
  end

  defp open_port(path, state) do
    port =
      Port.open(
        {:spawn_executable, path},
        [:binary, :exit_status, :use_stdio, :hide, {:args, state.helper_args}]
      )

    {:ok, %{state | port: port}}
  rescue
    error -> {:error, {:helper_open_failed, Exception.message(error)}}
  end

  # The helper is gone (died, or closed as wedged). Fail the in-flight caller
  # and every queued waiter with the tagged error, then compensate latched
  # physical input through a fresh helper.
  defp helper_lost(error, state) do
    input_lost? = input_op_lost?(state)

    case state.inflight do
      nil ->
        :ok

      entry ->
        cancel_deadline(entry.deadline)
        GenServer.reply(entry.from, error)
    end

    state.queue
    |> :queue.to_list()
    |> Enum.each(fn entry -> GenServer.reply(entry.from, error) end)

    Enum.each(state.monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)

    state = %{
      state
      | port: nil,
        buffer: "",
        inflight: nil,
        queue: :queue.new(),
        queued: 0,
        internal: %{},
        monitors: %{}
    }

    compensate_lost_input(state, input_lost?)
  end

  defp input_op_lost?(state) do
    inflight_input? =
      case state.inflight do
        %{op: op} -> op in @input_ops
        nil -> false
      end

    inflight_input? or Enum.any?(state.internal, fn {_id, op} -> op in @input_ops end)
  end

  # Nothing was latched and nothing input-shaped was in flight: stay lazily
  # closed. Otherwise reopen and post the tracked explicit mouse-ups plus a
  # release_all sweep — the fresh helper has no memory of the old one's state,
  # and a death mid-drag/mid-hold_key latches state no response ever reported.
  defp compensate_lost_input(%{held: held} = state, false) when map_size(held) == 0, do: state

  defp compensate_lost_input(state, _input_lost?) do
    case ensure_port(state) do
      {:ok, state} ->
        buttons = Map.keys(state.held)

        buttons
        |> Enum.reduce(release_all_held(state), fn button, state ->
          post_internal("mouse_up", %{"button" => button}, state)
        end)
        |> then(&post_internal("release_all", %{}, &1))

      {:error, _reason} ->
        # Nothing can post the release; drop the record rather than retrying
        # forever against a missing binary.
        release_all_held(state)
    end
  end

  # Best-effort synchronous release on shutdown: write the ups + sweep, close.
  defp release_held_best_effort(%{port: port} = state) when is_port(port) do
    case map_size(state.held) > 0 or input_op_lost?(state) do
      true ->
        Enum.each(Map.keys(state.held), fn button ->
          send_line(port, Protocol.encode(0, "mouse_up", %{"button" => button}))
        end)

        send_line(port, Protocol.encode(0, "release_all", %{}))

        # Give the single-threaded helper a beat to drain stdin before the close.
        receive do
        after
          50 -> :ok
        end

        close_port(port)

      false ->
        close_port(port)
    end
  end

  defp release_held_best_effort(_state), do: :ok

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Terminate the helper OS process mid-op, then close the Port. Closing alone
  # only delivers EOF/SIGPIPE the next time the helper touches the pipe — a
  # helper inside a blocking input loop (drag interpolation, hold_key sleep)
  # would keep posting physical input until then. SIGKILL stops it now.
  defp kill_port(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
      nil -> :ok
    end

    close_port(port)
  end

  defp kill_port(_not_open), do: :ok

  defp port_state(port) when is_port(port), do: :open
  defp port_state(_closed), do: :closed

  # ---- wedge deadline -------------------------------------------------------

  defp schedule_deadline(id, args, state) do
    Process.send_after(self(), {:inflight_deadline, id}, op_duration(args) + state.wedge_slack_ms)
  end

  defp cancel_deadline(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_deadline(_none), do: :ok

  defp op_duration(args) do
    case Map.get(args, "duration_ms") do
      ms when is_integer(ms) and ms > 0 -> ms
      _absent_or_invalid -> 0
    end
  end

  # ---- line framing ---------------------------------------------------------

  # Responses are newline-delimited; a Port read may split a line. Keep the
  # trailing partial in the buffer.
  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  # ---- timeout budget -------------------------------------------------------

  defp cap_durations(args) do
    case Map.fetch(args, "duration_ms") do
      {:ok, ms} when is_integer(ms) -> Map.put(args, "duration_ms", clamp(ms))
      _absent_or_invalid -> args
    end
  end

  defp clamp(ms), do: ms |> max(0) |> min(@max_duration_ms)

  defp call_timeout(args) do
    case Map.get(args, "duration_ms") do
      ms when is_integer(ms) and ms > 0 -> ms + @call_slack_ms
      _none -> @call_slack_ms
    end
  end
end
