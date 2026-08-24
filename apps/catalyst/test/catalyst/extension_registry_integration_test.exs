defmodule Catalyst.ExtensionRegistryIntegrationTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  import ExUnit.CaptureLog

  alias Catalyst.Context.Registry, as: ContextRegistry
  alias Catalyst.{ExtensionAPI, Extensions}
  alias Catalyst.LLM.Registry, as: LLMRegistry
  alias Catalyst.Extensions.BootGuard
  alias Catalyst.Prompt.Registry, as: PromptRegistry
  alias Catalyst.Runtime.Registry, as: RuntimeRegistry
  alias Catalyst.Workflow.Registry, as: WorkflowRegistry

  @direct_owner "registry_direct_owner"
  @lifecycle_owner "registry_lifecycle"

  setup do
    Catalyst.ExtensionsFixtures.await_bootstrap!()
    File.rm_rf!(Extensions.dir())
    File.mkdir_p!(Extensions.dir())

    on_exit(fn ->
      Enum.each([@direct_owner, @lifecycle_owner], &Catalyst.ExtensionAPI.purge_owner/1)
      Extensions.uninstall(@lifecycle_owner)
      File.rm_rf!(Extensions.dir())
    end)

    :ok
  end

  test "domain registries share one owner purge path" do
    assert {:ok, purged} = ExtensionAPI.purge_owner(@direct_owner)
    assert {RuntimeRegistry, :purge_owner, 1} in purged
    assert {Catalyst.Extensions.Processes, :stop_owner, 1} in purged
  end

  test "kind handlers use stable external captures" do
    handlers = %{
      tool: {Extensions, :register_extension_tool, 2},
      hook: {Extensions, :register_extension_hook, 4},
      event: {Extensions, :register_extension_observer, 3},
      process: {Extensions, :start_extension_process, 2},
      provider: {LLMRegistry, :register_extension_provider, 3},
      prompt: {PromptRegistry, :register_extension_prompt, 4},
      prompt_policy: {PromptRegistry, :register_extension_prompt_policy, 3},
      workflow: {WorkflowRegistry, :register_extension_workflow, 4},
      context_policy: {ContextRegistry, :register_extension_policy, 3},
      context_threshold: {ContextRegistry, :register_extension_threshold, 4}
    }

    for {kind, {module, name, arity}} <- handlers do
      handler = :persistent_term.get({ExtensionAPI, :kind, kind})

      assert Function.info(handler, :type) == {:type, :external}
      assert Function.info(handler, :module) == {:module, module}
      assert Function.info(handler, :name) == {:name, name}
      assert Function.info(handler, :arity) == {:arity, arity}
    end
  end

  test "ExtensionAPI owner-tags prompt, workflow, and context registrations" do
    api = Catalyst.ExtensionAPI.new(@direct_owner)

    assert :ok =
             Catalyst.ExtensionAPI.register_prompt(api, "registry-direct-model", "compact now",
               purpose: :compaction
             )

    assert :ok = Catalyst.ExtensionAPI.register_prompt_policy(api, Catalyst.SystemPrompt)

    assert :ok =
             Catalyst.ExtensionAPI.register_workflow(
               api,
               "registry-direct-workflow",
               Catalyst.Agent.Loop
             )

    assert :ok =
             Catalyst.ExtensionAPI.register_context_policy(api, Catalyst.Context.Window)

    assert :ok =
             Catalyst.ExtensionAPI.register_context_threshold(api, "registry-direct-model", 0.75)

    assert runtime_entry(PromptRegistry, {:text, :compaction, "registry-direct-model"}) ==
             %{value: "compact now", owner: @direct_owner}

    assert runtime_entry(PromptRegistry, {:policy, :default}) ==
             %{value: Catalyst.SystemPrompt, owner: @direct_owner}

    assert runtime_entry(WorkflowRegistry, {:workflow, "registry-direct-workflow"}) ==
             %{value: Catalyst.Agent.Loop, owner: @direct_owner}

    assert runtime_entry(ContextRegistry, {:policy, :default}) ==
             %{value: Catalyst.Context.Window, owner: @direct_owner}

    assert runtime_entry(ContextRegistry, {:threshold, "registry-direct-model"}) ==
             %{value: 0.75, owner: @direct_owner}

    assert {:ok, _purged} = Catalyst.ExtensionAPI.purge_owner(@direct_owner)
    refute owner_registered?(@direct_owner)
  end

  test "every new cross-owner collision rejects and purges the complete extension file" do
    scenarios = [
      %{
        name: "prompt_text",
        seed: fn api ->
          Catalyst.ExtensionAPI.register_prompt(api, "registry-shared-prompt", "owner a")
        end,
        collide:
          ~S<Catalyst.ExtensionAPI.register_prompt(api, "registry-shared-prompt", "owner b")>,
        error:
          {:owner_collision, :prompt, {:text, :system, "registry-shared-prompt"},
           "registry_collision_owner_a", "registry_collision_prompt_text"}
      },
      %{
        name: "prompt_policy",
        seed: fn api ->
          Catalyst.ExtensionAPI.register_prompt_policy(api, Catalyst.SystemPrompt)
        end,
        collide: ~S<Catalyst.ExtensionAPI.register_prompt_policy(api, Catalyst.SystemPrompt)>,
        error:
          {:owner_collision, :prompt, {:policy, :default}, "registry_collision_owner_a",
           "registry_collision_prompt_policy"}
      },
      %{
        name: "workflow",
        seed: fn api ->
          Catalyst.ExtensionAPI.register_workflow(
            api,
            "registry-shared-workflow",
            Catalyst.Agent.Loop
          )
        end,
        collide:
          ~S<Catalyst.ExtensionAPI.register_workflow(api, "registry-shared-workflow", Catalyst.Agent.Loop)>,
        error:
          {:owner_collision, :workflow, "registry-shared-workflow", "registry_collision_owner_a",
           "registry_collision_workflow"}
      },
      %{
        name: "context_policy",
        seed: fn api ->
          Catalyst.ExtensionAPI.register_context_policy(api, Catalyst.Context.Window)
        end,
        collide: ~S<Catalyst.ExtensionAPI.register_context_policy(api, Catalyst.Context.Window)>,
        error:
          {:owner_collision, :context_policy, nil, "registry_collision_owner_a",
           "registry_collision_context_policy"}
      },
      %{
        name: "context_threshold",
        seed: fn api ->
          Catalyst.ExtensionAPI.register_context_threshold(api, "registry-shared-threshold", 900)
        end,
        collide:
          ~S<Catalyst.ExtensionAPI.register_context_threshold(api, "registry-shared-threshold", 901)>,
        error:
          {:owner_collision, :context_threshold, "registry-shared-threshold",
           "registry_collision_owner_a", "registry_collision_context_threshold"}
      }
    ]

    Enum.each(scenarios, &assert_collision_rolls_back/1)
  end

  test "reload replaces an owner's complete registry footprint and file removal purges it" do
    path = write_extension!(@lifecycle_owner, lifecycle_source("one"))

    assert {:ok, _summary} = Extensions.load_file(path)
    assert_lifecycle_entries("one")

    File.write!(path, lifecycle_source("two"))
    assert {:ok, _summary} = Extensions.reload(@lifecycle_owner)

    refute lifecycle_key_registered?("one")
    assert_lifecycle_entries("two")

    File.rm!(path)

    capture_log(fn ->
      assert {:ok, %{failed: []}} = Extensions.load_all()
    end)

    refute owner_registered?(@lifecycle_owner)
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == @lifecycle_owner))
  end

  test "a reload rejected during setup restores the prior accepted version" do
    path = write_extension!(@lifecycle_owner, lifecycle_source("one"))
    assert {:ok, _summary} = Extensions.load_file(path)
    assert_lifecycle_entries("one")

    api = Catalyst.ExtensionAPI.new(@direct_owner)
    assert :ok = Catalyst.ExtensionAPI.register_prompt(api, "registry-restore-shared", "mine")

    # v2 collides with the direct owner's key AFTER registering its own keys —
    # the whole file must be rejected and v1's footprint reinstated, not lost.
    module = Catalyst.Ext.RegistryLifecycle

    File.write!(
      path,
      collision_source(
        module,
        "registry-restore-v2",
        ~s/Catalyst.ExtensionAPI.register_prompt(api, "registry-restore-shared", "stolen")/
      )
    )

    capture_log(fn ->
      assert {:error,
              {:owner_collision, :prompt, {:text, :system, "registry-restore-shared"},
               @direct_owner, @lifecycle_owner}} = Extensions.reload(@lifecycle_owner)
    end)

    assert_lifecycle_entries("one")
    refute key_registered?(PromptRegistry, {:text, :system, "registry-restore-v2"})
    assert Enum.any?(Extensions.list_loaded(), &(&1.owner == @lifecycle_owner))

    assert runtime_entry(PromptRegistry, {:text, :system, "registry-restore-shared"}) ==
             %{value: "mine", owner: @direct_owner}
  end

  test "safe-mode runtime restart skips extension overlays and retains core fallbacks" do
    path = write_extension!("registry_safe_mode", lifecycle_source("safe"))
    previous_safe_mode = Application.fetch_env(:catalyst, :safe_mode)

    on_exit(fn ->
      restore_env(:safe_mode, previous_safe_mode)
      File.rm(path)
      BootGuard.mark_ok()
      restart_extension_runtime!()
      Catalyst.ExtensionsFixtures.await_bootstrap!()
      BootGuard.mark_ok()
    end)

    assert {:ok, _summary} = Extensions.load_file(path)
    assert owner_registered?("registry_safe_mode")

    Application.put_env(:catalyst, :safe_mode, true)
    restart_extension_runtime!()
    Catalyst.ExtensionsFixtures.await_bootstrap!()

    assert Extensions.boot_status() == {:safe_mode, :env}
    refute owner_registered?("registry_safe_mode")
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "registry_safe_mode"))

    assert {:ok, Catalyst.SystemPrompt, :builtin} = PromptRegistry.policy()

    assert {:ok, %{module: Catalyst.Agent.Loop, source: :builtin}} =
             WorkflowRegistry.resolve([])

    assert {:ok, Catalyst.Context.Window, :builtin} = ContextRegistry.policy()
    assert {:ok, Catalyst.Tools.SpawnAgent} = Extensions.fetch("spawn_agent")
    assert {:ok, Catalyst.Tools.ListAgents} = Extensions.fetch("list_agents")
  end

  defp assert_collision_rolls_back(%{name: name, seed: seed, collide: collide, error: error}) do
    owner_a = "registry_collision_owner_a"
    owner_b = "registry_collision_#{name}"
    unique = "registry-unique-#{name}"
    api = Catalyst.ExtensionAPI.new(owner_a)

    assert :ok = seed.(api)

    module = Module.concat(Catalyst.Ext, "RegistryCollision#{Macro.camelize(name)}")
    path = write_extension!(owner_b, collision_source(module, unique, collide))

    assert {:error, ^error} = Extensions.load_file(path)
    assert Extensions.format_error(error) =~ "cannot replace"

    assert owner_registered?(owner_a)
    refute owner_registered?(owner_b)
    refute key_registered?(PromptRegistry, {:text, :system, unique})
    refute key_registered?(WorkflowRegistry, {:workflow, unique})
    refute key_registered?(ContextRegistry, {:threshold, unique})
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == owner_b))
    refute Code.ensure_loaded?(module)

    Catalyst.ExtensionAPI.purge_owner(owner_a)
    Extensions.uninstall(owner_b)
    File.rm!(path)
  end

  defp collision_source(module, unique, collide) do
    """
    defmodule #{inspect(module)} do
      use Catalyst.Extension

      @impl true
      def setup(api) do
        :ok = Catalyst.ExtensionAPI.register_prompt(api, #{inspect(unique)}, "unique prompt")
        :ok = Catalyst.ExtensionAPI.register_workflow(api, #{inspect(unique)}, Catalyst.Agent.Loop)
        :ok = Catalyst.ExtensionAPI.register_context_threshold(api, #{inspect(unique)}, 321)
        _ignored_collision = #{collide}
        :ok
      end
    end
    """
  end

  defp lifecycle_source(tag) do
    """
    defmodule Catalyst.Ext.RegistryLifecycle do
      use Catalyst.Extension

      @impl true
      def setup(api) do
        with :ok <- Catalyst.ExtensionAPI.register_prompt(api, "registry-lifecycle-#{tag}", "prompt #{tag}"),
             :ok <- Catalyst.ExtensionAPI.register_prompt_policy(api, Catalyst.SystemPrompt),
             :ok <- Catalyst.ExtensionAPI.register_workflow(api, "registry-lifecycle-#{tag}", Catalyst.Agent.Loop),
             :ok <- Catalyst.ExtensionAPI.register_context_policy(api, Catalyst.Context.Window),
             :ok <- Catalyst.ExtensionAPI.register_context_threshold(api, "registry-lifecycle-#{tag}", #{if(tag == "one", do: 111, else: 222)}) do
          :ok
        end
      end
    end
    """
  end

  defp assert_lifecycle_entries(tag) do
    key = "registry-lifecycle-#{tag}"

    assert runtime_entry(PromptRegistry, {:text, :system, key}) ==
             %{value: "prompt #{tag}", owner: @lifecycle_owner}

    assert runtime_entry(PromptRegistry, {:policy, :default}).owner == @lifecycle_owner
    assert runtime_entry(WorkflowRegistry, {:workflow, key}).owner == @lifecycle_owner
    assert runtime_entry(ContextRegistry, {:policy, :default}).owner == @lifecycle_owner
    assert runtime_entry(ContextRegistry, {:threshold, key}).owner == @lifecycle_owner
  end

  defp lifecycle_key_registered?(tag) do
    key = "registry-lifecycle-#{tag}"

    key_registered?(PromptRegistry, {:text, :system, key}) or
      key_registered?(WorkflowRegistry, {:workflow, key}) or
      key_registered?(ContextRegistry, {:threshold, key})
  end

  defp owner_registered?(owner) do
    Enum.any?([PromptRegistry, WorkflowRegistry, ContextRegistry], fn registry ->
      Enum.any?(registry.runtime_entries(), &(&1.owner == owner))
    end)
  end

  defp runtime_entry(registry, key) do
    case Enum.find(registry.runtime_entries(), &(&1.key == key)) do
      %{value: value, owner: owner} -> %{value: value, owner: owner}
      nil -> nil
    end
  end

  defp key_registered?(registry, key),
    do: Enum.any?(registry.runtime_entries(), &(&1.key == key))

  defp write_extension!(owner, source) do
    path = Path.join(Extensions.dir(), owner <> ".ex")
    File.write!(path, source)
    path
  end

  defp restart_extension_runtime! do
    id = Catalyst.ExtensionRuntimeSupervisor
    assert :ok = Supervisor.terminate_child(Catalyst.Supervisor, id)
    assert {:ok, pid} = Supervisor.restart_child(Catalyst.Supervisor, id)
    assert is_pid(pid)
    pid
  end
end
