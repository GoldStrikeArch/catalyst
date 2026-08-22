defmodule Catalyst.LLM.ModelsTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.{Models, ProviderConfig, Registry}
  alias Catalyst.Model

  defmodule Provider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :unused}
  end

  defmodule Catalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @entry %{
      id: "fixture-model",
      name: "Fixture Model",
      efforts: ["low"],
      default_effort: "low",
      fast?: false
    }

    @impl true
    def default_model_id, do: @entry.id

    @impl true
    def catalog_snapshot(id) do
      selected = if id == @entry.id, do: @entry, else: %{@entry | id: id, name: id}
      models = if id == @entry.id, do: [@entry], else: [@entry, selected]
      %{models: models, selected: selected}
    end

    @impl true
    def model(id), do: %Model{id: id, api: "fixture-api", provider: "fixture"}
  end

  setup do
    on_exit(fn ->
      Registry.unregister_provider("fixture-api")
      Registry.unregister_provider("duplicate-api")
    end)

    :ok
  end

  test "aggregates registered catalogs with provider metadata" do
    assert :ok = Registry.register_provider("fixture-api", fixture_config("fixture"))
    assert {:ok, models} = Models.list()

    assert Enum.any?(models, &(&1.id == "fixture-model" and &1.provider == "fixture"))

    assert Enum.any?(
             models,
             &(&1.id == "grok-4.6" and &1.provider == "grok-subscription")
           )
  end

  test "selects unknown ids without losing them from the combined snapshot" do
    assert :ok = Registry.register_provider("fixture-api", fixture_config("fixture"))
    assert {:ok, snapshot} = Models.catalog_snapshot("fixture", "custom-model")

    assert snapshot.selected.id == "custom-model"
    assert snapshot.selected.provider == "fixture"
    assert Enum.any?(snapshot.models, &(&1.id == "custom-model" and &1.provider == "fixture"))
  end

  test "builds models through the selected catalog and resolves their descriptor" do
    assert :ok = Registry.register_provider("fixture-api", fixture_config("fixture"))

    assert {:ok, %Model{id: "fixture-model", api: "fixture-api"} = model} =
             Models.build("fixture", "fixture-model")

    assert {:ok, "fixture"} = Models.provider_id(model)
    assert {:ok, "fixture"} = Models.infer_provider("fixture-model")
    assert {:ok, {"fixture", ^model}} = Models.resolve("fixture-model")
    assert {:ok, {"fixture", ^model}} = Models.resolve("fixture", "fixture-model")
  end

  test "reports duplicate model ids instead of choosing by registry order" do
    assert :ok = Registry.register_provider("fixture-api", fixture_config("fixture"))
    assert :ok = Registry.register_provider("duplicate-api", fixture_config("duplicate"))

    assert {:error, {:ambiguous_model, "fixture-model", ["duplicate", "fixture"]}} =
             Models.infer_provider("fixture-model")
  end

  test "providers without catalogs remain valid but cannot build models" do
    assert {:error, {:provider_has_no_catalog, "faux"}} = Models.build("faux", "faux")
  end

  defp fixture_config(id) do
    %ProviderConfig{
      id: id,
      module: Provider,
      name: String.capitalize(id),
      catalog: Catalog
    }
  end
end
