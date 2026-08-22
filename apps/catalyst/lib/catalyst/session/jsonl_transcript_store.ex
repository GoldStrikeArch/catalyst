defmodule Catalyst.Session.JSONLTranscriptStore do
  @moduledoc """
  Built-in transcript backend preserving Catalyst's existing JSONL format.
  """

  @behaviour Catalyst.Contracts.TranscriptStore.V1

  alias Catalyst.Session.Store

  @impl true
  defdelegate open(cwd, opts), to: Store

  @impl true
  defdelegate create_new(cwd, opts), to: Store

  @impl true
  def describe(%{id: id, path: path, cwd: cwd})
      when is_binary(id) and is_binary(path) and is_binary(cwd),
      do: {:ok, %{id: id, path: path, cwd: cwd}}

  def describe(handle), do: {:error, {:invalid_jsonl_handle, handle}}

  @impl true
  def load_state(%{path: path}), do: Store.load_state(path)

  @impl true
  defdelegate append(handle, envelope), to: Store, as: :append_envelope

  @impl true
  def close(_handle), do: :ok
end
