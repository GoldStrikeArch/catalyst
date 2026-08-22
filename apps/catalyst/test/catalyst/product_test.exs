defmodule Catalyst.ProductTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Product
  alias Catalyst.Tools.Registry

  defmodule Minimal do
    @behaviour Catalyst.Product

    @impl true
    def id, do: "minimal-test"

    @impl true
    def tools, do: [Catalyst.Tools.Read]
  end

  test "the product profile owns the registry's default composition" do
    previous = Application.fetch_env(:catalyst, :product_profile)
    Application.put_env(:catalyst, :product_profile, Minimal)
    on_exit(fn -> restore_env(:product_profile, previous) end)

    assert Product.profile() == Minimal
    assert Product.id() == "minimal-test"
    assert Product.tools() == [Catalyst.Tools.Read]
    assert Registry.default_tools() == [Catalyst.Tools.Read]
    assert Map.keys(Registry.index()) == ["read"]
  end
end
