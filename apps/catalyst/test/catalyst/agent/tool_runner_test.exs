defmodule Catalyst.Agent.ToolRunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 2]

  alias Catalyst.Agent.ToolRunner
  alias Catalyst.Content

  defmodule StrictTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "strict_tool"
    @impl true
    def description, do: "requires a string `text` argument"
    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    end

    @impl true
    def execute(%{"text" => "invalid-result"}, _ctx), do: result(<<"bad", 255, "text">>)

    def execute(%{"text" => t}, _ctx), do: result("got " <> t)
  end

  defmodule LooseSchemaTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "loose_tool"
    @impl true
    def description, do: "schema that does not resolve"
    @impl true
    def parameters, do: %{"type" => "object", "$ref" => "http://nope.invalid/schema.json"}
    @impl true
    def execute(_args, _ctx), do: result("ran anyway")
  end

  defmodule TerminatingTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "terminating_tool"
    @impl true
    def description, do: "returns terminate true"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx),
      do: %{content: Catalyst.Content.text("stop"), details: %{}, terminate: true}
  end

  # Implements the duck-typed tool functions but NOT execution_mode/0 (an
  # optional callback whose default is only injected by `use Catalyst.Tools.Tool`).
  defmodule NoModeTool do
    @behaviour Catalyst.Tools.Tool
    @impl true
    def name, do: "no_mode_tool"
    @impl true
    def description, do: "tool without execution_mode/0"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_args, _ctx) do
      %{content: [%Catalyst.Content.Text{text: "no mode"}], details: %{}, terminate: false}
    end
  end

  defmodule ContextProbeTool do
    use Catalyst.Tools.Tool

    @impl true
    def name, do: "context_probe"

    @impl true
    def description, do: "returns the ToolRunner-built inheritance context"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_args, context) do
      result("context", %{
        parent_session_id: context.parent_session_id,
        root_session_id: context.root_session_id,
        model: context.model,
        provider: context.provider,
        opts: context.opts,
        workflow: context.workflow,
        tool_source: context.tool_source,
        agent_depth: context.agent_depth
      })
    end
  end

  defmodule SequentialBlockingTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "sequential_blocking_tool"
    @impl true
    def description, do: "blocks until the runner deadline kills it"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execution_mode, do: :sequential
    @impl true
    def execute(_args, _ctx) do
      receive do
        :never_sent -> result("unexpected")
      end
    end
  end

  defmodule ModeProbeTool do
    use Catalyst.Tools.Tool

    @impl true
    def name, do: "mode_probe"

    @impl true
    def description, do: "reports when execution_mode metadata is evaluated"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execution_mode do
      case :persistent_term.get({__MODULE__, :observer}, nil) do
        pid when is_pid(pid) -> send(pid, :execution_mode_called)
        _none -> :ok
      end

      :parallel
    end

    @impl true
    def execute(_args, _ctx), do: result("mode probe ran")
  end

  defp run(tool_name, tools, args) do
    calls = [%{id: "c1", name: tool_name, arguments: args}]
    config = %{cwd: ".", tools: tools, opts: []}
    {[result], _terminate} = ToolRunner.run_batch(calls, config, fn _event -> :ok end)
    result
  end

  test "args missing a required property become an error tool-result, tool not run" do
    res = run("strict_tool", [StrictTool], %{})

    assert res.is_error
    assert Content.text_of(res.content) =~ "invalid arguments"
    assert Content.text_of(res.content) =~ "text"
  end

  test "args of the wrong type become an error tool-result" do
    res = run("strict_tool", [StrictTool], %{"text" => 42})

    assert res.is_error
    assert Content.text_of(res.content) =~ "invalid arguments"
  end

  test "valid args execute normally" do
    res = run("strict_tool", [StrictTool], %{"text" => "hi"})

    refute res.is_error
    assert Content.text_of(res.content) == "got hi"
  end

  test "ToolRunner builds the complete inheritable tool context" do
    model = %Catalyst.Model{id: "model", api: "api"}
    workflow = %{name: "review", module: Catalyst.Agent.Loop}
    # Live config.opts win over a stale inheritable_opts snapshot so mid-run
    # option changes (hooks) reach subsequently spawned children.
    opts = [
      session_id: "parent",
      reasoning_effort: "high",
      context_threshold: 100,
      get_steering: fn -> [] end
    ]

    config = %{
      cwd: ".",
      tools: [ContextProbeTool],
      opts: opts,
      parent_session_id: "parent",
      root_session_id: "root",
      model: model,
      provider: Catalyst.LLM.Faux,
      inheritable_opts: [reasoning_effort: "stale"],
      workflow: workflow,
      tool_source: :extensions,
      agent_depth: 2
    }

    calls = [%{id: "context-call", name: "context_probe", arguments: %{}}]
    {[result], false} = ToolRunner.run_batch(calls, config, fn _event -> :ok end)

    assert result.details == %{
             parent_session_id: "parent",
             root_session_id: "root",
             model: model,
             provider: Catalyst.LLM.Faux,
             opts: [reasoning_effort: "high", context_threshold: 100],
             workflow: workflow,
             tool_source: :extensions,
             agent_depth: 2
           }
  end

  test "tool text is valid UTF-8 before it enters the transcript" do
    res = run("strict_tool", [StrictTool], %{"text" => "invalid-result"})
    text = Content.text_of(res.content)

    assert String.valid?(text)
    assert text == "bad�text"
    assert is_binary(Jason.encode!(%{"text" => text}))
  end

  test "an unresolvable schema skips validation instead of blocking the tool" do
    res = run("loose_tool", [LooseSchemaTool], %{"whatever" => true})

    refute res.is_error
    assert Content.text_of(res.content) == "ran anyway"
  end

  test "a tool without execution_mode/0 runs (defaults to parallel) instead of crashing the batch" do
    res = run("no_mode_tool", [NoModeTool, StrictTool], %{})

    refute res.is_error
    assert Content.text_of(res.content) == "no mode"
  end

  test "execution mode is consumed from the validated entry, not called again by the runner" do
    key = {ModeProbeTool, :observer}
    :persistent_term.put(key, self())
    Catalyst.Tools.Registry.invalidate(ModeProbeTool)

    on_exit(fn ->
      :persistent_term.erase(key)
      Catalyst.Tools.Registry.invalidate(ModeProbeTool)
    end)

    res = run("mode_probe", [ModeProbeTool], %{})

    refute res.is_error
    assert Content.text_of(res.content) == "mode probe ran"
    assert_receive :execution_mode_called
    refute_receive :execution_mode_called, 0
  end

  test "sequential tools honor the per-tool timeout" do
    calls = [%{id: "c1", name: "sequential_blocking_tool", arguments: %{}}]
    config = %{cwd: ".", tools: [SequentialBlockingTool], opts: [], tool_timeout: 20}

    {[result], false} = ToolRunner.run_batch(calls, config, fn _event -> :ok end)

    assert result.is_error
    assert Content.text_of(result.content) =~ "timeout"
  end

  test "a batch terminates only when EVERY successful tool asks to terminate (PI parity)" do
    config = %{cwd: ".", tools: [TerminatingTool, StrictTool], opts: []}
    emit = fn _event -> :ok end

    mixed = [
      %{id: "c1", name: "terminating_tool", arguments: %{}},
      %{id: "c2", name: "strict_tool", arguments: %{"text" => "hi"}}
    ]

    {_results, terminate?} = ToolRunner.run_batch(mixed, config, emit)
    refute terminate?

    unanimous = [
      %{id: "c1", name: "terminating_tool", arguments: %{}},
      %{id: "c2", name: "terminating_tool", arguments: %{}}
    ]

    {_results, terminate?} = ToolRunner.run_batch(unanimous, config, emit)
    assert terminate?
  end

  test "validator exceptions become invalid arguments errors" do
    previous = Application.get_env(:catalyst, :tool_argument_validator)

    Application.put_env(:catalyst, :tool_argument_validator, fn _schema, _args ->
      raise "validator exploded"
    end)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:catalyst, :tool_argument_validator)
        validator -> Application.put_env(:catalyst, :tool_argument_validator, validator)
      end
    end)

    defmodule CrashingTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "crashing_tool"
      @impl true
      def description, do: "crashes during validation"
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}}

      @impl true
      def execute(_args, _ctx), do: result("ran")
    end

    res = run("crashing_tool", [CrashingTool], %{"a" => 1})
    assert res.is_error
    assert Content.text_of(res.content) =~ "invalid arguments"
    assert Content.text_of(res.content) =~ "validation"
  end

  test "a reloaded macro tool executes the generation matching its cached mode and schema" do
    module = Catalyst.Test.ToolRunnerPinnedEpochTool
    observer_key = {module, :observer}
    :persistent_term.put(observer_key, self())
    on_exit(fn -> unload_epoch_tool(module, observer_key) end)

    compile_epoch_tool(module, "pinned_epoch_tool", :parallel, :old, true)
    index = Catalyst.Tools.Registry.index([module])
    assert index["pinned_epoch_tool"].definition.execution_mode == :parallel

    compile_epoch_tool(module, "pinned_epoch_tool", :sequential, :new, true)

    assert {:ok, %{definition: %{execution_mode: :sequential}}} =
             Catalyst.Tools.Registry.cached_entry(module)

    calls = [
      %{id: "epoch", name: "pinned_epoch_tool", arguments: %{"old_arg" => "accepted"}}
    ]

    config = %{cwd: ".", tools: [module], opts: []}

    {[result], false} = ToolRunner.run_batch_with_index(calls, index, config, fn _ -> :ok end)

    refute result.is_error
    assert Content.text_of(result.content) == "old"
    assert_receive {:executed, :old}
    refute_receive {:executed, :new}, 0
  end

  test "a stale legacy tool entry fails the whole batch before new code executes" do
    module = Catalyst.Test.ToolRunnerLegacyEpochTool
    observer_key = {module, :observer}
    :persistent_term.put(observer_key, self())
    on_exit(fn -> unload_epoch_tool(module, observer_key) end)

    compile_epoch_tool(module, "legacy_epoch_tool", :parallel, :old, false)
    index = Catalyst.Tools.Registry.index([module])
    compile_epoch_tool(module, "legacy_epoch_tool", :sequential, :new, false)

    calls = [
      %{id: "epoch", name: "legacy_epoch_tool", arguments: %{"old_arg" => "accepted"}}
    ]

    config = %{cwd: ".", tools: [module], opts: []}

    {[result], false} = ToolRunner.run_batch_with_index(calls, index, config, fn _ -> :ok end)

    assert result.is_error
    assert result.details.validation == :stale_tool_entry
    assert Content.text_of(result.content) =~ "stale_tool_entry"
    refute_receive {:executed, :new}, 0
  end

  defp compile_epoch_tool(module, name, mode, version, use_macro?) do
    use_tool = if use_macro?, do: "use Catalyst.Tools.Tool", else: ""
    required = "#{version}_arg"

    source = """
    defmodule #{inspect(module)} do
      #{use_tool}
      def name, do: #{inspect(name)}
      def description, do: "generation probe"
      def parameters do
        %{
          "type" => "object",
          "properties" => %{#{inspect(required)} => %{"type" => "string"}},
          "required" => [#{inspect(required)}]
        }
      end
      def execution_mode, do: #{inspect(mode)}
      def execute(_args, _context) do
        case :persistent_term.get({__MODULE__, :observer}, nil) do
          pid when is_pid(pid) -> send(pid, {:executed, #{inspect(version)}})
          _none -> :ok
        end

        %{content: Catalyst.Content.text(#{inspect(to_string(version))}), details: %{}, terminate: false}
      end
    end
    """

    {_compiled, _stderr} = with_io(:stderr, fn -> Code.compile_string(source) end)
    :ok
  end

  defp unload_epoch_tool(module, observer_key) do
    :persistent_term.erase(observer_key)
    Catalyst.Tools.Registry.invalidate(module)
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end
