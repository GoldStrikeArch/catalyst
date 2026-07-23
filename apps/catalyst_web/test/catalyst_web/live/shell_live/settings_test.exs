defmodule CatalystWeb.ShellLive.SettingsTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.ShellLive.Settings

  @base_prefs %{
    model: "gpt-5.4",
    effort: "medium",
    fast: false,
    transport: "auto"
  }

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

  describe "toggle_fast/1" do
    test "enables priority only for models that support it" do
      assert Settings.toggle_fast(@base_prefs).fast

      prefs = %{@base_prefs | model: "gpt-5.4-mini"}
      refute Settings.toggle_fast(prefs).fast
    end
  end
end
