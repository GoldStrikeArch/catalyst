defmodule Catalyst.Workflow.Builtins do
  @moduledoc """
  Immutable linear workflow templates shipped with Catalyst.

  Review stages intentionally receive only the original goal and current
  workspace. They never consume implementation-agent artifacts, preserving an
  independent adversarial review context.
  """

  alias Catalyst.Workflow.Template

  @ids ~w(research build-review secure-build)

  @doc "Return built-in template ids in display order."
  @spec ids() :: [String.t()]
  def ids, do: @ids

  @doc "Fetch an immutable built-in template."
  @spec fetch(String.t()) :: {:ok, Template.t()} | {:error, :not_found}
  def fetch("research"), do: template(research())
  def fetch("build-review"), do: template(build_review())
  def fetch("secure-build"), do: template(secure_build())
  def fetch(_id), do: {:error, :not_found}

  @doc "List every immutable built-in template."
  @spec all() :: [Template.t()]
  def all do
    Enum.map(@ids, fn id ->
      {:ok, template} = fetch(id)
      template
    end)
  end

  defp template(attrs) do
    {:ok, template} = Template.new(attrs)
    {:ok, template}
  end

  defp research do
    base("research", "Research", "Research a codebase without modifying it.", [
      stage(
        "research",
        "Research",
        "Research the goal in the current workspace. Report relevant architecture, files, risks, and a concise plan.",
        "research",
        "inspect",
        ["goal"],
        "research"
      )
    ])
  end

  defp build_review do
    base("build-review", "Build and review", "Research, implement, review, repair, and verify.", [
      stage(
        "research",
        "Research",
        "Research the goal and produce an implementation handoff.",
        "research",
        "inspect",
        ["goal"],
        "research"
      ),
      stage(
        "implement",
        "Implement",
        "Implement the goal using the research handoff. Add focused tests.",
        "implementation",
        "coding",
        ["goal", "research"],
        "implementation"
      ),
      stage(
        "review",
        "Adversarial code review",
        "Independently review the current workspace changes. Report only actionable correctness, reliability, and maintainability findings.",
        "code_review",
        "inspect",
        ["goal"],
        "review"
      ),
      stage(
        "repair",
        "Repair review findings",
        "Verify each review finding and repair the actionable issues. Preserve correct behavior and tests.",
        "repair",
        "coding",
        ["goal", "review"],
        "repair"
      ),
      stage(
        "verify",
        "Verify",
        "Run the repository-required checks and summarize the final outcome.",
        "verification",
        "coding",
        ["goal"],
        "verification"
      )
    ])
  end

  defp secure_build do
    base(
      "secure-build",
      "Secure build",
      "Research, implement, independently review, security-review, repair, and verify.",
      build_review()["stages"]
      |> List.insert_at(
        4,
        stage(
          "security-review",
          "Adversarial security review",
          "Independently audit the current workspace for trust-boundary, injection, filesystem, process, capability, persistence, secret, and network risks.",
          "security_review",
          "inspect",
          ["goal"],
          "security-review"
        )
      )
      |> List.insert_at(
        5,
        stage(
          "security-repair",
          "Repair security findings",
          "Verify and repair actionable security findings, then add focused regressions.",
          "repair",
          "coding",
          ["goal", "security-review"],
          "security-repair"
        )
      )
    )
  end

  defp base(id, name, description, stages) do
    %{
      "version" => 1,
      "id" => id,
      "name" => name,
      "description" => description,
      "stages" => stages
    }
  end

  defp stage(id, name, prompt, preset, tool_profile, inputs, artifact) do
    %{
      "id" => id,
      "name" => name,
      "prompt" => prompt,
      "preset" => preset,
      "tool_profile" => tool_profile,
      "model" => "inherit",
      "reasoning_effort" => if(tool_profile == "inspect", do: "high", else: "inherit"),
      "inputs" => inputs,
      "artifact" => artifact,
      "inactivity_timeout_ms" => 300_000,
      "timeout_ms" => 1_800_000,
      "max_attempts" => 3
    }
  end
end
