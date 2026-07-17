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
      "min-h-screen bg-white text-slate-950 antialiased dark:bg-slate-950 dark:text-slate-50",
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
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
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
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
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
    <div class="relative grid grid-cols-3 rounded-full border border-slate-200 bg-white/80 p-1 shadow-sm shadow-slate-200/70 backdrop-blur dark:border-white/10 dark:bg-white/10 dark:shadow-black/20">
      <button
        class="rounded-full p-2 text-slate-500 transition hover:bg-slate-100 hover:text-slate-900 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-white"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        type="button"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="rounded-full p-2 text-slate-500 transition hover:bg-slate-100 hover:text-amber-600 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-amber-300"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        type="button"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="rounded-full p-2 text-slate-500 transition hover:bg-slate-100 hover:text-indigo-600 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-indigo-300"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        type="button"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
