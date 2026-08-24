defmodule CatalystWeb.UI.PageRenderer do
  @moduledoc """
  Resolves and safely renders runtime-registered pages and shell slot components.

  Built-in pages retain normal lazy LiveView diffs. Extension render functions
  are forced to iodata inside the safety boundary because failures can otherwise
  occur later, when LiveView evaluates a rendered template's dynamic closures.
  """

  use Phoenix.Component

  alias CatalystWeb.UI.{Registry, SafeRender}

  @doc "Renders the active registered page, falling back to the built-in chat page."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t() | {:safe, iodata()}
  def render(assigns) do
    {module, function, mode} = page_target(assigns.page)

    case mode do
      :live -> apply(module, function, [assigns])
      :safe -> safely_render_page(module, function, assigns)
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
    case Registry.fetch_page_entry(page) do
      {:ok, entry} -> {entry.mod, entry.fun, entry.render_mode}
      :error -> {CatalystWeb.Pages.ChatPage, :render, :live}
    end
  end

  defp safely_render_page(module, function, assigns) do
    SafeRender.forced_iodata(
      fn -> apply(module, function, [assigns]) end,
      "page #{inspect(module)}.#{function}",
      fn -> CatalystWeb.Pages.ChatPage.render(assigns) end
    )
  end

  defp safely_render_component(function, assigns) do
    SafeRender.forced_iodata(fn -> function.(assigns) end, "slot component", fn -> nil end)
  end
end
