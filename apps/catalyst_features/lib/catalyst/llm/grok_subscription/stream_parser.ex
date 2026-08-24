defmodule Catalyst.LLM.GrokSubscription.StreamParser do
  @moduledoc """
  Incrementally assembles xAI Chat Completions chunks into Catalyst content.

  Tool arguments are executable only after the complete JSON object validates;
  malformed or non-object arguments turn the assistant into an error.
  """

  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.LLM.Event

  defstruct text: [],
            thinking: [],
            tool_calls: %{},
            tools: [],
            usage: nil,
            response_id: nil,
            response_model: nil,
            stop_reason: nil,
            error: nil,
            done: false,
            text_started?: false,
            text_ended?: false

  @type t :: %__MODULE__{}

  @doc "Create an empty stream parser."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Reduce one decoded SSE payload and emit normalized stream events."
  @spec handle(t(), map(), Catalyst.LLM.Provider.sink()) :: t()
  def handle(parser, event, sink) when is_map(event) do
    parser =
      parser
      |> put_if_binary(:response_id, event["id"])
      |> put_if_binary(:response_model, event["model"])
      |> put_usage(event["usage"])

    case event do
      %{"error" => error} ->
        fail(parser, error_message(error), sink)

      %{"choices" => choices} when is_list(choices) ->
        Enum.reduce(choices, parser, &handle_choice(&2, &1, sink))

      _other ->
        parser
    end
  end

  @doc "Mark a transport or protocol failure while preserving complete partial text."
  @spec fail(t(), term(), Catalyst.LLM.Provider.sink()) :: t()
  def fail(%__MODULE__{done: true} = parser, _reason, _sink), do: parser

  def fail(parser, reason, sink) do
    parser = end_text(parser, sink)
    %{parser | done: true, stop_reason: :error, error: error_message(reason)}
  end

  @doc "Build the authoritative assistant returned by the provider."
  @spec finalize(t(), Catalyst.Model.t()) :: Message.Assistant.t()
  def finalize(parser, model) do
    parser =
      case parser.done do
        true ->
          parser

        false ->
          %{parser | done: true, stop_reason: :error, error: "stream ended before completion"}
      end

    content = content(parser)
    error = parser.error

    content =
      case {content, error} do
        {[], message} when is_binary(message) -> [%Content.Text{text: message}]
        _other -> content
      end

    %Message.Assistant{
      content: content,
      api: model.api,
      provider: model.provider,
      model: parser.response_model || model.id,
      usage: usage_from(parser.usage),
      stop_reason: parser.stop_reason || :error,
      error_message: error,
      response_id: parser.response_id,
      timestamp: Message.now()
    }
  end

  defp handle_choice(parser, choice, sink) do
    delta = choice["delta"] || %{}

    parser =
      parser
      |> append_thinking(delta["reasoning_content"], sink)
      |> append_text(delta["content"], sink)
      |> append_tool_calls(delta["tool_calls"], sink)

    case choice["finish_reason"] do
      reason when is_binary(reason) -> finish(parser, reason, sink)
      _not_finished -> parser
    end
  end

  defp append_thinking(parser, delta, sink) when is_binary(delta) and delta != "" do
    sink.(%Event.ThinkingDelta{delta: delta})
    %{parser | thinking: [delta | parser.thinking]}
  end

  defp append_thinking(parser, _delta, _sink), do: parser

  defp append_text(parser, delta, sink) when is_binary(delta) and delta != "" do
    parser =
      case parser.text_started? do
        true ->
          parser

        false ->
          sink.(%Event.TextStart{})
          %{parser | text_started?: true}
      end

    sink.(%Event.TextDelta{delta: delta})
    %{parser | text: [delta | parser.text]}
  end

  defp append_text(parser, _delta, _sink), do: parser

  defp append_tool_calls(parser, calls, sink) when is_list(calls) do
    Enum.reduce(calls, parser, &append_tool_call(&2, &1, sink))
  end

  defp append_tool_calls(parser, _calls, _sink), do: parser

  defp append_tool_call(parser, call, sink) do
    index = call["index"] || 0
    current = Map.get(parser.tool_calls, index, %{id: nil, name: nil, args: [], started?: false})
    function = call["function"] || %{}

    next = %{
      current
      | id: nonempty(call["id"]) || current.id,
        name: nonempty(function["name"]) || current.name,
        args: add_chunk(current.args, function["arguments"])
    }

    next = maybe_start_tool(next, sink)
    maybe_emit_tool_delta(next, function["arguments"], sink)
    %{parser | tool_calls: Map.put(parser.tool_calls, index, next)}
  end

  defp maybe_start_tool(%{started?: false, id: id, name: name} = tool, sink)
       when is_binary(id) and is_binary(name) do
    sink.(%Event.ToolCallStart{id: id, name: name})
    %{tool | started?: true}
  end

  defp maybe_start_tool(tool, _sink), do: tool

  defp maybe_emit_tool_delta(%{started?: true, id: id}, delta, sink)
       when is_binary(delta) and delta != "" do
    sink.(%Event.ToolCallDelta{id: id, delta: delta})
  end

  defp maybe_emit_tool_delta(_tool, _delta, _sink), do: :ok

  defp finish(%__MODULE__{done: true} = parser, _reason, _sink), do: parser

  defp finish(parser, reason, sink) do
    parser = parser |> finalize_tools(sink) |> end_text(sink)

    case parser.error do
      nil -> %{parser | done: true, stop_reason: stop_reason(reason, parser.tools)}
      _error -> %{parser | done: true, stop_reason: :error}
    end
  end

  defp finalize_tools(parser, sink) do
    parser.tool_calls
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(parser, fn {_index, tool}, acc -> finalize_tool(acc, tool, sink) end)
  end

  defp finalize_tool(parser, %{id: id, name: name} = tool, sink)
       when is_binary(id) and is_binary(name) do
    arguments = tool.args |> Enum.reverse() |> IO.iodata_to_binary()

    case decode_arguments(arguments) do
      {:ok, decoded} ->
        _tool = maybe_start_tool(tool, sink)
        sink.(%Event.ToolCallEnd{id: id, name: name, arguments: decoded})

        %{
          parser
          | tools: [%Content.ToolCall{id: id, name: name, arguments: decoded} | parser.tools]
        }

      {:error, reason} ->
        %{parser | error: "invalid arguments for tool #{name}: #{reason}"}
    end
  end

  defp finalize_tool(parser, _incomplete, _sink),
    do: %{parser | error: "incomplete tool call in Grok response"}

  defp end_text(%{text_started?: true, text_ended?: false} = parser, sink) do
    sink.(%Event.TextEnd{})
    %{parser | text_ended?: true}
  end

  defp end_text(parser, _sink), do: parser

  defp content(parser) do
    [
      content_block(Content.Thinking, parser.thinking, :thinking),
      content_block(Content.Text, parser.text, :text)
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(Enum.reverse(parser.tools))
  end

  defp content_block(_module, [], _field), do: nil

  defp content_block(module, chunks, field) do
    value = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    struct!(module, [{field, value}])
  end

  defp decode_arguments(""), do: {:ok, %{}}

  defp decode_arguments(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, "expected a JSON object, got #{inspect(other)}"}
      {:error, reason} -> {:error, Exception.message(reason)}
    end
  end

  defp put_usage(parser, %{} = usage), do: %{parser | usage: usage}
  defp put_usage(parser, _usage), do: parser

  defp put_if_binary(parser, field, value) when is_binary(value) and value != "",
    do: Map.put(parser, field, value)

  defp put_if_binary(parser, _field, _value), do: parser

  defp add_chunk(chunks, value) when is_binary(value) and value != "", do: [value | chunks]
  defp add_chunk(chunks, _value), do: chunks

  defp nonempty(value) when is_binary(value) and value != "", do: value
  defp nonempty(_value), do: nil

  defp stop_reason("length", _tools), do: :length
  defp stop_reason("content_filter", _tools), do: :error
  defp stop_reason("tool_calls", _tools), do: :tool_use
  defp stop_reason("function_call", _tools), do: :tool_use
  defp stop_reason(_reason, [_tool | _rest]), do: :tool_use
  defp stop_reason(_reason, []), do: :stop

  defp usage_from(nil), do: %Usage{}

  defp usage_from(usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    prompt = usage["prompt_tokens"] || 0

    %Usage{
      input: max(prompt - cached, 0),
      output: usage["completion_tokens"] || 0,
      cache_read: cached,
      total_tokens: usage["total_tokens"] || 0
    }
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(reason), do: inspect(reason)
end
