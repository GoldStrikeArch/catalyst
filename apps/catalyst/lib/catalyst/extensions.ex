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
  Catalyst retains the exact BEAM binaries from every accepted load and restores
  those binaries on failure; newly introduced partial modules are removed. Once
  a file compiles, its registration is committed even if a `setup/1` raises or
  times out mid-way: whatever it registered before failing stays registered
  (owner-tagged, so the next reload or uninstall purges it cleanly).

  Set `CATALYST_SAFE_MODE=1` (or `config :catalyst, :safe_mode, true`) to skip
  loading extensions at boot — only built-ins are seeded, so a bad extension can't
  brick startup. Safe mode also engages **automatically**: a boot-marker file
  (`Catalyst.Extensions.BootGuard`) detects that the previous boot died while its
  extensions were active and skips loading, so a bricking extension is recovered
  by a plain relaunch. `boot_status/0` reports it; a successful explicit
  `load_all/0` (the `reload_extensions` tool) clears it. A boot-time load
  failure is retained in `boot_status/0` and deliberately leaves the marker
  armed, so the next launch enters safe mode instead of silently treating the
  broken directory as clean.

  Purging an owner also undoes its **module definitions**: modules its file
  compiled are removed from the VM, and any module that shadowed one shipping
  with the app is restored from the original beam on the code path — so
  overriding core behavior is as reversible as registering a tool.
  """

  use GenServer
  require Logger

  alias Catalyst.{ExtensionAPI, Hooks, Tasks}
  alias Catalyst.Extensions.{BootGuard, Loader, Processes, Versioning}
  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @table :catalyst_tools
  @host_owner :host

  @load_lock {__MODULE__, :load_lock}
  @load_context_key {__MODULE__, :load_context}

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
  def names do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 0))
  rescue
    ArgumentError -> Enum.map(ToolRegistry.default_tools(), & &1.name())
  end

  @doc "Register a validated tool module. `opts[:owner]` tags it for purge-on-reload."
  @spec register_tool(module(), keyword()) :: {:ok, module()} | {:error, term()}
  def register_tool(module, opts \\ []) do
    with {:ok, definition} <- ToolRegistry.definition(module) do
      GenServer.call(__MODULE__, {:register, module, definition, opts})
    end
  end

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
  @spec load_all() :: {:ok, load_result()} | {:error, term()}
  def load_all do
    serialized_load(fn ->
      result = do_load_all()

      case result do
        {:ok, %{failed: []}} ->
          BootGuard.mark_ok()
          put_boot_status(:ok)

        _ ->
          :ok
      end

      result
    end)
  end

  @doc """
  Re-run the boot-time load after another app wires more extension kinds (the
  web app wires `:renderer`/`:component`/`:page` after `:catalyst` boots).

  No-ops in safe mode: unlike `load_all/0` it never clears crash-detected safe
  mode or touches the boot marker, so a bricking extension can't be re-loaded
  by a later app's boot. Returns `{:ok, load_result}` or `{:skipped, status}`.
  """
  @spec reload_after_wiring() :: {:ok, load_result()} | {:error, term()} | {:skipped, term()}
  def reload_after_wiring do
    case boot_status() do
      :ok -> serialized_load(&do_load_all/0)
      status -> {:skipped, status}
    end
  end

  @doc "Remove every contribution made by `owner` (tools here + hooks/providers/UI)."
  @spec uninstall(String.t()) :: :ok
  def uninstall(owner) do
    # Under the load lock: an uninstall racing an in-flight load_file (compile
    # done, commit pending) would otherwise be resurrected by the commit.
    serialized_load(fn -> GenServer.call(__MODULE__, {:uninstall, owner}) end)
  end

  @doc false
  @spec record_setup_collision(reference(), term()) :: :ok
  def record_setup_collision(load_ref, reason) when is_reference(load_ref) do
    GenServer.call(__MODULE__, {:record_setup_collision, load_ref, reason})
  end

  @doc """
  Run `fun` under the extensions load lock — the same lock `load_file/1`,
  `load_all/0`, `disable/1`… take. The function runs in a supervised,
  caller-independent transaction process, so it must not depend on the
  caller's mailbox or process dictionary. Calls nested by that transaction
  are re-entrant; this lets the installer compose write → load → commit into
  one critical section that a concurrent load cannot interleave or abandon.
  """
  @spec locked((-> result)) :: result when result: term()
  def locked(fun) when is_function(fun, 0), do: serialized_load(fun)

  @typedoc "One live owner's footprint: source file (nil when registered without a file), tool names, modules its file defined, merged `metadata/0`."
  @type loaded_info :: %{
          owner: String.t(),
          path: Path.t() | nil,
          managed?: boolean(),
          tools: [String.t()],
          modules: [module()],
          metadata: map()
        }

  @doc """
  Snapshot of every live extension owner — what each registered, which
  modules its file defined, and their merged optional `metadata/0`. The
  introspection behind the Extensions panel; built-in tools are not listed
  (they have no owner).
  """
  @spec list_loaded() :: [loaded_info()]
  def list_loaded do
    __MODULE__
    |> GenServer.call(:snapshot)
    |> Enum.map(&elem(&1, 1))
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
    case file_for(owner) do
      {:ok, path} -> {:ok, path}
      :error -> disabled_file_for(owner)
    end
  end

  @doc "Reload one extension from its source file (purge prior contributions + recompile)."
  @spec reload(String.t()) :: {:ok, summary()} | {:error, term()}
  def reload(owner) do
    serialized_load(fn ->
      case file_for(owner) do
        {:ok, path} -> do_load_file(path)
        :error -> {:error, :no_file}
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
        {:ok, path} ->
          disabled = path <> ".disabled"

          # Rename first (under the load lock) so a concurrent load can't
          # recompile the file between the purge and the rename.
          with :ok <- ensure_managed_source(path),
               :ok <- File.rename(path, disabled) do
            :ok = GenServer.call(__MODULE__, {:uninstall, owner})
            commit_lifecycle_change([path, disabled], "disable #{owner}")
            {:ok, disabled}
          end

        :error ->
          {:error, :no_file}
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
        {:ok, disabled} ->
          path = String.replace_suffix(disabled, ".disabled", "")

          with :ok <- File.rename(disabled, path) do
            result = do_load_file(path)
            commit_lifecycle_change([disabled, path], "enable #{owner}")
            result
          end

        :error ->
          {:error, :no_file}
      end
    end)
  end

  @doc "Directory holding extension source files."
  @spec dir() :: Path.t()
  def dir,
    do: Application.get_env(:catalyst, :extensions_dir) || Catalyst.Paths.extensions()

  @doc "Normalize a source-file/name string into its extension owner id."
  @spec sanitize_owner(String.t()) :: String.t()
  def sanitize_owner(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

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

  @doc "Boot status: `:ok`, a safe-mode reason, or `{:load_failed, reason}`."
  @spec boot_status() ::
          :ok | {:safe_mode, :env | :crash_detected} | {:load_failed, term()}
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
      _not_clean -> :ok
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

  def format_error({:owner_collision, owner, paths}) do
    "multiple extension files normalize to owner #{inspect(owner)}: #{Enum.join(paths, ", ")}"
  end

  def format_error(:no_file), do: "no extension source file found for that owner"

  def format_error(:external_source),
    do: "only files inside the extensions directory can be disabled"

  def format_error(:timeout), do: "timed out"
  def format_error({:exit, reason}), do: "exited: #{inspect(reason)}"

  def format_error({:not_a_tool, module}),
    do:
      "#{inspect(module)} is not a tool " <>
        "(needs name/0, description/0, parameters/0, execute/2)"

  def format_error({:bad_tool_name, reason}), do: "tool name/0 failed: #{inspect(reason)}"

  def format_error({:bad_tool_description, reason}),
    do: "tool description/0 failed: #{inspect(reason)}"

  def format_error({:bad_tool_parameters, reason}),
    do: "tool parameters/0 failed: #{inspect(reason)}"

  def format_error({:bad_tool_mode, reason}),
    do: "tool execution_mode/0 failed: #{inspect(reason)}"

  def format_error({:tool_metadata_timeout, module}),
    do: "tool metadata timed out for #{inspect(module)}"

  def format_error({:tool_metadata_exit, module, reason}),
    do: "tool metadata exited for #{inspect(module)}: #{inspect(reason)}"

  def format_error({:tool_owner_collision, name, existing, attempted}) do
    "tool #{inspect(name)} is already owned by #{inspect(existing)}; " <>
      "#{inspect(attempted)} cannot replace it"
  end

  def format_error({:provider_owner_collision, api, existing, attempted}) do
    "provider #{inspect(api)} is already owned by #{inspect(existing)}; " <>
      "#{inspect(attempted)} cannot replace it"
  end

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

    state = %{
      contrib: %{},
      owners: %{},
      modules: %{},
      module_versions: %{},
      metadata: %{},
      paths: %{},
      setup_collisions: %{}
    }

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

    case Tasks.start_background(fn -> send(server, {:boot_load_finished, boot_load()}) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> send(server, {:boot_load_finished, {:error, reason}})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:boot_load_finished, {:ok, %{failed: []}}}, state) do
    # If the app survives the stabilization window after the boot load finished,
    # this boot's extensions are considered safe. Dying before the timer fires
    # leaves the marker at "booting", which the next boot reads as crash-detected
    # safe mode.
    Process.send_after(self(), :mark_boot_ok, boot_stable_ms())
    {:noreply, state}
  end

  def handle_info({:boot_load_finished, {:ok, %{failed: failures}}}, state) do
    boot_load_failed(failures)
    {:noreply, state}
  end

  def handle_info({:boot_load_finished, {:error, reason}}, state) do
    boot_load_failed(reason)
    {:noreply, state}
  end

  def handle_info(:mark_boot_ok, state) do
    case boot_status() do
      :ok -> BootGuard.mark_ok()
      _not_clean -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    collisions =
      Enum.reduce(state.setup_collisions, state.setup_collisions, fn
        {load_ref, %{monitor: ^monitor}}, acc -> Map.delete(acc, load_ref)
        _entry, acc -> acc
      end)

    {:noreply, %{state | setup_collisions: collisions}}
  end

  @impl true
  def handle_call({:register, module, definition, opts}, _from, state) do
    {result, state} = do_register(module, definition, opts, state)
    {:reply, result, state}
  end

  def handle_call({:record_setup_collision, load_ref, reason}, _from, state) do
    collisions =
      case Map.fetch(state.setup_collisions, load_ref) do
        {:ok, entry} ->
          Map.put(state.setup_collisions, load_ref, %{
            entry
            | collisions: [reason | entry.collisions]
          })

        :error ->
          state.setup_collisions
      end

    {:reply, :ok, %{state | setup_collisions: collisions}}
  end

  def handle_call({:begin_setup, load_ref}, {caller, _tag}, state) do
    entry = %{monitor: Process.monitor(caller), collisions: []}
    collisions = Map.put(state.setup_collisions, load_ref, entry)
    {:reply, :ok, %{state | setup_collisions: collisions}}
  end

  def handle_call({:take_setup_collisions, load_ref}, _from, state) do
    {entry, remaining} = Map.pop(state.setup_collisions, load_ref)
    collisions = finish_setup_entry(entry)

    {:reply, collisions, %{state | setup_collisions: remaining}}
  end

  def handle_call({:purge_gone, live_owners}, _from, state) do
    state =
      state.modules
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(live_owners, &1))
      |> Enum.reduce(state, fn owner, st -> purge_owner(owner, st) end)

    {:reply, :ok, state}
  end

  def handle_call({:purge_partial_compile, candidates}, _from, state) do
    restore_compiled_modules(candidates, state, "failed multi-module compile")
    {:reply, :ok, state}
  end

  def handle_call({:purge_rejected_compile, candidates}, _from, state) do
    restore_compiled_modules(candidates, state, "rejected compiled contribution")
    {:reply, :ok, state}
  end

  def handle_call({:commit_load, owner, path, contribution}, _from, state) do
    {result, state} = commit_load(owner, path, contribution, state)
    {:reply, result, state}
  end

  def handle_call({:uninstall, owner}, _from, state) do
    {:reply, :ok, purge_owner(owner, state)}
  end

  def handle_call({:path_for, owner}, _from, state) do
    case Map.fetch(state.paths, owner) do
      {:ok, path} -> {:reply, {:ok, path}, state}
      :error -> {:reply, :error, state}
    end
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

        {owner,
         %{
           owner: owner,
           path: Map.get(state.paths, owner),
           managed?: managed_source?(Map.get(state.paths, owner)),
           tools: tools,
           modules: Map.get(state.modules, owner, []),
           metadata: Map.get(state.metadata, owner, %{})
         }}
      end)

    {:reply, snapshot, state}
  end

  defp finish_setup_entry(nil), do: []

  defp finish_setup_entry(%{monitor: monitor, collisions: collisions}) do
    Process.demonitor(monitor, [:flush])
    Enum.reverse(collisions)
  end

  # ---- boot helpers ---------------------------------------------------------

  defp boot_load do
    serialized_load(&do_load_all/0)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp boot_load_failed(reason) do
    put_boot_status({:load_failed, reason})

    Logger.error(
      "[extensions] boot load failed; leaving the boot marker armed: #{inspect(reason)}"
    )
  end

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
    Tasks.start_background(fn ->
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
    dest = Catalyst.Paths.join("guide.md")

    result =
      with {:ok, contents} <- File.read(src),
           :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- AtomicWrite.write(dest, contents) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[extensions] could not publish extension guide to #{dest}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ---- loading --------------------------------------------------------------

  # Keep boot load, post-web-wiring reload, explicit reload, and single-file
  # loads ordered without putting compile/setup work back inside this GenServer.
  # A supervised, unlinked transaction process deliberately owns the operation:
  # if a UI/session caller disappears after commit_load/4, the transaction still
  # reaches setup collision handling and either accepts or rolls back the file.
  # Nested calls (Installer holds the lock and then calls load_file/1) execute in
  # that same transaction process via the process-local context marker.
  defp serialized_load(fun) do
    case Process.get(@load_context_key, false) do
      true -> fun.()
      false -> run_serialized_task(fun)
    end
  end

  defp run_serialized_task(fun) do
    case start_serialized_task(fun) do
      {:ok, task} -> await_serialized_task(task)
      :error -> with_load_lock(fun)
    end
  end

  defp start_serialized_task(fun) do
    task =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        capture_load_outcome(fn -> with_load_lock(fun) end)
      end)

    {:ok, task}
  catch
    :exit, _reason -> :error
  end

  defp await_serialized_task(task) do
    case Task.yield(task, :infinity) do
      {:ok, {:return, result}} -> result
      {:ok, {:raised, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
      {:exit, reason} -> exit(reason)
    end
  end

  defp capture_load_outcome(fun) do
    {:return, fun.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  # The lock requester must be the transaction pid: `:global` treats locks held
  # by the SAME requester id as compatible, so a fixed atom requester would let
  # unrelated processes hold the "lock" concurrently.
  defp with_load_lock(fun) do
    :global.trans(
      {@load_lock, self()},
      fn ->
        Process.put(@load_context_key, true)

        try do
          fun.()
        after
          Process.delete(@load_context_key)
        end
      end,
      [node()],
      :infinity
    )
  end

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
    owner_paths = index_owner_paths(paths)

    with :ok <- ensure_distinct_owners(owner_paths) do
      load_paths(paths)
    end
  end

  defp load_paths(paths) do
    # Purge file-backed contributions whose source file is gone — e.g. removed
    # by a rollback or by hand. Without this, reverted code stays registered
    # (and callable) until the next restart. Only owners present in
    # state.modules are file-backed: an owner registered purely via
    # `register_tool(mod, owner: "x")` has no file to be "gone" and is kept.
    live_owners = MapSet.new(paths, &ext_id/1)
    :ok = GenServer.call(__MODULE__, {:purge_gone, live_owners}, 30_000)

    {loaded, failed} =
      Enum.reduce(paths, {[], []}, fn path, {ok, bad} ->
        case compile_and_load(path, ext_id(path)) do
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

    with :ok <- ensure_owner_path(owner, path) do
      compile_and_load(path, owner)
    end
  end

  defp compile_and_load(path, owner) do
    # Compile + classify FIRST, in their own failure domain: a broken file
    # fails here, before we touch any registry or tracking, so a failed reload
    # neither registers nor drops the prior version.
    case Loader.compile(path) do
      {:ok, contribution} ->
        case GenServer.call(__MODULE__, {:commit_load, owner, path, contribution}, 30_000) do
          {:ok, summary} ->
            load_ref = make_ref()
            :ok = GenServer.call(__MODULE__, {:begin_setup, load_ref}, 30_000)

            setup_status =
              Loader.run_setups(
                contribution.ext_mods,
                ExtensionAPI.new(owner, path, load_ref)
              )

            recorded_collisions =
              GenServer.call(__MODULE__, {:take_setup_collisions, load_ref}, 30_000)

            case List.first(recorded_collisions) || ownership_collision(setup_status) do
              nil ->
                {:ok, annotate_setup_status(summary, setup_status)}

              collision ->
                # setup may have registered other owner-tagged effects before
                # hitting this collision. Reject the contribution as a unit,
                # then restore the prior owner's code outside the GenServer.
                :ok = GenServer.call(__MODULE__, {:uninstall, owner}, 30_000)
                {:error, collision}
            end

          {:error, _reason} = err ->
            :ok =
              GenServer.call(
                __MODULE__,
                {:purge_rejected_compile, contribution.modules},
                30_000
              )

            err
        end

      {:error, reason, emitted_modules} ->
        # Compiler-traced modules are exact: unlike an AST scan this includes
        # dynamic names and excludes modules in quotes/non-executed branches.
        :ok = GenServer.call(__MODULE__, {:purge_partial_compile, emitted_modules}, 30_000)
        {:error, reason}
    end
  end

  defp ensure_distinct_owners(paths) do
    paths
    |> Enum.find(fn {_owner, owner_paths} -> length(owner_paths) > 1 end)
    |> case do
      nil -> :ok
      {owner, owner_paths} -> {:error, {:owner_collision, owner, Enum.sort(owner_paths)}}
    end
  end

  defp ensure_owner_path(owner, path) do
    paths =
      [path | extension_files()]
      |> index_owner_paths()
      |> Map.get(owner, [])

    case paths do
      [_path] -> :ok
      paths -> {:error, {:owner_collision, owner, Enum.sort(paths)}}
    end
  end

  defp index_owner_paths(paths) do
    paths
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.group_by(&ext_id/1)
  end

  # `Code.compile_file/1` installs each module as it is emitted. Keep the exact
  # accepted BEAM binaries in state so a later partial/rejected compile can put
  # the last-known-good code back without rereading source that may now be
  # broken. Untracked modules fall back to the original code-path beam (or are
  # removed when they were introduced by the failed compile).
  defp restore_compiled_modules(candidates, state, context) do
    candidates
    |> Enum.uniq()
    |> Enum.each(fn module ->
      Logger.warning("[extensions] restoring #{inspect(module)} after #{context}")
      restore_current_version(module, state.module_versions)
    end)
  end

  # Commit a compiled file: purge the prior version's side effects, apply the
  # new ones, and return the new tracking. The tracking is assembled BEFORE the
  # side effects run — Code.compile_file/1 already redefined the modules in the
  # VM, so even if a step below raises unexpectedly, the caller gets tracking
  # that claims them for this owner (never the stale pre-purge snapshot, which
  # would let registries and state tracking silently diverge).
  defp commit_load(owner, path, contribution, state) do
    %{
      modules: modules,
      beams: beams,
      ext_mods: ext_mods,
      tool_mods: tool_mods,
      tool_names: tool_names,
      metadata: metadata
    } = contribution

    case tool_owner_conflicts(owner, tool_names, state) do
      [] ->
        commit_contribution(
          owner,
          path,
          beams,
          modules,
          ext_mods,
          tool_mods,
          tool_names,
          metadata,
          state
        )

      [{name, existing_owner} | _] ->
        {{:error, {:tool_owner_collision, name, existing_owner, owner}}, state}
    end
  end

  defp commit_contribution(
         owner,
         path,
         beams,
         modules,
         ext_mods,
         tool_mods,
         tool_names,
         metadata,
         state
       ) do
    conflicts = module_conflicts(owner, modules, state)
    log_conflicts(owner, conflicts)

    pairs = Enum.zip(tool_names, tool_mods)

    module_versions = put_module_versions(state.module_versions, owner, path, beams)

    owners =
      state.owners
      |> Map.reject(fn {_name, existing_owner} -> existing_owner == owner end)
      |> then(fn current -> Enum.reduce(pairs, current, &Map.put(&2, elem(&1, 0), owner)) end)

    committed = %{
      state
      | contrib: Map.put(state.contrib, owner, MapSet.new(pairs)),
        owners: owners,
        modules: Map.put(state.modules, owner, modules),
        module_versions: module_versions,
        metadata: Map.put(state.metadata, owner, metadata),
        paths: Map.put(state.paths, owner, path)
    }

    try do
      # Modules the new file still defines were just redefined by the compile
      # above and must survive the purge; ones it dropped are restored/removed.
      purge_owner_effects(owner, state,
        keep_modules: modules,
        module_versions: module_versions
      )

      Enum.each(pairs, fn {name, mod} -> :ets.insert(@table, {name, mod}) end)
      {{:ok, build_summary(owner, tool_names, ext_mods, conflicts)}, committed}
    rescue
      e -> {{:error, {:register, Exception.message(e)}}, committed}
    catch
      kind, reason -> {{:error, {:register, {kind, reason}}}, committed}
    end
  end

  defp annotate_setup_status(summary, :ok), do: summary

  defp annotate_setup_status(summary, {:error, reason}) do
    Map.put(summary, :warning, "setup did not finish cleanly: #{inspect(reason)}")
  end

  defp ownership_collision({:error, {:setup_errors, errors}}) do
    Enum.find_value(errors, fn {_module, reason} -> ownership_collision_reason(reason) end)
  end

  defp ownership_collision(_setup_status), do: nil

  defp ownership_collision_reason(
         {:tool_owner_collision, _name, _existing_owner, _attempted_owner} = reason
       ),
       do: reason

  defp ownership_collision_reason(
         {:provider_owner_collision, _api, _existing_owner, _attempted_owner} = reason
       ),
       do: reason

  defp ownership_collision_reason(_reason), do: nil

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

  # ---- registration + owner tracking ----------------------------------------

  defp do_register(module, definition, opts, state) do
    name = definition.name
    owner = normalize_registration_owner(opts[:owner])

    case tool_owner(state, name) do
      nil ->
        :ets.insert(@table, {name, module})
        {{:ok, module}, track(name, module, owner, state)}

      ^owner ->
        :ets.insert(@table, {name, module})
        {{:ok, module}, track(name, module, owner, state)}

      existing_owner ->
        {{:error, {:tool_owner_collision, name, existing_owner, owner}}, state}
    end
  end

  defp track(name, _module, @host_owner, state),
    do: put_in(state.owners[name], @host_owner)

  defp track(name, module, owner, state) do
    pairs = Map.get(state.contrib, owner, MapSet.new())

    state
    |> put_in([:contrib, owner], MapSet.put(pairs, {name, module}))
    |> put_in([:owners, name], owner)
  end

  defp tool_owner_conflicts(owner, names, state) do
    Enum.flat_map(names, fn name ->
      case tool_owner(state, name) do
        nil -> []
        ^owner -> []
        other_owner -> [{name, other_owner}]
      end
    end)
  end

  defp tool_owner(state, name), do: Map.get(state.owners, name)

  defp normalize_registration_owner(nil), do: @host_owner
  defp normalize_registration_owner(owner), do: owner

  defp insert(module) do
    :ets.insert(@table, {module.name(), module})
    {:ok, module}
  end

  # Remove an owner's tools from the table (restoring a built-in if one was
  # shadowed), drop its hooks/providers/UI/processes via purgers, undo its module
  # definitions (minus `keep_modules`), and clear its tracking.
  defp purge_owner(owner, state, opts \\ []) do
    module_versions = drop_owner_versions(state.module_versions, owner)
    purge_opts = Keyword.put(opts, :module_versions, module_versions)
    purge_owner_effects(owner, state, purge_opts)

    %{
      state
      | contrib: Map.delete(state.contrib, owner),
        owners:
          Map.reject(state.owners, fn {_name, existing_owner} -> existing_owner == owner end),
        modules: Map.delete(state.modules, owner),
        module_versions: module_versions,
        metadata: Map.delete(state.metadata, owner),
        paths: Map.delete(state.paths, owner)
    }
  end

  # The side-effect half of a purge (registries + module definitions), with no
  # tracking change — commit_load assembles the new tracking itself, up front.
  defp purge_owner_effects(owner, state, opts) do
    keep = MapSet.new(Keyword.get(opts, :keep_modules, []))
    module_versions = Keyword.fetch!(opts, :module_versions)

    state.modules
    |> Map.get(owner, [])
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> Enum.each(&restore_removed_owner_module(&1, owner, state.module_versions, module_versions))

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

  defp put_module_versions(module_versions, owner, path, beams) do
    module_versions
    |> drop_owner_versions(owner)
    |> then(fn versions ->
      Enum.reduce(beams, versions, fn {module, beam}, acc ->
        version = %{owner: owner, path: path, beam: beam}
        Map.update(acc, module, [version], &[version | &1])
      end)
    end)
  end

  defp drop_owner_versions(module_versions, owner) do
    Enum.reduce(module_versions, %{}, fn {module, versions}, acc ->
      case Enum.reject(versions, &(&1.owner == owner)) do
        [] -> acc
        remaining -> Map.put(acc, module, remaining)
      end
    end)
  end

  defp restore_removed_owner_module(module, owner, old_versions, new_versions) do
    case Map.get(old_versions, module, []) do
      [%{owner: ^owner} | _rest] -> restore_current_version(module, new_versions)
      _not_active -> :ok
    end
  end

  defp restore_current_version(module, module_versions) do
    case Map.get(module_versions, module, []) do
      [version | _rest] -> load_version(module, version)
      [] -> restore_module(module)
    end
  end

  defp load_version(module, %{path: path, beam: beam}) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)

    case :code.load_binary(module, String.to_charlist(path), beam) do
      {:module, ^module} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[extensions] could not restore accepted BEAM for #{inspect(module)}: " <>
            inspect(reason)
        )

        restore_module(module)
    end
  catch
    kind, reason ->
      Logger.error(
        "[extensions] restoring accepted BEAM for #{inspect(module)} #{kind}: #{inspect(reason)}"
      )

      restore_module(module)
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

  defp ensure_managed_source(path) do
    case managed_source?(path) do
      true -> :ok
      false -> {:error, :external_source}
    end
  end

  defp managed_source?(nil), do: false

  defp managed_source?(path) do
    relative = path |> Path.expand() |> Path.relative_to(Path.expand(dir()))

    Path.type(relative) == :relative and relative != ".." and
      not String.starts_with?(relative, "../")
  end

  defp commit_lifecycle_change(paths, message) do
    Versioning.ensure_repo(dir())

    case Versioning.commit_paths(dir(), paths, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[extensions] #{message} succeeded but could not be git-versioned: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ext_id(path), do: path |> Path.basename(".ex") |> sanitize_owner()

  defp disabled_owner(path), do: path |> Path.basename(".ex.disabled") |> sanitize_owner()

  defp file_for(owner) do
    case GenServer.call(__MODULE__, {:path_for, owner}) do
      {:ok, path} -> existing_file(path, owner)
      :error -> find_file(extension_files(), owner, &ext_id/1)
    end
  catch
    :exit, _reason -> find_file(extension_files(), owner, &ext_id/1)
  end

  defp existing_file(path, owner) do
    case File.regular?(path) do
      true -> {:ok, path}
      false -> find_file(extension_files(), owner, &ext_id/1)
    end
  end

  defp disabled_file_for(owner),
    do: dir() |> disabled_files() |> find_file(owner, &disabled_owner/1)

  defp find_file(paths, owner, owner_fun) do
    case Enum.find(paths, &(owner_fun.(&1) == owner)) do
      nil -> :error
      path -> {:ok, path}
    end
  end

  defp disabled_files(dir) do
    case File.dir?(dir) do
      true -> dir |> Path.join("*.ex.disabled") |> Path.wildcard()
      false -> []
    end
  end
end
