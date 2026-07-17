defmodule Catalyst.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Catalyst.PubSub},
      # HTTP pool for LLM SSE streaming.
      {Finch, name: Catalyst.Finch},
      # Supervises the loop/tool Tasks spawned per run (and token refreshes),
      # so it must start before TokenStore.
      {Task.Supervisor, name: Catalyst.TaskSupervisor},
      # Holds OAuth credentials, refreshes tokens on demand.
      Catalyst.Auth.TokenStore,
      # The extension runtime registries, grouped under :rest_for_one because
      # they have hard inter-child dependencies (see extension_runtime/0).
      # Under the previous flat :one_for_one those held only at first boot: a
      # TableOwner crash restarted it with a fresh empty ETS table while Hooks
      # kept running — every registered handler silently lost and the
      # before_tool_call gates failing open — and a Hooks/LLM.Registry restart
      # lost extension registrations with nothing re-registering them.
      %{
        id: Catalyst.ExtensionRuntimeSupervisor,
        type: :supervisor,
        start: {Supervisor, :start_link, [extension_runtime(), [strategy: :rest_for_one]]}
      },
      # Registry maps session id -> Session.Server pid.
      {Registry, keys: :unique, name: Catalyst.Session.Registry},
      # Supervises one Session.Server per session. Outside the runtime group:
      # sessions resolve tools/hooks/providers from the live registries per
      # turn, so they ride out a registry-chain restart without being killed.
      {DynamicSupervisor, name: Catalyst.Session.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Catalyst.Supervisor)
  end

  # Order is load-bearing (:rest_for_one): each child depends on the ones
  # before it, and a crashed child restarts everything after it — ending with
  # Catalyst.Extensions, whose load_all re-registers extension contributions
  # into the freshly restarted registries.
  defp extension_runtime do
    [
      # Owns the hooks ETS table in a process that does nothing else, so the
      # registered handlers survive a Catalyst.Hooks crash (the table would
      # otherwise die with the server and the gates would fail open).
      Catalyst.Hooks.TableOwner,
      # Runtime agent-loop hook registry (before/after tool call, etc.).
      Catalyst.Hooks,
      # Runtime LLM provider registry (built-ins + runtime-registered providers).
      Catalyst.LLM.Registry,
      # Supervised home for extension-owned processes: one DynamicSupervisor per
      # extension owner (registered by id) under this top-level one, so purging
      # an extension can terminate its whole process subtree.
      {Registry, keys: :unique, name: Catalyst.Extensions.ProcessRegistry},
      {DynamicSupervisor, name: Catalyst.Extensions.ProcessSupervisor, strategy: :one_for_one},
      # Live tool registry: built-ins + runtime-loaded extensions. Last: its
      # boot load_all runs extension setup/1 functions that register into all
      # of the above.
      Catalyst.Extensions
    ]
  end
end
