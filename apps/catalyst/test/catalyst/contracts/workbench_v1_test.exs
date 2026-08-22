defmodule Catalyst.Contracts.Workbench.V1Test do
  use ExUnit.Case, async: true

  alias Catalyst.Contracts.Workbench.V1

  test "accepts serializable state and the bounded host effect vocabulary" do
    transition =
      {:ok, %{version: 1, files: []},
       [
         {:workspace, :list, "files"},
         {:workspace, :read, "read", "lib/example.ex"},
         {:workspace, :write, "save", "empty.txt", ""},
         {:command, :run, "command", "mix test"},
         {:navigate, "/"}
       ]}

    assert V1.validate_transition(transition) == transition
  end

  test "rejects socket-shaped state and unknown effects" do
    assert {:error, {:invalid_workbench_state, _reason}} =
             V1.validate_transition({:ok, %{owner: self()}, []})

    assert {:error, {:invalid_workbench_effect, {:socket, :mutate}}} =
             V1.validate_transition({:ok, %{}, [{:socket, :mutate}]})
  end
end
