defmodule CatalystWeb.Pages.ChatPage do
  @moduledoc """
  The default page: the conversation view + input. It is a plain render function
  (registered as the `"chat"` page in `CatalystWeb.UI.Registry`) driven by the
  `ShellLive` assigns; all events/PubSub are handled by `ShellLive`. Reloading
  this module hot-swaps the chat UI with no restart.
  """
  use CatalystWeb, :html

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
        <div class="mx-auto flex max-w-5xl flex-col gap-3">
          <div
            :if={@message_count == 0 and is_nil(@streaming)}
            id="chat-empty-state"
            class="mx-auto mt-32 flex w-full max-w-md flex-col items-center px-4 text-center"
          >
            <div class="mb-4 flex size-11 items-center justify-center rounded-2xl bg-neutral-900 text-white dark:bg-white dark:text-neutral-900">
              <.icon name="hero-sparkles" class="size-5" />
            </div>
            <p class="text-sm font-medium text-neutral-900 dark:text-white">
              Ask Catalyst to inspect this project.
            </p>
            <p class="mt-1.5 max-w-full truncate font-mono text-xs text-neutral-400 dark:text-neutral-500">
              {@cwd}
            </p>
          </div>

          <div id="message-stream" phx-update="stream" class="flex flex-col gap-3">
            <div :for={{dom_id, %{msg: msg}} <- @streams.messages} id={dom_id} phx-hook="Highlight">
              {MessageRenderer.render_message(%{msg: msg})}
            </div>
          </div>

          <%!-- The live streaming bubble, in three regions:
          1. thinking — client-appended raw text (phx-update="ignore");
          2. committed markdown blocks — a LiveView stream; each stabilized
             block renders ONCE through the real MessageRenderer (headings,
             lists, highlighted code) as it completes;
          3. the raw tail — the still-open last block, client-appended;
             trimmed via the "stream_tail" event whenever blocks commit.
        `@streaming` seeds the ignored regions on first paint (late joiners);
        the completed message replaces all of it at MessageEnd, rendering the
        same blocks through the same pipeline — a visual no-op. --%>
          <div
            :if={@streaming}
            id="streaming-message"
            phx-hook="StreamingMessage"
            data-message-role="assistant-streaming"
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

          <div :for={{_id, t} <- @tools} class="flex flex-col items-start gap-1">
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
        </div>
      </main>

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

    <div
      :if={@file_search}
      id="file-search-results"
      class="border-t border-neutral-200 bg-neutral-50 px-4 py-2 dark:border-white/10 dark:bg-neutral-900"
    >
      <div class="mx-auto max-w-5xl">
        <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
          <%= if @file_search.results == [] do %>
            no files match “@{@file_search.query}”
          <% else %>
            files matching “@{@file_search.query}” — Enter picks the first
          <% end %>
        </p>
        <div class="mt-1 flex flex-col">
          <button
            :for={r <- @file_search.results}
            type="button"
            phx-click="pick_file"
            phx-value-label={r.label}
            phx-value-path={r.path}
            class="flex items-baseline gap-3 rounded-lg px-2 py-1 text-left text-xs transition hover:bg-neutral-200/50 dark:hover:bg-white/10"
          >
            <code class="shrink-0 font-mono font-semibold text-neutral-900 dark:text-neutral-100">
              {r.label}
            </code>
            <span class="truncate font-mono text-neutral-400 dark:text-neutral-500">{r.path}</span>
          </button>
        </div>
      </div>
    </div>

    <.form
      for={@chat_form}
      id="chat-form"
      phx-submit="send"
      phx-change="typing"
      phx-hook="PasteImages"
      class="border-t border-neutral-200 bg-neutral-50 px-4 py-3 dark:border-white/10 dark:bg-neutral-900"
    >
      <%!-- Pending pasted screenshots (fed in by the PasteImages hook). --%>
      <div
        :if={@uploads.image.entries != []}
        class="mx-auto mb-2 flex max-w-5xl flex-wrap items-center gap-2"
      >
        <div :for={entry <- @uploads.image.entries} class="relative" data-image-entry>
          <.live_img_preview
            entry={entry}
            class="h-16 w-16 rounded-lg border border-neutral-200 object-cover dark:border-white/10"
          />
          <button
            type="button"
            phx-click="cancel_image"
            phx-value-ref={entry.ref}
            aria-label="remove image"
            class="absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full bg-neutral-950 text-xs text-white shadow dark:bg-white dark:text-neutral-950"
          >
            ×
          </button>
          <span
            :if={not entry.done?}
            class="absolute inset-x-0 bottom-0 rounded-b-lg bg-neutral-950/70 text-center text-[0.6rem] text-white"
          >
            {entry.progress}%
          </span>
          <p :for={err <- upload_errors(@uploads.image, entry)} class="text-xs text-red-500">
            {upload_error_label(err)}
          </p>
        </div>
        <p :for={err <- upload_errors(@uploads.image)} class="text-xs text-red-500">
          {upload_error_label(err)}
        </p>
      </div>

      <div class="mx-auto max-w-5xl">
        <div class="flex items-center gap-2 rounded-2xl border border-neutral-300 bg-white py-1.5 pl-2 pr-1.5 transition focus-within:border-neutral-400 dark:border-white/15 dark:bg-white/5 dark:focus-within:border-white/30">
          <.input
            field={@chat_form[:message]}
            type="text"
            autocomplete="off"
            phx-debounce="150"
            placeholder="Ask Catalyst…  (@ references a file, paste an image to attach it)"
            container_class="m-0 min-w-0 flex-1"
            class="w-full border-0 bg-transparent px-2 py-1.5 text-sm text-neutral-900 outline-none placeholder:text-neutral-400 focus:ring-0 dark:text-white dark:placeholder:text-neutral-500"
          />
          <.live_file_input upload={@uploads.image} class="hidden" />
          <button
            :if={!@running}
            id="chat-send"
            type="submit"
            aria-label="Send"
            title="Send"
            class="flex size-8 shrink-0 items-center justify-center rounded-full bg-neutral-900 text-white transition hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
          <button
            :if={@running}
            id="chat-stop"
            type="button"
            phx-click="abort"
            aria-label="Stop"
            title="Stop the run"
            class="flex size-8 shrink-0 items-center justify-center rounded-full bg-neutral-900 text-white transition hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            <.icon name="hero-stop-solid" class="size-3.5" />
          </button>
        </div>
      </div>
    </.form>
    """
  end

  defp upload_error_label(:too_large), do: "image too large (max 5MB)"
  defp upload_error_label(:not_accepted), do: "unsupported image type"
  defp upload_error_label(:too_many_files), do: "too many images (max 4)"
  defp upload_error_label(other), do: to_string(other)
end
