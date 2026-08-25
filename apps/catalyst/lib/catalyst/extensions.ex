defmodule Catalyst.Extensions do
  @moduledoc """
  Runtime extension registry — the mechanism behind "self-developing" Catalyst.

  Loads immutable bundled extension sources and user source files (`*.ex` in
  `dir/0`) at runtime. Bundled sources load first; a user file with the same
  basename replaces that bundled extension. This module is the public API and
  the registered coordinator process. Live contributions, including tools, are
  stored in `Catalyst.Runtime.Registry`; filesystem and compiler sagas run in
  `Catalyst.Extensions.Load`. Because the Elixir compiler ships in an OTP
  release, this works inside a packaged binary too — the binary stays immutable
  while new modules are loaded into the running VM from a user-writable
  directory.

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
  contributions through the shared owner-purge path,
  so reloads are idempotent. A file that fails to **compile** registers nothing —
  all selected sources are compiled and classified in a disposable external
  BEAM before any live registry or module is touched, and the prior accepted
  version stays active. A successful stage rebuilds the runtime projection from
  source. The current active contribution's reconstructible binary cache
  restores a prior owner if live registration rejects its staged contribution;
  no accepted-BEAM history is retained. Once a file compiles, its registration
  is committed even if a
  `setup/1` raises or times out mid-way: whatever it registered before failing
  stays registered (owner-tagged, so the next reload or uninstall purges it
  cleanly).

  Set `CATALYST_SAFE_MODE=1` (or `config :catalyst, :safe_mode, true`) to load
  only immutable bundled extensions at boot, so bad user code cannot brick
  startup. Safe mode also engages **automatically**: a boot-marker file
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
    Load,
    Modules,
    Processes,
    Sources
  }

  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Runtime.Registry, as: Runtime
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @ready_poll_ms 10
  @ready_timeout 30_000
  @load_lock {__MODULE__, :load_lock}
  @load_context_key {__MODULE__, :load_context}
  @load_server_key {__MODULE__, :load_server}
  @runtime_footprint_key {__MODULE__, :runtime_footprint}
  @reseeders_key {__MODULE__, :reseeders}
  @boot_status_key {__MODULE__, :boot_status}

  @typedoc "Per-file load summary. `:conflicts` is present only when this file redefines modules another loaded file also defines."
  @type summary :: %{
          required(:owner) => String.t(),
          required(:tools) => [String.t()],
          required(:extensions) => [module()],
          optional(:source) => :bundled | :user,
          optional(:conflicts) => [{String.t(), [module()]}],
          optional(:warning) => String.t()
        }

  @typedoc "Result of a full directory load: per-file summaries plus per-file failures."
  @type load_result :: %{loaded: [summary()], failed: [{Path.t(), term()}]}

  # ---- API ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    super(Keyword.put(opts, :name, __MODULE__))
  end

  @doc "All registered tool modules."
  @spec tools() :: [module()]
  def tools do
    :extensions
    |> tool_index()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_name, entry} -> entry.module end)
  end

  @doc "Look up a tool module by its tool name. Returns `{:ok, module}` or `:error`."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case Runtime.fetch(:tool, name) do
      {:ok, %{module: module}, _owner} -> {:ok, module}
      {:ok, module, _owner} when is_atom(module) -> {:ok, module}
      :error -> fetch_builtin(name)
    end
  end

  @doc "Names of all registered tools."
  @spec names() :: [String.t()]
  def names, do: Enum.map(tools(), & &1.name())

  @doc "Register a validated tool module. `opts[:owner]` tags it for purge-on-reload."
  @spec register_tool(module(), keyword()) :: {:ok, module()} | {:error, term()}
  def register_tool(module, opts \\ []) do
    with {:ok, entry} <- ToolRegistry.entry(module) do
      GenServer.call(__MODULE__, {:register, entry, opts})
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
  Register a live host lease after it has wired its extension kinds.

  A lease is valid only while its process remains alive. The host supplies the
  lease again after a restart, replacing the prior value without retaining a
  monitor in the extension coordinator.
  """
  @spec register_host(atom(), pid()) :: :ok
  def register_host(host, pid) when is_atom(host) and is_pid(pid) do
    :persistent_term.put({__MODULE__, :host_lease, host}, pid)
    :ok
  end

  @doc "Whether `host` has published a live lease."
  @spec host_ready?(atom()) :: boolean()
  def host_ready?(host) when is_atom(host) do
    case :persistent_term.get({__MODULE__, :host_lease, host}, nil) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _missing -> false
    end
  end

  @doc """
  Acknowledge that an optional host has finished wiring its extension kinds.

  The operation is idempotent. It starts the one deferred web bootstrap only
  after the web lease is live, returns `{:skipped, {:host_not_ready, :web}}`
  while it is absent, and returns
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
  Wait for extension bootstrap or recovery to publish a stable runtime generation.

  Returns `:ok` when tools, hooks, providers, and the other extension registries
  are ready for a run. Returns `{:error, :extension_runtime_unavailable}` when
  the extension coordinator is not running, or `{:error, :timeout}` when it
  does not become ready within `timeout` milliseconds.
  """
  @spec await_ready(non_neg_integer()) ::
          :ok | {:error, :extension_runtime_unavailable | :timeout}
  def await_ready(timeout \\ @ready_timeout) when is_integer(timeout) and timeout >= 0 do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :extension_runtime_unavailable}
      _pid -> await_ready_until(System.monotonic_time(:millisecond) + timeout)
    end
  end

  @doc """
  Compile an extension source file and apply its contributions (tools + anything
  its `setup/1` registers). Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec load_file(Path.t()) :: {:ok, summary()} | {:error, term()}
  defdelegate load_file(path), to: Load

  @doc """
  (Re)load bundled extensions followed by all `*.ex` files in the user
  extensions directory.

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

  @doc """
  Run `fun` under the extensions load lock — the same lock `load_file/1`,
  `load_all/0`, `disable/1`… take. Calls nested by that transaction are
  re-entrant; this lets the installer compose write → load → commit into one
  critical section that a concurrent load cannot interleave.
  """
  @spec locked((-> result)) :: result when result: term()
  def locked(fun) when is_function(fun, 0) do
    case Process.get(@load_context_key, false) do
      true -> fun.()
      false -> run_locked_task(fun)
    end
  end

  @doc false
  @spec locked_inline((-> result)) :: result when result: term()
  def locked_inline(fun) when is_function(fun, 0) do
    case Process.get(@load_context_key, false) do
      true -> fun.()
      false -> with_load_lock(transaction_server(), fun)
    end
  end

  @doc false
  @spec transaction_server() :: GenServer.server()
  def transaction_server,
    do: Process.get(@load_server_key, Process.whereis(__MODULE__) || __MODULE__)

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

  @doc "Validated name-to-entry index for a tool source."
  @spec tool_index([module()] | (-> [module()]) | term()) :: ToolRegistry.index()
  def tool_index(tools) when is_list(tools), do: ToolRegistry.index(tools)
  def tool_index(fun) when is_function(fun, 0), do: fun.() |> ToolRegistry.index()

  def tool_index(_) do
    ToolRegistry.default_tools()
    |> ToolRegistry.index()
    |> Map.merge(runtime_tool_entries())
  end

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
  def boot_status, do: :persistent_term.get(@boot_status_key, :ok)

  defp await_ready_until(deadline) do
    case remaining_time(deadline) do
      0 ->
        {:error, :timeout}

      remaining ->
        await_current_coordinator(deadline, remaining)
    end
  end

  defp await_current_coordinator(deadline, remaining) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        case coordinator_ready?(pid, remaining) do
          true -> :ok
          false -> wait_for_runtime(deadline)
        end

      nil ->
        wait_for_runtime(deadline)
    end
  end

  defp coordinator_ready?(pid, timeout) do
    monitor = Process.monitor(pid)

    try do
      case GenServer.call(pid, :runtime_readiness, timeout) do
        {:ready, _generation} -> current_coordinator?(pid, monitor)
        :recovering -> false
      end
    catch
      :exit, _reason -> false
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp current_coordinator?(pid, monitor) do
    case Process.whereis(__MODULE__) do
      ^pid ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> false
        after
          0 -> Process.alive?(pid)
        end

      _missing_or_replacement ->
        false
    end
  end

  defp wait_for_runtime(deadline) do
    receive do
    after
      min(@ready_poll_ms, remaining_time(deadline)) -> await_ready_until(deadline)
    end
  end

  defp remaining_time(deadline) do
    deadline
    |> Kernel.-(System.monotonic_time(:millisecond))
    |> max(0)
  end

  defp runtime_tool_entries do
    Runtime.list(:tool)
    |> Enum.reduce(%{}, fn
      %{key: name, value: %{module: _module} = entry}, entries ->
        Map.put(entries, name, entry)

      %{key: name, value: module}, entries when is_atom(module) ->
        case ToolRegistry.cached_entry(module) do
          {:ok, entry} -> Map.put(entries, name, entry)
          {:error, _reason} -> entries
        end
    end)
  end

  defp fetch_builtin(name) do
    case Enum.find(ToolRegistry.default_tools(), &(&1.name() == name)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

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

  def format_error({:not_a_tool, module}) do
    "#{inspect(module)} is not a tool " <>
      "(needs name/0, description/0, parameters/0, execute/2)"
  end

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

  @doc """
  Human-readable `{title, reason}` for a `boot_status/0` value — the single
  presenter behind the safe-mode/boot-failure banners in the UIs.
  """
  @spec describe_boot_status(term()) :: {String.t(), String.t()}
  def describe_boot_status(:ok),
    do: {"Extensions loaded", "The boot-time extension load completed."}

  def describe_boot_status({:waiting_for_host, :web}) do
    {"Waiting for the web extension host",
     "Extensions will load after the web registry finishes wiring its contribution kinds."}
  end

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
          boot_status:
            :ok
            | {:waiting_for_host, :web}
            | {:safe_mode, :env | :crash_detected}
            | {:load_failed, term()},
          safe_mode?: boolean(),
          owners: [snapshot_owner()]
        }

  @doc """
  Bounded, UI-safe summary of the extension runtime: boot status and every live
  owner — including degraded owners and their `purge_failures` — with a
  per-owner process count.

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

  defp run_locked_task(fun) do
    server = transaction_server()

    case start_lock_task(server, fun) do
      {:ok, task} -> await_lock_task(task)
      :error -> with_load_lock(server, fun)
    end
  end

  defp start_lock_task(server, fun) do
    task =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        capture_lock_outcome(fn -> with_load_lock(server, fun) end)
      end)

    {:ok, task}
  catch
    :exit, _reason -> :error
  end

  defp await_lock_task(task) do
    case Task.yield(task, :infinity) do
      {:ok, {:return, result}} -> result
      {:ok, {:raised, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
      {:exit, reason} -> exit(reason)
    end
  end

  defp capture_lock_outcome(fun) do
    {:return, fun.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp with_load_lock(server, fun) do
    :global.trans(
      {@load_lock, self()},
      fn ->
        Process.put(@load_context_key, true)
        Process.put(@load_server_key, server)

        try do
          fun.()
        after
          Process.delete(@load_context_key)
          Process.delete(@load_server_key)
        end
      end,
      [node()],
      :infinity
    )
  end

  defp collision_subject(:context_policy, _key), do: "context policy"

  defp collision_subject(kind, key),
    do: "#{kind |> Atom.to_string() |> String.replace("_", " ")} #{inspect(key)}"

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

  @impl true
  def init(:ok) do
    wire_core_kinds()
    :ok = Hooks.begin_runtime_rebuild()

    state =
      new_state()
      |> revoke_prior_runtime()

    cond do
      safe_mode?() ->
        safe_boot(state, {:safe_mode, :env})

      BootGuard.crashed_last_boot?() and Sources.enabled_files() == [] ->
        Logger.info(
          "[extensions] stale boot marker but no extension files in #{Sources.dir()} — " <>
            "booting normally"
        )

        normal_boot(state)

      BootGuard.crashed_last_boot?() ->
        safe_boot(state, {:safe_mode, :crash_detected})

      web_capable?() and not host_ready?(:web) ->
        put_boot_status({:waiting_for_host, :web})
        {:ok, state}

      true ->
        normal_boot(state)
    end
  end

  @impl true
  def handle_continue({:bootstrap, mode}, state) do
    server = self()

    case Tasks.start_background(fn ->
           result = bootstrap_workflow(mode)
           send(server, {:bootstrap_finished, mode, result})
         end) do
      {:ok, pid} ->
        link_bootstrap(pid)
        {:noreply, state}

      {:error, reason} ->
        bootstrap_start_failed(mode, reason)
        {:noreply, complete_bootstrap(state)}
    end
  end

  @impl true
  def handle_info({:bootstrap_finished, mode, result}, state) do
    finish_boot_load(mode, result)
    {:noreply, complete_bootstrap(state)}
  end

  # Compatibility test seam for injecting stale boot results without knowing
  # the internal bootstrap workflow message.
  def handle_info({:boot_load_finished, {:ok, %{failed: []}}}, state) do
    Process.send_after(self(), :mark_boot_ok, boot_stable_ms())
    {:noreply, state}
  end

  def handle_info({:boot_load_finished, _result}, state), do: {:noreply, state}

  def handle_info(:mark_boot_ok, state) do
    case {boot_status(), state.boot_token} do
      {:ok, token} when is_binary(token) -> BootGuard.mark_ok(token)
      _not_this_boots_clean_window -> :ok
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
  def handle_call(:bootstrap, _from, %{bootstrap: phase} = state)
      when phase in [:running, :complete] do
    {:reply, :ok, state}
  end

  def handle_call(:bootstrap, _from, %{bootstrap: :waiting} = state) do
    case web_capable?() and not host_ready?(:web) do
      true ->
        {:reply, {:skipped, {:host_not_ready, :web}}, state}

      false ->
        put_boot_status(:ok)

        state = %{
          state
          | bootstrap: :running,
            boot_token: BootGuard.arm()
        }

        {:reply, :ok, state, {:continue, {:bootstrap, :load}}}
    end
  end

  def handle_call(:explicit_load_finished, _from, state), do: explicit_load_finished(state)

  def handle_call({:register, entry, opts}, _from, state) do
    {result, state} = do_register(entry, opts, state)
    {:reply, result, state}
  end

  def handle_call({:register_reseeder, mod, fun}, _from, state) do
    :persistent_term.put(@reseeders_key, Map.put(reseeders(), {mod, fun}, true))
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

  def handle_call({:commit_load, owner, path, contribution}, _from, state) do
    {result, state} = commit_load(owner, path, contribution, state)
    {:reply, result, persist_footprint(state)}
  end

  def handle_call({:uninstall, owner}, _from, state) do
    {:reply, :ok, persist_footprint(purge_owner(owner, state))}
  end

  def handle_call({:owner_snapshot, owner}, _from, state) do
    {:reply, contribution_snapshot(state, owner, runtime_tool_pairs(owner)), state}
  end

  def handle_call({:path_for, owner}, _from, state) do
    case Map.fetch(state.paths, owner) do
      {:ok, path} -> {:reply, {:ok, path}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snapshot =
      state
      |> tracked_owners()
      |> Enum.map(&owner_snapshot(&1, state))

    {:reply, snapshot, state}
  end

  def handle_call(:runtime_readiness, _from, state) do
    readiness =
      case {state.bootstrap, Hooks.capture_snapshot([])} do
        {:complete, {:ok, _snapshot}} ->
          {:ready, :current}

        _recovering ->
          :recovering
      end

    {:reply, readiness, state}
  end

  defp safe_boot(state, status) do
    put_boot_status(status)
    log_safe_mode(status)

    state
    |> start_bootstrap(:bundled)
  end

  defp log_safe_mode({:safe_mode, :env}) do
    Logger.info("[extensions] safe mode (CATALYST_SAFE_MODE) — loading bundled extensions only")
  end

  defp log_safe_mode({:safe_mode, :crash_detected}) do
    Logger.warning(
      "[extensions] previous boot died while user extensions were active — loading bundled " <>
        "extensions only. Fix the files in #{Sources.dir()} and run the reload_extensions tool."
    )
  end

  defp revoke_prior_runtime(state) do
    runtime_footprint()
    |> Enum.reduce(state, fn {owner, modules}, current ->
      purge_result = ExtensionAPI.purge_owner(owner)
      Enum.each(modules, &Modules.restore_original/1)
      record_purge_result(current, owner, purge_result)
    end)
    |> persist_footprint()
  end

  defp normal_boot(state) do
    put_boot_status(:ok)

    state
    |> Map.put(:boot_token, BootGuard.arm())
    |> start_bootstrap(:load)
  end

  defp start_bootstrap(state, mode) do
    {:ok, %{state | bootstrap: :running}, {:continue, {:bootstrap, mode}}}
  end

  defp link_bootstrap(pid) do
    Process.link(pid)
  catch
    :error, :noproc -> :ok
  end

  defp owner_snapshot(owner, state) do
    tools =
      owner
      |> runtime_tool_pairs()
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    purge_failures = Map.get(state.degraded, owner, [])

    {owner,
     %{
       owner: owner,
       path: Map.get(state.paths, owner),
       managed?: Sources.managed?(Map.get(state.paths, owner)),
       tools: tools,
       modules: Map.get(state.modules, owner, []),
       metadata: Map.get(state.metadata, owner, %{}),
       status: owner_status(purge_failures),
       purge_failures: purge_failures
     }}
  end

  defp owner_status([]), do: :ok
  defp owner_status(_failures), do: :degraded

  defp finish_setup_entry(nil), do: []

  defp finish_setup_entry(%{monitor: monitor, collisions: collisions}) do
    Process.demonitor(monitor, [:flush])
    Enum.reverse(collisions)
  end

  defp explicit_load_finished(%{bootstrap: :waiting} = state) do
    BootGuard.mark_ok()
    put_boot_status(:ok)
    state = %{state | bootstrap: :running}
    {:reply, :ok, state, {:continue, {:bootstrap, :skip_load}}}
  end

  defp explicit_load_finished(state) do
    BootGuard.mark_ok()
    put_boot_status(:ok)
    {:reply, :ok, state}
  end

  defp boot_load do
    result = Load.boot_load()
    record_boot_outcome(result)
    result
  catch
    kind, reason ->
      record_boot_outcome({:error, {kind, reason}})
      {:error, {kind, reason}}
  end

  defp bundled_boot_load do
    Load.boot_load_bundled()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp record_boot_outcome({:ok, %{failed: []}}), do: :ok
  defp record_boot_outcome({:ok, %{failed: failures}}), do: boot_load_failed(failures)
  defp record_boot_outcome({:error, reason}), do: boot_load_failed(reason)

  defp boot_load_failed(reason) do
    Logger.error(
      "[extensions] boot load failed; leaving the boot marker armed: #{inspect(reason)}"
    )

    put_boot_status({:load_failed, reason})
  end

  defp wire_core_kinds do
    ExtensionAPI.register_kind(:tool, &Catalyst.Extensions.register_extension_tool/2)
    ExtensionAPI.register_kind(:hook, &Catalyst.Extensions.register_extension_hook/4)
    ExtensionAPI.register_kind(:event, &Catalyst.Extensions.register_extension_observer/3)
    ExtensionAPI.register_kind(:process, &Catalyst.Extensions.start_extension_process/2)

    ExtensionAPI.register_kind(
      :provider,
      &Catalyst.LLM.Registry.register_extension_provider/3
    )

    ExtensionAPI.register_kind(
      :prompt,
      &Catalyst.Prompt.Registry.register_extension_prompt/4
    )

    ExtensionAPI.register_kind(
      :prompt_policy,
      &Catalyst.Prompt.Registry.register_extension_prompt_policy/3
    )

    ExtensionAPI.register_kind(
      :workflow,
      &Catalyst.Workflow.Registry.register_extension_workflow/4
    )

    ExtensionAPI.register_kind(
      :workflow_source,
      &Catalyst.Workflow.Registry.register_extension_source/3
    )

    ExtensionAPI.register_kind(
      :context_policy,
      &Catalyst.Context.Registry.register_extension_policy/3
    )

    ExtensionAPI.register_kind(
      :context_threshold,
      &Catalyst.Context.Registry.register_extension_threshold/4
    )

    ExtensionAPI.register_kind(
      :capability,
      &Catalyst.Capabilities.register_extension_capability/3
    )
  end

  defp reseeders, do: :persistent_term.get(@reseeders_key, %{})

  defp web_capable? do
    not is_nil(Application.spec(:catalyst_web, :vsn))
  end

  defp bootstrap_workflow(mode) do
    run_nonfatal_bootstrap_step(:guide_publication, &ensure_guide/0)
    run_nonfatal_bootstrap_step(:reseeding, &run_reseeders_bounded/0)

    case mode do
      :load -> boot_load()
      :bundled -> bundled_boot_load()
      :skip_load -> :skipped
    end
  end

  defp run_nonfatal_bootstrap_step(step, fun) do
    fun.()
  catch
    kind, reason ->
      Logger.warning("[extensions] bootstrap #{step} #{kind}: #{inspect(reason)}; continuing")

      :ok
  end

  defp bootstrap_start_failed(:load, reason) do
    boot_load_failed({:bootstrap_start_failed, reason})
  end

  defp bootstrap_start_failed(:bundled, reason) do
    Logger.error("[extensions] could not load bundled extensions: #{inspect(reason)}")
  end

  defp bootstrap_start_failed(:skip_load, reason) do
    Logger.warning("[extensions] could not start bootstrap workflow: #{inspect(reason)}")
  end

  defp finish_boot_load(:load, {:ok, %{failed: []}}) do
    Process.send_after(self(), :mark_boot_ok, boot_stable_ms())
    :ok
  end

  defp finish_boot_load(_mode, _result), do: :ok

  defp complete_bootstrap(%{bootstrap: :complete} = state), do: state

  defp complete_bootstrap(state) do
    :ok = Hooks.mark_runtime_ready()
    %{state | bootstrap: :complete}
  end

  defp run_reseeders_bounded do
    task = Tasks.async(&run_reseeders/0)

    case Tasks.await(task, reseed_deadline_ms()) do
      {:ok, results} ->
        results

      {:exit, reason} ->
        Logger.warning("[extensions] reseeders exited: #{inspect(reason)}")
        []

      :timeout ->
        Logger.warning(
          "[extensions] reseeders exceeded #{reseed_deadline_ms()}ms; continuing bootstrap"
        )

        []
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

  defp reseed_deadline_ms, do: Application.get_env(:catalyst, :reseed_deadline_ms, 5_000)

  defp ensure_guide do
    case publish_guide() do
      :ok ->
        :ok

      {:error, destination, reason} ->
        log_guide_failure(destination, reason)
        :ok
    end
  catch
    kind, reason ->
      log_guide_failure(Catalyst.Paths.join("guide.md"), {kind, reason})
      :ok
  end

  defp publish_guide do
    source = Application.app_dir(:catalyst, "priv/guide.md")
    destination = Catalyst.Paths.join("guide.md")

    with {:ok, contents} <- File.read(source),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- AtomicWrite.write(destination, contents) do
      :ok
    else
      {:error, reason} -> {:error, destination, reason}
    end
  end

  defp log_guide_failure(destination, reason) do
    Logger.warning(
      "[extensions] could not publish extension guide to #{destination}: #{inspect(reason)}"
    )
  end

  defp commit_load(owner, path, %Contribution{} = contribution, state) do
    case runtime_tool_conflicts(owner, contribution.tool_names) do
      [] ->
        commit_contribution(owner, path, contribution, state)

      [{name, existing_owner} | _rest] ->
        {{:error, {:owner_collision, :tool, name, existing_owner, owner}}, state}
    end
  end

  defp commit_contribution(owner, path, contribution, state) do
    conflicts = module_conflicts(state, owner, contribution.modules)
    log_conflicts(owner, conflicts)

    try do
      purge_result = purge_owner_effects(owner, state)

      Enum.each(contribution.tool_entries, fn {name, entry} ->
        :ok = Runtime.put(:tool, name, entry, owner: owner)
      end)

      result = build_summary(owner, contribution.tool_names, contribution.ext_mods, conflicts)
      committed = put_contribution_state(state, owner, path, contribution)
      {{:ok, result}, record_purge_result(committed, owner, purge_result)}
    rescue
      error -> {{:error, {:register, Exception.message(error)}}, state}
    catch
      kind, reason -> {{:error, {:register, {kind, reason}}}, state}
    end
  end

  defp build_summary(owner, tool_names, extension_modules, []),
    do: %{owner: owner, tools: tool_names, extensions: extension_modules}

  defp build_summary(owner, tool_names, extension_modules, conflicts),
    do: %{
      owner: owner,
      tools: tool_names,
      extensions: extension_modules,
      conflicts: conflicts
    }

  defp log_conflicts(_owner, []), do: :ok

  defp log_conflicts(owner, conflicts) do
    Enum.each(conflicts, fn {other, modules} ->
      Logger.warning(
        "[extensions] #{owner} redefines #{inspect(modules)} also defined by extension " <>
          "\"#{other}\" — purging/reloading either file will affect the other"
      )
    end)
  end

  defp do_register(%{module: module, definition: definition} = entry, opts, state) do
    name = definition.name
    owner = Runtime.normalize_owner(opts[:owner])

    case Runtime.put(:tool, name, entry, owner: owner) do
      :ok -> {{:ok, module}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp purge_owner(owner, state) do
    purge_result = purge_owner_effects(owner, state)

    state
    |> drop_owner(owner)
    |> record_purge_result(owner, purge_result)
  end

  defp purge_owner_effects(owner, state) do
    owner
    |> runtime_tool_pairs()
    |> Enum.map(&elem(&1, 1))
    |> Enum.concat(Map.get(state.modules, owner, []))
    |> Enum.uniq()
    |> Enum.each(&ToolRegistry.invalidate/1)

    ExtensionAPI.purge_owner(owner)
  end

  defp runtime_tool_conflicts(owner, names) do
    Enum.flat_map(names, fn name ->
      case Runtime.fetch(:tool, name) do
        {:ok, _entry, ^owner} -> []
        {:ok, _entry, existing_owner} -> [{name, existing_owner}]
        :error -> []
      end
    end)
  end

  defp runtime_tool_pairs(owner) do
    :tool
    |> Runtime.list()
    |> Enum.flat_map(fn
      %{key: name, owner: ^owner, value: %{module: module}} -> [{name, module}]
      %{key: name, owner: ^owner, value: module} when is_atom(module) -> [{name, module}]
      _other_owner_or_shape -> []
    end)
  end

  defp put_boot_status(status), do: :persistent_term.put(@boot_status_key, status)

  defp persist_footprint(state) do
    :persistent_term.put(@runtime_footprint_key, runtime_state_footprint(state))
    state
  end

  defp new_state do
    %{
      modules: %{},
      beams: %{},
      extensions: %{},
      metadata: %{},
      paths: %{},
      degraded: %{},
      setup_collisions: %{},
      boot_token: nil,
      bootstrap: :waiting
    }
  end

  defp put_contribution_state(state, owner, path, contribution) do
    %{
      state
      | modules: Map.put(state.modules, owner, contribution.modules),
        beams: Map.put(state.beams, owner, contribution.beams),
        extensions: Map.put(state.extensions, owner, contribution.ext_mods),
        metadata: Map.put(state.metadata, owner, contribution.metadata),
        paths: Map.put(state.paths, owner, path)
    }
  end

  defp module_conflicts(state, owner, modules) do
    modules = MapSet.new(modules)

    state.modules
    |> Map.delete(owner)
    |> Enum.flat_map(fn {other, other_modules} ->
      case Enum.filter(other_modules, &MapSet.member?(modules, &1)) do
        [] -> []
        overlap -> [{other, overlap}]
      end
    end)
  end

  defp drop_owner(state, owner) do
    %{
      state
      | modules: Map.delete(state.modules, owner),
        beams: Map.delete(state.beams, owner),
        extensions: Map.delete(state.extensions, owner),
        metadata: Map.delete(state.metadata, owner),
        paths: Map.delete(state.paths, owner)
    }
  end

  defp record_purge_result(state, owner, {:ok, _purged}),
    do: %{state | degraded: Map.delete(state.degraded, owner)}

  defp record_purge_result(state, owner, {:error, failures}) do
    Logger.warning(
      "[extensions] purge of #{inspect(owner)} left residue; owner kept as degraded: " <>
        inspect(failures)
    )

    %{state | degraded: Map.put(state.degraded, owner, failures)}
  end

  defp contribution_snapshot(state, owner, tools) do
    with {:ok, path} <- Map.fetch(state.paths, owner),
         {:ok, modules} <- Map.fetch(state.modules, owner) do
      pairs = Enum.sort(tools)

      {:ok,
       %{
         path: path,
         modules: modules,
         beams: Map.get(state.beams, owner, %{}),
         ext_mods: Map.get(state.extensions, owner, []),
         tool_names: Enum.map(pairs, &elem(&1, 0)),
         tool_mods: Enum.map(pairs, &elem(&1, 1)),
         metadata: Map.get(state.metadata, owner, %{})
       }}
    else
      _missing -> :none
    end
  end

  defp tracked_owners(state) do
    state.modules
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(MapSet.new(Map.keys(state.degraded)))
  end

  defp runtime_state_footprint(state) do
    state.degraded
    |> Map.keys()
    |> Map.new(&{&1, []})
    |> Map.merge(state.modules)
  end

  defp runtime_footprint, do: :persistent_term.get(@runtime_footprint_key, %{})

  defp boot_stable_ms, do: Application.get_env(:catalyst, :boot_stable_ms, 10_000)
end
