defmodule Catalyst.Prompt.ConfigTest do
  use ExUnit.Case, async: true

  alias Catalyst.Prompt

  test "validates and reads purpose-aware model and default entries" do
    config = %{
      system: %{"gpt-test" => "system model", default: "system default"},
      compaction: %{default: "compact default"}
    }

    assert :ok = Prompt.validate(config)
    assert {:ok, "system model"} = Prompt.lookup(config, :system, "gpt-test")
    assert {:ok, "system default"} = Prompt.lookup(config, :system, :default)
    assert {:ok, "compact default"} = Prompt.lookup(config, :compaction, :default)
    assert :error = Prompt.lookup(config, :compaction, "missing")
  end

  test "a selected blank value is an error rather than a silent fallthrough" do
    config = %{system: %{"blank" => "  \n", default: "usable"}}

    assert :ok = Prompt.validate(config)

    assert {:error, {:invalid_prompt_config, {:blank_text, :system, "blank"}}} =
             Prompt.lookup(config, :system, "blank")

    assert {:ok, "usable"} = Prompt.lookup(config, :system, :default)
  end

  test "rejects malformed outer shapes, purposes, keys, and values" do
    assert {:error, {:invalid_prompt_config, {:expected_map, []}}} = Prompt.validate([])

    assert {:error, {:invalid_prompt_config, {:unknown_purpose, :other}}} =
             Prompt.validate(%{other: %{default: "text"}})

    assert {:error, {:invalid_prompt_config, {:expected_purpose_map, :system, []}}} =
             Prompt.validate(%{system: []})

    assert {:error, {:invalid_prompt_config, {:invalid_model_key, :system, ""}}} =
             Prompt.validate(%{system: %{"" => "text"}})

    assert {:error, {:invalid_prompt_config, {:invalid_model_key, :system, :dynamic_atom}}} =
             Prompt.validate(%{system: %{dynamic_atom: "text"}})

    assert {:error, {:invalid_prompt_config, {:invalid_text, :system, :default, 42}}} =
             Prompt.validate(%{system: %{default: 42}})
  end
end
