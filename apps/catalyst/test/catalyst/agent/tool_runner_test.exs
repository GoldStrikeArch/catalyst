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

  test "resolved schemas are cached in :persistent_term keyed by the parameters hash" do
    run("strict_tool", [StrictTool], %{"text" => "hi"})

    key = {ToolRunner, StrictTool, :erlang.phash2(StrictTool.parameters())}
    assert {:ok, %ExJsonSchema.Schema.Root{}} = :persistent_term.get(key)

    # The cache-hit path still validates and still rejects bad args.
    assert run("strict_tool", [StrictTool], %{"text" => "again"}).is_error == false
    assert run("strict_tool", [StrictTool], %{}).is_error
  end
end
