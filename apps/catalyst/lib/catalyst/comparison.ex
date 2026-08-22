defmodule Catalyst.Comparison do
  @moduledoc """
  Durable groups of independent model sessions backed by isolated Git clones.

  Initial lanes share one captured source snapshot. A lane added later captures
  the source again. Persistence belongs to `Catalyst.Comparison.Store`; Git and
  filesystem work belongs to `Catalyst.Comparison.Workspace`.
  """

  alias Catalyst.Comparison.{Store, Workspace}
  alias Catalyst.LLM.Models
  alias Catalyst.Session.{Manager, Server}

  # Comparison v1 accepted only Codex model ids and persisted no provider descriptor.
  @legacy_provider_id "openai-codex"

  @workspace_instruction """

  Your entire project workspace is the current working directory. Do not inspect \
  parent directories or access paths outside this workspace.\
  """

  @type manifest :: Store.manifest()
  @type lane :: map()
  @type model_selection :: String.t() | %{required(String.t()) => String.t()}

  @doc "Create a comparison with at least two model lanes."
  @spec create(Path.t(), [model_selection()], keyword()) ::
          {:ok, manifest()} | {:error, term()}
  def create(source, model_selections, opts \\ [])

  def create(source, model_selections, opts)
      when is_binary(source) and is_list(model_selections) and is_list(opts) do
    with :ok <- validate_models(model_selections, 2),
         {:ok, source_root} <- Workspace.git_root(source) do
      create_in(
        Catalyst.Ids.hex(16),
        source_root,
        model_selections,
        Keyword.get(opts, :system_prompt)
      )
    end
  end

  def create(source, model_selections, _opts),
    do: {:error, {:invalid_comparison_options, source, model_selections}}

  @doc "Load one persisted comparison."
  @spec get(String.t()) :: {:ok, manifest()} | {:error, term()}
  defdelegate get(id), to: Store

  @doc "List persisted comparisons, newest first."
  @spec list() :: [manifest()]
  defdelegate list(), to: Store

  @doc false
  @spec comparison_topic(String.t()) :: String.t()
  def comparison_topic(id), do: "comparison:" <> id

  @doc "Add a lane from a fresh snapshot of the comparison's original source."
  @spec add_lane(String.t(), model_selection()) :: {:ok, manifest()} | {:error, term()}
  def add_lane(id, model_selection) when is_binary(id) do
    with :ok <- validate_models([model_selection], 1) do
      locked(id, fn -> do_add_lane(id, model_selection) end)
    end
  end

  def add_lane(_id, model_selection), do: {:error, {:invalid_model_id, model_selection}}

  @doc "Start or resume the ordinary Catalyst session owned by a lane."
  @spec ensure_session(lane()) :: {:ok, pid()} | {:error, term()}
  def ensure_session(%{"session_id" => id, "cwd" => cwd, "model_id" => _model_id} = lane) do
    case Manager.whereis(id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        with {:ok, {_provider_id, model}} <- resolve_lane_model(lane),
             {:ok, %{pid: pid}} <-
               Manager.start_session(
                 id: id,
                 cwd: cwd,
                 model: model,
                 provider: model.api,
                 system_prompt: lane["system_prompt"],
                 opts: lane_session_opts(lane)
               ) do
          {:ok, pid}
        end
    end
  end

  def ensure_session(lane), do: {:error, {:invalid_comparison_lane, lane}}

  @doc "Persistently reconfigure one lane and return the updated comparison."
  @spec configure_lane(String.t(), String.t(), keyword()) ::
          {:ok, manifest()} | {:error, term()}
  def configure_lane(id, lane_id, changes)
      when is_binary(id) and is_binary(lane_id) and is_list(changes) do
    locked(id, fn -> do_configure_lane(id, lane_id, changes) end)
  end

  def configure_lane(_id, _lane_id, changes),
    do: {:error, {:invalid_lane_configuration, changes}}

  @doc "Submit one prompt concurrently to selected lanes."
  @spec dispatch(String.t(), [String.t()], String.t()) ::
          {:ok, %{String.t() => :started | :queued | {:error, term()}}} | {:error, term()}
  def dispatch(id, lane_ids, text) when is_list(lane_ids) and is_binary(text) do
    text = String.trim(text)

    with true <- text != "" or {:error, :blank_prompt},
         {:ok, manifest} <- get(id),
         {:ok, lanes} <- selected_lanes(manifest["lanes"], lane_ids) do
      results =
        Catalyst.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          lanes,
          &submit(&1, text),
          ordered: true,
          timeout: 5_000,
          on_timeout: :kill_task
        )

      outcomes =
        lanes
        |> Enum.zip(results)
        |> Map.new(fn {lane, result} -> {lane["id"], dispatch_outcome(result)} end)

      {:ok, outcomes}
    end
  end

  def dispatch(_id, _lane_ids, _text), do: {:error, :invalid_dispatch}

  @doc "Resolve a lane by id from a comparison manifest."
  @spec lane(manifest(), String.t()) :: {:ok, lane()} | {:error, :lane_not_found}
  def lane(%{"lanes" => lanes}, id) do
    case Enum.find(lanes, &(&1["id"] == id)) do
      nil -> {:error, :lane_not_found}
      lane -> {:ok, lane}
    end
  end

  def lane(_manifest, _id), do: {:error, :lane_not_found}

  @doc "System prompt used by comparison lanes, including the workspace boundary."
  @spec system_prompt(String.t() | nil) :: String.t()
  def system_prompt(custom) do
    base =
      case custom do
        text when is_binary(text) and text != "" -> text
        _default -> Catalyst.SystemPrompt.get()
      end

    case String.ends_with?(base, @workspace_instruction) do
      true -> base
      false -> base <> @workspace_instruction
    end
  end

  defp create_in(id, source_root, model_ids, custom_prompt) do
    prompt = system_prompt(custom_prompt)

    with {:ok, snapshot} <- Workspace.capture_snapshot(source_root, id),
         {:ok, lanes} <- provision_lanes(source_root, id, snapshot, model_ids, prompt) do
      persist_new(id, source_root, prompt, snapshot, lanes)
    else
      {:error, reason, lanes} -> cleanup_comparison(id, lanes, {:error, reason})
      {:error, reason} -> cleanup_comparison(id, [], {:error, reason})
    end
  end

  defp persist_new(id, source_root, prompt, snapshot, lanes) do
    timestamp = now()

    manifest = %{
      "version" => 1,
      "id" => id,
      "title" => Path.basename(source_root),
      "source_root" => source_root,
      "system_prompt" => prompt,
      "snapshots" => %{snapshot["id"] => snapshot},
      "lanes" => lanes,
      "inserted_at" => timestamp,
      "updated_at" => timestamp
    }

    case Store.persist(manifest) do
      :ok -> {:ok, manifest}
      {:error, reason} -> cleanup_comparison(id, lanes, {:error, reason})
    end
  end

  defp do_add_lane(id, model_id) do
    with {:ok, manifest} <- get(id),
         {:ok, source_root} <- Workspace.git_root(manifest["source_root"]),
         {:ok, snapshot} <- Workspace.capture_snapshot(source_root, id) do
      add_captured_lane(manifest, source_root, snapshot, model_id)
    end
  end

  defp do_configure_lane(id, lane_id, changes) do
    with {:ok, manifest} <- get(id),
         {:ok, lane} <- lane(manifest, lane_id),
         {:ok, pid} <- ensure_session(lane),
         :ok <- Server.configure(pid, changes),
         {:ok, configured_lane} <- configured_lane(lane, Server.state(pid)),
         updated = replace_lane(manifest, configured_lane),
         :ok <- Store.persist(updated) do
      broadcast_updated(updated)
      {:ok, updated}
    end
  end

  defp add_captured_lane(manifest, source_root, snapshot, model_id) do
    case provision_lane(
           source_root,
           manifest["id"],
           snapshot,
           model_id,
           manifest["system_prompt"]
         ) do
      {:ok, lane} -> persist_added_lane(manifest, snapshot, lane)
      {:error, reason} -> cleanup_snapshot(manifest["id"], snapshot, {:error, reason})
    end
  end

  defp persist_added_lane(manifest, snapshot, lane) do
    updated = append_lane(manifest, snapshot, lane)

    case Store.persist(updated) do
      :ok ->
        {:ok, updated}

      {:error, reason} ->
        cleanup_lane(lane)
        cleanup_snapshot(manifest["id"], snapshot, {:error, reason})
    end
  end

  defp append_lane(manifest, snapshot, lane) do
    manifest
    |> Map.update!("snapshots", &Map.put(&1, snapshot["id"], snapshot))
    |> Map.update!("lanes", &(&1 ++ [lane]))
    |> Map.put("updated_at", now())
  end

  defp provision_lanes(source_root, comparison_id, snapshot, model_ids, prompt) do
    Enum.reduce_while(model_ids, {:ok, []}, fn model_id, {:ok, lanes} ->
      case provision_lane(source_root, comparison_id, snapshot, model_id, prompt) do
        {:ok, lane} -> {:cont, {:ok, [lane | lanes]}}
        {:error, reason} -> {:halt, {:error, reason, lanes}}
      end
    end)
    |> case do
      {:ok, lanes} -> {:ok, Enum.reverse(lanes)}
      error -> error
    end
  end

  defp provision_lane(source_root, comparison_id, snapshot, model_id, prompt) do
    case Workspace.provision(source_root, comparison_id, snapshot) do
      {:ok, workspace} ->
        start_lane_session(workspace, snapshot, model_id, prompt)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_lane_session(workspace, snapshot, model_selection, prompt) do
    session_id = Catalyst.Ids.hex(16)

    with {:ok, {provider_id, model}} <- resolve_model_selection(model_selection),
         {:ok, %{pid: _pid}} <-
           Manager.start_unique_session(
             id: session_id,
             cwd: workspace.cwd,
             model: model,
             provider: model.api,
             system_prompt: prompt,
             opts: [reasoning_effort: "medium"]
           ) do
      {:ok,
       %{
         "id" => Catalyst.Ids.hex(8),
         "workspace_id" => workspace.id,
         "cwd" => workspace.cwd,
         "session_id" => session_id,
         "snapshot_id" => snapshot["id"],
         "model_id" => model.id,
         "provider_id" => provider_id,
         "system_prompt" => prompt,
         "reasoning_effort" => "medium",
         "workflow" => nil,
         "created_at" => now()
       }}
    else
      {:error, reason} ->
        Workspace.cleanup(workspace.cwd)
        {:error, {:lane_session_start_failed, reason}}
    end
  end

  defp locked(id, fun) do
    case :global.trans({__MODULE__, id}, fun) do
      :aborted -> {:error, :comparison_lock_aborted}
      {:aborted, reason} -> {:error, {:comparison_lock_aborted, reason}}
      result -> result
    end
  end

  defp submit(lane, text) do
    with {:ok, pid} <- ensure_session(lane) do
      Server.submit(pid, text)
    end
  end

  defp dispatch_outcome({:ok, {:ok, outcome}}), do: outcome
  defp dispatch_outcome({:ok, {:error, reason}}), do: {:error, reason}
  defp dispatch_outcome({:exit, reason}), do: {:error, reason}

  defp selected_lanes(lanes, ids) when is_list(lanes) do
    selected = Enum.filter(lanes, &(&1["id"] in ids))

    cond do
      ids == [] -> {:error, :no_recipients}
      length(selected) != length(Enum.uniq(ids)) -> {:error, :lane_not_found}
      true -> {:ok, selected}
    end
  end

  defp selected_lanes(_lanes, _ids), do: {:error, :invalid_lanes}

  defp validate_models(models, minimum) do
    case length(models) >= minimum and Enum.all?(models, &valid_model_selection?/1) do
      true -> :ok
      false -> {:error, {:invalid_models, models}}
    end
  end

  defp valid_model_selection?(model_id) when is_binary(model_id), do: model_id != ""

  defp valid_model_selection?(%{"provider_id" => provider_id, "model_id" => model_id}),
    do: is_binary(provider_id) and provider_id != "" and is_binary(model_id) and model_id != ""

  defp valid_model_selection?(_selection), do: false

  defp cleanup_comparison(id, lanes, result) do
    Enum.each(lanes, &cleanup_lane/1)
    Store.delete(id)
    result
  end

  defp cleanup_lane(lane) do
    Manager.stop(lane["session_id"])
    Workspace.cleanup(lane["cwd"])
  end

  defp cleanup_snapshot(comparison_id, snapshot, result) do
    Workspace.cleanup_snapshot(comparison_id, snapshot["id"])
    result
  end

  defp configured_lane(lane, snapshot) do
    with %{id: model_id} = model when is_binary(model_id) <- snapshot.model,
         {:ok, provider_id} <- Models.provider_id(model) do
      {:ok,
       Map.merge(lane, %{
         "model_id" => model_id,
         "provider_id" => provider_id,
         "system_prompt" => snapshot.system_prompt,
         "reasoning_effort" => Keyword.get(snapshot.opts, :reasoning_effort),
         "workflow" => Keyword.get(snapshot.opts, :workflow)
       })}
    else
      {:error, _reason} = error -> error
      model -> {:error, {:invalid_configured_model, model}}
    end
  end

  defp resolve_lane_model(%{"provider_id" => provider_id, "model_id" => model_id})
       when is_binary(provider_id),
       do: Models.resolve(provider_id, model_id)

  defp resolve_lane_model(%{"model_id" => model_id}), do: resolve_model_id(model_id)

  defp resolve_model_selection(%{"provider_id" => provider_id, "model_id" => model_id}),
    do: Models.resolve(provider_id, model_id)

  defp resolve_model_selection(model_id), do: resolve_model_id(model_id)

  defp resolve_model_id(model_id) do
    case Models.resolve(model_id) do
      {:error, {:unknown_model, ^model_id}} -> Models.resolve(@legacy_provider_id, model_id)
      result -> result
    end
  end

  defp replace_lane(manifest, configured_lane) do
    manifest
    |> Map.update!("lanes", fn lanes ->
      Enum.map(lanes, &replace_matching_lane(&1, configured_lane))
    end)
    |> Map.put("updated_at", now())
  end

  defp replace_matching_lane(%{"id" => id}, %{"id" => id} = configured), do: configured
  defp replace_matching_lane(lane, _configured), do: lane

  defp broadcast_updated(manifest) do
    Phoenix.PubSub.broadcast(
      Catalyst.PubSub,
      comparison_topic(manifest["id"]),
      {:comparison_updated, manifest["id"], manifest}
    )
  end

  defp lane_session_opts(lane) do
    [
      reasoning_effort: lane["reasoning_effort"],
      workflow: lane["workflow"]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
