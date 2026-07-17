defmodule CatalystWeb.UI.MessageRenderer do
  @moduledoc """
  Renders a conversation message (or content block) for the chat UI. A registered
  renderer (`CatalystWeb.UI.Registry`) whose match function matches wins; otherwise
  the built-in rendering below is used. This is the seam that lets an extension add
  a custom card for a particular tool result or message type at runtime.
  """
  use CatalystWeb, :html

  alias Catalyst.{Content, Message}
  alias CatalystWeb.UI.Registry

  @doc "Render a message: a registered `:message` renderer if one matches, else built-in."
  def render_message(assigns) do
    case Registry.renderer(:message, assigns.msg) do
      nil -> message(assigns)
      fun -> fun.(assigns)
    end
  end

  @doc "Render a content block: a registered `:block` renderer if one matches, else built-in."
  def render_block(assigns) do
    case Registry.renderer(:block, assigns.block) do
      nil -> block(assigns)
      fun -> fun.(assigns)
    end
  end

  # ---- built-in message rendering -------------------------------------------

  defp message(%{msg: %Message.User{}} = assigns) do
    ~H"""
    <div class="chat chat-end">
      <div class="chat-bubble chat-bubble-primary whitespace-pre-wrap">{Content.text_of(@msg.content)}</div>
    </div>
    """
  end

  defp message(%{msg: %Message.Assistant{}} = assigns) do
    ~H"""
    <div :if={@msg.content != []} class="chat chat-start">
      <div class="chat-bubble chat-bubble-neutral whitespace-pre-wrap">
        <%= for b <- @msg.content do %>{render_block(%{block: b})}<% end %>
      </div>
    </div>
    """
  end

  defp message(%{msg: %Message.ToolResult{}} = assigns) do
    ~H"""
    <div class="px-2">
      <div class={[
        "rounded-lg border text-xs font-mono overflow-hidden",
        @msg.is_error && "border-error/50 bg-error/10",
        !@msg.is_error && "border-base-300 bg-base-100"
      ]}>
        <div class="px-3 py-1 border-b border-base-300/50 font-semibold flex items-center gap-2">
          <span>{@msg.tool_name}</span>
          <span :if={@msg.is_error} class="badge badge-error badge-xs">error</span>
        </div>
        <pre class="px-3 py-2 whitespace-pre-wrap max-h-60 overflow-y-auto">{tool_output(@msg)}</pre>
      </div>
    </div>
    """
  end

  defp message(assigns), do: ~H""

  # ---- built-in block rendering ---------------------------------------------

  defp block(%{block: %Content.Text{}} = assigns), do: ~H"{@block.text}"

  defp block(%{block: %Content.Thinking{}} = assigns) do
    ~H"""
    <details class="text-xs italic opacity-60 my-1">
      <summary class="cursor-pointer">thinking</summary>
      <div class="whitespace-pre-wrap mt-1">{@block.thinking}</div>
    </details>
    """
  end

  defp block(%{block: %Content.ToolCall{}} = assigns) do
    ~H"""
    <div class="text-xs opacity-70 my-1">
      <span class="badge badge-xs badge-ghost">tool</span>
      <code>{@block.name}({short_args(@block.arguments)})</code>
    </div>
    """
  end

  defp block(assigns), do: ~H""

  # ---- helpers --------------------------------------------------------------

  defp tool_output(%Message.ToolResult{content: content}) do
    content |> Content.text_of() |> String.split("\n") |> Enum.take(40) |> Enum.join("\n")
  end

  defp short_args(args) when is_map(args) and map_size(args) == 0, do: ""
  defp short_args(args) when is_map(args), do: args |> Jason.encode!() |> String.slice(0, 80)
  defp short_args(_), do: ""
end
