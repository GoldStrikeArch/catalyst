defmodule Catalyst.Test.ProductMinimal do
  @moduledoc false

  @behaviour Catalyst.Product

  @impl true
  def id, do: "minimal-test"

  @impl true
  def tools, do: [Catalyst.Tools.Read]
end
