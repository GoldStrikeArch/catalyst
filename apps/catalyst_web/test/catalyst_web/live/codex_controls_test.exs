defmodule CatalystWeb.CodexControlsTest do
  # async: false — stubs the login fun and writes the shared codex prefs.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.LLM.Registry
  alias Catalyst.Session.{Manager, Server}

  @codex_api "openai-codex-responses"
  @capture_pid_env :model_request_capture_pid

  defmodule RequestCaptureProvider do
    @moduledoc false
    @behaviour Catalyst.LLM.Provider

    alias Catalyst.{Content, Message, Usage}
    alias Catalyst.LLM.OpenAICodex.Request

    @capture_pid_env :model_request_capture_pid

    @impl true
    def stream(model, context, opts, _sink) do
      body = Request.build(model, context, opts)
      send(Application.fetch_env!(:catalyst_web, @capture_pid_env), {:codex_request, body})

      assistant = %Message.Assistant{
        content: [%Content.Text{text: "captured"}],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: %Usage{},
        stop_reason: :stop,
        timestamp: Message.now()
      }

      {:ok, assistant}
    end
  end

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
    assert has_element?(view, "#codex-opts option[value='gpt-5.6-sol']")
    assert has_element?(view, "#codex-opts option[value='gpt-5.6-terra']")
    assert has_element?(view, "#codex-opts option[value='gpt-5.6-luna']")
    pid = session_pid(view)

    # The codex session starts with the default settings already applied.
    snap = Server.state(pid)
    assert snap.model.id == OpenAICodex.default_model_id()
    assert snap.opts[:reasoning_effort] == "medium"
    assert snap.opts[:transport] == "auto"
    refute snap.opts[:service_tier]

    view
    |> form("#codex-opts")
    |> render_change(%{
      "model" => "gpt-5.6-sol",
      "effort" => "ultra",
      "transport" => "websocket"
    })

    snap = Server.state(pid)
    assert snap.model.id == "gpt-5.6-sol"
    assert snap.opts[:reasoning_effort] == "ultra"
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

  test "a Luna selection reaches the provider request for a newly created chat", %{conn: conn} do
    {:ok, previous_provider} = Registry.fetch_config(@codex_api)
    Application.put_env(:catalyst_web, @capture_pid_env, self())
    :ok = Registry.register_provider(@codex_api, RequestCaptureProvider)

    on_exit(fn ->
      Application.delete_env(:catalyst_web, @capture_pid_env)
      Registry.register_provider(@codex_api, previous_provider)
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("#new-session-button") |> render_click()

    view
    |> form("#codex-opts")
    |> render_change(%{"model" => "gpt-5.6-luna"})

    assert Server.state(session_pid(view)).model.id == "gpt-5.6-luna"

    submit_prompt(view, "What is your model name?")
    assert_receive {:codex_request, body}

    assert body["model"] == "gpt-5.6-luna"
    assert body["instructions"] =~ ~s(exact model identifier "gpt-5.6-luna")
    refute body["instructions"] =~ "gpt-5.4"
  end
end
