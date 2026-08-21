defmodule CatalystWeb.UI.Registry do
  @moduledoc """
  Runtime registry for UI extension points (ETS-backed, like `Catalyst.Extensions`):

    * **pages** — `path -> {module, function}` rendered by `ShellLive` at `/:page`;
    * **renderers** — per-kind (`:message`, `:block`) `{match_fun, render_fun}` that
      override the built-in rendering for matching values (newest wins);
    * **components** — named slot widgets (e.g. `:header_extra`, `:sidebar`);
    * **commands** — named command-palette entries.

  Extensions register through `Catalyst.ExtensionAPI` (the `ui.renderer`,
  `ui.component`, `ui.page`, and `ui.command` extension points are wired here at
  boot), tagged with an `owner` so reloading an extension purges its prior UI
  contributions.
  """

  use GenServer

  alias Catalyst.ExtensionAPI
  alias CatalystWeb.UI.Contributions

  @table :catalyst_ui

  @type kind :: :message | :block
  @type target :: module() | {module(), atom()}
  @type render_fun :: (map() -> Phoenix.LiveView.Rendered.t())

  defguardp valid_page_target(target)
            when is_atom(target) or
                   (is_tuple(target) and tuple_size(target) == 2 and
                      is_atom(elem(target, 0)) and is_atom(elem(target, 1)))

  # ---- API ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Whether the UI contribution table is currently available."
  @spec available?() :: boolean()
  def available?, do: :ets.whereis(@table) != :undefined

  ## pages

  @doc "Register (replace) a page at `path`. `target` is a module (uses `render/1`) or `{module, fun}`."
  @spec register_page(String.t(), target(), keyword()) :: :ok
  def register_page(path, target, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_page, path, normalize_target(target), opts})

  @doc "The `{module, function}` registered for a page path. Returns `{:ok, {mod, fun}}` or `:error`."
  @spec fetch_page(String.t()) :: {:ok, {module(), atom()}} | :error
  def fetch_page(path) do
    case lookup_entries({:page, path}) do
      [entry | _] -> {:ok, {entry.mod, entry.fun}}
      [] -> :error
    end
  end

  @doc "All registered pages (`%{path, label, ...}`), sorted by label."
  @spec list_pages() :: [map()]
  def list_pages do
    {:page, :_}
    |> match_entries()
    |> Enum.sort_by(& &1.label)
  end

  ## renderers

  @doc "Register a renderer for `kind` (`:message`/`:block`). `match_fun.(value)` -> bool; `render_fun.(assigns)` -> rendered."
  @spec register_renderer(kind(), (term() -> boolean()), render_fun(), keyword()) :: :ok
  def register_renderer(kind, match_fun, render_fun, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_renderer, kind, match_fun, render_fun, opts})

  @doc """
  The newest matching render function for `value` at `kind`.

  Returns `{:ok, render_fun}` or `:error` — no renderer matched, or the
  registry table is temporarily absent (recovery); callers fall back to the
  built-in rendering in both cases.
  """
  @spec renderer(kind(), term()) :: {:ok, render_fun()} | :error
  def renderer(kind, value) do
    {:renderer, kind}
    |> lookup_entries()
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.find_value(:error, fn e ->
      if safe_match(e.match, value), do: {:ok, e.render}
    end)
  end

  @doc "All registered renderers (`%{kind, owner, seq}`), newest first. Introspection only."
  @spec list_renderers() :: [map()]
  def list_renderers do
    {:renderer, :_}
    |> match_objects()
    |> Enum.map(fn {{:renderer, kind}, e} -> %{kind: kind, owner: e.owner, seq: e.seq} end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  ## components

  @doc "Register a slot component (`fun.(assigns) -> rendered`)."
  @spec register_component(atom(), render_fun(), keyword()) :: :ok
  def register_component(slot, fun, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_component, slot, fun, opts})

  @doc "Component render functions for a slot, newest first."
  @spec components(atom()) :: [render_fun()]
  def components(slot) do
    {:component, slot}
    |> lookup_entries()
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.map(& &1.fun)
  end

  @doc "All registered slot components (`%{slot, owner, seq}`), newest first. Introspection only."
  @spec list_components() :: [map()]
  def list_components do
    {:component, :_}
    |> match_objects()
    |> Enum.map(fn {{:component, slot}, e} -> %{slot: slot, owner: e.owner, seq: e.seq} end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  ## commands

  @doc "Register or replace a command-palette entry."
  @spec register_command(String.t(), keyword()) :: :ok
  def register_command(name, opts \\ []),
    do: GenServer.call(__MODULE__, {:register_command, name, opts})

  @doc "All registered command-palette entries."
  @spec list_commands() :: [map()]
  def list_commands do
    match_entries({:command, :_})
  end

  @doc "The command entry registered under `name`. Returns `{:ok, entry}` or `:error`."
  @spec fetch_command(String.t()) :: {:ok, map()} | :error
  def fetch_command(name) do
    case lookup_entries({:command, name}) do
      [] -> :error
      entries -> {:ok, Enum.max_by(entries, & &1.seq)}
    end
  end

  # The rescues wrap only the :ets call: while the named table is absent
  # (table-owner recovery) reads degrade to "nothing registered"; a malformed
  # entry is a real bug and must not be silently read as absence.
  defp lookup_entries(key) do
    key |> ets_lookup() |> Enum.map(&elem(&1, 1))
  end

  defp ets_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp match_objects(key_pattern) do
    :ets.match_object(@table, {key_pattern, :_})
  rescue
    ArgumentError -> []
  end

  defp match_entries(key_pattern) do
    key_pattern |> match_objects() |> Enum.map(&elem(&1, 1))
  end

  ## purge

  @doc """
  Remove every UI contribution made by `owner`.

  Pages and commands are last-write-wins per key, so an owner's registration may
  have displaced a seeded built-in (e.g. a replacement `"chat"` page). Any
  built-in left without an entry after the purge is restored, keeping overrides
  of built-ins as reversible as plain additions.
  """
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: GenServer.call(__MODULE__, {:unregister_owner, owner})

  @doc false
  @spec purge_extension_owner(term()) :: :ok
  def purge_extension_owner(owner) do
    :ok = Contributions.drop_owner(owner)

    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:unregister_owner, owner, false})
    end
  end

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    ensure_table()
    :ets.delete_all_objects(@table)
    reseed_displaced_builtins()
    replay_contributions()
    wire()
    {:ok, %{seq: next_seq()}}
  end

  @impl true
  def handle_call({:register_page, path, {mod, fun}, opts}, _from, state) do
    entry = %{
      path: path,
      mod: mod,
      fun: fun,
      label: opts[:label] || page_label(path),
      owner: opts[:owner],
      seq: state.seq
    }

    :ok = Contributions.record({:page, path}, entry)
    # last write wins per path
    :ets.match_delete(@table, {{:page, path}, :_})
    :ets.insert(@table, {{:page, path}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:register_renderer, kind, match, render, opts}, _from, state) do
    entry = %{match: match, render: render, owner: opts[:owner], seq: state.seq}
    :ok = Contributions.record({:renderer, kind}, entry)
    :ets.insert(@table, {{:renderer, kind}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:register_component, slot, fun, opts}, _from, state) do
    entry = %{fun: fun, owner: opts[:owner], seq: state.seq}
    :ok = Contributions.record({:component, slot}, entry)
    :ets.insert(@table, {{:component, slot}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:register_command, name, opts}, _from, state) do
    entry = %{
      name: name,
      owner: opts[:owner],
      handler: opts[:handler],
      label: opts[:label] || name,
      seq: state.seq
    }

    :ok = Contributions.record({:command, name}, entry)
    :ets.match_delete(@table, {{:command, name}, :_})
    :ets.insert(@table, {{:command, name}, entry})
    {:reply, :ok, bump(state)}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    :ok = Contributions.drop_owner(owner)
    {:reply, :ok, unregister_owner_entries(owner, state)}
  end

  def handle_call({:unregister_owner, owner, false}, _from, state) do
    {:reply, :ok, unregister_owner_entries(owner, state)}
  end

  defp unregister_owner_entries(owner, state) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {_key, entry} = obj ->
      if Map.get(entry, :owner) == owner, do: :ets.delete_object(@table, obj)
    end)

    reseed_displaced_builtins()
    state
  end

  # ---- internals ------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
        :ok

      _table ->
        :ok
    end
  end

  defp next_seq do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, entry} -> Map.get(entry, :seq, -1) end)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp replay_contributions do
    Contributions.list()
    |> Enum.each(&replay_contribution/1)
  end

  defp replay_contribution({{kind, _name} = key, entry}) when kind in [:page, :command] do
    :ets.match_delete(@table, {key, :_})
    :ets.insert(@table, {key, entry})
  end

  defp replay_contribution(entry), do: :ets.insert(@table, entry)

  defp bump(state), do: %{state | seq: state.seq + 1}

  defp builtin_pages do
    [
      %{path: "chat", mod: CatalystWeb.Pages.ChatPage, label: "Chat"},
      %{path: "prompts", mod: CatalystWeb.Pages.PromptsPage, label: "Models & Prompts"},
      %{path: "workflows", mod: CatalystWeb.Pages.WorkflowsPage, label: "Workflows"},
      %{path: "extensions", mod: CatalystWeb.Pages.ExtensionsPage, label: "Extensions"},
      %{path: "computer", mod: CatalystWeb.Pages.ComputerPage, label: "Computer"}
    ]
    |> Enum.map(&Map.merge(&1, %{fun: :render, owner: nil, seq: 0}))
  end

  # Built-in chat commands live in the same registry extensions write to
  # (dogfooding it, and making them introspectable/overridable): `ShellLive`
  # dispatches every "/name [arg]" message through `fetch_command/1`.
  defp builtin_commands do
    [
      %{
        name: "cd",
        owner: nil,
        handler: &CatalystWeb.ShellLive.Commands.change_directory/2,
        label: "/cd <path> — change the session working directory",
        seq: 0
      }
    ]
  end

  defp reseed_displaced_builtins do
    Enum.each(builtin_pages(), fn page ->
      if :ets.lookup(@table, {:page, page.path}) == [],
        do: :ets.insert(@table, {{:page, page.path}, page})
    end)

    Enum.each(builtin_commands(), fn cmd ->
      if :ets.lookup(@table, {:command, cmd.name}) == [],
        do: :ets.insert(@table, {{:command, cmd.name}, cmd})
    end)
  end

  @doc false
  @spec register_extension_renderer(ExtensionAPI.t(), kind(), function(), render_fun()) :: :ok
  def register_extension_renderer(%ExtensionAPI{owner: owner}, kind, match, fun) do
    register_renderer(kind, match, fun, owner: owner)
  end

  @doc false
  @spec register_extension_component(ExtensionAPI.t(), atom(), render_fun(), keyword()) :: :ok
  def register_extension_component(%ExtensionAPI{owner: owner}, slot, fun, opts) do
    register_component(slot, fun, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_page(ExtensionAPI.t(), String.t(), target(), keyword()) :: :ok
  def register_extension_page(%ExtensionAPI{owner: owner}, path, target, opts) do
    # Keyword.put, not put_new: a spoofed :owner in extension opts would detach
    # the registration from its real owner and survive that owner's purge.
    register_page(path, target, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_command(ExtensionAPI.t(), String.t(), keyword()) :: :ok
  def register_extension_command(%ExtensionAPI{owner: owner}, name, opts) do
    register_command(name, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec activate_renderer_contribution(
          ExtensionAPI.t(),
          Catalyst.Runtime.Contribution.t(),
          keyword()
        ) :: :ok
  def activate_renderer_contribution(
        api,
        %Catalyst.Runtime.Contribution{
          value: %{kind: kind, match: match, function: function}
        },
        _opts
      )
      when is_atom(kind) and is_function(match, 1) and is_function(function),
      do: register_extension_renderer(api, kind, match, function)

  def activate_renderer_contribution(_api, contribution, _opts),
    do: invalid_contribution(contribution)

  @doc false
  @spec activate_component_contribution(
          ExtensionAPI.t(),
          Catalyst.Runtime.Contribution.t(),
          keyword()
        ) :: :ok
  def activate_component_contribution(
        api,
        %Catalyst.Runtime.Contribution{
          value: %{slot: slot, function: function, opts: component_opts}
        },
        _opts
      )
      when is_atom(slot) and is_function(function) and is_list(component_opts),
      do: register_extension_component(api, slot, function, component_opts)

  def activate_component_contribution(_api, contribution, _opts),
    do: invalid_contribution(contribution)

  @doc false
  @spec activate_page_contribution(
          ExtensionAPI.t(),
          Catalyst.Runtime.Contribution.t(),
          keyword()
        ) :: :ok
  def activate_page_contribution(
        api,
        %Catalyst.Runtime.Contribution{
          value: %{path: path, target: target, opts: page_opts}
        },
        _opts
      )
      when is_binary(path) and valid_page_target(target) and is_list(page_opts),
      do: register_extension_page(api, path, target, page_opts)

  def activate_page_contribution(_api, contribution, _opts),
    do: invalid_contribution(contribution)

  @doc false
  @spec activate_command_contribution(
          ExtensionAPI.t(),
          Catalyst.Runtime.Contribution.t(),
          keyword()
        ) :: :ok
  def activate_command_contribution(
        api,
        %Catalyst.Runtime.Contribution{value: %{name: name, opts: command_opts}},
        _opts
      )
      when is_binary(name) and is_list(command_opts),
      do: register_extension_command(api, name, command_opts)

  def activate_command_contribution(_api, contribution, _opts),
    do: invalid_contribution(contribution)

  defp invalid_contribution(%Catalyst.Runtime.Contribution{} = contribution),
    do: {:error, {:invalid_contribution, contribution.point, contribution.value}}

  defp invalid_contribution(contribution),
    do: {:error, {:invalid_contribution, :ui, contribution}}

  defp wire do
    :ok =
      ExtensionAPI.register_extension_point(
        %{id: "ui.renderer", cardinality: :many},
        {__MODULE__, :activate_renderer_contribution},
        {:host, :web}
      )

    :ok =
      ExtensionAPI.register_extension_point(
        %{id: "ui.component", cardinality: :many},
        {__MODULE__, :activate_component_contribution},
        {:host, :web}
      )

    :ok =
      ExtensionAPI.register_extension_point(
        %{id: "ui.page", cardinality: :many},
        {__MODULE__, :activate_page_contribution},
        {:host, :web}
      )

    :ok =
      ExtensionAPI.register_extension_point(
        %{id: "ui.command", cardinality: :many},
        {__MODULE__, :activate_command_contribution},
        {:host, :web}
      )

    ExtensionAPI.register_purger(&__MODULE__.purge_extension_owner/1)
    Catalyst.Extensions.register_host(:web, :registry, self())
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
