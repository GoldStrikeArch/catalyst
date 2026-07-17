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
  so reloads are idempotent. A file that fails to **compile** registers nothing —
  compile + classify run before any registry is touched, and the prior version
  stays active. Because `Code.compile_file/1` defines modules sequentially, a
  multi-module file can fail with its first modules already redefined in the VM:
  the failed load purges any module it newly introduced (not previously loaded
  and not tracked by any owner); modules that pre-existed are left alone — for a
  reinstall over an existing file, `Catalyst.Extensions.Installer` re-loads the
  restored prior source so the VM runs the old definitions again. Once a file
  compiles, its registration is committed even if a `setup/1` raises mid-way:
  whatever it registered before raising stays registered (owner-tagged, so the
  next reload or uninstall purges it cleanly).

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

  @typedoc "Per-file load summary. `:conflicts` is present only when this file redefines modules another loaded file also defines."
  @type summary :: %{
          required(:owner) => String.t(),
          required(:tools) => [String.t()],
          required(:extensions) => [module()],
          optional(:conflicts) => [{String.t(), [module()]}]
        }

  @typedoc "Result of a full directory load: per-file summaries plus per-file failures."
  @type load_result :: %{loaded: [summary()], failed: [{Path.t(), term()}]}

  # ---- API ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "All registered tool modules."
  @spec tools() :: [module()]
  def tools do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  rescue
    ArgumentError -> Catalyst.Tools.Registry.default_tools()
  end

  @doc "Look up a tool module by its tool name. Returns `{:ok, module}` or `:error`."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case :ets.lookup(@table, name) do
      [{^name, module}] -> {:ok, module}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Names of all registered tools."
  @spec names() :: [String.t()]
  def names, do: Enum.map(tools(), & &1.name())

  @doc "Register a tool module (last write wins). `opts[:owner]` tags it for purge-on-reload."
  @spec register_tool(module(), keyword()) :: {:ok, module()} | {:error, term()}
  def register_tool(module, opts \\ []), do: GenServer.call(__MODULE__, {:register, module, opts})

  @doc """
  Compile an extension source file and apply its contributions (tools + anything
  its `setup/1` registers). Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec load_file(Path.t()) :: {:ok, summary()} | {:error, term()}
  def load_file(path), do: GenServer.call(__MODULE__, {:load_file, path}, 30_000)

  @doc """
  (Re)load all `*.ex` files in the extensions directory.

  Returns `{:ok, %{loaded: summaries, failed: [{path, reason}]}}` — per-file
  failures are reported, not swallowed. Crash-detected safe mode is cleared
  only when `failed` is empty.
  """
  @spec load_all() :: {:ok, load_result()}
  def load_all, do: GenServer.call(__MODULE__, :load_all, 60_000)

  @doc """
  Re-run the boot-time load after another app wires more extension kinds (the
  web app wires `:renderer`/`:component`/`:page` after `:catalyst` boots).

  No-ops in safe mode: unlike `load_all/0` it never clears crash-detected safe
  mode or touches the boot marker, so a bricking extension can't be re-loaded
  by a later app's boot. Returns `{:ok, load_result}` or `{:skipped, status}`.
  """
  @spec reload_after_wiring() :: {:ok, load_result()} | {:skipped, term()}
  def reload_after_wiring do
    case boot_status() do
      :ok -> GenServer.call(__MODULE__, :reload_after_wiring, 60_000)
      status -> {:skipped, status}
    end
  end

  @doc "Remove every contribution made by `owner` (tools here + hooks/providers/UI)."
  @spec uninstall(String.t()) :: :ok
  def uninstall(owner), do: GenServer.call(__MODULE__, {:uninstall, owner})

  @doc "Directory holding extension source files."
  @spec dir() :: Path.t()
  def dir,
    do: Application.get_env(:catalyst, :extensions_dir) || Path.expand("~/.catalyst/extensions")

  @doc "Resolve a session's `tools` setting into a concrete module list (per turn)."
  @spec resolve([module()] | (-> [module()]) | term()) :: [module()]
  def resolve(tools) when is_list(tools), do: tools
  def resolve(fun) when is_function(fun, 0), do: fun.()
  def resolve(_), do: tools()

  @doc "Whether extensions are skipped at boot (safe mode)."
  @spec safe_mode?() :: boolean()
  def safe_mode? do
    System.get_env("CATALYST_SAFE_MODE") in ~w(1 true) or
      Application.get_env(:catalyst, :safe_mode, false)
  end

  @doc "Boot status: `:ok`, or `{:safe_mode, :env | :crash_detected}` when extensions were skipped."
  @spec boot_status() :: :ok | {:safe_mode, :env | :crash_detected}
  def boot_status, do: :persistent_term.get({__MODULE__, :boot_status}, :ok)

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    seed_builtins()
    wire_core_kinds()
    ensure_guide()

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
    # An explicit reload means a human/agent is at the wheel: a fully clean
    # pass clears crash-detected safe mode for the next boot. A pass with any
    # failure must NOT — broken extensions would be re-armed at the next boot.
    case result do
      {:ok, %{failed: []}} ->
        BootGuard.mark_ok()
        put_boot_status(:ok)

      _ ->
        :ok
    end

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
    # The extensions repo is ensured on the load path, NOT in init/1: git runs
    # with a deadline but can still take seconds, and a safe-mode boot (whose
    # whole point is "extensions can't brick startup") must never wait on it.
    # Explicit safe-mode load_all (the recovery path) still lands here.
    Catalyst.Extensions.Versioning.ensure_repo(dir())

    paths =
      case File.dir?(dir()) do
        true -> dir() |> Path.join("*.ex") |> Path.wildcard()
        false -> []
      end

    # Purge file-backed contributions whose source file is gone — e.g. removed
    # by a rollback or by hand. Without this, reverted code stays registered
    # (and callable) until the next restart. Only owners present in
    # state.modules are file-backed: an owner registered purely via
    # `register_tool(mod, owner: "x")` has no file to be "gone" and is kept.
    live_owners = MapSet.new(paths, &ext_id/1)

    state =
      state.modules
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(live_owners, &1))
      |> Enum.reduce(state, fn owner, st -> purge_owner(owner, st) end)

    {loaded, failed, state} =
      Enum.reduce(paths, {[], [], state}, fn path, {ok, bad, st} ->
        case do_load_file(path, st) do
          {{:ok, summary}, st} ->
            {[summary | ok], bad, st}

          {{:error, reason}, st} ->
            Logger.warning("[extensions] failed to load #{path}: #{inspect(reason)}")
            {ok, [{path, reason} | bad], st}
        end
      end)

    {{:ok, %{loaded: Enum.reverse(loaded), failed: Enum.reverse(failed)}}, state}
  end

  defp do_load_file(path, state) do
    owner = ext_id(path)

    # Code.compile_file/1 defines modules SEQUENTIALLY: a file whose first
    # module compiles but whose second raises fails the load with module 1
    # already redefined in the VM. Snapshot the file's candidate module names
    # (from its AST) and which of them are loaded before the attempt, so the
    # error path below can purge what a partial compile left behind.
    candidates = candidate_modules(path)
    preloaded = MapSet.new(Enum.filter(candidates, &:erlang.module_loaded/1))

    # Compile + classify FIRST, in their own failure domain: a broken file
    # fails here, before we touch any registry or tracking, so a failed reload
    # neither registers nor drops the prior version.
    case compile_and_classify(path) do
      {:ok, contribution} ->
        commit_load(owner, path, contribution, state)

      {:error, reason} ->
        purge_partial_compile(candidates, preloaded, state)
        {{:error, reason}, state}
    end
  end

  # After a failed compile, drop any module the partial compile left live: a
  # candidate that is loaded NOW but was not loaded before this attempt and is
  # not claimed by any owner's tracking. Deliberately conservative — a module
  # that pre-existed (e.g. the prior version of this same file, or a shadowed
  # app module) is never purged here, because purging would remove the new AND
  # old definitions at once; the Installer repairs that case by re-loading the
  # restored backup source instead.
  defp purge_partial_compile(candidates, preloaded, state) do
    tracked = state.modules |> Map.values() |> List.flatten() |> MapSet.new()

    candidates
    |> Enum.reject(&MapSet.member?(preloaded, &1))
    |> Enum.reject(&MapSet.member?(tracked, &1))
    |> Enum.filter(&:erlang.module_loaded/1)
    |> Enum.each(fn mod ->
      Logger.warning(
        "[extensions] purging #{inspect(mod)} left behind by a failed multi-module compile"
      )

      restore_module(mod)
    end)
  end

  # Module names a source file would define, read from its AST without
  # compiling anything (best effort: an unparseable file defines nothing, so
  # it yields []). Used only to clean up after a partial compile.
  defp candidate_modules(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      ast |> collect_defmodules([], []) |> Enum.uniq()
    else
      _ -> []
    end
  rescue
    # Arbitrary user source flows through here inside the GenServer; a walker
    # edge case must degrade to "no candidates", never crash the server.
    _ -> []
  end

  # Walk the AST collecting defmodule names, nesting prefixes the way the
  # compiler does (`defmodule B` inside `defmodule A` defines A.B; a name
  # starting with `Elixir.` is absolute). Dynamic names (interpolation, module
  # attributes) can't be resolved statically and are skipped — failing to
  # purge such a module is a leak, purging a wrongly-guessed name would be
  # far worse.
  defp collect_defmodules({:defmodule, _, [name | rest]}, prefix, acc) do
    case static_module_name(name, prefix) do
      {:ok, mod, child_prefix} ->
        Enum.reduce(rest, [mod | acc], &collect_defmodules(&1, child_prefix, &2))

      :error ->
        Enum.reduce(rest, acc, &collect_defmodules(&1, prefix, &2))
    end
  end

  defp collect_defmodules({form, _meta, args}, prefix, acc) when is_list(args) do
    acc = collect_defmodules(form, prefix, acc)
    Enum.reduce(args, acc, &collect_defmodules(&1, prefix, &2))
  end

  defp collect_defmodules({a, b}, prefix, acc),
    do: collect_defmodules(b, prefix, collect_defmodules(a, prefix, acc))

  defp collect_defmodules(list, prefix, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_defmodules(&1, prefix, &2))

  defp collect_defmodules(_other, _prefix, acc), do: acc

  defp static_module_name({:__aliases__, _, segments}, prefix) do
    cond do
      segments == [] or not Enum.all?(segments, &is_atom/1) ->
        :error

      prefix == [] or hd(segments) == :"Elixir" ->
        {:ok, Module.concat(segments), segments}

      true ->
        {:ok, Module.concat(prefix ++ segments), prefix ++ segments}
    end
  end

  # `defmodule :raw_atom` defines exactly that atom (no Elixir. prefix).
  defp static_module_name(name, _prefix) when is_atom(name), do: {:ok, name, [name]}
  defp static_module_name(_name, _prefix), do: :error

  defp compile_and_classify(path) do
    modules = path |> Code.compile_file() |> Enum.map(&elem(&1, 0))
    {ext_mods, tool_mods} = classify(modules)

    {:ok,
     %{
       modules: modules,
       ext_mods: ext_mods,
       tool_mods: tool_mods,
       tool_names: Enum.map(tool_mods, & &1.name())
     }}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Commit a compiled file: purge the prior version's side effects, apply the
  # new ones, and return the new tracking. The tracking is assembled BEFORE the
  # side effects run — Code.compile_file/1 already redefined the modules in the
  # VM, so even if a step below raises unexpectedly, the caller gets tracking
  # that claims them for this owner (never the stale pre-purge snapshot, which
  # would let registries and state tracking silently diverge).
  defp commit_load(owner, path, contribution, state) do
    %{modules: modules, ext_mods: ext_mods, tool_mods: tool_mods, tool_names: tool_names} =
      contribution

    conflicts = module_conflicts(owner, modules, state)
    log_conflicts(owner, conflicts)

    committed = %{
      state
      | contrib: Map.put(state.contrib, owner, MapSet.new(tool_names)),
        modules: Map.put(state.modules, owner, modules)
    }

    try do
      # Modules the new file still defines were just redefined by the compile
      # above and must survive the purge; ones it dropped are restored/removed.
      purge_owner_effects(owner, state, keep_modules: modules)
      Enum.each(tool_mods, &insert/1)
      setup_tools = run_setups(ext_mods, ExtensionAPI.new(owner, path))
      committed = Enum.reduce(setup_tools, committed, fn mod, st -> track(mod, owner, st) end)
      {{:ok, build_summary(owner, tool_names, ext_mods, conflicts)}, committed}
    rescue
      e -> {{:error, Exception.message(e)}, committed}
    catch
      kind, reason -> {{:error, {kind, reason}}, committed}
    end
  end

  # Run each extension module's setup/1, collecting tools it registered inline
  # (see wire_core_kinds). A raising setup is logged, not fatal: everything it
  # registered before raising stays registered (owner-tagged, hence purgeable).
  defp run_setups(ext_mods, api) do
    Process.put(@setup_tools, [])
    Enum.each(ext_mods, &run_setup(&1, api))
    Process.delete(@setup_tools) || []
  end

  defp run_setup(mod, api) do
    mod.setup(api)
  rescue
    e ->
      Logger.warning(
        "[extensions] #{api.owner}: #{inspect(mod)}.setup/1 raised: #{Exception.message(e)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "[extensions] #{api.owner}: #{inspect(mod)}.setup/1 #{kind}: #{inspect(reason)}"
      )
  end

  defp build_summary(owner, tool_names, ext_mods, []),
    do: %{owner: owner, tools: tool_names, extensions: ext_mods}

  defp build_summary(owner, tool_names, ext_mods, conflicts),
    do: %{owner: owner, tools: tool_names, extensions: ext_mods, conflicts: conflicts}

  # Cross-owner module collisions: two files defining the same module means
  # purging one reverts code the other still owns. Surfaced (log + summary),
  # not rejected — the last load wins until one of the files is fixed.
  defp module_conflicts(owner, modules, state) do
    mods = MapSet.new(modules)

    state.modules
    |> Map.delete(owner)
    |> Enum.flat_map(fn {other, other_mods} ->
      case Enum.filter(other_mods, &MapSet.member?(mods, &1)) do
        [] -> []
        overlap -> [{other, overlap}]
      end
    end)
  end

  defp log_conflicts(_owner, []), do: :ok

  defp log_conflicts(owner, conflicts) do
    Enum.each(conflicts, fn {other, mods} ->
      Logger.warning(
        "[extensions] #{owner} redefines #{inspect(mods)} also defined by extension " <>
          "\"#{other}\" — purging/reloading either file will affect the other"
      )
    end)
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
    purge_owner_effects(owner, state, opts)

    %{
      state
      | contrib: Map.delete(state.contrib, owner),
        modules: Map.delete(state.modules, owner)
    }
  end

  # The side-effect half of a purge (registries + module definitions), with no
  # tracking change — commit_load assembles the new tracking itself, up front.
  defp purge_owner_effects(owner, state, opts) do
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
