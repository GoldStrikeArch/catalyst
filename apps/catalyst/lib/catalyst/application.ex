defmodule Catalyst.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DNSCluster, query: Application.get_env(:catalyst, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Catalyst.PubSub},
      # HTTP pool for LLM SSE streaming.
      {Finch, name: Catalyst.Finch},
      # Holds OAuth credentials, refreshes tokens on demand.
      Catalyst.Auth.TokenStore,
      # Live tool registry: built-ins + runtime-loaded extensions.
      Catalyst.Extensions,
      # Runtime agent-loop hook registry (before/after tool call, etc.).
      Catalyst.Hooks,
      # Runtime LLM provider registry (built-ins + runtime-registered providers).
      Catalyst.LLM.Registry,
      # Registry maps session id -> Session.Server pid.
      {Registry, keys: :unique, name: Catalyst.Session.Registry},
      # Supervises the loop/tool Tasks spawned per run.
      {Task.Supervisor, name: Catalyst.TaskSupervisor},
      # Supervises one Session.Server per session.
      {DynamicSupervisor, name: Catalyst.Session.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Catalyst.Supervisor)
  end
end
