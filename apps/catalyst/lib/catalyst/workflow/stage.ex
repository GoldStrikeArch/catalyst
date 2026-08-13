defmodule Catalyst.Workflow.Stage do
  @moduledoc """
  One fresh-child stage in a linear workflow template.

  `inputs` contains `"goal"` and artifact ids produced by earlier stages.
  Every stage produces the artifact named by `artifact`.
  """

  @derive Jason.Encoder
  @enforce_keys [
    :id,
    :name,
    :prompt,
    :preset,
    :tool_profile,
    :inputs,
    :artifact,
    :timeout_ms,
    :max_attempts
  ]
  defstruct @enforce_keys

  @typedoc "A validated, JSON-safe fresh-child stage."
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          prompt: String.t(),
          preset: String.t(),
          tool_profile: String.t(),
          inputs: [String.t()],
          artifact: String.t(),
          timeout_ms: pos_integer(),
          max_attempts: pos_integer()
        }
end
