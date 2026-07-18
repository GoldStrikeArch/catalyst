defmodule Catalyst.Prompt.RegistryTest do
  use ExUnit.Case, async: false

  alias Catalyst.Prompt
  alias Catalyst.Prompt.{Registry, Request, Resolution}

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

    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> clear_runtime()
    end

    on_exit(fn ->
      clear_runtime()
      restore_env(:prompts, previous_prompts)
      restore_env(:prompt_policy, previous_policy)
    end)

    :ok
  end

  test "runtime text overlays live application values and removal reveals the current value" do
    Application.put_env(:catalyst, :prompts, %{system: %{default: "application v1"}})

    assert {:ok, "application v1", {:application, {:prompts, :system, :default}}} =
             Registry.lookup_text(:system, :default)

    assert :ok = Registry.register_prompt(:default, "runtime", owner: "prompt-owner")

    assert {:ok, "runtime", {:extension, "prompt-owner", {:text, :system, :default}}} =
             Registry.lookup_text(:system, :default)

    Application.put_env(:catalyst, :prompts, %{system: %{default: "application v2"}})
    assert :ok = Registry.unregister_owner("prompt-owner")

    assert {:ok, "application v2", {:application, {:prompts, :system, :default}}} =
             Registry.lookup_text(:system, :default)

    Application.delete_env(:catalyst, :prompts)
    assert :error = Registry.lookup_text(:system, :default)
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

    assert {:error, {:prompt_owner_collision, ^key, "owner-a", "owner-b"}} =
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

    assert :ok = Registry.unregister_owner("owner-a")

    assert :error = Registry.runtime_text(:system, "a")
    assert {:ok, "B", "owner-b"} = Registry.runtime_text(:system, "b")
    assert {:ok, Catalyst.SystemPrompt, :builtin} = Registry.policy()
  end

  test "runtime_entries returns a stable sorted owner-aware view" do
    assert :ok = Registry.register_prompt("z", "Z", owner: "owner-z")
    assert :ok = Registry.register_policy(FirstPolicy, owner: "owner-policy")
    assert :ok = Registry.register_prompt("a", "A", owner: "owner-a")

    assert Registry.runtime_entries() == [
             %{key: {:policy, :default}, value: FirstPolicy, owner: "owner-policy"},
             %{key: {:text, :system, "a"}, value: "A", owner: "owner-a"},
             %{key: {:text, :system, "z"}, value: "Z", owner: "owner-z"}
           ]
  end

  test "policy selection is runtime then live application then built-in" do
    assert {:ok, Catalyst.SystemPrompt, :builtin} = Registry.policy()
    assert {:ok, Catalyst.SystemPrompt} = Registry.fetch_policy()

    Application.put_env(:catalyst, :prompt_policy, FirstPolicy)
    assert {:ok, FirstPolicy, {:application, :prompt_policy}} = Registry.policy()
    assert {:ok, FirstPolicy} = Registry.fetch_policy()

    assert :ok = Registry.register_policy(SecondPolicy, owner: "policy-owner")

    assert {:ok, SecondPolicy, {:extension, "policy-owner", {:policy, :default}}} =
             Registry.policy()

    Application.delete_env(:catalyst, :prompt_policy)
    assert :ok = Registry.unregister_owner("policy-owner")
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

    assert Registry.runtime_entries() == []
  end

  test "malformed live policy configuration is tagged" do
    Application.put_env(:catalyst, :prompt_policy, String)
    assert {:error, {:invalid_prompt_policy, String}} = Registry.policy()
  end

  test "reads still use live application fallback while the ETS table is absent" do
    Application.put_env(:catalyst, :prompts, %{system: %{default: "without ETS"}})
    Application.put_env(:catalyst, :prompt_policy, FirstPolicy)

    with_registry_absent(fn ->
      assert {:ok, "without ETS", {:application, {:prompts, :system, :default}}} =
               Registry.lookup_text(:system, :default)

      assert {:ok, FirstPolicy, {:application, :prompt_policy}} = Registry.policy()
      assert Registry.runtime_entries() == []
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
    case Process.whereis(Registry) do
      pid when is_pid(pid) ->
        Registry.runtime_entries()
        |> Enum.each(&Registry.unregister(&1.key))

      _not_started ->
        :ok
    end
  end

  defp with_registry_absent(fun) do
    case stop_supervised(Registry) do
      :ok ->
        assert Process.whereis(Registry) == nil
        fun.()

      {:error, _not_test_supervised} ->
        with_application_registry_suspended(fun)
    end
  end

  defp with_application_registry_suspended(fun) do
    old_registry = Process.whereis(Registry)
    supervisor = parent_supervisor(old_registry)
    ref = Process.monitor(old_registry)
    :ok = :sys.suspend(supervisor)

    try do
      Process.exit(old_registry, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_registry, :killed}
      assert Process.whereis(Registry) == nil
      fun.()
    after
      :ok = :sys.resume(supervisor)
      wait_for_registry(old_registry)
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
    case Process.whereis(Registry) do
      pid when is_pid(pid) and pid != old_registry ->
        _ = :sys.get_state(pid)
        :ok

      _not_restarted ->
        receive do
        after
          10 -> wait_for_registry(old_registry, attempts - 1)
        end
    end
  end

  defp restore_env(key, :error), do: Application.delete_env(:catalyst, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:catalyst, key, value)
end
