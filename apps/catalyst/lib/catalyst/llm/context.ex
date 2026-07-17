defmodule Catalyst.LLM.Context do
  @moduledoc """
  The payload handed to a provider: the system prompt, the LLM-shaped message
  list, and the available tools (as `%{name, description, parameters}` maps —
  `parameters` being a JSON-Schema map).
  """
  defstruct system_prompt: nil, messages: [], tools: []

  @type tool :: %{name: String.t(), description: String.t(), parameters: map()}
  @type t :: %__MODULE__{
          system_prompt: String.t() | nil,
          messages: [Catalyst.Message.t()],
          tools: [tool()]
        }
end
