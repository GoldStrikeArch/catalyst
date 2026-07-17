defmodule Catalyst.Extensions.ProcessesTest do
  # async: false — shared process registry + Extensions server.
  use ExUnit.Case, async: false

  alias Catalyst.{ExtensionAPI, Extensions}
  alias Catalyst.Extensions.Processes

  test "start_child runs a process under the owner's supervisor; purge kills it" do
    owner = "proc_test_#{System.unique_integer([:positive])}"
    api = ExtensionAPI.new(owner)

    {:ok, pid} =
      ExtensionAPI.start_child(api, %{
        id: :probe,
        start: {Agent, :start_link, [fn -> :alive end]},
        restart: :temporary
      })

    assert Process.alive?(pid)
    assert [^pid] = Processes.list(owner)

    ExtensionAPI.purge_owner(owner)

    refute Process.alive?(pid)
    assert Processes.list(owner) == []
  end

  test "a crashed-and-restarted child is still torn down on purge" do
    owner = "proc_restart_#{System.unique_integer([:positive])}"
    api = ExtensionAPI.new(owner)

    {:ok, pid} =
      ExtensionAPI.start_child(api, %{
        id: :phoenix_child,
        start: {Agent, :start_link, [fn -> :alive end]},
        restart: :permanent
      })

    Process.exit(pid, :kill)
    # The per-owner supervisor restarts it with a NEW pid.
    new_pid =
      Enum.find_value(1..50, fn _ ->
        case Processes.list(owner) do
          [p] when p != pid -> p
          _ -> Process.sleep(10) && nil
        end
      end)

    assert new_pid, "expected the supervisor to restart the killed child"

    ExtensionAPI.purge_owner(owner)
    refute Process.alive?(new_pid)
  end

  test "start_child immediately after stop_owner succeeds (stale Registry window)" do
    owner = "proc_race_#{System.unique_integer([:positive])}"
    on_exit(fn -> ExtensionAPI.purge_owner(owner) end)

    spec = fn id ->
      %{id: id, start: {Agent, :start_link, [fn -> :alive end]}, restart: :temporary}
    end

    # The reload path purges the owner sup and immediately starts new children;
    # Registry cleanup of the dead sup's name is async, so the lookup can still
    # return a corpse. Loop to give the race a real chance to fire — every
    # iteration must come up with a live child either way.
    for i <- 1..10 do
      {:ok, _} = Processes.start_child(owner, spec.({:probe_a, i}))
      assert :ok = Processes.stop_owner(owner)

      assert {:ok, pid} = Processes.start_child(owner, spec.({:probe_b, i}))
      assert Process.alive?(pid)
      assert [^pid] = Processes.list(owner)
    end
  end

  defmodule Stubborn do
    @moduledoc false
    # Simulates a wedged extension process: traps exits and ignores ALL
    # messages, so only an untrappable direct kill can take it down. A raw
    # receive loop, deliberately not a GenServer — gen_server intercepts a
    # parent supervisor's EXIT and complies with the shutdown.
    def start_link(test_pid) do
      pid =
        spawn_link(fn ->
          Process.flag(:trap_exit, true)
          send(test_pid, {:stubborn, self()})
          loop()
        end)

      {:ok, pid}
    end

    defp loop do
      receive do
        _ -> loop()
      end
    end
  end

  test "stop_owner stays bounded and kills a tree that ignores graceful shutdown" do
    owner = "stubborn_#{System.unique_integer([:positive])}"

    prev = Application.get_env(:catalyst, :extension_stop_timeout)
    Application.put_env(:catalyst, :extension_stop_timeout, 50)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:catalyst, :extension_stop_timeout)
        ms -> Application.put_env(:catalyst, :extension_stop_timeout, ms)
      end
    end)

    {:ok, child} =
      Processes.start_child(owner, %{
        id: :stubborn,
        start: {Stubborn, :start_link, [self()]},
        shutdown: :infinity
      })

    assert_receive {:stubborn, ^child}
    ref = Process.monitor(child)

    # A graceful terminate would wait on shutdown: :infinity forever, wedging
    # the Catalyst.Extensions GenServer whose purge path calls this — it must
    # return bounded and the child must actually die (the snapshot-then-kill
    # path uses an untrappable direct exit).
    assert :ok = Processes.stop_owner(owner)
    assert_receive {:DOWN, ^ref, :process, ^child, :killed}, 2_000

    # The owner slot is reusable after the forced teardown.
    assert {:ok, pid2} =
             Processes.start_child(owner, %{
               id: :probe,
               start: {Agent, :start_link, [fn -> :alive end]},
               restart: :temporary
             })

    assert Process.alive?(pid2)
    Processes.stop_owner(owner)
  end

  @proc_ext_source ~S'''
  defmodule Catalyst.Ext.ProcOwner do
    use Catalyst.Extension
    @impl true
    def setup(api) do
      {:ok, _pid} =
        Catalyst.ExtensionAPI.start_child(api, %{
          id: :ext_agent,
          start: {Agent, :start_link, [fn -> :ext end, [name: Catalyst.Ext.ProcOwnerAgent]]},
          restart: :temporary
        })

      :ok
    end
  end
  '''

  test "an extension's setup/1 starts a supervised process; uninstall tears it down" do
    File.mkdir_p!(Extensions.dir())
    path = Path.join(Extensions.dir(), "procowner.ex")
    File.write!(path, @proc_ext_source)
    on_exit(fn -> File.rm_rf!(path) end)

    assert {:ok, _summary} = Extensions.load_file(path)

    pid = Process.whereis(Catalyst.Ext.ProcOwnerAgent)
    assert pid && Process.alive?(pid)

    Extensions.uninstall("procowner")
    refute Process.whereis(Catalyst.Ext.ProcOwnerAgent)
  end
end
