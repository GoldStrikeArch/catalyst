defmodule Catalyst.WorkflowRun do
  @moduledoc """
  Public API for durable, explicitly resumed multi-stage workflow runs.

  A full application restart discovers interrupted checkpoints through `list/0`
  and `get/1` but never resumes them. `resume/2` requires an attempt
  implementation unless one is configured as `:workflow_run_attempt_module`.
  """

  alias Catalyst.WorkflowRun.{Coordinator, Names, Store}

  @dynamic_supervisor Catalyst.WorkflowRun.DynamicSupervisor

  @doc """
  Create and start a run.

  Required option `:stages` is a non-empty list of JSON-safe maps. A stage may
  set `"max_attempts"` to a positive integer (default 1). `:input` defaults to
  an empty map. `:attempt_module` implements `Catalyst.WorkflowRun.Attempt`.
  """
  @spec start(keyword()) :: {:ok, %{id: String.t(), pid: pid()}} | {:error, term()}
  def start(opts) when is_list(opts) do
    id = Keyword.get(opts, :id) || Catalyst.Ids.hex(16)

    with {:ok, module} <- attempt_module(opts),
         {:ok, stages} <- validate_stages(Keyword.get(opts, :stages)),
         {:ok, input} <- validate_json(Keyword.get(opts, :input, %{}), :input),
         :ok <- ensure_new(id),
         checkpoint = new_checkpoint(id, stages, input),
         :ok <- Store.put(checkpoint),
         {:ok, pid} <- start_supervisor(id, module, Keyword.get(opts, :owner)) do
      {:ok, %{id: id, pid: pid}}
    end
  end

  def start(opts), do: {:error, {:invalid_workflow_run_options, opts}}

  @doc "List all durable checkpoints, newest first."
  @spec list() :: [map()]
  defdelegate list(), to: Store

  @doc "Load one durable checkpoint."
  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get(id), to: Store

  @doc """
  Explicitly resume an interrupted run.

  Returns the existing live process when the run is already active. Completed,
  failed, and cancelled runs cannot be resumed.
  """
  @spec resume(String.t(), keyword()) ::
          {:ok, %{id: String.t(), pid: pid()}} | {:error, term()}
  def resume(id, opts \\ []) when is_list(opts) do
    with {:ok, checkpoint} <- Store.get(id),
         :ok <- resumable(checkpoint),
         {:ok, module} <- attempt_module(opts),
         {:ok, pid} <- start_supervisor(id, module, Keyword.get(opts, :owner)) do
      {:ok, %{id: id, pid: pid}}
    end
  end

  @doc "Cancel a live run. Cancellation is durably checkpointed."
  @spec cancel(String.t(), term()) :: :ok | {:error, term()}
  def cancel(id, reason \\ "cancelled"), do: Coordinator.cancel(id, reason)

  @doc "Subscribe the calling process to transient events for one run."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(id) do
    with {:ok, _path} <- Store.path(id) do
      Phoenix.PubSub.subscribe(Catalyst.PubSub, topic(id))
    end
  end

  @doc "PubSub topic for a run id."
  @spec topic(String.t()) :: String.t()
  def topic(id), do: "workflow_run:" <> id

  @doc "Return the live per-run supervisor, if any."
  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(id), do: Names.whereis(:supervisor, id)

  defp start_supervisor(id, module, owner) do
    child_spec =
      Supervisor.child_spec(
        {Catalyst.WorkflowRun.Supervisor, id: id, attempt_module: module, owner: owner},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(@dynamic_supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp attempt_module(opts) do
    module =
      Keyword.get(opts, :attempt_module) ||
        Application.get_env(
          :catalyst,
          :workflow_run_attempt_module,
          Catalyst.WorkflowRun.SessionAttempt
        )

    case Code.ensure_loaded?(module) and function_exported?(module, :run, 2) do
      true -> {:ok, module}
      false -> {:error, {:invalid_attempt_module, module}}
    end
  end

  defp validate_stages(stages) when is_list(stages) and stages != [] do
    with true <- Enum.all?(stages, &valid_stage?/1),
         {:ok, stages} <- validate_json(stages, :stages) do
      {:ok, stages}
    else
      false -> {:error, {:invalid_workflow_stages, stages}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_stages(stages), do: {:error, {:invalid_workflow_stages, stages}}

  defp valid_stage?(stage) when is_map(stage) do
    case Map.get(stage, "max_attempts", 1) do
      attempts when is_integer(attempts) and attempts > 0 -> string_keys?(stage)
      _invalid -> false
    end
  end

  defp valid_stage?(_stage), do: false

  defp string_keys?(map), do: Enum.all?(Map.keys(map), &is_binary/1)

  defp validate_json(value, field) do
    case Jason.encode(value) do
      {:ok, _json} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_json_value, field, reason}}
    end
  end

  defp ensure_new(id) do
    case Store.get(id) do
      {:error, :workflow_run_not_found} -> :ok
      {:ok, _checkpoint} -> {:error, {:workflow_run_exists, id}}
      {:error, {:invalid_workflow_run_id, _id} = reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resumable(%{"status" => status}) when status in ["interrupted", "running"], do: :ok
  defp resumable(%{"status" => status}), do: {:error, {:workflow_run_terminal, status}}
  defp resumable(checkpoint), do: {:error, {:invalid_checkpoint, checkpoint}}

  defp new_checkpoint(id, stages, input) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "version" => 1,
      "id" => id,
      "status" => "running",
      "stages" => stages,
      "stage_index" => 0,
      "attempt" => 0,
      "stage_session_id" => nil,
      "input" => input,
      "results" => [],
      "last_error" => nil,
      "error" => nil,
      "inserted_at" => now,
      "updated_at" => now
    }
  end
end
