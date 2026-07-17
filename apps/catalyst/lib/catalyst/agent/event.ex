defmodule Catalyst.Agent.Event do
  @moduledoc """
  Events emitted by `Catalyst.Agent.Loop` (PI's `AgentEvent`). The loop pushes
  these to a `sink`; `Catalyst.Session.Server` folds them into state and
  re-broadcasts on `"session:<id>"`.

  Ordering per turn:

      turn_start
        message_start (assistant)
          message_update*            # streaming deltas
        message_end   (assistant)
        [per tool call]
          tool_execution_start
            tool_execution_update*
          tool_execution_end
          (a tool_result message_end follows via the loop appending results)
      turn_end
  """

  defmodule AgentStart, do: defstruct([])
  defmodule AgentEnd, do: defstruct([:messages])
  defmodule TurnStart, do: defstruct([])
  defmodule TurnEnd, do: defstruct([:message, :tool_results])
  defmodule MessageStart, do: defstruct([:message])
  defmodule MessageUpdate, do: defstruct([:message, :llm_event])
  defmodule MessageEnd, do: defstruct([:message])
  defmodule ToolExecutionStart, do: defstruct([:call_id, :name, :args])
  defmodule ToolExecutionUpdate, do: defstruct([:call_id, :name, :args, :partial])
  defmodule ToolExecutionEnd, do: defstruct([:call_id, :name, :result, :is_error])

  @type t ::
          %AgentStart{}
          | %AgentEnd{}
          | %TurnStart{}
          | %TurnEnd{}
          | %MessageStart{}
          | %MessageUpdate{}
          | %MessageEnd{}
          | %ToolExecutionStart{}
          | %ToolExecutionUpdate{}
          | %ToolExecutionEnd{}
end
