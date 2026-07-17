defmodule CatalystWeb.Router do
  use CatalystWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CatalystWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CatalystWeb do
    pipe_through :browser

    # One LiveView for everything; the catch-all resolves runtime-registered
    # pages by path (e.g. /settings) with no router recompile per page.
    live "/", ShellLive, :index
    live "/:page", ShellLive, :page
  end

  # Other scopes may use custom stacks.
  # scope "/api", CatalystWeb do
  #   pipe_through :api
  # end
end
