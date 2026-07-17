defmodule Catalyst.Hooks do
  @moduledoc """
  Runtime registry of agent-loop hooks — the seam that lets extensions intercept
  and modify the loop's behavior without forking it (Catalyst's analog of PI's
  `beforeToolCall`/`afterToolCall`/`prepareNextTurn`/`shouldStopAfterTurn`/
  `transformContext` callbacks).

  Hook points:

    * `:transform_context`      — filter/edit messages before each LLM call (filter,
      `(messages, ctx) -> {:ok, messages}`)
    * `:before_tool_call`       — inspect/block a tool call (decision,
      `(ctx) -> {:block, reason} | :cont`)
    * `:after_tool_call`        — rewrite a tool result (filter,
      `({content, details, is_error, terminate}, ctx) -> {:ok, tuple}`)
    * `:prepare_next_turn`      — swap context/model before the next turn (filter,
      `({context, config}, ctx) -> {:ok, {context, config}}`)
    * `:should_stop_after_turn` — force the loop to stop (decision, `(ctx) -> true | :cont`)

  Plus a fire-and-forget observer channel (`on/2` + `notify/2`) for every
  `Catalyst.Agent.Event`. Event observers are dispatched asynchronously in a
  bounded per-session queue; they cannot delay token streaming or other loop
  work. Decision and filter hooks remain synchronous because their return
  values control the current run.

  Handlers are stored in an ETS bag (like `Catalyst.Extensions`), tagged with an
  `owner` so a reloaded extension can revoke its prior handlers (`unregister/1`).
  The table is owned by `Catalyst.Hooks.TableOwner`, not by this server, so a
  crash here cannot destroy the registered handlers (which nothing would
  re-register — `before_tool_call` gates would silently fail open). The hot path
  (`run_filter/3`, `run_decision/2`, `notify/2`) reads ETS directly. **Every
  handler runs in an isolated supervised process under a deadline
  (`:hook_handler_timeout`, default 10s): a crashing, throwing, or hanging hook
  is logged and skipped — it can never take down or wedge a run.** Synchronous
  decision/filter hooks use awaitable tasks. Observer callbacks use a single
  dispatcher-managed task each, with no nested per-event task. Observer
  admission is capped by `:hook_observer_queue_limit` (default 256 accepted
  events per session); overload drops stream updates but preserves structural
  lifecycle events.
  """

  use GenServer
  require Logger

  alias Catalyst.Hooks.ObserverDispatcher
  alias Catalyst.Tasks

  @table :catalyst_hooks
  @handler_timeout_ms 10_000
  @points [
    :transform_context,
    :before_tool_call,
    :after_tool_call,
    :prepare_next_turn,
    :should_stop_after_turn,
    :event
  ]

  @type point :: atom()
  @type handler_entry :: %{
          point: point(),
          id: term(),
          owner: term(),
          priority: integer(),
          seq: non_neg_integer(),
          fun: function()
        }

  @doc "The known hook points."
  @spec points() :: [point()]
  def points, do: @points

  # ---- API ------------------------------------------------------------------

  @doc "Start the singleton hook registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Register a hook handler at `point`. `fun`'s arity depends on the point (see the
  moduledoc). `opts`: `:owner` (for `unregister/1`), `:id` (display), `:priority`
  (lower runs first, default 100).
  """
  @spec register(point(), function(), keyword()) :: :ok
  def register(point, fun, opts \\ []) when is_atom(point) and is_function(fun) do
    GenServer.call(__MODULE__, {:register, point, fun, opts})
  end

  @doc "Register an event observer (`fun.(event) -> any`) for every agent event."
  @spec on((term() -> term()), keyword()) :: :ok
  def on(fun, opts \\ []) when is_function(fun, 1), do: register(:event, fun, opts)

  @doc "Remove every handler registered by `owner` across all points."
  @spec unregister(term()) :: :ok
  def unregister(owner), do: GenServer.call(__MODULE__, {:unregister, owner})

  @doc "Drop all handlers (test helper)."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "Handlers registered at `point`, ordered by priority then registration order."
  @spec handlers(point()) :: [handler_entry()]
  def handlers(point) do
    @table
    |> :ets.lookup(point)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&{&1.priority, &1.seq})
  rescue
    ArgumentError -> []
  end

  # ---- hot path (ETS reads only) --------------------------------------------

  @doc """
  Fold `value` through every handler at `point` (handler: `(value, ctx) -> {:ok, new} | _`).

  `valid?` guards the documented isolation promise: a handler returning
  `{:ok, value}` of the wrong SHAPE (e.g. `{:ok, :done}` where a 4-tuple is
  expected) is logged and skipped instead of poisoning the fold and crashing
  the run when the caller destructures the result.
  """
  @spec run_filter(point(), term(), term(), (term() -> boolean())) :: term()
  def run_filter(point, value, ctx, valid? \\ fn _ -> true end) do
    Enum.reduce(handlers(point), value, fn entry, acc ->
      case safe(entry, fn -> entry.fun.(acc, ctx) end) do
        {:hook_ok, {:ok, new}} ->
          case valid?.(new) do
            true ->
              new

            false ->
              Logger.warning(
                "[hooks] #{entry.point}/#{entry.id} returned a malformed value — skipped"
              )

              acc
          end

        _ ->
          acc
      end
    end)
  end

  @doc "First non-abstaining decision from a handler at `point`, else `:none` (handler: `(ctx) -> decision | :cont`)."
  @spec run_decision(point(), term()) :: term() | :none
  def run_decision(point, ctx) do
    Enum.reduce_while(handlers(point), :none, fn entry, _ ->
      case safe(entry, fn -> entry.fun.(ctx) end) do
        {:hook_ok, decision} when decision not in [:cont, nil, :none] -> {:halt, decision}
        _ -> {:cont, :none}
      end
    end)
  end

  # Convenience wrappers used by Catalyst.Agent.Loop / ToolRunner.

  @doc "Synchronously fold the request message list through context-transform hooks."
  @spec transform_context([term()], term()) :: [term()]
  def transform_context(messages, ctx),
    do: run_filter(:transform_context, messages, ctx, &is_list/1)

  @doc "Synchronously ask tool-call gates for the first blocking decision."
  @spec before_tool_call(term()) :: term() | :none
  def before_tool_call(ctx), do: run_decision(:before_tool_call, ctx)

  @doc "Synchronously fold a tool result through result-transform hooks."
  @spec after_tool_call({term(), term(), boolean(), boolean()}, term()) ::
          {term(), term(), boolean(), boolean()}
  def after_tool_call(result_tuple, ctx),
    do: run_filter(:after_tool_call, result_tuple, ctx, &valid_tool_result?/1)

  @doc "Synchronously fold context/config through next-turn preparation hooks."
  @spec prepare_next_turn(map(), map(), term()) :: {map(), map()}
  def prepare_next_turn(context, config, ctx),
    do: run_filter(:prepare_next_turn, {context, config}, ctx, &match?({%{}, %{}}, &1))

  @doc "Whether a synchronous stop hook requests termination after this turn."
  @spec should_stop?(term()) :: boolean()
  def should_stop?(ctx), do: run_decision(:should_stop_after_turn, ctx) == true

  defp valid_tool_result?({_content, _details, error?, terminate?}),
    do: is_boolean(error?) and is_boolean(terminate?)

  defp valid_tool_result?(_result), do: false

  @doc """
  Queue an event for asynchronous observer delivery under `session_key`.

  Returns promptly after bounded admission. When that session already has the
  configured maximum accepted work, stream updates return
  `{:dropped, :queue_full}`. Structural events replace an older queued update
  or wait for capacity, preserving lifecycle completion. Omitting the key
  groups events by the calling process, which preserves ordering for direct
  loop/test callers.
  """
  @spec notify(term()) :: ObserverDispatcher.enqueue_result()
  def notify(event), do: notify(event, self())

  @doc "Queue an event under an explicit session key; see `notify/1`."
  @spec notify(term(), term()) :: ObserverDispatcher.enqueue_result()
  def notify(event, session_key) do
    ObserverDispatcher.enqueue(session_key || self(), event, handlers(:event))
  end

  @doc "Wait until every accepted observer event for `session_key` is complete."
  @spec await_observers(term(), timeout()) :: :ok
  def await_observers(session_key \\ self(), timeout \\ 5_000) do
    ObserverDispatcher.await_idle(session_key, timeout)
  end

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    # The table is normally created (and owned) by Catalyst.Hooks.TableOwner,
    # started just before this server, so handlers survive a crash here.
    # Creating it ourselves is a fallback for tests that start Hooks standalone.
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
      _table -> :ok
    end

    # Resume the seq counter past any surviving entries, or a restart would
    # hand out duplicate seqs and scramble the documented "priority then
    # registration order" tie-break.
    next_seq =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_point, entry} -> entry.seq end)
      |> Enum.max(fn -> -1 end)
      |> Kernel.+(1)

    {:ok, %{seq: next_seq}}
  end

  @impl true
  def handle_call({:register, point, fun, opts}, _from, %{seq: seq} = state) do
    entry = %{
      point: point,
      id: Keyword.get(opts, :id, "h#{seq}"),
      owner: Keyword.get(opts, :owner),
      priority: Keyword.get(opts, :priority, 100),
      seq: seq,
      fun: fun
    }

    :ets.insert(@table, {point, entry})
    {:reply, :ok, %{state | seq: seq + 1}}
  end

  def handle_call({:unregister, owner}, _from, state) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {_point, entry} = obj ->
      case entry.owner == owner do
        true -> :ets.delete_object(@table, obj)
        false -> :ok
      end
    end)

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ---- internals ------------------------------------------------------------

  # Run an extension-authored handler isolated AND bounded. A try/rescue alone
  # cannot honor the moduledoc's promise: a handler that merely blocks (infinite
  # loop, receive that never matches) would hang the agent loop at this hook
  # point — and a hanging :before_tool_call also blocks the rollback/reload
  # tools that could remove it. Handlers were already the only extension-code
  # path without a deadline (compile and setup have one). The task copies the
  # closed-over value/ctx; that cost is only paid when handlers are registered.
  defp safe(entry, thunk) do
    task = Tasks.async(thunk)

    case Tasks.await(task, handler_timeout()) do
      {:ok, value} ->
        {:hook_ok, value}

      {:exit, {exception, _stack}} when is_exception(exception) ->
        Logger.warning(
          "[hooks] #{entry.point}/#{entry.id} raised: #{Exception.message(exception)}"
        )

        :hook_skip

      {:exit, reason} ->
        Logger.warning("[hooks] #{entry.point}/#{entry.id} exited: #{inspect(reason)}")
        :hook_skip

      :timeout ->
        Logger.warning(
          "[hooks] #{entry.point}/#{entry.id} timed out after #{handler_timeout()}ms — " <>
            "killed and skipped"
        )

        :hook_skip
    end
  end

  defp handler_timeout,
    do: Application.get_env(:catalyst, :hook_handler_timeout, @handler_timeout_ms)
end
