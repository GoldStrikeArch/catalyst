defmodule Catalyst.Extensions.Server do
  @moduledoc """
  State-owning GenServer behind the stable `Catalyst.Extensions` facade.

  The process remains registered as `Catalyst.Extensions`. It owns canonical
  contribution state and the live tool table; filesystem, compiler, and
  lifecycle sagas run in `Catalyst.Extensions.Load`.
  """

  use GenServer
  require Logger

  alias Catalyst.{ExtensionAPI, Hooks, Tasks}

  alias Catalyst.Extensions.{
    BootGuard,
    Contribution,
    Load,
    ModuleVersions,
    Owner,
    Processes,
    Sources,
    State
  }

  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @server Catalyst.Extensions
  @table :catalyst_tools
  @runtime_generation_key {Catalyst.Extensions, :runtime_generation}
  @runtime_footprint_key {Catalyst.Extensions, :runtime_footprint}
  @reseeders_key {Catalyst.Extensions, :reseeders}
  @boot_status_key {Catalyst.Extensions, :boot_status}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, @server))
  end

  @impl true
  def init(:ok) do
    :persistent_term.put(@runtime_generation_key, make_ref())
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    seed_builtins()
    wire_core_kinds()
    hook_generation = Hooks.begin_runtime_generation()

    state = %{State.new() | hook_generation: hook_generation}

    cond do
      Catalyst.Extensions.safe_mode?() ->
        safe_boot(state, {:safe_mode, :env})

      BootGuard.crashed_last_boot?() and Sources.enabled_files() == [] ->
        Logger.info(
          "[extensions] stale boot marker but no extension files in #{Sources.dir()} — " <>
            "booting normally"
        )

        normal_boot(state)

      BootGuard.crashed_last_boot?() ->
        safe_boot(state, {:safe_mode, :crash_detected})

      web_capable?() and not Catalyst.Extensions.host_ready?(:web) ->
        put_boot_status({:waiting_for_host, :web})
        {:ok, state}

      true ->
        normal_boot(state)
    end
  end

  defp safe_boot(state, status) do
    put_boot_status(status)
    log_safe_mode(status)

    state
    |> revoke_prior_generation()
    |> start_bootstrap(:skip_load)
  end

  defp log_safe_mode({:safe_mode, :env}) do
    Logger.info("[extensions] safe mode (CATALYST_SAFE_MODE) — skipping extension load")
  end

  defp log_safe_mode({:safe_mode, :crash_detected}) do
    Logger.warning(
      "[extensions] previous boot died while extensions were active — skipping extension " <>
        "load. Fix the files in #{Sources.dir()} and run the reload_extensions tool."
    )
  end

  defp revoke_prior_generation(state) do
    runtime_footprint()
    |> Enum.reduce(state, fn {owner, modules}, current ->
      purge_result = ExtensionAPI.purge_owner(owner)
      Enum.each(modules, &ModuleVersions.restore_original/1)
      State.record_purge_result(current, owner, purge_result)
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

  @impl true
  def handle_continue({:bootstrap, mode}, state) do
    server = self()
    generation = Catalyst.Extensions.generation_token()

    case Tasks.start_background(fn ->
           result = bootstrap_workflow(mode, generation)
           send(server, {:bootstrap_finished, generation, mode, result})
         end) do
      {:ok, _pid} ->
        {:noreply, state}

      {:error, reason} ->
        bootstrap_start_failed(mode, reason)
        {:noreply, complete_bootstrap(state)}
    end
  end

  @impl true
  def handle_info({:bootstrap_finished, generation, mode, result}, state) do
    case Catalyst.Extensions.generation_current?(generation) do
      true ->
        finish_boot_load(mode, result)
        {:noreply, complete_bootstrap(state)}

      false ->
        {:noreply, state}
    end
  end

  # Compatibility test seam for injecting stale boot results without knowing
  # the internal bootstrap workflow message.
  def handle_info({:boot_load_finished, {:ok, %{failed: []}}}, state) do
    Process.send_after(self(), :mark_boot_ok, boot_stable_ms())
    {:noreply, state}
  end

  def handle_info({:boot_load_finished, _result}, state), do: {:noreply, state}

  def handle_info(:mark_boot_ok, state) do
    case {Catalyst.Extensions.boot_status(), state.boot_token} do
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
    case web_capable?() and not Catalyst.Extensions.host_ready?(:web) do
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

  def handle_call({:explicit_load_finished, generation}, _from, state) do
    case Catalyst.Extensions.generation_current?(generation) do
      true -> explicit_load_finished(state)
      false -> {:reply, {:error, :stale_extension_generation}, state}
    end
  end

  def handle_call({:register, module, definition, opts}, _from, state) do
    {result, state} = do_register(module, definition, opts, state)
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

  def handle_call({:purge_gone, live_owners}, _from, state) do
    state =
      state.modules
      |> Map.keys()
      |> Enum.concat(Map.keys(state.degraded))
      |> Enum.concat(Map.keys(runtime_footprint()))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(live_owners, &1))
      |> Enum.reduce(state, fn owner, current -> purge_owner(owner, current) end)

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
    snapshot =
      state
      |> State.tracked_owners()
      |> Enum.map(&owner_snapshot(&1, state))

    {:reply, snapshot, state}
  end

  def handle_call(:runtime_readiness, _from, state) do
    readiness =
      case {state.bootstrap, Hooks.capture_snapshot([])} do
        {:complete, {:ok, %{generation: generation}}} ->
          {:ready, generation}

        _recovering ->
          :recovering
      end

    {:reply, readiness, state}
  end

  defp owner_snapshot(owner, state) do
    tools =
      state.contrib
      |> Map.get(owner, MapSet.new())
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

  defp boot_load(generation) do
    result = Load.boot_load(generation)
    record_boot_outcome(generation, result)
    result
  catch
    kind, reason ->
      record_boot_outcome(generation, {:error, {kind, reason}})
      {:error, {kind, reason}}
  end

  defp record_boot_outcome(generation, result) do
    case Catalyst.Extensions.generation_current?(generation) do
      true -> record_current_boot_outcome(result)
      false -> :ok
    end
  end

  defp record_current_boot_outcome({:ok, %{failed: []}}), do: :ok
  defp record_current_boot_outcome({:ok, %{failed: failures}}), do: boot_load_failed(failures)
  defp record_current_boot_outcome({:error, reason}), do: boot_load_failed(reason)

  defp boot_load_failed(reason) do
    Logger.error(
      "[extensions] boot load failed; leaving the boot marker armed: #{inspect(reason)}"
    )

    put_boot_status({:load_failed, reason})
  end

  defp seed_builtins do
    Enum.each(ToolRegistry.default_tools(), &insert/1)
  end

  defp wire_core_kinds do
    ExtensionAPI.register_kind(:tool, &Catalyst.Extensions.register_extension_tool/2)
    ExtensionAPI.register_kind(:hook, &Catalyst.Extensions.register_extension_hook/4)
    ExtensionAPI.register_kind(:event, &Catalyst.Extensions.register_extension_observer/3)
    ExtensionAPI.register_kind(:process, &Catalyst.Extensions.start_extension_process/2)

    ExtensionAPI.register_purger(&Hooks.unregister/1)
    ExtensionAPI.register_purger(&Processes.stop_owner/1)
  end

  defp reseeders, do: :persistent_term.get(@reseeders_key, %{})

  defp web_capable? do
    not is_nil(Application.spec(:catalyst_web, :vsn))
  end

  defp bootstrap_workflow(mode, generation) do
    run_nonfatal_bootstrap_step(:guide_publication, &ensure_guide/0)
    run_nonfatal_bootstrap_step(:reseeding, &run_reseeders_bounded/0)

    case mode do
      :load -> boot_load(generation)
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
    :ok = Hooks.mark_runtime_ready(state.hook_generation)
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

  defp restore_compiled_modules(candidates, state, context) do
    ModuleVersions.restore_candidates(candidates, state.module_versions, context)
  end

  defp commit_load(owner, path, %Contribution{} = contribution, state) do
    case State.tool_owner_conflicts(state, owner, contribution.tool_names) do
      [] ->
        commit_contribution(owner, path, contribution, state)

      [{name, existing_owner} | _rest] ->
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

      Enum.each(Contribution.pairs(contribution), fn {name, module} ->
        :ets.insert(@table, {name, module})
      end)

      result = build_summary(owner, contribution.tool_names, contribution.ext_mods, conflicts)
      {{:ok, result}, State.record_purge_result(committed, owner, purge_result)}
    rescue
      error -> {{:error, {:register, Exception.message(error)}}, committed}
    catch
      kind, reason -> {{:error, {:register, {kind, reason}}}, committed}
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

  defp purge_owner(owner, state, opts \\ []) do
    module_versions = ModuleVersions.drop_owner(state.module_versions, owner)
    purge_opts = Keyword.put(opts, :module_versions, module_versions)
    purge_result = purge_owner_effects(owner, state, purge_opts)

    state
    |> State.drop_owner(owner, module_versions)
    |> State.record_purge_result(owner, purge_result)
  end

  defp purge_owner_effects(owner, state, opts) do
    keep = MapSet.new(Keyword.get(opts, :keep_modules, []))
    module_versions = Keyword.fetch!(opts, :module_versions)

    removed_modules =
      state.modules
      |> Map.get(owner, [])
      |> Enum.reject(&MapSet.member?(keep, &1))

    Enum.each(
      removed_modules,
      &ModuleVersions.restore_removed(&1, owner, state.module_versions, module_versions)
    )

    pairs = Map.get(state.contrib, owner, MapSet.new())
    builtins = builtins_index()

    Enum.each(pairs, fn {name, module} ->
      :ets.delete_object(@table, {name, module})

      case {:ets.member(@table, name), Map.get(builtins, name)} do
        {false, builtin} when not is_nil(builtin) -> :ets.insert(@table, {name, builtin})
        _present_or_missing -> :ok
      end
    end)

    pairs
    |> Enum.map(&elem(&1, 1))
    |> Enum.concat(removed_modules)
    |> Enum.uniq()
    |> Enum.each(&ToolRegistry.invalidate/1)

    ExtensionAPI.purge_owner(owner)
  end

  defp put_boot_status(status), do: :persistent_term.put(@boot_status_key, status)

  defp persist_footprint(state) do
    :persistent_term.put(@runtime_footprint_key, State.footprint(state))
    state
  end

  defp runtime_footprint, do: :persistent_term.get(@runtime_footprint_key, %{})

  defp boot_stable_ms, do: Application.get_env(:catalyst, :boot_stable_ms, 10_000)

  defp builtins_index do
    Map.new(ToolRegistry.default_tools(), &{&1.name(), &1})
  end
end
