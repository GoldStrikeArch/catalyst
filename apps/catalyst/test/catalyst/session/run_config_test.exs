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

  defp build!(state) do
    {:ok, config} = RunConfig.build(state, self())
    config
  end

  test "the loop defaults to Catalyst.Agent.Loop" do
    assert build!(state([])).loop == Catalyst.Agent.Loop
  end

  test "the :agent_loop application env swaps the loop (live, reversible)" do
    Application.put_env(:catalyst, :agent_loop, MyCustomLoop)
    on_exit(fn -> Application.delete_env(:catalyst, :agent_loop) end)

    assert build!(state([])).loop == MyCustomLoop

    Application.delete_env(:catalyst, :agent_loop)
    assert build!(state([])).loop == Catalyst.Agent.Loop
  end

  test "a per-session opts[:loop] wins over the env" do
    Application.put_env(:catalyst, :agent_loop, EnvLoop)
    on_exit(fn -> Application.delete_env(:catalyst, :agent_loop) end)

    assert build!(state(opts: [loop: SessionLoop])).loop == SessionLoop
  end

  test "a session without a resolvable provider is a tagged error, not a raise" do
    assert {:error, :no_provider} = RunConfig.build(state(provider: nil), self())

    assert {:error, {:unknown_api, "nope"}} =
             RunConfig.build(state(provider: "nope"), self())
  end
end
