defmodule CatalystWeb.ShellLive.SettingsTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.{ProviderConfig, Registry}
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

  setup do
    on_exit(fn -> Registry.unregister_provider("fixture-api") end)
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
    assert %{api: "openai-codex-responses", id: "gpt-5.4"} =
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
    assert %{api: "fixture-api", id: "fixture-model"} = Settings.provider_config(prefs)

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
