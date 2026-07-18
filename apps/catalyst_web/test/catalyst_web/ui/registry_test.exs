defmodule CatalystWeb.UI.RegistryTest do
  use Catalyst.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.ExtensionAPI
  alias CatalystWeb.UI.Contributions
  alias CatalystWeb.UI.Registry

  @owner "ui_registry_test_owner"
  @dispatch_probe_key {__MODULE__, :dispatch_probe}

  setup do
    on_exit(fn -> Registry.unregister_owner(@owner) end)
    :ok
  end

  test "extension wiring uses stable external captures" do
    purgers = :persistent_term.get({ExtensionAPI, :purgers}, %{})
    purger_key = {Registry, :purge_extension_owner, 1}

    assert %{^purger_key => purger} = purgers
    assert Function.info(purger, :type) == {:type, :external}

    handlers = %{
      renderer: {:register_extension_renderer, 4},
      component: {:register_extension_component, 4},
      page: {:register_extension_page, 4},
      command: {:register_extension_command, 3}
    }

    for {kind, {name, arity}} <- handlers do
      handler = :persistent_term.get({ExtensionAPI, :kind, kind})

      assert Function.info(handler, :type) == {:type, :external}
      assert Function.info(handler, :module) == {:module, Registry}
      assert Function.info(handler, :name) == {:name, name}
      assert Function.info(handler, :arity) == {:arity, arity}
    end
  end

  describe "pages" do
    test "last write wins per path, and purging the owner restores a displaced built-in" do
      assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")

      Registry.register_page("chat", {__MODULE__, :fake_render}, owner: @owner)
      assert {:ok, {__MODULE__, :fake_render}} = Registry.fetch_page("chat")

      Registry.unregister_owner(@owner)
      assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")
    end

    test "the extensions built-in page is restored too (it has no ShellLive fallback)" do
      Registry.register_page("extensions", {__MODULE__, :fake_render}, owner: @owner)
      assert {:ok, {__MODULE__, :fake_render}} = Registry.fetch_page("extensions")

      Registry.unregister_owner(@owner)

      assert {:ok, {CatalystWeb.Pages.ExtensionsPage, :render}} =
               Registry.fetch_page("extensions")
    end

    test "a purged non-builtin page is simply removed" do
      Registry.register_page("scratch", {__MODULE__, :fake_render}, owner: @owner)
      assert {:ok, _} = Registry.fetch_page("scratch")

      Registry.unregister_owner(@owner)
      assert :error = Registry.fetch_page("scratch")
    end

    test "extension facades force the real owner over a spoofed :owner option" do
      api = ExtensionAPI.new(@owner)

      :ok =
        Registry.register_extension_page(api, "spoof-page", {__MODULE__, :fake_render},
          owner: "spoofed-owner"
        )

      :ok =
        Registry.register_extension_command(api, "spoofcmd",
          owner: "spoofed-owner",
          handler: &__MODULE__.fake_command/2
        )

      :ok =
        Registry.register_extension_component(api, :spoof_slot, &__MODULE__.fake_render/1,
          owner: "spoofed-owner"
        )

      assert {:ok, _} = Registry.fetch_page("spoof-page")
      assert {:ok, %{owner: @owner}} = Registry.fetch_command("spoofcmd")

      # Purging the real owner must remove everything it registered; a spoofed
      # :owner in opts cannot detach a registration from its extension.
      Registry.unregister_owner(@owner)

      assert :error = Registry.fetch_page("spoof-page")
      assert :error = Registry.fetch_command("spoofcmd")
      refute Enum.any?(Registry.list_components(), &(&1.owner == "spoofed-owner"))
    end
  end

  describe "commands" do
    test "overriding /cd and purging the owner restores the built-in handler" do
      assert {:ok, %{owner: nil}} = Registry.fetch_command("cd")

      Registry.register_command("cd", owner: @owner, handler: &__MODULE__.fake_command/2)
      assert {:ok, %{owner: @owner}} = Registry.fetch_command("cd")

      Registry.unregister_owner(@owner)
      assert {:ok, entry} = Registry.fetch_command("cd")
      assert entry.owner == nil
      assert entry.handler == (&CatalystWeb.ShellLive.Commands.change_directory/2)
      assert entry.label =~ "/cd <path>"
    end

    test "fetch_command returns the newest entry for a name" do
      Registry.register_command("flexdup", owner: @owner, label: "first")
      Registry.register_command("flexdup", owner: @owner, label: "second")

      assert {:ok, %{label: "second"}} = Registry.fetch_command("flexdup")
    end
  end

  describe "renderers" do
    test "newest matching renderer wins; a crashing match_fun is skipped" do
      Registry.register_renderer(:message, &match?({:probe, _}, &1), fn _ -> :older end,
        owner: @owner
      )

      Registry.register_renderer(:message, &match?({:probe, _}, &1), fn _ -> :newer end,
        owner: @owner
      )

      assert Registry.renderer(:message, {:probe, 1}).(%{}) == :newer

      # A newest renderer whose match raises must fall through, not crash.
      Registry.register_renderer(:message, fn _ -> raise "boom" end, fn _ -> :crashy end,
        owner: @owner
      )

      assert Registry.renderer(:message, {:probe, 1}).(%{}) == :newer
      assert Registry.renderer(:message, {:unmatched, 1}) == nil
    end
  end

  describe "unregister_owner" do
    test "sweeps all four kinds for the owner" do
      Registry.register_page("sweep", {__MODULE__, :fake_render}, owner: @owner)

      Registry.register_renderer(:message, &match?(:sweep_probe, &1), fn _ -> :x end,
        owner: @owner
      )

      Registry.register_component(:header_extra, fn _ -> :x end, owner: @owner)
      Registry.register_command("sweepcmd", owner: @owner, handler: &__MODULE__.fake_command/2)

      Registry.unregister_owner(@owner)

      assert :error = Registry.fetch_page("sweep")
      assert Registry.renderer(:message, :sweep_probe) == nil
      refute Enum.any?(Registry.list_components(), &(&1.owner == @owner))
      assert :error = Registry.fetch_command("sweepcmd")
    end
  end

  describe "crash recovery" do
    test "a registry restart retains accepted built-ins and extension contributions" do
      install_fixture!("ui_chat_page")
      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")

      pid = Process.whereis(Registry)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      new_pid = wait_for_restart!(Registry, pid)
      _ = :sys.get_state(new_pid)

      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")
      assert {:ok, %{owner: nil}} = Registry.fetch_command("cd")

      remove_installed_fixture!("ui_chat_page")
      assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")
    end

    test "table-loss recovery does not query Extensions from Registry.init" do
      extensions = Process.whereis(Catalyst.Extensions)
      :sys.suspend(extensions)

      try do
        :ets.delete_all_objects(:catalyst_ui)

        pid = Process.whereis(Registry)
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

        new_pid = wait_for_restart!(Registry, pid)
        assert %{seq: _seq} = :sys.get_state(new_pid, 500)
      after
        :sys.resume(extensions)
      end

      assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")
    end

    test "registry recovery removes ETS entries absent from the authoritative log" do
      Registry.register_page("stale-replay", {__MODULE__, :fake_render}, owner: @owner)
      assert {:ok, {__MODULE__, :fake_render}} = Registry.fetch_page("stale-replay")

      :ok = Contributions.drop_owner(@owner)

      pid = Process.whereis(Registry)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      new_pid = wait_for_restart!(Registry, pid)
      _ = :sys.get_state(new_pid)

      assert :error = Registry.fetch_page("stale-replay")
    end

    test "a table-owner restart replays accepted UI contributions" do
      install_fixture!("ui_chat_page")
      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")

      old_owner = Process.whereis(CatalystWeb.UI.TableOwner)
      old_registry = Process.whereis(Registry)
      owner_ref = Process.monitor(old_owner)
      registry_ref = Process.monitor(old_registry)
      Process.exit(old_owner, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^old_owner, :killed}
      assert_receive {:DOWN, ^registry_ref, :process, ^old_registry, _reason}

      _new_owner = wait_for_restart!(CatalystWeb.UI.TableOwner, old_owner)
      new_registry = wait_for_restart!(Registry, old_registry)
      _ = :sys.get_state(new_registry)

      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")

      remove_installed_fixture!("ui_chat_page")
      assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")
    end

    test "the replay log survives its own supervised restart" do
      install_fixture!("ui_chat_page")
      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")

      contributions = Process.whereis(CatalystWeb.UI.Contributions)
      registry = Process.whereis(Registry)
      contributions_ref = Process.monitor(contributions)
      Process.exit(contributions, :kill)
      assert_receive {:DOWN, ^contributions_ref, :process, ^contributions, :killed}

      _new_contributions = wait_for_restart!(CatalystWeb.UI.Contributions, contributions)
      new_registry = wait_for_restart!(Registry, registry)
      _ = :sys.get_state(new_registry)

      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")

      remove_installed_fixture!("ui_chat_page")
      assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")
    end

    test "a safe-mode Extensions generation revokes prior UI, hooks, and modules" do
      %{owner: owner} = install_fixture!("ui_chat_page")
      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")

      Catalyst.Hooks.register(:safe_mode_probe, fn value, _context -> {:ok, value} end,
        owner: owner
      )

      stale_api = ExtensionAPI.new(owner)

      assert Enum.any?(Catalyst.Hooks.handlers(:safe_mode_probe), &(&1.owner == owner))
      with_app_env(:catalyst, :safe_mode, true)

      extensions = Process.whereis(Catalyst.Extensions)
      ref = Process.monitor(extensions)
      Process.exit(extensions, :kill)
      assert_receive {:DOWN, ^ref, :process, ^extensions, :killed}

      new_extensions = wait_for_restart!(Catalyst.Extensions, extensions)
      _ = :sys.get_state(new_extensions)

      assert Catalyst.Extensions.boot_status() == {:safe_mode, :env}
      assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")
      refute Enum.any?(Catalyst.Hooks.handlers(:safe_mode_probe), &(&1.owner == owner))
      refute Code.ensure_loaded?(Catalyst.Ext.FlexChatPage)

      assert {:error, :stale_extension_generation} =
               ExtensionAPI.register_page(stale_api, "stale-generation", __MODULE__)

      assert :error = Registry.fetch_page("stale-generation")
    end

    test "an in-flight stale registration cannot purge the replacement generation" do
      owner = "generation_gate_owner"
      path = "generation-gate-page"
      previous_handler = :persistent_term.get({ExtensionAPI, :kind, :page})
      gate = make_ref()

      :persistent_term.put(@dispatch_probe_key, %{test: self(), gate: gate})
      ExtensionAPI.register_kind(:page, &__MODULE__.blocking_page_registration/4)

      on_exit(fn ->
        :persistent_term.erase(@dispatch_probe_key)
        ExtensionAPI.register_kind(:page, previous_handler)
        Registry.unregister_owner(owner)
      end)

      stale_api = ExtensionAPI.new(owner)

      task =
        Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
          ExtensionAPI.register_page(stale_api, path, __MODULE__)
        end)

      assert_receive {:dispatch_waiting, blocked, ^gate}

      extensions = Process.whereis(Catalyst.Extensions)
      ref = Process.monitor(extensions)
      Process.exit(extensions, :kill)
      assert_receive {:DOWN, ^ref, :process, ^extensions, :killed}

      new_extensions = wait_for_restart!(Catalyst.Extensions, extensions)
      assert Catalyst.Extensions.generation_token() == nil

      send(blocked, {:continue, gate})
      assert {:error, :stale_extension_generation} = Task.await(task, 5_000)
      _ = :sys.get_state(new_extensions)

      ExtensionAPI.register_kind(:page, previous_handler)
      fresh_api = ExtensionAPI.new(owner)

      assert :ok = ExtensionAPI.register_page(fresh_api, path, __MODULE__)
      assert {:ok, {__MODULE__, :render}} = Registry.fetch_page(path)

      assert {:ok, %{failed: []}} = Catalyst.Extensions.load_all()
      CatalystWeb.Application.register_web_tools()
    end

    test "table recovery replays live entries without activating current disk edits" do
      install_fixture!("ui_chat_page")
      accepted_path = Path.join(Catalyst.Extensions.dir(), "ui_chat_page.ex")
      File.write!(accepted_path, "this current edit is intentionally not valid Elixir")

      unaccepted_path =
        write_extension!(
          "unaccepted_ui_recovery",
          ~S"""
          defmodule Catalyst.Ext.UnacceptedRecoveryPage do
            def render(assigns), do: assigns
          end

          defmodule Catalyst.Ext.UnacceptedRecoveryExtension do
            use Catalyst.Extension

            @impl true
            def setup(api) do
              Catalyst.ExtensionAPI.register_page(
                api,
                "unaccepted-recovery",
                Catalyst.Ext.UnacceptedRecoveryPage
              )
            end
          end
          """
        )

      old_owner = Process.whereis(CatalystWeb.UI.TableOwner)
      old_registry = Process.whereis(Registry)
      owner_ref = Process.monitor(old_owner)
      Process.exit(old_owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^old_owner, :killed}

      _new_owner = wait_for_restart!(CatalystWeb.UI.TableOwner, old_owner)
      new_registry = wait_for_restart!(Registry, old_registry)
      _ = :sys.get_state(new_registry)

      assert {:ok, {Catalyst.Ext.FlexChatPage, :render}} = Registry.fetch_page("chat")
      assert :error = Registry.fetch_page("unaccepted-recovery")

      File.rm!(unaccepted_path)
      remove_installed_fixture!("ui_chat_page")
    end
  end

  def fake_render(assigns), do: assigns
  def fake_command(_arg, socket), do: socket

  def blocking_page_registration(api, path, target, opts) do
    %{test: test, gate: gate} = :persistent_term.get(@dispatch_probe_key)
    result = Registry.register_extension_page(api, path, target, opts)
    send(test, {:dispatch_waiting, self(), gate})

    receive do
      {:continue, ^gate} -> result
    end
  end
end
