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

  Plus a fire-and-forget observer channel (`on/3` + `notify/1`) for every
  `Catalyst.Agent.Event`.

  Handlers are stored in an ETS bag (like `Catalyst.Extensions`), tagged with an
  `owner` so a reloaded extension can revoke its prior handlers (`unregister/1`).
  The hot path (`run_filter/3`, `run_decision/2`, `notify/1`) reads ETS directly
  and never calls the GenServer, so it works even if this process is down (an
  absent table just yields no handlers). **Every handler runs inside a
  try/rescue/catch: a crashing or misbehaving hook is logged and skipped — it can
  never take down a run.**
  """

  use GenServer
  require Logger

  @table :catalyst_hooks
  @points [
    :transform_context,
    :before_tool_call,
    :after_tool_call,
    :prepare_next_turn,
    :should_stop_after_turn,
    :event
  ]

  @doc "The known hook points."
  def points, do: @points

  # ---- API ------------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Register a hook handler at `point`. `fun`'s arity depends on the point (see the
  moduledoc). `opts`: `:owner` (for `unregister/1`), `:id` (display), `:priority`
  (lower runs first, default 100).
  """
  def register(point, fun, opts \\ []) when is_atom(point) and is_function(fun) do
    GenServer.call(__MODULE__, {:register, point, fun, opts})
  end

  @doc "Register an event observer (`fun.(event) -> any`). `:any` or omit to see all events."
  def on(fun, opts \\ []) when is_function(fun, 1), do: register(:event, fun, opts)

  @doc "Remove every handler registered by `owner` across all points."
  def unregister(owner), do: GenServer.call(__MODULE__, {:unregister, owner})

  @doc "Drop all handlers (test helper)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "Handlers registered at `point`, ordered by priority then registration order."
  def handlers(point) do
    @table
    |> :ets.lookup(point)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&{&1.priority, &1.seq})
  rescue
    ArgumentError -> []
  end

  # ---- hot path (ETS reads only) --------------------------------------------

  @doc "Fold `value` through every handler at `point` (handler: `(value, ctx) -> {:ok, new} | _`)."
  def run_filter(point, value, ctx) do
    Enum.reduce(handlers(point), value, fn entry, acc ->
      case safe(entry, fn -> entry.fun.(acc, ctx) end) do
        {:hook_ok, {:ok, new}} -> new
        _ -> acc
      end
    end)
  end

  @doc "First non-abstaining decision from a handler at `point`, else `:none` (handler: `(ctx) -> decision | :cont`)."
  def run_decision(point, ctx) do
    Enum.reduce_while(handlers(point), :none, fn entry, _ ->
      case safe(entry, fn -> entry.fun.(ctx) end) do
        {:hook_ok, decision} when decision not in [:cont, nil, :none] -> {:halt, decision}
        _ -> {:cont, :none}
      end
    end)
  end

  # Convenience wrappers used by Catalyst.Agent.Loop / ToolRunner.

  def transform_context(messages, ctx), do: run_filter(:transform_context, messages, ctx)

  def before_tool_call(ctx), do: run_decision(:before_tool_call, ctx)

  def after_tool_call(result_tuple, ctx), do: run_filter(:after_tool_call, result_tuple, ctx)

  def prepare_next_turn(context, config, ctx),
    do: run_filter(:prepare_next_turn, {context, config}, ctx)

  def should_stop?(ctx), do: run_decision(:should_stop_after_turn, ctx) == true

  @doc "Notify every event observer (isolated; errors logged)."
  def notify(event) do
    Enum.each(handlers(:event), fn entry -> safe(entry, fn -> entry.fun.(event) end) end)
    :ok
  end

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    {:ok, %{seq: 0}}
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
      if entry.owner == owner, do: :ets.delete_object(@table, obj)
    end)

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ---- internals ------------------------------------------------------------

  defp safe(entry, thunk) do
    {:hook_ok, thunk.()}
  rescue
    e ->
      Logger.warning("[hooks] #{entry.point}/#{entry.id} raised: #{Exception.message(e)}")
      :hook_skip
  catch
    kind, reason ->
      Logger.warning("[hooks] #{entry.point}/#{entry.id} #{kind}: #{inspect(reason)}")
      :hook_skip
  end
end
