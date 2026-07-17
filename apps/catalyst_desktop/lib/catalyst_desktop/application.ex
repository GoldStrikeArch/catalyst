defmodule CatalystDesktop.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if window_enabled?() do
        Logger.info("[catalyst_desktop] starting native window")
        [{Desktop.Window, window_opts()}]
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

  @spec window_opts() :: keyword()
  defp window_opts do
    [
      app: :catalyst_desktop,
      id: CatalystWindow,
      title: Application.get_env(:catalyst_desktop, :window_title, "Catalyst"),
      size: Application.get_env(:catalyst_desktop, :window_size, {1100, 800}),
      url: &CatalystWeb.Endpoint.url/0
    ]
  end
end
