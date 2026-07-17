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

  # ---- API ------------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  ## pages

  @doc "Register (replace) a page at `path`. `target` is a module (uses `render/1`) or `{module, fun}`."
  def register_page(path, target, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_page, path, normalize_target(target), opts})

  @doc "`{module, function}` for a page path, or nil."
  def fetch_page(path) do
    case :ets.lookup(@table, {:page, path}) do
      [{_, entry} | _] -> {entry.mod, entry.fun}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "All registered pages (`%{path, label, ...}`), sorted by label."
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
  def register_renderer(kind, match_fun, render_fun, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_renderer, kind, match_fun, render_fun, opts})

  @doc "The newest matching render function for `value` at `kind`, or nil."
  def renderer(kind, value) do
    @table
    |> :ets.lookup({:renderer, kind})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.find_value(fn e -> if safe_match(e.match, value), do: e.render end)
  rescue
    ArgumentError -> nil
  end

  ## components

  @doc "Register a slot component (`fun.(assigns) -> rendered`)."
  def register_component(slot, fun, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_component, slot, fun, opts})

  @doc "Component render functions for a slot, newest first."
  def components(slot) do
    @table
    |> :ets.lookup({:component, slot})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.map(& &1.fun)
  rescue
    ArgumentError -> []
  end

  ## commands

  def register_command(name, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_command, name, opts})

  def list_commands do
    @table |> :ets.match_object({{:command, :_}, :_}) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  ## purge

  @doc "Remove every UI contribution made by `owner`."
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
    entry = %{
      path: "chat",
      mod: CatalystWeb.Pages.ChatPage,
      fun: :render,
      label: "Chat",
      owner: nil,
      seq: 0
    }

    :ets.insert(@table, {{:page, "chat"}, entry})
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
