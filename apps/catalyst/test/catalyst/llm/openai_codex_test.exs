defmodule Catalyst.LLM.OpenAICodexTest do
  # async: false — flips :codex_models / :codex_model app env.
  use ExUnit.Case, async: false

  alias Catalyst.LLM.OpenAICodex

  test "the built-in catalog lists the Codex models with efforts and Fast capability" do
    models = OpenAICodex.list_models()
    ids = Enum.map(models, & &1.id)

    assert "gpt-5.4" in ids
    assert "gpt-5.5" in ids

    gpt54 = Enum.find(models, &(&1.id == "gpt-5.4"))
    assert gpt54.fast?
    assert gpt54.efforts == ~w(low medium high xhigh)
    assert gpt54.default_effort == "medium"

    refute Enum.find(models, &(&1.id == "gpt-5.4-mini")).fast?
  end

  test "a custom :codex_model outside the catalog still shows up in the list" do
    Application.put_env(:catalyst, :codex_model, "my-custom-model")
    on_exit(fn -> Application.delete_env(:catalyst, :codex_model) end)

    entry = Enum.find(OpenAICodex.list_models(), &(&1.id == "my-custom-model"))
    assert entry.name == "my-custom-model"
    refute entry.fast?
  end

  test ":codex_models config overrides the catalog; catalog_entry falls back for unknown ids" do
    Application.put_env(:catalyst, :codex_models, [%{id: "alt-model", fast?: true}])
    on_exit(fn -> Application.delete_env(:catalyst, :codex_models) end)

    assert [%{id: "alt-model", fast?: true}, %{id: "gpt-5.4"}] = OpenAICodex.list_models()
    assert OpenAICodex.catalog_entry("nope").efforts == ~w(low medium high xhigh)
  end

  test "model/1 uses the catalog display name" do
    assert OpenAICodex.model("gpt-5.4").name == "GPT-5.4"
    assert OpenAICodex.model("unknown-id").name == "unknown-id"
  end
end
