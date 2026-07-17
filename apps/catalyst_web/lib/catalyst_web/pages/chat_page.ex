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
            class="mx-auto mt-24 max-w-md rounded-3xl border border-slate-200 bg-white/75 p-8 text-center shadow-xl shadow-slate-200/60 backdrop-blur dark:border-white/10 dark:bg-white/10 dark:shadow-black/20"
          >
            <div class="mx-auto mb-4 flex size-12 items-center justify-center rounded-2xl bg-indigo-600 text-white shadow-lg shadow-indigo-900/20">
              <.icon name="hero-sparkles" class="size-6" />
            </div>
            <p class="text-sm font-semibold text-slate-800 dark:text-white">
              Ask Catalyst to inspect this project.
            </p>
            <p class="mt-2 truncate font-mono text-xs text-slate-400 dark:text-slate-500">
              cwd: {@cwd}
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
            <div class="max-w-[85%] rounded-3xl rounded-bl-md border border-slate-200 bg-white/85 px-4 py-3 text-slate-800 shadow-sm shadow-slate-200/50 backdrop-blur dark:border-white/10 dark:bg-white/10 dark:text-slate-100 dark:shadow-black/20">
              <%!-- phx-no-format: whitespace-pre-wrap + empty:hidden — formatter
                whitespace inside would render as a blank line and defeat :empty. --%>
              <div
                id="stream-thinking"
                phx-update="ignore"
                data-stream="thinking"
                class="whitespace-pre-wrap text-xs italic text-slate-400 empty:hidden dark:text-slate-500"
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
                class="inline-flex items-center gap-1.5 text-slate-500 dark:text-slate-300"
              >
                <span class="sr-only">Assistant is working</span>
                <span class="size-1.5 animate-bounce rounded-full bg-indigo-500 [animation-delay:-0.2s]">
                </span>
                <span class="size-1.5 animate-bounce rounded-full bg-indigo-500 [animation-delay:-0.1s]">
                </span>
                <span class="size-1.5 animate-bounce rounded-full bg-indigo-500"></span>
              </div>
            </div>
          </div>

          <div :for={{_id, t} <- @tools} class="flex flex-col items-start gap-1">
            <div class="inline-flex items-center gap-2 rounded-full border border-indigo-200 bg-indigo-50 px-3 py-1.5 text-xs font-medium text-indigo-700 shadow-sm dark:border-indigo-400/20 dark:bg-indigo-400/10 dark:text-indigo-200">
              <span class="size-3 animate-spin rounded-full border-2 border-indigo-200 border-t-indigo-600 dark:border-indigo-200/20 dark:border-t-indigo-200">
              </span>
              running <code class="font-mono">{t.name}</code>…
            </div>
            <%!-- Live output tail streamed by the tool (bash) via ToolExecutionUpdate. --%>
            <pre
              :if={t[:partial]}
              data-tool-partial
              class="max-w-[85%] overflow-x-auto whitespace-pre-wrap rounded-lg bg-slate-100 px-2.5 py-1.5 font-mono text-[0.65rem] leading-relaxed text-slate-500 dark:bg-white/5 dark:text-slate-400"
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
          class="pointer-events-auto hidden items-center gap-1.5 rounded-full bg-indigo-600 px-3.5 py-2 text-xs font-semibold text-white shadow-lg shadow-indigo-900/25 transition hover:bg-indigo-500 dark:bg-indigo-500 dark:hover:bg-indigo-400"
        >
          <.icon name="hero-arrow-down" class="size-3.5" /> Jump to latest
        </button>
      </div>
    </div>

    <div
      :if={@file_search}
      id="file-search-results"
      class="border-t border-slate-200/80 bg-white/95 px-4 py-2 backdrop-blur dark:border-white/10 dark:bg-slate-950/90"
    >
      <div class="mx-auto max-w-5xl">
        <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-slate-400 dark:text-slate-500">
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
            class="flex items-baseline gap-3 rounded-lg px-2 py-1 text-left text-xs transition hover:bg-indigo-50 dark:hover:bg-white/10"
          >
            <code class="shrink-0 font-mono font-semibold text-indigo-700 dark:text-indigo-300">
              {r.label}
            </code>
            <span class="truncate font-mono text-slate-400 dark:text-slate-500">{r.path}</span>
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
      class="border-t border-slate-200/80 bg-white/85 px-4 py-3 shadow-[0_-8px_30px_rgba(15,23,42,0.06)] backdrop-blur dark:border-white/10 dark:bg-slate-950/80 dark:shadow-black/20"
    >
      <%!-- Pending pasted screenshots (fed in by the PasteImages hook). --%>
      <div
        :if={@uploads.image.entries != []}
        class="mx-auto mb-2 flex max-w-5xl flex-wrap items-center gap-2"
      >
        <div :for={entry <- @uploads.image.entries} class="relative" data-image-entry>
          <.live_img_preview
            entry={entry}
            class="h-16 w-16 rounded-lg border border-slate-200 object-cover dark:border-white/10"
          />
          <button
            type="button"
            phx-click="cancel_image"
            phx-value-ref={entry.ref}
            aria-label="remove image"
            class="absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full bg-slate-950 text-xs text-white shadow dark:bg-white dark:text-slate-950"
          >
            ×
          </button>
          <span
            :if={not entry.done?}
            class="absolute inset-x-0 bottom-0 rounded-b-lg bg-slate-950/70 text-center text-[0.6rem] text-white"
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

      <div class="mx-auto flex max-w-5xl items-end gap-3">
        <div class="min-w-0 flex-1">
          <.input
            field={@chat_form[:message]}
            type="text"
            autocomplete="off"
            phx-debounce="150"
            placeholder="Ask Catalyst…  (type @ to reference a file, paste an image to attach it)"
            class="w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-sm text-slate-950 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-indigo-400 focus:ring-4 focus:ring-indigo-500/15 dark:border-white/10 dark:bg-white/10 dark:text-white dark:placeholder:text-slate-500"
          />
          <.live_file_input upload={@uploads.image} class="hidden" />
        </div>
        <div :if={!@running} class="mb-3">
          <.button type="submit" variant="primary">Send</.button>
        </div>
        <div :if={@running} class="mb-3">
          <.button type="button" phx-click="abort" variant="danger">Stop</.button>
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
