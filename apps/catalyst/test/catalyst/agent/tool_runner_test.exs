defmodule Catalyst.Agent.ToolRunnerTest do
  use ExUnit.Case, async: true

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

  test "resolved schemas are cached per MODULE (a changed schema replaces, not accumulates)" do
    key = {ToolRunner, StrictTool}
    on_exit(fn -> :persistent_term.erase(key) end)

    run("strict_tool", [StrictTool], %{"text" => "hi"})

    params = StrictTool.parameters()
    assert {^params, {:ok, %ExJsonSchema.Schema.Root{}}} = :persistent_term.get(key)

    # The cache-hit path still validates and still rejects bad args.
    assert run("strict_tool", [StrictTool], %{"text" => "again"}).is_error == false
    assert run("strict_tool", [StrictTool], %{}).is_error

    # A stale entry (hot-reloaded tool whose schema changed) is REPLACED in
    # place — the module keeps exactly one entry, so reload churn can't leak.
    :persistent_term.put(key, {%{"type" => "array"}, :error})
    assert run("strict_tool", [StrictTool], %{}).is_error
    assert {^params, {:ok, %ExJsonSchema.Schema.Root{}}} = :persistent_term.get(key)
  end
end
