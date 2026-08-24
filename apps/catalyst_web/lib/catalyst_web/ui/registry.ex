defmodule CatalystWeb.UI.Registry do
  @moduledoc """
  Domain facade for runtime UI contributions.

  Pages, renderers, components, and commands share
  `Catalyst.Runtime.Registry` with the core extension kinds. This module owns
  UI-specific validation, ordering, and built-in fallbacks; it does not own a
  process or a second persistence layer.

  Extensions register through `Catalyst.ExtensionAPI`. Contributions are tagged
  with their extension owner and are removed by the shared owner-purge path.
  """

  require Logger

  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.Registry, as: Runtime

  @page_kind :ui_page
  @renderer_kind :ui_renderer
  @component_kind :ui_component
  @command_kind :ui_command
  @ui_kinds [@page_kind, @renderer_kind, @component_kind, @command_kind]

  @type kind :: :message | :block
  @type target :: module() | {module(), atom()}
  @type render_fun :: (map() -> Phoenix.LiveView.Rendered.t())

  @doc "Register (replace) a page at `path`. `target` is a module (uses `render/1`) or `{module, fun}`."
  @spec register_page(String.t(), target(), keyword()) :: :ok | {:error, term()}
  def register_page(path, target, opts \\ []) do
    {mod, fun} = normalize_target(target)
    seq = sequence()

    entry = %{
      path: path,
      mod: mod,
      fun: fun,
      label: opts[:label] || page_label(path),
      owner: opts[:owner],
      seq: seq
    }

    Runtime.put(@page_kind, path, entry, opts)
  end

  @doc "The `{module, function}` registered for a page path. Returns `{:ok, {mod, fun}}` or `:error`."
  @spec fetch_page(String.t()) :: {:ok, {module(), atom()}} | :error
  def fetch_page(path) do
    case runtime_value(@page_kind, path) || builtin_page(path) do
      %{mod: mod, fun: fun} -> {:ok, {mod, fun}}
      nil -> :error
    end
  end

  @doc "All registered pages (`%{path, label, ...}`), sorted by label."
  @spec list_pages() :: [map()]
  def list_pages do
    builtin_pages()
    |> Map.new(&{&1.path, &1})
    |> Map.merge(runtime_values(@page_kind, & &1.path))
    |> Map.values()
    |> Enum.sort_by(& &1.label)
  end

  @doc "Dispatch an otherwise-unhandled LiveView event to the active page module."
  @spec dispatch_event(String.t(), String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
          | {:reply, map(), Phoenix.LiveView.Socket.t()}
  def dispatch_event(path, event, params, socket) do
    dispatch_page(path, :handle_event, [event, params, socket], socket)
  end

  @doc "Dispatch an otherwise-unhandled process message to the active page module."
  @spec dispatch_info(String.t(), term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def dispatch_info(path, message, socket) do
    dispatch_page(path, :handle_info, [message, socket], socket)
  end

  @doc "Dispatch an otherwise-unhandled `start_async/3` result to the active page module."
  @spec dispatch_async(String.t(), term(), term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def dispatch_async(path, name, result, socket) do
    dispatch_page(path, :handle_async, [name, result, socket], socket)
  end

  @doc "Register a renderer for `kind` (`:message`/`:block`)."
  @spec register_renderer(kind(), (term() -> boolean()), render_fun(), keyword()) ::
          :ok | {:error, term()}
  def register_renderer(kind, match_fun, render_fun, opts \\ []) do
    seq = sequence()
    entry = %{match: match_fun, render: render_fun, owner: opts[:owner], seq: seq}
    Runtime.put(@renderer_kind, {kind, seq}, entry, opts)
  end

  @doc "Return the newest matching render function for `value` at `kind`."
  @spec renderer(kind(), term()) :: {:ok, render_fun()} | :error
  def renderer(kind, value) do
    @renderer_kind
    |> runtime_values()
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.find_value(:error, fn entry ->
      case safe_match(entry.match, value) do
        true -> {:ok, entry.render}
        false -> nil
      end
    end)
  end

  @doc "All registered renderers (`%{kind, owner, seq}`), newest first."
  @spec list_renderers() :: [map()]
  def list_renderers do
    @renderer_kind
    |> Runtime.list()
    |> Enum.map(fn %{key: {kind, _seq}, owner: owner, value: entry} ->
      %{kind: kind, owner: display_owner(owner), seq: entry.seq}
    end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  @doc "Register a slot component (`fun.(assigns) -> rendered`)."
  @spec register_component(atom(), render_fun(), keyword()) :: :ok | {:error, term()}
  def register_component(slot, fun, opts \\ []) do
    seq = sequence()
    entry = %{fun: fun, owner: opts[:owner], seq: seq}
    Runtime.put(@component_kind, {slot, seq}, entry, opts)
  end

  @doc "Component render functions for a slot, newest first."
  @spec components(atom()) :: [render_fun()]
  def components(slot) do
    @component_kind
    |> runtime_values()
    |> Enum.filter(&(&1.slot == slot))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.map(& &1.fun)
  end

  @doc "All registered slot components (`%{slot, owner, seq}`), newest first."
  @spec list_components() :: [map()]
  def list_components do
    @component_kind
    |> Runtime.list()
    |> Enum.map(fn %{key: {slot, _seq}, owner: owner, value: entry} ->
      %{slot: slot, owner: display_owner(owner), seq: entry.seq}
    end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  @doc "Register or replace a command-palette entry."
  @spec register_command(String.t(), keyword()) :: :ok | {:error, term()}
  def register_command(name, opts \\ []) do
    entry = %{
      name: name,
      owner: opts[:owner],
      handler: opts[:handler],
      label: opts[:label] || name,
      seq: sequence()
    }

    Runtime.put(@command_kind, name, entry, opts)
  end

  @doc "All registered command-palette entries."
  @spec list_commands() :: [map()]
  def list_commands do
    builtin_commands()
    |> Map.new(&{&1.name, &1})
    |> Map.merge(runtime_values(@command_kind, & &1.name))
    |> Map.values()
  end

  @doc "The command entry registered under `name`. Returns `{:ok, entry}` or `:error`."
  @spec fetch_command(String.t()) :: {:ok, map()} | :error
  def fetch_command(name) do
    case runtime_value(@command_kind, name) || builtin_command(name) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Remove every UI contribution made by `owner`."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: Runtime.purge_owner(owner, @ui_kinds)

  @doc false
  @spec register_extension_renderer(ExtensionAPI.t(), kind(), function(), render_fun()) ::
          :ok | {:error, term()}
  def register_extension_renderer(%ExtensionAPI{owner: owner}, kind, match, fun) do
    register_renderer(kind, match, fun, owner: owner)
  end

  @doc false
  @spec register_extension_component(ExtensionAPI.t(), atom(), render_fun(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_component(%ExtensionAPI{owner: owner}, slot, fun, opts) do
    register_component(slot, fun, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_page(ExtensionAPI.t(), String.t(), target(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_page(%ExtensionAPI{owner: owner}, path, target, opts) do
    register_page(path, target, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_command(ExtensionAPI.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_command(%ExtensionAPI{owner: owner}, name, opts) do
    register_command(name, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec wire_extension_api() :: :ok
  def wire_extension_api do
    ExtensionAPI.register_kind(:renderer, &__MODULE__.register_extension_renderer/4)
    ExtensionAPI.register_kind(:component, &__MODULE__.register_extension_component/4)
    ExtensionAPI.register_kind(:page, &__MODULE__.register_extension_page/4)
    ExtensionAPI.register_kind(:command, &__MODULE__.register_extension_command/3)
  end

  defp runtime_value(kind, key) do
    case Runtime.fetch(kind, key) do
      {:ok, value, owner} -> Map.put(value, :owner, display_owner(owner))
      :error -> nil
    end
  end

  defp runtime_values(kind) do
    Enum.map(Runtime.list(kind), fn %{key: key, owner: owner, value: value} ->
      value
      |> Map.put(:owner, display_owner(owner))
      |> Map.put_new(:kind, key_kind(key))
      |> Map.put_new(:slot, key_kind(key))
    end)
  end

  defp runtime_values(kind, key_fun), do: Map.new(runtime_values(kind), &{key_fun.(&1), &1})

  defp key_kind({kind, _seq}), do: kind
  defp key_kind(_key), do: nil

  defp display_owner(:host), do: nil
  defp display_owner(owner), do: owner

  defp sequence, do: System.unique_integer([:positive, :monotonic])

  defp builtin_page(path), do: Enum.find(builtin_pages(), &(&1.path == path))
  defp builtin_command(name), do: Enum.find(builtin_commands(), &(&1.name == name))

  defp dispatch_page(path, callback, args, socket) do
    with {:ok, {module, _render}} <- fetch_page(path),
         true <- function_exported?(module, callback, length(args)) do
      module
      |> apply(callback, args)
      |> valid_dispatch_result(socket, module, callback)
    else
      _missing_callback -> {:noreply, socket}
    end
  rescue
    exception ->
      log_dispatch_failure(path, callback, Exception.format(:error, exception, __STACKTRACE__))
      {:noreply, socket}
  catch
    kind, reason ->
      log_dispatch_failure(path, callback, Exception.format(kind, reason, __STACKTRACE__))
      {:noreply, socket}
  end

  defp valid_dispatch_result({:noreply, %Phoenix.LiveView.Socket{}} = result, _, _, _), do: result

  defp valid_dispatch_result(
         {:reply, reply, %Phoenix.LiveView.Socket{}} = result,
         _socket,
         _module,
         :handle_event
       )
       when is_map(reply),
       do: result

  defp valid_dispatch_result(result, socket, module, callback) do
    Logger.warning(
      "[ui] page #{inspect(module)}.#{callback} returned invalid result: #{inspect(result)}"
    )

    {:noreply, socket}
  end

  defp log_dispatch_failure(path, callback, reason) do
    Logger.warning("[ui] page #{inspect(path)} #{callback} failed: #{reason}")
  end

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

  defp normalize_target({mod, fun}) when is_atom(mod) and is_atom(fun), do: {mod, fun}
  defp normalize_target(mod) when is_atom(mod), do: {mod, :render}

  defp page_label(path), do: path |> String.replace("_", " ") |> String.capitalize()

  defp safe_match(match, value) do
    match.(value)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end
end
