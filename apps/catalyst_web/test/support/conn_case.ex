defmodule CatalystWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Besides the connection, every test gets session-leak protection: mounting
  `CatalystWeb.ShellLive` starts a `Catalyst.Session.Server` that deliberately
  outlives the LiveView, so the setup snapshots the session supervisor's
  children and `on_exit` terminates any session started during the test.

  Shared LiveView helpers for the shell (`session_id/1`, `submit_prompt/2`,
  `wait_until/2`) are importable in every test through
  `import CatalystWeb.ConnCase`.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  @session_supervisor Catalyst.Session.DynamicSupervisor

  using do
    quote do
      # The default endpoint for testing
      @endpoint CatalystWeb.Endpoint

      use CatalystWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CatalystWeb.ConnCase
    end
  end

  setup _tags do
    preexisting = session_pids()
    ExUnit.Callbacks.on_exit(fn -> stop_sessions_started_since(preexisting) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Return the session id exposed by a mounted shell (`#catalyst-shell`)."
  @spec session_id(struct()) :: String.t()
  def session_id(view) do
    html =
      view |> Phoenix.LiveViewTest.element("#catalyst-shell") |> Phoenix.LiveViewTest.render()

    case Regex.run(~r/data-session-id="([^"]+)"/, html) do
      [_, id] when id != "" -> id
      _no_session -> flunk("mounted shell did not expose a session id")
    end
  end

  @doc """
  Submit a chat prompt and block until the session broadcasts its terminal
  `AgentEnd`, then return the re-rendered HTML.
  """
  @spec submit_prompt(struct(), String.t()) :: String.t()
  def submit_prompt(view, prompt) do
    id = session_id(view)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Catalyst.Session.Server.topic(id))

    view
    |> Phoenix.LiveViewTest.form("#chat-form", %{"message" => prompt})
    |> Phoenix.LiveViewTest.render_submit()

    # Broadcasts are tagged with the broadcasting session's id.
    receive do
      {:agent_event, ^id, %Catalyst.Agent.Event.AgentEnd{}} ->
        Phoenix.LiveViewTest.render(view)
    after
      5_000 -> flunk("session #{id} did not emit AgentEnd within 5 seconds")
    end
  end

  @doc """
  Sanctioned bounded poll for conditions with no observable message to the
  test process (e.g. panel actions running in supervised tasks). Returns `:ok`
  once `fun` is truthy; flunks after `tries * 20ms`.
  """
  @spec wait_until((-> boolean()), pos_integer()) :: :ok
  def wait_until(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> retry_wait(fun, tries)
    end
  end

  defp retry_wait(fun, tries) do
    Process.sleep(20)
    wait_until(fun, tries - 1)
  end

  defp session_pids do
    @session_supervisor
    |> DynamicSupervisor.which_children()
    |> MapSet.new(fn {_id, pid, _type, _mods} -> pid end)
  end

  # Stop only the sessions this test created: shell mounts deliberately leave
  # their session running (sessions outlive LiveViews), so without this every
  # `live(conn, ...)` in the suite leaks an orphaned Session.Server.
  defp stop_sessions_started_since(preexisting) do
    Enum.each(session_pids(), fn pid ->
      case MapSet.member?(preexisting, pid) do
        true -> :ok
        false -> DynamicSupervisor.terminate_child(@session_supervisor, pid)
      end
    end)
  end
end
