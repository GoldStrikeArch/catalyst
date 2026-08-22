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

  test "bounds effect admission and rejects ambiguous request ids" do
    duplicate = [
      {:workspace, :read, "same", "one.ex"},
      {:command, :run, "same", "mix test"}
    ]

    assert {:error, {:duplicate_workbench_effect_ids, ["same"]}} =
             V1.validate_effects(duplicate)

    effects = Enum.map(1..33, &{:workspace, :list, Integer.to_string(&1)})
    assert {:error, {:too_many_workbench_effects, 33, 32}} = V1.validate_effects(effects)
  end

  test "accepts bounded versioned handoff capsules" do
    capsule = %{version: 1, payload: %{active_file: "lib/example.ex"}}
    assert {:ok, ^capsule} = V1.validate_capsule(capsule)

    assert {:error, {:invalid_workbench_capsule, %{payload: %{}}}} =
             V1.validate_capsule(%{payload: %{}})
  end
end
