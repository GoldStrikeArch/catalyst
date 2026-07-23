defmodule Catalyst.Session.ConcurrentSessionsTest do
  # async: false — starts real sessions against the shared Manager/PubSub.
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Model}
  alias Catalyst.Session.{Manager, Server, Store}

  # §9 gap: two REAL sessions driven through REAL turns at the same time,
  # asserting complete isolation — events stay on their own topic, transcripts
  # and JSONL stores never cross.
  test "two real sessions run concurrent turns with isolated events and stores" do
    model = %Model{id: "faux", api: "faux", provider: "faux"}
    parent = self()

    [a, b] =
      for label <- ["alpha", "beta"] do
        cwd =
          Path.join(
            System.tmp_dir!(),
            "catalyst_conc_#{label}_#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(cwd)
        on_exit(fn -> File.rm_rf!(cwd) end)

        script = [
          {:tool, "bash", %{"command" => "sleep 0.3; echo from-#{label}"}},
          {:text, "#{label} done"}
        ]

        {:ok, %{id: id, pid: pid}} =
          Manager.start_session(
            cwd: cwd,
            provider: Catalyst.LLM.Faux,
            model: model,
            opts: [script: script]
          )

        on_exit(fn -> Manager.stop(id) end)

        # Each collector subscribes to ONE session topic and fails on any
        # event tagged with a foreign session id (cross-talk detector).
        collector =
          Task.async(fn ->
            :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
            send(parent, {:subscribed, id})
            collect_events(id, [])
          end)

        assert_receive {:subscribed, ^id}, 1_000
        %{label: label, id: id, pid: pid, collector: collector}
      end

    # Both prompts are issued before either turn can finish (each script's
    # tool sleeps), so the two loops genuinely overlap.
    assert :ok = Server.prompt(a.pid, "prompt #{a.label}")
    assert :ok = Server.prompt(b.pid, "prompt #{b.label}")

    events_a = Task.await(a.collector, 15_000)
    events_b = Task.await(b.collector, 15_000)

    # Both completed, and neither collector saw the other's events.
    assert is_list(events_a), "session A collector failed: #{inspect(events_a)}"
    assert is_list(events_b), "session B collector failed: #{inspect(events_b)}"
    assert %Event.AgentEnd{} = List.last(events_a)
    assert %Event.AgentEnd{} = List.last(events_b)

    snap_a = Server.state(a.pid)
    snap_b = Server.state(b.pid)

    # Transcripts: each holds exactly its own turn (user, tool round, reply).
    assert transcript_text(snap_a) =~ "alpha done"
    assert transcript_text(snap_a) =~ "from-alpha"
    refute transcript_text(snap_a) =~ "beta"
    assert transcript_text(snap_b) =~ "beta done"
    assert transcript_text(snap_b) =~ "from-beta"
    refute transcript_text(snap_b) =~ "alpha"

    # Stores: distinct files, each replaying only its own transcript.
    refute snap_a.store_path == snap_b.store_path
    assert length(Store.load(snap_a.store_path)) == length(snap_a.messages)
    assert length(Store.load(snap_b.store_path)) == length(snap_b.messages)
  end

  defp collect_events(id, acc) do
    receive do
      {:agent_event, ^id, %Event.AgentEnd{} = event} ->
        Enum.reverse([event | acc])

      {:agent_event, ^id, event} ->
        collect_events(id, [event | acc])

      {:agent_event, other_id, event} ->
        {:cross_talk, other_id, event}
    after
      10_000 -> :timeout
    end
  end

  defp transcript_text(snapshot) do
    snapshot.messages
    |> Enum.map(&message_text/1)
    |> Enum.join("\n")
  end

  defp message_text(%{content: content}), do: Content.text_of(content)
  defp message_text(other), do: inspect(other)
end
