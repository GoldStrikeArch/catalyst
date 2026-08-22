defmodule Catalyst.Test.TranscriptStoreA do
  @moduledoc false

  @behaviour Catalyst.Contracts.TranscriptStore.V1

  alias Catalyst.Session.JSONLTranscriptStore

  @impl true
  def open(cwd, opts), do: wrap(JSONLTranscriptStore.open(cwd, opts))

  @impl true
  def create_new(cwd, opts), do: wrap(JSONLTranscriptStore.create_new(cwd, opts))

  @impl true
  def describe(%{jsonl: handle}), do: JSONLTranscriptStore.describe(handle)

  @impl true
  def load_state(%{jsonl: handle}), do: JSONLTranscriptStore.load_state(handle)

  @impl true
  def append_message(%{jsonl: handle}, message) do
    notify(:a, :append_message)
    JSONLTranscriptStore.append_message(handle, message)
  end

  @impl true
  def append_reset(%{jsonl: handle}), do: JSONLTranscriptStore.append_reset(handle)

  @impl true
  def append_compaction(%{jsonl: handle}, event),
    do: JSONLTranscriptStore.append_compaction(handle, event)

  @impl true
  def append_settings_snapshot(%{jsonl: handle}, settings),
    do: JSONLTranscriptStore.append_settings_snapshot(handle, settings)

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
