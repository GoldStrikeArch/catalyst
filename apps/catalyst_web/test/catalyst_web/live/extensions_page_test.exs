defmodule CatalystWeb.ExtensionsPageTest do
  # async: false — drives the global Extensions registry and the shared
  # extensions dir (same reasoning as ShellLiveTest / ExtensionsTest).
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Context.Registry, as: ContextRegistry
  alias Catalyst.Extensions
  alias Catalyst.Model
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

  test "the panel lists loaded extensions and the live registry contents", %{conn: conn} do
    install_probe!()

    {:ok, view, _html} = live(conn, "/extensions")

    # The loaded extension card, with its tool chip and action buttons.
    card = ~s(#loaded-extensions [data-ext-owner="panel_probe"])
    assert has_element?(view, card, "panel_probe")
    assert has_element?(view, card <> " button", "Disable")

    # Registry introspection: built-in tools, providers, and pages all listed.
    assert has_element?(view, "#live-registries", "Live registries")
    assert has_element?(view, "#live-registries", "built-in")
    assert has_element?(view, "#live-registries code", "develop_tool")
    assert has_element?(view, "#live-registries code", "faux")
    assert has_element?(view, "#live-registries code", "/extensions")

    # The commands registry has producers: the built-in /cd is seeded there.
    assert has_element?(view, "#live-registries", "change the session working directory")

    # The nav now has two built-in pages.
    assert has_element?(view, "#shell-page-nav", "Chat")
    assert has_element?(view, "#shell-page-nav", "Extensions")
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

    {:ok, view, _html} = live(conn, "/extensions")

    assert has_element?(view, "#effective-extension-diagnostics", "Effective diagnostics")
    assert has_element?(view, "#runtime-overlay-registries", "Owned runtime overlays")

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

    assert has_element?(view, "#runtime-overlay-registries", owner)

    assert has_element?(
             view,
             ~s([data-runtime-registry="Prompt registry"]),
             "PANEL-RUNTIME-PROMPT"
           )

    assert has_element?(
             view,
             ~s([data-runtime-registry="Workflow registry"]),
             "ui-panel-workflow"
           )

    assert has_element?(view, ~s([data-runtime-registry="Context registry"]), "12345")
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
    assert builtin_threshold.note =~ "coarse baseline"

    with_request =
      ExtensionsPage.panel_data(model, [], %{
        context_status: %{
          threshold: 85_000,
          threshold_source: :builtin
        },
        run_metadata: %{context: %{model_id: "run-snapshot-model"}}
      })

    request_threshold =
      Enum.find(with_request.effective, &(&1.label == "Last request threshold"))

    assert request_threshold.value == 85_000
    assert request_threshold.source == :builtin
    assert request_threshold.note == "estimated for run-snapshot-model"
  end

  test "panel data is built on the bounded snapshot" do
    install_probe!()

    panel = ExtensionsPage.panel_data()
    probe = Enum.find(panel.loaded, &(&1.owner == "panel_probe"))

    # Owner entries carry the snapshot/0 shape: degraded status + bounded count.
    assert probe.status == :ok
    assert probe.purge_failures == []
    assert is_integer(probe.process_count) or probe.process_count == :unknown

    # Tool rows come from the registry table (never extension name/0 calls),
    # with built-ins (nil owner) and extension tools both attributed.
    assert Enum.any?(panel.tools, &(&1.name == "panel_probe" and &1.owner == "panel_probe"))
    assert Enum.any?(panel.tools, &(&1.name == "develop_tool" and is_nil(&1.owner)))
    assert panel.boot_status == Extensions.boot_status()
  end

  test "a degraded owner is rendered with a badge naming the failed subsystems" do
    degraded = %{
      owner: "degraded_probe",
      path: nil,
      managed?: false,
      tools: [],
      modules: [],
      metadata: %{},
      status: :degraded,
      purge_failures: [{{Catalyst.Hooks, :unregister, 1}, {:exit, :boom}}],
      process_count: :unknown
    }

    panel = %{ExtensionsPage.panel_data() | loaded: [degraded]}

    html =
      render_component(&ExtensionsPage.render/1, ext_panel: panel, ext_action: nil)

    # render_component/2 yields a string, so anchor with LazyHTML selectors.
    doc = LazyHTML.from_fragment(html)
    card_text = doc |> LazyHTML.query(~s([data-ext-owner="degraded_probe"])) |> LazyHTML.text()
    badge = doc |> LazyHTML.query(~s([data-degraded-owner="degraded_probe"])) |> LazyHTML.text()

    assert badge =~ "degraded"
    assert card_text =~ "a previous purge left residue"
    assert card_text =~ "Catalyst.Hooks.unregister/1"
  end

  test "safe mode shows the shell banner and 'Load extensions now' recovers", %{conn: conn} do
    :persistent_term.put({Catalyst.Extensions, :boot_status}, {:safe_mode, :crash_detected})
    on_exit(fn -> :persistent_term.put({Catalyst.Extensions, :boot_status}, :ok) end)

    # The banner shows on every page and links to the panel; the wording is
    # the single core presenter, Extensions.describe_boot_status/1.
    {:ok, chat_view, _html} = live(conn, "/")

    assert has_element?(
             chat_view,
             "#extension-boot-status",
             "Safe mode — extensions were not loaded"
           )

    assert has_element?(
             chat_view,
             "#extension-boot-status",
             "previous boot died while extensions were active"
           )

    {:ok, view, _html} = live(conn, "/extensions")
    assert has_element?(view, "#extension-boot-problem button", "Load extensions now")

    # Recovery: an explicit successful load clears safe mode (empty dir → ok).
    view |> element("#extension-boot-problem button", "Load extensions now") |> render_click()
    wait_until(fn -> Catalyst.Extensions.boot_status() == :ok end)
    wait_until(fn -> not has_element?(view, "#extension-boot-problem") end)

    refute has_element?(view, "#extension-boot-status")
  end

  test "disable and enable round-trip through the panel buttons", %{conn: conn} do
    path = install_probe!()

    {:ok, view, _html} = live(conn, "/extensions")

    view
    |> element(~s([data-ext-owner="panel_probe"] button), "Disable")
    |> render_click()

    wait_until(fn -> Extensions.fetch("panel_probe") == :error end)

    wait_until(fn ->
      has_element?(view, ~s([data-ext-owner="panel_probe"] button), "Enable")
    end)

    assert File.exists?(path <> ".disabled")

    view
    |> element(~s([data-ext-owner="panel_probe"] button), "Enable")
    |> render_click()

    wait_until(fn -> match?({:ok, _}, Extensions.fetch("panel_probe")) end)
    wait_until(fn -> has_element?(view, "#flash-info", "Enabled panel_probe") end)
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

    wait_until(fn -> has_element?(view, "#flash-info, #flash-error", "Reloaded") end)
  end

  test "patching to the panel and back preserves the chat transcript", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    submit_prompt(view, "panel roundtrip probe")
    assert has_element?(view, "#message-stream", "panel roundtrip probe")

    render_patch(view, "/extensions")
    render_patch(view, "/")

    # Stream items live only in the DOM the panel replaced — without the
    # replay in change_page/2 the transcript would come back empty.
    assert has_element?(view, "#message-stream", "panel roundtrip probe")
  end
end
