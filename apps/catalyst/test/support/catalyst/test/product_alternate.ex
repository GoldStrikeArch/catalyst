defmodule Catalyst.Test.ProductAlternate do
  @moduledoc false

  @behaviour Catalyst.Product

  @impl true
  def id, do: "alternate-test"

  @impl true
  def tools, do: [Catalyst.Tools.Ls]
end
