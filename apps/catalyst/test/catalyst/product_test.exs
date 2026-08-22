defmodule Catalyst.ProductTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Product
  alias Catalyst.Product.{Selection, Spec}
  alias Catalyst.Tools.Registry

  test "the product profile owns the registry's default composition" do
    previous = Application.fetch_env(:catalyst, :product_profile)
    Application.put_env(:catalyst, :product_profile, Catalyst.Test.ProductMinimal)
    on_exit(fn -> restore_env(:product_profile, previous) end)

    assert Product.profile() == Catalyst.Test.ProductMinimal
    assert Product.id() == "minimal-test"
    assert Product.tools() == [Catalyst.Tools.Read]

    assert Product.active_spec() == %Spec{
             id: "minimal-test",
             packs: [],
             tools: [Catalyst.Tools.Read],
             hosts: [:cli]
           }

    assert Registry.default_tools() == [Catalyst.Tools.Read]
    assert Map.keys(Registry.index()) == ["read"]
  end

  test "compiled profiles expose validated initial compositions under stable ids" do
    assert Selection.profiles()
           |> Map.take(["coding-agent", "minimal-cli", "ide"])
           |> Map.keys()
           |> Enum.sort() == ["coding-agent", "ide", "minimal-cli"]

    for id <- ["coding-agent", "minimal-cli", "ide"] do
      assert {:ok, profile} = Selection.fetch(id)
      assert {:ok, %Spec{id: ^id, packs: packs}} = Spec.from_profile(profile)
      assert Enum.all?(packs, &is_binary/1)
    end

    assert Catalyst.Product.MinimalCLI.spec().hosts == [:cli]
    assert "catalyst.ide.core" in Catalyst.Product.IDE.spec().packs
  end

  test "product specs reject malformed and duplicate composition entries" do
    assert {:error, {:invalid_product_id, "IDE with spaces"}} =
             Spec.new(%{id: "IDE with spaces", packs: [], tools: [], hosts: [:desktop]})

    assert {:error, {:invalid_product_field, :packs, ["same", "same"]}} =
             Spec.new(%{id: "valid", packs: ["same", "same"], tools: [], hosts: [:cli]})

    assert {:error, {:invalid_product_field, :hosts, [:unknown]}} =
             Spec.new(%{id: "valid", packs: [], tools: [], hosts: [:unknown]})

    assert {:error, {:unknown_pack, "unknown.pack"}} =
             Spec.new(%{id: "valid", packs: ["unknown.pack"], tools: [], hosts: [:cli]})
  end

  test "a known product profile can be selected for the next boot" do
    tmp = Path.join(System.tmp_dir!(), "catalyst_product_#{System.unique_integer([:positive])}")
    previous_home = Application.fetch_env(:catalyst, :home)
    previous_profile = Application.fetch_env(:catalyst, :product_profile)
    previous_profiles = Application.fetch_env(:catalyst, :product_profiles)

    Application.put_env(:catalyst, :home, tmp)
    Application.delete_env(:catalyst, :product_profile)

    Application.put_env(:catalyst, :product_profiles, %{
      "alternate-test" => Catalyst.Test.ProductAlternate
    })

    on_exit(fn ->
      restore_env(:home, previous_home)
      restore_env(:product_profile, previous_profile)
      restore_env(:product_profiles, previous_profiles)
      File.rm_rf!(tmp)
    end)

    assert Product.active().source == :default
    assert {:ok, :restart_required} = Product.select("alternate-test")

    assert Product.active() == %{
             id: "alternate-test",
             module: Catalyst.Test.ProductAlternate,
             source: :persisted
           }

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
