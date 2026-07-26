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

  alias Catalyst.{ExtensionAPI, Hooks, Tasks}

  alias Catalyst.Extensions.{
    BootGuard,
    Load,
    Presenter,
    Processes,
    Server,
    Sources,
    Transaction
  }

  alias Catalyst.Tools.Registry, as: ToolRegistry

  @table :catalyst_tools
  @host_roles [:application, :registry]

  @runtime_generation_key {__MODULE__, :runtime_generation}

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
  def start_link(opts \\ []), do: Server.start_link(Keyword.put(opts, :name, __MODULE__))

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    {Server, Keyword.put(opts, :name, __MODULE__)}
    |> Supervisor.child_spec(id: __MODULE__)
  end

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

  @doc """
  Acknowledge that an optional host has finished wiring its extension kinds.

  The operation is idempotent. It starts the one deferred web bootstrap only
  after both web leases are live, returns `{:skipped, {:host_not_ready, :web}}`
  while either is absent, and returns
  `{:skipped, :extension_runtime_unavailable}` when this server is absent.
  Running and completed bootstraps return `:ok` without repeating setup.
  """
  @spec bootstrap() :: :ok | {:skipped, term()}
  def bootstrap do
    case Process.whereis(__MODULE__) do
      nil -> {:skipped, :extension_runtime_unavailable}
      _pid -> GenServer.call(__MODULE__, :bootstrap)
    end
  end

  @doc """
  Compile an extension source file and apply its contributions (tools + anything
  its `setup/1` registers). Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec load_file(Path.t()) :: {:ok, summary()} | {:error, term()}
  defdelegate load_file(path), to: Load

  @doc """
  (Re)load all `*.ex` files in the extensions directory.

  Returns `{:ok, %{loaded: summaries, failed: [{path, reason}]}}` — per-file
  failures are reported, not swallowed. Crash-detected safe mode is cleared
  only when `failed` is empty.
  """
  @spec load_all() :: {:ok, load_result()} | {:error, term()}
  defdelegate load_all(), to: Load

  @doc """
  Legacy compatibility entry point for hosts that used to reload after wiring.

  New host startup code must publish its leases and call `bootstrap/0`, which
  coordinates the one boot load without repeating `setup/1`. This function
  remains for this release and keeps its former return shapes.
  """
  @spec reload_after_wiring() :: {:ok, load_result()} | {:error, term()} | {:skipped, term()}
  @deprecated "Use bootstrap/0 during host startup or load_all/0 for an explicit reload"
  defdelegate reload_after_wiring(), to: Load

  @doc "Remove every contribution made by `owner` (tools here + hooks/providers/UI)."
  @spec uninstall(String.t()) :: :ok
  defdelegate uninstall(owner), to: Load

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
  def locked(fun) when is_function(fun, 0), do: Transaction.run(fun)

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
    Sources.disabled_files()
    |> Enum.map(&%{owner: Sources.disabled_owner(&1), path: &1})
    |> Enum.sort_by(& &1.owner)
  end

  @doc "The source file backing `owner`, enabled or disabled. `:error` for file-less owners."
  @spec source_file(String.t()) :: {:ok, Path.t()} | :error
  defdelegate source_file(owner), to: Load

  @doc "Reload one extension from its source file (purge prior contributions + recompile)."
  @spec reload(String.t()) :: {:ok, summary()} | {:error, term()}
  defdelegate reload(owner), to: Load

  @doc """
  Disable an extension without deleting it: purge its contributions and rename
  its source to `<file>.ex.disabled` so neither `load_all/0` nor the next boot
  picks it up. Reversed by `enable/1`. The rename is committed to the
  extensions repo so rollback history stays coherent.
  """
  @spec disable(String.t()) :: {:ok, Path.t()} | {:error, term()}
  defdelegate disable(owner), to: Load

  @doc """
  Re-enable a disabled extension: rename `<file>.ex.disabled` back and load it.
  A file that fails to compile stays enabled (and keeps failing visibly) —
  the load error is returned so the caller can surface it.
  """
  @spec enable(String.t()) :: {:ok, summary()} | {:error, term()}
  defdelegate enable(owner), to: Load

  @doc "Directory holding extension source files."
  @spec dir() :: Path.t()
  defdelegate dir(), to: Sources

  @doc "Normalize a source-file/name string into its extension owner id."
  @spec sanitize_owner(String.t()) :: String.t()
  defdelegate sanitize_owner(name), to: Sources

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

  @doc "Boot status: loaded, waiting for a host, safe mode, or a load failure."
  @spec boot_status() ::
          :ok
          | {:waiting_for_host, :web}
          | {:safe_mode, :env | :crash_detected}
          | {:load_failed, term()}
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
  defdelegate format_error(reason), to: Presenter

  @doc """
  Human-readable `{title, reason}` for a `boot_status/0` value — the single
  presenter behind the safe-mode/boot-failure banners in the UIs.
  """
  @spec describe_boot_status(term()) :: {String.t(), String.t()}
  defdelegate describe_boot_status(status), to: Presenter

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
          boot_status:
            :ok
            | {:waiting_for_host, :web}
            | {:safe_mode, :env | :crash_detected}
            | {:load_failed, term()},
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
  defdelegate rollback(owner), to: Load

  @doc false
  @spec register_extension_tool(ExtensionAPI.t(), module()) :: term()
  def register_extension_tool(%ExtensionAPI{owner: owner}, module) do
    register_tool(module, owner: owner)
  end

  @doc false
  @spec register_extension_hook(ExtensionAPI.t(), atom(), function(), keyword()) :: term()
  def register_extension_hook(%ExtensionAPI{owner: owner}, point, fun, opts) do
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

  @doc false
  @spec inject_boot_result(term()) :: :ok
  def inject_boot_result(result) do
    send(__MODULE__, {:boot_load_finished, result})
    :ok
  end
end
