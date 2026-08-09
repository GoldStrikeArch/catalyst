defmodule Catalyst.Session.RunConfigTest do
  use ExUnit.Case, async: false

  alias Catalyst.Session.RunConfig
  alias Catalyst.LLM.Registry

  defp state(overrides) do
    Map.merge(
      %{
        id: "run-config-test",
        provider: Catalyst.LLM.Faux,
        model: nil,
        cwd: ".",
        tools: :extensions,
        opts: []
      },
      Map.new(overrides)
    )
  end

  defp build_base!(state) do
    {:ok, config} =
      RunConfig.build_base(state, self(), make_ref(), Catalyst.LLM.Faux)

    config
  end

  test "a session without a resolvable provider is a tagged error, not a raise" do
    assert {:error, :no_provider} = RunConfig.resolve_provider(state(provider: nil))

    assert {:error, {:unknown_api, "nope"}} =
             RunConfig.resolve_provider(state(provider: "nope"))
  end

  test "the canonical session id overrides nested caller options" do
    config = build_base!(state(opts: [session_id: "../../outside"]))
    assert config.opts[:session_id] == "run-config-test"
  end

  test "child inheritance keeps tuning data and removes parent controls and process terms" do
    ref = make_ref()

    assert RunConfig.inheritable_opts(
             reasoning_effort: "high",
             context_threshold: 42_000,
             # A bare boolean passes `inheritable_term?/1`, so the machine-access
             # grant is only kept out of children by the denylist.
             computer_use: true,
             session_id: "parent",
             workflow: "parent-loop",
             callback: fn -> :unsafe end,
             nested_pid: %{owner: self()},
             nested_ref: [ref]
           ) == [reasoning_effort: "high", context_threshold: 42_000]
  end

  test "an improper list option is dropped instead of crashing inheritance" do
    assert RunConfig.inheritable_opts(custom: [1 | 2], kept: [1, 2]) == [kept: [1, 2]]
  end

  test "prewarm receives the canonical session id" do
    Application.put_env(:catalyst, :blocking_prewarm_test, self())
    on_exit(fn -> Application.delete_env(:catalyst, :blocking_prewarm_test) end)

    assert {:ok, pid} =
             RunConfig.start_prewarm(
               state(
                 provider: Catalyst.Test.BlockingPrewarmProvider,
                 opts: [session_id: "../../outside"],
                 messages: [],
                 system_prompt: "test",
                 tools: []
               )
             )

    monitor = Process.monitor(pid)
    assert_receive {:blocking_prewarm_started, ^pid}
    assert_receive {:blocking_prewarm_opts, opts}
    assert opts[:session_id] == "run-config-test"

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  test "provider cleanup callbacks run concurrently under one deadline" do
    owner = "run_config_cleanup_#{System.unique_integer([:positive])}"
    test_pid = self()

    Application.put_env(:catalyst, :blocking_cleanup_test_pid, test_pid)
    Application.put_env(:catalyst, :summary_cleanup_test_pid, test_pid)

    on_exit(fn ->
      Registry.unregister_owner(owner)
      Application.delete_env(:catalyst, :blocking_cleanup_test_pid)
      Application.delete_env(:catalyst, :summary_cleanup_test_pid)
    end)

    assert :ok =
             Registry.register_provider(
               "run-config-fast-cleanup",
               Catalyst.Test.SummaryCleanupProvider,
               owner: owner
             )

    session_id = "parallel-provider-cleanup"
    parent = self()

    _cleanup =
      start_supervised!(
        {Task,
         fn ->
           result =
             RunConfig.cleanup_session(
               state(id: session_id, provider: Catalyst.Test.BlockingCleanupProvider)
             )

           send(parent, {:cleanup_complete, result})
         end}
      )

    assert_receive {:blocking_cleanup_started, blocking_pid, ^session_id}, 500

    # The fast registered provider starts while the selected provider remains
    # blocked. A sequential cleanup would not emit this until the deadline.
    assert_receive {:summary_cleanup, Catalyst.Test.SummaryCleanupProvider, ^session_id}, 500

    send(blocking_pid, {:release_cleanup, session_id})
    assert_receive {:cleanup_complete, :ok}, 500
  end
end
