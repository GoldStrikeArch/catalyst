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

  defmodule AgentStart do
    @moduledoc "Emitted when an agent loop starts."
    defstruct []
  end

  defmodule AgentEnd do
    @moduledoc "Emitted when an agent loop finishes with the final message list."
    defstruct [:messages]
  end

  defmodule TurnStart do
    @moduledoc "Emitted before a model turn begins."
    defstruct []
  end

  defmodule TurnEnd do
    @moduledoc "Emitted after a model turn and any requested tool executions finish."
    defstruct [:message, :tool_results]
  end

  defmodule MessageStart do
    @moduledoc "Emitted when an assistant message begins streaming."
    defstruct [:message]
  end

  defmodule MessageUpdate do
    @moduledoc "Emitted for a normalized LLM stream event during message generation."
    defstruct [:llm_event]
  end

  defmodule MessageEnd do
    @moduledoc "Emitted when a message has been finalized."
    defstruct [:message]
  end

  defmodule ToolExecutionStart do
    @moduledoc "Emitted before a tool call starts executing."
    defstruct [:call_id, :name, :args]
  end

  defmodule ToolExecutionUpdate do
    @moduledoc "Emitted while a tool call reports partial output."
    defstruct [:call_id, :name, :args, :partial]
  end

  defmodule ToolExecutionEnd do
    @moduledoc "Emitted after a tool call finishes or fails."
    defstruct [:call_id, :name, :result, :is_error]
  end

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
