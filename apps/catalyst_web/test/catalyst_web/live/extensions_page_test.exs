defmodule CatalystWeb.ExtensionsPageTest do
  # async: false — drives the global Extensions registry and the shared
  # extensions dir (same reasoning as ShellLiveTest / ExtensionsTest).
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.Context.Registry, as: ContextRegistry
  alias Catalyst.Extensions
  alias Catalyst.Model
  alias Catalyst.Session.Server
  alias CatalystWeb.Pages.ExtensionsPage

  @probe_source ~S'''
  defmodule Catalyst.Ext.PanelProbeTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "panel_probe"
    @impl true
    def description, do: "extensions panel test tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end
  '''

  defp install_probe! do
    File.mkdir_p!(Extensions.dir())
    path = Path.join(Extensions.dir(), "panel_probe.ex")
    File.write!(path, @probe_source)
    {:ok, _summary} = Extensions.load_file(path)

    on_exit(fn ->
      Extensions.uninstall("panel_probe")
      File.rm(path)
      File.rm(path <> ".disabled")
    end)

    path
  end

  # Panel actions run in a supervised task; poll the condition (and the view,
  # so the handle_info result gets rendered) instead of racing it.
  defp wait_until(fun, tries \\ 150) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  test "the panel lists loaded extensions and the live registry contents", %{conn: conn} do
    install_probe!()

    {:ok, _view, html} = live(conn, "/extensions")

    # The loaded extension card, with its tool chip and action buttons.
    assert html =~ ~s(data-ext-owner="panel_probe")
    assert html =~ "panel_probe"
    assert html =~ "Disable"

    # Registry introspection: built-in tools, providers, and pages all listed.
    assert html =~ "Live registries"
    assert html =~ "built-in"
    assert html =~ "develop_tool"
    assert html =~ "faux"
    assert html =~ "/extensions"

    # The commands registry has producers: the built-in /cd is seeded there.
    assert html =~ "change the session working directory"

    # The nav now has two built-in pages.
    assert html =~ "Chat"
    assert html =~ "Extensions"
  end

  test "the panel separates owned runtime overlays from effective diagnostics", %{conn: conn} do
    owner = "ui_runtime_overlay"

    assert :ok =
             Catalyst.Prompt.Registry.register_prompt(
               "ui-panel-model",
               "PANEL-RUNTIME-PROMPT",
               owner: owner
             )

    assert :ok =
             Catalyst.Workflow.Registry.register_workflow(
               "ui-panel-workflow",
               Catalyst.Agent.Loop,
               owner: owner
             )

    assert :ok =
             Catalyst.Context.Registry.register_threshold(
               "ui-panel-model",
               12_345,
               owner: owner
             )

    on_exit(fn ->
      Catalyst.Prompt.Registry.unregister_owner(owner)
      Catalyst.Workflow.Registry.unregister_owner(owner)
      Catalyst.Context.Registry.unregister_owner(owner)
    end)

    {:ok, view, html} = live(conn, "/extensions")

    assert html =~ "Effective diagnostics"
    assert html =~ "Owned runtime overlays"

    assert has_element?(
             view,
             ~s([data-runtime-registry="Prompt registry"] code),
             "ui-panel-model"
           )

    assert has_element?(
             view,
             ~s([data-runtime-registry="Workflow registry"] code),
             "ui-panel-workflow"
           )

    assert has_element?(
             view,
             ~s([data-runtime-registry="Context registry"] code),
             "ui-panel-model"
           )

    assert html =~ owner
    assert html =~ "PANEL-RUNTIME-PROMPT"
    assert html =~ "ui-panel-workflow"
    assert html =~ "12345"
  end

  test "custom context policies defer threshold diagnostics without invoking callbacks" do
    previous_policy =
      Enum.find(ContextRegistry.runtime_entries(), &(&1.key == {:policy, :default}))

    ContextRegistry.unregister_policy()

    on_exit(fn ->
      ContextRegistry.unregister_policy()

      case previous_policy do
        nil -> :ok
        entry -> ContextRegistry.register_policy(entry.value, owner: entry.owner)
      end
    end)

    assert :ok =
             ContextRegistry.register_policy(CatalystWeb.Test.ContextDiagnosticsPolicy,
               owner: :extensions_page_test
             )

    model = %Model{id: "diagnostic-model", api: "diagnostic", context_window: 100_000}
    panel = ExtensionsPage.panel_data(model, [])
    policy = Enum.find(panel.effective, &(&1.label == "Context policy"))
    threshold = Enum.find(panel.effective, &(&1.label == "Context threshold"))

    assert policy.value == CatalystWeb.Test.ContextDiagnosticsPolicy
    assert threshold.value == "resolved per request by custom policy"
    assert threshold.source == policy.source

    ContextRegistry.unregister_policy()
    builtin = ExtensionsPage.panel_data(model, [])
    builtin_threshold = Enum.find(builtin.effective, &(&1.label == "Context threshold"))

    assert is_integer(builtin_threshold.value)
    assert builtin_threshold.source == :builtin
    assert builtin_threshold.note =~ "unanchored baseline"

    with_request =
      ExtensionsPage.panel_data(model, [], %{
        context_status: %{
          threshold: 85_000,
          threshold_source: :builtin,
          anchored: true
        },
        run_metadata: %{context: %{model_id: "run-snapshot-model"}}
      })

    request_threshold =
      Enum.find(with_request.effective, &(&1.label == "Last request threshold"))

    assert request_threshold.value == 85_000
    assert request_threshold.source == :builtin
    assert request_threshold.note == "anchored for run-snapshot-model"
  end

  test "safe mode shows the shell banner and 'Load extensions now' recovers", %{conn: conn} do
    :persistent_term.put({Catalyst.Extensions, :boot_status}, {:safe_mode, :crash_detected})
    on_exit(fn -> :persistent_term.put({Catalyst.Extensions, :boot_status}, :ok) end)

    # The banner shows on every page and links to the panel.
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Extensions were not loaded"
    assert html =~ "previous boot crashed while extensions were active"

    {:ok, view, html} = live(conn, "/extensions")
    assert html =~ "Load extensions now"

    # Recovery: an explicit successful load clears safe mode (empty dir → ok).
    view |> element("button", "Load extensions now") |> render_click()
    assert wait_until(fn -> Catalyst.Extensions.boot_status() == :ok end)
    assert wait_until(fn -> not (render(view) =~ "Load extensions now") end)

    refute render(view) =~ "Extensions were not loaded"
  end

  test "disable and enable round-trip through the panel buttons", %{conn: conn} do
    path = install_probe!()

    {:ok, view, _html} = live(conn, "/extensions")

    view
    |> element(~s([data-ext-owner="panel_probe"] button), "Disable")
    |> render_click()

    assert wait_until(fn -> Extensions.fetch("panel_probe") == :error end)
    assert wait_until(fn -> render(view) =~ "Enable" end)
    assert File.exists?(path <> ".disabled")

    view
    |> element(~s([data-ext-owner="panel_probe"] button), "Enable")
    |> render_click()

    assert wait_until(fn -> match?({:ok, _}, Extensions.fetch("panel_probe")) end)
    assert wait_until(fn -> render(view) =~ "Enabled panel_probe" end)
    assert File.exists?(path)
  end

  test "an external source is shown as reload-only", %{conn: conn} do
    external_dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst_panel_external_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(external_dir)
    path = Path.join(external_dir, "external_panel.ex")
    File.write!(path, @probe_source)
    assert {:ok, _summary} = Extensions.load_file(path)

    on_exit(fn ->
      Extensions.uninstall("external_panel")
      File.rm_rf!(external_dir)
    end)

    {:ok, view, _html} = live(conn, "/extensions")
    card = ~s([data-ext-owner="external_panel"])

    assert has_element?(view, card, "external source")
    assert has_element?(view, card <> " button", "Reload")
    refute has_element?(view, card <> " button", "Disable")
    refute has_element?(view, card <> " button", "Roll back")
  end

  test "reload all reports its result in a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/extensions")

    view |> element("button", "Reload all") |> render_click()

    assert wait_until(fn -> render(view) =~ "Reloaded" end)
  end

  test "patching to the panel and back preserves the chat transcript", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = submit_prompt(view, "panel roundtrip probe")
    assert html =~ "panel roundtrip probe"

    render_patch(view, "/extensions")
    html = render_patch(view, "/")

    # Stream items live only in the DOM the panel replaced — without the
    # replay in change_page/2 the transcript would come back empty.
    assert html =~ "panel roundtrip probe"
  end

  defp session_id(view) do
    html = view |> element("#catalyst-shell") |> render()
    [_, id] = Regex.run(~r/data-session-id="([^"]+)"/, html)
    id
  end

  defp submit_prompt(view, prompt) do
    id = session_id(view)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    view
    |> form("#chat-form", %{"message" => prompt})
    |> render_submit()

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5_000
    render(view)
  end
end
