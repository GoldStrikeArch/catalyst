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

        <%!-- The model is working, but partial text stays internal until MessageEnd.
        The final assistant message then renders through MessageRenderer once. --%>
        <div
          :if={@streaming}
          id="streaming-message"
          data-message-role="assistant-streaming"
          class="flex justify-start"
        >
          <div class="inline-flex items-center gap-1.5 rounded-3xl rounded-bl-md border border-slate-200 bg-white/85 px-4 py-3 text-slate-500 shadow-sm shadow-slate-200/50 backdrop-blur dark:border-white/10 dark:bg-white/10 dark:text-slate-300 dark:shadow-black/20">
            <span class="sr-only">Assistant is working</span>
            <span class="size-1.5 animate-bounce rounded-full bg-indigo-500 [animation-delay:-0.2s]">
            </span>
            <span class="size-1.5 animate-bounce rounded-full bg-indigo-500 [animation-delay:-0.1s]">
            </span>
            <span class="size-1.5 animate-bounce rounded-full bg-indigo-500"></span>
          </div>
        </div>

        <div :for={{_id, t} <- @tools} class="flex justify-start">
          <div class="inline-flex items-center gap-2 rounded-full border border-indigo-200 bg-indigo-50 px-3 py-1.5 text-xs font-medium text-indigo-700 shadow-sm dark:border-indigo-400/20 dark:bg-indigo-400/10 dark:text-indigo-200">
            <span class="size-3 animate-spin rounded-full border-2 border-indigo-200 border-t-indigo-600 dark:border-indigo-200/20 dark:border-t-indigo-200">
            </span>
            running <code class="font-mono">{t.name}</code>…
          </div>
        </div>
      </div>
    </main>

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
            placeholder="Ask Catalyst…  (e.g. “list the files” or “search defmodule”)"
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
