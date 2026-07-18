defmodule CatalystWeb.UI.PageRenderer do
  @moduledoc """
  Resolves and safely renders runtime-registered pages and shell slot components.

  Built-in pages retain normal lazy LiveView diffs. Extension render functions
  are forced to iodata inside the safety boundary because failures can otherwise
  occur later, when LiveView evaluates a rendered template's dynamic closures.
  """

  use Phoenix.Component

  require Logger

  alias CatalystWeb.UI.Registry

  @trusted_pages [CatalystWeb.Pages.ChatPage, CatalystWeb.Pages.ExtensionsPage]

  @doc "Renders the active registered page, falling back to the built-in chat page."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t() | {:safe, iodata()}
  def render(assigns) do
    {module, function} = page_target(assigns.page)

    case module in @trusted_pages do
      true -> apply(module, function, [assigns])
      false -> safely_render_page(module, function, assigns)
    end
  end

  @doc "Renders all runtime components registered for a named shell slot."
  @spec render_components(atom(), map()) :: Phoenix.LiveView.Rendered.t()
  def render_components(slot, assigns) do
    assigns = assign(assigns, :__slot_functions__, Registry.components(slot))

    ~H"""
    <%= for function <- @__slot_functions__ do %>
      {safely_render_component(function, assigns)}
    <% end %>
    """
  end

  defp page_target(page) do
    case Registry.fetch_page(page) do
      {:ok, target} -> target
      :error -> {CatalystWeb.Pages.ChatPage, :render}
    end
  end

  defp safely_render_page(module, function, assigns) do
    rendered = apply(module, function, [assigns])
    {:safe, Phoenix.HTML.Safe.to_iodata(rendered)}
  rescue
    error ->
      Logger.warning(
        "[ui] page #{inspect(module)}.#{function} raised: #{Exception.message(error)} — falling back to chat"
      )

      CatalystWeb.Pages.ChatPage.render(assigns)
  catch
    kind, reason ->
      Logger.warning("[ui] page #{inspect(module)}.#{function} #{kind}: #{inspect(reason)}")
      CatalystWeb.Pages.ChatPage.render(assigns)
  end

  defp safely_render_component(function, assigns) do
    {:safe, Phoenix.HTML.Safe.to_iodata(function.(assigns))}
  rescue
    error ->
      Logger.warning("[ui] slot component raised: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.warning("[ui] slot component #{kind}: #{inspect(reason)}")
      nil
  end
end
