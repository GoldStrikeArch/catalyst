defmodule CatalystWeb.UI.Registry do
  @moduledoc """
  Runtime registry for UI extension points (ETS-backed, like `Catalyst.Extensions`):

    * **pages** — `path -> {module, function}` rendered by `ShellLive` at `/:page`;
    * **renderers** — per-kind (`:message`, `:block`) `{match_fun, render_fun}` that
      override the built-in rendering for matching values (newest wins);
    * **components** — named slot widgets (e.g. `:header_extra`, `:sidebar`);
    * **commands** — named command-palette entries.

  Extensions register through `Catalyst.ExtensionAPI` (the `:renderer`,
  `:component`, `:page`, `:command` kinds are wired here at boot), tagged with an
  `owner` so reloading an extension purges its prior UI contributions.
  """

  use GenServer

  alias Catalyst.ExtensionAPI

  @table :catalyst_ui

  @type kind :: :message | :block
  @type target :: module() | {module(), atom()}
  @type render_fun :: (map() -> Phoenix.LiveView.Rendered.t())

  # ---- API ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  ## pages

  @doc "Register (replace) a page at `path`. `target` is a module (uses `render/1`) or `{module, fun}`."
  @spec register_page(String.t(), target(), keyword()) :: :ok
  def register_page(path, target, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_page, path, normalize_target(target), opts})

  @doc "The `{module, function}` registered for a page path. Returns `{:ok, {mod, fun}}` or `:error`."
  @spec fetch_page(String.t()) :: {:ok, {module(), atom()}} | :error
  def fetch_page(path) do
    case :ets.lookup(@table, {:page, path}) do
      [{_, entry} | _] -> {:ok, {entry.mod, entry.fun}}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "All registered pages (`%{path, label, ...}`), sorted by label."
  @spec list_pages() :: [map()]
  def list_pages do
    @table
    |> :ets.match_object({{:page, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.label)
  rescue
    ArgumentError -> []
  end

  ## renderers

  @doc "Register a renderer for `kind` (`:message`/`:block`). `match_fun.(value)` -> bool; `render_fun.(assigns)` -> rendered."
  @spec register_renderer(kind(), (term() -> boolean()), render_fun(), keyword()) :: :ok
  def register_renderer(kind, match_fun, render_fun, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_renderer, kind, match_fun, render_fun, opts})

  @doc "The newest matching render function for `value` at `kind`, or nil."
  @spec renderer(kind(), term()) :: render_fun() | nil
  def renderer(kind, value) do
    @table
    |> :ets.lookup({:renderer, kind})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.find_value(fn e -> if safe_match(e.match, value), do: e.render end)
  rescue
    ArgumentError -> nil
  end

  @doc "All registered renderers (`%{kind, owner, seq}`), newest first. Introspection only."
  @spec list_renderers() :: [map()]
  def list_renderers do
    @table
    |> :ets.match_object({{:renderer, :_}, :_})
    |> Enum.map(fn {{:renderer, kind}, e} -> %{kind: kind, owner: e.owner, seq: e.seq} end)
    |> Enum.sort_by(& &1.seq, :desc)
  rescue
    ArgumentError -> []
  end

  ## components

  @doc "Register a slot component (`fun.(assigns) -> rendered`)."
  @spec register_component(atom(), render_fun(), keyword()) :: :ok
  def register_component(slot, fun, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_component, slot, fun, opts})

  @doc "Component render functions for a slot, newest first."
  @spec components(atom()) :: [render_fun()]
  def components(slot) do
    @table
    |> :ets.lookup({:component, slot})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.map(& &1.fun)
  rescue
    ArgumentError -> []
  end

  @doc "All registered slot components (`%{slot, owner, seq}`), newest first. Introspection only."
  @spec list_components() :: [map()]
  def list_components do
    @table
    |> :ets.match_object({{:component, :_}, :_})
    |> Enum.map(fn {{:component, slot}, e} -> %{slot: slot, owner: e.owner, seq: e.seq} end)
    |> Enum.sort_by(& &1.seq, :desc)
  rescue
    ArgumentError -> []
  end

  ## commands

  @doc "Register or replace a command-palette entry."
  @spec register_command(String.t(), keyword()) :: :ok
  def register_command(name, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_command, name, opts})

  @doc "All registered command-palette entries."
  @spec list_commands() :: [map()]
  def list_commands do
    @table |> :ets.match_object({{:command, :_}, :_}) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  ## purge

  @doc "Remove every UI contribution made by `owner`."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: GenServer.call(__MODULE__, {:unregister_owner, owner})

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    seed_builtin_pages()
    wire()
    {:ok, %{seq: 0}}
  end

  @impl true
  def handle_call({:register_page, path, {mod, fun}, opts}, _from, state) do
    # last write wins per path
    :ets.match_delete(@table, {{:page, path}, :_})

    entry = %{
      path: path,
      mod: mod,
      fun: fun,
      label: opts[:label] || page_label(path),
      owner: opts[:owner],
      seq: state.seq
    }

    :ets.insert(@table, {{:page, path}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:register_renderer, kind, match, render, opts}, _from, state) do
    entry = %{match: match, render: render, owner: opts[:owner], seq: state.seq}
    :ets.insert(@table, {{:renderer, kind}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:register_component, slot, fun, opts}, _from, state) do
    entry = %{fun: fun, owner: opts[:owner], seq: state.seq}
    :ets.insert(@table, {{:component, slot}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:register_command, name, opts}, _from, state) do
    :ets.match_delete(@table, {{:command, name}, :_})

    entry = %{
      name: name,
      owner: opts[:owner],
      handler: opts[:handler],
      label: opts[:label] || name,
      seq: state.seq
    }

    :ets.insert(@table, {{:command, name}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {_key, entry} = obj ->
      if Map.get(entry, :owner) == owner, do: :ets.delete_object(@table, obj)
    end)

    {:reply, :ok, state}
  end

  # ---- internals ------------------------------------------------------------

  defp bump(state), do: %{state | seq: state.seq + 1}

  defp seed_builtin_pages do
    builtins = [
      %{path: "chat", mod: CatalystWeb.Pages.ChatPage, label: "Chat"},
      %{path: "extensions", mod: CatalystWeb.Pages.ExtensionsPage, label: "Extensions"}
    ]

    Enum.each(builtins, fn page ->
      entry = Map.merge(page, %{fun: :render, owner: nil, seq: 0})
      :ets.insert(@table, {{:page, page.path}, entry})
    end)
  end

  defp wire do
    ExtensionAPI.register_kind(:renderer, fn api, kind, match, fun ->
      register_renderer(kind, match, fun, owner: api.owner)
    end)

    ExtensionAPI.register_kind(:component, fn api, slot, fun, opts ->
      register_component(slot, fun, Keyword.put_new(opts, :owner, api.owner))
    end)

    ExtensionAPI.register_kind(:page, fn api, path, target, opts ->
      register_page(path, target, Keyword.put_new(opts, :owner, api.owner))
    end)

    ExtensionAPI.register_kind(:command, fn api, name, opts ->
      register_command(name, Keyword.put_new(opts, :owner, api.owner))
    end)

    ExtensionAPI.register_purger(&unregister_owner/1)
  end

  defp normalize_target({mod, fun}) when is_atom(mod) and is_atom(fun), do: {mod, fun}
  defp normalize_target(mod) when is_atom(mod), do: {mod, :render}

  defp page_label(path), do: path |> String.replace("_", " ") |> String.capitalize()

  defp safe_match(match, value) do
    match.(value)
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
