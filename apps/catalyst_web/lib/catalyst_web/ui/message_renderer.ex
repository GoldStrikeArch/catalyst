defmodule CatalystWeb.UI.MessageRenderer do
  @moduledoc """
  Renders a conversation message (or content block) for the chat UI. A registered
  renderer (`CatalystWeb.UI.Registry`) whose match function matches wins; otherwise
  the built-in rendering below is used. This is the seam that lets an extension add
  a custom card for a particular tool result or message type at runtime.
  """
  use CatalystWeb, :html

  alias Catalyst.{Content, Message}
  alias CatalystWeb.UI.{ImageStore, Markdown, Registry, SafeRender, ToolSummary}

  @doc "Render a message: a registered `:message` renderer if one matches, else built-in."
  @spec render_message(map()) :: Phoenix.LiveView.Rendered.t() | Phoenix.HTML.safe()
  def render_message(assigns) do
    case Registry.renderer(:message, assigns.msg) do
      :error -> message(assigns)
      {:ok, fun} -> safe_render(fun, assigns, &message/1)
    end
  end

  @doc "Render a content block: a registered `:block` renderer if one matches, else built-in."
  @spec render_block(map()) :: Phoenix.LiveView.Rendered.t() | Phoenix.HTML.safe()
  def render_block(assigns) do
    case Registry.renderer(:block, assigns.block) do
      :error -> block(assigns)
      {:ok, fun} -> safe_render(fun, assigns, &block/1)
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
  # extension-registered (the built-in clauses below never pass through);
  # SafeRender forces the template to iodata inside the guard and any
  # raise/throw/exit falls back to built-in rendering.
  defp safe_render(fun, assigns, fallback) do
    SafeRender.forced_iodata(
      fn -> fun.(assigns) end,
      "extension renderer",
      fn -> fallback.(assigns) end
    )
  end

  # ---- built-in message rendering -------------------------------------------

  defp message(%{msg: %Message.User{}} = assigns) do
    ~H"""
    <div data-message-role="user" data-turn="user" class="flex items-start gap-3">
      <span
        data-user-mark
        class="mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full bg-raised text-muted"
      >
        <.icon name="hero-user" class="size-3.5" />
      </span>
      <div class="min-w-0 text-sm leading-7 text-ink">
        <img
          :for={img <- user_images(@msg.content)}
          src={image_src(img)}
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
    <div
      :if={@msg.content != []}
      data-message-role="assistant"
      data-turn="assistant"
      class="flex justify-start"
    >
      <div class="w-full min-w-0 px-1 py-1 text-sm leading-7 text-ink">
        <%= for b <- @msg.content do %>
          {render_block(%{block: b})}
        <% end %>
      </div>
    </div>
    """
  end

  defp message(%{msg: %Message.ToolResult{}} = assigns) do
    output = tool_output(assigns.msg)

    assigns =
      assigns
      |> Map.put(:output, output)
      |> Map.put(:lines, line_label(output))

    ~H"""
    <div data-message-role="tool-result" data-tool-error={to_string(@msg.is_error)} class="px-2">
      <%!-- Collapsed by default so a long transcript stays scannable; a failed
        call opens itself, because the output is the reason it failed. --%>
      <details open={@msg.is_error} class="group my-0.5">
        <summary class={[
          "flex cursor-pointer list-none items-center gap-1.5 text-xs",
          "[&::-webkit-details-marker]:hidden",
          @msg.is_error && "text-danger",
          !@msg.is_error && "text-faint hover:text-muted"
        ]}>
          <.icon
            name="hero-chevron-right-micro"
            class="size-3 shrink-0 transition-transform group-open:rotate-90"
          />
          <span class="font-medium">{@msg.tool_name}</span>
          <span :if={@msg.is_error} class="font-medium">error</span>
          <span class="truncate">· {@lines}</span>
        </summary>
        <div
          :if={user_images(@msg.content) != []}
          data-block-kind="tool-image"
          class="mt-1"
        >
          <img
            :for={img <- user_images(@msg.content)}
            src={image_src(img)}
            alt="tool result image"
            class="mb-2 max-h-64 max-w-full rounded-xl last:mb-0"
          />
        </div>
        <pre class="mt-1 max-h-60 overflow-y-auto whitespace-pre-wrap rounded-md bg-raised px-2.5 py-1.5 font-mono text-[0.7rem] leading-relaxed text-muted">{@output}</pre>
      </details>
    </div>
    """
  end

  defp message(assigns), do: ~H""

  # ---- built-in block rendering ---------------------------------------------

  defp block(%{block: %Content.Text{text: text}} = assigns) do
    assigns = Map.put(assigns, :blocks, Markdown.parse(text))

    ~H"""
    <div data-block-kind="text" class="space-y-2 text-sm leading-7 text-ink">
      <%= for block <- @blocks do %>
        <.formatted_block block={block} />
      <% end %>
    </div>
    """
  end

  defp block(%{block: %Content.Thinking{}} = assigns) do
    ~H"""
    <details data-block-kind="thinking" class="group my-1">
      <summary class="flex cursor-pointer list-none items-center gap-1.5 text-xs text-faint hover:text-muted [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 shrink-0 transition-transform group-open:rotate-90"
        /> Thinking
      </summary>
      <div class="mt-1 whitespace-pre-wrap border-l border-edge pl-3 text-xs leading-5 text-faint">
        {@block.thinking}
      </div>
    </details>
    """
  end

  defp block(%{block: %Content.ToolCall{}} = assigns) do
    {label, detail} = ToolSummary.summarize(assigns.block.name, assigns.block.arguments)

    assigns =
      assigns
      |> Map.put(:label, label)
      |> Map.put(:detail, detail)

    ~H"""
    <details data-block-kind="tool-call" class="group my-0.5">
      <summary class="flex cursor-pointer list-none items-baseline gap-1.5 text-xs text-muted hover:text-ink [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 shrink-0 self-center transition-transform group-open:rotate-90"
        />
        <span class="font-medium text-xs text-muted">{@label}</span>
        <span class="min-w-0 truncate font-mono text-faint">{@detail}</span>
      </summary>
      <pre class="mt-1 max-h-60 overflow-auto whitespace-pre-wrap rounded-md bg-raised px-2.5 py-1.5 font-mono text-[0.7rem] leading-relaxed text-muted">{pretty_args(@block.arguments)}</pre>
    </details>
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
    <p class={["mt-4 first:mt-0 font-semibold text-ink", heading_class(@level)]}>
      <.formatted_inlines inlines={@inlines} />
    </p>
    """
  end

  defp formatted_block(%{block: {:ul, items}} = assigns) do
    assigns = Map.put(assigns, :items, items)

    ~H"""
    <ul class="my-2 ml-5 list-disc space-y-1 marker:text-faint">
      <li :for={item <- @items}>
        <.formatted_inlines inlines={item} />
      </li>
    </ul>
    """
  end

  defp formatted_block(%{block: {:ol, items}} = assigns) do
    assigns = Map.put(assigns, :items, items)

    ~H"""
    <ol class="my-2 ml-5 list-decimal space-y-1 marker:text-faint">
      <li :for={item <- @items}>
        <.formatted_inlines inlines={item} />
      </li>
    </ol>
    """
  end

  defp formatted_block(%{block: {:blockquote, blocks}} = assigns) do
    assigns = Map.put(assigns, :blocks, blocks)

    ~H"""
    <blockquote class="my-3 border-l-2 border-edge-strong pl-3 text-muted">
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
    <%!-- The fence keeps its dark shell in both themes on purpose: the hljs
      theme loaded in app.css is a dark one (documented invariant). --%>
    <div class="my-3 overflow-hidden rounded-xl border border-edge bg-neutral-950 text-neutral-100">
      <div
        :if={@lang}
        class="border-b border-white/10 px-3 py-1 text-[0.65rem] font-semibold uppercase tracking-wide text-neutral-400"
      >
        {@lang}
      </div>
      <pre class="overflow-x-auto px-3 py-2 text-xs leading-5"><code data-lang={@lang}>{@code}</code></pre>
    </div>
    """
  end

  defp formatted_block(%{block: :hr} = assigns) do
    ~H"""
    <hr class="my-4 border-edge" />
    """
  end

  defp formatted_inlines(assigns) do
    ~H"""
    <%= for inline <- @inlines do %>
      <.formatted_inline inline={inline} />
    <% end %>
    """
  end

  defp formatted_inline(%{inline: {:br}} = assigns) do
    ~H"""
    <br />
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
    <code class="rounded-md bg-raised px-1 py-0.5 font-mono text-[0.85em] text-ink">
      {@code}
    </code>
    """
  end

  defp formatted_inline(%{inline: {:strong, inlines}} = assigns) do
    assigns = Map.put(assigns, :inlines, inlines)

    ~H"""
    <strong class="font-semibold text-ink">
      <.formatted_inlines inlines={@inlines} />
    </strong>
    """
  end

  defp formatted_inline(%{inline: {:em, inlines}} = assigns) do
    assigns = Map.put(assigns, :inlines, inlines)

    ~H"""
    <em class="italic">
      <.formatted_inlines inlines={@inlines} />
    </em>
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
      class="font-medium text-accent underline decoration-accent/40 underline-offset-2 transition hover:decoration-accent"
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

  defp line_label(output) do
    case output |> String.split("\n") |> length() do
      1 -> "1 line"
      n -> "#{n} lines"
    end
  end

  defp pretty_args(args) when is_map(args) and map_size(args) == 0, do: "{}"
  defp pretty_args(args) when is_map(args), do: Jason.encode!(args, pretty: true)

  defp user_images(content) when is_list(content),
    do: Enum.filter(content, &match?(%Content.Image{}, &1))

  defp user_images(_), do: []

  # Images render as digest-addressed references served by
  # CatalystWeb.ImageController, never as inline data URIs: a reconnect
  # re-streams the whole transcript, and inlining made screenshot-heavy
  # sessions unreconnectable (100+ MB of HTML for 100 captures). A failed
  # registration (invalid base64, non-raster MIME, oversized) yields a
  # src-less <img> that shows its alt text, and an entry later evicted from
  # the bounded store 404s into the same degraded state — never a crash.
  defp image_src(%Content.Image{data: data, mime_type: mime_type}) do
    case ImageStore.register(data, mime_type) do
      {:ok, digest} -> ~p"/image/#{digest}"
      :error -> nil
    end
  end
end
