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
  `Catalyst.Agent.Event`. Each observer is a PubSub subscriber with its own
  mailbox, so observer work cannot delay token streaming or other loop work.
  Decision and filter hooks remain synchronous because their return values
  control the current run.

  Handlers are contributions in `Catalyst.Runtime.Registry`, tagged with an
  `owner` so a reloaded extension can revoke its prior handlers (`unregister/1`).
  Synchronous decision/filter hooks are generation-gated and fail
  closed: the agent loop pins one `capture_snapshot/1` per turn, snapshot
  capture refuses to observe a rebuilding extension runtime (returning
  `{:error, :extension_runtime_recovering}`), and `before_tool_call` blocks
  rather than proceeding without its gates. Only the fire-and-forget observer
  channel (`notify/2`) uses PubSub and stays fail-open. **Every synchronous
  handler runs in an isolated supervised process under a deadline
  (`:hook_handler_timeout`, default 10s): a crashing, throwing, or hanging hook
  is logged and skipped — it can never take down or wedge a run.** Observer
  callbacks run in their subscriber process; failures are logged and isolated,
  while ordinary BEAM mailbox ordering and backpressure apply.
  """

  require Logger

  alias Catalyst.Hooks.Observer
  alias Catalyst.Runtime.Registry, as: Runtime
  alias Catalyst.Tasks

  @runtime_ready_key {__MODULE__, :runtime_ready}
  @handler_timeout_ms 10_000
  @points [
    :transform_context,
    :before_tool_call,
    :after_tool_call,
    :prepare_next_turn,
    :should_stop_after_turn,
    :event
  ]
  @sync_points [
    :transform_context,
    :before_tool_call,
    :after_tool_call,
    :prepare_next_turn,
    :should_stop_after_turn
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

  @typedoc "An immutable selection of synchronous hook entries for one turn."
  @type snapshot :: %{
          handlers: %{optional(point()) => [handler_entry()]}
        }

  @doc "The known hook points."
  @spec points() :: [point()]
  def points, do: @points

  # ---- API ------------------------------------------------------------------

  @doc """
  Register a hook handler at `point`. `fun`'s arity depends on the point (see the
  moduledoc). `opts`: `:owner` (for `unregister/1`), `:id` (display), `:priority`
  (lower runs first, default 100).
  """
  @spec register(point(), function(), keyword()) :: :ok | {:error, term()}
  def register(point, fun, opts \\ []) when is_atom(point) and is_function(fun) do
    seq = System.unique_integer([:positive, :monotonic])
    owner = opts |> Keyword.get(:owner) |> Runtime.normalize_owner()

    entry = %{
      point: point,
      id: Keyword.get(opts, :id, "h#{seq}"),
      owner: owner,
      priority: Keyword.get(opts, :priority, 100),
      seq: seq,
      fun: fun
    }

    register_entry(entry)
  end

  @doc "Register an event observer (`fun.(event) -> any`) for every agent event."
  @spec on((term() -> term()), keyword()) :: :ok | {:error, term()}
  def on(fun, opts \\ []) when is_function(fun, 1), do: register(:event, fun, opts)

  @doc "Remove every handler registered by `owner` across all points."
  @spec unregister(term()) :: :ok
  def unregister(owner) do
    owner = Runtime.normalize_owner(owner)
    observers = owner_observers(owner)
    :ok = Runtime.purge_owner(owner, :hook)
    Observer.stop(observers)
  end

  defp register_entry(%{point: :event} = entry) do
    key = {:event, entry.seq}

    with :ok <- Runtime.put(:hook, key, entry, owner: entry.owner),
         {:ok, observer} <- Observer.start(entry),
         :ok <- Runtime.put(:hook, key, Map.put(entry, :observer, observer), owner: entry.owner) do
      :ok
    else
      {:error, reason} = error ->
        :ok = Runtime.delete(:hook, key)
        Logger.warning("[hooks] could not start observer #{entry.id}: #{inspect(reason)}")
        error
    end
  end

  defp register_entry(entry) do
    Runtime.put(:hook, {entry.point, entry.seq}, entry, owner: entry.owner)
  end

  defp owner_observers(owner) do
    for %{owner: ^owner, value: %{point: :event, observer: observer}} <- Runtime.list(:hook),
        do: observer
  end

  @doc """
  Handlers registered at `point`, ordered by priority then registration order.

  Fail-open live read used for introspection; synchronous gates and filters go
  through `capture_snapshot/1` instead.
  """
  @spec handlers(point()) :: [handler_entry()]
  def handlers(point) do
    case fetch_handlers(point) do
      {:ok, entries} -> entries
      {:error, :registry_unavailable} -> []
    end
  end

  @doc false
  @spec fetch_handlers(point()) :: {:ok, [handler_entry()]} | {:error, :registry_unavailable}
  def fetch_handlers(point) do
    case Runtime.available?() do
      true ->
        entries =
          for %{key: {^point, _seq}, value: entry} <- Runtime.list(:hook), do: entry

        {:ok, Enum.sort_by(entries, &{&1.priority, &1.seq})}

      false ->
        {:error, :registry_unavailable}
    end
  end

  @doc "Capture ready synchronous hook entries for one complete turn."
  @spec capture_snapshot([point()]) :: {:ok, snapshot()} | {:error, :extension_runtime_recovering}
  def capture_snapshot(points \\ @sync_points) when is_list(points) do
    points = Enum.uniq(points)

    with true <- runtime_ready?(),
         {:ok, entries} <- snapshot_handlers(points),
         true <- runtime_ready?() do
      {:ok, %{handlers: entries}}
    else
      _not_stable -> {:error, :extension_runtime_recovering}
    end
  end

  defp snapshot_handlers(points) do
    Enum.reduce_while(points, {:ok, %{}}, fn point, {:ok, entries} ->
      case fetch_handlers(point) do
        {:ok, handlers} -> {:cont, {:ok, Map.put(entries, point, handlers)}}
        {:error, :registry_unavailable} -> {:halt, {:error, :registry_unavailable}}
      end
    end)
  end

  @doc false
  @spec begin_runtime_rebuild() :: :ok
  def begin_runtime_rebuild, do: :persistent_term.put(@runtime_ready_key, false)

  @doc false
  @spec mark_runtime_ready() :: :ok
  def mark_runtime_ready, do: :persistent_term.put(@runtime_ready_key, true)

  @doc false
  @spec invalidate_runtime() :: :ok
  def invalidate_runtime, do: begin_runtime_rebuild()

  @doc false
  @spec runtime_ready?() :: boolean()
  def runtime_ready?, do: :persistent_term.get(@runtime_ready_key, true)

  # ---- hot path --------------------------------------------------------------

  # Generic runners over a freshly captured single-point snapshot. Contract
  # seams for the handler-isolation tests (crash/timeout/shape coverage on
  # synthetic points); production sync-hook call sites use the turn-pinned
  # snapshot wrappers below.
  #
  # `valid?` guards the documented isolation promise: a handler returning
  # `{:ok, value}` of the wrong SHAPE (e.g. `{:ok, :done}` where a 4-tuple is
  # expected) is logged and skipped instead of poisoning the fold and crashing
  # the run when the caller destructures the result.
  @doc false
  @spec run_filter(point(), term(), term(), (term() -> boolean())) :: term()
  def run_filter(point, value, ctx, valid? \\ fn _ -> true end) do
    with {:ok, snapshot} <- capture_snapshot([point]),
         {:ok, entries} <- snapshot_entries(snapshot, point) do
      run_filter_entries(entries, value, ctx, valid?)
    else
      _recovering -> value
    end
  end

  defp run_filter_entries(entries, value, ctx, valid?) do
    Enum.reduce(entries, value, fn entry, acc ->
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

  # First non-abstaining decision from a handler at `point`, else `:none`
  # (handler: `(ctx) -> decision | :cont`). Same test-seam status as
  # `run_filter/4`; the production gate is `before_tool_call/1,2`.
  @doc false
  @spec run_decision(point(), term()) :: term() | :none
  def run_decision(point, ctx) do
    with {:ok, snapshot} <- capture_snapshot([point]),
         {:ok, entries} <- snapshot_entries(snapshot, point) do
      run_decision_entries(entries, ctx)
    else
      _recovering -> :none
    end
  end

  defp run_decision_entries(entries, ctx) do
    Enum.reduce_while(entries, :none, fn entry, _ ->
      case safe(entry, fn -> entry.fun.(ctx) end) do
        {:hook_ok, decision} when decision not in [:cont, nil, :none] -> {:halt, decision}
        _ -> {:cont, :none}
      end
    end)
  end

  # Convenience wrappers used by Catalyst.Agent.Loop / ToolRunner.

  @doc "Fold request messages through a turn-pinned hook snapshot."
  @spec transform_context([term()], term(), snapshot()) ::
          {:ok, [term()]} | {:error, :extension_runtime_recovering}
  def transform_context(messages, ctx, snapshot) do
    case snapshot_entries(snapshot, :transform_context) do
      {:ok, entries} -> {:ok, run_filter_entries(entries, messages, ctx, &is_list/1)}
      :error -> {:error, :extension_runtime_recovering}
    end
  end

  @doc "Synchronously ask tool-call gates for the first blocking decision."
  @spec before_tool_call(term()) :: term() | :none
  def before_tool_call(ctx) do
    case capture_snapshot([:before_tool_call]) do
      {:ok, snapshot} -> before_tool_call(ctx, snapshot)
      {:error, :extension_runtime_recovering} -> {:block, :extension_runtime_recovering}
    end
  end

  @doc "Ask a turn-pinned tool-call gate for the first blocking decision."
  @spec before_tool_call(term(), snapshot()) :: term() | :none
  def before_tool_call(ctx, snapshot) do
    case snapshot_entries(snapshot, :before_tool_call) do
      {:ok, entries} -> run_decision_entries(entries, ctx)
      :error -> {:block, :extension_runtime_recovering}
    end
  end

  @doc """
  Fold a tool result through result-transform hooks under a freshly captured
  snapshot; while the extension runtime is recovering, the result passes
  through unchanged.
  """
  @spec after_tool_call({term(), term(), boolean(), boolean()}, term()) ::
          {term(), term(), boolean(), boolean()}
  def after_tool_call(result_tuple, ctx) do
    case capture_snapshot([:after_tool_call]) do
      {:ok, snapshot} -> after_tool_call(result_tuple, ctx, snapshot)
      {:error, :extension_runtime_recovering} -> result_tuple
    end
  end

  @doc "Fold a tool result through the result-transform hooks pinned in `snapshot`."
  @spec after_tool_call({term(), term(), boolean(), boolean()}, term(), snapshot()) ::
          {term(), term(), boolean(), boolean()}
  def after_tool_call(result_tuple, ctx, snapshot) do
    case snapshot_entries(snapshot, :after_tool_call) do
      {:ok, entries} -> run_filter_entries(entries, result_tuple, ctx, &valid_tool_result?/1)
      :error -> result_tuple
    end
  end

  @doc "Fold context/config through the next-turn preparation hooks pinned in `snapshot`."
  @spec prepare_next_turn(map(), map(), term(), snapshot()) :: {map(), map()}
  def prepare_next_turn(context, config, ctx, snapshot) do
    case snapshot_entries(snapshot, :prepare_next_turn) do
      {:ok, entries} ->
        run_filter_entries(entries, {context, config}, ctx, &match?({%{}, %{}}, &1))

      :error ->
        {context, config}
    end
  end

  @doc "Whether a stop hook pinned in `snapshot` requests termination after this turn."
  @spec should_stop?(term(), snapshot()) :: boolean()
  def should_stop?(ctx, snapshot) do
    case snapshot_entries(snapshot, :should_stop_after_turn) do
      {:ok, entries} -> run_decision_entries(entries, ctx) == true
      :error -> false
    end
  end

  defp snapshot_entries(%{handlers: handlers}, point) when is_map(handlers) do
    case Map.fetch(handlers, point) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      _missing_or_invalid -> :error
    end
  end

  defp snapshot_entries(_snapshot, _point), do: :error

  defp valid_tool_result?({content, details, error?, terminate?}) do
    is_list(content) and (is_map(details) or is_nil(details)) and is_boolean(error?) and
      is_boolean(terminate?)
  end

  defp valid_tool_result?(_result), do: false

  @doc """
  Broadcast an event for asynchronous observer delivery under `session_key`.

  Returns after PubSub has placed the event in each subscriber mailbox.
  Omitting the key uses the calling process as the session identity.
  """
  @spec notify(term()) :: :ok
  def notify(event), do: notify(event, self())

  @doc "Broadcast an event under an explicit session key; see `notify/1`."
  @spec notify(term(), term()) :: :ok
  def notify(event, session_key) do
    Observer.broadcast(session_key || self(), event)
  end

  @doc "Broadcast a host-synthesized event without running observer callbacks inline."
  @spec notify_async(term(), term()) :: :ok
  def notify_async(event, session_key), do: notify(event, session_key)

  @doc "Wait until every current observer has processed its prior mailbox entries."
  @spec await_observers(term(), timeout()) :: :ok
  def await_observers(_session_key \\ self(), timeout \\ 5_000),
    do: Observer.await(length(handlers(:event)), timeout)

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
