defmodule Catalyst.Workflow.TemplateTest do
  use ExUnit.Case, async: true

  alias Catalyst.Workflow.{Builtins, Template}

  test "builds a JSON-safe linear fresh-child template" do
    assert {:ok, template} = Template.new(template_attrs())
    assert template.id == "custom-build"
    assert Enum.map(template.stages, & &1.inputs) == [["goal"], ["goal", "code"]]
    assert Template.new(Template.to_map(template)) == {:ok, template}
    assert Jason.decode!(Jason.encode!(template))["id"] == "custom-build"
  end

  test "rejects forward artifact references and duplicate stage ids" do
    attrs = template_attrs()
    [first, second] = attrs["stages"]

    assert {:error, {:invalid, "stages[0].inputs", {:unavailable_artifact, "code"}}} =
             Template.new(%{attrs | "stages" => [%{first | "inputs" => ["code"]}, second]})

    assert {:error, {:invalid, "stages[1].id", {:duplicate, "build"}}} =
             Template.new(%{attrs | "stages" => [first, %{second | "id" => "build"}]})
  end

  test "bounds ids, text, stage count, timeouts, attempts, presets, and profiles" do
    attrs = template_attrs()
    [first | rest] = attrs["stages"]

    cases = [
      {%{attrs | "id" => "../escape"}, "id", :invalid_id},
      {%{attrs | "name" => String.duplicate("x", 121)}, "name", {:too_long, 120}},
      {%{attrs | "stages" => List.duplicate(first, 17)}, "stages", {:too_many, 16}},
      {replace_first(attrs, "timeout_ms", 999), "stages[0].timeout_ms",
       {:outside_range, 1_000, 3_600_000, 999}},
      {replace_first(attrs, "max_attempts", 6), "stages[0].max_attempts",
       {:outside_range, 1, 5, 6}},
      {replace_first(attrs, "preset", "unknown"), "stages[0].preset", {:unknown, "unknown"}},
      {replace_first(attrs, "tool_profile", "root"), "stages[0].tool_profile", {:unknown, "root"}}
    ]

    Enum.each(cases, fn {invalid, path, reason} ->
      assert {:error, {:invalid, ^path, ^reason}} = Template.new(invalid)
    end)

    assert length(rest) == 1
  end

  test "snapshots are stable and detect tampering" do
    {:ok, template} = Template.new(template_attrs())
    snapshot = Template.snapshot(template)

    assert {:ok, ^template} = Template.from_snapshot(snapshot)
    assert snapshot["digest"] == Template.digest(template)

    tampered = put_in(snapshot, ["template", "name"], "Tampered")

    assert {:error, {:digest_mismatch, snapshot_digest, actual}} =
             Template.from_snapshot(tampered)

    assert snapshot_digest == snapshot["digest"]
    assert actual != snapshot_digest
  end

  test "built-ins are valid, distinct, and immutable values" do
    templates = Builtins.all()
    {:ok, build_review} = Builtins.fetch("build-review")
    {:ok, secure_build} = Builtins.fetch("secure-build")

    assert Enum.map(templates, & &1.id) == ~w(research build-review secure-build)
    assert Enum.all?(templates, &(Template.new(Template.to_map(&1)) == {:ok, &1}))
    assert Enum.uniq(Enum.map(templates, &Template.digest/1)) |> length() == 3

    assert Enum.find(build_review.stages, &(&1.preset == "code_review")).inputs == ["goal"]
    assert Enum.find(secure_build.stages, &(&1.preset == "security_review")).inputs == ["goal"]
  end

  defp replace_first(attrs, key, value) do
    [first | rest] = attrs["stages"]
    %{attrs | "stages" => [Map.put(first, key, value) | rest]}
  end

  defp template_attrs do
    %{
      "version" => 1,
      "id" => "custom-build",
      "name" => "Custom build",
      "description" => "Build and then inspect a change.",
      "stages" => [
        %{
          "id" => "build",
          "name" => "Build",
          "prompt" => "Implement the goal.",
          "preset" => "implementation",
          "tool_profile" => "coding",
          "model" => "inherit",
          "reasoning_effort" => "high",
          "inputs" => ["goal"],
          "artifact" => "code",
          "inactivity_timeout_ms" => 30_000,
          "timeout_ms" => 60_000,
          "max_attempts" => 2
        },
        %{
          "id" => "inspect",
          "name" => "Inspect",
          "prompt" => "Inspect the implementation.",
          "preset" => "code_review",
          "tool_profile" => "inspect",
          "model" => "inherit",
          "reasoning_effort" => "high",
          "inputs" => ["goal", "code"],
          "artifact" => "review",
          "inactivity_timeout_ms" => 30_000,
          "timeout_ms" => 30_000,
          "max_attempts" => 1
        }
      ]
    }
  end
end
