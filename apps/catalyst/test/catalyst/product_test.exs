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

  defmodule Alternate do
    @behaviour Catalyst.Product

    @impl true
    def id, do: "alternate-test"

    @impl true
    def tools, do: [Catalyst.Tools.Ls]
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

  test "a known product profile can be selected for the next boot" do
    tmp = Path.join(System.tmp_dir!(), "catalyst_product_#{System.unique_integer([:positive])}")
    previous_home = Application.fetch_env(:catalyst, :home)
    previous_profile = Application.fetch_env(:catalyst, :product_profile)
    previous_profiles = Application.fetch_env(:catalyst, :product_profiles)

    Application.put_env(:catalyst, :home, tmp)
    Application.delete_env(:catalyst, :product_profile)
    Application.put_env(:catalyst, :product_profiles, %{"alternate-test" => Alternate})

    on_exit(fn ->
      restore_env(:home, previous_home)
      restore_env(:product_profile, previous_profile)
      restore_env(:product_profiles, previous_profiles)
      File.rm_rf!(tmp)
    end)

    assert Product.active().source == :default
    assert {:ok, :restart_required} = Product.select("alternate-test")
    assert Product.active() == %{id: "alternate-test", module: Alternate, source: :persisted}
    assert Product.tools() == [Catalyst.Tools.Ls]
    assert File.read!(Catalyst.Paths.product_profile()) == "alternate-test\n"
  end

  test "an unknown persisted profile falls back without creating a module identity" do
    tmp = Path.join(System.tmp_dir!(), "catalyst_product_#{System.unique_integer([:positive])}")
    previous_home = Application.fetch_env(:catalyst, :home)
    previous_profile = Application.fetch_env(:catalyst, :product_profile)

    Application.put_env(:catalyst, :home, tmp)
    Application.delete_env(:catalyst, :product_profile)
    File.mkdir_p!(tmp)
    File.write!(Catalyst.Paths.product_profile(), "Elixir.Unknown.DynamicModule\n")

    on_exit(fn ->
      restore_env(:home, previous_home)
      restore_env(:product_profile, previous_profile)
      File.rm_rf!(tmp)
    end)

    assert Product.active() == %{
             id: "coding-agent",
             module: Catalyst.Product.Default,
             source: :fallback
           }
  end
end
