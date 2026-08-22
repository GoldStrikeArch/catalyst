defmodule CatalystWeb.ShellLive.SettingsTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.{Models, ProviderConfig, Registry}
  alias Catalyst.Model
  alias CatalystWeb.ShellLive.Settings

  @base_prefs %{
    model: "gpt-5.4",
    provider: "openai-codex",
    effort: "medium",
    fast: false,
    transport: "auto"
  }

  defmodule FixtureProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :unused}
  end

  defmodule FixtureAuth do
    @behaviour Catalyst.Auth.Flow

    @impl true
    def provider_id, do: "fixture-auth"

    @impl true
    def label, do: "Fixture Subscription"

    @impl true
    def login(_opts), do: {:ok, "fixture-account"}

    @impl true
    def refresh(credentials), do: {:ok, credentials}
  end

  defmodule FixtureCatalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @entry %{
      id: "fixture-model",
      name: "Fixture Model",
      efforts: ["high"],
      default_effort: "high",
      fast?: false
    }

    @impl true
    def default_model_id, do: @entry.id

    @impl true
    def catalog_snapshot(id) do
      selected = if id == @entry.id, do: @entry, else: %{@entry | id: id, name: id}
      %{models: [selected], selected: selected}
    end

    @impl true
    def model(id), do: %Model{id: id, api: "fixture-api", provider: "fixture"}
  end

  defmodule SparseCatalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @impl true
    def default_model_id, do: "sparse-model"

    @impl true
    def catalog_snapshot(id) do
      selected = %{id: id}
      %{models: [selected], selected: selected}
    end

    @impl true
    def model(id), do: %Model{id: id, api: "sparse-api", provider: "sparse"}
  end

  defmodule DuplicateCatalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @impl true
    def default_model_id, do: "fixture-model"

    @impl true
    def catalog_snapshot(id) do
      selected = %{id: id, name: "Duplicate Fixture Model"}
      %{models: [selected], selected: selected}
    end

    @impl true
    def model(id), do: %Model{id: id, api: "duplicate-api", provider: "duplicate"}
  end

  setup do
    on_exit(fn ->
      Enum.each(
        ["fixture-api", "sparse-api", "duplicate-api", "no-catalog-api"],
        &Registry.unregister_provider/1
      )
    end)

    :ok
  end

  describe "run_opts/1" do
    test "derives session options and preserves nil for option deletion" do
      assert Settings.run_opts(@base_prefs) ==
               [reasoning_effort: "medium", service_tier: nil, transport: "auto"]

      assert Settings.run_opts(%{@base_prefs | fast: true}) ==
               [reasoning_effort: "medium", service_tier: "priority", transport: "auto"]
    end
  end

  test "provider selection is deferred to the model API's live registry entry" do
    assert {:ok, %{api: "openai-codex-responses", id: "gpt-5.4"}} =
             Settings.provider_config(@base_prefs)
  end

  test "a registered descriptor drives models, controls, and subscription metadata" do
    config = %ProviderConfig{
      id: "fixture",
      module: FixtureProvider,
      name: "Fixture Subscription",
      catalog: FixtureCatalog,
      auth: FixtureAuth
    }

    assert :ok = Registry.register_provider("fixture-api", config)

    prefs = Settings.update_codex(@base_prefs, %{"model" => "fixture-model"})
    assert prefs.provider == "fixture"
    assert {:ok, %{api: "fixture-api", id: "fixture-model"}} = Settings.provider_config(prefs)

    assert Settings.run_opts(prefs) == [
             reasoning_effort: "high",
             service_tier: nil,
             transport: nil
           ]

    assert Settings.auth_provider(prefs) == "fixture-auth"
    assert Settings.auth_label(prefs) == "Fixture Subscription"

    assert %{selected: %{provider: "fixture", provider_name: "Fixture Subscription"}} =
             Settings.catalog_snapshot(prefs)

    assert :ok = Registry.unregister_provider("fixture-api")

    assert %{selected: %{provider: "openai-codex", id: "fixture-model"}} =
             Settings.catalog_snapshot(prefs)
  end

  test "contract-minimal catalog entries and providers without auth remain usable" do
    config = %ProviderConfig{
      id: "sparse",
      module: FixtureProvider,
      name: "Sparse Provider",
      catalog: SparseCatalog,
      auth: nil
    }

    assert :ok = Registry.register_provider("sparse-api", config)

    prefs = %{@base_prefs | provider: "sparse", model: "sparse-model", effort: nil, fast: true}

    assert %{selected: selected} = Settings.catalog_snapshot(prefs)
    assert selected.id == "sparse-model"
    assert selected.name == "sparse-model"
    assert selected.efforts == []
    refute selected.fast?
    assert Settings.auth_provider(prefs) == nil
    assert Settings.logged_in?(prefs)

    assert Settings.run_opts(prefs) == [
             reasoning_effort: nil,
             service_tier: nil,
             transport: nil
           ]
  end

  test "a catalog-less provider returns tagged errors and a safe picker fallback" do
    config = %ProviderConfig{
      id: "no-catalog",
      module: FixtureProvider,
      name: "No Catalog",
      catalog: nil,
      auth: nil
    }

    assert :ok = Registry.register_provider("no-catalog-api", config)
    prefs = %{@base_prefs | provider: "no-catalog", model: "manual-model"}

    assert {:error, {:provider_has_no_catalog, "no-catalog"}} = Settings.provider_config(prefs)

    assert %{models: [%{id: "manual-model"}], selected: %{provider: "no-catalog"}} =
             Settings.catalog_snapshot(prefs)
  end

  test "provider-qualified picker values preserve duplicate model identity" do
    fixture = %ProviderConfig{
      id: "fixture",
      module: FixtureProvider,
      name: "Fixture Subscription",
      catalog: FixtureCatalog,
      auth: FixtureAuth
    }

    duplicate = %ProviderConfig{
      id: "duplicate",
      module: FixtureProvider,
      name: "Duplicate Provider",
      catalog: DuplicateCatalog,
      auth: nil
    }

    assert :ok = Registry.register_provider("fixture-api", fixture)
    assert :ok = Registry.register_provider("duplicate-api", duplicate)
    assert {:ok, snapshot} = Models.catalog_snapshot("duplicate", "fixture-model")

    value = Models.picker_value(snapshot.models, "duplicate", "fixture-model")
    prefs = Settings.update_codex(@base_prefs, %{"model" => value})

    assert prefs.provider == "duplicate"
    assert prefs.model == "fixture-model"
    assert {:ok, %{api: "duplicate-api"}} = Settings.provider_config(prefs)
  end

  describe "toggle_fast/1" do
    test "enables priority for every GPT-5.6 model" do
      Enum.each(~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna), fn model_id ->
        prefs = %{@base_prefs | model: model_id}
        assert Settings.toggle_fast(prefs).fast
      end)
    end

    test "enables priority only for models that support it" do
      assert Settings.toggle_fast(@base_prefs).fast

      prefs = %{@base_prefs | model: "gpt-5.4-mini"}
      refute Settings.toggle_fast(prefs).fast
    end
  end
end
