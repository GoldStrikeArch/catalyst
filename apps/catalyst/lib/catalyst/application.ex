defmodule Catalyst.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Catalyst.Debug.init()
    :ok = Catalyst.Tools.Registry.validate_defaults()

    children = [
      {Phoenix.PubSub, name: Catalyst.PubSub},
      # Durable workflow runs are explicitly started or resumed. Boot discovery
      # marks abandoned checkpoints interrupted but never starts their processes.
      {Registry, keys: :unique, name: Catalyst.WorkflowRun.Registry},
      {
        DynamicSupervisor,
        name: Catalyst.WorkflowRun.DynamicSupervisor,
        strategy: :one_for_one,
        max_restarts: 100,
        max_seconds: 5
      },
      Catalyst.WorkflowRun.Bootstrap,
      # HTTP pool for LLM SSE streaming.
      {Finch, name: Catalyst.Finch},
      # Supervises the loop/tool Tasks spawned per run (and token refreshes),
      # so it must start before TokenStore.
      {Task.Supervisor, name: Catalyst.TaskSupervisor},
      Catalyst.ACP.Supervisor,
      # Observer entries are passed by value, so delivery has no lifecycle
      # dependency on the extension registries. Keeping the dispatcher outside
      # their rest-for-one group preserves admitted queues during registry
      # recovery; committed admission retries its own rare direct restart.
      Catalyst.Hooks.ObserverDispatcher,
      # Holds OAuth credentials, refreshes tokens on demand.
      Catalyst.Auth.TokenStore,
      # Live Codex model metadata with monotonic freshness and single-flight refresh.
      Catalyst.LLM.OpenAICodex.CatalogCache,
      # Idle Codex websocket connections between runs (delta-upload state).
      Catalyst.LLM.OpenAICodex.ConnCache,
      # Stable owner of the per-session screenshot-geometry ETS table. Kept
      # outside the Helper deliberately: a Helper crash must not destroy the
      # recorded viewports, or the next click silently falls back to the
      # default main-display mapping after a window-scoped screenshot.
      Catalyst.Tools.Computer.Viewport,
      # Owns the native computer-use input helper Port. Lazy: no Port (and no
      # TCC prompt) until the first computer-use call; :permanent so the held-
      # input release invariant survives helper crashes.
      Catalyst.Tools.Computer.Helper,
      # Cross-turn PTY shell sessions (shell_session tool): one Server per
      # shell under the DynamicSupervisor, registered by shell-session id with
      # the owning Catalyst session id as the value.
      {Registry, keys: :unique, name: Catalyst.Tools.Shell.Registry},
      {DynamicSupervisor, name: Catalyst.Tools.Shell.Supervisor, strategy: :one_for_one},
      # The reconstructible extension runtime. A registry restart also restarts
      # the extension coordinator, whose boot load rebuilds every contribution
      # from source instead of replaying parallel per-domain state.
      %{
        id: Catalyst.ExtensionRuntimeSupervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             extension_runtime(),
             [strategy: :rest_for_one, max_restarts: extension_runtime_max_restarts()]
           ]}
      },
      # Registry maps session id -> Session.Server pid.
      {Registry, keys: :unique, name: Catalyst.Session.Registry},
      # Atomic root-tree capacity and parent/child monitoring for real
      # subagent sessions. The table owner survives a Children restart so the
      # coordinator can reconstruct monitors without forgetting live leases.
      %{
        id: Catalyst.AgentChildrenSupervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [Catalyst.Agent.Children.TableOwner, Catalyst.Agent.Children],
             [strategy: :rest_for_one]
           ]}
      },
      # Supervises one Session.Server per session. Outside the runtime group:
      # sessions resolve tools/hooks/providers from the live registries per
      # turn, so they ride out a registry-chain restart without being killed.
      {
        DynamicSupervisor,
        # All Manager-started sessions are :temporary, so this is a backstop for
        # direct children rather than a shared failure domain for normal sessions.
        name: Catalyst.Session.DynamicSupervisor,
        strategy: :one_for_one,
        max_restarts: 100,
        max_seconds: 5
      }
    ]

    with {:ok, _sup} = ok <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Catalyst.Supervisor) do
      register_builtin_hooks()
      ok
    end
  end

  # Built-in agent-loop hooks (currently: optional screenshot pruning). They
  # live in the same runtime Hooks registry extensions use, so a reseeder keeps
  # them registered across extension-runtime restarts and load_all reloads.
  defp register_builtin_hooks do
    :ok = Catalyst.Tools.Computer.Screenshots.register_hooks()

    :ok =
      Catalyst.Extensions.register_reseeder(Catalyst.Tools.Computer.Screenshots, :register_hooks)
  end

  @impl true
  def stop(_state) do
    # A graceful shutdown is not a crash: without this, a System.stop within
    # the BootGuard stabilization window flips the next boot into extension
    # safe mode. The desktop quit path is a System.halt and never reaches
    # here — the window's quit menu marks it instead.
    Catalyst.Extensions.mark_clean_shutdown()
  end

  # Order is load-bearing (:rest_for_one): a shared-registry crash restarts the
  # extension coordinator, whose load rebuilds the live projection from source.
  defp extension_runtime do
    [
      # One owner-aware table backs every migrated runtime contribution kind.
      # Domain modules retain validation and fallback resolution but no longer
      # own parallel GenServer/ETS implementations.
      Catalyst.Runtime.Registry,
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

  defp extension_runtime_max_restarts do
    Application.get_env(:catalyst, :extension_runtime_max_restarts, 3)
  end
end
