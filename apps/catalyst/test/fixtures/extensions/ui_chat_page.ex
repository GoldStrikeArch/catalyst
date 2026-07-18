defmodule Catalyst.Ext.FlexChatPage do
  @moduledoc false

  use CatalystWeb, :html

  @doc false
  def render(assigns) do
    assigns = assign(assigns, :built_in_chat, CatalystWeb.Pages.ChatPage.render(assigns))

    ~H"""
    <section id="flex-chat-v2" data-flex-page="chat-v2">
      <p class="sr-only">FLEX-CHAT-V2</p>
      {@built_in_chat}
    </section>
    """
  end
end

defmodule Catalyst.Ext.FlexChatPageExtension do
  @moduledoc false

  use Catalyst.Extension

  @impl true
  def setup(api) do
    Catalyst.ExtensionAPI.register_page(api, "chat", Catalyst.Ext.FlexChatPage, label: "Chat V2")
  end
end
