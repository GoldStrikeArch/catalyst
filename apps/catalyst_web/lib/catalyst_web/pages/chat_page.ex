defmodule CatalystWeb.Pages.ChatPage do
  @moduledoc """
  The default page: the conversation view and the inline draft. Run controls
  stay in `CatalystWeb.ShellComponents`. Registered as the `"chat"` page in
  `CatalystWeb.UI.Registry` and driven by `ShellLive` assigns. Reloading this
  module hot-swaps the transcript UI.
  """
  use CatalystWeb, :html

  alias CatalystWeb.ShellComponents
  alias CatalystWeb.UI.MessageRenderer

  def render(assigns) do
    ~H"""
    <div class="relative flex min-h-0 flex-1 flex-col">
      <main
        id="messages"
        phx-hook="ScrollBottom"
        data-quiet={@ui_prefs.quiet}
        class="flex-1 overflow-y-auto px-4 py-6 sm:px-6"
      >
        <div class="flex max-w-3xl flex-col gap-3">
          <p
            :if={@message_count == 0 and is_nil(@streaming) and @queued == []}
            id="chat-empty-state"
            class="truncate text-xs text-neutral-400 dark:text-neutral-500"
          >
            Ask Catalyst to inspect this project. <span class="font-mono">{@cwd}</span>
          </p>

          <div id="message-stream" phx-update="stream" class="flex flex-col gap-3">
            <div :for={{dom_id, %{msg: msg}} <- @streams.messages} id={dom_id} phx-hook="Highlight">
              {MessageRenderer.render_message(%{msg: msg})}
            </div>
          </div>

          <%!-- The live streaming bubble:
          1. thinking — client-appended raw text (phx-update="ignore");
          2. committed markdown blocks — a LiveView stream;
          3. preview — parse(complete tail lines) through MessageRenderer so
             the still-open list/paragraph is already markdown;
          4. raw tail — only the unfinished last line, client-appended.
        MessageEnd swaps to the finished message; committed + preview use
        the same renderer, so the swap is a visual no-op. --%>
          <div
            :if={@streaming}
            id="streaming-message"
            phx-hook="StreamingMessage"
            data-message-role="assistant-streaming"
            data-turn="assistant"
            class="flex justify-start"
          >
            <div class="w-full min-w-0 px-1 py-1 text-neutral-800 dark:text-neutral-200">
              <%!-- phx-no-format: whitespace-pre-wrap + empty:hidden — formatter
                whitespace inside would render as a blank line and defeat :empty. --%>
              <div
                id="stream-thinking"
                phx-update="ignore"
                data-stream="thinking"
                class="whitespace-pre-wrap text-xs italic text-neutral-400 empty:hidden dark:text-neutral-500"
                phx-no-format
              >{@streaming.thinking}</div>
              <div id="stream-blocks" phx-update="stream" class="text-sm leading-6">
                <div
                  :for={{dom_id, %{block: block}} <- @streams.stream_blocks}
                  id={dom_id}
                  phx-hook="Highlight"
                >
                  {MessageRenderer.markdown_block(%{block: block})}
                </div>
              </div>
              <div id="stream-preview" phx-hook="Highlight" class="text-sm leading-6">
                <div :for={{block, index} <- Enum.with_index(@streaming.preview)} id={"sp-#{index}"}>
                  {MessageRenderer.markdown_block(%{block: block})}
                </div>
              </div>
              <%!-- phx-no-format: same pre-wrap whitespace hazard as above. --%>
              <div
                id="stream-tail"
                phx-update="ignore"
                data-stream="text"
                class="whitespace-pre-wrap text-sm"
                phx-no-format
              >{@streaming.tail}</div>
              <div
                id="stream-dots"
                phx-update="ignore"
                data-stream-dots
                class="inline-flex items-center gap-1.5 text-neutral-500 dark:text-neutral-400"
              >
                <span class="sr-only">Assistant is working</span>
                <span class="size-1.5 animate-bounce rounded-full bg-neutral-400 [animation-delay:-0.2s] dark:bg-neutral-500">
                </span>
                <span class="size-1.5 animate-bounce rounded-full bg-neutral-400 [animation-delay:-0.1s] dark:bg-neutral-500">
                </span>
                <span class="size-1.5 animate-bounce rounded-full bg-neutral-400 dark:bg-neutral-500">
                </span>
              </div>
            </div>
          </div>

          <div
            :for={{call_id, t} <- @tools}
            id={"tool-indicator-#{call_id}"}
            class="flex flex-col items-start gap-1"
          >
            <div class="inline-flex items-center gap-2 rounded-full border border-neutral-200 bg-white px-3 py-1.5 text-xs font-medium text-neutral-600 dark:border-white/10 dark:bg-white/5 dark:text-neutral-300">
              <span class="size-3 animate-spin rounded-full border-2 border-neutral-200 border-t-neutral-600 dark:border-white/15 dark:border-t-white">
              </span>
              running <code class="font-mono">{t.name}</code>…
            </div>
            <%!-- Live output tail streamed by the tool (bash) via ToolExecutionUpdate. --%>
            <pre
              :if={t[:partial]}
              data-tool-partial
              class="max-w-[85%] overflow-x-auto whitespace-pre-wrap rounded-lg bg-neutral-100 px-2.5 py-1.5 font-mono text-[0.65rem] leading-relaxed text-neutral-500 dark:bg-white/5 dark:text-neutral-400"
            >{t[:partial]}</pre>
          </div>

          <div
            :for={{text, index} <- Enum.with_index(@queued)}
            id={"queued-#{index}"}
            class="text-sm leading-6 text-neutral-400 dark:text-neutral-500"
          >
            <span class="mr-2 text-[10px] font-medium uppercase tracking-wide">Queued</span>
            {text}
          </div>

          <ShellComponents.file_search_popover file_search={@file_search} />
          <ShellComponents.composer {assigns} />
        </div>
      </main>

      <%!-- Scrollbar tick rail: one mark per user/assistant turn. Hover the
        gutter for a first-line preview; click jumps. Alt/⌥+wheel steps.
        Hook lives here so #messages can keep ScrollBottom (one hook / el). --%>
      <div
        id="turn-jump-track"
        phx-hook="JumpByTurn"
        phx-update="ignore"
        class="pointer-events-none absolute inset-y-0 right-0 z-20 w-4"
      >
        <div id="turn-jump-ticks" class="absolute inset-0"></div>
        <div
          id="turn-jump-card"
          hidden
          class="pointer-events-none absolute right-full mr-2 w-max max-w-xs rounded-lg border border-neutral-200 bg-white px-2.5 py-1.5 text-xs shadow-lg dark:border-white/10 dark:bg-neutral-900 dark:text-neutral-100"
        >
          <div
            data-turn-role
            class="text-[10px] font-medium uppercase tracking-wide text-neutral-400 dark:text-neutral-500"
          >
          </div>
          <div data-turn-preview class="truncate"></div>
        </div>
      </div>

      <%!-- Floating return-to-bottom pill. Visibility is toggled client-side
        by the ScrollBottom hook (classList, no server round-trips); the
        wrapper is phx-update="ignore" so LiveView patches never clobber the
        toggled classes on the button (ignored elements' children are left
        alone; the element's own attributes are not). --%>
      <div
        id="jump-to-bottom-wrap"
        phx-update="ignore"
        class="pointer-events-none absolute inset-x-0 bottom-4 z-10 flex justify-center"
      >
        <button
          id="jump-to-bottom"
          type="button"
          class="pointer-events-auto hidden items-center gap-1.5 rounded-full bg-neutral-900 px-3.5 py-2 text-xs font-semibold text-white shadow-lg shadow-neutral-950/20 transition hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:shadow-black/40 dark:hover:bg-neutral-200"
        >
          <.icon name="hero-arrow-down" class="size-3.5" /> Jump to latest
        </button>
      </div>
    </div>
    """
  end
end
