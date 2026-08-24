defmodule Catalyst.Context.WindowTest do
  use ExUnit.Case, async: false

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Context.{Registry, Transcript, Window}

  defmodule ToolUseSummarizer do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink) do
      {:ok,
       %Message.Assistant{
         content: Content.text("nonblank summary text"),
         stop_reason: :tool_use,
         timestamp: Message.now()
       }}
    end
  end

  setup do
    previous = Application.get_env(:catalyst, :context_thresholds)
    Application.delete_env(:catalyst, :context_thresholds)

    for key <- ["model", "api", :default], do: Registry.unregister_threshold(key)

    on_exit(fn ->
      for key <- ["model", "api", :default], do: Registry.unregister_threshold(key)

      case previous do
        nil -> Application.delete_env(:catalyst, :context_thresholds)
        value -> Application.put_env(:catalyst, :context_thresholds, value)
      end
    end)

    :ok
  end

  test "effective windows apply Codex's absent 95-percent default and explicit percentages" do
    codex = %Model{id: "model", api: "openai-codex-responses", context_window: 100_000}
    other = %Model{id: "model", api: "other", max_context_window: 200_000}
    explicit = %{other | effective_context_window_percent: 80}
    fractional = %{other | effective_context_window_percent: 0.5}

    assert Window.effective_window(codex) == {:ok, 95_000}
    assert Window.effective_window(other) == {:ok, 200_000}
    assert Window.effective_window(explicit) == {:ok, 160_000}
    assert Window.effective_window(fractional) == {:ok, 1_000}
  end

  test "session values win and explicit absolute thresholds above the window fail" do
    model = %Model{id: "model", api: "api", context_window: 1_000}

    assert {:ok, 500, {:session, :context_threshold}} =
             Window.threshold_with_source(model, %{context_threshold: 500})

    assert {:ok, :none, {:session, :context_threshold}} =
             Window.threshold_with_source(model, %{opts: [context_threshold: :none]})

    assert {:error,
            {:context_threshold_exceeds_window, 1_001, 1_000, {:session, :context_threshold}}} =
             Window.threshold_with_source(model, %{context_threshold: 1_001})
  end

  test "built-in thresholds conservatively combine catalog limit and one coarse ratio" do
    model = %Model{
      id: "model",
      api: "openai-codex-responses",
      context_window: 100_000,
      auto_compact_token_limit: 999_999
    }

    assert {:ok, 66_500, :builtin} = Window.builtin_threshold(model)

    no_window = %Model{id: "model", api: "api", auto_compact_token_limit: 12_000}
    assert {:ok, 12_000, :builtin} = Window.builtin_threshold(no_window)

    tiny = %Model{id: "model", api: "api", context_window: 1, auto_compact_token_limit: 10}
    assert :missing = Window.builtin_threshold(tiny)

    assert {:error, {:context_ratio_without_window, 0.8, {:session, :context_threshold}}} =
             Window.threshold_with_source(no_window, %{context_threshold: 0.8})
  end

  test "tool-call groups are indivisible and duplicate or orphan ids are rejected" do
    valid = [
      Message.user("old"),
      tool_assistant(["one", "two"]),
      tool_result("one"),
      tool_result("two")
    ]

    assert :ok = Transcript.validate_transcript(valid)

    duplicate_calls = [tool_assistant(["same", "same"]), tool_result("same")]

    assert {:error, {:invalid_tool_result_group, _, _}} =
             Transcript.validate_transcript(duplicate_calls)

    assert {:error, :orphan_tool_result} = Transcript.validate_transcript([tool_result("orphan")])

    assert {:error, {:invalid_transcript_message, :foreign}} =
             Transcript.validate_transcript([Message.user("ok"), :foreign])
  end

  test "compaction preserves the active tool group and current input" do
    active_assistant = tool_assistant(["call"])
    active_result = tool_result("call")
    current = Message.user("current input")

    messages = [
      Message.user("old user"),
      assistant("old answer"),
      active_assistant,
      active_result,
      current
    ]

    context = %{
      threshold: 100,
      tokens_before: 200,
      summary_fun: fn _removed -> "faithful summary" end,
      estimate_replacement: fn replacement -> length(replacement) * 10 end
    }

    assert {:ok, compaction} = Window.compact(messages, context)
    assert %Message.User{} = compaction.summary

    assert compaction.replacement == [
             compaction.summary,
             active_assistant,
             active_result,
             current
           ]

    assert :ok = Transcript.validate_transcript(compaction.replacement)
  end

  test "a summary that misses the target is discarded before tightening old units" do
    parent = self()

    messages = [
      Message.user("a"),
      assistant("b"),
      Message.user("c"),
      assistant("d"),
      Message.user("e")
    ]

    context = %{
      threshold: 100,
      tokens_before: 200,
      summary_fun: fn removed ->
        send(parent, {:summary_input, removed})
        "summary"
      end,
      estimate_replacement: fn replacement -> length(replacement) * 20 end
    }

    assert {:ok, compaction} = Window.compact(messages, context)

    assert_receive {:summary_input, [summarized]}
    assert Content.text_of(summarized.content) == "a"
    assert compaction.summary == nil
    assert compaction.replacement == Enum.drop(messages, 2)
  end

  test "the protected suffix may miss the hysteresis target while remaining below the trigger" do
    messages = [Message.user("old"), assistant("answer"), Message.user("current")]

    context = %{
      threshold: 100,
      tokens_before: 200,
      estimate_replacement: fn _replacement -> 80 end
    }

    assert {:ok, compaction} = Window.compact(messages, context)
    assert compaction.summary == nil
    assert compaction.replacement == Enum.drop(messages, 1)

    summary_context =
      context
      |> Map.put(:summary_fun, fn _removed -> "summary" end)
      |> Map.put(:estimate_replacement, fn replacement ->
        if(length(replacement) == 3, do: 90, else: 80)
      end)

    assert {:ok, summary_free} = Window.compact(messages, summary_context)
    assert summary_free.summary == nil
    assert summary_free.replacement == Enum.drop(messages, 1)

    assert {:error, :irreducible_context} =
             Window.compact(messages, %{
               context
               | estimate_replacement: fn _replacement -> 100 end
             })
  end

  test "oversized summaries are discarded instead of being truncated and persisted" do
    messages = [Message.user("old"), assistant("answer"), Message.user("current")]

    context = %{
      threshold: 100,
      tokens_before: 200,
      summary_fun: fn _removed -> String.duplicate("s", 20_000) end,
      estimate_replacement: fn replacement -> length(replacement) * 10 end
    }

    assert {:ok, compaction} = Window.compact(messages, context)
    assert compaction.summary == nil
    assert compaction.replacement == Enum.drop(messages, 1)
  end

  test "tool-result summary bounds count Unicode characters rather than bytes" do
    assert tool_result_render_bytes(2_000) > tool_result_render_bytes(1_000)
    assert tool_result_render_bytes(2_001) == tool_result_render_bytes(2_000)
  end

  test "an invalid summarizer stop reason falls back to the summary-free cut" do
    messages = [Message.user("old"), assistant("answer"), Message.user("current")]

    context = %{
      threshold: 100,
      tokens_before: 200,
      provider: Catalyst.Context.WindowTest.ToolUseSummarizer,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      estimate_replacement: fn replacement -> length(replacement) * 10 end
    }

    assert {:ok, compaction} = Window.compact(messages, context)
    assert compaction.summary == nil
    assert compaction.replacement == Enum.drop(messages, 1)
  end

  test "summarizer timeout falls back deterministically and protected-only input is irreducible" do
    messages = [Message.user("old"), assistant("answer"), Message.user("current")]

    context = %{
      threshold: 100,
      tokens_before: 200,
      compaction_timeout: 5,
      summary_fun: fn _removed ->
        receive do
          :never -> "not reached"
        end
      end,
      estimate_replacement: fn replacement -> length(replacement) * 10 end
    }

    assert {:ok, compaction} = Window.compact(messages, context)
    assert compaction.summary == nil
    assert compaction.replacement == Enum.drop(messages, 1)

    assert {:error, :irreducible_context} =
             Window.compact(Enum.drop(messages, 1), Map.delete(context, :summary_fun))
  end

  test "generated cut matrix preserves suffix and accounting invariants" do
    for old_turns <- 1..8,
        token_weight <- [7, 13, 20],
        summarize? <- [false, true] do
      messages = generated_history(old_turns)

      context = %{
        threshold: 100,
        tokens_before: 500,
        estimate_replacement: fn replacement -> length(replacement) * token_weight end
      }

      context =
        case summarize? do
          true -> Map.put(context, :summary_fun, fn _removed -> "summary" end)
          false -> context
        end

      assert {:ok, compaction} = Window.compact(messages, context)

      summary_count = length(List.wrap(compaction.summary))
      retained = Enum.drop(compaction.replacement, summary_count)

      assert retained == Enum.take(messages, -length(retained))
      assert List.last(retained) == List.last(messages)
      # History must shrink, and the accepted candidate must satisfy the
      # 75-token hysteresis target under the test estimator.
      assert length(retained) < length(messages)
      assert length(compaction.replacement) * token_weight <= 75
      assert :ok = Transcript.validate_transcript(compaction.replacement)
    end
  end

  test "companion ids are unique per compaction attempt outside ordinary session ids" do
    first = Window.companion_id("session-1")
    second = Window.companion_id("session-1")

    assert String.starts_with?(first, "@compact:")
    refute first == second
    refute first == Window.companion_id("session-2")
  end

  defp generated_history(old_turns) do
    old_messages =
      Enum.flat_map(1..old_turns, fn index ->
        [Message.user("old #{index}"), assistant("answer #{index}")]
      end)

    Enum.concat(old_messages, [Message.user("current")])
  end

  defp assistant(text) do
    %Message.Assistant{content: Content.text(text), stop_reason: :stop}
  end

  defp tool_assistant(ids) do
    calls =
      Enum.map(ids, fn id ->
        %Content.ToolCall{id: id, name: "read", arguments: %{"path" => id}}
      end)

    %Message.Assistant{content: calls, stop_reason: :tool_use}
  end

  defp tool_result(id), do: tool_result(id, "result")

  defp tool_result(id, text) do
    %Message.ToolResult{tool_call_id: id, tool_name: "read", content: Content.text(text)}
  end

  defp tool_result_render_bytes(character_count) do
    "call"
    |> tool_result(String.duplicate("🙂", character_count))
    |> Catalyst.Context.Summarizer.render_message()
    |> byte_size()
  end
end
