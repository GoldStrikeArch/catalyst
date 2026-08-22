defmodule Catalyst.Test.TranscriptStoreB do
  @moduledoc false

  @behaviour Catalyst.Contracts.TranscriptStore.V1

  alias Catalyst.Agent.Event
  alias Catalyst.Session.{EventEnvelope, JSONLTranscriptStore}

  @impl true
  def open(cwd, opts), do: wrap(JSONLTranscriptStore.open(cwd, opts))

  @impl true
  def create_new(cwd, opts), do: wrap(JSONLTranscriptStore.create_new(cwd, opts))

  @impl true
  def describe(%{jsonl: handle}), do: JSONLTranscriptStore.describe(handle)

  @impl true
  def load_state(%{jsonl: handle}), do: JSONLTranscriptStore.load_state(handle)

  @impl true
  def append(%{jsonl: handle}, %EventEnvelope{event: event} = envelope) do
    case event do
      %Event.MessageEnd{} -> notify(:b, :append_message)
      _other -> :ok
    end

    JSONLTranscriptStore.append(handle, envelope)
  end

  @impl true
  def close(%{jsonl: handle}), do: JSONLTranscriptStore.close(handle)

  defp wrap({:ok, handle}), do: {:ok, %{jsonl: handle}}
  defp wrap({:error, _reason} = error), do: error

  defp notify(backend, operation) do
    case :persistent_term.get({__MODULE__, :test_pid}, nil) do
      pid when is_pid(pid) -> send(pid, {:transcript_store, backend, operation})
      nil -> :ok
    end
  end
end
