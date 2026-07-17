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
  @spec render_message(map()) :: Phoenix.LiveView.Rendered.t()
  def render_message(assigns) do
    case Registry.renderer(:message, assigns.msg) do
      nil -> message(assigns)
      fun -> fun.(assigns)
    end
  end

  @doc "Render a content block: a registered `:block` renderer if one matches, else built-in."
  @spec render_block(map()) :: Phoenix.LiveView.Rendered.t()
  def render_block(assigns) do
    case Registry.renderer(:block, assigns.block) do
      nil -> block(assigns)
      fun -> fun.(assigns)
    end
  end

  # ---- built-in message rendering -------------------------------------------

  defp message(%{msg: %Message.User{}} = assigns) do
    ~H"""
    <div data-message-role="user" class="flex justify-end">
      <div class="max-w-[82%] rounded-3xl rounded-br-md bg-slate-950 px-4 py-3 text-sm leading-6 text-white shadow-lg shadow-slate-900/15 dark:bg-indigo-500 dark:shadow-indigo-950/20">
        {Content.text_of(@msg.content)}
      </div>
    </div>
    """
  end

  defp message(%{msg: %Message.Assistant{}} = assigns) do
    ~H"""
    <div :if={@msg.content != []} data-message-role="assistant" class="flex justify-start">
      <div class="max-w-[82%] rounded-3xl rounded-bl-md border border-slate-200 bg-white/85 px-4 py-3 text-sm leading-6 text-slate-700 shadow-sm shadow-slate-200/50 backdrop-blur dark:border-white/10 dark:bg-white/10 dark:text-slate-100 dark:shadow-black/20">
        <%= for b <- @msg.content do %>
          {render_block(%{block: b})}
        <% end %>
      </div>
    </div>
    """
  end

  defp message(%{msg: %Message.ToolResult{}} = assigns) do
    ~H"""
    <div data-message-role="tool-result" data-tool-error={to_string(@msg.is_error)} class="px-2">
      <div class={[
        "overflow-hidden rounded-2xl border text-xs font-mono shadow-sm backdrop-blur",
        @msg.is_error &&
          "border-rose-200 bg-rose-50/90 text-rose-950 dark:border-rose-400/20 dark:bg-rose-500/10 dark:text-rose-100",
        !@msg.is_error &&
          "border-slate-200 bg-white/80 text-slate-700 dark:border-white/10 dark:bg-white/10 dark:text-slate-200"
      ]}>
        <div class="flex items-center gap-2 border-b border-current/10 px-3 py-1.5 font-semibold">
          <span>{@msg.tool_name}</span>
          <span
            :if={@msg.is_error}
            class="rounded-full bg-rose-600 px-1.5 py-0.5 text-[0.65rem] uppercase tracking-wide text-white"
          >
            error
          </span>
        </div>
        <pre class="max-h-60 overflow-y-auto whitespace-pre-wrap px-3 py-2">{tool_output(@msg)}</pre>
      </div>
    </div>
    """
  end

  defp message(assigns), do: ~H""

  # ---- built-in block rendering ---------------------------------------------

  defp block(%{block: %Content.Text{}} = assigns), do: ~H"{@block.text}"

  defp block(%{block: %Content.Thinking{}} = assigns) do
    ~H"""
    <details class="my-1 rounded-xl border border-slate-200/70 bg-slate-50/80 px-3 py-2 text-xs italic text-slate-500 dark:border-white/10 dark:bg-white/5 dark:text-slate-400">
      <summary class="cursor-pointer font-medium not-italic text-slate-500 dark:text-slate-300">
        thinking
      </summary>
      <div class="mt-2 whitespace-pre-wrap">{@block.thinking}</div>
    </details>
    """
  end

  defp block(%{block: %Content.ToolCall{}} = assigns) do
    ~H"""
    <div class="my-1 inline-flex items-center gap-2 rounded-full border border-indigo-200 bg-indigo-50 px-2.5 py-1 text-xs text-indigo-700 dark:border-indigo-400/20 dark:bg-indigo-400/10 dark:text-indigo-200">
      <span class="rounded-full bg-indigo-600 px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide text-white dark:bg-indigo-400 dark:text-indigo-950">
        tool
      </span>
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
