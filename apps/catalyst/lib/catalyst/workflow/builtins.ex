defmodule Catalyst.Workflow.Builtins do
  @moduledoc """
  Immutable workflow templates shipped with Catalyst.

  Built-ins participate in store lookup and listing, but cannot be overwritten
  or deleted by the user-defined template store.
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
  def all,
    do:
      Enum.map(@ids, fn id ->
        {:ok, template} = fetch(id)
        template
      end)

  defp template(attrs) do
    {:ok, template} = Template.new(attrs)
    {:ok, template}
  end

  defp research do
    base("research", "Research", "Investigate a goal and synthesize findings.", [
      stage(
        "investigate",
        "Investigate",
        "Gather relevant evidence for the goal.",
        "thorough",
        "read_only",
        ["goal"],
        "evidence"
      ),
      stage(
        "synthesize",
        "Synthesize",
        "Turn the evidence into a concise, sourced answer.",
        "balanced",
        "read_only",
        ["goal", "evidence"],
        "report"
      )
    ])
  end

  defp build_review do
    base(
      "build-review",
      "Build and review",
      "Implement a change, then review it independently.",
      [
        stage(
          "build",
          "Build",
          "Implement and test the requested change.",
          "balanced",
          "workspace",
          ["goal"],
          "implementation"
        ),
        stage(
          "review",
          "Review",
          "Review the implementation and report actionable findings.",
          "thorough",
          "review",
          ["goal", "implementation"],
          "review"
        )
      ]
    )
  end

  defp secure_build do
    base("secure-build", "Secure build", "Research, implement, and security-review a change.", [
      stage(
        "threat-model",
        "Threat model",
        "Identify security constraints and likely abuse cases.",
        "thorough",
        "security",
        ["goal"],
        "threat-model"
      ),
      stage(
        "build",
        "Build",
        "Implement and test the goal within the identified constraints.",
        "balanced",
        "workspace",
        ["goal", "threat-model"],
        "implementation"
      ),
      stage(
        "security-review",
        "Security review",
        "Audit the implementation against the threat model and report findings.",
        "thorough",
        "security",
        ["goal", "threat-model", "implementation"],
        "security-review"
      )
    ])
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
      "inputs" => inputs,
      "artifact" => artifact,
      "timeout_ms" => 900_000,
      "max_attempts" => 2
    }
  end
end
