defmodule Catalyst.Session.RunContextEffectiveModelTest do
  use ExUnit.Case, async: true

  alias Catalyst.Model
  alias Catalyst.Session.RunContext

  test "nil and non-catalog models pass through unchanged" do
    assert RunContext.effective_model(nil) == nil

    model = %Model{id: "faux", api: "faux", context_window: 1_234}
    assert RunContext.effective_model(model) == model
  end

  test "a session-pinned codex model is not refreshed from the catalog" do
    model = %Model{
      id: "codex-mini",
      api: "openai-codex-responses",
      context_window: 4_242,
      context_window_source: :session
    }

    assert RunContext.effective_model(model) == model
  end

  test "a refreshable codex model gets concrete context metadata" do
    model = %Model{id: "unknown-codex-model", api: "openai-codex-responses"}
    resolved = RunContext.effective_model(model)

    assert %Model{api: "openai-codex-responses"} = resolved
    assert is_integer(resolved.context_window) and resolved.context_window > 0
    assert resolved.context_window_source in [:catalog, :persisted, :fallback]
  end
end
