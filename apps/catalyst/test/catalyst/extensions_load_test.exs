defmodule Catalyst.ExtensionsLoadTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [put_env: 2, wait_until: 1]
  import Catalyst.ExtensionsFixtures
  import ExUnit.CaptureLog

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Agent.Loop
  alias Catalyst.Extension.Manifest
  alias Catalyst.Extensions
  alias Catalyst.ExtensionsFixtures.SetupOnlyTool

  alias Catalyst.Runtime.{
    Artifacts,
    CandidateProcesses,
    GenerationStore,
    Generations,
    Leases,
    RunEngine
  }

  alias Catalyst.Tools.DevelopTool

  setup do
    setup_extensions_dir()
  end

  defmodule BlockingHealth do
    def check do
      parent = :persistent_term.get({__MODULE__, :parent})
      send(parent, {:blocking_health, self()})

      receive do
        :release -> :ok
      end
    end
  end

  test "the built-ins (incl. develop_tool) are seeded" do
    assert {:ok, _} = Extensions.fetch("read")
    assert Extensions.fetch("develop_tool") == {:ok, DevelopTool}
    assert "ast_grep" in Extensions.names()
  end

  test "an extension's optional metadata/0 is surfaced by list_loaded/0" do
    path = write_ext("meta_probe", meta_ext_source())
    on_exit(fn -> Extensions.uninstall("meta_probe") end)

    assert {:ok, _summary} = Extensions.load_file(path)

    info = Enum.find(Extensions.list_loaded(), &(&1.owner == "meta_probe"))
    assert info.metadata[:name] == "Meta Probe"
    assert info.metadata[:description] =~ "metadata/0"
  end

  test "API-v2 manifests are activated without invoking setup callbacks" do
    path =
      write_ext(
        "declarative_probe",
        """
        defmodule Catalyst.Ext.DeclarativeProbe do
          use Catalyst.Extension, api: 2

          manifest %{
            id: "test.declarative-probe",
            version: "1.0.0",
            metadata: %{name: "Declarative Probe"}
          }

          def setup(_api), do: raise("API-v2 setup must not execute")
          def metadata, do: raise("API-v2 metadata must come from the manifest")
        end
        """
      )

    on_exit(fn -> Extensions.uninstall("declarative_probe") end)

    assert {:ok, summary} = Extensions.load_file(path)
    assert summary.activation == :active
    assert summary.manifests == ["test.declarative-probe"]
    assert is_binary(summary.generation)
    assert summary.extensions == [Catalyst.Ext.DeclarativeProbe]
    refute Map.has_key?(summary, :warning)

    assert {:ok, manifest} = Catalyst.Extension.manifest_of(Catalyst.Ext.DeclarativeProbe)
    assert manifest.id == "test.declarative-probe"

    info = Enum.find(Extensions.list_loaded(), &(&1.owner == "declarative_probe"))
    assert info.metadata == %{name: "Declarative Probe"}
  end

  test "generation-qualified API-v2 reload retains pinned code until its run drains" do
    owner = "generation_artifact_probe"
    workflow = "generation-artifact-probe"
    path = write_ext(owner, generation_artifact_source(:first, workflow))
    on_exit(fn -> Extensions.uninstall(owner) end)

    assert {:ok, first_summary} = Extensions.load_file(path)
    assert first_summary.activation == :active

    assert {:ok, first_resolution} = RunEngine.resolve(workflow: workflow)
    assert {:ok, first_pinned} = RunEngine.pin(first_resolution)
    first_target = first_pinned.handle.implementation
    assert first_target.marker() == :first

    assert {:ok, [], %{generation: :first}} =
             RunEngine.invoke(
               first_pinned.handle,
               [],
               %{generation: :first},
               %{},
               fn _event -> :ok end
             )

    File.write!(path, generation_artifact_source(:second, workflow))
    assert {:ok, second_summary} = Extensions.load_file(path)
    assert second_summary.activation == :active

    assert {:ok, second_resolution} = RunEngine.resolve(workflow: workflow)
    assert {:ok, second_pinned} = RunEngine.pin(second_resolution)
    second_target = second_pinned.handle.implementation

    assert second_target.marker() == :second
    assert first_target != second_target
    assert first_target.marker() == :first
    assert :code.is_loaded(first_target) != false

    assert {:ok, [], %{generation: :first}} =
             RunEngine.invoke(
               first_pinned.handle,
               [],
               %{generation: :first},
               %{},
               fn _event -> :ok end
             )

    assert {:ok, [], %{generation: :second}} =
             RunEngine.invoke(
               second_pinned.handle,
               [],
               %{generation: :second},
               %{},
               fn _event -> :ok end
             )

    assert :ok = RunEngine.release(first_pinned)
    wait_until(fn -> :code.is_loaded(first_target) == false end)
    assert :code.is_loaded(second_target) != false
    assert {:ok, [_active_artifact]} = Artifacts.snapshot()

    assert :ok = RunEngine.release(second_pinned)
  end

  test "byte-identical generation reload reuses its artifact and activation" do
    owner = "generation_artifact_noop_probe"
    workflow = "generation-artifact-noop-probe"
    path = write_ext(owner, generation_artifact_source(:unchanged, workflow))
    on_exit(fn -> Extensions.uninstall(owner) end)

    assert {:ok, first_summary} = Extensions.load_file(path)
    assert {:ok, first_artifacts} = Artifacts.snapshot()

    assert {:ok, second_summary} = Extensions.load_file(path)
    assert {:ok, second_artifacts} = Artifacts.snapshot()

    assert second_summary.generation == first_summary.generation
    assert Enum.map(second_artifacts, & &1.id) == Enum.map(first_artifacts, & &1.id)
  end

  test "generation process failure retains pinned artifact code until its run drains" do
    owner = "generation_artifact_failure_probe"
    workflow = "generation-artifact-failure-probe"
    path = write_ext(owner, generation_artifact_source(:retained_after_failure, workflow))
    on_exit(fn -> Extensions.uninstall(owner) end)

    assert {:ok, _summary} = Extensions.load_file(path)
    assert {:ok, resolution} = RunEngine.resolve(workflow: workflow)
    assert {:ok, pinned} = RunEngine.pin(resolution)
    target = pinned.handle.implementation
    activation = GenerationStore.active_id()

    assert :ok = CandidateProcesses.stop(activation)
    wait_until(fn -> GenerationStore.active_id() == nil end)

    assert Leases.count(activation) == 1
    assert :code.is_loaded(target) != false
    assert target.marker() == :retained_after_failure

    assert :ok = RunEngine.release(pinned)
    wait_until(fn -> :code.is_loaded(target) == false end)
  end

  test "artifact-manager restart retains code held by a surviving run lease" do
    owner = "generation_artifact_restart_probe"
    workflow = "generation-artifact-restart-probe"
    path = write_ext(owner, generation_artifact_source(:retained_after_restart, workflow))
    on_exit(fn -> Extensions.uninstall(owner) end)

    assert {:ok, _summary} = Extensions.load_file(path)
    assert {:ok, resolution} = RunEngine.resolve(workflow: workflow)
    assert {:ok, pinned} = RunEngine.pin(resolution)
    target = pinned.handle.implementation
    activation = pinned.handle.lease.generation
    File.rm!(path)

    old_artifacts = Process.whereis(Artifacts)
    old_extensions = Process.whereis(Extensions)
    monitor = Process.monitor(old_artifacts)
    Process.exit(old_artifacts, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_artifacts, :killed}

    wait_until(fn ->
      artifacts = Process.whereis(Artifacts)
      leases = Process.whereis(Leases)
      generations = Process.whereis(Generations)
      extensions = Process.whereis(Extensions)

      is_pid(artifacts) and artifacts != old_artifacts and is_pid(leases) and is_pid(generations) and
        is_pid(extensions) and extensions != old_extensions
    end)

    assert :ok = Extensions.await_ready()
    _state = :sys.get_state(Generations)
    assert Leases.count(activation) == 1
    assert :code.is_loaded(target) != false
    assert target.marker() == :retained_after_restart

    assert :ok = RunEngine.release(pinned)
    _state = :sys.get_state(Generations)
    assert :code.is_loaded(target) == false
  end

  test "bulk activation failure discards generation artifacts that were never staged" do
    owner = "generation_bulk_rollback_probe"
    path = write_ext(owner, generation_artifact_source(:bulk_rollback, "bulk-rollback"))
    on_exit(fn -> Extensions.uninstall(owner) end)
    assert File.exists?(path)
    assert {:ok, before} = Artifacts.snapshot()
    :persistent_term.put({BlockingHealth, :parent}, self())
    on_exit(fn -> :persistent_term.erase({BlockingHealth, :parent}) end)

    blocking =
      Manifest.new!(%{
        id: "test.blocking-composition",
        version: "1.0.0",
        health_checks: [
          %{
            id: "blocking",
            module: BlockingHealth,
            function: :check,
            args: [],
            timeout: 5_000
          }
        ]
      })

    task = Task.async(fn -> Generations.install("blocking-composition", [blocking]) end)
    assert_receive {:blocking_health, health_check}, 1_000

    result = Extensions.load_all()
    {:ok, after_rollback} = Artifacts.snapshot()
    send(health_check, :release)
    activation_result = Task.await(task, 5_000)
    cleanup_result = Generations.remove_owner("blocking-composition")

    assert {:ok, %{failed: failed}} = result

    assert {_, {:candidate_activation_failed, :generation_activation_in_progress}} =
             Enum.find(failed, fn {failed_path, _reason} -> failed_path == path end)

    assert Enum.map(after_rollback, & &1.id) == Enum.map(before, & &1.id)
    assert {:ok, _generation} = activation_result
    assert :ok = cleanup_result
  end

  test "bulk loading returns a tagged error while the extension runtime is unavailable" do
    server = Process.whereis(Extensions)
    assert Process.unregister(Extensions)

    try do
      assert {:error, :extension_runtime_unavailable} = Extensions.load_all()
    after
      assert Process.register(server, Extensions)
    end
  end

  test "a rejected API-v2 candidate does not replace the active generation" do
    active_id = Catalyst.Runtime.GenerationStore.active_id()

    path =
      write_ext(
        "rejected_declarative_probe",
        """
        defmodule Catalyst.Ext.RejectedDeclarativeHealth do
          def check, do: {:error, :not_ready}
        end

        defmodule Catalyst.Ext.RejectedDeclarativeProbe do
          use Catalyst.Extension, api: 2

          manifest %{
            id: "test.rejected-declarative-probe",
            version: "1.0.0",
            health_checks: [
              %{
                id: "not-ready",
                module: Catalyst.Ext.RejectedDeclarativeHealth,
                function: :check,
                timeout: 100
              }
            ]
          }
        end
        """
      )

    on_exit(fn -> Extensions.uninstall("rejected_declarative_probe") end)

    assert {:error,
            {:candidate_activation_failed, {:health_check_failed, "not-ready", :not_ready}}} =
             Extensions.load_file(path)

    assert Catalyst.Runtime.GenerationStore.active_id() == active_id

    refute Enum.any?(
             Extensions.list_loaded(),
             &(&1.owner == "rejected_declarative_probe")
           )
  end

  test "the load lock mutually excludes different processes" do
    parent = self()

    holder =
      Task.async(fn ->
        Extensions.locked(fn ->
          send(parent, {:holder_in, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:holder_in, holder_transaction}, 1_000

    waiter = Task.async(fn -> Extensions.locked(fn -> send(parent, :waiter_in) end) end)

    # With the old fixed-atom lock requester, :global treated both processes
    # as "the same requester" and the waiter would enter immediately.
    refute_receive :waiter_in, 200

    send(holder_transaction, :release)
    # Generous deadline: :global.trans retries with randomized backoff, so a
    # contended waiter can legitimately take well over a second to re-acquire.
    assert_receive :waiter_in, 5_000
    Task.await_many([holder, waiter])
  end

  test "develop_tool compiles and loads a new tool at runtime (no restart)" do
    ctx = %{cwd: System.tmp_dir!(), call_id: "t", report: fn _ -> :ok end}

    capture_log(fn ->
      DevelopTool.execute(%{"name" => "shout_test", "source" => shout_source()}, ctx)
    end)

    # The freshly written module is now a live, registered tool.
    assert {:ok, mod} = Extensions.fetch("shout_test")
    assert mod == Catalyst.Ext.ShoutTest
    assert mod.execute(%{"text" => "hi"}, ctx).content |> hd() |> Map.get(:text) == "HI"
  end

  test "the agent can self-develop a tool and use it in the same run" do
    tmp = Path.join(System.tmp_dir!(), "selfdev_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    model = %Model{id: "faux", api: "faux", provider: "faux"}

    # Turn 1: write the tool. Turn 2: call it (now resolvable). Turn 3: done.
    script = [
      {:tool, "develop_tool", %{"name" => "shout_run", "source" => shout_run_source()}},
      {:tool, "shout_run", %{"text" => "it works"}},
      {:text, "self-extended!"}
    ]

    config = %{
      provider: Catalyst.LLM.Faux,
      model: model,
      cwd: tmp,
      # :extensions → the loop resolves the LIVE tool set every turn
      tools: :extensions,
      opts: [script: script]
    }

    {:ok, collector} = Agent.start_link(fn -> [] end)
    emit = fn ev -> Agent.update(collector, &[ev | &1]) end

    {:ok, messages, _ctx} =
      Loop.run(
        [Message.user("extend yourself")],
        %{system_prompt: nil, messages: []},
        config,
        emit
      )

    Agent.stop(collector)

    tool_results = Enum.filter(messages, &match?(%Message.ToolResult{}, &1))
    shout_result = Enum.find(tool_results, &(&1.tool_name == "shout_run"))

    assert shout_result, "expected the self-created tool to have been called"
    assert Content.text_of(shout_result.content) == "IT WORKS"
    assert Content.text_of(List.last(messages).content) == "self-extended!"
  end

  test "an extension's setup/1 registers both a tool and a loop hook" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", multikind_source())

    assert {:ok, summary} = Extensions.load_file(path)
    assert "mk_tool" in summary.tools

    assert Extensions.fetch("mk_tool") == {:ok, Catalyst.Ext.MultiKindTool}
    assert length(owner_hooks("multikind")) == 1
  end

  test "auto-loaded tools must return binary names" do
    source = ~S'''
    defmodule Catalyst.Ext.BadNameTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: :bad_name_tool
      @impl true
      def description, do: "bad tool"
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("bad")
    end
    '''

    path = write_ext("bad_name_tool", source)

    assert {:error, {:bad_tool_name, :bad_name_tool}} = Extensions.load_file(path)
    assert Extensions.fetch("bad_name_tool") == :error
    refute Code.ensure_loaded?(Catalyst.Ext.BadNameTool)
  end

  test "reloading an extension purges its prior hooks (no duplicates)" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", multikind_source())

    Extensions.load_file(path)
    Extensions.load_file(path)

    assert length(owner_hooks("multikind")) == 1
  end

  test "setup/1 can register a tool through the API without deadlocking the server" do
    on_exit(fn -> Extensions.uninstall("setupreg") end)
    path = write_ext("setupreg", setup_reg_source())

    assert {:ok, summary} = Extensions.load_file(path)
    assert summary.extensions == [Catalyst.Ext.SetupReg]
    assert Extensions.fetch("setup_only_tool") == {:ok, SetupOnlyTool}

    # The setup-registered tool is owner-tracked, so uninstall removes it.
    Extensions.uninstall("setupreg")
    assert Extensions.fetch("setup_only_tool") == :error
  end

  test "a hanging extension compile is timed out without blocking the registry GenServer" do
    put_env(:extension_compile_timeout, 200)
    put_parent!(:compile_parent)
    compiler_options = Code.compiler_options()

    on_exit(fn -> Extensions.uninstall("compile_probe") end)

    path = write_ext("compile_hang", compile_hang_source())
    task = Task.async(fn -> Extensions.load_file(path) end)

    assert_receive :compile_started, 1_000
    assert {:ok, _} = Extensions.register_tool(SetupOnlyTool, owner: "compile_probe")
    assert {:error, :timeout} = Task.await(task, 1_000)
    assert Code.compiler_options() == compiler_options
  end

  test "a hanging extension setup is timed out without blocking the registry GenServer" do
    put_env(:extension_setup_timeout, 200)
    put_parent!(:setup_parent)

    on_exit(fn ->
      Extensions.uninstall("hanging_setup")
      Extensions.uninstall("setup_probe")
    end)

    log =
      capture_log(fn ->
        path = write_ext("hanging_setup", setup_hang_source())
        task = Task.async(fn -> Extensions.load_file(path) end)

        assert_receive :setup_started, 1_000
        assert {:ok, _} = Extensions.register_tool(SetupOnlyTool, owner: "setup_probe")
        assert {:ok, summary} = Task.await(task, 1_000)
        assert summary.warning =~ "setup did not finish cleanly"
      end)

    assert log =~ "setup timed out"
  end

  test "load_all reports per-file failures alongside the loaded summaries" do
    on_exit(fn -> Extensions.uninstall("goodfile") end)
    write_ext("goodfile", ephemeral_source())
    broken_path = write_ext("badfile", "defmodule Catalyst.Ext.BadFile do @@@ end")

    capture_log(fn ->
      assert {:ok, %{loaded: loaded, failed: [{^broken_path, reason}]}} = Extensions.load_all()
      assert Enum.any?(loaded, &(&1.owner == "goodfile"))
      assert Extensions.format_error(reason) =~ "badfile.ex"
    end)
  end

  test "load_all purges a renamed owner before committing its replacement" do
    original = write_ext("renamed_original", ephemeral_source())
    renamed = Path.join(Extensions.dir(), "renamed_replacement.ex")

    on_exit(fn ->
      Extensions.uninstall("renamed_original")
      Extensions.uninstall("renamed_replacement")
    end)

    assert {:ok, %{failed: []}} = Extensions.load_all()
    assert {:ok, Catalyst.Ext.EphemeralTool} = Extensions.fetch("ephemeral_tool")

    File.rename!(original, renamed)

    assert {:ok, %{loaded: loaded, failed: []}} = Extensions.load_all()
    assert Enum.any?(loaded, &(&1.owner == "renamed_replacement"))
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "renamed_original"))
    assert {:ok, Catalyst.Ext.EphemeralTool} = Extensions.fetch("ephemeral_tool")
  end

  test "reloading a v2 extension as v1 removes its managed manifests" do
    path =
      write_ext(
        "manifest_removed",
        """
        defmodule Catalyst.Ext.ManifestRemoved do
          use Catalyst.Extension, api: 2

          manifest %{
            id: "test.manifest-removed",
            version: "1.0.0"
          }

          def marker, do: :managed
        end
        """
      )

    on_exit(fn -> Extensions.uninstall("manifest_removed") end)

    assert {:ok, _summary} = Extensions.load_file(path)
    assert Map.has_key?(GenerationStore.owners(), "manifest_removed")

    write_ext(
      "manifest_removed",
      """
      defmodule Catalyst.Ext.ManifestRemoved do
        use Catalyst.Extension

        def setup(_api), do: :ok
        def marker, do: :imperative
      end
      """
    )

    assert {:ok, _summary} = Extensions.load_file(path)
    refute Map.has_key?(GenerationStore.owners(), "manifest_removed")
    assert apply(Catalyst.Ext.ManifestRemoved, :marker, []) == :imperative
  end

  test "load_all activates interdependent manifests independently of file order" do
    write_ext(
      "a_dependent",
      """
      defmodule Catalyst.Ext.OrderedDependent do
        use Catalyst.Extension, api: 2

        manifest %{
          id: "test.ordered-dependent",
          version: "1.0.0",
          requires: [{"test.ordered-base", "~> 1.0"}]
        }
      end
      """
    )

    write_ext(
      "z_base",
      """
      defmodule Catalyst.Ext.OrderedBase do
        use Catalyst.Extension, api: 2

        manifest %{
          id: "test.ordered-base",
          version: "1.0.0"
        }
      end
      """
    )

    on_exit(fn ->
      Extensions.uninstall("a_dependent")
      Extensions.uninstall("z_base")
    end)

    assert {:ok, %{loaded: loaded, failed: []}} = Extensions.load_all()
    assert Enum.map(loaded, & &1.owner) == ["a_dependent", "z_base"]
    assert Map.has_key?(GenerationStore.owners(), "a_dependent")
    assert Map.has_key?(GenerationStore.owners(), "z_base")
  end

  test "a rejected managed composition does not block an unrelated v1 load" do
    write_ext("legacy_survivor", ephemeral_source())

    rejected_path =
      write_ext(
        "managed_rejected",
        """
        defmodule Catalyst.Ext.ManagedRejectedHealth do
          def check, do: {:error, :not_ready}
        end

        defmodule Catalyst.Ext.ManagedRejected do
          use Catalyst.Extension, api: 2

          manifest %{
            id: "test.managed-rejected",
            version: "1.0.0",
            health_checks: [
              %{
                id: "not-ready",
                module: Catalyst.Ext.ManagedRejectedHealth,
                function: :check,
                timeout: 100
              }
            ]
          }
        end
        """
      )

    on_exit(fn ->
      Extensions.uninstall("legacy_survivor")
      Extensions.uninstall("managed_rejected")
    end)

    assert {:ok, %{loaded: loaded, failed: [{^rejected_path, reason}]}} =
             Extensions.load_all()

    assert Enum.any?(loaded, &(&1.owner == "legacy_survivor"))

    assert reason ==
             {:candidate_activation_failed, {:health_check_failed, "not-ready", :not_ready}}

    assert Enum.any?(Extensions.list_loaded(), &(&1.owner == "legacy_survivor"))
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "managed_rejected"))
  end

  test "a rejected replacement restores the prior accepted module and manifest" do
    path =
      write_ext(
        "managed_restore",
        """
        defmodule Catalyst.Ext.ManagedRestore do
          use Catalyst.Extension, api: 2

          manifest %{
            id: "test.managed-restore",
            version: "1.0.0"
          }

          def marker, do: :old
        end
        """
      )

    on_exit(fn -> Extensions.uninstall("managed_restore") end)

    assert {:ok, _summary} = Extensions.load_file(path)

    write_ext(
      "managed_restore",
      """
      defmodule Catalyst.Ext.ManagedRestoreHealth do
        def check, do: {:error, :replacement_rejected}
      end

      defmodule Catalyst.Ext.ManagedRestore do
        use Catalyst.Extension, api: 2

        manifest %{
          id: "test.managed-restore",
          version: "2.0.0",
          health_checks: [
            %{
              id: "replacement-health",
              module: Catalyst.Ext.ManagedRestoreHealth,
              function: :check,
              timeout: 100
            }
          ]
        }

        def marker, do: :new
      end
      """
    )

    assert {:error,
            {:candidate_activation_failed,
             {:health_check_failed, "replacement-health", :replacement_rejected}}} =
             Extensions.load_file(path)

    assert apply(Catalyst.Ext.ManagedRestore, :marker, []) == :old
    assert [%{version: "1.0.0"}] = GenerationStore.owners()["managed_restore"]
  end

  test "uninstalling a v1 extension does not restage unrelated managed owners" do
    :persistent_term.put({__MODULE__, :managed_health}, :ready)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :managed_health})
      Extensions.uninstall("stable_managed")
      Extensions.uninstall("legacy_uninstall")
    end)

    managed_path =
      write_ext(
        "stable_managed",
        """
        defmodule Catalyst.Ext.StableManagedHealth do
          def check do
            case :persistent_term.get({#{inspect(__MODULE__)}, :managed_health}) do
              :ready -> :ok
              status -> {:error, status}
            end
          end
        end

        defmodule Catalyst.Ext.StableManaged do
          use Catalyst.Extension, api: 2

          manifest %{
            id: "test.stable-managed",
            version: "1.0.0",
            health_checks: [
              %{
                id: "stable-health",
                module: Catalyst.Ext.StableManagedHealth,
                function: :check,
                timeout: 100
              }
            ]
          }
        end
        """
      )

    legacy_path = write_ext("legacy_uninstall", ephemeral_source())

    assert {:ok, _summary} = Extensions.load_file(managed_path)
    assert {:ok, legacy_summary} = Extensions.load_file(legacy_path)
    refute Map.has_key?(legacy_summary, :activation)
    refute Map.has_key?(legacy_summary, :generation)

    :persistent_term.put({__MODULE__, :managed_health}, :broken)

    assert :ok = Extensions.uninstall("legacy_uninstall")
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "legacy_uninstall"))
    assert Map.has_key?(GenerationStore.owners(), "stable_managed")
  end

  test "failed managed removal preserves every active owner" do
    :persistent_term.put({__MODULE__, :removal_health}, :ready)

    on_exit(fn ->
      :persistent_term.put({__MODULE__, :removal_health}, :ready)
      Extensions.uninstall("removal_guard")
      Extensions.uninstall("removal_target")
      :persistent_term.erase({__MODULE__, :removal_health})
    end)

    guard_path = write_ext("removal_guard", removal_guard_source())
    target_path = write_ext("removal_target", managed_manifest_source("test.removal-target"))

    assert {:ok, _summary} = Extensions.load_file(guard_path)
    assert {:ok, _summary} = Extensions.load_file(target_path)
    active_id = GenerationStore.active_id()
    :persistent_term.put({__MODULE__, :removal_health}, :broken)

    assert {:error, {:health_check_failed, "removal-health", :broken}} =
             Extensions.uninstall("removal_target")

    assert GenerationStore.active_id() == active_id
    assert Map.has_key?(GenerationStore.owners(), "removal_guard")
    assert Map.has_key?(GenerationStore.owners(), "removal_target")
    assert Enum.any?(Extensions.list_loaded(), &(&1.owner == "removal_target"))
  end

  test "failed disable restores the enabled source filename" do
    :persistent_term.put({__MODULE__, :removal_health}, :ready)

    on_exit(fn ->
      :persistent_term.put({__MODULE__, :removal_health}, :ready)
      Extensions.uninstall("disable_guard")
      Extensions.uninstall("disable_target")
      :persistent_term.erase({__MODULE__, :removal_health})
    end)

    guard_path = write_ext("disable_guard", removal_guard_source())
    target_path = write_ext("disable_target", managed_manifest_source("test.disable-target"))

    assert {:ok, _summary} = Extensions.load_file(guard_path)
    assert {:ok, _summary} = Extensions.load_file(target_path)
    :persistent_term.put({__MODULE__, :removal_health}, :broken)

    assert {:error, {:health_check_failed, "removal-health", :broken}} =
             Extensions.disable("disable_target")

    assert File.exists?(target_path)
    refute File.exists?(target_path <> ".disabled")
    assert Map.has_key?(GenerationStore.owners(), "disable_target")
    assert Enum.any?(Extensions.list_loaded(), &(&1.owner == "disable_target"))
  end

  test "redefining another owner's module is warned about and surfaced in the summary" do
    on_exit(fn ->
      Extensions.uninstall("conflict_a")
      Extensions.uninstall("conflict_b")
    end)

    path_a = write_ext("conflict_a", conflict_source(:a))
    path_b = write_ext("conflict_b", conflict_source(:b))

    capture_log(fn ->
      assert {:ok, summary_a} = Extensions.load_file(path_a)
      refute Map.has_key?(summary_a, :conflicts)
    end)

    log =
      capture_log(fn ->
        assert {:ok, summary_b} = Extensions.load_file(path_b)
        assert summary_b.conflicts == [{"conflict_a", [Catalyst.Ext.SharedMod]}]
      end)

    assert log =~ "also defined by extension"
  end

  test "a broken extension file registers nothing and returns an error" do
    source = ~S'''
    defmodule Catalyst.Ext.BrokenTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "broken_tool"
      this is not valid @@@
    end
    '''

    path = write_ext("brokenext", source)

    assert {:error, _reason} = Extensions.load_file(path)
    assert Extensions.fetch("broken_tool") == :error
  end

  test "list_loaded reports each owner's tools, modules, and source file" do
    on_exit(fn -> Extensions.uninstall("toggle") end)
    path = write_ext("toggle", toggle_source())
    assert {:ok, _summary} = Extensions.load_file(path)

    assert [entry] = Enum.filter(Extensions.list_loaded(), &(&1.owner == "toggle"))
    assert entry.path == path
    assert entry.tools == ["toggle_tool"]
    assert Catalyst.Ext.ToggleTool in entry.modules
  end

  test "setup return errors and exceptions are surfaced in load warnings" do
    returned =
      write_ext(
        "setup_returned_error",
        ~S'''
        defmodule Catalyst.Ext.SetupReturnedError do
          use Catalyst.Extension
          @impl true
          def setup(_api), do: {:error, :not_ready}
        end
        '''
      )

    raised =
      write_ext(
        "setup_raised_error",
        ~S'''
        defmodule Catalyst.Ext.SetupRaisedError do
          use Catalyst.Extension
          @impl true
          def setup(_api), do: raise("setup exploded")
        end
        '''
      )

    log =
      capture_log(fn ->
        assert {:ok, returned_summary} = Extensions.load_file(returned)
        assert returned_summary.warning =~ "not_ready"

        assert {:ok, raised_summary} = Extensions.load_file(raised)
        assert raised_summary.warning =~ "setup exploded"
      end)

    assert log =~ "returned {:error"
    assert log =~ "setup/1 raised: setup exploded"
  end

  test "tool registration metadata is bounded outside the Extensions server" do
    put_env(:tool_metadata_timeout, 100)
    put_parent!(:tool_metadata_parent)

    path =
      write_ext(
        "hanging_tool_metadata",
        ~S'''
        defmodule Catalyst.Ext.HangingToolMetadata do
          use Catalyst.Tools.Tool
          @impl true
          def name, do: "hanging_tool_metadata"
          @impl true
          def description do
            send(:persistent_term.get({Catalyst.ExtensionsFixtures, :tool_metadata_parent}), :tool_metadata_started)

            receive do
              :never -> "unreachable"
            end
          end
          @impl true
          def parameters, do: %{"type" => "object"}
          @impl true
          def execute(_args, _ctx), do: result("ok")
        end
        '''
      )

    task = Task.async(fn -> Extensions.load_file(path) end)
    assert_receive :tool_metadata_started

    assert {:ok, Catalyst.Tools.Read} = Extensions.fetch("read")

    assert {:error, {:tool_metadata_timeout, Catalyst.Ext.HangingToolMetadata}} =
             Task.await(task, 1_000)
  end

  test "extension metadata is bounded and cached after a successful load" do
    put_env(:extension_metadata_timeout, 50)
    put_parent!(:metadata_parent)

    cached =
      write_ext(
        "cached_metadata",
        ~S'''
        defmodule Catalyst.Ext.CachedMetadata do
          use Catalyst.Extension
          @impl true
          def metadata do
            send(:persistent_term.get({Catalyst.ExtensionsFixtures, :metadata_parent}), :metadata_called)
            %{name: "cached"}
          end
          @impl true
          def setup(_api), do: :ok
        end
        '''
      )

    assert {:ok, _} = Extensions.load_file(cached)
    assert_receive :metadata_called

    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "cached_metadata")).metadata == %{
             name: "cached"
           }

    _ = Extensions.list_loaded()
    refute_receive :metadata_called

    hanging =
      write_ext(
        "hanging_metadata",
        ~S'''
        defmodule Catalyst.Ext.HangingMetadata do
          use Catalyst.Extension
          @impl true
          def metadata do
            receive do
              :never -> %{}
            end
          end
          @impl true
          def setup(_api), do: :ok
        end
        '''
      )

    assert {:ok, _} = Extensions.load_file(hanging)
    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "hanging_metadata")).metadata == %{}
  end

  defp generation_artifact_source(marker, workflow) do
    """
    defmodule Catalyst.Ext.GenerationArtifactEngine do
      @behaviour Catalyst.Workflow

      @impl true
      def run(_prompts, context, _config, _emit), do: {:ok, [], context}

      def marker, do: #{inspect(marker)}
    end

    defmodule Catalyst.Ext.GenerationArtifactProbe do
      use Catalyst.Extension, api: 2, code: :generation

      manifest %{
        id: "test.generation-artifact-probe",
        version: "1.0.0",
        services: [
          %{
            key: {"agent", "run_engine", "named:#{workflow}"},
            contract: {"catalyst.agent-run-engine", 1},
            implementation: Catalyst.Ext.GenerationArtifactEngine
          }
        ]
      }
    end
    """
  end

  defp removal_guard_source do
    """
    defmodule Catalyst.Ext.RemovalGuardHealth do
      def check do
        case :persistent_term.get({#{inspect(__MODULE__)}, :removal_health}) do
          :ready -> :ok
          status -> {:error, status}
        end
      end
    end

    defmodule Catalyst.Ext.RemovalGuard do
      use Catalyst.Extension, api: 2

      manifest %{
        id: "test.removal-guard",
        version: "1.0.0",
        health_checks: [
          %{
            id: "removal-health",
            module: Catalyst.Ext.RemovalGuardHealth,
            function: :check,
            timeout: 100
          }
        ]
      }
    end
    """
  end

  defp managed_manifest_source(id) do
    """
    defmodule Catalyst.Ext.ManagedRemovalTarget do
      use Catalyst.Extension, api: 2

      manifest %{
        id: #{inspect(id)},
        version: "1.0.0"
      }
    end
    """
  end
end
