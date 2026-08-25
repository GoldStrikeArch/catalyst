defmodule CatalystWeb.FlexCase do
  @moduledoc """
  Web flexibility-test case: the core isolated-home/baseline setup plus a
  Phoenix connection and helpers for the long-lived sessions mounted by
  `CatalystWeb.ShellLive`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint CatalystWeb.Endpoint

      use CatalystWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Catalyst.Flex.Harness
      import CatalystWeb.FlexCase

      alias Catalyst.Flex.{Baseline, Fixtures}
    end
  end

  setup context do
    {:ok, values} = Catalyst.FlexCase.setup_flex(context)
    persistent = shell_persistent_snapshot()

    ExUnit.Callbacks.on_exit(fn -> restore_shell_persistent(persistent) end)

    {:ok, Map.put(values, :conn, Phoenix.ConnTest.build_conn())}
  end

  @doc "Return the session id exposed by a mounted stock shell and schedule cleanup."
  @spec session_id(struct()) :: String.t()
  def session_id(view) do
    html =
      view |> Phoenix.LiveViewTest.element("#catalyst-shell") |> Phoenix.LiveViewTest.render()

    case Regex.run(~r/data-session-id="([^"]+)"/, html) do
      [_, id] when id != "" ->
        track_session(id)
        id

      _no_session ->
        ExUnit.Assertions.flunk("mounted shell did not expose a session id")
    end
  end

  @doc "Resolve the session process attached to a mounted stock shell."
  @spec session_pid(struct()) :: pid()
  def session_pid(view) do
    id = session_id(view)

    case Catalyst.Session.Manager.whereis(id) do
      {:ok, pid} -> pid
      :error -> ExUnit.Assertions.flunk("session #{id} is not running")
    end
  end

  @doc "Submit a chat prompt and wait for the real session's terminal AgentEnd."
  @spec submit_prompt!(struct(), String.t()) :: String.t()
  def submit_prompt!(view, prompt) do
    id = session_id(view)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Catalyst.Session.Server.topic(id))

    view
    |> Phoenix.LiveViewTest.form("#chat-form", %{"message" => prompt})
    |> Phoenix.LiveViewTest.render_submit()

    receive do
      {:agent_event, ^id, %Catalyst.Agent.Event.AgentEnd{}} ->
        Phoenix.LiveViewTest.render(view)
    after
      5_000 ->
        ExUnit.Assertions.flunk("session #{id} did not emit AgentEnd within 5 seconds")
    end
  end

  @doc "Replace the mounted shell's session and return the new session id."
  @spec fresh_session!(struct()) :: String.t()
  def fresh_session!(view) do
    old_id = session_id(view)

    view
    |> Phoenix.LiveViewTest.element("#new-session-button")
    |> Phoenix.LiveViewTest.render_click()

    new_id = session_id(view)
    ExUnit.Assertions.refute(new_id == old_id, "New did not replace the active session")
    new_id
  end

  defp shell_persistent_snapshot do
    Map.new([:current_session, :codex_prefs, :ui_prefs, :machine_prefs], fn name ->
      key = {CatalystWeb.ShellLive, name}
      {key, Catalyst.Flex.Harness.persistent_snapshot(key)}
    end)
  end

  defp restore_shell_persistent(snapshot) do
    Enum.each(snapshot, fn {key, value} ->
      Catalyst.Flex.Harness.restore_persistent(key, value)
    end)
  end

  defp track_session(id) do
    key = {__MODULE__, :tracked_sessions}
    tracked = Process.get(key, MapSet.new())

    case MapSet.member?(tracked, id) do
      true ->
        :ok

      false ->
        Process.put(key, MapSet.put(tracked, id))
        ExUnit.Callbacks.on_exit(fn -> Catalyst.Session.Manager.stop(id) end)
    end
  end
end
