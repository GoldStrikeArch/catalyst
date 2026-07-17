defmodule Catalyst.Message do
  @moduledoc """
  Conversation messages. Mirrors PI's message union: `user`, `assistant`,
  `toolResult`. `content` is a list of `Catalyst.Content` blocks.
  """

  alias Catalyst.Content

  defmodule User do
    @moduledoc "A user-authored message with content blocks and an optional timestamp."
    @enforce_keys [:content]
    defstruct [:content, :timestamp]
    @type t :: %__MODULE__{content: [Catalyst.Content.t()], timestamp: integer() | nil}
  end

  defmodule Assistant do
    @moduledoc "An assistant message plus provider metadata, usage, stop reason, and errors."
    defstruct content: [],
              api: nil,
              provider: nil,
              model: nil,
              usage: nil,
              stop_reason: :stop,
              error_message: nil,
              response_id: nil,
              timestamp: nil

    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted
    @type t :: %__MODULE__{
            content: [Catalyst.Content.t()],
            api: String.t() | nil,
            provider: String.t() | nil,
            model: String.t() | nil,
            usage: Catalyst.Usage.t() | nil,
            stop_reason: stop_reason(),
            error_message: String.t() | nil,
            response_id: String.t() | nil,
            timestamp: integer() | nil
          }
  end

  defmodule ToolResult do
    @moduledoc "A tool execution result message associated with an assistant tool call."
    @enforce_keys [:tool_call_id, :tool_name, :content]
    defstruct [:tool_call_id, :tool_name, :content, :details, :timestamp, is_error: false]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            tool_name: String.t(),
            content: [Catalyst.Content.t()],
            details: map() | nil,
            is_error: boolean(),
            timestamp: integer() | nil
          }
  end

  @type t :: User.t() | Assistant.t() | ToolResult.t()

  @doc "Build a user message from a string or content list, stamping the time."
  @spec user(String.t() | [Content.t()]) :: User.t()
  def user(content) when is_binary(content), do: user(Content.text(content))
  def user(content) when is_list(content), do: %User{content: content, timestamp: now()}

  @doc "Tool-call blocks contained in an assistant message."
  @spec tool_calls(t()) :: [Content.ToolCall.t()]
  def tool_calls(%Assistant{content: content}), do: Content.tool_calls(content)
  def tool_calls(_), do: []

  @doc "Current wall-clock time in milliseconds."
  @spec now() :: integer()
  def now, do: System.system_time(:millisecond)
end
