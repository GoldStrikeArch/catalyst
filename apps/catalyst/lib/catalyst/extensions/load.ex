defmodule Catalyst.Extensions.Load do
  @moduledoc """
  Serialized source and lifecycle operations for runtime extensions.

  This module owns the caller-independent load saga. Canonical ownership state,
  ETS mutation, and purge side effects remain in the registered
  `Catalyst.Extensions` server and are reached through its existing message
  protocol.
  """

  require Logger

  alias Catalyst.ExtensionAPI

  alias Catalyst.Extensions.{
    Contribution,
    Loader,
    Modules,
    Sources,
    Transaction,
    Versioning
  }

  @server Catalyst.Extensions
  @suppressed_key {__MODULE__, :suppressed_owners}
  @default_server_call_timeout 30_000

  @doc false
  @spec load_file(Path.t()) ::
          {:ok, Catalyst.Extensions.summary()} | {:error, term()}
  def load_file(path), do: Transaction.run(fn -> do_load_file(path) end)

  @doc false
  @spec load_all() :: {:ok, Catalyst.Extensions.load_result()} | {:error, term()}
  def load_all do
    Transaction.run(fn ->
      result = do_load_all()
      finish_explicit_load(result)
    end)
  end

  @doc false
  @spec boot_load() :: {:ok, Catalyst.Extensions.load_result()} | {:error, term()}
  def boot_load, do: Transaction.run_inline(&do_load_all/0)

  @doc false
  @spec boot_load_bundled() :: {:ok, Catalyst.Extensions.load_result()} | {:error, term()}
  def boot_load_bundled, do: do_load_bundled()

  @doc false
  @spec reload_after_wiring() ::
          {:ok, Catalyst.Extensions.load_result()} | {:error, term()} | {:skipped, term()}
  def reload_after_wiring do
    case Catalyst.Extensions.boot_status() do
      :ok -> Transaction.run(&do_load_all/0)
      status -> {:skipped, status}
    end
  end

  @doc false
  @spec uninstall(String.t()) :: :ok
  def uninstall(owner) do
    Transaction.run(fn ->
      suppress(owner)

      case server_call({:owner_snapshot, owner}) do
        {:ok, %{path: path}} when is_binary(path) ->
          paths =
            Enum.reject(active_source_paths(), &(Sources.owner(elem(&1, 1)) == owner))

          _ = rebuild(paths)
          :ok

        _fileless_or_missing ->
          server_call({:uninstall, owner})
      end
    end)
  end

  @doc false
  @spec source_file(String.t()) :: {:ok, Path.t()} | :error
  def source_file(owner) do
    case file_for(owner) do
      {:ok, path} -> {:ok, path}
      :error -> disabled_file_for(owner)
    end
  end

  @doc false
  @spec reload(String.t()) :: {:ok, Catalyst.Extensions.summary()} | {:error, term()}
  def reload(owner) do
    Transaction.run(fn ->
      case file_for(owner) do
        {:ok, path} -> do_load_file(path)
        :error -> {:error, :no_file}
      end
    end)
  end

  @doc false
  @spec disable(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def disable(owner) do
    Transaction.run(fn ->
      case file_for(owner) do
        {:ok, path} ->
          disable_file(owner, path)

        :error ->
          {:error, :no_file}
      end
    end)
  end

  @doc false
  @spec enable(String.t()) ::
          {:ok, Catalyst.Extensions.summary()} | {:error, term()}
  def enable(owner) do
    Transaction.run(fn ->
      case disabled_file_for(owner) do
        {:ok, disabled} -> enable_file(owner, disabled)
        :error -> {:error, :no_file}
      end
    end)
  end

  @doc false
  @spec rollback(String.t() | nil) ::
          {:ok, Catalyst.Extensions.load_result()} | {:error, term()}
  def rollback(owner) when is_binary(owner) or is_nil(owner) do
    Transaction.run(fn ->
      with :ok <- rollback_source(owner) do
        case load_all() do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, {:reload_failed, reason}}
        end
      end
    end)
  end

  @doc false
  @spec server_call_timeout() :: timeout()
  def server_call_timeout do
    Application.get_env(
      :catalyst,
      :extension_lifecycle_call_timeout,
      @default_server_call_timeout
    )
  end

  defp disable_file(owner, path) do
    disabled = path <> ".disabled"

    with :ok <- Sources.ensure_managed(path),
         :ok <- File.rename(path, disabled) do
      unsuppress(owner)
      _ = rebuild(all_source_paths())
      commit_lifecycle_change([path, disabled], "disable #{owner}")
      {:ok, disabled}
    end
  end

  defp finish_explicit_load({:ok, %{failed: []}} = result) do
    :ok = server_call(:explicit_load_finished)
    result
  end

  defp finish_explicit_load(result), do: result

  defp enable_file(owner, disabled) do
    path = String.replace_suffix(disabled, ".disabled", "")

    with :ok <- File.rename(disabled, path) do
      result = do_load_file(path)
      commit_lifecycle_change([disabled, path], "enable #{owner}")
      result
    end
  end

  defp rollback_source(nil), do: Versioning.rollback(Sources.dir())

  defp rollback_source(owner) do
    case source_file(owner) do
      {:ok, path} -> Versioning.rollback_file(Sources.dir(), path)
      :error -> {:error, :no_file}
    end
  end

  defp do_load_all do
    # Git may take seconds, so repository setup belongs in the load task rather
    # than the state-owning GenServer or its init callback.
    Versioning.ensure_repo(Sources.dir())

    clear_suppressed()

    with :ok <- validate_source_owners() do
      rebuild(all_source_paths())
    end
  end

  defp do_load_bundled do
    paths = Sources.bundled_files()
    clear_suppressed()

    with :ok <- ensure_distinct_owners(Sources.index_by_owner(paths)) do
      rebuild(tag_paths(paths, :bundled))
    end
  end

  defp tag_paths(paths, source), do: Enum.map(paths, &{source, &1})

  defp do_load_file(path) do
    owner = Sources.owner(path)
    unsuppress(owner)

    with :ok <- ensure_owner_path(owner, path) do
      paths = include_source(active_source_paths(), path)

      case rebuild(paths) do
        {:ok, %{loaded: loaded, failed: failed}} ->
          result_for_path(path, loaded, failed)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp rebuild(paths) do
    paths = effective_paths(paths)
    staged = Loader.compile_many(paths)
    prior = prior_file_owners()
    failed_owners = compile_failed_owners(staged)

    prior
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(failed_owners, &1))
    |> Enum.each(&server_call({:uninstall, &1}))

    {loaded, failed, desired} = apply_staged(staged, prior)
    :ok = reconcile_modules(paths, staged, prior, desired, failed != [])

    {:ok, %{loaded: loaded, failed: failed}}
  rescue
    error -> {:error, {:rebuild, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:rebuild, {kind, reason}}}
  end

  defp apply_staged(staged, prior) do
    {loaded, failed, desired, _loaded_modules} =
      Enum.reduce(staged, {[], [], retained_failed(staged, prior), MapSet.new()}, fn
        {source, path, {:ok, contribution}}, {loaded, failed, desired, loaded_modules} ->
          owner = Sources.owner(path)
          prior_owner = Map.get(prior, owner)

          load? =
            contribution_changed?(prior_owner, contribution) or
              Enum.any?(contribution.modules, &MapSet.member?(loaded_modules, &1))

          case apply_contribution(path, owner, contribution, prior_owner, load?) do
            {:ok, summary} ->
              entry = %{path: path, contribution: contribution}
              loaded_modules = track_loaded_modules(loaded_modules, contribution, load?)

              {loaded ++ [Map.put(summary, :source, source)], failed,
               Map.put(desired, owner, entry), loaded_modules}

            {:error, reason} ->
              Logger.warning("[extensions] failed to apply #{path}: #{inspect(reason)}")
              suppress(owner)
              desired = retain_prior(desired, owner, prior_owner)
              :ok = reload_desired(staged, desired)
              {loaded, failed ++ [{path, reason}], desired, MapSet.new()}
          end

        {_source, path, {:error, reason}}, {loaded, failed, desired, loaded_modules} ->
          Logger.warning("[extensions] failed to stage #{path}: #{inspect(reason)}")
          suppress(Sources.owner(path))
          {loaded, failed ++ [{path, reason}], desired, loaded_modules}
      end)

    {loaded, failed, desired}
  end

  defp apply_contribution(path, owner, contribution, prior, load?) do
    with :ok <- maybe_load(path, contribution, load?),
         {:ok, summary} <- server_call({:commit_load, owner, path, contribution}) do
      finish_setup(owner, contribution, summary, prior)
    else
      {:error, reason} = error ->
        :ok = restore_rejected(owner, prior, contribution.modules)
        Logger.warning("[extensions] rejected #{path}: #{inspect(reason)}")
        error
    end
  end

  defp contribution_changed?(nil, _contribution), do: true
  defp contribution_changed?(prior, contribution), do: prior.beams != contribution.beams

  defp maybe_load(_path, _contribution, false), do: :ok
  defp maybe_load(path, contribution, true), do: Loader.load(path, contribution)

  defp track_loaded_modules(modules, _contribution, false), do: modules

  defp track_loaded_modules(modules, contribution, true) do
    MapSet.union(modules, MapSet.new(contribution.modules))
  end

  defp finish_setup(owner, contribution, summary, prior) do
    load_ref = make_ref()
    :ok = server_call({:begin_setup, load_ref})
    setup_status = Loader.run_setups(contribution.ext_mods, ExtensionAPI.new(owner, load_ref))
    recorded_collisions = server_call({:take_setup_collisions, load_ref})

    case List.first(recorded_collisions) || ownership_collision(setup_status) do
      nil ->
        {:ok, annotate_setup_status(summary, setup_status)}

      collision ->
        :ok = server_call({:uninstall, owner})
        :ok = restore_rejected(owner, prior, contribution.modules)
        {:error, collision}
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
      [path | Sources.enabled_files()]
      |> Sources.index_by_owner()
      |> Map.get(owner, [])

    case paths do
      [_path] -> :ok
      paths -> {:error, {:owner_collision, owner, Enum.sort(paths)}}
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

  defp restore_rejected(_owner, nil, modules) do
    Enum.each(modules, &Modules.restore_original/1)
  end

  defp restore_rejected(owner, snapshot, _modules) do
    :ok = Modules.load(snapshot.path, snapshot.beams)
    contribution = snapshot_contribution(snapshot)

    case server_call({:commit_load, owner, snapshot.path, contribution}) do
      {:ok, _summary} -> restore_prior_setup(owner, contribution)
      {:error, reason} -> log_failed_restore(owner, reason)
    end
  end

  defp snapshot_contribution(snapshot) do
    %Contribution{
      modules: snapshot.modules,
      beams: snapshot.beams,
      ext_mods: snapshot.ext_mods,
      tool_mods: snapshot.tool_mods,
      tool_names: snapshot.tool_names,
      metadata: snapshot.metadata
    }
  end

  defp restore_prior_setup(owner, contribution) do
    load_ref = make_ref()
    :ok = server_call({:begin_setup, load_ref})
    setup_status = Loader.run_setups(contribution.ext_mods, ExtensionAPI.new(owner, load_ref))
    collisions = server_call({:take_setup_collisions, load_ref})

    case List.first(collisions) || setup_restore_failure(setup_status) do
      nil ->
        Logger.info("[extensions] restored prior accepted version of #{owner}")
        :ok

      reason ->
        :ok = server_call({:uninstall, owner})
        log_failed_restore(owner, reason)
    end
  end

  defp setup_restore_failure(:ok), do: nil
  defp setup_restore_failure({:error, reason}), do: reason

  defp log_failed_restore(owner, reason) do
    Logger.warning("[extensions] could not restore prior version of #{owner}: #{inspect(reason)}")
    :ok
  end

  defp prior_file_owners do
    @server
    |> GenServer.call(:snapshot, server_call_timeout())
    |> Enum.reduce(%{}, fn
      {owner, %{path: path}}, acc when is_binary(path) ->
        case server_call({:owner_snapshot, owner}) do
          {:ok, snapshot} ->
            Map.put(acc, owner, snapshot)

          :none ->
            acc
        end

      _fileless_owner, acc ->
        acc
    end)
  end

  defp compile_failed_owners(staged) do
    staged
    |> Enum.flat_map(fn
      {_source, path, {:error, _reason}} -> [Sources.owner(path)]
      _success -> []
    end)
    |> MapSet.new()
  end

  defp retained_failed(staged, prior) do
    staged
    |> compile_failed_owners()
    |> Enum.reduce(%{}, fn owner, acc -> retain_prior(acc, owner, Map.get(prior, owner)) end)
  end

  defp retain_prior(desired, _owner, nil), do: desired

  defp retain_prior(desired, owner, snapshot) do
    Map.put(desired, owner, %{path: snapshot.path, contribution: snapshot_contribution(snapshot)})
  end

  defp reconcile_modules(paths, staged, prior, desired, repair?) do
    touched =
      prior
      |> Map.values()
      |> Enum.flat_map(& &1.modules)
      |> Enum.concat(staged_modules(staged))
      |> Enum.uniq()

    desired_modules =
      desired
      |> Map.values()
      |> Enum.flat_map(& &1.contribution.modules)
      |> MapSet.new()

    touched
    |> Enum.reject(&MapSet.member?(desired_modules, &1))
    |> Enum.each(&Modules.restore_original/1)

    repair_desired_modules(paths, desired, repair?)
  end

  defp repair_desired_modules(_paths, _desired, false), do: :ok

  defp repair_desired_modules(paths, desired, true) do
    Enum.reduce_while(paths, :ok, fn {_source, path}, :ok ->
      case Map.get(desired, Sources.owner(path)) do
        nil ->
          {:cont, :ok}

        %{path: desired_path, contribution: contribution} ->
          case Loader.load(desired_path, contribution) do
            :ok -> {:cont, :ok}
            {:error, failures} -> {:halt, {:error, {:module_reconcile, path, failures}}}
          end
      end
    end)
  end

  defp staged_modules(staged) do
    Enum.flat_map(staged, fn
      {_source, _path, {:ok, contribution}} -> contribution.modules
      _failure -> []
    end)
  end

  defp reload_desired(staged, desired) do
    Enum.reduce_while(staged, :ok, fn {_source, path, _result}, :ok ->
      case Map.get(desired, Sources.owner(path)) do
        nil ->
          {:cont, :ok}

        %{path: desired_path, contribution: contribution} ->
          case Loader.load(desired_path, contribution) do
            :ok -> {:cont, :ok}
            {:error, failures} -> {:halt, {:error, {:module_restore, path, failures}}}
          end
      end
    end)
  end

  defp all_source_paths do
    bundled = Sources.bundled_files()
    user = Sources.enabled_files()

    bundled
    |> tag_paths(:bundled)
    |> Kernel.++(tag_paths(user, :user))
    |> effective_paths()
    |> Enum.reject(&(Sources.owner(elem(&1, 1)) in suppressed()))
  end

  defp active_source_paths do
    bundled = Sources.bundled_files() |> Enum.map(&Path.expand/1) |> MapSet.new()

    @server
    |> GenServer.call(:snapshot, server_call_timeout())
    |> Enum.flat_map(fn
      {_owner, %{path: path}} when is_binary(path) ->
        case File.regular?(path) and Sources.owner(path) not in suppressed() do
          true -> [{source_kind(path, bundled), path}]
          false -> []
        end

      _fileless_owner ->
        []
    end)
    |> Enum.sort_by(fn {source, path} -> {source_order(source), path} end)
    |> effective_paths()
  end

  defp source_kind(path, bundled) do
    case MapSet.member?(bundled, Path.expand(path)) do
      true -> :bundled
      false -> :user
    end
  end

  defp source_order(:bundled), do: 0
  defp source_order(:user), do: 1

  defp effective_paths(paths) do
    paths
    |> Enum.reverse()
    |> Enum.uniq_by(fn {_source, path} -> Sources.owner(path) end)
    |> Enum.reverse()
  end

  defp include_source(paths, path) do
    owner = Sources.owner(path)
    bundled = Sources.bundled_files() |> Enum.map(&Path.expand/1) |> MapSet.new()

    paths
    |> Enum.reject(&(Sources.owner(elem(&1, 1)) == owner))
    |> Kernel.++([{source_kind(path, bundled), path}])
  end

  defp validate_source_owners do
    with :ok <- ensure_distinct_owners(Sources.index_by_owner(Sources.bundled_files())) do
      ensure_distinct_owners(Sources.index_by_owner(Sources.enabled_files()))
    end
  end

  defp result_for_path(path, loaded, failed) do
    case Enum.find(failed, &(Path.expand(elem(&1, 0)) == Path.expand(path))) do
      {_failed_path, reason} ->
        {:error, reason}

      nil ->
        case Enum.find(loaded, &(&1.owner == Sources.owner(path))) do
          nil -> {:error, :not_loaded}
          summary -> {:ok, Map.delete(summary, :source)}
        end
    end
  end

  defp suppress(owner) do
    :persistent_term.put(@suppressed_key, Enum.uniq([owner | suppressed()]))
  end

  defp unsuppress(owner) do
    :persistent_term.put(@suppressed_key, List.delete(suppressed(), owner))
  end

  defp clear_suppressed, do: :persistent_term.erase(@suppressed_key)
  defp suppressed, do: :persistent_term.get(@suppressed_key, [])

  defp commit_lifecycle_change(paths, message) do
    Versioning.ensure_repo(Sources.dir())

    case Versioning.commit_paths(Sources.dir(), paths, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[extensions] #{message} succeeded but could not be git-versioned: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp file_for(owner) do
    case server_call({:path_for, owner}) do
      {:ok, path} -> existing_file(path, owner)
      :error -> Sources.find(Sources.enabled_files(), owner, &Sources.owner/1)
    end
  catch
    :exit, _reason -> Sources.find(Sources.enabled_files(), owner, &Sources.owner/1)
  end

  defp existing_file(path, owner) do
    case File.regular?(path) do
      true -> {:ok, path}
      false -> Sources.find(Sources.enabled_files(), owner, &Sources.owner/1)
    end
  end

  defp disabled_file_for(owner),
    do: Sources.find(Sources.disabled_files(), owner, &Sources.disabled_owner/1)

  defp server_call(message), do: GenServer.call(@server, message, server_call_timeout())
end
