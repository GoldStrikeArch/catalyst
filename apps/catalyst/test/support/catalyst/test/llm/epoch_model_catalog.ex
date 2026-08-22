defmodule Catalyst.Test.LLM.EpochModelCatalog do
  @moduledoc false

  @behaviour Catalyst.LLM.ModelCatalog

  alias Catalyst.Model

  @entry %{
    id: "epoch-model",
    name: "Epoch Model",
    context_window: 77_777,
    max_context_window: 88_888,
    efforts: ["low"]
  }

  @impl true
  def default_model_id, do: @entry.id

  @impl true
  def catalog_snapshot(_id), do: %{models: [@entry], selected: @entry}

  @impl true
  def model(id), do: %Model{id: id, api: "epoch-api", provider: "epoch"}
end
