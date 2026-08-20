defmodule Catalyst.ACP.ClaudeTest do
  use ExUnit.Case, async: true

  alias Catalyst.ACP.Claude

  test "keeps the Claude Code prompt when no Catalyst override exists" do
    assert {:ok, meta} = Claude.session_meta(%{prompt_override: nil, opts: []})

    refute Map.has_key?(meta, "systemPrompt")
    assert get_in(meta, ["claudeCode", "options", "settingSources"]) == []
  end

  test "supports documented replacement and preset append metadata" do
    config = %{prompt_override: "Catalyst guidance", opts: []}

    assert {:ok, %{"systemPrompt" => "Catalyst guidance"}} = Claude.session_meta(config)

    assert {:ok, meta} =
             Claude.session_meta(%{
               config
               | opts: [
                   acp_claude_prompt_mode: :append,
                   acp_claude_setting_sources: ["user"]
                 ]
             })

    assert meta["systemPrompt"] == %{"append" => "Catalyst guidance"}
    assert get_in(meta, ["claudeCode", "options", "settingSources"]) == ["user"]
  end

  test "rejects unsupported modes and setting sources" do
    assert {:error, {:invalid_acp_claude_prompt_mode, :unknown}} =
             Claude.session_meta(%{
               prompt_override: "prompt",
               opts: [acp_claude_prompt_mode: :unknown]
             })

    assert {:error, {:invalid_acp_claude_setting_sources, ["managed"]}} =
             Claude.session_meta(%{
               prompt_override: nil,
               opts: [acp_claude_setting_sources: ["managed"]]
             })
  end
end
