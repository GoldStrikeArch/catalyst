defmodule Catalyst.Prompt.ConfigTest do
  use ExUnit.Case, async: true

  alias Catalyst.Prompt.Config

  test "validates and reads purpose-aware model and default entries" do
    config = %{
      system: %{"gpt-test" => "system model", default: "system default"},
      compaction: %{default: "compact default"}
    }

    assert :ok = Config.validate(config)
    assert {:ok, "system model"} = Config.lookup(config, :system, "gpt-test")
    assert {:ok, "system default"} = Config.lookup(config, :system, :default)
    assert {:ok, "compact default"} = Config.lookup(config, :compaction, :default)
    assert :error = Config.lookup(config, :compaction, "missing")
  end

  test "a selected blank value is an error rather than a silent fallthrough" do
    config = %{system: %{"blank" => "  \n", default: "usable"}}

    assert :ok = Config.validate(config)

    assert {:error, {:invalid_prompt_config, {:blank_text, :system, "blank"}}} =
             Config.lookup(config, :system, "blank")

    assert {:ok, "usable"} = Config.lookup(config, :system, :default)
  end

  test "rejects malformed outer shapes, purposes, keys, and values" do
    assert {:error, {:invalid_prompt_config, {:expected_map, []}}} = Config.validate([])

    assert {:error, {:invalid_prompt_config, {:unknown_purpose, :other}}} =
             Config.validate(%{other: %{default: "text"}})

    assert {:error, {:invalid_prompt_config, {:expected_purpose_map, :system, []}}} =
             Config.validate(%{system: []})

    assert {:error, {:invalid_prompt_config, {:invalid_model_key, :system, ""}}} =
             Config.validate(%{system: %{"" => "text"}})

    assert {:error, {:invalid_prompt_config, {:invalid_model_key, :system, :dynamic_atom}}} =
             Config.validate(%{system: %{dynamic_atom: "text"}})

    assert {:error, {:invalid_prompt_config, {:invalid_text, :system, :default, 42}}} =
             Config.validate(%{system: %{default: 42}})
  end
end
