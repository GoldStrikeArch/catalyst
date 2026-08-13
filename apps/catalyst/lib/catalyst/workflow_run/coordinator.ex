defmodule Catalyst.WorkflowRun.Coordinator do
  @moduledoc """
  Durable single-writer coordinator for one workflow run.

  It advances stages, applies tagged retry requests, owns cancellation, emits
  transient PubSub events, and checkpoints every durable transition before
  starting the corresponding side effect.
  """

  use GenServer

  alias Catalyst.WorkflowRun.{AttemptWorker, Names, Store}

  @type state :: %{
          id: String.t(),
          checkpoint: map(),
          attempt_module: module(),
          attempt_pid: pid() | nil,
          attempt_ref: reference() | nil,
          monitor_ref: reference() | nil
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:coordinator, id))
  end

  @doc "Cancel a live run and its current attempt."
  @spec cancel(String.t(), term()) :: :ok | {:error, term()}
  def cancel(id, reason \\ "cancelled") do
    case Names.whereis(:coordinator, id) do
      {:ok, pid} -> GenServer.call(pid, {:cancel, reason})
      :error -> {:error, :workflow_run_not_running}
    end
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    module = Keyword.fetch!(opts, :attempt_module)

    case Store.get(id) do
      {:ok, checkpoint} ->
        state = %{
          id: id,
          checkpoint: checkpoint,
          attempt_module: module,
          attempt_pid: nil,
          attempt_ref: nil,
          monitor_ref: nil
        }

        {:ok, state, {:continue, :recover}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    case state.checkpoint["status"] do
      "running" -> start_attempt(state)
      "interrupted" -> persist_and_start(state, %{"status" => "running"})
      _terminal -> {:noreply, state}
    end
  end

  @impl true
  def handle_call({:cancel, reason}, _from, state) do
    case terminal?(state.checkpoint["status"]) do
      true ->
        {:reply, {:error, {:workflow_run_terminal, state.checkpoint["status"]}}, state}

      false ->
        state = terminate_attempt(state)

        case finish(state, "cancelled", %{"reason" => json_value(reason)}) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, state} -> {:reply, {:error, :checkpoint_write_failed}, state}
        end
    end
  end

  @impl true
  def handle_info({:attempt_progress, ref, event}, %{attempt_ref: ref} = state) do
    broadcast(state.id, %{"type" => "progress", "event" => event})
    {:noreply, state}
  end

  def handle_info({:attempt_result, ref, result}, %{attempt_ref: ref} = state) do
    state = clear_attempt(state)
    handle_result(result, state)
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, reason},
        %{monitor_ref: monitor_ref} = state
      ) do
    state = %{state | attempt_pid: nil, attempt_ref: nil, monitor_ref: nil}
    handle_result({:retry, %{"attempt_crash" => inspect(reason)}}, state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_result({:ok, result}, state) do
    case json_safe(result) do
      {:ok, result} -> advance(result, state)
      {:error, reason} -> fail_reply(state, reason)
    end
  end

  defp handle_result({:retry, reason}, state) do
    case retry_available?(state.checkpoint) do
      true ->
        persist_and_start(state, %{"last_error" => json_value(reason)})

      false ->
        fail_reply(state, %{"retry_exhausted" => json_value(reason)})
    end
  end

  defp handle_result({:error, reason}, state),
    do: fail_reply(state, %{"attempt_error" => json_value(reason)})

  defp handle_result({:cancelled, reason}, state),
    do: finish_reply(state, "cancelled", %{"reason" => json_value(reason)})

  defp handle_result(other, state),
    do: fail_reply(state, %{"invalid_attempt_result" => inspect(other)})

  defp advance(result, state) do
    checkpoint = state.checkpoint
    results = checkpoint["results"] ++ [result]
    next_index = checkpoint["stage_index"] + 1

    case next_index < length(checkpoint["stages"]) do
      true ->
        persist_and_start(state, %{
          "results" => results,
          "stage_index" => next_index,
          "attempt" => 0,
          "last_error" => nil
        })

      false ->
        finish_reply(state, "completed", %{"results" => results})
    end
  end

  defp start_attempt(state) do
    checkpoint =
      Map.update!(state.checkpoint, "attempt", &(&1 + 1))
      |> Map.put("status", "running")
      |> Map.put("updated_at", timestamp())

    case Store.put(checkpoint) do
      :ok -> start_persisted_attempt(%{state | checkpoint: checkpoint})
      {:error, reason} -> persistence_error(state, reason)
    end
  end

  defp start_persisted_attempt(state) do
    ref = make_ref()
    context = attempt_context(state.checkpoint)

    opts = [
      coordinator: self(),
      ref: ref,
      module: state.attempt_module,
      context: context
    ]

    child_spec = Supervisor.child_spec({AttemptWorker, opts}, restart: :temporary)

    case DynamicSupervisor.start_child(Names.via(:attempt_supervisor, state.id), child_spec) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)
        broadcast(state.id, %{"type" => "attempt_started", "context" => context})
        {:noreply, %{state | attempt_pid: pid, attempt_ref: ref, monitor_ref: monitor_ref}}

      {:error, reason} ->
        handle_result({:retry, %{"attempt_start" => inspect(reason)}}, state)
    end
  end

  defp attempt_context(checkpoint) do
    %{
      "run_id" => checkpoint["id"],
      "stage" => Enum.at(checkpoint["stages"], checkpoint["stage_index"]),
      "stage_index" => checkpoint["stage_index"],
      "attempt" => checkpoint["attempt"],
      "results" => checkpoint["results"],
      "input" => checkpoint["input"]
    }
  end

  defp retry_available?(checkpoint) do
    stage = Enum.at(checkpoint["stages"], checkpoint["stage_index"])
    checkpoint["attempt"] < Map.get(stage, "max_attempts", 1)
  end

  defp fail_reply(state, reason) do
    finish_reply(state, "failed", %{"error" => json_value(reason)})
  end

  defp finish(state, status, fields) do
    case persist(state, Map.merge(fields, %{"status" => status})) do
      {:ok, state} ->
        broadcast(state.id, %{"type" => status, "checkpoint" => state.checkpoint})
        {:ok, state}

      {:error, state} ->
        {:error, state}
    end
  end

  defp finish_reply(state, status, fields) do
    case finish(state, status, fields) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:noreply, state}
    end
  end

  defp persist_and_start(state, fields) do
    case persist(state, fields) do
      {:ok, state} -> start_attempt(state)
      {:error, state} -> {:noreply, state}
    end
  end

  defp persist(state, fields) do
    checkpoint =
      state.checkpoint
      |> Map.merge(fields)
      |> Map.put("updated_at", timestamp())

    case Store.put(checkpoint) do
      :ok ->
        {:ok, %{state | checkpoint: checkpoint}}

      {:error, reason} ->
        broadcast(state.id, %{"type" => "persistence_failed", "reason" => inspect(reason)})
        {:error, state}
    end
  end

  defp persistence_error(state, reason) do
    broadcast(state.id, %{"type" => "persistence_failed", "reason" => inspect(reason)})
    {:noreply, state}
  end

  defp terminate_attempt(%{attempt_pid: nil} = state), do: state

  defp terminate_attempt(state) do
    _result =
      DynamicSupervisor.terminate_child(
        Names.via(:attempt_supervisor, state.id),
        state.attempt_pid
      )

    clear_attempt(state)
  end

  defp clear_attempt(%{monitor_ref: monitor_ref} = state) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | attempt_pid: nil, attempt_ref: nil, monitor_ref: nil}
  end

  defp clear_attempt(state), do: %{state | attempt_pid: nil, attempt_ref: nil, monitor_ref: nil}

  defp terminal?(status), do: status in ["completed", "failed", "cancelled"]

  defp json_safe(value) do
    case Jason.encode(value) do
      {:ok, _json} -> {:ok, value}
      {:error, reason} -> {:error, %{"non_json_result" => inspect(reason)}}
    end
  end

  defp json_value(value) do
    case json_safe(value) do
      {:ok, safe} -> safe
      {:error, _reason} -> inspect(value)
    end
  end

  defp broadcast(id, event) do
    Phoenix.PubSub.broadcast(
      Catalyst.PubSub,
      Catalyst.WorkflowRun.topic(id),
      {:workflow_run_event, id, event}
    )
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
