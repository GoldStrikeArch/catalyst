defmodule CatalystWeb.Router do
  @moduledoc """
  HTTP routes. Everything renders through `CatalystWeb.ShellLive`: `/` plus a
  `/:page` catch-all that resolves runtime-registered pages from
  `CatalystWeb.UI.Registry` — no router recompile per extension page.
  """
  use CatalystWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CatalystWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", CatalystWeb do
    pipe_through :browser

    # Digest-addressed transcript images (CatalystWeb.UI.ImageStore); served
    # out of line so reconnects don't re-embed every capture as base64. The
    # path is deliberately /image (singular): /images is a Plug.Static path
    # (CatalystWeb.static_paths/0) and would be shadowed there and treated as
    # a static asset by verified routes.
    get "/image/:digest", ImageController, :show

    # One LiveView for everything; the catch-all resolves runtime-registered
    # pages by path (e.g. /settings) with no router recompile per page.
    live "/", ShellLive, :index
    live "/:page", ShellLive, :page
  end
end
