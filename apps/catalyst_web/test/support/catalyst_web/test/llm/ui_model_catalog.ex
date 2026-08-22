defmodule CatalystWeb.Test.LLM.UIModelCatalog do
  @moduledoc false

  @behaviour Catalyst.LLM.ModelCatalog

  alias Catalyst.Model

  @entries [
    %{
      id: "third-ui-model",
      name: "Third UI Model",
      efforts: ["low", "medium"],
      default_effort: "low",
      context_window: 32_000
    },
    %{
      id: "gpt-5.6-sol",
      name: "Third UI Sol",
      efforts: ["medium"],
      default_effort: "medium",
      context_window: 32_000
    }
  ]

  @impl true
  def default_model_id, do: hd(@entries).id

  @impl true
  def catalog_snapshot(id) do
    selected = Enum.find(@entries, &(&1.id == id)) || %{hd(@entries) | id: id, name: id}
    models = if Enum.any?(@entries, &(&1.id == id)), do: @entries, else: @entries ++ [selected]
    %{models: models, selected: selected}
  end

  @impl true
  def model(id), do: %Model{id: id, api: "third-ui-api", provider: "third-ui"}
end
