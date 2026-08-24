defmodule CatalystWeb.FeatureControlsTest do
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.LLM.OpenAICodex.CatalogCache
  alias Catalyst.Session.{Manager, Server}

  @codex_prefs_ptr {CatalystWeb.ShellLive, :codex_prefs}
  @workflow_prefs_ptr {CatalystWeb.ShellLive, :workflow_prefs}

  defmodule BlockingWorkflow do
    @behaviour Catalyst.Workflow

    @impl true
    def run(_prompts, context, config, _emit) do
      pid = Keyword.fetch!(config.opts, :feature_controls_test_pid)
      ref = Keyword.fetch!(config.opts, :feature_controls_ref)
      send(pid, {:blocking_workflow_started, ref, self()})

      receive do
        {:release_blocking_workflow, ^ref} -> {:ok, [], context}
      end
    end
  end

  setup do
    previous_models = CatalogCache.models()
    previous_codex_prefs = :persistent_term.get(@codex_prefs_ptr, :not_set)
    previous_workflow_prefs = :persistent_term.get(@workflow_prefs_ptr, :not_set)

    :ok = CatalogCache.reset()
    :persistent_term.erase(@workflow_prefs_ptr)

    on_exit(fn ->
      restore_prefs(@codex_prefs_ptr, previous_codex_prefs)
      restore_prefs(@workflow_prefs_ptr, previous_workflow_prefs)
      restore_catalog(previous_models)
      Application.delete_env(:catalyst_web, :grok_login_fun)
    end)

    :ok
  end

  test "Grok 4.6 selects the direct subscription provider and SuperGrok auth", %{conn: conn} do
    parent = self()

    Application.put_env(:catalyst_web, :grok_login_fun, fn ->
      send(parent, :grok_login_called)
      {:ok, "xai-user"}
    end)

    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    assert has_element?(view, "#codex-opts option[value='grok-4.6']", "Grok 4.6")

    view
    |> form("#codex-opts")
    |> render_change(%{"model" => "grok-4.6", "effort" => "xhigh"})

    snapshot = Server.state(pid)
    assert snapshot.model.id == "grok-4.6"
    assert snapshot.model.api == "grok-subscription-chat-completions"
    assert snapshot.model.provider == "grok-subscription"
    assert snapshot.model.context_window == 500_000
    assert snapshot.opts[:reasoning_effort] == "xhigh"
    refute Keyword.has_key?(snapshot.opts, :service_tier)
    refute Keyword.has_key?(snapshot.opts, :transport)
    refute has_element?(view, "#codex-fast-toggle")
    assert has_element?(view, "#login-button", "Sign in to SuperGrok")

    view |> element("#login-button") |> render_click()
    assert_receive :grok_login_called, 1_000
    assert has_element?(view, ~s(#logout-button[title="Sign out of SuperGrok"]))
  end

  test "the picker includes bundled templates and external-agent workflows", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#workflow-form")
    assert has_element?(view, "#workflow-select option[value='research']", "(template)")
    assert has_element?(view, "#workflow-select option[value='build-review']", "(template)")
    assert has_element?(view, "#workflow-select option[value='secure-build']", "(template)")
    assert has_element?(view, "#workflow-select option[value='claude-code']")
    assert has_element?(view, "#workflow-select option[value='acp/claude']")
  end

  test "switching a populated session to a bundled backend starts fresh", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    assert :ok =
             Server.append_recovered(pid, %Catalyst.Message.Assistant{
               content: Catalyst.Content.text("existing"),
               timestamp: Catalyst.Message.now()
             })

    view |> form("#workflow-form") |> render_change(%{"workflow" => "claude-code"})

    new_pid = session_pid(view)
    refute new_pid == pid
    assert Server.state(new_pid).opts[:workflow] == "claude-code"
    assert Server.state(new_pid).messages == []
  end

  test "switching an active first run to a bundled backend starts fresh", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)
    ref = make_ref()

    assert :ok =
             Server.configure(pid,
               opts: [
                 loop: BlockingWorkflow,
                 feature_controls_test_pid: self(),
                 feature_controls_ref: ref
               ]
             )

    assert :ok = Server.prompt(pid, "first")
    assert_receive {:blocking_workflow_started, ^ref, worker}, 1_000
    assert %{running: true, messages: []} = Server.state(pid)

    view |> form("#workflow-form") |> render_change(%{"workflow" => "claude-code"})

    new_pid = session_pid(view)
    refute new_pid == pid
    assert Server.state(new_pid).opts[:workflow] == "claude-code"
    assert Server.state(new_pid).messages == []

    send(worker, {:release_blocking_workflow, ref})
  end

  test "a stale saved workflow preference self-heals while bundled options remain", %{conn: conn} do
    :persistent_term.put(@workflow_prefs_ptr, %{workflow: "ghost"})

    {:ok, view, _html} = live(conn, "/")

    refute Keyword.has_key?(Server.state(session_pid(view)).opts, :workflow)
    assert :persistent_term.get(@workflow_prefs_ptr) == %{workflow: nil}
    assert has_element?(view, "#workflow-select option[value=''][selected]")
    refute has_element?(view, "#workflow-select option[value='ghost']")
  end

  defp session_pid(view) do
    {:ok, pid} = Manager.whereis(session_id(view))
    pid
  end

  defp restore_prefs(pointer, :not_set), do: :persistent_term.erase(pointer)
  defp restore_prefs(pointer, prefs), do: :persistent_term.put(pointer, prefs)

  defp restore_catalog([]), do: CatalogCache.reset()

  defp restore_catalog(models) do
    :ok = CatalogCache.reset()
    CatalogCache.store(models)
  end
end
