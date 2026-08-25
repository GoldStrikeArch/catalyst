defmodule Catalyst.Prompt.RegistryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Prompt
  alias Catalyst.Prompt.{Registry, Request, Resolution}
  alias Catalyst.Runtime.Registry, as: RuntimeRegistry

  defmodule FirstPolicy do
    @behaviour Prompt

    @impl true
    def resolve(%Request{}), do: {:ok, Resolution.new("first", [:builtin])}
  end

  defmodule InvalidProvenancePolicy do
    @behaviour Prompt

    @impl true
    def resolve(%Request{}), do: {:ok, Resolution.new("invalid", [:builtin, {:garbage, 1}])}
  end

  defmodule SecondPolicy do
    @behaviour Prompt

    @impl true
    def resolve(%Request{}), do: {:ok, Resolution.new("second", [:builtin])}
  end

  setup do
    previous_prompts = Application.fetch_env(:catalyst, :prompts)
    previous_policy = Application.fetch_env(:catalyst, :prompt_policy)

    Application.delete_env(:catalyst, :prompts)
    Application.delete_env(:catalyst, :prompt_policy)

    clear_runtime()

    on_exit(fn ->
      clear_runtime()
      restore_env(:prompts, previous_prompts)
      restore_env(:prompt_policy, previous_policy)
    end)

    :ok
  end

  test "same-owner replacement is allowed and cross-owner collisions preserve the first entry" do
    key = {:text, :compaction, "gpt-test"}

    assert :ok =
             Registry.register_prompt("gpt-test", "first",
               purpose: :compaction,
               owner: "owner-a"
             )

    assert :ok =
             Registry.register_prompt("gpt-test", "updated",
               purpose: :compaction,
               owner: "owner-a"
             )

    assert {:error, {:owner_collision, :prompt, ^key, "owner-a", "owner-b"}} =
             Registry.register_prompt("gpt-test", "rejected",
               purpose: :compaction,
               owner: "owner-b"
             )

    assert {:ok, "updated", "owner-a"} = Registry.runtime_text(:compaction, "gpt-test")
  end

  test "owner purge removes only that owner's entries" do
    assert :ok = Registry.register_prompt("b", "B", owner: "owner-b")
    assert :ok = Registry.register_prompt("a", "A", owner: "owner-a")
    assert :ok = Registry.register_policy(FirstPolicy, owner: "owner-a")

    assert :ok = Catalyst.Runtime.Registry.purge_owner("owner-a")

    assert :error = Registry.runtime_text(:system, "a")
    assert {:ok, "B", "owner-b"} = Registry.runtime_text(:system, "b")
    assert {:ok, Catalyst.SystemPrompt, :builtin} = Registry.policy()
  end

  test "policy selection is runtime then live application then built-in" do
    assert {:ok, Catalyst.SystemPrompt, :builtin} = Registry.policy()

    Application.put_env(:catalyst, :prompt_policy, FirstPolicy)
    assert {:ok, FirstPolicy, {:application, :prompt_policy}} = Registry.policy()

    assert :ok = Registry.register_policy(SecondPolicy, owner: "policy-owner")

    assert {:ok, SecondPolicy, {:extension, "policy-owner", {:policy, :default}}} =
             Registry.policy()

    Application.delete_env(:catalyst, :prompt_policy)
    assert :ok = Catalyst.Runtime.Registry.purge_owner("policy-owner")
    assert {:ok, Catalyst.SystemPrompt, :builtin} = Registry.policy()
  end

  test "malformed registrations are rejected before ETS writes" do
    assert {:error, {:invalid_registration, {:text, :system, :default}, " \n "}} =
             Registry.register_prompt(:default, " \n ")

    assert {:error, {:invalid_registration, {:text, :system, ""}, "text"}} =
             Registry.register_prompt("", "text")

    assert {:error, {:invalid_registration, {:text, :unknown, :default}, "text"}} =
             Registry.register_prompt(:default, "text", purpose: :unknown)

    assert {:error, {:invalid_registration, {:policy, :default}, String}} =
             Registry.register_policy(String)

    assert RuntimeRegistry.list(:prompt) == []
  end

  test "malformed live policy configuration is tagged" do
    Application.put_env(:catalyst, :prompt_policy, String)
    assert {:error, {:invalid_prompt_policy, String}} = Registry.policy()
  end

  test "reads still use live application fallback while the ETS table is absent" do
    Application.put_env(:catalyst, :prompt_policy, FirstPolicy)

    with_registry_absent(fn ->
      assert {:ok, FirstPolicy, {:application, :prompt_policy}} = Registry.policy()
      assert RuntimeRegistry.list(:prompt) == []
    end)
  end

  test "bounded prompt resolution rejects malformed provenance entries" do
    assert :ok = Registry.register_policy(InvalidProvenancePolicy)

    assert {:error, {:invalid_prompt_provenance, {:garbage, 1}}} =
             Prompt.resolve_bounded(%Request{})
  end

  test "Prompt.resolve dispatches through the selected policy" do
    assert :ok = Registry.register_policy(FirstPolicy)
    assert {:ok, %Resolution{text: "first"}} = Prompt.resolve(%Request{})
  end

  defp clear_runtime do
    RuntimeRegistry.list(:prompt)
    |> Enum.each(&RuntimeRegistry.delete(:prompt, &1.key))
  end

  defp with_registry_absent(fun) do
    case stop_supervised(RuntimeRegistry) do
      :ok ->
        assert Process.whereis(RuntimeRegistry) == nil
        fun.()

      {:error, _not_test_supervised} ->
        with_application_registry_suspended(fun)
    end
  end

  defp with_application_registry_suspended(fun) do
    old_registry = Process.whereis(RuntimeRegistry)
    supervisor = parent_supervisor(old_registry)
    ref = Process.monitor(old_registry)
    :ok = :sys.suspend(supervisor)

    try do
      Process.exit(old_registry, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_registry, :killed}
      assert Process.whereis(RuntimeRegistry) == nil
      fun.()
    after
      :ok = :sys.resume(supervisor)
      _replacement = wait_for_registry(old_registry)
      assert :ok = Catalyst.Extensions.await_ready(5_000)
    end
  end

  defp parent_supervisor(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)

    dictionary
    |> Keyword.fetch!(:"$ancestors")
    |> List.first()
  end

  defp wait_for_registry(old_registry, attempts \\ 100)

  defp wait_for_registry(_old_registry, 0), do: flunk("prompt registry did not restart")

  defp wait_for_registry(old_registry, attempts) do
    case Process.whereis(RuntimeRegistry) do
      pid when is_pid(pid) and pid != old_registry ->
        _ = :sys.get_state(pid)
        pid

      _not_restarted ->
        receive do
        after
          10 -> wait_for_registry(old_registry, attempts - 1)
        end
    end
  end
end
