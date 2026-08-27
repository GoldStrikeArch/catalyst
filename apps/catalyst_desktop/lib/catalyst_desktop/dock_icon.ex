defmodule CatalystDesktop.DockIcon do
  @moduledoc """
  Shows Catalyst's icon in the macOS Dock for the running BEAM process.

  The packaged `.app` gets its Dock tile from the bundle's `.icns`, but a dev run
  (`CATALYST_DESKTOP=1 iex -S mix`) is a plain `beam.smp` process and therefore
  shows Erlang's default icon. wxWidgets' `wxTBI_DOCK` task-bar icon wraps
  `NSApp.applicationIconImage`, so installing one swaps the tile for this process.

  Started after `Desktop.Window` (it needs the shared wx environment) and a no-op
  (`:ignore`) on every other platform. Side effects: one native `wxTaskBarIcon`
  owned by this process for the app's lifetime.
  """

  use GenServer
  require Logger

  # wx.hrl: -define(wxTBI_DOCK, 0).
  @wx_tbi_dock 0

  @typedoc "Options: `:app` owning `priv/<icon>` and the `:icon` file name."
  @type option :: {:app, atom()} | {:icon, String.t()}

  @doc "Start the Dock icon owner; returns `:ignore` off macOS or without a wx env."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case {:os.type(), Desktop.Env.wx_env()} do
      {{:unix, :darwin}, env} when env != nil ->
        :wx.set_env(env)
        install(Keyword.fetch!(opts, :app), Keyword.fetch!(opts, :icon))

      _other_platform_or_no_wx ->
        :ignore
    end
  end

  defp install(app, icon_file) do
    path = app |> Application.app_dir(Path.join("priv", icon_file)) |> String.to_charlist()
    image = :wxImage.new(path)

    case :wxImage.isOk(image) do
      true ->
        taskbar = :wxTaskBarIcon.new(iconType: @wx_tbi_dock)
        set_dock_icon(taskbar, to_icon(image))
        {:ok, %{taskbar: taskbar}}

      false ->
        Logger.warning("[catalyst_desktop] could not load Dock icon #{path}")
        :ignore
    end
  end

  defp to_icon(image) do
    bitmap = :wxBitmap.new(image)
    icon = :wxIcon.new()
    :ok = :wxIcon.copyFromBitmap(icon, bitmap)
    :wxBitmap.destroy(bitmap)
    :wxImage.destroy(image)
    icon
  end

  defp set_dock_icon(taskbar, icon) do
    case :wxTaskBarIcon.setIcon(taskbar, icon, tooltip: "Catalyst") do
      true -> :ok
      false -> Logger.warning("[catalyst_desktop] wx refused to set the Dock icon")
    end
  end
end
