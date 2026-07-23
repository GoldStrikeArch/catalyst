defmodule Catalyst.Context.GuardTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  import ExUnit.CaptureLog

  alias Catalyst.Agent.Event
  alias Catalyst.{Hooks, Message, Model}
  alias Catalyst.Context.{Compaction, Guard, Registry, Tokens}
  alias Catalyst.LLM.Context, as: LLMContext

  defmodule NoAdapter do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :not_used}
  end

  defmodule Policy do
    @behaviour Catalyst.Context.Policy

    @impl true
    def threshold(_model, %{threshold_mode: :timeout}) do
      receive do
        :release_policy -> :none
      end
    end

    def threshold(_model, %{threshold_return: return}), do: return
    def threshold(_model, context), do: {:ok, context.threshold_value}

    @impl true
    def compact(_messages, %{compact_return: return}), do: return

    def compact(_messages, context) do
      {:ok,
       %Compaction{
         replacement: context.replacement,
         summary: Map.get(context, :summary)
       }}
    end
  end

  defmodule RaisingPolicy do
    @behaviour Catalyst.Context.Policy

    @impl true
    def threshold(_model, _context), do: raise("policy failed")

    @impl true
    def compact(_messages, _context), do: {:error, :not_used}
  end

  setup do
    owner = "guard-test-#{System.unique_integer([:positive])}"
    Registry.unregister_policy()

    on_exit(fn ->
      Registry.unregister_policy()
      Hooks.unregister(owner)
    end)

    {:ok, owner: owner}
  end

  test "an ordinary request transforms once and emits only transient status", %{owner: owner} do
    parent = self()

    Hooks.register(
      :transform_context,
      fn messages, _context ->
        send(parent, :transformed)
        {:ok, messages}
      end,
      owner: owner
    )

    context = %{messages: [Message.user("hello")], system_prompt: "system"}
    config = config()
    emit = fn event -> send(parent, {:emitted, event}) end

    assert {:ok, prepared} =
             Guard.prepare_request(context, config, emit, context_threshold: 100_000)

    refute prepared.compacted?
    assert prepared.context == context
    assert_receive :transformed
    refute_receive :transformed
    assert_receive {:emitted, %Event.ContextStatus{threshold: 100_000}}
    refute_receive {:emitted, %Event.ContextCompacted{}}
  end

  test "accepted compaction transforms twice and replaces advisory accounting", %{owner: owner} do
    parent = self()
    assert :ok = Registry.register_policy(Policy, owner: owner)
    register_transform_counter(owner, parent)

    current = Message.user("current")

    context = %{
      messages: [Message.user(String.duplicate("old ", 8_000)), current],
      system_prompt: "s"
    }

    config = config()
    threshold = accepted_threshold(config, context, [current])
    emit = fn event -> send(parent, {:emitted, event}) end

    assert {:ok, prepared} =
             Guard.prepare_request(context, config, emit,
               threshold_value: threshold,
               replacement: [current]
             )

    assert prepared.compacted?
    assert prepared.context.messages == [current]
    assert_receive :transformed
    assert_receive :transformed
    refute_receive :transformed

    assert_receive {:emitted, %Event.ContextStatus{used_tokens: before}}

    assert_receive {:emitted,
                    %Event.ContextCompacted{
                      replacement: [^current],
                      replaced_count: 1,
                      tokens_before: ^before,
                      tokens_after: after_tokens,
                      policy: Policy
                    }}

    assert after_tokens < before
    assert after_tokens < threshold
    assert_receive {:emitted, %Event.ContextStatus{used_tokens: ^after_tokens}}
  end

  test "an accepted compaction is durably persisted before the request proceeds", %{owner: owner} do
    parent = self()
    assert :ok = Registry.register_policy(Policy, owner: owner)

    current = Message.user("current")

    context = %{
      messages: [Message.user(String.duplicate("old ", 8_000)), current],
      system_prompt: "s"
    }

    config = config()
    threshold = accepted_threshold(config, context, [current])
    emit = fn event -> send(parent, {:emitted, event}) end

    persist = fn event ->
      send(parent, {:persisted, event})
      :ok
    end

    assert {:ok, prepared} =
             Guard.prepare_request(context, config, emit,
               threshold_value: threshold,
               replacement: [current],
               persist_event: persist
             )

    assert prepared.compacted?
    assert_receive {:persisted, %Event.ContextCompacted{replacement: [^current]}}
    # The durable event goes only through the synchronous ack, never the
    # transient emit path, so it cannot race the provider request.
    refute_receive {:emitted, %Event.ContextCompacted{}}
  end

  test "a compaction that cannot be persisted fails instead of proceeding", %{owner: owner} do
    parent = self()
    assert :ok = Registry.register_policy(Policy, owner: owner)

    current = Message.user("current")

    context = %{
      messages: [Message.user(String.duplicate("old ", 8_000)), current],
      system_prompt: "s"
    }

    config = config()
    threshold = accepted_threshold(config, context, [current])
    emit = fn event -> send(parent, {:emitted, event}) end

    assert {:error, {:compaction_not_persisted, :stale_run}} =
             Guard.prepare_request(context, config, emit,
               threshold_value: threshold,
               replacement: [current],
               persist_event: fn _event -> {:error, :stale_run} end
             )

    refute_receive {:emitted, %Event.ContextCompacted{}}
  end

  test "a still-oversized staged replacement is rejected without installing or emitting it", %{
    owner: owner
  } do
    parent = self()
    assert :ok = Registry.register_policy(Policy, owner: owner)
    register_transform_counter(owner, parent)

    current = Message.user("current")

    context = %{
      messages: [Message.user(String.duplicate("old ", 8_000)), current],
      system_prompt: "s"
    }

    config = config()
    threshold = replacement_tokens(config, %{context | messages: [current]})
    emit = fn event -> send(parent, {:emitted, event}) end

    assert {:error, {:context_compaction_still_oversized, ^threshold, ^threshold}} =
             Guard.prepare_request(context, config, emit,
               threshold_value: threshold,
               replacement: [current]
             )

    assert context.messages != [current]
    assert_receive :transformed
    assert_receive :transformed
    refute_receive :transformed
    assert_receive {:emitted, %Event.ContextStatus{}}
    refute_receive {:emitted, %Event.ContextCompacted{}}
  end

  test "a candidate that prepends a summary without removing history is rejected", %{owner: owner} do
    assert :ok = Registry.register_policy(Policy, owner: owner)
    summary = Message.user("summary")
    context = %{messages: [Message.user(String.duplicate("old ", 2_000))], system_prompt: "s"}
    config = config()
    threshold = replacement_tokens(config, context)

    assert {:error, :context_compaction_no_progress} =
             Guard.prepare_request(context, config, fn _event -> :ok end,
               threshold_value: threshold,
               replacement: [summary | context.messages],
               summary: summary
             )
  end

  test "an empty replacement is rejected before it can diverge from the store", %{owner: owner} do
    assert :ok = Registry.register_policy(Policy, owner: owner)
    context = %{messages: [Message.user(String.duplicate("old ", 2_000))], system_prompt: "s"}
    config = config()
    threshold = replacement_tokens(config, context)

    assert {:error, {:invalid_compaction_replacement, []}} =
             Guard.prepare_request(context, config, fn _event -> :ok end,
               threshold_value: threshold,
               replacement: []
             )
  end

  test "policy timeouts and invalid callback returns are normalized", %{owner: owner} do
    previous_timeout = Application.fetch_env(:catalyst, :context_policy_timeout)
    Application.put_env(:catalyst, :context_policy_timeout, 10)
    on_exit(fn -> restore_env(:context_policy_timeout, previous_timeout) end)

    assert :ok = Registry.register_policy(Policy, owner: owner)
    context = %{messages: [Message.user("hello")], system_prompt: "s"}

    assert {:error, {:context_policy_timeout, Policy, :threshold}} =
             Guard.prepare_request(context, config(), fn _event -> :ok end,
               threshold_mode: :timeout
             )

    assert {:error, {:invalid_context_policy_return, Policy, :threshold, :invalid}} =
             Guard.prepare_request(context, config(), fn _event -> :ok end,
               threshold_return: :invalid
             )

    assert {:error, {:invalid_context_policy_return, Policy, :compact, :invalid}} =
             Guard.prepare_request(context, config(), fn _event -> :ok end,
               threshold_value: 1,
               compact_return: :invalid
             )
  end

  test "policy exceptions are normalized at the supervised task boundary", %{owner: owner} do
    assert :ok = Registry.register_policy(RaisingPolicy, owner: owner)

    capture_log(fn ->
      assert {:error, {:context_policy_exit, RaisingPolicy, :threshold, _reason}} =
               Guard.prepare_request(
                 %{messages: [Message.user("hello")], system_prompt: "s"},
                 config(),
                 fn _event -> :ok end
               )
    end)
  end

  defp config do
    %{
      model: %Model{id: "model", api: "api", context_window: 200_000},
      provider: NoAdapter,
      tools: [],
      opts: []
    }
  end

  defp accepted_threshold(config, context, replacement) do
    before = replacement_tokens(config, context)
    after_tokens = replacement_tokens(config, %{context | messages: replacement})
    assert before > after_tokens + 1
    after_tokens + 1
  end

  defp replacement_tokens(config, context) do
    llm_context = %LLMContext{
      system_prompt: context.system_prompt,
      messages: context.messages,
      tools: []
    }

    assert {:ok, estimate} =
             Tokens.estimate(config.model, llm_context, provider: config.provider)

    estimate.tokens
  end

  defp register_transform_counter(owner, parent) do
    Hooks.register(
      :transform_context,
      fn messages, _context ->
        send(parent, :transformed)
        {:ok, messages}
      end,
      owner: owner
    )
  end
end
