defmodule CatalystWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # ETS-backed session store for the desktop webview. Created here (idempotent
    # across restarts) before the endpoint, which references the :session table.
    if :ets.whereis(:session) == :undefined do
      :ets.new(:session, [:named_table, :public, read_concurrency: true])
    end

    children = [
      CatalystWeb.Telemetry,
      # Runtime UI registry: pages, renderers, components, commands.
      CatalystWeb.UI.Registry,
      # Start to serve requests, typically the last entry
      CatalystWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CatalystWeb.Supervisor]
    result = Supervisor.start_link(children, opts)
    register_web_tools()
    # Re-registered on every Catalyst.Extensions restart: a registry-chain
    # restart re-seeds only built-ins and extension files, and this app's
    # start/2 won't run again to put the web tools back.
    Catalyst.Extensions.register_reseeder(__MODULE__, :register_web_tools)
    reload_extensions()
    result
  end

  @doc false
  # Register the web-side self-modification tools into the core tool registry.
  # (`:catalyst` boots before `:catalyst_web`, so `Catalyst.Extensions` is up.)
  # Public: re-run as an Extensions reseeder after a registry restart.
  def register_web_tools do
    Enum.each([CatalystWeb.Tools.RebuildAssets, CatalystWeb.Tools.ReconnectUi], fn tool ->
      case Catalyst.Extensions.register_tool(tool) do
        {:ok, _} -> :ok
        other -> Logger.warning("failed to register #{inspect(tool)}: #{inspect(other)}")
      end
    end)
  rescue
    e -> Logger.warning("web tool registration failed: #{Exception.message(e)}")
  end

  # The boot-time extension load in :catalyst ran before this app wired the UI
  # kinds (:renderer/:component/:page) into ExtensionAPI, so any UI
  # registrations from extensions were dropped. Reload now that they resolve.
  # reload_after_wiring/0 no-ops in safe mode (env or crash-detected) and never
  # clears the BootGuard marker — only an explicit reload_extensions does that.
  defp reload_extensions do
    case Catalyst.Extensions.reload_after_wiring() do
      {:skipped, status} ->
        Logger.info("extension reload skipped: #{inspect(status)}")

      {:ok, %{failed: []}} ->
        :ok

      {:ok, %{failed: failed}} ->
        Logger.warning("extension reload after UI wiring: #{length(failed)} file(s) failed")
    end
  rescue
    e -> Logger.warning("extension reload after UI wiring failed: #{Exception.message(e)}")
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CatalystWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
