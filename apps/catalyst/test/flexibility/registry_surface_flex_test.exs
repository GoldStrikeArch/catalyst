defmodule Catalyst.Flex.RegistrySurfaceFlexTest do
  use Catalyst.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.Context.Registry, as: ContextRegistry
  alias Catalyst.Prompt.Registry, as: PromptRegistry
  alias Catalyst.Workflow.Registry, as: WorkflowRegistry

  @new_app_env_keys [
    :agents_dir,
    :context_policy,
    :context_policy_timeout,
    :context_thresholds,
    :prompt_policy,
    :prompt_policy_timeout,
    :prompts,
    :prompts_dir,
    :provider_cleanup_timeout,
    :subagent_max_depth,
    :workflows
  ]

  test "C7: registry overlays, live config, and prompt/agent files are baseline dimensions", %{
    flex_baseline: baseline,
    flex_home: home
  } do
    assert Enum.all?(@new_app_env_keys, &Map.has_key?(baseline.app_env, {:catalyst, &1}))
    flex_root = Path.dirname(home)
    assert Catalyst.SystemPrompt.prompts_dir() == Path.join(flex_root, "prompts")
    assert Catalyst.Tools.ListAgents.agents_dir() == Path.join(flex_root, "agents")

    owner = "registry_surface_flex"
    register_cleanup(owner)

    assert :ok = PromptRegistry.register_prompt("flex-model", "runtime prompt", owner: owner)

    assert :ok =
             WorkflowRegistry.register_workflow("flex-workflow", Catalyst.Agent.Loop,
               owner: owner
             )

    assert :ok = ContextRegistry.register_threshold("flex-model", 1_234, owner: owner)

    prompt_path = Path.join(Catalyst.SystemPrompt.prompts_dir(), "flex-model.md")
    agent_path = Path.join(Catalyst.Tools.ListAgents.agents_dir(), "flex-review.md")
    snapshot_files([prompt_path, agent_path])
    File.write!(prompt_path, "file prompt bytes")
    File.write!(agent_path, "agent prompt bytes")

    previous_prompts =
      with_app_env(:catalyst, :prompts, %{system: %{"flex-model" => "application prompt"}})

    changed = Baseline.capture()
    diffs = Baseline.diff(baseline, changed)

    assert Map.keys(diffs) |> MapSet.new() ==
             MapSet.new([
               :agent_files,
               :app_env,
               :prompt_files,
               :runtime
             ])

    assert Enum.any?(
             changed.runtime,
             &(&1.kind == :prompt and &1.key == {:text, :system, "flex-model"})
           )

    assert Enum.any?(
             changed.runtime,
             &(&1.kind == :workflow and &1.key == "flex-workflow")
           )

    assert Enum.any?(
             changed.runtime,
             &(&1.kind == :context_threshold and &1.key == "flex-model")
           )

    assert {"flex-model.md", "file prompt bytes"} in changed.prompt_files
    assert {"flex-review.md", "agent prompt bytes"} in changed.agent_files

    unregister_owner(owner)
    restore_app_env(:catalyst, :prompts, previous_prompts)
    restore_file(prompt_path, :absent)
    restore_file(agent_path, :absent)

    assert Baseline.diff(baseline, Baseline.capture()) == %{}
  end

  defp register_cleanup(owner) do
    ExUnit.Callbacks.on_exit(fn -> unregister_owner(owner) end)
  end

  defp unregister_owner(owner) do
    :ok = Catalyst.Runtime.Registry.purge_owner(owner)
  end

  defp snapshot_files(paths) do
    snapshots = Map.new(paths, &{&1, file_snapshot(&1)})

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(snapshots, fn {path, snapshot} -> restore_file(path, snapshot) end)
    end)
  end
end
