defmodule CatalystWeb.Flex.GuideExamplesTest do
  use CatalystWeb.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.{Content, Extensions}
  alias Catalyst.Extensions.Installer

  @manifest Path.expand("../fixtures/guide_examples_manifest.json", __DIR__)
  @result_probe Catalyst.Flex.GuideResultProbe

  test "G1: every bundled Elixir block is classified in the manifest" do
    # Count + id-set only: the per-block content fingerprint was dropped so a
    # prose edit to the guide no longer requires a manifest update — the blocks'
    # behavior is pinned by the executable G1 tests below.
    blocks = Fixtures.guide_blocks()
    manifest = @manifest |> File.read!() |> Jason.decode!()
    manifest_by_id = Map.new(manifest, &{&1["id"], &1})

    assert length(blocks) == 7
    assert Enum.sort(Map.keys(manifest_by_id)) == Enum.sort(Enum.map(blocks, & &1.id))
  end

  test "G1: ComputerUseGate compiles without setup and gates the documented tool set" do
    block = guide_block!("computer_use_gate")
    assert {:ok, _ast} = Code.string_to_quoted(block.source)

    # The recipe must gate the machine-control tools and speak in retryable
    # block reasons — the auto-allow counterweight the guide promises.
    assert block.source =~ "before_tool_call"
    assert block.source =~ ~s({:block,)

    for tool <- ~w(computer applescript open_app clipboard shell_session) do
      assert block.source =~ tool
    end

    purge_module(Catalyst.Ext.ComputerUseGate)

    try do
      assert [{Catalyst.Ext.ComputerUseGate, _binary}] = Code.compile_string(block.source)
      assert function_exported?(Catalyst.Ext.ComputerUseGate, :setup, 1)
    after
      purge_module(Catalyst.Ext.ComputerUseGate)
    end
  end

  # AUDIT: the gate is the *only* counterweight to auto-allow, and it excludes
  # `bash` — which is always advertised — while its own block reason hands the
  # model the exact command that opens the gate ("touch <approval_path>"). The
  # model can approve itself through ungated bash and retry, with no human in
  # the loop. Either bash is gated too, or approval must not be reachable from
  # any tool the gate lets through.
  @tag :audit
  test "G1: ComputerUseGate cannot be opened by the tools it lets through" do
    install_guide_block!(guide_block!("computer_use_gate"), "guide_computer_gate")

    approval = Path.expand("~/.catalyst/computer_use_approved")
    refute File.exists?(approval), "test would be meaningless: the gate is already open"

    self_approval = %{
      name: "bash",
      args: %{"command" => "touch #{approval}"},
      call_id: "audit",
      cwd: File.cwd!(),
      assistant: nil
    }

    assert match?({:block, _reason}, Catalyst.Hooks.before_tool_call(self_approval)),
           "the gate let an ungated tool create its own approval file"
  end

  # AUDIT (resolved): approval and confirmation now live in the gate's
  # supervised state process, whose only writers are human channels — the
  # `/computer` chat command (dispatched exclusively from text the user types
  # into the chat input; no tool can issue it) and the module's console
  # functions, which that command calls. This test drives those human-side
  # controls directly; the pinned property is unchanged: a consequential call,
  # once the user has confirmed it, is allowed to run.
  @tag :audit
  test "G1: ComputerUseGate lets a confirmed consequential call proceed" do
    install_guide_block!(guide_block!("computer_use_gate"), "guide_computer_gate")

    # The human switches machine control on (in the app: `/computer on`).
    gate = Catalyst.Ext.ComputerUseGate
    assert :ok = apply(gate, :enable, [])

    risky = %{
      name: "applescript",
      args: %{"script" => ~s(do shell script "sudo softwareupdate -l")},
      call_id: "audit",
      cwd: File.cwd!(),
      assistant: nil
    }

    assert {:block, reason} = Catalyst.Hooks.before_tool_call(risky)
    assert reason =~ "confirm"

    # The human confirms the pending consequential call (`/computer confirm`).
    assert :ok = apply(gate, :confirm_next, [])

    refute match?({:block, _}, Catalyst.Hooks.before_tool_call(risky)),
           "a consequential call stays blocked after the user confirmed it"

    # One confirmation covers exactly one call: the next one re-blocks.
    assert {:block, _reason} = Catalyst.Hooks.before_tool_call(risky)
  end

  test "G1: WordCount installs verbatim and executes" do
    block = guide_block!("word_count")
    install_guide_block!(block, "guide_word_count")

    cwd = temp_workdir!("word_count")
    File.write!(Path.join(cwd, "words.txt"), "one two\nthree")

    result = execute_tool!("word_count", %{"path" => "words.txt"}, cwd)
    assert Content.text_of(result.content) =~ "3 words"
    assert result.details.count == 3

    remove_installed_fixture!("guide_word_count")
  end

  @tag skip: match?({:error, _reason}, Catalyst.Tools.Binaries.path(:rg))
  test "G1: CountMatches installs verbatim and executes against local data" do
    block = guide_block!("count_matches")
    install_guide_block!(block, "guide_count_matches")

    cwd = temp_workdir!("count_matches")
    File.write!(Path.join(cwd, "matches.txt"), "needle\nnope\nneedle\n")

    result =
      execute_tool!(
        "count_matches",
        %{"pattern" => "needle", "path" => "matches.txt"},
        cwd
      )

    assert Content.text_of(result.content) =~ "2 matches"
    remove_installed_fixture!("guide_count_matches")
  end

  test "G1: HttpGet installs verbatim and uses a supervised local Bandit endpoint" do
    server =
      start_supervised!(
        {Bandit,
         plug: {CatalystWeb.Flex.HttpPlug, "LOCAL GUIDE HTTP BODY"},
         scheme: :http,
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    block = guide_block!("http_get")
    install_guide_block!(block, "guide_http_get")

    result = execute_tool!("http_get", %{"url" => "http://127.0.0.1:#{port}/guide"}, File.cwd!())
    assert Content.text_of(result.content) =~ "HTTP 200"
    assert Content.text_of(result.content) =~ "LOCAL GUIDE HTTP BODY"

    remove_installed_fixture!("guide_http_get")
  end

  test "G1: WhiteBackground compiles and uses the writable asset workspace" do
    block = guide_block!("white_background")
    assert {:ok, _ast} = Code.string_to_quoted(block.source)

    assert block.source =~ "CatalystWeb.RuntimeAssets.ensure_workspace()"
    assert block.source =~ "Path.join(workspace, \"assets/css/app.css\")"

    purge_module(Catalyst.Ext.WhiteBackground)

    try do
      assert [{Catalyst.Ext.WhiteBackground, _binary}] = Code.compile_string(block.source)
      assert function_exported?(Catalyst.Ext.WhiteBackground, :setup, 1)
    after
      purge_module(Catalyst.Ext.WhiteBackground)
    end
  end

  test "G1: result helper snippet parses and its two shapes execute in a generated tool module" do
    block = guide_block!("result_helpers")
    assert {:ok, _ast} = Code.string_to_quoted(block.source)
    # function_exported?/3 is false for a not-yet-loaded module; load first so
    # this doesn't depend on which earlier test happened to touch Tool.
    assert Code.ensure_loaded?(Catalyst.Tools.Tool)
    assert function_exported?(Catalyst.Tools.Tool, :result, 1)
    assert function_exported?(Catalyst.Tools.Tool, :result, 2)

    purge_module(@result_probe)

    source = """
    defmodule #{@result_probe} do
      use Catalyst.Tools.Tool

      @impl true
      def name, do: "guide_result_probe"

      @impl true
      def description, do: "Validate the documented result helpers."

      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

      @impl true
      def execute(_args, _ctx), do: result("executed")

      def plain(text), do: result(text)
      def detailed(text, details), do: result(text, details)
    end
    """

    try do
      assert [{@result_probe, _binary}] = Code.compile_string(source)

      assert %{content: plain, details: %{}, terminate: false} =
               apply(@result_probe, :plain, ["plain"])

      assert Content.text_of(plain) == "plain"

      assert %{content: detailed, details: %{probe: true}, terminate: false} =
               apply(@result_probe, :detailed, ["detailed", %{probe: true}])

      assert Content.text_of(detailed) == "detailed"
    after
      purge_module(@result_probe)
    end
  end

  test "G1: the manual load snippet parses and every referenced remote call exists" do
    block = guide_block!("manual_load")
    assert {:ok, ast} = Code.string_to_quoted(block.source)

    calls = remote_calls(ast)

    assert {Catalyst.Extensions, :load_file, 1} in calls
    assert {Catalyst.Extensions, :names, 0} in calls
    assert {Path, :expand, 1} in calls

    Enum.each(calls, fn {module, function, arity} ->
      assert Code.ensure_loaded?(module)

      assert function_exported?(module, function, arity),
             "expected checked guide call #{inspect(module)}.#{function}/#{arity} to exist"
    end)
  end

  defp install_guide_block!(block, owner) do
    ExUnit.Callbacks.on_exit(fn -> remove_installed_fixture!(owner) end)

    case Installer.install(owner, block.source, "guide example") do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        flunk("guide block #{block.id} failed to install: #{Extensions.format_error(reason)}")
    end
  end

  defp execute_tool!(name, args, cwd) do
    {:ok, tool} = Extensions.fetch(name)
    apply(tool, :execute, [args, %{cwd: cwd, call_id: "guide", report: fn _ -> :ok end}])
  end

  defp guide_block!(id), do: Enum.find(Fixtures.guide_blocks(), &(&1.id == id))

  defp temp_workdir!(name) do
    path = Path.join(Application.fetch_env!(:catalyst, :home), name)
    File.mkdir_p!(path)
    path
  end

  defp remote_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [module_ast, function]}, _call_meta, args} = node, acc
        when is_atom(function) and is_list(args) ->
          module = Macro.expand(module_ast, __ENV__)
          {node, [{module, function, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(calls)
  end

  defp purge_module(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end
end
