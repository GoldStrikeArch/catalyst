defmodule Catalyst.Test.LLM.CrashingModelCatalog do
  @moduledoc false

  @behaviour Catalyst.LLM.ModelCatalog

  @impl true
  def default_model_id, do: "broken-model"

  @impl true
  def catalog_snapshot(_id), do: raise("broken catalog")

  @impl true
  def model(_id), do: exit(:broken_catalog_model)
end
