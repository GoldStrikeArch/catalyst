defmodule CatalystWeb.UI.MessageRenderer do
  @moduledoc """
  Renders a conversation message (or content block) for the chat UI. A registered
  renderer (`CatalystWeb.UI.Registry`) whose match function matches wins; otherwise
  the built-in rendering below is used. This is the seam that lets an extension add
  a custom card for a particular tool result or message type at runtime.
  """
  use CatalystWeb, :html
  require Logger

  alias Catalyst.{Content, Message}
  alias CatalystWeb.UI.{Markdown, Registry}

  @doc "Render a message: a registered `:message` renderer if one matches, else built-in."
  @spec render_message(map()) :: Phoenix.LiveView.Rendered.t() | Phoenix.HTML.safe()
  def render_message(assigns) do
    case Registry.renderer(:message, assigns.msg) do
      nil -> message(assigns)
      fun -> safe_render(fun, assigns, &message/1)
    end
  end

  @doc "Render a content block: a registered `:block` renderer if one matches, else built-in."
  @spec render_block(map()) :: Phoenix.LiveView.Rendered.t() | Phoenix.HTML.safe()
  def render_block(assigns) do
    case Registry.renderer(:block, assigns.block) do
      nil -> block(assigns)
      fun -> safe_render(fun, assigns, &block/1)
    end
  end

  @doc """
  Render one parsed Markdown block (`CatalystWeb.UI.Markdown.block/0`).

  Used by the streaming block-commit path (`ShellLive`) so blocks committed
  MID-stream render through exactly the same pipeline as the finished message —
  the `message_end` swap is then pixel-identical.
  """
  @spec markdown_block(map()) :: Phoenix.LiveView.Rendered.t()
  def markdown_block(assigns), do: formatted_block(assigns)

  # A broken extension renderer must not crash-loop the LiveView on every
  # render of the transcript (recovery — asking the agent to reload_extensions
  # — needs the chat UI it would take down). Every fun reaching here is
  # extension-registered (the built-in clauses below never pass through), and
  # calling a ~H fun only BUILDS a lazy %Phoenix.LiveView.Rendered{} whose
  # dynamics would otherwise run later in the diff engine, outside this rescue
  # — so the template is forced to iodata INSIDE the guard. raise/throw/exit
  # (e.g. a bad assign or a GenServer call in the template) all fall back to
  # built-in rendering, which stays on the normal lazy/diffable path.
  defp safe_render(fun, assigns, fallback) do
    {:safe, Phoenix.HTML.Safe.to_iodata(fun.(assigns))}
  rescue
    e ->
      Logger.warning("[ui] extension renderer raised: #{Exception.message(e)} — using built-in")
      fallback.(assigns)
  catch
    kind, reason ->
      Logger.warning("[ui] extension renderer #{kind}: #{inspect(reason)} — using built-in")
      fallback.(assigns)
  end

  # ---- built-in message rendering -------------------------------------------

  defp message(%{msg: %Message.User{}} = assigns) do
    ~H"""
    <div data-message-role="user" class="flex justify-end">
      <div class="max-w-[82%] rounded-3xl rounded-br-md bg-slate-950 px-4 py-3 text-sm leading-6 text-white shadow-lg shadow-slate-900/15 dark:bg-indigo-500 dark:shadow-indigo-950/20">
        <img
          :for={img <- user_images(@msg.content)}
          src={"data:#{img.mime_type};base64,#{img.data}"}
          alt="attached image"
          class="mb-2 max-h-64 max-w-full rounded-xl"
        />
        <span :if={Content.text_of(@msg.content) != ""}>{Content.text_of(@msg.content)}</span>
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

  defp block(%{block: %Content.Text{text: text}} = assigns) do
    assigns = Map.put(assigns, :blocks, Markdown.parse(text))

    ~H"""
    <div
      data-block-kind="text"
      class="space-y-2 text-sm leading-6 text-slate-700 dark:text-slate-100"
    >
      <%= for block <- @blocks do %>
        <.formatted_block block={block} />
      <% end %>
    </div>
    """
  end

  defp block(%{block: %Content.Thinking{}} = assigns) do
    ~H"""
    <details
      data-block-kind="thinking"
      class="my-1 rounded-xl border border-slate-200/70 bg-slate-50/80 px-3 py-2 text-xs italic text-slate-500 dark:border-white/10 dark:bg-white/5 dark:text-slate-400"
    >
      <summary class="cursor-pointer font-medium not-italic text-slate-500 dark:text-slate-300">
        thinking
      </summary>
      <div class="mt-2 whitespace-pre-wrap">{@block.thinking}</div>
    </details>
    """
  end

  defp block(%{block: %Content.ToolCall{}} = assigns) do
    ~H"""
    <div
      data-block-kind="tool-call"
      class="my-1 inline-flex items-center gap-2 rounded-full border border-indigo-200 bg-indigo-50 px-2.5 py-1 text-xs text-indigo-700 dark:border-indigo-400/20 dark:bg-indigo-400/10 dark:text-indigo-200"
    >
      <span class="rounded-full bg-indigo-600 px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide text-white dark:bg-indigo-400 dark:text-indigo-950">
        tool
      </span>
      <code>{@block.name}({short_args(@block.arguments)})</code>
    </div>
    """
  end

  defp block(assigns), do: ~H""

  # ---- formatted text rendering ---------------------------------------------

  defp formatted_block(%{block: {:paragraph, inlines}} = assigns) do
    assigns = Map.put(assigns, :inlines, inlines)

    ~H"""
    <p class="my-2 first:mt-0 last:mb-0">
      <.formatted_inlines inlines={@inlines} />
    </p>
    """
  end

  defp formatted_block(%{block: {:heading, level, inlines}} = assigns) do
    assigns =
      assigns
      |> Map.put(:level, level)
      |> Map.put(:inlines, inlines)

    ~H"""
    <p class={["mt-4 first:mt-0 font-semibold text-slate-950 dark:text-white", heading_class(@level)]}>
      <.formatted_inlines inlines={@inlines} />
    </p>
    """
  end

  defp formatted_block(%{block: {:ul, items}} = assigns) do
    assigns = Map.put(assigns, :items, items)

    ~H"""
    <ul class="my-2 ml-5 list-disc space-y-1 marker:text-slate-400 dark:marker:text-slate-500">
      <li :for={item <- @items}>
        <.formatted_inlines inlines={item} />
      </li>
    </ul>
    """
  end

  defp formatted_block(%{block: {:ol, items}} = assigns) do
    assigns = Map.put(assigns, :items, items)

    ~H"""
    <ol class="my-2 ml-5 list-decimal space-y-1 marker:text-slate-400 dark:marker:text-slate-500">
      <li :for={item <- @items}>
        <.formatted_inlines inlines={item} />
      </li>
    </ol>
    """
  end

  defp formatted_block(%{block: {:blockquote, blocks}} = assigns) do
    assigns = Map.put(assigns, :blocks, blocks)

    ~H"""
    <blockquote class="my-3 border-l-2 border-indigo-300 pl-3 text-slate-600 dark:border-indigo-400/60 dark:text-slate-300">
      <%= for block <- @blocks do %>
        <.formatted_block block={block} />
      <% end %>
    </blockquote>
    """
  end

  defp formatted_block(%{block: {:code, lang, code}} = assigns) do
    assigns =
      assigns
      |> Map.put(:lang, lang)
      |> Map.put(:code, code)

    ~H"""
    <div class="my-3 overflow-hidden rounded-2xl border border-slate-200 bg-slate-950 text-slate-100 shadow-sm dark:border-white/10 dark:bg-black/40">
      <div
        :if={@lang}
        class="border-b border-white/10 px-3 py-1 text-[0.65rem] font-semibold uppercase tracking-wide text-slate-400"
      >
        {@lang}
      </div>
      <pre class="overflow-x-auto px-3 py-2 text-xs leading-5"><code data-lang={@lang}>{@code}</code></pre>
    </div>
    """
  end

  defp formatted_block(%{block: :hr} = assigns) do
    ~H"""
    <hr class="my-4 border-slate-200 dark:border-white/10" />
    """
  end

  defp formatted_inlines(assigns) do
    ~H"""
    <%= for inline <- @inlines do %>
      <.formatted_inline inline={inline} />
    <% end %>
    """
  end

  defp formatted_inline(%{inline: {:text, text}} = assigns) do
    assigns = Map.put(assigns, :text, text)

    ~H"""
    {@text}
    """
  end

  defp formatted_inline(%{inline: {:code, code}} = assigns) do
    assigns = Map.put(assigns, :code, code)

    ~H"""
    <code class="rounded-md bg-slate-100 px-1 py-0.5 font-mono text-[0.85em] text-slate-900 dark:bg-white/10 dark:text-slate-100">
      {@code}
    </code>
    """
  end

  defp formatted_inline(%{inline: {:strong, inlines}} = assigns) do
    assigns = Map.put(assigns, :inlines, inlines)

    ~H"""
    <strong class="font-semibold text-slate-950 dark:text-white">
      <.formatted_inlines inlines={@inlines} />
    </strong>
    """
  end

  defp formatted_inline(%{inline: {:link, inlines, href}} = assigns) do
    assigns =
      assigns
      |> Map.put(:inlines, inlines)
      |> Map.put(:href, href)
      |> Map.put(:safe_href?, Markdown.safe_href?(href))

    ~H"""
    <a
      :if={@safe_href?}
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="font-medium text-indigo-600 underline decoration-indigo-300 underline-offset-2 transition hover:text-indigo-500 hover:decoration-indigo-500 dark:text-indigo-300 dark:decoration-indigo-400/50 dark:hover:text-indigo-200"
    >
      <.formatted_inlines inlines={@inlines} />
    </a>
    <span :if={!@safe_href?}>
      <.formatted_inlines inlines={@inlines} />
    </span>
    """
  end

  defp heading_class(level) when level <= 1, do: "text-lg leading-7"
  defp heading_class(2), do: "text-base leading-7"
  defp heading_class(_level), do: "text-sm leading-6"

  # ---- helpers --------------------------------------------------------------

  # The transcript shows a preview of tool output, not the full result.
  @tool_output_preview_lines 40

  defp tool_output(%Message.ToolResult{content: content}) do
    lines = content |> Content.text_of() |> String.split("\n")
    preview = lines |> Enum.take(@tool_output_preview_lines) |> Enum.join("\n")

    case length(lines) - @tool_output_preview_lines do
      hidden when hidden > 0 -> preview <> "\n… (#{hidden} more lines)"
      _ -> preview
    end
  end

  defp short_args(args) when is_map(args) and map_size(args) == 0, do: ""
  defp short_args(args) when is_map(args), do: args |> Jason.encode!() |> String.slice(0, 80)
  defp short_args(_), do: ""

  defp user_images(content) when is_list(content),
    do: Enum.filter(content, &match?(%Content.Image{}, &1))

  defp user_images(_), do: []
end
