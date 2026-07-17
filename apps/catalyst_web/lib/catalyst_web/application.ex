defmodule CatalystWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # ETS-backed session store for the desktop webview. Created here (idempotent
    # across restarts) before the endpoint, which references the :session table.
    if :ets.whereis(:session) == :undefined do
      :ets.new(:session, [:named_table, :public, read_concurrency: true])
    end

    children = [
      CatalystWeb.Telemetry,
      # Start a worker by calling: CatalystWeb.Worker.start_link(arg)
      # {CatalystWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      CatalystWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CatalystWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CatalystWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
