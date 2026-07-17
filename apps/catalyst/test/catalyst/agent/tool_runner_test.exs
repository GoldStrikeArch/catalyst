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
end
