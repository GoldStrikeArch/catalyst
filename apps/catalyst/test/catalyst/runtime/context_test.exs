defmodule Catalyst.Runtime.ContextTest do
  use ExUnit.Case, async: true

  alias Catalyst.Runtime.Context

  test "host contexts carry the active product without overriding explicit identity" do
    assert Context.new(%{}).product_id == nil
    assert Context.host(%{}).product_id == Catalyst.Product.id()
    assert Context.host(product_id: "explicit-product").product_id == "explicit-product"
  end
end
