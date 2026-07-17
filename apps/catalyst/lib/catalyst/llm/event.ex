defmodule Catalyst.LLM.Event do
  @moduledoc """
  Normalized streaming events emitted by a provider's `sink` (PI's
  `AssistantMessageEvent`). The loop forwards these to the UI as
  `message_update`s; the authoritative message is the provider's final return.

  Lifecycle (start/done/error) is not modeled here: the agent loop emits its own
  `Catalyst.Agent.Event` lifecycle around each turn, and errors travel in the
  final assistant message (`stop_reason: :error`).
  """

  defmodule TextStart, do: defstruct([])
  defmodule TextDelta, do: defstruct([:delta])
  defmodule TextEnd, do: defstruct([])
  defmodule ThinkingDelta, do: defstruct([:delta])
  defmodule ToolCallStart, do: defstruct([:id, :name])
  defmodule ToolCallDelta, do: defstruct([:id, :delta])
  defmodule ToolCallEnd, do: defstruct([:id, :name, :arguments])

  @type t ::
          %TextStart{}
          | %TextDelta{}
          | %TextEnd{}
          | %ThinkingDelta{}
          | %ToolCallStart{}
          | %ToolCallDelta{}
          | %ToolCallEnd{}
end
