defmodule CatalystWeb.CodexControlsTest do
  # async: false — stubs the login fun and writes the shared codex prefs.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.Session.{Manager, Server}

  setup do
    on_exit(fn -> :persistent_term.erase({CatalystWeb.ShellLive, :codex_prefs}) end)
    :ok
  end

  defp session_pid(view) do
    {:ok, pid} = Manager.whereis(session_id(view))
    pid
  end

  test "the run controls reconfigure the live session in place", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#codex-opts")
    pid = session_pid(view)

    # The codex session starts with the default settings already applied.
    snap = Server.state(pid)
    assert snap.model.id == OpenAICodex.default_model_id()
    assert snap.opts[:reasoning_effort] == "medium"
    assert snap.opts[:transport] == "auto"
    refute snap.opts[:service_tier]

    view
    |> form("#codex-opts")
    |> render_change(%{"model" => "gpt-5.5", "effort" => "high", "transport" => "websocket"})

    snap = Server.state(pid)
    assert snap.model.id == "gpt-5.5"
    assert snap.opts[:reasoning_effort] == "high"
    assert snap.opts[:transport] == "websocket"

    # Fast → service_tier "priority"; toggling off DELETES the key.
    view |> element("#codex-fast-toggle") |> render_click()
    assert Server.state(pid).opts[:service_tier] == "priority"

    view |> element("#codex-fast-toggle") |> render_click()
    refute Keyword.has_key?(Server.state(pid).opts, :service_tier)

    # Reconfigured in place: same session process, transcript untouched.
    assert session_pid(view) == pid
  end

  test "fast is clamped off when switching to a model without the priority tier", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    view |> element("#codex-fast-toggle") |> render_click()
    assert Server.state(pid).opts[:service_tier] == "priority"

    view |> form("#codex-opts") |> render_change(%{"model" => "gpt-5.4-mini"})

    refute Keyword.has_key?(Server.state(pid).opts, :service_tier)
    refute has_element?(view, "#codex-fast-toggle")
  end
end
