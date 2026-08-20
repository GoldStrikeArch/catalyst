defmodule Catalyst.ACP.AgentTest do
  use ExUnit.Case, async: true

  alias Catalyst.ACP.Agent

  test "validates descriptor ids, arguments, and environment keys" do
    assert {:ok, %Agent{id: "fixture", adapter: Catalyst.ACP.Claude}} =
             Agent.new(%{
               "id" => "fixture",
               "name" => "Fixture",
               "command" => "fixture",
               "args" => ["--stdio"],
               "env" => %{"FIXTURE_MODE" => "test"},
               "adapter" => "claude"
             })

    assert {:error, {:invalid_agent_field, :id, "bad/id"}} =
             Agent.new(id: "bad/id", name: "Bad", command: "bad")

    assert {:error, {:invalid_agent_field, :env, _env}} =
             Agent.new(id: "ok", name: "Bad env", command: "ok", env: %{"BAD-KEY" => "x"})

    assert {:error, {:invalid_agent_field, :adapter, "unknown"}} =
             Agent.new(id: "ok", name: "Bad adapter", command: "ok", adapter: "unknown")
  end
end
