defmodule Catalyst.ExtensionsPurgeTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import Catalyst.ExtensionsFixtures
  import ExUnit.CaptureLog

  alias Catalyst.Extensions
  alias Catalyst.ExtensionsFixtures.{CacheProbeTool, DegradedPurgeTool}

  setup do
    setup_extensions_dir()
  end

  test "disable purges + renames the file; load_all keeps it off; enable restores it" do
    on_exit(fn -> Extensions.uninstall("toggle") end)
    path = write_ext("toggle", toggle_source())
    assert {:ok, _summary} = Extensions.load_file(path)
    assert {:ok, _mod} = Extensions.fetch("toggle_tool")

    assert {:ok, disabled} = Extensions.disable("toggle")
    assert disabled == path <> ".disabled"
    assert File.exists?(disabled)
    refute File.exists?(path)
    assert Extensions.fetch("toggle_tool") == :error
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "toggle"))
    assert [%{owner: "toggle"}] = Extensions.list_disabled()

    # A full reload (≈ next boot) must not resurrect a disabled extension.
    {:ok, _} = Extensions.load_all()
    assert Extensions.fetch("toggle_tool") == :error

    assert {:ok, summary} = Extensions.enable("toggle")
    assert summary.tools == ["toggle_tool"]
    assert {:ok, _mod} = Extensions.fetch("toggle_tool")
    assert Extensions.list_disabled() == []
  end

  test "disable/enable for an owner with no source file return :no_file" do
    assert {:error, :no_file} = Extensions.disable("no_such_owner")
    assert {:error, :no_file} = Extensions.enable("no_such_owner")
  end

  test "an externally loaded extension is reload-only and cannot be stranded by disable" do
    external_dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst_external_disable_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(external_dir)
    path = Path.join(external_dir, "external_disable.ex")

    File.write!(
      path,
      owned_tool_source(
        "Catalyst.Ext.ExternalDisableTool",
        "external_disable_tool",
        "external"
      )
    )

    on_exit(fn ->
      Extensions.uninstall("external_disable")
      File.rm_rf!(external_dir)
    end)

    assert {:ok, _summary} = Extensions.load_file(path)
    info = Enum.find(Extensions.list_loaded(), &(&1.owner == "external_disable"))
    refute info.managed?

    assert {:error, :external_source} = Extensions.disable("external_disable")
    assert File.regular?(path)
    refute File.exists?(path <> ".disabled")
    assert {:ok, Catalyst.Ext.ExternalDisableTool} = Extensions.fetch("external_disable_tool")
  end

  test "a failing purger leaves the owner tracked as degraded, never forgotten" do
    purgers_key = {Catalyst.ExtensionAPI, :purgers}
    previous_purgers = :persistent_term.get(purgers_key, %{})
    owner = "degraded_purge_owner"

    on_exit(fn ->
      :persistent_term.put(purgers_key, previous_purgers)
      Extensions.uninstall(owner)
    end)

    assert {:ok, _module} = Extensions.register_tool(DegradedPurgeTool, owner: owner)

    Catalyst.ExtensionAPI.register_purger(fn
      ^owner -> raise "purger boom"
      _other_owner -> :ok
    end)

    log = capture_log(fn -> assert :ok = Extensions.uninstall(owner) end)
    assert log =~ "purger boom"
    assert log =~ "degraded"

    # The tool itself is gone, but the owner stays tracked with the failure.
    assert Extensions.fetch("degraded_purge_tool") == :error
    assert [info] = Enum.filter(Extensions.list_loaded(), &(&1.owner == owner))
    assert info.status == :degraded
    assert [{_purger_key, {:error, %RuntimeError{message: "purger boom"}}}] = info.purge_failures

    # Once the purger is fixed, a retried purge clears the degraded entry.
    :persistent_term.put(purgers_key, previous_purgers)
    assert :ok = Extensions.uninstall(owner)
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == owner))
  end

  test "purging an owner invalidates its tool registry metadata cache" do
    owner = "cache_invalidate_owner"
    cache_key = {{Catalyst.Tools.Registry, :definition}, CacheProbeTool}
    on_exit(fn -> Extensions.uninstall(owner) end)

    assert {:ok, _module} = Extensions.register_tool(CacheProbeTool, owner: owner)
    assert :persistent_term.get(cache_key, :missing) != :missing

    assert :ok = Extensions.uninstall(owner)
    assert :persistent_term.get(cache_key, :missing) == :missing
  end

  test "concurrent reseeder registration cannot lose entries" do
    reseeders_key = {Extensions, :reseeders}
    previous = :persistent_term.get(reseeders_key, %{})
    on_exit(fn -> :persistent_term.put(reseeders_key, previous) end)

    funs = for i <- 1..32, do: :"concurrent_reseed_#{i}"

    funs
    |> Task.async_stream(&Extensions.register_reseeder(__MODULE__, &1), timeout: :infinity)
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    registered = :persistent_term.get(reseeders_key, %{})
    assert Enum.all?(funs, &Map.has_key?(registered, {__MODULE__, &1}))
  end

  test "uninstall uses the configured lifecycle deadline beyond a graceful phase" do
    purgers_key = {Catalyst.ExtensionAPI, :purgers}
    probe_key = {__MODULE__, :lifecycle_purger_probe}
    previous_purgers = :persistent_term.get(purgers_key, %{})
    previous_timeout = Application.fetch_env(:catalyst, :extension_lifecycle_call_timeout)
    test = self()

    Application.put_env(:catalyst, :extension_lifecycle_call_timeout, 250)

    Catalyst.ExtensionAPI.register_purger(fn owner ->
      case :persistent_term.get(probe_key, nil) do
        %{owner: ^owner, gate: gate} ->
          send(test, {:lifecycle_purger_entered, owner, self(), gate})

          receive do
            {:release_lifecycle_purger, ^gate} -> :ok
          after
            1_000 -> :ok
          end

        _other_owner ->
          :ok
      end
    end)

    on_exit(fn ->
      :persistent_term.erase(probe_key)
      :persistent_term.put(purgers_key, previous_purgers)
      restore_timeout(previous_timeout)
      _ = :sys.get_state(Extensions)
    end)

    owner = "lifecycle_grace_probe"
    gate = make_ref()
    :persistent_term.put(probe_key, %{owner: owner, gate: gate})

    uninstall =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        Extensions.uninstall(owner)
      end)

    assert_receive {:lifecycle_purger_entered, ^owner, server, ^gate}
    Process.send_after(self(), {:graceful_phase_elapsed, gate}, 50)
    assert_receive {:graceful_phase_elapsed, ^gate}
    assert Task.yield(uninstall, 0) == nil

    send(server, {:release_lifecycle_purger, gate})
    assert Task.await(uninstall, 500) == :ok

    timeout_owner = "lifecycle_timeout_probe"
    timeout_gate = make_ref()
    :persistent_term.put(probe_key, %{owner: timeout_owner, gate: timeout_gate})

    caller =
      spawn(fn ->
        outcome =
          try do
            {:return, Extensions.uninstall(timeout_owner)}
          catch
            :exit, reason -> {:exit, reason}
          end

        send(test, {:lifecycle_uninstall_outcome, self(), outcome})
      end)

    assert_receive {:lifecycle_purger_entered, ^timeout_owner, ^server, ^timeout_gate}
    Process.send_after(server, {:release_lifecycle_purger, timeout_gate}, 500)

    assert_receive {:lifecycle_uninstall_outcome, ^caller, {:exit, reason}}, 400
    assert inspect(reason) =~ "timeout"

    # Synchronize after the delayed release so the global server and purger
    # registry are quiescent before cleanup restores the shared test state.
    _ = :sys.get_state(Extensions)
  end

  defp restore_timeout(:error),
    do: Application.delete_env(:catalyst, :extension_lifecycle_call_timeout)

  defp restore_timeout({:ok, timeout}),
    do: Application.put_env(:catalyst, :extension_lifecycle_call_timeout, timeout)
end
