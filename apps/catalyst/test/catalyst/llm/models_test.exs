defmodule Catalyst.LLM.ModelsTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.{Models, ProviderConfig, Registry}
  alias Catalyst.Model

  alias Catalyst.Test.LLM.{
    CrashingModelCatalog,
    FixtureModelCatalog,
    FixtureProvider,
    HangingModelCatalog
  }

  setup do
    on_exit(fn ->
      Registry.unregister_provider("fixture-api")
      Registry.unregister_provider("duplicate-api")
      Registry.unregister_provider("broken-api")
      Registry.unregister_provider("hanging-api")
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

  test "selects the highest-priority healthy catalog default" do
    assert {:ok, %{provider_id: "openai-codex", model_id: model_id}} =
             Models.default_selection()

    assert is_binary(model_id) and model_id != ""
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

    options =
      Models.list()
      |> elem(1)
      |> Enum.filter(&(&1.id == "fixture-model"))
      |> Models.picker_options()

    assert Enum.all?(options, fn {_label, value} -> value != "fixture-model" end)

    assert options
           |> Enum.map(fn {_label, value} -> Models.decode_selection(value) end)
           |> Enum.sort() ==
             [
               {:ok, %{"model_id" => "fixture-model", "provider_id" => "duplicate"}},
               {:ok, %{"model_id" => "fixture-model", "provider_id" => "fixture"}}
             ]
  end

  test "catalog crashes and timeouts are bounded and tagged" do
    put_catalog_timeout(10)

    assert :ok =
             Registry.register_provider(
               "broken-api",
               catalog_config("broken", CrashingModelCatalog)
             )

    assert :ok =
             Registry.register_provider(
               "hanging-api",
               catalog_config("hanging", HangingModelCatalog)
             )

    assert {:error, {:model_catalog_exit, "broken", :model, _reason}} =
             Models.build("broken", "broken-model")

    assert {:error, {:model_catalog_exit, "broken", :catalog_snapshot, _reason}} =
             Models.catalog_snapshot("broken", "broken-model")

    assert {:error, {:model_catalog_timeout, "hanging", :default_model_id}} =
             Models.default_model_id("hanging")

    assert {:error, {:model_catalog_timeout, "hanging", :catalog_snapshot}} =
             Models.catalog_snapshot("hanging", "hanging-model")

    assert {:error, {:model_catalog_timeout, "hanging", :model}} =
             Models.build("hanging", "hanging-model")

    assert {:ok, models} = Models.list()
    refute Enum.any?(models, &(&1.provider in ["broken", "hanging"]))
  end

  test "listing reports every broken catalog when none remain" do
    put_catalog_timeout(10)

    {:ok, previous_openai} = Registry.fetch_config("openai-codex-responses")
    {:ok, previous_grok} = Registry.fetch_config("grok-subscription-chat-completions")

    assert :ok =
             Registry.register_provider(
               "openai-codex-responses",
               catalog_config("broken-openai", CrashingModelCatalog)
             )

    assert :ok =
             Registry.register_provider(
               "grok-subscription-chat-completions",
               catalog_config("broken-grok", HangingModelCatalog)
             )

    on_exit(fn ->
      Registry.register_provider("openai-codex-responses", previous_openai)
      Registry.register_provider("grok-subscription-chat-completions", previous_grok)
    end)

    assert {:error, {:no_model_catalogs_available, failures}} = Models.list()
    assert failures |> Enum.map(& &1.provider) |> Enum.sort() == ["broken-grok", "broken-openai"]

    assert Enum.any?(failures, fn failure ->
             match?({:model_catalog_exit, "broken-openai", :catalog_snapshot, _}, failure.reason)
           end)

    assert Enum.any?(failures, fn failure ->
             failure.reason == {:model_catalog_timeout, "broken-grok", :default_model_id}
           end)
  end

  test "providers without catalogs remain valid but cannot build models" do
    assert {:error, {:provider_has_no_catalog, "faux"}} = Models.build("faux", "faux")
  end

  test "rejects provider-qualified picker values with empty ids" do
    for selection <- [["", "fixture-model"], ["fixture", ""]] do
      encoded = selection |> Jason.encode!() |> Base.url_encode64(padding: false)
      value = "catalyst-provider-model:" <> encoded

      assert {:error, {:invalid_model_selection, ^value}} = Models.decode_selection(value)
    end
  end

  defp fixture_config(id) do
    %ProviderConfig{
      id: id,
      module: FixtureProvider,
      name: String.capitalize(id),
      catalog: FixtureModelCatalog
    }
  end

  defp catalog_config(id, catalog) do
    %ProviderConfig{id: id, module: FixtureProvider, name: id, catalog: catalog}
  end

  defp put_catalog_timeout(timeout) do
    previous = Application.get_env(:catalyst, :model_catalog_timeout)
    Application.put_env(:catalyst, :model_catalog_timeout, timeout)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:catalyst, :model_catalog_timeout)
        value -> Application.put_env(:catalyst, :model_catalog_timeout, value)
      end
    end)
  end
end
