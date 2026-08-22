defmodule CatalystCli.ReleaseSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :release

  @tag timeout: 600_000
  test "R1: plain CLI release hot-loads, persists a turn, isolates paths, and boots safe" do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_release_smoke_#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    release_path = Path.join(root, "release")
    catalyst_home = Path.join(root, "catalyst-home")
    os_home = Path.join(root, "os-home")
    umbrella_root = Path.expand("../../..", __DIR__)

    File.mkdir_p!(catalyst_home)
    File.mkdir_p!(os_home)
    on_exit(fn -> File.rm_rf!(root) end)

    mix = System.find_executable("mix") || flunk("mix executable is unavailable")

    {build_output, build_status} =
      System.cmd(
        mix,
        ["release", "catalyst_cli", "--overwrite", "--path", release_path],
        cd: umbrella_root,
        env: [{"MIX_ENV", "prod"}, {"CATALYST_RELEASE_PLAIN", "1"}],
        stderr_to_stdout: true
      )

    assert build_status == 0, "plain release build failed:\n#{build_output}"

    executable = Path.join([release_path, "bin", "catalyst_cli"])
    env = [{"CATALYST_HOME", catalyst_home}, {"HOME", os_home}]

    {turn_output, turn_status} =
      System.cmd(executable, ["eval", release_turn_eval()], env: env, stderr_to_stdout: true)

    assert turn_status == 0, "release turn eval failed:\n#{turn_output}"
    assert turn_output =~ "PACKAGED HOT-LOAD WORKS"
    assert turn_output =~ "RELEASE CHILD OK"
    assert turn_output =~ "RELEASE TURN OK"

    assert Path.wildcard(Path.join([catalyst_home, "extensions", "cli_selftest_*.ex"])) == []
    assert Path.wildcard(Path.join([catalyst_home, "sessions", "**", "*.jsonl"])) != []

    fixture =
      Path.expand(
        "../../catalyst/test/fixtures/extensions/safe_mode_probe.ex",
        __DIR__
      )

    extensions_dir = Path.join(catalyst_home, "extensions")
    File.mkdir_p!(extensions_dir)
    File.write!(Path.join(catalyst_home, "boot_marker"), "booting\n")
    File.cp!(fixture, Path.join(extensions_dir, "safe_mode_probe.ex"))

    {safe_output, safe_status} =
      System.cmd(executable, ["eval", safe_mode_eval()], env: env, stderr_to_stdout: true)

    assert safe_status == 0, "release safe-mode eval failed:\n#{safe_output}"
    assert safe_output =~ "RELEASE SAFE MODE OK"
    refute File.exists?(Path.join(catalyst_home, "safe_mode_probe_ran"))
    refute File.exists?(Path.join(extensions_dir, "safe_mode_probe.ex"))
  end

  defp release_turn_eval do
    ~S'''
    {:ok, _apps} = Application.ensure_all_started(:catalyst)
    :ok = Catalyst.Extensions.await_ready(5_000)
    "minimal-cli" = Catalyst.Product.id()
    home = Path.expand(System.fetch_env!("CATALYST_HOME"))

    paths = [
      Catalyst.Paths.home(),
      Catalyst.Paths.extensions(),
      Catalyst.Paths.sessions(),
      Catalyst.Paths.debug(),
      Catalyst.Paths.auth(),
      Catalyst.Paths.system_prompt(),
      Catalyst.Paths.prompts(),
      Catalyst.Paths.agents(),
      Catalyst.Tools.ListAgents.agents_dir(),
      Catalyst.Paths.boot_marker(),
      Catalyst.Paths.join("guide.md")
    ]

    Enum.each(paths, fn path ->
      expanded = Path.expand(path)

      case expanded == home or String.starts_with?(expanded, home <> "/") do
        true -> :ok
        false -> raise "Catalyst path escaped CATALYST_HOME: #{expanded}"
      end
    end)

    case {
      Catalyst.Prompt.Registry.runtime_entries(),
      Catalyst.Workflow.Registry.runtime_entries(),
      Catalyst.Context.Registry.runtime_entries()
    } do
      {[], [], []} -> :ok
      entries -> raise "release registries booted with runtime overlays: #{inspect(entries)}"
    end

    {:ok, Catalyst.SystemPrompt, _prompt_source} = Catalyst.Prompt.Registry.policy()
    {:ok, %{module: Catalyst.Agent.Loop}} = Catalyst.Workflow.resolve([])
    {:ok, Catalyst.Context.Window, _context_source} = Catalyst.Context.Registry.policy()

    File.mkdir_p!(Catalyst.Tools.ListAgents.agents_dir())
    agent_path = Path.join(Catalyst.Tools.ListAgents.agents_dir(), "release_review.md")
    File.write!(agent_path, "You are the packaged release reviewer.")

    {:ok, [%{name: "release_review", path: ^agent_path}]} = Catalyst.Tools.ListAgents.list()

    loaded_before_selftest = Catalyst.Extensions.list_loaded()
    sources_before_selftest = Path.wildcard(Path.join(Catalyst.Paths.extensions(), "*.ex"))
    :ok = CatalystCli.run(["selftest"])

    case Catalyst.Extensions.list_loaded() == loaded_before_selftest do
      true -> :ok
      false -> raise "selftest registration leaked"
    end

    case Path.wildcard(Path.join(Catalyst.Paths.extensions(), "*.ex")) == sources_before_selftest do
      true -> :ok
      false -> raise "selftest source leaked into CATALYST_HOME"
    end

    model = %Catalyst.Model{id: "faux", api: "faux", provider: "faux"}

    child_context =
      Catalyst.Tools.Context.new(
        cwd: home,
        parent_session_id: "release-parent",
        root_session_id: "release-root",
        model: model,
        provider: Catalyst.LLM.Faux,
        opts: [script: [{:text, "RELEASE CHILD OK"}], subagent_timeout: 5_000],
        workflow: Catalyst.Agent.Loop,
        tool_source: [],
        agent_depth: 0,
        call_id: "release-spawn",
        report: fn _partial -> :ok end
      )

    {:ok, "RELEASE CHILD OK", child_details} =
      Catalyst.Tools.SpawnAgent.run(
        %{"agent" => "release_review", "task" => "Review the packaged release."},
        child_context
      )

    :error = Catalyst.Session.Manager.whereis(child_details.child_session_id)
    0 = Catalyst.Agent.Children.count("release-root")
    IO.puts("RELEASE CHILD OK")

    {:ok, %{id: id, pid: pid}} =
      Catalyst.Session.Manager.start_session(
        cwd: home,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: [{:text, "RELEASE TURN OK"}]]
      )

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Catalyst.Session.Server.topic(id))
    :ok = Catalyst.Session.Server.prompt(pid, "release smoke")

    receive do
      {:agent_event, ^id, %Catalyst.Agent.Event.AgentEnd{}} -> :ok
    after
      5_000 -> raise "release session did not finish"
    end

    snapshot = Catalyst.Session.Server.state(pid)
    final = snapshot.messages |> List.last() |> Map.fetch!(:content) |> Catalyst.Content.text_of()

    case final == "RELEASE TURN OK" do
      true -> :ok
      false -> raise "unexpected release response: #{inspect(final)}"
    end

    store = Path.expand(snapshot.store_path)

    case String.starts_with?(store, home <> "/") and File.regular?(store) do
      true -> :ok
      false -> raise "session store escaped CATALYST_HOME or is absent: #{store}"
    end

    ref = Process.monitor(pid)
    :ok = Catalyst.Session.Manager.stop(id)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> raise "release session did not stop"
    end

    IO.puts("RELEASE TURN OK")
    '''
  end

  defp safe_mode_eval do
    ~S'''
    {:ok, _apps} = Application.ensure_all_started(:catalyst)

    case Catalyst.Extensions.boot_status() do
      {:safe_mode, :crash_detected} -> :ok
      other -> raise "expected crash-detected safe mode, got: #{inspect(other)}"
    end

    for tool <- Catalyst.Product.tools(), name = tool.name() do
      case Catalyst.Extensions.fetch(name) do
        {:ok, ^tool} -> :ok
        other -> raise "product tool #{name} unavailable in safe mode: #{inspect(other)}"
      end
    end

    {:ok, Catalyst.SystemPrompt, _prompt_source} = Catalyst.Prompt.Registry.policy()
    {:ok, %{module: Catalyst.Agent.Loop}} = Catalyst.Workflow.resolve([])
    {:ok, Catalyst.Context.Window, _context_source} = Catalyst.Context.Registry.policy()

    {:ok, [%{name: "release_review"}]} = Catalyst.Tools.ListAgents.list()

    sentinel = Path.join(Catalyst.Paths.home(), "safe_mode_probe_ran")

    case File.exists?(sentinel) do
      false -> :ok
      true -> raise "safe-mode probe setup unexpectedly ran"
    end

    source = Path.join(Catalyst.Paths.extensions(), "safe_mode_probe.ex")
    :ok = File.rm(source)
    {:ok, %{failed: []}} = Catalyst.Extensions.load_all()

    case Catalyst.Extensions.boot_status() do
      :ok -> :ok
      other -> raise "reload did not clear safe mode: #{inspect(other)}"
    end

    IO.puts("RELEASE SAFE MODE OK")
    '''
  end
end
