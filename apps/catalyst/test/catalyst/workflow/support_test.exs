defmodule Catalyst.Workflow.SupportTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.LLM
  alias Catalyst.Workflow.Support

  defmodule ToolA do
  end

  defmodule Provider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(model, _context, opts, sink) do
      send(opts[:test_pid], {:provider_called, model, opts})
      sink.(%LLM.Event.TextDelta{delta: "hello"})

      {:ok,
       %Catalyst.Message.Assistant{
         content: Catalyst.Content.text("hello"),
         model: model && model.id,
         stop_reason: :stop,
         timestamp: Catalyst.Message.now()
       }}
    end
  end

  defmodule AnchoringProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(model, _context, opts, _sink) do
      {:ok,
       %Catalyst.Message.Assistant{
         content: Catalyst.Content.text("anchored"),
         model: model && model.id,
         usage: %Catalyst.Usage{total_tokens: Keyword.fetch!(opts, :total_tokens)},
         stop_reason: :stop,
         timestamp: Catalyst.Message.now()
       }}
    end

    @impl true
    def context_fingerprint(model, context, opts) do
      {:ok, Catalyst.Context.Tokens.semantic_digest(model, context, opts)}
    end
  end

  defmodule Guard do
    def prepare_request(context, config, emit, opts) do
      send(config.test_pid, {:guard_called, context, config, emit, opts})

      {:ok,
       %{
         context: %{system_prompt: context.system_prompt, messages: []},
         llm_context: context,
         status: %Event.ContextStatus{
           used_tokens: 10,
           threshold: 100,
           threshold_source: :test,
           anchored: false,
           estimate_source: :coarse,
           context_digest: "before"
         },
         compacted?: false
       }}
    end
  end

  setup do
    owner = "workflow_support_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Catalyst.Hooks.unregister(owner) end)
    {:ok, owner: owner}
  end

  test "observed_emit sends to the workflow sink and ordered observers", %{owner: owner} do
    test_pid = self()
    session_key = make_ref()
    events = [%Event.AgentStart{}, %Event.ContextCompacted{replacement: []}]

    Catalyst.Hooks.on(fn observed -> send(test_pid, {:observed, observed}) end, owner: owner)

    emit =
      Support.observed_emit(fn emitted -> send(test_pid, {:emitted, emitted}) end, %{
        opts: [session_id: session_key]
      })

    Enum.each(events, emit)

    Enum.each(events, fn event ->
      assert_receive {:emitted, ^event}
    end)

    assert :ok = Catalyst.Hooks.await_observers(session_key)

    Enum.each(events, fn event ->
      assert_receive {:observed, ^event}
    end)
  end

  test "live tools resolve from the original selector and depth filtering is final" do
    spawn_agent = Module.concat([Catalyst, Tools, SpawnAgent])
    source = fn -> [ToolA, spawn_agent] end

    config = %{
      tools: [],
      tool_source: source,
      agent_depth: 3,
      opts: [subagent_max_depth: 3]
    }

    resolved = Support.resolve_turn_tools(config)

    assert resolved.tool_source == source
    assert resolved.tools == [ToolA]
    assert Support.at_subagent_depth_limit?(resolved)

    below_limit = %{config | agent_depth: 2}
    assert Support.resolve_tools(below_limit) == [ToolA, spawn_agent]
    refute Support.at_subagent_depth_limit?(below_limit)

    extensions_at_limit = %{
      tools: :extensions,
      tool_source: :extensions,
      agent_depth: 3,
      opts: [subagent_max_depth: 3]
    }

    refute spawn_agent in Support.resolve_tools(extensions_at_limit)
  end

  test "the provider fallback emits normalized message updates" do
    model = %Catalyst.Model{id: "test-model", api: "test"}
    context = %Catalyst.LLM.Context{system_prompt: "system", messages: [], tools: []}
    config = %{provider: Provider, opts: [test_pid: self()]}
    emit = fn event -> send(self(), {:event, event}) end

    assert {:ok, %Catalyst.Message.Assistant{}} =
             Support.request_provider(model, context, config, emit, guard: false)

    assert_receive {:provider_called, ^model, _opts}

    assert_receive {:event, %Event.MessageUpdate{llm_event: %LLM.Event.TextDelta{delta: "hello"}}}
  end

  test "a guarded ordinary request prepares and then streams the provider" do
    model = %Catalyst.Model{id: "test-model", api: "test"}
    context = %Catalyst.LLM.Context{system_prompt: "system", messages: [], tools: []}
    config = %{provider: Provider, opts: [test_pid: self()], test_pid: self()}
    emit = fn _event -> :ok end

    assert {:ok, %Catalyst.Message.Assistant{}, prepared} =
             Support.request_provider(model, context, config, emit, guard: Guard)

    assert prepared.llm_context == context

    assert_receive {:guard_called, ^context, guarded_config, emitted, guard_opts}
                   when is_function(emitted, 1) and is_list(guard_opts)

    assert guarded_config.model == model
    assert_receive {:provider_called, ^model, _}
  end

  test "guarded provider responses attach digests and expose shared anchor status emission" do
    model = %Catalyst.Model{id: "anchored-model", api: "test"}
    context = %Catalyst.LLM.Context{system_prompt: "system", messages: [], tools: []}

    config = %{
      provider: AnchoringProvider,
      opts: [total_tokens: 42],
      test_pid: self()
    }

    emit = fn event -> send(self(), {:anchor_event, event}) end

    assert {:ok, assistant, prepared} =
             Support.request_provider(model, context, config, emit, guard: Guard)

    assert is_binary(assistant.usage.context_digest)
    assert :ok = Support.emit_anchor_status(assistant, prepared.status, emit)

    assert_receive {:anchor_event,
                    %Event.ContextStatus{
                      used_tokens: 42,
                      anchored: true,
                      estimate_source: :provider,
                      threshold: 100
                    }}
  end

  test "anchored status recomputes a built-in threshold for the anchored ratio" do
    model = %Catalyst.Model{id: "anchored-window", api: "test", context_window: 100_000}

    status = %Event.ContextStatus{
      used_tokens: 60_000,
      threshold: 70_000,
      threshold_source: :builtin,
      anchored: false,
      estimate_source: :coarse,
      context_digest: "pre-request"
    }

    assistant = %Catalyst.Message.Assistant{
      content: [],
      stop_reason: :stop,
      usage: %Catalyst.Usage{total_tokens: 60_000, context_digest: "anchored-digest"}
    }

    emit = fn event -> send(self(), {:anchor_event, event}) end
    assert :ok = Support.emit_anchor_status(assistant, status, emit, model)

    # 100_000 window * 0.85 anchored ratio, not the unanchored 70_000 the
    # pre-request estimate resolved.
    assert_receive {:anchor_event,
                    %Event.ContextStatus{
                      anchored: true,
                      threshold: 85_000,
                      threshold_source: :builtin
                    }}
  end

  test "anchored status reuses explicit anchor-independent thresholds unchanged" do
    model = %Catalyst.Model{id: "anchored-window", api: "test", context_window: 100_000}

    status = %Event.ContextStatus{
      used_tokens: 60_000,
      threshold: 64_000,
      threshold_source: {:session, :context_threshold},
      anchored: false,
      estimate_source: :coarse,
      context_digest: "pre-request"
    }

    assistant = %Catalyst.Message.Assistant{
      content: [],
      stop_reason: :stop,
      usage: %Catalyst.Usage{total_tokens: 60_000, context_digest: "anchored-digest"}
    }

    emit = fn event -> send(self(), {:anchor_event, event}) end
    assert :ok = Support.emit_anchor_status(assistant, status, emit, model)

    assert_receive {:anchor_event,
                    %Event.ContextStatus{
                      anchored: true,
                      threshold: 64_000,
                      threshold_source: {:session, :context_threshold}
                    }}
  end

  test "an unavailable guard and invalid providers are tagged" do
    model = %Catalyst.Model{id: "test-model", api: "test"}
    context = %Catalyst.LLM.Context{system_prompt: "system", messages: [], tools: []}
    emit = fn event -> send(self(), {:event, event}) end
    missing_guard = Module.concat([Catalyst, MissingGuard])

    assert {:error, {:invalid_context_guard, ^missing_guard}} =
             Support.request_provider(
               model,
               context,
               %{provider: Provider, opts: [test_pid: self()]},
               emit,
               guard: missing_guard
             )

    refute_receive {:provider_called, ^model, _opts}

    assert {:error, {:invalid_context_guard, "not-a-module"}} =
             Support.request_provider(
               model,
               context,
               %{provider: Provider, opts: [test_pid: self()]},
               emit,
               guard: "not-a-module"
             )

    refute_receive {:provider_called, ^model, _opts}

    assert {:error, {:invalid_provider, nil}} =
             Support.request_provider(model, context, %{provider: nil}, emit, guard: false)
  end
end
