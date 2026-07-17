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

  defstruct [:owner, :source_path]

  @type t :: %__MODULE__{owner: String.t() | nil, source_path: String.t() | nil}

  @doc "Build an API handle for `owner` (the extension id) and its source file."
  def new(owner, source_path \\ nil), do: %__MODULE__{owner: owner, source_path: source_path}

  # ---- kind wiring (called by subsystems at boot) ---------------------------

  @doc "Wire a `register_<kind>` handler. `handler` is `(api, ...args) -> term`."
  def register_kind(kind, handler) when is_atom(kind) and is_function(handler) do
    :persistent_term.put({__MODULE__, :kind, kind}, handler)
  end

  @doc "Whether a kind has a wired handler."
  def kind_available?(kind), do: :persistent_term.get({__MODULE__, :kind, kind}, nil) != nil

  @doc """
  Register an owner-purge function. Before a file is (re)loaded, every purger is
  called with the extension's owner id so its registries can drop that owner's
  prior entries. (Tools are purged inline by `Catalyst.Extensions` to avoid a
  self-call; hooks/providers/UI register purgers here.)
  """
  def register_purger(fun) when is_function(fun, 1) do
    :persistent_term.put({__MODULE__, :purgers}, [fun | purgers()])
  end

  @doc "Run every registered purger for `owner`."
  def purge_owner(owner) do
    Enum.each(purgers(), fn fun ->
      try do
        fun.(owner)
      rescue
        _ -> :ok
      end
    end)
  end

  defp purgers, do: :persistent_term.get({__MODULE__, :purgers}, [])

  # ---- registration facade --------------------------------------------------

  def register_tool(api, module), do: dispatch(api, :tool, [module])
  def register_provider(api, name, config), do: dispatch(api, :provider, [name, config])
  def register_hook(api, point, fun, opts \\ []), do: dispatch(api, :hook, [point, fun, opts])
  def on(api, fun, opts \\ []), do: dispatch(api, :event, [fun, opts])
  def register_renderer(api, kind, match, fun), do: dispatch(api, :renderer, [kind, match, fun])

  def register_component(api, slot, fun, opts \\ []),
    do: dispatch(api, :component, [slot, fun, opts])

  def register_page(api, path, module, opts \\ []), do: dispatch(api, :page, [path, module, opts])
  def register_command(api, name, opts \\ []), do: dispatch(api, :command, [name, opts])

  defp dispatch(%__MODULE__{} = api, kind, args) do
    case :persistent_term.get({__MODULE__, :kind, kind}, nil) do
      nil -> {:error, {:unsupported_kind, kind}}
      handler -> apply(handler, [api | args])
    end
  end
end
