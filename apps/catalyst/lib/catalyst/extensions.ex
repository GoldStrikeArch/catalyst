defmodule Catalyst.Extensions do
  @moduledoc """
  Runtime extension registry — the mechanism behind "self-developing" Catalyst.

  Holds the live set of tool modules in an ETS table, and loads extension source
  files (`*.ex` in `dir/0`) at runtime with `Code.compile_file/1`. Because the
  Elixir compiler ships in an OTP release, this works inside a packaged binary
  too — the binary stays immutable while new modules are loaded into the running
  VM from a user-writable directory.

  A loaded file can contribute more than tools. Each compiled module is
  classified:

    * a module exporting `setup/1` (`use Catalyst.Extension`) is run as an
      **extension** — its `setup/1` registers any mix of tools, loop hooks, event
      observers, providers, and UI renderers/components/pages via
      `Catalyst.ExtensionAPI`;
    * a module shaped like a tool (`name/0` + `parameters/0` + `execute/2`) that
      is *not* an extension is **auto-registered** as a tool (backward compatible
      with tool-only extension files).

  Everything a file contributes is tagged with the file's `owner` id (its
  sanitized basename). Reloading a file first **purges** that owner's prior
  contributions (tools here, hooks/providers/UI via `ExtensionAPI.purge_owner/1`),
  so reloads are idempotent. Registration is **committed only after** the file
  compiles and classifies cleanly, so a broken file never partially registers.

  Set `CATALYST_SAFE_MODE=1` (or `config :catalyst, :safe_mode, true`) to skip
  loading extensions at boot — only built-ins are seeded, so a bad extension can't
  brick startup. Safe mode also engages **automatically**: a boot-marker file
  (`Catalyst.Extensions.BootGuard`) detects that the previous boot died while its
  extensions were active and skips loading, so a bricking extension is recovered
  by a plain relaunch. `boot_status/0` reports it; a successful explicit
  `load_all/0` (the `reload_extensions` tool) clears it.

  Purging an owner also undoes its **module definitions**: modules its file
  compiled are removed from the VM, and any module that shadowed one shipping
  with the app is restored from the original beam on the code path — so
  overriding core behavior is as reversible as registering a tool.
  """

  use GenServer
  require Logger

  alias Catalyst.{Extension, ExtensionAPI, Hooks}
  alias Catalyst.Extensions.{BootGuard, Processes}

  @table :catalyst_tools

  # Process-dictionary key (server process only) collecting tools registered
  # from a setup/1 that is executing inside this GenServer — see wire_core_kinds.
  @setup_tools {__MODULE__, :setup_tools}

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

  @doc "Register a tool module (last write wins). `opts[:owner]` tags it for purge-on-reload."
  def register_tool(module, opts \\ []), do: GenServer.call(__MODULE__, {:register, module, opts})

  @doc """
  Compile an extension source file and apply its contributions (tools + anything
  its `setup/1` registers). Returns `{:ok, summary}` or `{:error, reason}`.
  """
  def load_file(path), do: GenServer.call(__MODULE__, {:load_file, path}, 30_000)

  @doc "(Re)load all `*.ex` files in the extensions directory."
  def load_all, do: GenServer.call(__MODULE__, :load_all, 60_000)

  @doc """
  Re-run the boot-time load after another app wires more extension kinds (the
  web app wires `:renderer`/`:component`/`:page` after `:catalyst` boots).

  No-ops in safe mode: unlike `load_all/0` it never clears crash-detected safe
  mode or touches the boot marker, so a bricking extension can't be re-loaded
  by a later app's boot. Returns `{:ok, summaries}` or `{:skipped, status}`.
  """
  def reload_after_wiring do
    case boot_status() do
      :ok -> GenServer.call(__MODULE__, :reload_after_wiring, 60_000)
      status -> {:skipped, status}
    end
  end

  @doc "Remove every contribution made by `owner` (tools here + hooks/providers/UI)."
  def uninstall(owner), do: GenServer.call(__MODULE__, {:uninstall, owner})

  @doc "Directory holding extension source files."
  def dir,
    do: Application.get_env(:catalyst, :extensions_dir) || Path.expand("~/.catalyst/extensions")

  @doc "Resolve a session's `tools` setting into a concrete module list (per turn)."
  def resolve(tools) when is_list(tools), do: tools
  def resolve(fun) when is_function(fun, 0), do: fun.()
  def resolve(_), do: tools()

  @doc "Whether extensions are skipped at boot (safe mode)."
  def safe_mode? do
    System.get_env("CATALYST_SAFE_MODE") in ~w(1 true) or
      Application.get_env(:catalyst, :safe_mode, false)
  end

  @doc "Boot status: `:ok`, or `{:safe_mode, :env | :crash_detected}` when extensions were skipped."
  def boot_status, do: :persistent_term.get({__MODULE__, :boot_status}, :ok)

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    seed_builtins()
    wire_core_kinds()
    ensure_guide()
    Catalyst.Extensions.Versioning.ensure_repo(dir())

    state = %{contrib: %{}, modules: %{}}

    cond do
      safe_mode?() ->
        put_boot_status({:safe_mode, :env})
        Logger.info("[extensions] safe mode (CATALYST_SAFE_MODE) — skipping extension load")
        {:ok, state}

      BootGuard.crashed_last_boot?() ->
        put_boot_status({:safe_mode, :crash_detected})

        Logger.warning(
          "[extensions] previous boot died while extensions were active — skipping extension " <>
            "load. Fix the files in #{dir()} and run the reload_extensions tool."
        )

        {:ok, state}

      true ->
        put_boot_status(:ok)
        BootGuard.mark_booting()
        {:ok, state, {:continue, :load_all}}
    end
  end

  @impl true
  def handle_continue(:load_all, state) do
    {_result, state} = do_load_all(state)
    # If the app survives the stabilization window, this boot's extensions are
    # considered safe; dying before the timer fires leaves the marker at
    # "booting", which the next boot reads as crash-detected safe mode.
    Process.send_after(self(), :mark_boot_ok, boot_stable_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(:mark_boot_ok, state) do
    BootGuard.mark_ok()
    {:noreply, state}
  end

  @impl true
  def handle_call({:register, module, opts}, _from, state) do
    {result, state} = do_register(module, opts, state)
    {:reply, result, state}
  end

  def handle_call({:load_file, path}, _from, state) do
    {result, state} = do_load_file(path, state)
    {:reply, result, state}
  end

  def handle_call(:load_all, _from, state) do
    {result, state} = do_load_all(state)
    # An explicit reload means a human/agent is at the wheel: a successful pass
    # clears crash-detected safe mode for the next boot.
    BootGuard.mark_ok()
    put_boot_status(:ok)
    {:reply, result, state}
  end

  # Same load as :load_all but for the automatic boot-time rewire: it must NOT
  # mark boot OK — that would defeat crash-loop detection and end the
  # stabilization window early. Only the explicit reload clears the guard.
  def handle_call(:reload_after_wiring, _from, state) do
    {result, state} = do_load_all(state)
    {:reply, result, state}
  end

  def handle_call({:uninstall, owner}, _from, state) do
    {:reply, :ok, purge_owner(owner, state)}
  end

  # ---- boot helpers ---------------------------------------------------------

  defp seed_builtins do
    Enum.each(Catalyst.Tools.Registry.default_tools(), &insert/1)
  end

  # Wire the extension kinds that core can back, and the hooks owner-purger.
  # Provider (E3) and UI (E5) kinds/purgers are wired by their own subsystems.
  defp wire_core_kinds do
    ExtensionAPI.register_kind(:tool, fn api, module ->
      # setup/1 runs inside this GenServer, so a call to self would deadlock
      # (and crash-loop the server on timeout): register inline in that case,
      # stashing the module so do_load_file can fold it into owner tracking.
      if self() == Process.whereis(__MODULE__) do
        case insert(module) do
          {:ok, _} = ok ->
            Process.put(@setup_tools, [module | Process.get(@setup_tools, [])])
            ok

          err ->
            err
        end
      else
        register_tool(module, owner: api.owner)
      end
    end)

    ExtensionAPI.register_kind(:hook, fn api, point, fun, opts ->
      Hooks.register(point, fun, Keyword.put_new(opts, :owner, api.owner))
    end)

    ExtensionAPI.register_kind(:event, fn api, fun, opts ->
      Hooks.on(fun, Keyword.put_new(opts, :owner, api.owner))
    end)

    # Extension-owned processes live under a per-owner supervisor, so a purge
    # tears down the whole subtree (including restarted children).
    ExtensionAPI.register_kind(:process, fn api, child_spec ->
      Processes.start_child(api.owner || "anonymous", child_spec)
    end)

    ExtensionAPI.register_purger(&Hooks.unregister/1)
    ExtensionAPI.register_purger(&Processes.stop_owner/1)
  end

  # Publish the bundled self-extension guide to a stable, agent-readable path.
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

  # ---- loading --------------------------------------------------------------

  defp do_load_all(state) do
    paths =
      case File.dir?(dir()) do
        true -> dir() |> Path.join("*.ex") |> Path.wildcard()
        false -> []
      end

    # Purge contributions whose source file is gone — e.g. removed by a
    # rollback or by hand. Without this, reverted code stays registered (and
    # callable) until the next restart. Module tracking counts as a footprint
    # too: a file that only redefines modules registers nothing in contrib.
    live_owners = MapSet.new(paths, &ext_id/1)

    state =
      (Map.keys(state.contrib) ++ Map.keys(state.modules))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(live_owners, &1))
      |> Enum.reduce(state, fn owner, st -> purge_owner(owner, st) end)

    {summaries, state} =
      Enum.reduce(paths, {[], state}, fn path, {acc, st} ->
        case do_load_file(path, st) do
          {{:ok, summary}, st} ->
            {[summary | acc], st}

          {{:error, reason}, st} ->
            Logger.warning("[extensions] failed to load #{path}: #{inspect(reason)}")
            {acc, st}
        end
      end)

    {{:ok, Enum.reverse(summaries)}, state}
  end

  defp do_load_file(path, state) do
    owner = ext_id(path)

    # Compile + classify FIRST: a broken file fails here, before we touch any
    # registry, so a failed reload neither registers nor drops the prior version.
    modules = path |> Code.compile_file() |> Enum.map(&elem(&1, 0))
    {ext_mods, tool_mods} = classify(modules)

    # Replace this owner's prior contributions, then commit the new ones. Modules
    # the new file still defines were just redefined by the compile above and must
    # survive the purge; ones it dropped are restored/removed.
    state = purge_owner(owner, state, keep_modules: modules)
    state = put_in(state.modules[owner], modules)
    state = Enum.reduce(tool_mods, state, fn mod, st -> register_owned(mod, owner, st) end)
    api = ExtensionAPI.new(owner, path)

    Process.put(@setup_tools, [])

    Enum.each(ext_mods, fn mod ->
      try do
        mod.setup(api)
      rescue
        e ->
          Logger.warning(
            "[extensions] #{owner}: #{inspect(mod)}.setup/1 raised: #{Exception.message(e)}"
          )
      catch
        kind, reason ->
          Logger.warning(
            "[extensions] #{owner}: #{inspect(mod)}.setup/1 #{kind}: #{inspect(reason)}"
          )
      end
    end)

    setup_tools = Process.delete(@setup_tools) || []
    state = Enum.reduce(setup_tools, state, fn mod, st -> track(mod, owner, st) end)

    summary = %{owner: owner, tools: Enum.map(tool_mods, & &1.name()), extensions: ext_mods}
    {{:ok, summary}, state}
  rescue
    e -> {{:error, Exception.message(e)}, state}
  catch
    kind, reason -> {{:error, {kind, reason}}, state}
  end

  # Extensions take precedence: a module that is both is treated as an extension.
  defp classify(modules) do
    Enum.reduce(modules, {[], []}, fn mod, {exts, tools} ->
      cond do
        Extension.extension_module?(mod) -> {[mod | exts], tools}
        tool_module?(mod) -> {exts, [mod | tools]}
        true -> {exts, tools}
      end
    end)
    |> then(fn {exts, tools} -> {Enum.reverse(exts), Enum.reverse(tools)} end)
  end

  # ---- registration + owner tracking ----------------------------------------

  defp do_register(module, opts, state) do
    case insert(module) do
      {:ok, _} = ok -> {ok, track(module, opts[:owner], state)}
      err -> {err, state}
    end
  end

  defp register_owned(module, owner, state) do
    insert(module)
    track(module, owner, state)
  end

  defp track(_module, nil, state), do: state

  defp track(module, owner, state) do
    names = Map.get(state.contrib, owner, MapSet.new())
    put_in(state.contrib[owner], MapSet.put(names, module.name()))
  end

  defp insert(module) do
    if tool_module?(module) do
      :ets.insert(@table, {module.name(), module})
      {:ok, module}
    else
      {:error, {:not_a_tool, module}}
    end
  end

  # Remove an owner's tools from the table (restoring a built-in if one was
  # shadowed), drop its hooks/providers/UI/processes via purgers, undo its module
  # definitions (minus `keep_modules`), and clear its tracking.
  defp purge_owner(owner, state, opts \\ []) do
    keep = MapSet.new(Keyword.get(opts, :keep_modules, []))

    state.modules
    |> Map.get(owner, [])
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> Enum.each(&restore_module/1)

    names = Map.get(state.contrib, owner, MapSet.new())
    builtins = builtins_index()

    Enum.each(names, fn name ->
      :ets.delete(@table, name)

      case Map.get(builtins, name) do
        nil -> :ok
        mod -> :ets.insert(@table, {name, mod})
      end
    end)

    ExtensionAPI.purge_owner(owner)

    %{
      state
      | contrib: Map.delete(state.contrib, owner),
        modules: Map.delete(state.modules, owner)
    }
  end

  # Drop an extension's version of a module from the VM. If an original beam
  # exists on the code path (the extension shadowed a module shipping with the
  # app), reload it; otherwise the module simply ceases to exist. Processes
  # still executing the old code are killed by the purge — same rule as any
  # hot reload.
  defp restore_module(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)

    case :code.load_file(mod) do
      {:module, ^mod} ->
        Logger.info("[extensions] restored original #{inspect(mod)}")

      {:error, :nofile} ->
        :ok

      {:error, reason} ->
        Logger.warning("[extensions] could not restore #{inspect(mod)}: #{inspect(reason)}")
    end
  catch
    kind, reason ->
      Logger.warning("[extensions] purging #{inspect(mod)} #{kind}: #{inspect(reason)}")
  end

  defp put_boot_status(status), do: :persistent_term.put({__MODULE__, :boot_status}, status)

  defp boot_stable_ms, do: Application.get_env(:catalyst, :boot_stable_ms, 10_000)

  defp builtins_index do
    Map.new(Catalyst.Tools.Registry.default_tools(), &{&1.name(), &1})
  end

  defp ext_id(path) do
    path |> Path.basename(".ex") |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  # Duck-typed: a tool exports name/0, parameters/0 and execute/2.
  defp tool_module?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :name, 0) and
      function_exported?(module, :parameters, 0) and
      function_exported?(module, :execute, 2)
  end
end
