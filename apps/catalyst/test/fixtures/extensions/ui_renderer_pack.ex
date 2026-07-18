defmodule Catalyst.Ext.FlexRendererPack do
  @moduledoc false

  use Catalyst.Extension
  use CatalystWeb, :html

  alias Catalyst.Message

  @impl true
  def setup(api) do
    :ok =
      Catalyst.ExtensionAPI.register_renderer(
        api,
        :message,
        &__MODULE__.ls_result?/1,
        &__MODULE__.render_ls/1
      )

    :ok =
      Catalyst.ExtensionAPI.register_component(
        api,
        :header_extra,
        &__MODULE__.header_extra/1
      )

    Catalyst.ExtensionAPI.register_command(api, "flexping",
      handler: &__MODULE__.command_flexping/2,
      label: "/flexping — prove the runtime command registry is live"
    )
  end

  @doc false
  def ls_result?(%Message.ToolResult{tool_name: "ls"}), do: true
  def ls_result?(_message), do: false

  @doc false
  def render_ls(assigns) do
    ~H"""
    <article
      id={"flex-ls-card-#{@msg.tool_call_id}"}
      data-flex-renderer="ls"
      class="rounded-xl border border-violet-300 bg-violet-50 p-3 text-violet-950"
    >
      <strong>FLEX-LS-CARD</strong>
      <span>{@msg.tool_name}</span>
      <pre>{Catalyst.Content.text_of(@msg.content)}</pre>
    </article>
    """
  end

  @doc false
  def header_extra(assigns) do
    ~H"""
    <span
      id="flex-header-widget"
      data-flex-component="header-extra"
      class="rounded-full border border-violet-300 px-2 py-1 text-xs font-semibold text-violet-700"
    >
      FLEX-HEADER
    </span>
    """
  end

  @doc false
  def command_flexping(arg, socket) do
    suffix =
      case arg do
        "" -> ""
        value -> " #{value}"
      end

    Phoenix.LiveView.put_flash(socket, :info, "FLEX-PONG#{suffix}")
  end
end
