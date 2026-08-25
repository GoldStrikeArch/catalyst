defmodule CatalystWeb.Components.ComputerControl do
  @moduledoc """
  Optional computer-use grant control for the shell.

  The component owns persistence, rendering, and its local event. Parent-session
  mutation crosses the generic UI-component action boundary, keeping computer
  knowledge out of `CatalystWeb.ShellLive`.
  """

  use CatalystWeb, :live_component

  alias Catalyst.Session.Server
  alias CatalystWeb.ShellLive.RunDiagnostics

  @prefs_key {CatalystWeb.ShellLive, :machine_prefs}

  @doc "Session option contributed when a new shell session starts."
  @spec session_options() :: keyword()
  def session_options, do: [computer_use: enabled?()]

  @doc "Whether the persisted browser-level computer grant is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    case :persistent_term.get(@prefs_key, nil) do
      %{computer_use: value} when is_boolean(value) -> value
      _not_saved -> false
    end
  end

  @impl true
  def update(%{shell: shell}, socket) do
    enabled = authoritative_value(shell.session_opts, enabled?())
    persist(enabled)
    {:ok, assign(socket, enabled: enabled)}
  end

  @impl true
  def handle_event("toggle_computer_use", _params, socket) do
    send(self(), {:ui_component, __MODULE__, :toggle})
    {:noreply, assign(socket, enabled: !socket.assigns.enabled)}
  end

  @doc "Apply a component action to the parent shell socket."
  @spec handle_shell_action(term(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_shell_action(:toggle, socket) do
    enabled = !enabled?()
    persist(enabled)
    opts = [computer_use: enabled]

    socket
    |> configure_session(opts)
    |> RunDiagnostics.preview()
  end

  def handle_shell_action(_action, socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <button
      id="computer-toggle"
      type="button"
      phx-click="toggle_computer_use"
      phx-target={@myself}
      aria-pressed={to_string(@enabled)}
      title="Computer use: let the agent see the screen and drive this machine. Full access, no sandbox — applies to the next run and is never inherited by subagents."
      class={icon_btn_class(@enabled)}
    >
      <.icon name="hero-computer-desktop" class="size-3.5" />
    </button>
    """
  end

  defp authoritative_value(opts, fallback) do
    case Keyword.fetch(opts || [], :computer_use) do
      {:ok, value} when is_boolean(value) -> value
      _absent_or_invalid -> fallback
    end
  end

  defp configure_session(%{assigns: %{session_pid: pid}} = socket, opts) when is_pid(pid) do
    try do
      :ok = Server.configure(pid, opts: opts)
      assign(socket, session_opts: Keyword.merge(socket.assigns.session_opts || [], opts))
    catch
      :exit, _reason -> socket
    end
  end

  defp configure_session(socket, _opts), do: socket

  defp persist(enabled),
    do: :persistent_term.put(@prefs_key, %{computer_use: enabled})

  defp icon_btn_class(active?) do
    [
      "flex size-6 items-center justify-center rounded-md transition",
      active? && "bg-warn/15 text-warn",
      !active? && "text-faint hover:bg-raised hover:text-ink"
    ]
  end
end
