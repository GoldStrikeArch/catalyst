defmodule Catalyst.ExtensionAPI do
  @moduledoc """
  The facade passed to `Catalyst.Extension.setup/1`. It carries the extension's
  provenance (`owner`) and exposes `register_*` functions for every
  extension kind. Handles also capture the originating extension server and
  runtime generation. Registration through a stale handle is rejected, including
  a generation change that races a subsystem handler call.

  Each *kind* has a validation handler wired by its domain facade, so
  `apps/catalyst` never depends on `apps/catalyst_web`. Accepted contributions
  share `Catalyst.Runtime.Registry`; domain handlers retain their own validation
  and fallback rules. A `register_*` call for a kind that nothing has wired yet
  returns `{:error, {:unsupported_kind, kind}}` rather than crashing.

  Kind handlers live in `:persistent_term` (read-mostly, set once at boot).
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

  @typedoc "Stable identity of one built-in owner cleanup operation."
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
    purgers = [
      {{Catalyst.Runtime.Registry, :purge_owner, 1}, &Catalyst.Runtime.Registry.purge_owner/1},
      {{Catalyst.Extensions.Processes, :stop_owner, 1},
       &Catalyst.Extensions.Processes.stop_owner/1}
    ]

    results = Enum.map(purgers, fn {key, fun} -> {key, run_purger(fun, owner)} end)

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
  def register_renderer(api, kind, match, fun) do
    result = dispatch(api, :renderer, [kind, match, fun])
    remember_owner_collision(api, result)
  end

  @doc "Register a UI slot component."
  @spec register_component(t(), atom(), function(), keyword()) :: term()
  def register_component(api, slot, fun, opts \\ []) do
    result = dispatch(api, :component, [slot, fun, opts])
    remember_owner_collision(api, result)
  end

  @doc "Register a UI page at `path`."
  @spec register_page(t(), String.t(), module() | {module(), atom()}, keyword()) :: term()
  def register_page(api, path, module, opts \\ []) do
    result = dispatch(api, :page, [path, module, opts])
    remember_owner_collision(api, result)
  end

  @doc "Register a command-palette command."
  @spec register_command(t(), String.t(), keyword()) :: term()
  def register_command(api, name, opts \\ []) do
    result = dispatch(api, :command, [name, opts])
    remember_owner_collision(api, result)
  end

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
