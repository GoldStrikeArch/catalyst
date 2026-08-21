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
    ModuleVersions,
    Sources,
    Transaction,
    Versioning
  }

  alias Catalyst.Runtime.{GenerationId, Generations}

  @server Catalyst.Extensions
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
      finish_explicit_load(result, Transaction.generation())
    end)
  end

  @doc false
  @spec boot_load(reference() | nil) ::
          {:ok, Catalyst.Extensions.load_result()} | {:error, term()}
  def boot_load(generation) do
    Transaction.run(fn ->
      case generation == Transaction.generation() and
             Catalyst.Extensions.generation_current?(generation) do
        true -> do_load_all()
        false -> {:error, :stale_extension_generation}
      end
    end)
  end

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
  @spec uninstall(String.t()) :: :ok | {:error, term()}
  def uninstall(owner) do
    Transaction.run(fn ->
      with :ok <- Generations.remove_owner(owner) do
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
      case Generations.remove_owner(owner) do
        :ok ->
          :ok = server_call({:uninstall, owner})
          commit_lifecycle_change([path, disabled], "disable #{owner}")
          {:ok, disabled}

        {:error, reason} ->
          restore_enabled_file(path, disabled, reason)
      end
    end
  end

  defp restore_enabled_file(path, disabled, reason) do
    case File.rename(disabled, path) do
      :ok -> {:error, reason}
      {:error, rollback_reason} -> {:error, {:disable_failed, reason, rollback_reason}}
    end
  end

  defp finish_explicit_load({:ok, %{failed: []}} = result, generation) do
    case server_call({:explicit_load_finished, generation}) do
      :ok -> result
      {:error, :stale_extension_generation} = error -> error
    end
  end

  defp finish_explicit_load(result, _generation), do: result

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

    paths = Sources.enabled_files()

    with :ok <- ensure_distinct_owners(Sources.index_by_owner(paths)) do
      load_paths(paths)
    end
  end

  defp load_paths(paths) do
    live_owners = MapSet.new(paths, &Sources.owner/1)

    with :ok <- Generations.reconcile(live_owners),
         :ok <- server_call({:purge_gone, live_owners}) do
      {loaded, failed} =
        Enum.reduce(paths, {[], []}, fn path, {ok, bad} ->
          case compile_and_load(path, Sources.owner(path)) do
            {:ok, summary} ->
              {[summary | ok], bad}

            {:error, reason} ->
              Logger.warning("[extensions] failed to load #{path}: #{inspect(reason)}")
              {ok, [{path, reason} | bad]}
          end
        end)

      {:ok, %{loaded: Enum.reverse(loaded), failed: Enum.reverse(failed)}}
    end
  end

  defp do_load_file(path) do
    owner = Sources.owner(path)

    with :ok <- ensure_owner_path(owner, path) do
      compile_and_load(path, owner)
    end
  end

  defp compile_and_load(path, owner) do
    case Loader.compile(path) do
      {:ok, contribution} ->
        commit_compiled(path, owner, contribution)

      {:error, reason, emitted_modules} ->
        :ok = server_call({:purge_partial_compile, emitted_modules})
        {:error, reason}
    end
  end

  defp commit_compiled(path, owner, contribution) do
    case Catalyst.Extensions.generation_current?(Transaction.generation()) do
      true ->
        commit_current_generation(path, owner, contribution)

      false ->
        :ok = server_call({:purge_rejected_compile, contribution.modules})
        {:error, :stale_extension_generation}
    end
  end

  defp commit_current_generation(path, owner, contribution) do
    prior = server_call({:owner_snapshot, owner})

    case server_call({:commit_load, owner, path, contribution}) do
      {:ok, summary} ->
        finish_setup(owner, contribution, summary, prior)

      {:error, _reason} = error ->
        :ok = server_call({:purge_rejected_compile, contribution.modules})
        error
    end
  end

  defp finish_setup(owner, contribution, summary, prior) do
    load_ref = make_ref()
    :ok = server_call({:begin_setup, load_ref})
    setup_status = Loader.run_setups(contribution.ext_mods, ExtensionAPI.new(owner, load_ref))
    recorded_collisions = server_call({:take_setup_collisions, load_ref})

    case List.first(recorded_collisions) || ownership_collision(setup_status) do
      nil ->
        finish_activation(owner, contribution, summary, setup_status, prior)

      collision ->
        :ok = server_call({:uninstall, owner})
        restore_prior_version(owner, prior)
        {:error, collision}
    end
  end

  defp finish_activation(owner, contribution, summary, setup_status, prior) do
    case activate_manifests(owner, contribution.manifests) do
      {:ok, generation} ->
        {:ok,
         summary
         |> annotate_setup_status(setup_status)
         |> annotate_generation(generation)}

      {:error, reason} ->
        :ok = server_call({:uninstall, owner})
        restore_prior_version(owner, prior)
        {:error, {:candidate_activation_failed, reason}}
    end
  end

  defp activate_manifests(_owner, []), do: {:ok, nil}
  defp activate_manifests(owner, manifests), do: Generations.install(owner, manifests)

  defp annotate_generation(summary, nil), do: summary

  defp annotate_generation(summary, generation) do
    summary
    |> Map.put(:activation, :active)
    |> Map.put(:generation, GenerationId.to_wire(generation.id))
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

  defp restore_prior_version(_owner, :none), do: :ok

  defp restore_prior_version(owner, {:ok, snapshot}) do
    case ModuleVersions.load_beams(snapshot.path, snapshot.beams) do
      :ok ->
        contribution = snapshot_contribution(snapshot)

        case server_call({:commit_load, owner, snapshot.path, contribution}) do
          {:ok, _summary} -> restore_prior_setup(owner, contribution)
          {:error, reason} -> log_failed_restore(owner, reason)
        end

      {:error, failures} ->
        log_failed_restore(owner, {:load_beams, failures})
    end
  end

  defp snapshot_contribution(snapshot) do
    %Contribution{
      modules: snapshot.modules,
      beams: snapshot.beams,
      ext_mods: Enum.filter(snapshot.modules, &Catalyst.Extension.extension_module?/1),
      manifests:
        snapshot.modules
        |> Enum.filter(&Catalyst.Extension.extension_module?/1)
        |> Catalyst.Extension.manifests_of(),
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
    activation_status = activate_manifests(owner, contribution.manifests)

    case List.first(collisions) || setup_restore_failure(setup_status) ||
           activation_restore_failure(activation_status) do
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

  defp activation_restore_failure({:ok, _generation}), do: nil

  defp activation_restore_failure({:error, reason}),
    do: {:activation_restore_failed, reason}

  defp log_failed_restore(owner, reason) do
    Logger.warning("[extensions] could not restore prior version of #{owner}: #{inspect(reason)}")
    :ok
  end

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
