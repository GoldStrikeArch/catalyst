defmodule Catalyst.Test.LLM.ComparisonModelCatalog do
  @moduledoc false

  @behaviour Catalyst.LLM.ModelCatalog

  alias Catalyst.Model

  @entry %{
    id: "third-comparison-model",
    name: "Third Comparison Model",
    efforts: ["medium"],
    default_effort: "medium",
    context_window: 64_000
  }

  @impl true
  def default_model_id, do: @entry.id

  @impl true
  def catalog_snapshot(id) do
    selected = if id == @entry.id, do: @entry, else: %{@entry | id: id, name: id}
    models = if id == @entry.id, do: [@entry], else: [@entry, selected]
    %{models: models, selected: selected}
  end

  @impl true
  def model(id),
    do: %Model{id: id, api: "third-comparison-api", provider: "third-comparison"}
end
