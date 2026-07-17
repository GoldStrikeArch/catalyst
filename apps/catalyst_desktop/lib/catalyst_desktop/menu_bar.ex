defmodule CatalystDesktop.MenuBar do
  @moduledoc """
  Native window menubar.

  Its presence is what makes ⌘Q work on macOS: `Desktop.Window` only rewires
  the Apple menu's Quit item (and connects `command_menu_selected` on the
  frame) when a menubar is attached — without one it modifies a detached
  `wxMenuBar` and ⌘Q is silently dead.

  Implements the `Desktop.Menu` behaviour directly instead of
  `use Desktop.Menu`: the use-macro imports `Phoenix.HTML.sigil_E/2`, removed
  in phoenix_html 4.x, so it no longer compiles against this stack.
  """

  @behaviour Desktop.Menu

  @impl true
  def mount(menu), do: {:ok, menu}

  @impl true
  def handle_event("quit", menu) do
    # Desktop quit is a System.halt (no Application.stop callbacks run), so
    # record the clean shutdown first — a stale "booting" marker would flip
    # the next boot into extension safe mode.
    Catalyst.Extensions.mark_clean_shutdown()
    Desktop.Window.quit()
    {:noreply, menu}
  end

  @impl true
  def handle_info(_msg, menu), do: {:noreply, menu}

  # A plain string, deliberately NOT ~H (despite the callback's Rendered.t()
  # spec — Desktop.Menu.Parser.parse/1 explicitly takes binaries): the dev
  # config's debug_heex_annotations/debug_attributes wrap every HEEx template
  # in comment markers and data-phx-loc attributes, and the parser requires
  # <menubar> as the literal root token, so the annotated output fails to
  # parse and the menu comes up empty. Suppress only this upstream callback
  # contract mismatch while retaining the runtime format its parser supports.
  @dialyzer {:nowarn_function, render: 1}
  @impl true
  def render(_assigns) do
    """
    <menubar>
      <menu label="File">
        <item onclick="quit">Quit</item>
      </menu>
    </menubar>
    """
  end
end
