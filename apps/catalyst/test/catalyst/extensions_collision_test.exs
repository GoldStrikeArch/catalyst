defmodule Catalyst.ExtensionsCollisionTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [put_env: 2]
  import Catalyst.ExtensionsFixtures

  alias Catalyst.Extensions
  alias Catalyst.ExtensionsFixtures.SetupOnlyTool
  alias Catalyst.Tools.ReloadTool

  setup do
    setup_extensions_dir()
  end

  test "killing a load caller cannot abandon a committed setup collision" do
    put_env(:extension_setup_timeout, 100)
    put_parent!(:cancelled_setup_parent)

    on_exit(fn ->
      Extensions.uninstall("cancelled_provider_owner_b")
      Extensions.uninstall("cancelled_provider_owner_a")
    end)

    first =
      write_ext(
        "cancelled_provider_owner_a",
        ~S'''
        defmodule Catalyst.Ext.CancelledOwnedProvider do
          def identity, do: :a
          def stream(_request, _messages, _opts, _emit), do: {:error, :not_implemented}
        end

        defmodule Catalyst.Ext.CancelledProviderAExtension do
          use Catalyst.Extension

          @impl true
          def setup(api) do
            Catalyst.ExtensionAPI.register_provider(
              api,
              "cancelled-owned-provider",
              Catalyst.Ext.CancelledOwnedProvider
            )
          end
        end
        '''
      )

    second =
      write_ext(
        "cancelled_provider_owner_b",
        ~S'''
        defmodule Catalyst.Ext.CancelledOwnedProvider do
          def identity, do: :b
          def stream(_request, _messages, _opts, _emit), do: {:error, :not_implemented}
        end

        defmodule Catalyst.Ext.CancelledProviderBExtension do
          use Catalyst.Extension

          @impl true
          def setup(api) do
            _ignored =
              Catalyst.ExtensionAPI.register_provider(
                api,
                "cancelled-owned-provider",
                Catalyst.Ext.CancelledOwnedProvider
              )

            send(
              :persistent_term.get({Catalyst.ExtensionsFixtures, :cancelled_setup_parent}),
              {:cancelled_setup_started, self()}
            )

            receive do
              :never -> :ok
            end
          end
        end
        '''
      )

    assert {:ok, _} = Extensions.load_file(first)
    caller = start_supervised!({Task, fn -> Extensions.load_file(second) end})
    assert_receive {:cancelled_setup_started, setup_task}
    setup_ref = Process.monitor(setup_task)

    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^setup_ref, :process, ^setup_task, :killed}, 1_000

    # A second serialized transaction waits for the abandoned caller's durable
    # transaction to finish its timeout, collision rejection, and restoration.
    assert :ok = Extensions.locked(fn -> :ok end)

    state = :sys.get_state(Extensions)
    assert state.setup_collisions == %{}
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "cancelled_provider_owner_b"))
    assert apply(Catalyst.Ext.CancelledOwnedProvider, :identity, []) == :a
  end

  test "colliding normalized filenames reject the directory load before compiling" do
    first = Path.join(Extensions.dir(), "Owner One.ex")
    second = Path.join(Extensions.dir(), "owner---one.ex")
    File.write!(first, "defmodule Catalyst.Ext.OwnerOneA do end")
    File.write!(second, "defmodule Catalyst.Ext.OwnerOneB do end")

    assert {:error, {:owner_collision, "owner_one", paths}} = Extensions.load_all()
    assert Enum.sort(paths) == Enum.sort([first, second])
    refute Code.ensure_loaded?(Catalyst.Ext.OwnerOneA)
    refute Code.ensure_loaded?(Catalyst.Ext.OwnerOneB)
  end

  test "reload tool surfaces colliding normalized filenames without a match error" do
    File.write!(
      Path.join(Extensions.dir(), "Owner One.ex"),
      "defmodule Catalyst.Ext.OwnerOneA do end"
    )

    File.write!(
      Path.join(Extensions.dir(), "owner---one.ex"),
      "defmodule Catalyst.Ext.OwnerOneB do end"
    )

    assert_raise RuntimeError, ~r/multiple extension files normalize to owner "owner_one"/, fn ->
      ReloadTool.execute(%{}, %{})
    end
  end

  test "a second extension owner cannot replace an extension-owned tool" do
    first =
      write_ext(
        "tool_owner_a",
        owned_tool_source("Catalyst.Ext.OwnedToolA", "owned_collision", "owner a")
      )

    second =
      write_ext(
        "tool_owner_b",
        owned_tool_source("Catalyst.Ext.OwnedToolB", "owned_collision", "owner b")
      )

    assert {:ok, _} = Extensions.load_file(first)

    assert {:error, {:owner_collision, :tool, "owned_collision", "tool_owner_a", "tool_owner_b"}} =
             Extensions.load_file(second)

    assert {:ok, Catalyst.Ext.OwnedToolA} = Extensions.fetch("owned_collision")

    :ok = Extensions.uninstall("tool_owner_b")
    assert {:ok, Catalyst.Ext.OwnedToolA} = Extensions.fetch("owned_collision")

    :ok = Extensions.uninstall("tool_owner_a")
    assert :error = Extensions.fetch("owned_collision")
  end

  test "an ownerless host registration cannot detach an extension-owned tool" do
    path = write_ext("setupreg", setup_reg_source())
    on_exit(fn -> Extensions.uninstall("setupreg") end)

    assert {:ok, _summary} = Extensions.load_file(path)

    assert {:error, {:owner_collision, :tool, "setup_only_tool", "setupreg", :host}} =
             Extensions.register_tool(SetupOnlyTool)

    assert {:ok, SetupOnlyTool} = Extensions.fetch("setup_only_tool")

    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "setupreg")).tools == [
             "setup_only_tool"
           ]
  end

  test "a rejected tool owner cannot leave a same-named module redefined" do
    module = "Catalyst.Ext.SameOwnedTool"

    first =
      write_ext(
        "same_tool_owner_a",
        owned_tool_source(module, "same_owned_collision", "owner a")
      )

    second =
      write_ext(
        "same_tool_owner_b",
        owned_tool_source(module, "same_owned_collision", "owner b")
      )

    on_exit(fn ->
      Extensions.uninstall("same_tool_owner_b")
      Extensions.uninstall("same_tool_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    assert apply(Catalyst.Ext.SameOwnedTool, :description, []) == "owner a"

    assert {:error,
            {:owner_collision, :tool, "same_owned_collision", "same_tool_owner_a",
             "same_tool_owner_b"}} = Extensions.load_file(second)

    assert {:ok, Catalyst.Ext.SameOwnedTool} = Extensions.fetch("same_owned_collision")
    assert apply(Catalyst.Ext.SameOwnedTool, :description, []) == "owner a"

    :ok = Extensions.uninstall("same_tool_owner_b")
    assert apply(Catalyst.Ext.SameOwnedTool, :description, []) == "owner a"
  end

  test "collision restoration uses the tracked path for an externally loaded file" do
    external_dir =
      Path.join(System.tmp_dir!(), "catalyst_external_ext_#{System.unique_integer([:positive])}")

    File.mkdir_p!(external_dir)
    on_exit(fn -> File.rm_rf!(external_dir) end)

    first = Path.join(external_dir, "external_tool_owner_a.ex")

    File.write!(
      first,
      owned_tool_source("Catalyst.Ext.ExternalOwnedTool", "external_collision", "owner a")
    )

    second =
      write_ext(
        "external_tool_owner_b",
        owned_tool_source("Catalyst.Ext.ExternalOwnedTool", "external_collision", "owner b")
      )

    on_exit(fn ->
      Extensions.uninstall("external_tool_owner_b")
      Extensions.uninstall("external_tool_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)

    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "external_tool_owner_a")).path ==
             first

    assert {:error,
            {:owner_collision, :tool, "external_collision", "external_tool_owner_a",
             "external_tool_owner_b"}} = Extensions.load_file(second)

    assert apply(Catalyst.Ext.ExternalOwnedTool, :description, []) == "owner a"
  end

  test "a rejected distinct tool does not recompile or evict the live owner" do
    first =
      write_ext(
        "distinct_tool_owner_a",
        owned_tool_source("Catalyst.Ext.DistinctOwnedToolA", "distinct_collision", "owner a")
      )

    second =
      write_ext(
        "distinct_tool_owner_b",
        rejected_dynamic_module_source() <>
          owned_tool_source(
            "Catalyst.Ext.DistinctOwnedToolB",
            "distinct_collision",
            "owner b"
          )
      )

    on_exit(fn ->
      Extensions.uninstall("distinct_tool_owner_b")
      Extensions.uninstall("distinct_tool_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    File.write!(first, "this source is intentionally invalid @@@")

    assert {:error,
            {:owner_collision, :tool, "distinct_collision", "distinct_tool_owner_a",
             "distinct_tool_owner_b"}} = Extensions.load_file(second)

    assert {:ok, Catalyst.Ext.DistinctOwnedToolA} = Extensions.fetch("distinct_collision")
    assert apply(Catalyst.Ext.DistinctOwnedToolA, :description, []) == "owner a"
    refute Code.ensure_loaded?(Catalyst.Ext.DistinctOwnedToolB)
    refute Code.ensure_loaded?(Catalyst.Ext.RejectedDynamicHelper)
  end

  test "a rejected provider owner cannot leave a same-named module redefined" do
    first = write_ext("same_provider_owner_a", owned_provider_source(:a))
    second = write_ext("same_provider_owner_b", owned_provider_source(:b))

    on_exit(fn ->
      Extensions.uninstall("same_provider_owner_b")
      Extensions.uninstall("same_provider_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    assert apply(Catalyst.Ext.SameOwnedProvider, :identity, []) == :a

    assert {:error,
            {:owner_collision, :provider, "same-owned-provider", "same_provider_owner_a",
             "same_provider_owner_b"}} = Extensions.load_file(second)

    assert {:ok, config} = Catalyst.LLM.Registry.fetch_config("same-owned-provider")
    assert config.module == Catalyst.Ext.SameOwnedProvider

    assert apply(Catalyst.Ext.SameOwnedProvider, :identity, []) == :a

    :ok = Extensions.uninstall("same_provider_owner_b")
    assert apply(Catalyst.Ext.SameOwnedProvider, :identity, []) == :a
  end

  test "a timed-out setup cannot hide an ignored provider owner collision" do
    put_env(:extension_setup_timeout, 100)
    put_parent!(:timed_collision_parent)

    first = write_ext("timed_provider_owner_a", timed_provider_source(:a, false))
    second = write_ext("timed_provider_owner_b", timed_provider_source(:b, true))

    on_exit(fn ->
      Extensions.uninstall("timed_provider_owner_b")
      Extensions.uninstall("timed_provider_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)

    assert {:error,
            {:owner_collision, :provider, "timed-owned-provider", "timed_provider_owner_a",
             "timed_provider_owner_b"}} = Extensions.load_file(second)

    assert_receive :timed_collision_recorded
    assert apply(Catalyst.Ext.TimedOwnedProvider, :identity, []) == :a
  end
end
