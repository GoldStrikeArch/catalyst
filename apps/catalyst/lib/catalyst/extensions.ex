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

  alias Catalyst.Extensions.{
    BootGuard,
    Contribution,
    Loader,
    ModuleVersions,
    Owner,
    Processes,
    State,
    Transaction,
    Versioning
  }

  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @table :catalyst_tools
  @host_roles [:application, :registry]

  @runtime_generation_key {__MODULE__, :runtime_generation}
  @runtime_footprint_key {__MODULE__, :runtime_footprint}

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
    case tool_rows() do
      {:ok, rows} -> rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      :error -> Catalyst.Tools.Registry.default_tools()
    end
  end

  @doc "Look up a tool module by its tool name. Returns `{:ok, module}` or `:error`."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case lookup_tool(name) do
      [{^name, module}] -> {:ok, module}
      _ -> :error
    end
  end

  @doc "Names of all registered tools."
  @spec names() :: [String.t()]
  def names do
    case tool_rows() do
      {:ok, rows} -> Enum.map(rows, &elem(&1, 0))
      :error -> Enum.map(ToolRegistry.default_tools(), & &1.name())
    end
  end

  # The rescue wraps only the :ets call: while the named table is absent
  # (registry restarting) reads fall back; a malformed row would be a real bug
  # and must not read as "no tools".
  defp tool_rows do
    {:ok, :ets.tab2list(@table)}
  rescue
    ArgumentError -> :error
  end

  defp lookup_tool(name) do
    :ets.lookup(@table, name)
  rescue
    ArgumentError -> []
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
  Writes are serialized through this server (the `:persistent_term` map stays
  the read store), so concurrent registrations cannot lose entries.
  """
  @spec register_reseeder(module(), atom()) :: :ok
  def register_reseeder(mod, fun) when is_atom(mod) and is_atom(fun) do
    GenServer.call(__MODULE__, {:register_reseeder, mod, fun})
  end

  @doc """
  Register a live host lease used to coordinate extension bootstrap.

  A lease is valid only while its process remains alive. The host supplies the
  same role again after a restart, replacing the prior lease without retaining a
  monitor in the extension coordinator.
  """
  @spec register_host(atom(), :application | :registry, pid()) :: :ok
  def register_host(host, role, pid)
      when is_atom(host) and role in @host_roles and is_pid(pid) do
    :persistent_term.put({__MODULE__, :host_lease, host, role}, pid)
    :ok
  end

  @doc "Whether every required lease for `host` names a live process."
  @spec host_ready?(atom()) :: boolean()
  def host_ready?(host) when is_atom(host) do
    Enum.all?(@host_roles, fn role ->
      case :persistent_term.get({__MODULE__, :host_lease, host, role}, nil) do
        pid when is_pid(pid) -> Process.alive?(pid)
        _missing -> false
      end
    end)
  end

  @doc "Acknowledge that an optional host has finished wiring its extension kinds."
  @spec bootstrap() :: :ok | {:skipped, term()}
  def bootstrap do
    case Process.whereis(__MODULE__) do
      nil -> {:skipped, :extension_runtime_unavailable}
      _pid -> :ok
    end
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
  @spec record_setup_collision(GenServer.server(), reference(), term()) :: :ok
  def record_setup_collision(server, load_ref, reason) when is_reference(load_ref) do
    GenServer.call(server, {:record_setup_collision, load_ref, reason})
  end

  @doc false
  @spec generation_token() :: reference() | nil
  def generation_token, do: :persistent_term.get(@runtime_generation_key, nil)

  @doc false
  @spec generation_current?(reference() | nil) :: boolean()
  def generation_current?(generation) when is_reference(generation),
    do: generation == generation_token()

  def generation_current?(_generation), do: false

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

  @typedoc """
  One live owner's footprint: source file (nil when registered without a file),
  tool names, modules its file defined, merged `metadata/0`. `:status` is
  `:degraded` when the owner's last purge left residue (`:purge_failures`
  records which subsystems failed); a later successful purge or reload clears it.
  """
  @type loaded_info :: %{
          owner: String.t(),
          path: Path.t() | nil,
          managed?: boolean(),
          tools: [String.t()],
          modules: [module()],
          metadata: map(),
          status: :ok | :degraded,
          purge_failures: [ExtensionAPI.purger_failure()]
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

  def format_error({:owner_collision, kind, key, existing, attempted}) do
    "#{collision_subject(kind, key)} is already owned by #{inspect(existing)}; " <>
      "#{inspect(attempted)} cannot replace it"
  end

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  defp collision_subject(:context_policy, _key), do: "context policy"

  defp collision_subject(kind, key),
    do: "#{kind |> Atom.to_string() |> String.replace("_", " ")} #{inspect(key)}"

  @doc """
  Human-readable `{title, reason}` for a `boot_status/0` value — the single
  presenter behind the safe-mode/boot-failure banners in the UIs.
  """
  @spec describe_boot_status(term()) :: {String.t(), String.t()}
  def describe_boot_status(:ok),
    do: {"Extensions loaded", "The boot-time extension load completed."}

  def describe_boot_status({:safe_mode, :env}) do
    {"Safe mode — extensions were not loaded",
     "CATALYST_SAFE_MODE is set, so loading was skipped on purpose."}
  end

  def describe_boot_status({:safe_mode, :crash_detected}) do
    {"Safe mode — extensions were not loaded",
     "The previous boot died while extensions were active, so this boot skipped them."}
  end

  def describe_boot_status({:load_failed, reason}) do
    {"Extension boot load failed",
     "The boot-time load returned an error: #{format_error(reason)}."}
  end

  def describe_boot_status(_status),
    do: {"Extensions were not loaded", "Extension loading was skipped."}

  @typedoc "One `snapshot/0` owner entry: `loaded_info/0` plus a bounded process count."
  @type snapshot_owner :: %{
          owner: String.t(),
          path: Path.t() | nil,
          managed?: boolean(),
          tools: [String.t()],
          modules: [module()],
          metadata: map(),
          status: :ok | :degraded,
          purge_failures: [ExtensionAPI.purger_failure()],
          process_count: non_neg_integer() | :unknown
        }

  @typedoc "Bounded runtime summary for UIs."
  @type snapshot :: %{
          boot_status: :ok | {:safe_mode, :env | :crash_detected} | {:load_failed, term()},
          safe_mode?: boolean(),
          generation: reference() | nil,
          owners: [snapshot_owner()]
        }

  @doc """
  Bounded, UI-safe summary of the extension runtime: boot status, the current
  runtime generation, and every live owner — including degraded owners and
  their `purge_failures` — with a per-owner process count.

  Process counts are computed in one supervised task with a deadline
  (`config :catalyst, :extensions_snapshot_timeout`, default 1000 ms), because
  counting extension processes can hang on extension-authored supervisors
  (`Catalyst.Extensions.Processes.list/1`). On deadline the counts degrade to
  `:unknown` instead of blocking the caller, so this is safe to call from
  render/data paths.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    owners = list_loaded()
    counts = bounded_process_counts(Enum.map(owners, & &1.owner))

    %{
      boot_status: boot_status(),
      safe_mode?: safe_mode?(),
      generation: generation_token(),
      owners: Enum.map(owners, &Map.put(&1, :process_count, Map.get(counts, &1.owner, :unknown)))
    }
  end

  defp bounded_process_counts([]), do: %{}

  defp bounded_process_counts(owners) do
    task = Tasks.async(fn -> Map.new(owners, &{&1, length(Processes.list(&1))}) end)

    case Tasks.await(task, snapshot_timeout()) do
      {:ok, counts} -> counts
      _timeout_or_exit -> %{}
    end
  end

  defp snapshot_timeout,
    do: Application.get_env(:catalyst, :extensions_snapshot_timeout, 1_000)

  @doc """
  Roll back the most recent non-reverted extension change and reload.

  A tagged domain operation composing, under the extensions load lock: a git
  revert of the newest non-reverted commit — scoped to `owner`'s source file
  when an owner id is given, repo-wide when `nil` — followed by a full
  `load_all/0`. Returns `{:ok, load_result}` (its `failed` list carries
  per-file reload failures so callers can present partial outcomes) or a
  tagged error: `{:error, :no_file}` for an unknown owner,
  `{:error, :nothing_to_rollback}` when history is exhausted,
  `{:error, {:reload_failed, reason}}` when the revert applied but the reload
  itself errored, or the underlying git failure.
  """
  @spec rollback(String.t() | nil) :: {:ok, load_result()} | {:error, term()}
  def rollback(owner) when is_binary(owner) or is_nil(owner) do
    serialized_load(fn ->
      with :ok <- rollback_source(owner) do
        case load_all() do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, {:reload_failed, reason}}
        end
      end
    end)
  end

  defp rollback_source(nil), do: Versioning.rollback(dir())

  defp rollback_source(owner) do
    case source_file(owner) do
      {:ok, path} -> Versioning.rollback_file(dir(), path)
      :error -> {:error, :no_file}
    end
  end

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :persistent_term.put(@runtime_generation_key, make_ref())
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    seed_builtins()
    wire_core_kinds()
    hook_generation = Hooks.begin_runtime_generation()
    ensure_guide()
    start_reseeders()

    state = %{State.new() | hook_generation: hook_generation}

    cond do
      safe_mode?() ->
        put_boot_status({:safe_mode, :env})
        Logger.info("[extensions] safe mode (CATALYST_SAFE_MODE) — skipping extension load")
        {:ok, revoke_prior_generation(state)}

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

        {:ok, revoke_prior_generation(state)}

      true ->
        normal_boot(state)
    end
  end

  # A restart into safe mode must revoke what the dead generation left behind:
  # owner-tagged registry entries (hooks/providers/UI…) live in tables owned
  # outside this process, and extension-defined modules stay loaded in the VM.
  # The persisted runtime footprint lists the prior generation's owners and
  # modules: purge each owner through the registered purgers, then restore or
  # remove its module definitions. A failing purger keeps the owner tracked as
  # degraded, so cleanup stays retryable instead of silently forgotten.
  defp revoke_prior_generation(state) do
    runtime_footprint()
    |> Enum.reduce(state, fn {owner, modules}, st ->
      purge_result = ExtensionAPI.purge_owner(owner)
      Enum.each(modules, &restore_module/1)
      State.record_purge_result(st, owner, purge_result)
    end)
    |> persist_footprint()
  end

  defp normal_boot(state) do
    put_boot_status(:ok)
    # Arm a token-identified marker: the stabilization timer may only bless
    # the marker THIS boot armed — never one a later boot (or an explicit
    # mark_booting) re-armed in the meantime.
    {:ok, %{state | boot_token: BootGuard.arm()}, {:continue, :load_all}}
  end

  @impl true
  def handle_continue(:load_all, state) do
    server = self()

    case Tasks.start_background(fn -> send(server, {:boot_load_finished, boot_load()}) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> boot_load_failed(reason)
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

  # Failed boot outcomes were already recorded by the boot task itself, inside
  # the load lock and gated on its generation (`record_boot_outcome/1`) — so a
  # boot result that lost the race to a newer explicit load, or that belongs to
  # a dead generation, can never overwrite the newer published status here.
  def handle_info({:boot_load_finished, _result}, state), do: {:noreply, state}

  def handle_info(:mark_boot_ok, state) do
    case {boot_status(), state.boot_token} do
      {:ok, token} when is_binary(token) -> BootGuard.mark_ok(token)
      _not_this_boots_clean_window -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:reseed_finished, _results}, state) do
    {:noreply, publish_hook_readiness(state)}
  end

  def handle_info(:reseed_deadline, %{bootstrap: :pending} = state) do
    Logger.warning(
      "[extensions] reseeders did not finish within #{reseed_deadline_ms()}ms — " <>
        "publishing hook readiness anyway"
    )

    {:noreply, publish_hook_readiness(state)}
  end

  def handle_info(:reseed_deadline, state), do: {:noreply, state}

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

  def handle_call({:register_reseeder, mod, fun}, _from, state) do
    :persistent_term.put({__MODULE__, :reseeders}, Map.put(reseeders(), {mod, fun}, true))
    {:reply, :ok, state}
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
    # Degraded owners (a prior purge left residue) are retried here too, so a
    # full reload heals them even when their source file is already gone. The
    # persisted footprint adds owners a prior server generation tracked (this
    # process restarted since), so their registry residue is purged as well.
    state =
      state.modules
      |> Map.keys()
      |> Enum.concat(Map.keys(state.degraded))
      |> Enum.concat(Map.keys(runtime_footprint()))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(live_owners, &1))
      |> Enum.reduce(state, fn owner, st -> purge_owner(owner, st) end)

    {:reply, :ok, persist_footprint(state)}
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
    {:reply, result, persist_footprint(state)}
  end

  def handle_call({:uninstall, owner}, _from, state) do
    {:reply, :ok, persist_footprint(purge_owner(owner, state))}
  end

  def handle_call({:owner_snapshot, owner}, _from, state) do
    {:reply, State.owner_snapshot(state, owner), state}
  end

  def handle_call({:path_for, owner}, _from, state) do
    case Map.fetch(state.paths, owner) do
      {:ok, path} -> {:reply, {:ok, path}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    owners = State.tracked_owners(state)

    snapshot =
      Enum.map(owners, fn owner ->
        tools =
          state.contrib |> Map.get(owner, MapSet.new()) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

        purge_failures = Map.get(state.degraded, owner, [])

        {owner,
         %{
           owner: owner,
           path: Map.get(state.paths, owner),
           managed?: managed_source?(Map.get(state.paths, owner)),
           tools: tools,
           modules: Map.get(state.modules, owner, []),
           metadata: Map.get(state.metadata, owner, %{}),
           status: owner_status(purge_failures),
           purge_failures: purge_failures
         }}
      end)

    {:reply, snapshot, state}
  end

  defp owner_status([]), do: :ok
  defp owner_status(_failures), do: :degraded

  defp finish_setup_entry(nil), do: []

  defp finish_setup_entry(%{monitor: monitor, collisions: collisions}) do
    Process.demonitor(monitor, [:flush])
    Enum.reverse(collisions)
  end

  # ---- boot helpers ---------------------------------------------------------

  defp boot_load do
    serialized_load(fn ->
      result = do_load_all()
      record_boot_outcome(result)
      result
    end)
  catch
    kind, reason ->
      record_boot_outcome({:error, {kind, reason}})
      {:error, {kind, reason}}
  end

  # Boot outcomes are recorded where they are produced — under the load lock,
  # so status writes follow lock order and cannot overwrite a newer explicit
  # load's status — and only while this boot's generation is still current, so
  # a boot task that survived into a replacement server (safe mode included)
  # cannot overwrite the replacement's status either.
  defp record_boot_outcome(result) do
    case generation_current?(Transaction.generation()) do
      true -> record_current_boot_outcome(result)
      false -> :ok
    end
  end

  defp record_current_boot_outcome({:ok, %{failed: []}}), do: :ok
  defp record_current_boot_outcome({:ok, %{failed: failures}}), do: boot_load_failed(failures)
  defp record_current_boot_outcome({:error, reason}), do: boot_load_failed(reason)

  # Log BEFORE publishing the status: callers (and tests) synchronize on the
  # published status, so the log line must already be emitted when they do.
  defp boot_load_failed(reason) do
    Logger.error(
      "[extensions] boot load failed; leaving the boot marker armed: #{inspect(reason)}"
    )

    put_boot_status({:load_failed, reason})
  end

  defp seed_builtins do
    Enum.each(Catalyst.Tools.Registry.default_tools(), &insert/1)
  end

  @doc false
  @spec register_extension_tool(ExtensionAPI.t(), module()) :: term()
  def register_extension_tool(%ExtensionAPI{owner: owner}, module) do
    register_tool(module, owner: owner)
  end

  @doc false
  @spec register_extension_hook(ExtensionAPI.t(), atom(), function(), keyword()) :: term()
  def register_extension_hook(%ExtensionAPI{owner: owner}, point, fun, opts) do
    # Force the file owner: extension-supplied :owner would survive purge_owner/1.
    Hooks.register(point, fun, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_observer(ExtensionAPI.t(), function(), keyword()) :: term()
  def register_extension_observer(%ExtensionAPI{owner: owner}, fun, opts) do
    Hooks.on(fun, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec start_extension_process(ExtensionAPI.t(), Supervisor.child_spec()) :: term()
  def start_extension_process(%ExtensionAPI{owner: owner}, child_spec) do
    Processes.start_child(owner || "anonymous", child_spec)
  end

  # Wire the extension kinds that core can back, and the hooks owner-purger.
  # Provider (E3) and UI (E5) kinds/purgers are wired by their own subsystems.
  defp wire_core_kinds do
    ExtensionAPI.register_kind(:tool, &__MODULE__.register_extension_tool/2)
    ExtensionAPI.register_kind(:hook, &__MODULE__.register_extension_hook/4)
    ExtensionAPI.register_kind(:event, &__MODULE__.register_extension_observer/3)
    ExtensionAPI.register_kind(:process, &__MODULE__.start_extension_process/2)

    ExtensionAPI.register_purger(&Hooks.unregister/1)
    ExtensionAPI.register_purger(&Processes.stop_owner/1)
  end

  defp reseeders, do: :persistent_term.get({__MODULE__, :reseeders}, %{})

  # Reseeding is an acknowledged bootstrap phase: hook readiness (which gates
  # every per-turn snapshot) is published only once all reseeders have reported
  # back — or the bounded deadline fires — so a turn cannot start against a
  # half-reseeded tool table. The work still runs outside this server because
  # reseeders call back into it (`register_tool/2`); running them inline in
  # `init/1` would deadlock.
  defp start_reseeders do
    server = self()
    Process.send_after(server, :reseed_deadline, reseed_deadline_ms())

    case Tasks.start_background(fn -> send(server, {:reseed_finished, run_reseeders()}) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[extensions] could not start reseeders: #{inspect(reason)}")
        send(server, {:reseed_finished, []})
        :ok
    end
  end

  defp run_reseeders do
    Enum.map(Map.keys(reseeders()), fn {mod, fun} -> {{mod, fun}, run_reseeder(mod, fun)} end)
  end

  defp run_reseeder(mod, fun) do
    apply(mod, fun, [])
    :ok
  catch
    kind, reason ->
      Logger.warning("[extensions] reseeder #{inspect(mod)}.#{fun}/0 #{kind}: #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  # Completing bootstrap publishes hook readiness: per-turn snapshot capture
  # succeeds only once the reseed phase has been acknowledged (or timed out).
  defp publish_hook_readiness(%{bootstrap: :complete} = state), do: state

  defp publish_hook_readiness(state) do
    Hooks.mark_runtime_ready(state.hook_generation)
    %{state | bootstrap: :complete}
  end

  defp reseed_deadline_ms, do: Application.get_env(:catalyst, :reseed_deadline_ms, 5_000)

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

  # One serialized-transaction implementation: Transaction.run/1 shares this
  # module's load lock and re-entrancy context, and pins the server + runtime
  # generation at transaction start so a load that survives a server restart
  # is detected as stale at commit time (commit_compiled/3).
  defp serialized_load(fun), do: Transaction.run(fun)

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
        commit_compiled(path, owner, contribution)

      {:error, reason, emitted_modules} ->
        # Compiler-traced modules are exact: unlike an AST scan this includes
        # dynamic names and excludes modules in quotes/non-executed branches.
        :ok = GenServer.call(__MODULE__, {:purge_partial_compile, emitted_modules}, 30_000)
        {:error, reason}
    end
  end

  # The extension runtime can restart while a transaction is compiling (the
  # transaction task is supervised independently and holds the load lock).
  # Its work then belongs to a dead generation: committing would resurrect
  # extension code into the replacement generation — safe mode included — so
  # the compiled modules are dropped instead.
  defp commit_compiled(path, owner, contribution) do
    case generation_current?(Transaction.generation()) do
      true ->
        commit_current_generation(path, owner, contribution)

      false ->
        :ok =
          GenServer.call(__MODULE__, {:purge_rejected_compile, contribution.modules}, 30_000)

        {:error, :stale_extension_generation}
    end
  end

  defp commit_current_generation(path, owner, contribution) do
    # Committing drops the prior accepted version's tracking and beams, so
    # a later setup-phase rejection needs this pre-commit snapshot to keep
    # the "rejected contribution restores the accepted version" contract.
    prior = GenServer.call(__MODULE__, {:owner_snapshot, owner}, 30_000)

    case GenServer.call(__MODULE__, {:commit_load, owner, path, contribution}, 30_000) do
      {:ok, summary} ->
        load_ref = make_ref()
        :ok = GenServer.call(__MODULE__, {:begin_setup, load_ref}, 30_000)

        setup_status =
          Loader.run_setups(contribution.ext_mods, ExtensionAPI.new(owner, load_ref))

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
            restore_prior_version(owner, prior)
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
  # would let registries and state tracking silently diverge). This
  # error-with-committed-state outcome is deliberate (see the moduledoc).
  defp commit_load(owner, path, %Contribution{} = contribution, state) do
    case State.tool_owner_conflicts(state, owner, contribution.tool_names) do
      [] ->
        commit_contribution(owner, path, contribution, state)

      [{name, existing_owner} | _] ->
        {{:error, {:owner_collision, :tool, name, existing_owner, owner}}, state}
    end
  end

  defp commit_contribution(owner, path, contribution, state) do
    conflicts = State.module_conflicts(state, owner, contribution.modules)
    log_conflicts(owner, conflicts)

    committed = State.commit_contribution(state, owner, path, contribution)

    try do
      purge_result =
        purge_owner_effects(owner, state,
          keep_modules: contribution.modules,
          module_versions: committed.module_versions
        )

      Enum.each(Contribution.pairs(contribution), fn {name, mod} ->
        :ets.insert(@table, {name, mod})
      end)

      {{:ok, build_summary(owner, contribution.tool_names, contribution.ext_mods, conflicts)},
       State.record_purge_result(committed, owner, purge_result)}
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
         {:owner_collision, _kind, _key, _existing_owner, _attempted_owner} = reason
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
    owner = Owner.normalize(opts[:owner])

    case State.tool_owner(state, name) do
      nil ->
        :ets.insert(@table, {name, module})
        {{:ok, module}, State.track(state, name, module, owner)}

      ^owner ->
        :ets.insert(@table, {name, module})
        {{:ok, module}, State.track(state, name, module, owner)}

      existing_owner ->
        {{:error, {:owner_collision, :tool, name, existing_owner, owner}}, state}
    end
  end

  defp insert(module) do
    :ets.insert(@table, {module.name(), module})
    {:ok, module}
  end

  # Remove an owner's tools from the table (restoring a built-in if one was
  # shadowed), drop its hooks/providers/UI/processes via purgers, undo its module
  # definitions (minus `keep_modules`), and clear its tracking. A failed
  # subsystem purge keeps the owner in `state.degraded` instead of forgetting it.
  defp purge_owner(owner, state, opts \\ []) do
    module_versions = State.drop_owner_versions(state.module_versions, owner)
    purge_opts = Keyword.put(opts, :module_versions, module_versions)
    purge_result = purge_owner_effects(owner, state, purge_opts)

    state
    |> State.drop_owner(owner, module_versions)
    |> State.record_purge_result(owner, purge_result)
  end

  # The side-effect half of a purge (registries + module definitions), with no
  # tracking change — commit_load assembles the new tracking itself, up front.
  # Returns the tagged per-subsystem purger outcome from ExtensionAPI.
  defp purge_owner_effects(owner, state, opts) do
    keep = MapSet.new(Keyword.get(opts, :keep_modules, []))
    module_versions = Keyword.fetch!(opts, :module_versions)

    removed_modules =
      state.modules
      |> Map.get(owner, [])
      |> Enum.reject(&MapSet.member?(keep, &1))

    Enum.each(
      removed_modules,
      &restore_removed_owner_module(&1, owner, state.module_versions, module_versions)
    )

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

    # Purged metadata must not linger in the tool registry cache (its executor
    # closure would pin dead code); the next registration revalidates.
    pairs
    |> Enum.map(&elem(&1, 1))
    |> Enum.concat(removed_modules)
    |> Enum.uniq()
    |> Enum.each(&ToolRegistry.invalidate/1)

    ExtensionAPI.purge_owner(owner)
  end

  # Best-effort reinstatement of the last accepted version after its reload was
  # rejected: reload the retained beams, recommit tracking/tools through the
  # normal accepted-load pipeline, and re-run setup so owner-tagged
  # registrations return. A failure here leaves the owner unloaded (the
  # pre-snapshot behavior) and is logged rather than raised.
  defp restore_prior_version(_owner, :none), do: :ok

  defp restore_prior_version(owner, {:ok, snapshot}) do
    case ModuleVersions.load_beams(snapshot.path, snapshot.beams) do
      :ok ->
        contribution = %Contribution{
          modules: snapshot.modules,
          beams: snapshot.beams,
          ext_mods: Enum.filter(snapshot.modules, &Catalyst.Extension.extension_module?/1),
          tool_mods: snapshot.tool_mods,
          tool_names: snapshot.tool_names,
          metadata: snapshot.metadata
        }

        case GenServer.call(
               __MODULE__,
               {:commit_load, owner, snapshot.path, contribution},
               30_000
             ) do
          {:ok, _summary} -> restore_prior_setup(owner, contribution)
          {:error, reason} -> log_failed_restore(owner, reason)
        end

      {:error, failures} ->
        log_failed_restore(owner, {:load_beams, failures})
    end
  end

  defp restore_prior_setup(owner, contribution) do
    load_ref = make_ref()
    :ok = GenServer.call(__MODULE__, {:begin_setup, load_ref}, 30_000)

    setup_status =
      Loader.run_setups(contribution.ext_mods, ExtensionAPI.new(owner, load_ref))

    collisions = GenServer.call(__MODULE__, {:take_setup_collisions, load_ref}, 30_000)

    case List.first(collisions) || setup_restore_failure(setup_status) do
      nil ->
        Logger.info("[extensions] restored prior accepted version of #{owner}")
        :ok

      reason ->
        :ok = GenServer.call(__MODULE__, {:uninstall, owner}, 30_000)
        log_failed_restore(owner, reason)
    end
  end

  # Rollback must not report success when setup failed for any reason. Ownership
  # collisions are one failure mode; timeouts and other setup errors are too.
  # Loader.run_setups/2 returns exactly :ok | {:error, _}; the compiler rejects
  # an unreachable catch-all clause here.
  defp setup_restore_failure(:ok), do: nil
  defp setup_restore_failure({:error, reason}), do: reason

  defp log_failed_restore(owner, reason) do
    Logger.warning("[extensions] could not restore prior version of #{owner}: #{inspect(reason)}")

    :ok
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

  # The footprint mirrors owner tracking into `:persistent_term` so it survives
  # this process: a replacement generation (safe mode especially) uses it to
  # revoke registry residue and module definitions the dead generation left
  # behind (`revoke_prior_generation/1`, `{:purge_gone, _}`).
  defp persist_footprint(state) do
    :persistent_term.put(@runtime_footprint_key, State.footprint(state))
    state
  end

  defp runtime_footprint, do: :persistent_term.get(@runtime_footprint_key, %{})

  @doc false
  # Test seam: deliver a (possibly stale) boot-load result message without
  # tests fabricating the private message shape.
  @spec inject_boot_result(term()) :: :ok
  def inject_boot_result(result) do
    send(__MODULE__, {:boot_load_finished, result})
    :ok
  end

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
