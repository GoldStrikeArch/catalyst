defmodule CatalystDesktop.Application do
  @moduledoc false

  use Application
  require Logger

  # Window/Dock icon under this app's priv (also the packaging source in mix.exs).
  @icon "icon.png"

  @window_id CatalystWindow

  @doc "Registered name of the native `Desktop.Window` process."
  @spec window_id() :: atom()
  def window_id, do: @window_id

  @impl true
  def start(_type, _args) do
    children =
      if window_enabled?() do
        Logger.info("[catalyst_desktop] starting native window")
        register_folder_picker()

        [
          {Desktop.Window, window_opts()},
          # Dev runs are a bare beam.smp process: give the Dock our icon too.
          {CatalystDesktop.DockIcon, app: :catalyst_desktop, icon: @icon}
        ]
      else
        Logger.info("[catalyst_desktop] window disabled (browser mode)")
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: CatalystDesktop.Supervisor)
  end

  # Desktop mode is opt-in so plain `mix phx.server` stays a fast browser loop.
  # Enable with `CATALYST_DESKTOP=1` or `config :catalyst_desktop, start_window: true`.
  @spec window_enabled?() :: boolean()
  defp window_enabled? do
    Application.get_env(:catalyst_desktop, :start_window, false) or
      System.get_env("CATALYST_DESKTOP") == "1"
  end

  # The web app cannot open an OS folder picker; hand it ours (see
  # CatalystWeb.FolderPicker) so the sidebar's + opens a native dialog.
  defp register_folder_picker do
    Application.put_env(:catalyst_web, :folder_picker, &CatalystDesktop.FolderPicker.pick/1)
  end

  @spec window_opts() :: keyword()
  defp window_opts do
    [
      app: :catalyst_desktop,
      id: @window_id,
      title: Application.get_env(:catalyst_desktop, :window_title, "Catalyst"),
      size: Application.get_env(:catalyst_desktop, :window_size, {1100, 800}),
      # Required for ⌘Q on macOS: Desktop.Window only wires the Apple menu's
      # Quit item when the frame has a menubar attached.
      menubar: CatalystDesktop.MenuBar,
      icon: @icon,
      url: &CatalystWeb.Endpoint.url/0
    ]
  end
end
