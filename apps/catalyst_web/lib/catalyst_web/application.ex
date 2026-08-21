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
      # Serializes and retains the exact live UI contribution replay log. It
      # starts before the table owner so rest-for-one table recovery keeps it.
      CatalystWeb.UI.Contributions,
      # Owns the ETS table independently so UI registrations survive a
      # CatalystWeb.UI.Registry process restart.
      CatalystWeb.UI.TableOwner,
      # Runtime UI registry: pages, renderers, components, commands.
      CatalystWeb.UI.Registry,
      # Start to serve requests, typically the last entry
      CatalystWeb.Endpoint,
      # Bounded digest-addressed store for transcript images served out of
      # line by CatalystWeb.ImageController. After the endpoint on purpose:
      # under rest_for_one a store crash must not bounce the endpoint, and
      # both the renderer and the controller already degrade (placeholder /
      # 404) while the table is briefly absent.
      CatalystWeb.UI.ImageStore
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [
      strategy: :rest_for_one,
      name: CatalystWeb.Supervisor,
      max_restarts: ui_runtime_max_restarts()
    ]

    children
    |> Supervisor.start_link(opts)
    |> complete_start(fn supervisor ->
      :ok =
        Catalyst.Runtime.ReadModel.register_source(
          :web,
          {CatalystWeb.RuntimeSource, :snapshot}
        )

      register_web_tools()

      # Re-registered on every Catalyst.Extensions restart: a registry-chain
      # restart re-seeds only built-ins and extension files, and this app's
      # start/2 won't run again to put the web tools back.
      Catalyst.Extensions.register_reseeder(__MODULE__, :register_web_tools)

      # Publish host readiness last. This notification may start the deferred
      # extension bootstrap immediately, so host-owned tool claims and their
      # restart reseeder must already be installed.
      Catalyst.Extensions.register_host(:web, :application, supervisor)
      bootstrap_extensions()
    end)
  end

  @doc false
  @spec complete_start(Supervisor.on_start(), (pid() -> term())) :: Supervisor.on_start()
  def complete_start({:ok, supervisor} = result, after_start) do
    after_start.(supervisor)
    result
  end

  def complete_start({:error, _reason} = error, _after_start), do: error

  @doc false
  # Register the web-side self-modification tools into the core tool registry.
  # (`:catalyst` boots before `:catalyst_web`, so `Catalyst.Extensions` is up.)
  # Public: re-run as an Extensions reseeder after a registry restart.
  def register_web_tools do
    Enum.each([CatalystWeb.Tools.RebuildAssets, CatalystWeb.Tools.ReloadUi], fn tool ->
      case Catalyst.Extensions.register_tool(tool) do
        {:ok, _} -> :ok
        other -> Logger.warning("failed to register #{inspect(tool)}: #{inspect(other)}")
      end
    end)
  rescue
    e -> Logger.warning("web tool registration failed: #{Exception.message(e)}")
  end

  # Core defers its one boot load in web-capable releases until the UI kinds
  # have been wired. bootstrap/0 is idempotent, so setup/1 runs once even if
  # this application or its supervisor is restarted.
  defp bootstrap_extensions do
    case Catalyst.Extensions.bootstrap() do
      {:skipped, status} ->
        Logger.info("extension bootstrap skipped: #{inspect(status)}")

      :ok ->
        :ok
    end
  rescue
    e -> Logger.warning("extension bootstrap failed: #{Exception.message(e)}")
  end

  defp ui_runtime_max_restarts do
    Application.get_env(:catalyst_web, :ui_runtime_max_restarts, 3)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CatalystWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
