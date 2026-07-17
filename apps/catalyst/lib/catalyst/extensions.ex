defmodule Catalyst.Extensions do
  @moduledoc """
  Runtime extension registry — the mechanism behind "self-developing" Catalyst.

  Holds the live set of tool modules in an ETS table: the built-ins are seeded at
  boot, and extensions (Elixir source files in `extensions_dir`) are compiled and
  loaded **at runtime** with `Code.compile_file/1`. Because the Elixir compiler
  is part of an OTP release, this works inside a packaged binary too — the binary
  stays immutable while new modules are loaded into the running VM from a
  user-writable directory.

  The agent can therefore write a new tool and call `load_file/1` to use it with
  no restart (see `Catalyst.Tools.DevelopTool`). Loaded modules are not persisted
  in the VM across restarts; the source files are, and are re-loaded on boot.
  """

  use GenServer
  require Logger

  @table :catalyst_tools

  # ---- API ------------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "All registered tool modules."
  def tools do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  rescue
    ArgumentError -> Catalyst.Tools.Registry.default_tools()
  end

  @doc "Look up a tool module by its tool name."
  def fetch(name) do
    case :ets.lookup(@table, name) do
      [{^name, module}] -> module
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Names of all registered tools."
  def names, do: Enum.map(tools(), & &1.name())

  @doc "Register a tool module (last write wins, so reloading a file updates it)."
  def register_tool(module), do: GenServer.call(__MODULE__, {:register, module})

  @doc "Compile an extension source file and register the tool modules it defines."
  def load_file(path), do: GenServer.call(__MODULE__, {:load_file, path}, 30_000)

  @doc "(Re)load all `*.ex` files in the extensions directory."
  def load_all, do: GenServer.call(__MODULE__, :load_all, 60_000)

  @doc "Directory holding extension source files."
  def dir, do: Application.get_env(:catalyst, :extensions_dir) || Path.expand("~/.catalyst/extensions")

  @doc "Resolve a session's `tools` setting into a concrete module list (per turn)."
  def resolve(tools) when is_list(tools), do: tools
  def resolve(fun) when is_function(fun, 0), do: fun.()
  def resolve(_), do: tools()

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    seed_builtins()
    ensure_guide()
    {:ok, %{}, {:continue, :load_all}}
  end

  @impl true
  def handle_continue(:load_all, state) do
    do_load_all()
    {:noreply, state}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    {:reply, insert(module), state}
  end

  def handle_call({:load_file, path}, _from, state) do
    {:reply, do_load_file(path), state}
  end

  def handle_call(:load_all, _from, state) do
    {:reply, do_load_all(), state}
  end

  # ---- internals ------------------------------------------------------------

  defp seed_builtins do
    Enum.each(Catalyst.Tools.Registry.default_tools(), &insert/1)
  end

  # Publish the bundled self-extension guide to a stable, agent-readable path.
  # Refreshed each boot so it tracks the app version.
  defp ensure_guide do
    src = Application.app_dir(:catalyst, "priv/guide.md")

    if File.exists?(src) do
      dest = Path.join(Path.dirname(dir()), "guide.md")
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(src, dest)
    end
  rescue
    _ -> :ok
  end

  defp do_load_all do
    dir = dir()

    if File.dir?(dir) do
      dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case do_load_file(path) do
          {:ok, mods} ->
            mods

          {:error, reason} ->
            Logger.warning("[extensions] failed to load #{path}: #{inspect(reason)}")
            []
        end
      end)
      |> then(&{:ok, &1})
    else
      {:ok, []}
    end
  end

  defp do_load_file(path) do
    compiled = Code.compile_file(path)
    tool_modules = compiled |> Enum.map(&elem(&1, 0)) |> Enum.filter(&tool_module?/1)
    Enum.each(tool_modules, &insert/1)
    {:ok, tool_modules}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp insert(module) do
    if tool_module?(module) do
      :ets.insert(@table, {module.name(), module})
      {:ok, module}
    else
      {:error, {:not_a_tool, module}}
    end
  end

  # Duck-typed: a tool exports name/0, parameters/0 and execute/2.
  defp tool_module?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :name, 0) and
      function_exported?(module, :parameters, 0) and
      function_exported?(module, :execute, 2)
  end
end
