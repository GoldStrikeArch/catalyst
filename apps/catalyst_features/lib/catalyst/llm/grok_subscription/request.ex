defmodule Catalyst.LLM.GrokSubscription.Request do
  @moduledoc "Projects Catalyst messages and tools into xAI Chat Completions JSON."

  alias Catalyst.{Content, Message}
  alias Catalyst.LLM.Context

  @doc "Build a streaming Grok Chat Completions request."
  @spec build(Catalyst.Model.t(), Context.t(), keyword()) :: map()
  def build(model, context, opts) do
    %{
      "model" => model.id,
      "messages" => messages(context),
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "reasoning_effort" => opts[:reasoning_effort] || "high"
    }
    |> put_tools(context.tools)
    |> put_max_tokens(model.max_tokens)
  end

  defp messages(%Context{} = context) do
    system_message(context.system_prompt) ++ Enum.map(context.messages, &message/1)
  end

  defp system_message(prompt) when is_binary(prompt) and prompt != "",
    do: [%{"role" => "system", "content" => prompt}]

  defp system_message(_prompt), do: []

  defp message(%Message.User{content: content}) do
    %{"role" => "user", "content" => content_parts(content)}
  end

  defp message(%Message.Assistant{content: content}) do
    content
    |> Enum.reduce(%{"role" => "assistant"}, &assistant_part/2)
    |> Map.put_new("content", "")
  end

  defp message(%Message.ToolResult{} = result) do
    %{
      "role" => "tool",
      "tool_call_id" => result.tool_call_id,
      "content" => content_parts(result.content)
    }
  end

  defp assistant_part(%Content.Text{text: text}, message),
    do: Map.update(message, "content", text, &(&1 <> text))

  defp assistant_part(%Content.Thinking{thinking: thinking}, message),
    do: Map.update(message, "reasoning_content", thinking, &(&1 <> thinking))

  defp assistant_part(%Content.ToolCall{} = call, message) do
    wire = %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.name, "arguments" => Jason.encode!(call.arguments)}
    }

    Map.update(message, "tool_calls", [wire], &(&1 ++ [wire]))
  end

  defp assistant_part(_unsupported, message), do: message

  defp content_parts(content) do
    Enum.flat_map(content, fn
      %Content.Text{text: text} ->
        [%{"type" => "text", "text" => text}]

      %Content.Image{data: data, mime_type: mime_type} ->
        url = "data:#{mime_type};base64,#{data}"
        [%{"type" => "image_url", "image_url" => %{"url" => url}}]

      _unsupported ->
        []
    end)
  end

  defp put_tools(body, []), do: body

  defp put_tools(body, tools) do
    wire_tools =
      Enum.map(tools, fn tool ->
        %{
          "type" => "function",
          "function" => %{
            "name" => tool.name,
            "description" => tool.description,
            "parameters" => tool.parameters
          }
        }
      end)

    body
    |> Map.put("tools", wire_tools)
    |> Map.put("tool_choice", "auto")
  end

  defp put_max_tokens(body, max_tokens) when is_integer(max_tokens) and max_tokens > 0,
    do: Map.put(body, "max_tokens", max_tokens)

  defp put_max_tokens(body, _max_tokens), do: body
end
