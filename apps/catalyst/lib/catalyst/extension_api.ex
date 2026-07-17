defmodule Catalyst.ExtensionAPI do
  @moduledoc """
  The facade passed to `Catalyst.Extension.setup/1`. It carries the extension's
  provenance (`owner`, `source_path`) and exposes `register_*` functions for every
  extension kind.

  Decoupling: each *kind* is backed by a handler registered at boot by the
  subsystem that owns it — so `apps/catalyst` (core) never has to depend on
  `apps/catalyst_web`. Core wires `:tool`, `:hook`, `:event`; the provider
  registry wires `:provider`; the web UI registry wires `:renderer`, `:component`,
  `:page`, `:command`. A `register_*` call for a kind that nothing has wired yet
  returns `{:error, {:unsupported_kind, kind}}` rather than crashing.

  Handlers and purgers live in `:persistent_term` (read-mostly, set once at boot).
  """

  require Logger

  defstruct [:owner, :source_path]

  @type t :: %__MODULE__{owner: String.t() | nil, source_path: String.t() | nil}

  @doc "Build an API handle for `owner` (the extension id) and its source file."
  @spec new(String.t() | nil, String.t() | nil) :: t()
  def new(owner, source_path \\ nil), do: %__MODULE__{owner: owner, source_path: source_path}

  # ---- kind wiring (called by subsystems at boot) ---------------------------

  @doc "Wire a `register_<kind>` handler. `handler` is `(api, ...args) -> term`."
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

  @doc "Run every registered purger for `owner`."
  @spec purge_owner(term()) :: :ok
  def purge_owner(owner) do
    Enum.each(purgers(), fn fun ->
      # `catch _, _`, not just `rescue` (mirrors Hooks.safe/2): purgers call
      # into other registries' GenServers, and a dead or busy one EXITs
      # (:noproc/:timeout) rather than raising. The purge paths run inside the
      # Catalyst.Extensions server, so an uncaught exit would take down the
      # live tools table along with it.
      try do
        fun.(owner)
      catch
        kind, reason ->
          Logger.warning(
            "[extension_api] purger #{inspect(fun)} for #{inspect(owner)} " <>
              "#{kind}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp purgers, do: Map.values(purger_map())

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
  def register_tool(api, module), do: dispatch(api, :tool, [module])

  @doc "Register an LLM provider under `name`."
  @spec register_provider(t(), String.t(), term()) :: term()
  def register_provider(api, name, config), do: dispatch(api, :provider, [name, config])

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
    case :persistent_term.get({__MODULE__, :kind, kind}, nil) do
      nil -> {:error, {:unsupported_kind, kind}}
      handler -> apply(handler, [api | args])
    end
  end
end
