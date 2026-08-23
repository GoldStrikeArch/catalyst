defmodule CatalystWeb.Router do
  @moduledoc """
  HTTP routes. The current chat product renders through `CatalystWeb.ShellLive`;
  `/ide` and `/workbench/:workbench` exercise the stable replaceable-workbench
  host before any root switch. Other `/:page` paths resolve runtime-registered
  shell pages from the UI registry.
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

    # Runtime rebuilds are published outside the immutable application bundle.
    # The generation digest makes these responses safe to cache permanently.
    get "/runtime-assets/:generation/assets/css/app.css", RuntimeAssetController, :css

    get "/runtime-assets/:generation/assets/js/app.js",
        RuntimeAssetController,
        :javascript

    get "/runtime-assets/:generation/modules/*path", RuntimeAssetController, :module

    # The stable workbench host is an A/B seam; `/` remains the chat Shell.
    live "/ide", WorkbenchHostLive, :index
    live "/workbench/:workbench", WorkbenchHostLive, :show

    # One LiveView for the current shell; the catch-all resolves runtime-registered
    # pages by path (e.g. /settings) with no router recompile per page.
    live "/compare", ComparisonLive, :index
    live "/compare/:id", ComparisonLive, :show
    live "/", ShellLive, :index
    live "/:page", ShellLive, :page
  end
end
