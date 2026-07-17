defmodule Catalyst.LLM.OpenAICodex.ConnCacheTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.OpenAICodex.{ConnCache, WebSocket}
  alias Catalyst.Model
  alias Catalyst.Session.{Manager, Server}

  test "maximum size evicts and closes the oldest idle socket deterministically" do
    test = self()
    close = fn %WebSocket{conn: label} -> send(test, {:closed, label}) end

    cache =
      start_cache(
        max_entries: 2,
        idle_ttl_ms: 10_000,
        clock: fn -> 0 end,
        close: close
      )

    :ok = stash(cache, "session-a", :a)
    :ok = stash(cache, "session-b", :b)
    :ok = stash(cache, "session-c", :c)

    assert_receive {:closed, :a}
    refute ConnCache.has?("session-a", "wss://example.test", cache)
    assert ConnCache.has?("session-b", "wss://example.test", cache)
    assert ConnCache.has?("session-c", "wss://example.test", cache)

    :ok = ConnCache.drop("session-b", cache)
    assert_receive {:closed, :b}
    refute ConnCache.has?("session-b", "wss://example.test", cache)
  end

  test "idle TTL schedules eviction and closes the socket" do
    test = self()
    close = fn %WebSocket{conn: label} -> send(test, {:closed, label}) end
    cache = start_cache(max_entries: 4, idle_ttl_ms: 25, close: close)

    :ok = stash(cache, "idle-session", :idle)

    assert_receive {:closed, :idle}, 1_000
    refute ConnCache.has?("idle-session", "wss://example.test", cache)
  end

  test "lazy sweep uses the injected monotonic clock when a timer is delayed" do
    test = self()
    clock = start_supervised!({Agent, fn -> 0 end})
    close = fn %WebSocket{conn: label} -> send(test, {:closed, label}) end

    cache =
      start_cache(
        max_entries: 4,
        idle_ttl_ms: 100,
        clock: fn -> Agent.get(clock, & &1) end,
        close: close
      )

    :ok = stash(cache, "clock-session", :clock)
    Agent.update(clock, fn _now -> 99 end)
    assert ConnCache.has?("clock-session", "wss://example.test", cache)

    Agent.update(clock, fn _now -> 100 end)
    refute ConnCache.has?("clock-session", "wss://example.test", cache)
    assert_receive {:closed, :clock}
  end

  test "a caller death during a reserved handoff closes the uncommitted socket" do
    test = self()
    close = fn %WebSocket{conn: label} -> send(test, {:closed, label}) end
    cache = start_cache(max_entries: 4, idle_ttl_ms: 10_000, close: close)

    owner =
      start_supervised!(
        {Task,
         fn ->
           result = GenServer.call(cache, {:prepare_stash, socket(:pending)})
           send(test, {:handoff_prepared, self(), result})

           receive do
             :never -> :ok
           end
         end}
      )

    assert_receive {:handoff_prepared, ^owner, {:ok, _ref}}
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert_receive {:closed, :pending}
    state = :sys.get_state(cache)
    assert state.pending == %{}
  end

  test "terminating a session drops its cached connection" do
    id = "conn-cache-#{System.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(tmp)

    on_exit(fn ->
      Manager.stop(id)
      ConnCache.drop(id)
      File.rm_rf!(tmp)
    end)

    {:ok, %{pid: pid}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.Test.ConnCacheProvider,
        model: %Model{id: "cache-cleanup", api: "test-cache-cleanup"}
      )

    _snapshot = Server.state(pid)

    :ok = ConnCache.stash_owned(id, "wss://example.test", socket(:session), nil)
    assert ConnCache.has?(id, "wss://example.test")

    monitor = Process.monitor(pid)
    assert :ok = Manager.stop(id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}

    refute ConnCache.has?(id, "wss://example.test")
  end

  test "terminating a session cancels an in-flight prewarm before cache drop" do
    id = "prewarm-stop-#{System.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(tmp)
    Application.put_env(:catalyst, :blocking_prewarm_test, self())

    on_exit(fn ->
      Application.delete_env(:catalyst, :blocking_prewarm_test)
      Manager.stop(id)
      ConnCache.drop(id)
      File.rm_rf!(tmp)
    end)

    {:ok, %{pid: pid}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.Test.BlockingPrewarmProvider,
        model: %Model{id: "prewarm-test", api: "blocking-prewarm"},
        tools: []
      )

    _snapshot = Server.state(pid)
    assert_receive {:blocking_prewarm_started, prewarm_pid}, 1_000
    prewarm_ref = Process.monitor(prewarm_pid)
    session_ref = Process.monitor(pid)

    assert :ok = Manager.stop(id)
    assert_receive {:DOWN, ^session_ref, :process, ^pid, :shutdown}

    # If the task were still untracked, this release would let it stash a
    # connection after terminate's drop and repopulate the dead session.
    send(prewarm_pid, :finish_prewarm)
    assert_receive {:DOWN, ^prewarm_ref, :process, ^prewarm_pid, :killed}
    _cache_state = :sys.get_state(ConnCache)

    refute_received :blocking_prewarm_stashed
    refute ConnCache.has?(id, "wss://example.test")
  end

  test "starting a run cancels an in-flight prewarm before checkout" do
    id = "prewarm-prompt-#{System.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(tmp)
    Application.put_env(:catalyst, :blocking_prewarm_test, self())

    on_exit(fn ->
      Application.delete_env(:catalyst, :blocking_prewarm_test)
      Manager.stop(id)
      ConnCache.drop(id)
      File.rm_rf!(tmp)
    end)

    {:ok, %{pid: pid}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.Test.BlockingPrewarmProvider,
        model: %Model{id: "prewarm-test", api: "blocking-prewarm"},
        tools: []
      )

    _snapshot = Server.state(pid)
    assert_receive {:blocking_prewarm_started, prewarm_pid}, 1_000
    assert_receive {:blocking_prewarm_opts, opts}, 1_000
    assert opts[:session_id] == id
    prewarm_ref = Process.monitor(prewarm_pid)

    assert :ok = Server.prompt(pid, "start now")
    assert_receive {:DOWN, ^prewarm_ref, :process, ^prewarm_pid, :killed}

    refute_received :blocking_prewarm_stashed
    refute ConnCache.has?(id, "wss://example.test")
  end

  defp start_cache(opts) do
    start_supervised!({ConnCache, Keyword.put(opts, :name, nil)})
  end

  defp stash(cache, session_id, label) do
    ConnCache.stash_owned(
      session_id,
      "wss://example.test",
      socket(label),
      nil,
      server: cache
    )
  end

  defp socket(label) do
    %WebSocket{conn: label, websocket: %Mint.WebSocket{}, ref: make_ref()}
  end
end
