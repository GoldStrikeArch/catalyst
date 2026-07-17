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
  compiles, its registration is committed even if a `setup/1` raises or times
  out mid-way: whatever it registered before failing stays registered
  (owner-tagged, so the next reload or uninstall purges it cleanly).

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
  alias Catalyst.Extensions.{BootGuard, Processes, Versioning}

  @table :catalyst_tools

  @compile_timeout 30_000
  @setup_timeout 30_000
  @load_lock {__MODULE__, :load_lock}

  @typedoc "Per-file load summary. `:conflicts` is present only when this file redefines modules another loaded file also defines."
  @type summary :: %{
          required(:owner) => String.t(),
          required(:tools) => [String.t()],
          required(:extensions) => [module()],
          optional(:conflicts) => [{String.t(), [module()]}],
          optional(:warning) => String.t()
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
  Register `mod.fun/0` to be re-run on every (re)start of this server.

  Boot-time registrations from OTHER apps (e.g. the web app's rebuild_assets
  tool) live in this server's table, but a supervisor restart of this server
  only re-seeds built-ins and extension files — the other app's `start/2`
  doesn't run again, so its tools would silently vanish. Reseeders live in
  `:persistent_term` (like `ExtensionAPI` kinds/purgers) and are MFA-keyed, so
  they survive restarts and hot-reload replaces rather than accumulates.
  """
  @spec register_reseeder(module(), atom()) :: :ok
  def register_reseeder(mod, fun) when is_atom(mod) and is_atom(fun) do
    :persistent_term.put({__MODULE__, :reseeders}, Map.put(reseeders(), {mod, fun}, true))
  end

  @doc """
  Compile an extension source file and apply its contributions (tools + anything
  its `setup/1` registers). Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec load_file(Path.t()) :: {:ok, summary()} | {:error, term()}
  def load_file(path), do: serialized_load(fn -> do_load_file(path) end)

  @doc """
  (Re)load all `*.ex` files in the extensions directory.

  Returns `{:ok, %{loaded: summaries, failed: [{path, reason}]}}` — per-file
  failures are reported, not swallowed. Crash-detected safe mode is cleared
  only when `failed` is empty.
  """
  @spec load_all() :: {:ok, load_result()}
  def load_all do
    result = serialized_load(&do_load_all/0)

    case result do
      {:ok, %{failed: []}} ->
        BootGuard.mark_ok()
        put_boot_status(:ok)

      _ ->
        :ok
    end

    result
  end

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
      :ok -> serialized_load(&do_load_all/0)
      status -> {:skipped, status}
    end
  end

  @doc "Remove every contribution made by `owner` (tools here + hooks/providers/UI)."
  @spec uninstall(String.t()) :: :ok
  def uninstall(owner), do: GenServer.call(__MODULE__, {:uninstall, owner})

  @typedoc "One live owner's footprint: source file (nil when registered without a file), tool names, modules its file defined."
  @type loaded_info :: %{
          owner: String.t(),
          path: Path.t() | nil,
          tools: [String.t()],
          modules: [module()]
        }

  @doc """
  Snapshot of every live extension owner — what each registered and which
  modules its file defined. The introspection behind the Extensions panel;
  built-in tools are not listed (they have no owner).
  """
  @spec list_loaded() :: [loaded_info()]
  def list_loaded do
    files = Map.new(extension_files(), &{ext_id(&1), &1})

    __MODULE__
    |> GenServer.call(:snapshot)
    |> Enum.map(fn {owner, info} -> Map.put(info, :path, Map.get(files, owner)) end)
    |> Enum.sort_by(& &1.owner)
  end

  @doc "Extensions present on disk but disabled (`<file>.ex.disabled`), as `%{owner, path}`."
  @spec list_disabled() :: [%{owner: String.t(), path: Path.t()}]
  def list_disabled do
    dir()
    |> disabled_files()
    |> Enum.map(&%{owner: disabled_owner(&1), path: &1})
    |> Enum.sort_by(& &1.owner)
  end

  @doc "The source file backing `owner`, enabled or disabled. `:error` for file-less owners."
  @spec source_file(String.t()) :: {:ok, Path.t()} | :error
  def source_file(owner) do
    case file_for(owner) || disabled_file_for(owner) do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @doc "Reload one extension from its source file (purge prior contributions + recompile)."
  @spec reload(String.t()) :: {:ok, summary()} | {:error, term()}
  def reload(owner) do
    serialized_load(fn ->
      case file_for(owner) do
        nil -> {:error, :no_file}
        path -> do_load_file(path)
      end
    end)
  end

  @doc """
  Disable an extension without deleting it: purge its contributions and rename
  its source to `<file>.ex.disabled` so neither `load_all/0` nor the next boot
  picks it up. Reversed by `enable/1`. The rename is committed to the
  extensions repo so rollback history stays coherent.
  """
  @spec disable(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def disable(owner) do
    serialized_load(fn ->
      case file_for(owner) do
        nil ->
          {:error, :no_file}

        path ->
          disabled = path <> ".disabled"

          # Rename first (under the load lock) so a concurrent load can't
          # recompile the file between the purge and the rename.
          with :ok <- File.rename(path, disabled) do
            :ok = GenServer.call(__MODULE__, {:uninstall, owner})
            _ = Versioning.commit(dir(), "disable #{owner}")
            {:ok, disabled}
          end
      end
    end)
  end

  @doc """
  Re-enable a disabled extension: rename `<file>.ex.disabled` back and load it.
  A file that fails to compile stays enabled (and keeps failing visibly) —
  the load error is returned so the caller can surface it.
  """
  @spec enable(String.t()) :: {:ok, summary()} | {:error, term()}
  def enable(owner) do
    serialized_load(fn ->
      case disabled_file_for(owner) do
        nil ->
          {:error, :no_file}

        disabled ->
          path = String.replace_suffix(disabled, ".disabled", "")

          with :ok <- File.rename(disabled, path) do
            result = do_load_file(path)
            _ = Versioning.commit(dir(), "enable #{owner}")
            result
          end
      end
    end)
  end

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

  @doc """
  Record that this boot is ending by user intent, not a crash.

  Quitting inside the BootGuard stabilization window otherwise leaves the
  marker at "booting", and the NEXT boot flips into extension safe mode — a
  false positive that stays sticky until an explicit reload. Called from
  `Catalyst.Application.stop/1` (graceful stops) and the desktop quit menu
  (desktop quit is a `System.halt/1`, which skips stop callbacks). No-op when
  this boot is already in safe mode: its stale marker must survive until the
  bad extension is actually fixed.
  """
  @spec mark_clean_shutdown() :: :ok
  def mark_clean_shutdown do
    case boot_status() do
      :ok -> BootGuard.mark_ok()
      {:safe_mode, _why} -> :ok
    end
  end

  @doc """
  Human-readable rendering of the tagged error reasons returned by
  `load_file/1`, `load_all/0`, `register_tool/2`, and `Installer.install/3`.
  Tools format at this boundary; the tagged tuples stay matchable for callers.
  """
  @spec format_error(term()) :: String.t()
  def format_error(:self_mod_disabled) do
    "self-modification is disabled on this machine " <>
      "(CATALYST_DISABLE_SELF_MOD / config :catalyst, :allow_self_modification)"
  end

  def format_error({:compile, reason}), do: "compile failed: " <> format_error(reason)
  def format_error({:register, reason}), do: "registration failed: " <> format_error(reason)
  def format_error(:no_file), do: "no extension source file found for that owner"
  def format_error(:timeout), do: "timed out"
  def format_error({:exit, reason}), do: "exited: #{inspect(reason)}"

  def format_error({:not_a_tool, module}),
    do: "#{inspect(module)} is not a tool (needs name/0, parameters/0, execute/2)"

  def format_error({:bad_tool_name, reason}), do: "tool name/0 failed: #{inspect(reason)}"
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    seed_builtins()
    wire_core_kinds()
    ensure_guide()
    # In a task: reseeders call register_tool/2, a call back into this server,
    # which would deadlock from init. Runs in safe mode too — reseeded tools
    # are app wiring, not extension code.
    run_reseeders()

    state = %{contrib: %{}, modules: %{}}

    cond do
      safe_mode?() ->
        put_boot_status({:safe_mode, :env})
        Logger.info("[extensions] safe mode (CATALYST_SAFE_MODE) — skipping extension load")
        {:ok, state}

      BootGuard.crashed_last_boot?() and extension_files() == [] ->
        # A stale "booting" marker with nothing to load protects nothing: the
        # previous boot was quit inside the stabilization window (desktop quit
        # is a System.halt — no stop callback runs to mark it clean), not
        # bricked by an extension. Boot normally; the marker re-arms and
        # self-heals once this boot stabilizes.
        Logger.info(
          "[extensions] stale boot marker but no extension files in #{dir()} — booting normally"
        )

        normal_boot(state)

      BootGuard.crashed_last_boot?() ->
        put_boot_status({:safe_mode, :crash_detected})

        Logger.warning(
          "[extensions] previous boot died while extensions were active — skipping extension " <>
            "load. Fix the files in #{dir()} and run the reload_extensions tool."
        )

        {:ok, state}

      true ->
        normal_boot(state)
    end
  end

  defp normal_boot(state) do
    put_boot_status(:ok)
    BootGuard.mark_booting()
    {:ok, state, {:continue, :load_all}}
  end

  @impl true
  def handle_continue(:load_all, state) do
    server = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(Catalyst.TaskSupervisor, fn ->
        _ = serialized_load(&do_load_all/0)
        send(server, :boot_load_finished)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:boot_load_finished, state) do
    # If the app survives the stabilization window after the boot load finished,
    # this boot's extensions are considered safe. Dying before the timer fires
    # leaves the marker at "booting", which the next boot reads as crash-detected
    # safe mode.
    Process.send_after(self(), :mark_boot_ok, boot_stable_ms())
    {:noreply, state}
  end

  def handle_info(:mark_boot_ok, state) do
    BootGuard.mark_ok()
    {:noreply, state}
  end

  @impl true
  def handle_call({:register, module, opts}, _from, state) do
    {result, state} = do_register(module, opts, state)
    {:reply, result, state}
  end

  def handle_call({:purge_gone, live_owners}, _from, state) do
    state =
      state.modules
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(live_owners, &1))
      |> Enum.reduce(state, fn owner, st -> purge_owner(owner, st) end)

    {:reply, :ok, state}
  end

  def handle_call({:purge_partial_compile, candidates, preloaded}, _from, state) do
    purge_partial_compile(candidates, preloaded, state)
    {:reply, :ok, state}
  end

  def handle_call({:commit_load, owner, path, contribution}, _from, state) do
    {result, state} = commit_load(owner, path, contribution, state)
    {:reply, result, state}
  end

  def handle_call({:uninstall, owner}, _from, state) do
    {:reply, :ok, purge_owner(owner, state)}
  end

  def handle_call(:snapshot, _from, state) do
    owners =
      state.contrib
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.keys(state.modules)))

    snapshot =
      Enum.map(owners, fn owner ->
        tools =
          state.contrib |> Map.get(owner, MapSet.new()) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

        {owner, %{owner: owner, tools: tools, modules: Map.get(state.modules, owner, [])}}
      end)

    {:reply, snapshot, state}
  end

  # ---- boot helpers ---------------------------------------------------------

  defp seed_builtins do
    Enum.each(Catalyst.Tools.Registry.default_tools(), &insert/1)
  end

  # Wire the extension kinds that core can back, and the hooks owner-purger.
  # Provider (E3) and UI (E5) kinds/purgers are wired by their own subsystems.
  defp wire_core_kinds do
    ExtensionAPI.register_kind(:tool, fn api, module ->
      register_tool(module, owner: api.owner)
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

  defp reseeders, do: :persistent_term.get({__MODULE__, :reseeders}, %{})

  defp run_reseeders do
    Task.Supervisor.start_child(Catalyst.TaskSupervisor, fn ->
      Enum.each(Map.keys(reseeders()), fn {mod, fun} ->
        try do
          apply(mod, fun, [])
        catch
          kind, reason ->
            Logger.warning(
              "[extensions] reseeder #{inspect(mod)}.#{fun}/0 #{kind}: #{inspect(reason)}"
            )
        end
      end)
    end)

    :ok
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

  # Keep boot load, post-web-wiring reload, explicit reload, and single-file
  # loads ordered without putting compile/setup work back inside this GenServer.
  defp serialized_load(fun), do: :global.trans(@load_lock, fun, [node()], :infinity)

  defp extension_files do
    case File.dir?(dir()) do
      true -> dir() |> Path.join("*.ex") |> Path.wildcard()
      false -> []
    end
  end

  defp do_load_all do
    # The extensions repo is ensured on the load path, NOT in init/1: git runs
    # with a deadline but can still take seconds, and a safe-mode boot (whose
    # whole point is "extensions can't brick startup") must never wait on it.
    # Explicit safe-mode load_all (the recovery path) still lands here.
    Versioning.ensure_repo(dir())

    paths = extension_files()

    # Purge file-backed contributions whose source file is gone — e.g. removed
    # by a rollback or by hand. Without this, reverted code stays registered
    # (and callable) until the next restart. Only owners present in
    # state.modules are file-backed: an owner registered purely via
    # `register_tool(mod, owner: "x")` has no file to be "gone" and is kept.
    live_owners = MapSet.new(paths, &ext_id/1)
    :ok = GenServer.call(__MODULE__, {:purge_gone, live_owners}, 30_000)

    {loaded, failed} =
      Enum.reduce(paths, {[], []}, fn path, {ok, bad} ->
        case do_load_file(path) do
          {:ok, summary} ->
            {[summary | ok], bad}

          {:error, reason} ->
            Logger.warning("[extensions] failed to load #{path}: #{inspect(reason)}")
            {ok, [{path, reason} | bad]}
        end
      end)

    {:ok, %{loaded: Enum.reverse(loaded), failed: Enum.reverse(failed)}}
  end

  defp do_load_file(path) do
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
    case compile_and_classify_async(path) do
      {:ok, contribution} ->
        case GenServer.call(__MODULE__, {:commit_load, owner, path, contribution}, 30_000) do
          {:ok, summary} ->
            setup_status = run_setups_async(contribution.ext_mods, ExtensionAPI.new(owner, path))
            {:ok, annotate_setup_status(summary, setup_status)}

          {:error, _reason} = err ->
            err
        end

      {:error, reason} ->
        _ = GenServer.call(__MODULE__, {:purge_partial_compile, candidates, preloaded}, 30_000)
        {:error, reason}
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
    # Arbitrary user source flows through here; a walker edge case must degrade
    # to "no candidates", never crash the caller.
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
    modules = path |> compile_extension_file() |> Enum.map(&elem(&1, 0))
    {ext_mods, tool_mods} = classify(modules)

    with {:ok, tool_names} <- safe_tool_names(tool_mods) do
      {:ok,
       %{
         modules: modules,
         ext_mods: ext_mods,
         tool_mods: tool_mods,
         tool_names: tool_names
       }}
    end
  rescue
    e -> {:error, {:compile, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:compile, {kind, reason}}}
  end

  defp compile_extension_file(path) do
    previous = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_file(path)
    after
      Code.compiler_options(previous)
    end
  end

  defp compile_and_classify_async(path) do
    task = async_task(fn -> compile_and_classify(path) end)

    case await_task(task, compile_timeout()) do
      {:ok, {:ok, contribution}} -> {:ok, contribution}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:exit, reason}}
      :timeout -> {:error, :timeout}
    end
  end

  defp async_task(fun) do
    case Process.whereis(Catalyst.TaskSupervisor) do
      nil -> Task.async(fun)
      _pid -> Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fun)
    end
  end

  defp await_task(task, timeout) do
    case Task.yield(task, timeout) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        {:exit, reason}

      nil ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, value} -> {:ok, value}
          {:exit, reason} -> {:exit, reason}
          nil -> :timeout
        end
    end
  end

  defp compile_timeout,
    do: Application.get_env(:catalyst, :extension_compile_timeout, @compile_timeout)

  defp setup_timeout,
    do: Application.get_env(:catalyst, :extension_setup_timeout, @setup_timeout)

  # Commit a compiled file: purge the prior version's side effects, apply the
  # new ones, and return the new tracking. The tracking is assembled BEFORE the
  # side effects run — Code.compile_file/1 already redefined the modules in the
  # VM, so even if a step below raises unexpectedly, the caller gets tracking
  # that claims them for this owner (never the stale pre-purge snapshot, which
  # would let registries and state tracking silently diverge).
  defp commit_load(owner, _path, contribution, state) do
    %{modules: modules, ext_mods: ext_mods, tool_mods: tool_mods, tool_names: tool_names} =
      contribution

    conflicts = module_conflicts(owner, modules, state)
    log_conflicts(owner, conflicts)

    pairs = Enum.zip(tool_names, tool_mods)

    committed = %{
      state
      | contrib: Map.put(state.contrib, owner, MapSet.new(pairs)),
        modules: Map.put(state.modules, owner, modules)
    }

    try do
      # Modules the new file still defines were just redefined by the compile
      # above and must survive the purge; ones it dropped are restored/removed.
      purge_owner_effects(owner, state, keep_modules: modules)
      Enum.each(pairs, fn {name, mod} -> :ets.insert(@table, {name, mod}) end)
      {{:ok, build_summary(owner, tool_names, ext_mods, conflicts)}, committed}
    rescue
      e -> {{:error, {:register, Exception.message(e)}}, committed}
    catch
      kind, reason -> {{:error, {:register, {kind, reason}}}, committed}
    end
  end

  # Run each extension module's setup/1 outside the registry GenServer. A raising
  # setup is logged, not fatal: everything it registered before raising stays
  # registered (owner-tagged, hence purgeable). A hung setup task is killed at a
  # bounded timeout so reload/install callers return and the registry stays live.
  defp run_setups_async([], _api), do: :ok

  defp run_setups_async(ext_mods, api) do
    task = async_task(fn -> Enum.each(ext_mods, &run_setup(&1, api)) end)

    case await_task(task, setup_timeout()) do
      {:ok, :ok} ->
        :ok

      {:exit, reason} ->
        Logger.warning("[extensions] #{api.owner}: setup task exited: #{inspect(reason)}")
        {:error, {:setup_exit, reason}}

      :timeout ->
        Logger.warning("[extensions] #{api.owner}: setup timed out after #{setup_timeout()}ms")
        {:error, :setup_timeout}
    end
  end

  defp annotate_setup_status(summary, :ok), do: summary

  defp annotate_setup_status(summary, {:error, reason}) do
    Map.put(summary, :warning, "setup did not finish cleanly: #{inspect(reason)}")
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
    case safe_tool_name(module) do
      {:ok, name} ->
        :ets.insert(@table, {name, module})
        {{:ok, module}, track(name, module, opts[:owner], state)}

      {:error, _reason} = err ->
        {err, state}
    end
  end

  defp track(_name, _module, nil, state), do: state

  defp track(name, module, owner, state) do
    pairs = Map.get(state.contrib, owner, MapSet.new())
    put_in(state.contrib[owner], MapSet.put(pairs, {name, module}))
  end

  # `name/0` is extension-authored code reached inside this GenServer; a raise
  # would crash the registry and destroy the tools table with it, so resolve it
  # defensively and reject instead.
  defp safe_tool_name(module) do
    if tool_module?(module) do
      try do
        case module.name() do
          name when is_binary(name) -> {:ok, name}
          other -> {:error, {:bad_tool_name, other}}
        end
      rescue
        e -> {:error, {:bad_tool_name, Exception.message(e)}}
      catch
        kind, reason -> {:error, {:bad_tool_name, {kind, reason}}}
      end
    else
      {:error, {:not_a_tool, module}}
    end
  end

  defp safe_tool_names(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, names} ->
      case safe_tool_name(module) do
        {:ok, name} -> {:cont, {:ok, [name | names]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      {:error, _reason} = error -> error
    end
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

    pairs = Map.get(state.contrib, owner, MapSet.new())
    builtins = builtins_index()

    Enum.each(pairs, fn {name, mod} ->
      # Delete only if the live row is still THIS owner's registration —
      # registration is last-write-wins by name, so another owner may have
      # overwritten it since, and purging this owner must not clobber theirs.
      :ets.delete_object(@table, {name, mod})

      case {:ets.member(@table, name), Map.get(builtins, name)} do
        {false, builtin} when builtin != nil -> :ets.insert(@table, {name, builtin})
        _ -> :ok
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

  defp ext_id(path), do: path |> Path.basename(".ex") |> sanitize_owner()

  defp disabled_owner(path), do: path |> Path.basename(".ex.disabled") |> sanitize_owner()

  defp sanitize_owner(base), do: String.replace(base, ~r/[^a-zA-Z0-9_]/, "_")

  defp file_for(owner), do: Enum.find(extension_files(), &(ext_id(&1) == owner))

  defp disabled_file_for(owner),
    do: dir() |> disabled_files() |> Enum.find(&(disabled_owner(&1) == owner))

  defp disabled_files(dir) do
    case File.dir?(dir) do
      true -> dir |> Path.join("*.ex.disabled") |> Path.wildcard()
      false -> []
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
