defmodule Catalyst.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Catalyst.Debug.init()

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
      # Observer entries are passed by value, so delivery has no lifecycle
      # dependency on the extension registries. Keeping the dispatcher outside
      # their rest-for-one group preserves admitted queues during registry
      # recovery; committed admission retries its own rare direct restart.
      Catalyst.Hooks.ObserverDispatcher,
      # Validates built-in tool metadata once; extension registrations populate
      # the same hot-reload-safe cache before a tool becomes visible.
      Catalyst.Tools.Registry,
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
      # The extension runtime registries, grouped under :rest_for_one because
      # they have hard inter-child dependencies (see extension_runtime/0).
      # Under the previous flat :one_for_one those held only at first boot: a
      # TableOwner crash restarted it with a fresh empty ETS table while Hooks
      # kept running — every registered handler silently lost and the
      # before_tool_call gates failing open — and a Hooks/LLM.Registry restart
      # lost extension registrations with nothing re-registering them. The
      # restart budget is test-overridable because chaos tests deliberately
      # kill several different children in one short window; production keeps
      # OTP's default escalation threshold.
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
      # Runtime-only owned overlays. Application config remains a live fallback
      # and Catalyst.Extensions (last below) replays extension registrations
      # after any rest-for-one restart.
      Catalyst.Prompt.Registry,
      Catalyst.Workflow.Registry,
      Catalyst.Context.Registry,
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
