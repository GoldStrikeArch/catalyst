defmodule Catalyst.Content do
  @moduledoc """
  Content blocks that make up message bodies.

  Mirrors PI's `packages/ai/src/types.ts` content union (text / thinking / image /
  tool_call) so conversion to and from provider wire formats stays mechanical.
  """

  defmodule Text do
    @moduledoc "A plain text content block."
    @enforce_keys [:text]
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule Thinking do
    @moduledoc "A reasoning block. `signature` round-trips provider reasoning ids."
    @enforce_keys [:thinking]
    defstruct [:thinking, :signature, redacted: false]
    @type t :: %__MODULE__{thinking: String.t(), signature: String.t() | nil, redacted: boolean()}
  end

  defmodule Image do
    @moduledoc "An inline image content block with binary data and MIME type."
    @enforce_keys [:data, :mime_type]
    defstruct [:data, :mime_type]
    @type t :: %__MODULE__{data: binary(), mime_type: String.t()}
  end

  defmodule ToolCall do
    @moduledoc "A model-requested tool call with decoded argument data."
    @enforce_keys [:id, :name]
    defstruct [:id, :name, arguments: %{}]
    @type t :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}
  end

  @type t :: Text.t() | Thinking.t() | Image.t() | ToolCall.t()

  @doc "Wrap a plain string as a single text block list."
  @spec text(String.t()) :: [Text.t()]
  def text(string) when is_binary(string), do: [%Text{text: string}]

  @doc "Extract the concatenated text from a content list."
  @spec text_of([t()]) :: String.t()
  def text_of(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  @doc "Collect the tool-call blocks from a content list."
  @spec tool_calls([t()]) :: [ToolCall.t()]
  def tool_calls(content) when is_list(content) do
    Enum.filter(content, &match?(%ToolCall{}, &1))
  end
end
