defmodule Catalyst.Session.RunConfigTest do
  # async: false — exercises the :agent_loop application env.
  use ExUnit.Case, async: false

  alias Catalyst.Session.RunConfig

  defp state(overrides) do
    Map.merge(
      %{
        id: "run-config-test",
        provider: Catalyst.LLM.Faux,
        model: nil,
        cwd: ".",
        tools: :extensions,
        opts: []
      },
      Map.new(overrides)
    )
  end

  test "the loop defaults to Catalyst.Agent.Loop" do
    assert RunConfig.build(state([]), self()).loop == Catalyst.Agent.Loop
  end

  test "the :agent_loop application env swaps the loop (live, reversible)" do
    Application.put_env(:catalyst, :agent_loop, MyCustomLoop)
    on_exit(fn -> Application.delete_env(:catalyst, :agent_loop) end)

    assert RunConfig.build(state([]), self()).loop == MyCustomLoop

    Application.delete_env(:catalyst, :agent_loop)
    assert RunConfig.build(state([]), self()).loop == Catalyst.Agent.Loop
  end

  test "a per-session opts[:loop] wins over the env" do
    Application.put_env(:catalyst, :agent_loop, EnvLoop)
    on_exit(fn -> Application.delete_env(:catalyst, :agent_loop) end)

    assert RunConfig.build(state(opts: [loop: SessionLoop]), self()).loop == SessionLoop
  end
end
