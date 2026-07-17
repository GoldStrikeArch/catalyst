defmodule Catalyst.LLM.Event do
  @moduledoc """
  Normalized streaming events emitted by a provider's `sink` (PI's
  `AssistantMessageEvent`). The loop forwards these to the UI as
  `message_update`s; the authoritative message is the provider's final return.
  """

  defmodule Start, do: defstruct([:partial])
  defmodule TextStart, do: defstruct([])
  defmodule TextDelta, do: defstruct([:delta])
  defmodule TextEnd, do: defstruct([])
  defmodule ThinkingDelta, do: defstruct([:delta])
  defmodule ToolCallStart, do: defstruct([:id, :name])
  defmodule ToolCallDelta, do: defstruct([:id, :delta])
  defmodule ToolCallEnd, do: defstruct([:id, :name, :arguments])
  defmodule Done, do: defstruct([:reason, :message])
  defmodule Error, do: defstruct([:reason, :message])

  @type t ::
          %Start{}
          | %TextStart{}
          | %TextDelta{}
          | %TextEnd{}
          | %ThinkingDelta{}
          | %ToolCallStart{}
          | %ToolCallDelta{}
          | %ToolCallEnd{}
          | %Done{}
          | %Error{}
end
