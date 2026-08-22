defmodule Catalyst.Test.LLM.DuplicateComparisonModelCatalog do
  @moduledoc false

  @behaviour Catalyst.LLM.ModelCatalog

  alias Catalyst.Model

  @entry %{
    id: "gpt-5.6-sol",
    name: "Third Sol",
    efforts: ["medium"],
    default_effort: "medium",
    context_window: 64_000
  }

  @impl true
  def default_model_id, do: @entry.id

  @impl true
  def catalog_snapshot(_id), do: %{models: [@entry], selected: @entry}

  @impl true
  def model(id), do: %Model{id: id, api: "duplicate-comparison-api", provider: "duplicate"}
end
