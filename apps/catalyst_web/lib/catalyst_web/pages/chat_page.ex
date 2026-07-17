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
    <main
      id="messages"
      phx-hook="ScrollBottom"
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
          <div :for={{dom_id, %{msg: msg}} <- @streams.messages} id={dom_id}>
            {MessageRenderer.render_message(%{msg: msg})}
          </div>
        </div>

        <%!-- The live streaming bubble. `@streaming` seeds the first paint
        (accumulated text for late joiners); every later delta is push_event'd
        and appended client-side by the StreamingMessage hook. phx-update="ignore"
        keeps LiveView from repainting over the appended text; the completed
        message then renders once through MessageRenderer at MessageEnd, which
        removes this element (@streaming goes nil). --%>
        <div
          :if={@streaming}
          id="streaming-message"
          phx-hook="StreamingMessage"
          phx-update="ignore"
          data-message-role="assistant-streaming"
          class="flex justify-start"
        >
          <div class="max-w-[85%] rounded-3xl rounded-bl-md border border-slate-200 bg-white/85 px-4 py-3 text-slate-800 shadow-sm shadow-slate-200/50 backdrop-blur dark:border-white/10 dark:bg-white/10 dark:text-slate-100 dark:shadow-black/20">
            <div
              data-stream="thinking"
              class="whitespace-pre-wrap text-xs italic text-slate-400 empty:hidden dark:text-slate-500"
            >{@streaming.thinking}</div>
            <div data-stream="text" class="whitespace-pre-wrap text-sm">{@streaming.text}</div>
            <div data-stream-dots class="inline-flex items-center gap-1.5 text-slate-500 dark:text-slate-300">
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
      class="border-t border-slate-200/80 bg-white/85 px-4 py-3 shadow-[0_-8px_30px_rgba(15,23,42,0.06)] backdrop-blur dark:border-white/10 dark:bg-slate-950/80 dark:shadow-black/20"
    >
      <div class="mx-auto flex max-w-5xl items-end gap-3">
        <div class="min-w-0 flex-1">
          <.input
            field={@chat_form[:message]}
            type="text"
            autocomplete="off"
            phx-debounce="150"
            placeholder="Ask Catalyst…  (type @ to reference a file)"
            class="w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-sm text-slate-950 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-indigo-400 focus:ring-4 focus:ring-indigo-500/15 dark:border-white/10 dark:bg-white/10 dark:text-white dark:placeholder:text-slate-500"
          />
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
end
