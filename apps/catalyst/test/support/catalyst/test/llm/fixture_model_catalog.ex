defmodule Catalyst.Test.LLM.FixtureModelCatalog do
  @moduledoc false

  @behaviour Catalyst.LLM.ModelCatalog

  alias Catalyst.Model

  @entry %{
    id: "fixture-model",
    name: "Fixture Model",
    efforts: ["low"],
    default_effort: "low",
    fast?: false
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
  def model(id), do: %Model{id: id, api: "fixture-api", provider: "fixture"}
end
