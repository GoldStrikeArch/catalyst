defmodule Catalyst.Test.LLM.HangingModelCatalog do
  @moduledoc false

  @behaviour Catalyst.LLM.ModelCatalog

  @impl true
  def default_model_id, do: hang()

  @impl true
  def catalog_snapshot(_id), do: hang()

  @impl true
  def model(_id), do: hang()

  defp hang do
    receive do
      :never -> :ok
    end
  end
end
