defmodule CatalystWeb.Layouts do
  @moduledoc """
  Application layouts and layout-adjacent components.
  """
  use CatalystWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the app layout wrapper used by LiveViews and pages.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :class, :any,
    default:
      "min-h-screen bg-neutral-50 text-neutral-900 antialiased dark:bg-neutral-900 dark:text-neutral-100",
    doc: "classes for the layout wrapper"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class={@class}>
      {render_slot(@inner_block)}
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed right-4 top-4 z-50 flex w-[min(24rem,calc(100vw-2rem))] flex-col gap-3"
      aria-live="polite"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides a dark/light/system theme toggle.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="grid grid-cols-3 rounded-full border border-neutral-200 p-0.5 dark:border-white/10"
      title="Theme: system / light / dark"
    >
      <button
        class={theme_segment_class()}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        type="button"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5" />
      </button>

      <button
        class={theme_segment_class()}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        type="button"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-3.5" />
      </button>

      <button
        class={theme_segment_class()}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        type="button"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-3.5" />
      </button>
    </div>
    """
  end

  # The pressed segment is styled from html[data-theme] by CSS in app.css —
  # the theme is client-owned, so no server assign can know it.
  defp theme_segment_class do
    "flex items-center justify-center rounded-full p-1 text-neutral-400 transition " <>
      "hover:text-neutral-900 dark:text-neutral-500 dark:hover:text-white"
  end
end
