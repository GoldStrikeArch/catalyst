defmodule Catalyst.Session.StoreTest do
  use ExUnit.Case, async: true

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.Session.Store

  test "messages round-trip through JSONL" do
    store = Store.new("/tmp/some/project")
    on_exit(fn -> File.rm_rf!(store.path) end)

    messages = [
      Message.user("hello"),
      %Message.Assistant{
        content: [
          %Content.Text{text: "let me look"},
          %Content.ToolCall{id: "call_1", name: "read", arguments: %{"path" => "x"}}
        ],
        provider: "faux",
        api: "faux",
        model: "faux-1",
        usage: %Usage{input: 8, output: 5, cache_read: 2, total_tokens: 15, cost: 0.01},
        stop_reason: :tool_use,
        response_id: "resp_1",
        timestamp: 123
      },
      %Message.ToolResult{
        tool_call_id: "call_1",
        tool_name: "read",
        content: [%Content.Text{text: "file body"}],
        details: %{"path" => "x"},
        is_error: false,
        timestamp: 124
      }
    ]

    Enum.each(messages, &Store.append_message(store, &1))
    loaded = Store.load(store.path)

    assert length(loaded) == 3
    assert [%Message.User{}, %Message.Assistant{} = a, %Message.ToolResult{} = tr] = loaded

    assert Content.text_of(a.content) == "let me look"
    assert a.stop_reason == :tool_use
    assert a.usage == %Usage{input: 8, output: 5, cache_read: 2, total_tokens: 15, cost: 0.01}
    assert a.response_id == "resp_1"
    [_text, tool_call] = a.content
    assert %Content.ToolCall{name: "read", arguments: %{"path" => "x"}} = tool_call

    assert tr.tool_name == "read"
    assert Content.text_of(tr.content) == "file body"
  end

  test "header line is not decoded as a message" do
    store = Store.new("/tmp/proj2")
    on_exit(fn -> File.rm_rf!(store.path) end)
    assert Store.load(store.path) == []
  end

  test "model_change and thinking_level_change entries fold to the LAST values" do
    store = Store.new("/tmp/some/project")
    on_exit(fn -> File.rm_rf!(store.path) end)

    # A fresh file has no settings.
    assert %{model: nil, thinking_level: nil} = Store.load_settings(store.path)

    m1 = %Catalyst.Model{id: "m-1", api: "faux", provider: "faux", input: [:text]}
    m2 = %Catalyst.Model{id: "m-2", api: "faux", provider: "faux", input: [:text, :image]}

    Store.append_model_change(store, m1)
    Store.append_thinking_level_change(store, "low")
    Store.append_message(store, Message.user("hi"))
    Store.append_model_change(store, m2)
    Store.append_thinking_level_change(store, "xhigh")
    # Settings are session-level: a transcript reset does not undo them.
    Store.append_reset(store)

    settings = Store.load_settings(store.path)
    assert settings.model.id == "m-2"
    assert settings.model.input == [:text, :image]
    assert settings.thinking_level == "xhigh"
    assert settings.model_set?
    assert settings.thinking_level_set?

    Store.append_model_change(store, nil)
    Store.append_thinking_level_change(store, nil)

    assert %{
             model: nil,
             model_set?: true,
             thinking_level: nil,
             thinking_level_set?: true
           } = Store.load_settings(store.path)

    # The transcript loader ignores settings entries (and honors the reset).
    assert Store.load(store.path) == []
  end

  test "load_state folds transcript and settings together while preserving tombstones" do
    store = Store.new("/tmp/proj_load_state")
    on_exit(fn -> File.rm_rf!(store.path) end)

    model = %Catalyst.Model{id: "m-1", api: "faux", provider: "faux", input: [:text]}

    Store.append_message(store, Message.user("discarded"))
    Store.append_model_change(store, model)
    Store.append_thinking_level_change(store, "high")
    Store.append_reset(store)
    Store.append_message(store, Message.user("kept"))
    Store.append_model_change(store, nil)
    Store.append_thinking_level_change(store, nil)

    assert {:ok,
            %{
              messages: [%Message.User{} = message],
              model: nil,
              model_set?: true,
              thinking_level: nil,
              thinking_level_set?: true
            }} = Store.load_state(store.path)

    assert Content.text_of(message.content) == "kept"
  end

  test "one mixed JSONL log folds every persisted entry type" do
    store =
      Store.new("/tmp/proj_every_entry",
        parent_id: "parent",
        root_session_id: "root",
        agent_depth: 2
      )

    on_exit(fn -> File.rm_rf!(store.path) end)

    model = %Catalyst.Model{
      id: "mixed-model",
      api: "faux",
      provider: "faux",
      input: [:text],
      context_window: 10_000
    }

    Store.append_message(store, Message.user("discarded by reset"))
    Store.append_reset(store)
    Store.append_model_change(store, model)
    Store.append_thinking_level_change(store, "high")

    Store.append_settings_snapshot(store, %{
      model: model,
      thinking_level: "high",
      workflow: "review",
      system_prompt: "Be terse."
    })

    Store.append_message(store, Message.user("replaced by compaction"))

    summary = Message.user("summary")
    current = Message.user("current")

    Store.append_compaction(store, %Event.ContextCompacted{
      replacement: [summary, current],
      summary: summary,
      replaced_count: 1,
      tokens_before: 1_000,
      tokens_after: 200,
      policy: Catalyst.Context.Window
    })

    Store.append_message(store, Message.user("later"))

    assert {:ok, state} = Store.load_state(store.path)

    assert Enum.map(state.messages, &Content.text_of(&1.content)) == [
             "summary",
             "current",
             "later"
           ]

    assert state.model == model
    assert state.model_set?
    assert state.thinking_level == "high"
    assert state.thinking_level_set?
    assert state.parent_id == "parent"
    assert state.root_session_id == "root"
    assert state.agent_depth == 2

    entry_types =
      store.path
      |> File.stream!()
      |> Enum.map(fn line -> line |> Jason.decode!() |> Map.fetch!("type") end)
      |> MapSet.new()

    assert entry_types ==
             MapSet.new(
               ~w(session message reset model_change thinking_level_change compaction settings_snapshot)
             )
  end

  test "settings_snapshot entry folds to the authoritative values" do
    store = Store.new("/tmp/proj_settings_snapshot")
    on_exit(fn -> File.rm_rf!(store.path) end)

    m1 = %Catalyst.Model{id: "m-1", api: "faux", provider: "faux", input: [:text]}

    Store.append_settings_snapshot(store, %{
      model: m1,
      thinking_level: "high",
      workflow: "review",
      system_prompt: "Be terse."
    })

    settings = Store.load_settings(store.path)

    assert settings.model.id == "m-1"
    assert settings.thinking_level == "high"
    assert settings.workflow == "review"
    assert settings.system_prompt == "Be terse."
    assert settings.model_set?
    assert settings.thinking_level_set?
    assert settings.workflow_set?
    assert settings.system_prompt_set?

    Store.append_settings_snapshot(store, %{
      model: nil,
      thinking_level: nil,
      workflow: nil,
      system_prompt: nil
    })

    settings = Store.load_settings(store.path)

    assert settings.model == nil
    assert settings.thinking_level == nil
    assert settings.workflow == nil
    assert settings.system_prompt == nil
    assert settings.model_set?
    assert settings.thinking_level_set?
    assert settings.workflow_set?
    assert settings.system_prompt_set?
  end

  test "legacy settings_snapshot lines without the new keys never fabricate tombstones" do
    store = Store.new("/tmp/proj_settings_snapshot_legacy")
    on_exit(fn -> File.rm_rf!(store.path) end)

    # Written by a pre-workflow build: only model + thinking_level keys exist.
    legacy =
      Jason.encode!(%{
        "type" => "settings_snapshot",
        "model" => nil,
        "thinking_level" => "high"
      })

    File.write!(store.path, legacy <> "\n", [:append])

    settings = Store.load_settings(store.path)
    assert settings.thinking_level_set?
    refute settings.workflow_set?
    refute settings.system_prompt_set?
    assert settings.workflow == nil
    assert settings.system_prompt == nil

    # A later full snapshot then owns every field, including explicit clears.
    Store.append_settings_snapshot(store, %{
      model: nil,
      thinking_level: "high",
      workflow: "review",
      system_prompt: nil
    })

    settings = Store.load_settings(store.path)
    assert settings.workflow == "review"
    assert settings.workflow_set?
    assert settings.system_prompt == nil
    assert settings.system_prompt_set?
  end

  test "append_settings_snapshot rejects malformed settings" do
    store = Store.new("/tmp/proj_settings_snapshot_invalid")
    on_exit(fn -> File.rm_rf!(store.path) end)

    valid = %{model: nil, thinking_level: nil, workflow: nil, system_prompt: nil}

    assert {:error, {:build_failed, :invalid_settings_snapshot}} =
             Store.append_settings_snapshot(store, %{valid | workflow: :not_a_name})

    assert {:error, {:build_failed, :invalid_settings_snapshot}} =
             Store.append_settings_snapshot(store, %{valid | system_prompt: 42})

    assert {:error, {:build_failed, {:invalid_settings_snapshot, _}}} =
             Store.append_settings_snapshot(store, :not_a_map)
  end

  test "open returns tagged errors for inaccessible roots" do
    # Root that cannot be created (dir-as-file collision)
    collision = "/tmp/catalyst_test_collision"
    File.write!(collision, "not a dir")
    on_exit(fn -> File.rm!(collision) end)

    Application.put_env(:catalyst, :sessions_root, collision)
    on_exit(fn -> Application.delete_env(:catalyst, :sessions_root) end)

    assert {:error, {:mkdir_failed, :enotdir}} = Store.open("cwd")
  end

  test "load_state returns tagged errors for unreadable files" do
    store = Store.new("/tmp/proj_unreadable")
    on_exit(fn -> File.rm_rf!(store.path) end)

    File.chmod!(store.path, 0o000)
    assert {:error, {:read_failed, :eacces}} = Store.load_state(store.path)
  end

  test "reopening an existing session file preserves its transcript" do
    id = "resume_#{System.unique_integer([:positive])}"
    store = Store.new("/tmp/proj3", id: id)
    on_exit(fn -> File.rm_rf!(store.path) end)

    Store.append_message(store, Message.user("hello"))

    # Same id again (what a crash-restarted Session.Server does) must not truncate.
    reopened = Store.new("/tmp/proj3", id: id)
    assert reopened.path == store.path
    assert [%Message.User{}] = Store.load(reopened.path)
  end

  test "a reset marker clears everything before it on load" do
    store = Store.new("/tmp/proj_reset")
    on_exit(fn -> File.rm_rf!(store.path) end)

    Store.append_message(store, Message.user("old one"))
    Store.append_message(store, Message.user("old two"))
    Store.append_reset(store)
    Store.append_message(store, Message.user("fresh"))

    assert [%Message.User{} = m] = Store.load(store.path)
    assert Content.text_of(m.content) == "fresh"

    # A trailing reset leaves the session empty.
    Store.append_reset(store)
    assert Store.load(store.path) == []
  end

  test "a compaction entry replaces the logical transcript and later messages keep appending" do
    store = Store.new("/tmp/proj_compaction")
    on_exit(fn -> File.rm_rf!(store.path) end)

    old = [Message.user("old one"), Message.user("old two")]
    Enum.each(old, &Store.append_message(store, &1))

    summary = Message.user("[Compacted context summary]\nsummary")
    kept = Message.user("current")

    event = %Event.ContextCompacted{
      replacement: [summary, kept],
      summary: summary,
      replaced_count: 2,
      tokens_before: 1_000,
      tokens_after: 200,
      policy: Catalyst.Context.Window
    }

    assert :ok = Store.append_compaction(store, event)
    assert :ok = Store.append_message(store, Message.user("later"))

    assert [loaded_summary, loaded_kept, loaded_later] = Store.load(store.path)
    assert Content.text_of(loaded_summary.content) =~ "Compacted context summary"
    assert Content.text_of(loaded_kept.content) == "current"
    assert Content.text_of(loaded_later.content) == "later"
  end

  test "older readers degrade by ignoring compaction and replaying physical messages" do
    store = Store.new("/tmp/proj_older_compaction")
    on_exit(fn -> File.rm_rf!(store.path) end)

    old = [Message.user("old one"), Message.user("old two")]
    Enum.each(old, &Store.append_message(store, &1))

    summary = Message.user("[Compacted context summary]\nsummary")
    current = Message.user("current")

    Store.append_compaction(store, %Event.ContextCompacted{
      replacement: [summary, current],
      summary: summary,
      replaced_count: 2,
      tokens_before: 1_000,
      tokens_after: 200,
      policy: Catalyst.Context.Window
    })

    Store.append_message(store, Message.user("later"))

    assert Enum.map(Store.load(store.path), &Content.text_of(&1.content)) == [
             "[Compacted context summary]\nsummary",
             "current",
             "later"
           ]

    assert Enum.map(old_build_load(store.path), &Content.text_of(&1.content)) == [
             "old one",
             "old two",
             "later"
           ]
  end

  test "a malformed compaction line preserves the prior fold and later valid lines continue" do
    store = Store.new("/tmp/proj_malformed_compaction")
    on_exit(fn -> File.rm_rf!(store.path) end)

    Store.append_message(store, Message.user("before"))

    File.write!(
      store.path,
      ~s({"type":"compaction","replacement":[{"role":"martian"}]}\n),
      [:append]
    )

    orphan = %Message.ToolResult{
      tool_call_id: "orphan",
      tool_name: "read",
      content: Content.text("invalid")
    }

    File.write!(
      store.path,
      Jason.encode!(%{"type" => "compaction", "replacement" => [Store.encode(orphan)]}) <> "\n",
      [:append]
    )

    Store.append_message(store, Message.user("after"))

    assert [before, after_message] = Store.load(store.path)
    assert Content.text_of(before.content) == "before"
    assert Content.text_of(after_message.content) == "after"
  end

  test "load skips corrupt or unknown lines instead of crashing" do
    store = Store.new("/tmp/proj4")
    on_exit(fn -> File.rm_rf!(store.path) end)

    Store.append_message(store, Message.user("kept"))
    File.write!(store.path, "not json at all\n", [:append])
    File.write!(store.path, ~s({"type":"message","message":{"role":"martian"}}\n), [:append])

    File.write!(
      store.path,
      ~s({"type":"message","message":{"role":"assistant","stopReason":"new_unknown_reason"}}\n),
      [:append]
    )

    loaded = Store.load(store.path)
    assert [%Message.User{}, %Message.Assistant{stop_reason: :stop}] = loaded
  end

  # Regression: decode used whitelist + String.to_existing_atom/1, which
  # crashes in a lazily loaded VM when no module referencing the atom has been
  # loaded yet — load_state then reported {:read_failed, {:error, :badarg}}
  # and resume came back empty. Every persisted enum value must decode.
  test "every persisted stop reason and context-window source decodes" do
    store = Store.new("/tmp/proj_enum_decode")
    on_exit(fn -> File.rm_rf!(store.path) end)

    for reason <- ~w(stop length tool_use error aborted) do
      File.write!(
        store.path,
        ~s({"type":"message","message":{"role":"assistant","stopReason":"#{reason}"}}\n),
        [:append]
      )
    end

    reasons = store.path |> Store.load() |> Enum.map(& &1.stop_reason)
    assert reasons == [:stop, :length, :tool_use, :error, :aborted]

    for source <- ~w(session catalog persisted fallback) do
      snapshot =
        ~s({"type":"settings_snapshot","model":{"id":"m","contextWindowSource":"#{source}"},) <>
          ~s("thinking_level":null}\n)

      File.write!(store.path, snapshot, [:append])

      assert {:ok, %{model: %{context_window_source: decoded}}} = Store.load_state(store.path)
      assert decoded == String.to_atom(source)
    end
  end

  test "unexpected content shapes degrade to text instead of crashing the append" do
    store = Store.new("/tmp/proj_duck_typed")
    on_exit(fn -> File.rm_rf!(store.path) end)

    # Tool results are duck-typed: an extension/LLM-authored tool can hand the
    # loop content that is not a block list at all…
    bare = %Message.ToolResult{
      tool_call_id: "call_1",
      tool_name: "custom",
      content: {:unexpected, :tuple},
      timestamp: 1
    }

    # …or a list holding blocks the store has never heard of.
    unknown_block = %Message.ToolResult{
      tool_call_id: "call_2",
      tool_name: "custom",
      content: [%{weird: "block"}],
      timestamp: 2
    }

    assert :ok = Store.append_message(store, bare)
    assert :ok = Store.append_message(store, unknown_block)

    # Both lines stayed decodable, with the foreign shapes inspected into text.
    assert [%Message.ToolResult{} = a, %Message.ToolResult{} = b] = Store.load(store.path)
    assert Content.text_of(a.content) == inspect({:unexpected, :tuple})
    assert Content.text_of(b.content) == inspect(%{weird: "block"})
  end

  test "append failures are returned as tagged errors instead of raising" do
    store = Store.new("/tmp/proj_unwritable")
    on_exit(fn -> File.rm_rf!(store.path) end)

    # Replace the session file with a directory so appends fail at the disk.
    File.rm!(store.path)
    File.mkdir_p!(store.path)

    assert {:error, {:write_failed, _reason}} =
             Store.append_message(store, Message.user("lost, but explicitly"))

    assert {:error, {:write_failed, _reason}} = Store.append_reset(store)
  end

  test "encoding failures are returned without appending a partial line" do
    store = Store.new("/tmp/proj_unencodable")
    on_exit(fn -> File.rm_rf!(store.path) end)
    invalid = %Message.User{content: [%Content.Text{text: <<255>>}]}

    assert {:error, {:encode_failed, _reason}} = Store.append_message(store, invalid)
    assert [_header] = File.read!(store.path) |> String.split("\n", trim: true)
  end

  defp old_build_load(path) do
    path
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"type" => "message", "message" => message}} ->
          case Store.decode(message) do
            {:ok, decoded} -> [decoded]
            {:error, _reason} -> []
          end

        _unknown_or_invalid ->
          []
      end
    end)
  end
end
