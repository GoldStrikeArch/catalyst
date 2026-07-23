defmodule Catalyst.ExtensionAPI do
  @moduledoc """
  The facade passed to `Catalyst.Extension.setup/1`. It carries the extension's
  provenance (`owner`) and exposes `register_*` functions for every
  extension kind. Handles also capture the originating extension server and
  runtime generation. Registration through a stale handle is rejected, including
  a generation change that races a subsystem handler call.

  Decoupling: each *kind* is backed by a handler registered at boot by the
  subsystem that owns it — so `apps/catalyst` (core) never has to depend on
  `apps/catalyst_web`. Core wires `:tool`, `:hook`, `:event`; the provider
  registry wires `:provider`; the web UI registry wires `:renderer`, `:component`,
  `:page`, `:command`. A `register_*` call for a kind that nothing has wired yet
  returns `{:error, {:unsupported_kind, kind}}` rather than crashing.

  Handlers and purgers live in `:persistent_term` (read-mostly, set once at boot).
  """

  require Logger

  defstruct [:owner, :load_ref, :generation, :server]

  @type t :: %__MODULE__{
          owner: String.t() | nil,
          load_ref: reference() | nil,
          generation: reference() | nil,
          server: GenServer.server()
        }

  @doc "Build an API handle for `owner` (the extension id)."
  @spec new(String.t() | nil, reference() | nil) :: t()
  def new(owner, load_ref \\ nil) do
    %__MODULE__{
      owner: owner,
      load_ref: load_ref,
      generation: Catalyst.Extensions.Transaction.generation(),
      server: Catalyst.Extensions.Transaction.server()
    }
  end

  # ---- kind wiring (called by subsystems at boot) ---------------------------

  @doc "Wire a `register_<kind>` handler. Use a named external capture `(api, ...args) -> term` so it remains valid across hot reloads."
  @spec register_kind(atom(), function()) :: :ok
  def register_kind(kind, handler) when is_atom(kind) and is_function(handler) do
    :persistent_term.put({__MODULE__, :kind, kind}, handler)
  end

  @doc """
  Register an owner-purge function. Before a file is (re)loaded, every purger is
  called with the extension's owner id so its registries can drop that owner's
  prior entries. (Tools are purged inline by `Catalyst.Extensions` to avoid a
  self-call; hooks/providers/UI register purgers here.)

  Purgers are keyed by stable identity — `{module, function, arity}` for
  external captures like `&Mod.fun/1` — so re-registering after the defining
  module is hot-reloaded *replaces* the prior entry. (Capture equality would
  treat the new capture as different, accumulating stale funs that raise
  `:badfun` on every purge, forever.) Anonymous funs have no stable identity
  and fall back to the fun itself as key.
  """
  @spec register_purger((term() -> any())) :: :ok
  def register_purger(fun) when is_function(fun, 1) do
    :persistent_term.put({__MODULE__, :purgers}, Map.put(purger_map(), purger_key(fun), fun))
  end

  @typedoc "Stable purger identity: `{module, function, arity}` for external captures, else the fun itself."
  @type purger_key :: {module(), atom(), arity()} | (term() -> any())

  @typedoc "One purger's failure: its key plus the caught `{kind, reason}`."
  @type purger_failure :: {purger_key(), {atom(), term()}}

  @doc """
  Run every registered purger for `owner`.

  Returns `{:ok, purged_keys}` when every purger succeeded, or
  `{:error, failures}` listing each failed subsystem — callers keep the owner
  tracked as degraded on failure so cleanup stays retryable, never silently
  forgotten with live residue.
  """
  @spec purge_owner(term()) :: {:ok, [purger_key()]} | {:error, [purger_failure()]}
  def purge_owner(owner) do
    results = Enum.map(purger_map(), fn {key, fun} -> {key, run_purger(fun, owner)} end)

    case for {key, {:error, reason}} <- results, do: {key, reason} do
      [] -> {:ok, Enum.map(results, &elem(&1, 0))}
      failures -> {:error, failures}
    end
  end

  # `catch _, _`, not just `rescue` (mirrors Hooks.safe/2): purgers call
  # into other registries' GenServers, and a dead or busy one EXITs
  # (:noproc/:timeout) rather than raising. The purge paths run inside the
  # Catalyst.Extensions server, so an uncaught exit would take down the
  # live tools table along with it.
  defp run_purger(fun, owner) do
    fun.(owner)
    :ok
  catch
    kind, reason ->
      Logger.warning(
        "[extension_api] purger #{inspect(fun)} for #{inspect(owner)} " <>
          "#{kind}: #{inspect(reason)}"
      )

      {:error, {kind, reason}}
  end

  defp purger_map, do: :persistent_term.get({__MODULE__, :purgers}, %{})

  defp purger_key(fun) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        {:module, mod} = Function.info(fun, :module)
        {:name, name} = Function.info(fun, :name)
        {:arity, arity} = Function.info(fun, :arity)
        {mod, name, arity}

      _ ->
        fun
    end
  end

  # ---- registration facade --------------------------------------------------
  # Each function returns whatever the wired handler returns, or
  # `{:error, {:unsupported_kind, kind}}` when nothing has wired that kind yet.

  @doc "Register a tool module (owner-tagged)."
  @spec register_tool(t(), module()) :: term()
  def register_tool(api, module) do
    result = dispatch(api, :tool, [module])
    remember_owner_collision(api, result)
  end

  @doc "Register an LLM provider under `name`."
  @spec register_provider(t(), String.t(), term()) :: term()
  def register_provider(api, name, config) do
    result = dispatch(api, :provider, [name, config])
    remember_owner_collision(api, result)
  end

  @doc "Register purpose-aware prompt text for an exact model key."
  @spec register_prompt(t(), String.t() | :default, String.t(), keyword()) :: term()
  def register_prompt(api, model_key, text, opts \\ []) do
    result = dispatch(api, :prompt, [model_key, text, opts])
    remember_owner_collision(api, result)
  end

  @doc "Register the runtime-default prompt policy."
  @spec register_prompt_policy(t(), module(), keyword()) :: term()
  def register_prompt_policy(api, module, opts \\ []) do
    result = dispatch(api, :prompt_policy, [module, opts])
    remember_owner_collision(api, result)
  end

  @doc "Register a named workflow (use `:default` for the runtime default)."
  @spec register_workflow(t(), String.t() | :default, module(), keyword()) :: term()
  def register_workflow(api, name, module, opts \\ []) do
    result = dispatch(api, :workflow, [name, module, opts])
    remember_owner_collision(api, result)
  end

  @doc "Register the runtime-default context policy."
  @spec register_context_policy(t(), module(), keyword()) :: term()
  def register_context_policy(api, module, opts \\ []) do
    result = dispatch(api, :context_policy, [module, opts])
    remember_owner_collision(api, result)
  end

  @doc "Register a context threshold for an exact model key."
  @spec register_context_threshold(t(), String.t() | :default, term(), keyword()) :: term()
  def register_context_threshold(api, model_key, value, opts \\ []) do
    result = dispatch(api, :context_threshold, [model_key, value, opts])
    remember_owner_collision(api, result)
  end

  @doc "Register a loop hook at `point` (e.g. `:before_tool_call`)."
  @spec register_hook(t(), atom(), function(), keyword()) :: term()
  def register_hook(api, point, fun, opts \\ []), do: dispatch(api, :hook, [point, fun, opts])

  @doc "Register an event observer."
  @spec on(t(), function(), keyword()) :: term()
  def on(api, fun, opts \\ []), do: dispatch(api, :event, [fun, opts])

  @doc "Register a UI renderer for `kind` values matching `match`."
  @spec register_renderer(t(), atom(), (term() -> boolean()), function()) :: term()
  def register_renderer(api, kind, match, fun), do: dispatch(api, :renderer, [kind, match, fun])

  @doc "Register a UI slot component."
  @spec register_component(t(), atom(), function(), keyword()) :: term()
  def register_component(api, slot, fun, opts \\ []),
    do: dispatch(api, :component, [slot, fun, opts])

  @doc "Register a UI page at `path`."
  @spec register_page(t(), String.t(), module() | {module(), atom()}, keyword()) :: term()
  def register_page(api, path, module, opts \\ []), do: dispatch(api, :page, [path, module, opts])

  @doc "Register a command-palette command."
  @spec register_command(t(), String.t(), keyword()) :: term()
  def register_command(api, name, opts \\ []), do: dispatch(api, :command, [name, opts])

  @doc """
  Start a supervised, owner-tagged process (any child spec) under
  `Catalyst.Extensions.Processes`. Purging/reloading the extension terminates it
  — use this for watchers, pollers, client connections, and other long-lived
  extension processes instead of unsupervised `spawn`.
  """
  @spec start_child(t(), Supervisor.child_spec() | {module(), term()} | module()) :: term()
  def start_child(api, child_spec), do: dispatch(api, :process, [child_spec])

  defp dispatch(%__MODULE__{} = api, kind, args) do
    Catalyst.Extensions.Transaction.with_generation_gate(fn ->
      case Catalyst.Extensions.generation_current?(api.generation) do
        true -> dispatch_current(api, kind, args)
        false -> {:error, :stale_extension_generation}
      end
    end)
  end

  defp dispatch_current(api, kind, args) do
    result =
      case :persistent_term.get({__MODULE__, :kind, kind}, nil) do
        nil -> {:error, {:unsupported_kind, kind}}
        handler -> apply(handler, [api | args])
      end

    case Catalyst.Extensions.generation_current?(api.generation) do
      true -> result
      false -> purge_stale_registration(api.owner)
    end
  end

  defp purge_stale_registration(owner) do
    case purge_owner(owner) do
      {:ok, _purged} ->
        :ok

      {:error, failures} ->
        Logger.warning(
          "[extension_api] stale-generation purge for #{inspect(owner)} left residue: " <>
            inspect(failures)
        )
    end

    {:error, :stale_extension_generation}
  end

  # Every registry emits the one unified collision shape
  # `{:owner_collision, kind, key, existing, attempted}` (key `nil` for the
  # context policy), so one clause records them all for the in-flight load.
  defp remember_owner_collision(
         api,
         {:error, {:owner_collision, _kind, _key, _existing, _attempted} = reason} = error
       ) do
    record_load_collision(api, reason)
    error
  end

  defp remember_owner_collision(_api, result), do: result

  defp record_load_collision(%__MODULE__{load_ref: nil}, _reason), do: :ok

  defp record_load_collision(%__MODULE__{server: server, load_ref: load_ref}, reason),
    do: Catalyst.Extensions.record_setup_collision(server, load_ref, reason)
end
