defmodule Catalyst.Session.RunContextBoundaryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2, restore_runtime_policy: 2, runtime_policy: 1]

  alias Catalyst.Model
  alias Catalyst.LLM.OpenAICodex.Catalog
  alias Catalyst.Prompt.Registry, as: PromptRegistry
  alias Catalyst.Session.RunContext
  alias Catalyst.Workflow.Template

  defmodule TemplateStore do
    def list, do: {:ok, [template()]}
    def fetch("pinned-template"), do: {:ok, template()}
    def fetch(_name), do: :error

    defp template do
      {:ok, template} =
        Catalyst.Workflow.Template.new(%{
          "version" => 1,
          "id" => "pinned-template",
          "name" => "Pinned template",
          "description" => "Pinned test template",
          "stages" => [
            %{
              "id" => "pinned-step",
              "name" => "Pinned step",
              "prompt" => "Pinned step",
              "preset" => "implementation",
              "tool_profile" => "coding",
              "model" => "inherit",
              "reasoning_effort" => "high",
              "inputs" => ["goal"],
              "artifact" => "result",
              "inactivity_timeout_ms" => 30_000,
              "timeout_ms" => 60_000,
              "max_attempts" => 3
            }
          ]
        })

      template
    end
  end

  setup do
    previous_timeout = Application.fetch_env(:catalyst, :prompt_policy_timeout)
    previous_policy = runtime_policy(PromptRegistry)

    :ok = PromptRegistry.unregister_policy()

    :ok =
      PromptRegistry.register_policy(Catalyst.Test.RunBoundaryPrompt,
        owner: :run_boundary_test
      )

    Application.put_env(:catalyst, :prompt_policy_timeout, 25)

    on_exit(fn ->
      :ok = PromptRegistry.unregister_policy()
      restore_runtime_policy(PromptRegistry, previous_policy)
      restore_env(:prompt_policy_timeout, previous_timeout)
    end)

    :ok
  end

  test "template selections are pinned in run config and diagnostics" do
    previous_store = Application.fetch_env(:catalyst, :workflow_template_store)
    Application.put_env(:catalyst, :workflow_template_store, TemplateStore)

    on_exit(fn -> restore_env(:workflow_template_store, previous_store) end)
    template = TemplateStore.fetch("pinned-template") |> elem(1)
    digest = Template.digest(template)

    state =
      model("template-model", "template-provider")
      |> build_state()
      |> Map.update!(:opts, fn opts ->
        opts
        |> Keyword.delete(:loop)
        |> Keyword.put(:workflow, "pinned-template")
      end)

    assert {:ok, run} =
             RunContext.build(state, self(), make_ref(), Catalyst.LLM.Faux)

    assert run.config.loop == Catalyst.Workflow.Runner

    assert %{
             name: "pinned-template",
             module: Catalyst.Workflow.Runner,
             source:
               {:template,
                %{
                  id: "pinned-template",
                  name: "Pinned template",
                  version: 1,
                  digest: ^digest
                }},
             template: ^template
           } = run.config.workflow

    assert run.metadata.workflow == run.config.workflow
    assert run.config.run_engine_resolution.claim.implementation == Catalyst.Workflow.Runner
    assert run.metadata.run_engine.service == "agent.run_engine/pinned-template"
    assert run.metadata.run_engine.binding == {:pin, :run}
  end

  test "worker prompt failures are normalized at the supervised task boundary" do
    assert {:error, {:prompt_resolution, :policy_rejected}} =
             RunContext.resolve_prompt(state(prompt_mode: {:error, :policy_rejected}))

    assert {:error, {:invalid_prompt_policy_return, :not_a_resolution}} =
             RunContext.resolve_prompt(state(prompt_mode: {:invalid, :not_a_resolution}))

    assert {:error, {:prompt_policy_exit, exception_reason}} =
             RunContext.resolve_prompt(state(prompt_mode: {:raise, "prompt exploded"}))

    assert Exception.format_exit(exception_reason) =~ "prompt exploded"

    assert {:error, {:prompt_policy_exit, :prompt_policy_exit}} =
             RunContext.resolve_prompt(state(prompt_mode: {:exit, :prompt_policy_exit}))

    assert {:error, :prompt_policy_timeout} =
             RunContext.resolve_prompt(state(prompt_mode: :timeout))
  end

  test "model epochs resolve once per model key, reuse cached prompts, and report hook prompts" do
    model_a = model("model-a", "provider-a")
    model_b = model("model-b", "provider-b")

    assert {:ok, run} =
             RunContext.build(
               build_state(model_a),
               self(),
               make_ref(),
               Catalyst.LLM.Faux
             )

    assert_receive {:run_boundary_prompt_resolved, "model-a", _policy_worker}
    assert run.context.system_prompt == "prompt for model-a"

    test_pid = self()

    config =
      Map.put(run.config, :report_metadata, fn metadata ->
        send(test_pid, {:run_boundary_epoch_metadata, metadata})
      end)

    edited_opts = Keyword.put(config.opts, :run_boundary_prompt_text, "edited mid-run")
    edited_config = Map.put(config, :opts, edited_opts)

    assert {:ok, stable_context, stable_config} =
             RunContext.reconcile_request(run.context, edited_config)

    assert stable_context == run.context
    assert stable_config == edited_config
    refute_receive {:run_boundary_prompt_resolved, _model_id, _policy_worker}

    assert {:ok, context_b, config_b} =
             run.context
             |> RunContext.reconcile_request(Map.put(config, :model, model_b))

    assert_receive {:run_boundary_prompt_resolved, "model-b", _policy_worker}
    assert_receive {:run_boundary_epoch_metadata, metadata_b}
    assert context_b.system_prompt == "prompt for model-b"
    assert config_b.active_model_identity == {"model-b", "test-api", "provider-b"}
    assert metadata_b.context.model_id == "model-b"
    assert metadata_b.context_status == nil

    assert {:ok, context_a, config_a} =
             context_b
             |> RunContext.reconcile_request(Map.put(config_b, :model, model_a))

    assert_receive {:run_boundary_epoch_metadata, metadata_a}
    refute_receive {:run_boundary_prompt_resolved, "model-a", _policy_worker}
    assert context_a.system_prompt == "prompt for model-a"
    assert metadata_a.context.model_id == "model-a"

    hook_context = Map.put(context_a, :system_prompt, "hook-selected prompt")

    assert {:ok, ^hook_context, hook_config} =
             RunContext.reconcile_request(hook_context, config_a)

    assert_receive {:run_boundary_epoch_metadata, hook_metadata}
    assert hook_config.active_prompt == "hook-selected prompt"
    assert hook_metadata.prompt.text == "hook-selected prompt"
    assert hook_metadata.prompt.sources == [{:hook, :prepare_next_turn}]
    assert hook_metadata.context_status == nil
    refute_receive {:run_boundary_prompt_resolved, _model_id, _policy_worker}
  end

  test "missing hook prompt keys preserve the active prompt and nil clears an override" do
    model = model("hook-prompt", "provider")

    assert {:ok, run} =
             RunContext.build(build_state(model), self(), make_ref(), Catalyst.LLM.Faux)

    assert_receive {:run_boundary_prompt_resolved, "hook-prompt", _policy_worker}

    missing_prompt = Map.delete(run.context, :system_prompt)

    assert {:ok, restored, stable_config} =
             RunContext.reconcile_request(missing_prompt, run.config)

    assert restored.system_prompt == "prompt for hook-prompt"
    assert stable_config.active_prompt == "prompt for hook-prompt"
    refute_receive {:run_boundary_prompt_resolved, _model_id, _policy_worker}

    hook_context = Map.put(restored, :system_prompt, "temporary hook prompt")
    assert {:ok, hooked, hook_config} = RunContext.reconcile_request(hook_context, stable_config)
    assert hooked.system_prompt == "temporary hook prompt"

    cleared = Map.put(hooked, :system_prompt, nil)

    assert {:ok, cleared_context, cleared_config} =
             RunContext.reconcile_request(cleared, hook_config)

    assert cleared_context.system_prompt == "prompt for hook-prompt"
    assert cleared_config.active_prompt == "prompt for hook-prompt"
    refute_receive {:run_boundary_prompt_resolved, _model_id, _policy_worker}
  end

  test "a provider-only identity change starts an epoch without re-resolving the model-key prompt" do
    model = model("same-model", "provider-a")

    assert {:ok, run} =
             RunContext.build(build_state(model), self(), make_ref(), Catalyst.LLM.Faux)

    assert_receive {:run_boundary_prompt_resolved, "same-model", _policy_worker}

    test_pid = self()

    config =
      run.config
      |> Map.put(:model, %{model | provider: "provider-b"})
      |> Map.put(:report_metadata, fn metadata ->
        send(test_pid, {:run_boundary_epoch_metadata, metadata})
      end)

    assert {:ok, context, next_config} = RunContext.reconcile_request(run.context, config)

    assert_receive {:run_boundary_epoch_metadata, metadata}
    refute_receive {:run_boundary_prompt_resolved, "same-model", _policy_worker}
    assert context.system_prompt == "prompt for same-model"
    assert next_config.active_model_identity == {"same-model", "test-api", "provider-b"}
    assert metadata.context.provider == "provider-b"
    assert metadata.context_status == nil
  end

  test "a stable hook prompt survives a later model-only epoch" do
    model_a = model("hook-stable-a", "provider")
    model_b = model("hook-stable-b", "provider")

    assert {:ok, run} =
             RunContext.build(build_state(model_a), self(), make_ref(), Catalyst.LLM.Faux)

    assert_receive {:run_boundary_prompt_resolved, "hook-stable-a", _policy_worker}

    test_pid = self()

    config =
      run.config
      |> Map.put(:report_metadata, fn metadata ->
        send(test_pid, {:run_boundary_epoch_metadata, metadata})
      end)

    hook_context = Map.put(run.context, :system_prompt, "sticky hook prompt")

    assert {:ok, hooked, hook_config} = RunContext.reconcile_request(hook_context, config)
    assert_receive {:run_boundary_epoch_metadata, _}
    assert hooked.system_prompt == "sticky hook prompt"
    assert hook_config.hook_prompt_override == "sticky hook prompt"

    # Same hook text as active_prompt: prompt_changed? would have been false.
    stable_hook = Map.put(hooked, :system_prompt, "sticky hook prompt")

    assert {:ok, after_model, next_config} =
             RunContext.reconcile_request(stable_hook, Map.put(hook_config, :model, model_b))

    # Model reconciliation reports first; the hook override is reapplied after.
    assert_receive {:run_boundary_epoch_metadata, model_metadata}
    assert model_metadata.context.model_id == "hook-stable-b"

    assert_receive {:run_boundary_epoch_metadata, metadata}
    assert after_model.system_prompt == "sticky hook prompt"
    assert next_config.active_prompt == "sticky hook prompt"
    assert next_config.hook_prompt_override == "sticky hook prompt"
    assert metadata.prompt.text == "sticky hook prompt"
    assert metadata.prompt.sources == [{:hook, :prepare_next_turn}]
    assert metadata.context.model_id == "hook-stable-b"
  end

  test "a hook prompt equal to the active resolution is not a sticky override" do
    model_a = model("hook-equal-a", "provider")
    model_b = model("hook-equal-b", "provider")

    assert {:ok, run} =
             RunContext.build(build_state(model_a), self(), make_ref(), Catalyst.LLM.Faux)

    assert_receive {:run_boundary_prompt_resolved, "hook-equal-a", _policy_worker}

    config = Map.put(run.config, :report_metadata, fn _metadata -> :ok end)

    # Documented contract: writing back exactly the active prompt is
    # indistinguishable from an untouched context and stores no override.
    equal_hook = Map.put(run.context, :system_prompt, config.active_prompt)

    assert {:ok, context, next_config} = RunContext.reconcile_request(equal_hook, config)
    assert context.system_prompt == config.active_prompt
    assert Map.get(next_config, :hook_prompt_override) == nil

    # A later model-only epoch therefore resolves the new model's prompt
    # instead of pinning the coincidentally equal text.
    assert {:ok, after_model, _final_config} =
             RunContext.reconcile_request(context, Map.put(next_config, :model, model_b))

    assert_receive {:run_boundary_prompt_resolved, "hook-equal-b", _policy_worker}
    assert after_model.system_prompt == "prompt for hook-equal-b"
  end

  test "Codex catalog reconciliation covers legacy, resumed, and session-owned models" do
    legacy = %Model{
      id: "legacy-codex",
      api: "openai-codex-responses",
      provider: "openai-codex"
    }

    entry =
      Catalog.normalize(%{
        id: legacy.id,
        context_window: 200_000,
        max_context_window: 240_000,
        effective_context_window_percent: 90,
        auto_compact_token_limit: 170_000
      })

    assert {:ok, resolved_legacy} =
             RunContext.resolve_epoch_model(legacy, %{models: [entry]})

    assert resolved_legacy.context_window == 200_000
    assert resolved_legacy.max_context_window == 240_000
    assert resolved_legacy.effective_context_window_percent == 90
    assert resolved_legacy.auto_compact_token_limit == 170_000
    assert resolved_legacy.context_window_source == :catalog

    resumed = %{
      legacy
      | id: "resumed-codex",
        context_window: 111_000,
        max_context_window: 120_000,
        context_window_source: nil
    }

    assert {:ok, resolved_resumed} =
             RunContext.resolve_epoch_model(resumed, %{models: []})

    assert resolved_resumed.context_window == 111_000
    assert resolved_resumed.max_context_window == 120_000
    assert resolved_resumed.context_window_source == :persisted

    session_owned = %{resumed | context_window_source: :session}
    session_entry = Catalog.normalize(%{id: resumed.id, context_window: 300_000})

    assert {:ok, ^session_owned} =
             RunContext.resolve_epoch_model(session_owned, %{models: [session_entry]})
  end

  test "model epochs preserve the session prompt override" do
    model_a = model("override-a", "provider-a")
    model_b = model("override-b", "provider-b")
    state = %{build_state(model_a) | system_prompt: "owned child prompt"}

    assert {:ok, run} = RunContext.build(state, self(), make_ref(), Catalyst.LLM.Faux)
    assert_receive {:run_boundary_prompt_resolved, "override-a", _policy_worker}
    assert run.context.system_prompt == "owned child prompt"

    assert {:ok, context_b, _config_b} =
             RunContext.reconcile_request(run.context, Map.put(run.config, :model, model_b))

    assert_receive {:run_boundary_prompt_resolved, "override-b", _policy_worker}
    assert context_b.system_prompt == "owned child prompt"
  end

  defp state(opts) do
    %{
      id: "run-context-boundary",
      cwd: ".",
      model: model("prompt-model", "prompt-provider"),
      system_prompt: nil,
      opts: [
        run_boundary_test_pid: self(),
        run_boundary_prompt_mode: Keyword.fetch!(opts, :prompt_mode)
      ]
    }
  end

  defp build_state(model) do
    %{
      id: "run-context-epoch",
      cwd: ".",
      model: model,
      provider: Catalyst.LLM.Faux,
      system_prompt: nil,
      tools: [],
      opts: [
        loop: Catalyst.Test.RunBoundaryWorkflow,
        run_boundary_test_pid: self()
      ],
      messages: [],
      root_session_id: "run-context-epoch",
      agent_depth: 0
    }
  end

  defp model(id, provider),
    do: %Model{id: id, api: "test-api", provider: provider, context_window: 10_000}
end
