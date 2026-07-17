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
    <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto px-4 py-6 space-y-2">
      <div :if={@messages == [] and is_nil(@streaming)} class="text-center text-base-content/50 mt-20">
        <p class="text-sm">Ask Catalyst to inspect this project.</p>
        <p class="text-xs mt-1">cwd: {@cwd}</p>
      </div>

      <%= for msg <- @messages do %>
        {MessageRenderer.render_message(%{msg: msg})}
      <% end %>

      <div :if={@streaming} class="chat chat-start">
        <div class="chat-bubble chat-bubble-neutral whitespace-pre-wrap">
          <span :if={@streaming.thinking != ""} class="block text-xs italic opacity-60 mb-1">{@streaming.thinking}</span>{@streaming.text}<span class="animate-pulse">▌</span>
        </div>
      </div>

      <div :for={{_id, t} <- @tools} class="chat chat-start">
        <div class="chat-bubble chat-bubble-info text-sm flex items-center gap-2">
          <span class="loading loading-spinner loading-xs"></span> running <code>{t.name}</code>…
        </div>
      </div>
    </div>

    <form
      phx-submit="send"
      phx-change="typing"
      class="bg-base-100 border-t border-base-300 p-3 flex gap-2"
    >
      <input
        type="text"
        name="message"
        value={@input}
        autocomplete="off"
        placeholder="Ask Catalyst…  (e.g. “list the files” or “search defmodule”)"
        class="input input-bordered flex-1"
      />
      <button :if={!@running} type="submit" class="btn btn-primary">Send</button>
      <button :if={@running} type="button" phx-click="abort" class="btn btn-error">Stop</button>
    </form>
    """
  end
end
