defmodule CatalystWeb.WorkbenchHostLiveTest do
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Auth.TokenStore
  alias Catalyst.Contracts.Workbench.V1
  alias Catalyst.Extension.Manifest
  alias Catalyst.ExtensionAPI
  alias Catalyst.Extensions.GenerationCompiler
  alias Catalyst.LLM.ProviderConfig
  alias Catalyst.LLM.Registry, as: LLMRegistry
  alias Catalyst.Model
  alias Catalyst.Session.{Catalog, Manager}

  alias Catalyst.Runtime.{
    ArtifactSet,
    Artifacts,
    ExtensionPoints,
    GenerationStore,
    Generations,
    Leases,
    PermissionPolicy
  }

  alias CatalystWeb.ShellLive.Settings
  alias CatalystWeb.UI.Registry
  alias CatalystWeb.Workbench

  @preference_keys [
    {CatalystWeb.ShellLive, :codex_prefs},
    {CatalystWeb.ShellLive, :ui_prefs},
    {CatalystWeb.ShellLive, :machine_prefs},
    {CatalystWeb.ShellLive, :workflow_prefs}
  ]
  @png_bytes Base.decode64!(
               "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
             )

  defmodule DenyWrites do
    @behaviour Catalyst.Contracts.PermissionPolicy.V1

    @impl true
    def authorize(%{operation: :write}, _principal, _resource, _context),
      do: {:deny, :read_only_workspace}

    def authorize(_action, _principal, _resource, _context), do: :allow
  end

  defmodule WorkbenchProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :unused}
  end

  defmodule WorkbenchCatalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @entry %{
      id: "workbench-model",
      name: "Workbench Model",
      efforts: ["low", "high"],
      default_effort: "low",
      fast?: true
    }

    @impl true
    def default_model_id, do: @entry.id

    @impl true
    def catalog_snapshot(_id), do: %{models: [@entry], selected: @entry}

    @impl true
    def model(id),
      do: %Model{id: id, api: "workbench-fixture-api", provider: "workbench-fixture"}
  end

  defmodule WorkbenchAuth do
    @behaviour Catalyst.Auth.Flow

    @impl true
    def provider_id, do: "workbench-fixture-auth"

    @impl true
    def label, do: "Workbench Fixture"

    @impl true
    def login(_opts), do: {:error, :use_test_override}

    @impl true
    def refresh(credentials), do: {:ok, credentials}
  end

  setup do
    :ok = Generations.clear()

    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_workbench_live_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), "hello\n")

    on_exit(fn ->
      ExtensionPoints.purge_owner("workbench_policy_test")
      Generations.clear()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "workspace effects obey the effective permission policy", %{conn: conn, root: root} do
    assert :ok =
             "workbench_policy_test"
             |> ExtensionAPI.new()
             |> ExtensionAPI.claim(PermissionPolicy.key(), DenyWrites,
               contract: Catalyst.Contracts.PermissionPolicy.V1.ref(),
               priority: 900
             )

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    wait_until(fn -> has_element?(view, ~s([data-file-path="lib/example.ex"])) end)
    view |> element(~s([data-file-path="lib/example.ex"])) |> render_click()
    wait_until(fn -> has_element?(view, "#editor-content", "hello") end)

    view
    |> form("#editor-form", %{"editor" => %{"content" => "blocked\n"}})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#command-output", "read_only_workspace") end)
    assert File.read!(Path.join(root, "lib/example.ex")) == "hello\n"
  end

  test "the IDE opens, edits, saves, and runs a workspace task", %{conn: conn, root: root} do
    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#workbench-host[data-workbench-owner=builtin]")
    assert has_element?(view, "#ide-workbench")
    assert has_element?(view, "#workbench-agent-chat-link[href='/']")
    assert has_element?(view, "#workbench-agent-pane-link[href='/']")

    wait_until(fn -> has_element?(view, ~s([data-file-path="lib/example.ex"])) end)
    view |> element(~s([data-file-path="lib/example.ex"])) |> render_click()
    wait_until(fn -> has_element?(view, "#editor-content", "hello") end)

    view
    |> form("#editor-form", %{"editor" => %{"content" => "updated\n"}})
    |> render_change()

    view
    |> form("#editor-form", %{"editor" => %{"content" => "updated\n"}})
    |> render_submit()

    wait_until(fn -> File.read!(Path.join(root, "lib/example.ex")) == "updated\n" end)

    view
    |> form("#terminal-form", %{"terminal" => %{"command" => "printf workbench-ok"}})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#command-output", "workbench-ok") end)

    view |> element("#command-palette-toggle") |> render_click()
    assert has_element?(view, "#command-palette")
    assert has_element?(view, "#palette-chat")
  end

  test "the root chat product opens a host-owned session and submits a prompt", %{
    conn: conn,
    root: root
  } do
    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#workbench-host[data-workbench-owner=builtin]")
    assert has_element?(view, "#chat-workbench")
    assert has_element?(view, "#workbench-chat-form")
    assert has_element?(view, "#workbench-chat-ide-link[href='/ide']")
    assert has_element?(view, "#workbench-nav-legacy[href='/legacy-chat']")
    assert has_element?(view, "#workbench-nav-extensions[href='/extensions']")

    wait_until(fn ->
      has_element?(view, "#workbench-chat-status[data-status=ready]") and
        has_element?(view, "#chat-workbench[data-session-id]")
    end)

    view
    |> form("#workbench-chat-form", %{"chat" => %{"message" => "list the files"}})
    |> render_submit()

    wait_until(fn ->
      has_element?(
        view,
        "#workbench-chat-messages [data-role=user]",
        "list the files"
      )
    end)

    wait_until(fn ->
      has_element?(
        view,
        "#workbench-chat-messages [data-role=assistant]",
        "offline Demo provider"
      )
    end)

    view |> element("#workbench-chat-apply-active") |> render_click()

    assert has_element?(
             view,
             "#workbench-chat-messages [data-role=user]",
             "list the files"
           )
  end

  test "the root chat resumes its durable session after the session process restarts", %{
    conn: conn,
    root: root
  } do
    prior_reattach = Application.fetch_env(:catalyst_web, :reattach_sessions)
    prior_catalog = Application.fetch_env(:catalyst, :session_catalog_path)

    catalog_path =
      Path.join(
        System.tmp_dir!(),
        "catalyst_workbench_catalog_#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:catalyst_web, :reattach_sessions, true)
    Application.put_env(:catalyst, :session_catalog_path, catalog_path)

    on_exit(fn ->
      restore_env(:catalyst_web, :reattach_sessions, prior_reattach)
      restore_env(:catalyst, :session_catalog_path, prior_catalog)
      File.rm(catalog_path)
    end)

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/")

    wait_until(fn -> has_element?(view, "#workbench-chat-status[data-status=ready]") end)
    assert {:ok, %{id: session_id, cwd: ^root}} = Catalog.most_recent()

    view
    |> form("#workbench-chat-form", %{"chat" => %{"message" => "remember this session"}})
    |> render_submit()

    wait_until(fn ->
      has_element?(
        view,
        "#workbench-chat-messages [data-role=assistant]",
        "offline Demo provider"
      )
    end)

    {:ok, pid} = Manager.whereis(session_id)
    ref = Process.monitor(pid)
    assert :ok = Manager.stop(session_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    second_conn = build_conn() |> init_test_session(%{"workbench_workspace" => root})
    {:ok, resumed, _html} = live(second_conn, "/")

    wait_until(fn ->
      has_element?(resumed, "#chat-workbench[data-session-id='#{session_id}']") and
        has_element?(
          resumed,
          "#workbench-chat-messages [data-role=user]",
          "remember this session"
        )
    end)
  end

  test "the previous shell chat remains available as an explicit recovery route", %{
    conn: conn,
    root: root
  } do
    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/legacy-chat")

    assert has_element?(view, "#shell-header")
    refute has_element?(view, "#chat-workbench")
  end

  test "the root chat discovers provider controls and delegates authentication to the host", %{
    conn: conn,
    root: root
  } do
    prior_preferences =
      Map.new(@preference_keys, &{&1, :persistent_term.get(&1, :not_set)})

    prior_login = Application.fetch_env(:catalyst_web, :auth_login_fun)
    parent = self()

    config = %ProviderConfig{
      id: "workbench-fixture",
      module: WorkbenchProvider,
      name: "Workbench Fixture",
      catalog: WorkbenchCatalog,
      auth: WorkbenchAuth,
      controls: %{transports: ["auto", "sse"]}
    }

    assert :ok = LLMRegistry.register_provider("workbench-fixture-api", config)

    assert :ok =
             Settings.persist_workbench(%{
               provider: "workbench-fixture",
               model: "workbench-model",
               effort: "low",
               fast: false,
               transport: "auto",
               workflow: nil,
               quiet: false,
               computer_use: false
             })

    Application.put_env(:catalyst_web, :auth_login_fun, fn provider ->
      send(parent, {:workbench_login, provider})
      TokenStore.put(provider, %{access_token: "fixture-token"})
    end)

    on_exit(fn ->
      LLMRegistry.unregister_provider("workbench-fixture-api")
      TokenStore.delete(WorkbenchAuth.provider_id())
      restore_env(:catalyst_web, :auth_login_fun, prior_login)
      Enum.each(prior_preferences, fn {key, value} -> restore_persistent(key, value) end)
    end)

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/")

    wait_until(fn ->
      has_element?(view, "#workbench-chat-status[data-status=ready]") and
        has_element?(view, "#workbench-model-select option", "Workbench Model")
    end)

    assert has_element?(view, "#workbench-auth-login")
    assert has_element?(view, "#workbench-effort-select option[value=high]")
    assert has_element?(view, "#workbench-transport-select option[value=sse]")
    assert has_element?(view, "#workbench-workflow-select")

    view
    |> form("#workbench-controls-form", %{
      "controls" => %{"effort" => "high", "transport" => "sse", "workflow" => ""}
    })
    |> render_change()

    view |> element("#workbench-computer-toggle") |> render_click()

    wait_until(fn ->
      preferences = Settings.load_workbench()

      preferences.effort == "high" and preferences.transport == "sse" and
        preferences.computer_use
    end)

    view |> element("#workbench-auth-login") |> render_click()
    assert_receive {:workbench_login, "workbench-fixture-auth"}
    wait_until(fn -> has_element?(view, "#workbench-auth-logout") end)

    view |> element("#workbench-auth-logout") |> render_click()
    wait_until(fn -> has_element?(view, "#workbench-auth-login") end)
  end

  test "the chat slot mediates models, threads, file references, and image prompts", %{
    conn: conn,
    root: root
  } do
    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/workbench/chat")

    wait_until(fn -> has_element?(view, "#workbench-chat-status[data-status=ready]") end)

    assert has_element?(view, "#workbench-model-select option")
    assert has_element?(view, "#workbench-thread-sidebar")

    view
    |> form("#workbench-chat-form", %{"chat" => %{"message" => "@exam"}})
    |> render_change()

    wait_until(fn ->
      has_element?(
        view,
        "#workbench-file-search button[phx-value-path='lib/example.ex']"
      )
    end)

    view
    |> element("#workbench-file-search button[phx-value-path='lib/example.ex']")
    |> render_click()

    view
    |> form("#workbench-chat-form", %{
      "chat" => %{"message" => "inspect @lib/example.ex"}
    })
    |> render_submit()

    wait_until(fn ->
      has_element?(
        view,
        "#workbench-chat-messages [data-role=user]",
        "inspect lib/example.ex"
      )
    end)

    wait_until(fn -> has_element?(view, "#workbench-chat-submit") end)

    input =
      file_input(view, "#workbench-chat-form", :image, [
        %{name: "shot.jpg", content: @png_bytes, type: "application/octet-stream"}
      ])

    render_upload(input, "shot.jpg")

    view
    |> form("#workbench-chat-form", %{"chat" => %{"message" => "inspect this image"}})
    |> render_submit()

    wait_until(fn ->
      has_element?(
        view,
        "#workbench-chat-messages [data-role=user] img[src^='/image/']"
      )
    end)

    assert has_element?(view, "#workbench-thread-sidebar [data-current='true']")
  end

  test "managed workbench replacements apply to new mounts while the old mount stays pinned", %{
    conn: conn,
    root: root
  } do
    first = manifest("test.workbench-a")
    assert {:ok, first_generation} = Generations.install("workbench_source", [first])

    first_conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, first_view, _html} = live(first_conn, "/ide")
    assert has_element?(first_view, "#command-output", "test.workbench-a")

    second = manifest("test.workbench-b")
    assert {:ok, _second_generation} = Generations.install("workbench_source", [second])

    assert has_element?(first_view, "#command-output", "test.workbench-a")
    assert Enum.any?(Leases.list(), &(&1.owner == first_view.pid))
    assert {:ok, %{status: :retiring}} = GenerationStore.fetch(first_generation.id)

    second_conn = build_conn() |> init_test_session(%{"workbench_workspace" => root})
    {:ok, second_view, _html} = live(second_conn, "/ide")
    assert has_element?(second_view, "#command-output", "test.workbench-b")
  end

  test "an artifact workbench renders through its exact pinned implementation", %{
    conn: conn,
    root: root
  } do
    install_artifact_workbench!("{__MODULE__, :render}")

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#artifact-workbench")
    assert has_element?(view, "#workbench-host[data-workbench-owner='test.artifact-workbench']")
    refute has_element?(view, "#workbench-error")
  end

  test "an artifact workbench cannot render through an unrelated module", %{
    conn: conn,
    root: root
  } do
    install_artifact_workbench!("{CatalystWeb.Test.WorkbenchTargetA, :render}")

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#workbench-error")
    assert has_element?(view, "#workbench-error-reason", "workbench_render_target_not_pinned")
    refute Enum.any?(Leases.list(), &(&1.owner == view.pid))
  end

  test "a mount pins its render descriptor until an explicit generation remount", %{
    conn: conn,
    root: root
  } do
    target_a_owner = "workbench_target_a_#{System.unique_integer([:positive])}"
    target_b_owner = "workbench_target_b_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Registry.unregister_owner(target_a_owner)
      Registry.unregister_owner(target_b_owner)
    end)

    assert :ok =
             Registry.register_page("ide", CatalystWeb.Test.WorkbenchTargetA,
               owner: target_a_owner
             )

    assert {:ok, _first_generation} =
             Generations.install("workbench_source", [manifest("test.workbench-a")])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")
    wait_until(fn -> has_element?(view, "#workbench-target-a[data-busy='0']") end)

    assert :ok =
             Registry.register_page("ide", CatalystWeb.Test.WorkbenchTargetB,
               owner: target_b_owner
             )

    view |> element("#workbench-target-a-transition") |> render_click()
    assert has_element?(view, "#workbench-target-a")
    refute has_element?(view, "#workbench-target-b")

    assert {:ok, _second_generation} =
             Generations.install("workbench_source", [manifest("test.workbench-b")])

    view |> element("#workbench-target-a-remount") |> render_click()
    assert has_element?(view, "#workbench-target-b")
    refute has_element?(view, "#workbench-target-a")
    assert has_element?(view, "#workbench-host[data-workbench-owner='test.workbench-b']")
  end

  test "a mounted workbench fails closed when its state selects another target id", %{
    conn: conn,
    root: root
  } do
    target_owner = "workbench_target_change_#{System.unique_integer([:positive])}"
    on_exit(fn -> Registry.unregister_owner(target_owner) end)

    assert :ok =
             Registry.register_page("ide", CatalystWeb.Test.WorkbenchTargetA, owner: target_owner)

    assert {:ok, _generation} =
             Generations.install("workbench_source", [manifest("test.workbench-a")])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")
    wait_until(fn -> has_element?(view, "#workbench-target-a[data-busy='0']") end)

    view |> element("#workbench-target-a-change") |> render_click()

    assert has_element?(view, "#workbench-error")
    assert has_element?(view, "#workbench-error-reason", "workbench_render_target_changed")
    refute has_element?(view, "#workbench-target-a")
  end

  test "a mounted host atomically restores into the active workbench", %{conn: conn, root: root} do
    first = manifest("test.workbench-a")
    assert {:ok, first_generation} = Generations.install("workbench_source", [first])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")
    host_pid = view.pid

    wait_until(fn -> has_element?(view, ~s([data-file-path="lib/example.ex"])) end)

    assert Enum.any?(
             Leases.list(),
             &(&1.generation == first_generation.id and &1.owner == host_pid)
           )

    second = manifest("test.workbench-b")
    assert {:ok, second_generation} = Generations.install("workbench_source", [second])

    view |> element("#workbench-apply-active") |> render_click()

    assert view.pid == host_pid
    assert has_element?(view, "#workbench-host[data-workbench-owner='test.workbench-b']")
    assert has_element?(view, "#command-output", "restored workbench test.workbench-b")

    refute Enum.any?(
             Leases.list(),
             &(&1.generation == first_generation.id and &1.owner == host_pid)
           )

    assert Enum.any?(
             Leases.list(),
             &(&1.generation == second_generation.id and &1.owner == host_pid)
           )
  end

  test "a rejected restore keeps the old workbench and releases the candidate lease", %{
    conn: conn,
    root: root
  } do
    first = manifest("test.workbench-a")
    assert {:ok, first_generation} = Generations.install("workbench_source", [first])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")
    host_pid = view.pid
    wait_until(fn -> has_element?(view, ~s([data-file-path="lib/example.ex"])) end)

    rejected = manifest("test.workbench-reject")
    assert {:ok, rejected_generation} = Generations.install("workbench_source", [rejected])

    view |> element("#workbench-apply-active") |> render_click()

    assert has_element?(view, "#workbench-host[data-workbench-owner='test.workbench-a']")
    assert has_element?(view, "#command-output", "mounted workbench test.workbench-a")

    assert Enum.any?(
             Leases.list(),
             &(&1.generation == first_generation.id and &1.owner == host_pid)
           )

    refute Enum.any?(
             Leases.list(),
             &(&1.generation == rejected_generation.id and &1.owner == host_pid)
           )
  end

  test "an invalid managed render target falls back without retaining its lease", %{
    conn: conn,
    root: root
  } do
    broken = manifest("test.workbench-broken")
    assert {:ok, _generation} = Generations.install("workbench_source", [broken])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#workbench-error")
    assert has_element?(view, "#workbench-error-chat-link[href='/legacy-chat']")
    refute Enum.any?(Leases.list(), &(&1.owner == view.pid))
  end

  test "a hanging managed mount is bounded and releases its lease", %{conn: conn, root: root} do
    previous = Application.fetch_env(:catalyst_web, :workbench_callback_timeout)
    Application.put_env(:catalyst_web, :workbench_callback_timeout, 25)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst_web, :workbench_callback_timeout, value)
        :error -> Application.delete_env(:catalyst_web, :workbench_callback_timeout)
      end
    end)

    hanging = manifest("test.workbench-hanging")
    assert {:ok, _generation} = Generations.install("workbench_source", [hanging])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#workbench-error")
    assert has_element?(view, "#workbench-error-reason", "workbench_callback_timeout")
    refute Enum.any?(Leases.list(), &(&1.owner == view.pid))
  end

  defp manifest(id) do
    Manifest.new!(%{
      id: id,
      version: "1.0.0",
      services: [
        %{
          key: Workbench.key(),
          contract: V1.ref(),
          implementation: CatalystWeb.Test.Workbench,
          priority: 900,
          binding: {:pin, :mount}
        }
      ]
    })
  end

  defp install_artifact_workbench!(target) do
    source = """
    defmodule Catalyst.Ext.ArtifactWorkbench do
      @behaviour Catalyst.Contracts.Workbench.V1

      @impl true
      def mount(_context), do: {:ok, %{output: "artifact"}, []}

      @impl true
      def event(_event, _params, state, _context), do: {:ok, state, []}

      @impl true
      def info(_message, state, _context), do: {:ok, state, []}

      @impl true
      def render_target(_state), do: #{target}

      @impl true
      def forms(_state), do: %{}

      def render(_assigns), do: Phoenix.HTML.raw("<main id=\\\"artifact-workbench\\\"></main>")
    end

    defmodule Catalyst.Ext.ArtifactWorkbenchExtension do
      use Catalyst.Extension, api: 2, code: :generation

      manifest %{
        id: "test.artifact-workbench",
        version: "1.0.0",
        services: [
          %{
            key: {"ui", "workbench", "default"},
            contract: {"catalyst.workbench", 1},
            implementation: Catalyst.Ext.ArtifactWorkbench,
            priority: 900,
            binding: {:pin, :mount}
          }
        ]
      }
    end
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "catalyst-artifact-workbench-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %ArtifactSet{} = artifact} = GenerationCompiler.compile_file(path)
    assert :ok = Artifacts.register(artifact)
    [manifest] = GenerationCompiler.manifests(artifact)
    assert {:ok, _generation} = Generations.install("artifact_workbench_source", [manifest])
  end

  defp restore_persistent(key, :not_set), do: :persistent_term.erase(key)
  defp restore_persistent(key, value), do: :persistent_term.put(key, value)

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
