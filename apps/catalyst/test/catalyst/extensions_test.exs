defmodule Catalyst.ExtensionsTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Agent.Loop
  alias Catalyst.Extensions
  alias Catalyst.Tools.DevelopTool

  setup do
    File.mkdir_p!(Extensions.dir())
    on_exit(fn -> File.rm_rf!(Extensions.dir()) end)
    :ok
  end

  @shout_source ~S'''
  defmodule Catalyst.Ext.ShoutTest do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "shout_test"
    @impl true
    def description, do: "Uppercases the given text."
    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
    end
    @impl true
    def execute(%{"text" => t}, _ctx), do: result(String.upcase(t))
  end
  '''

  test "the built-ins (incl. develop_tool) are seeded" do
    assert Extensions.fetch("read")
    assert Extensions.fetch("develop_tool") == DevelopTool
    assert "ast_grep" in Extensions.names()
  end

  test "develop_tool compiles and loads a new tool at runtime (no restart)" do
    ctx = %{cwd: System.tmp_dir!(), call_id: "t", report: fn _ -> :ok end}

    capture_log(fn ->
      DevelopTool.execute(%{"name" => "shout_test", "source" => @shout_source}, ctx)
    end)

    # The freshly written module is now a live, registered tool.
    mod = Extensions.fetch("shout_test")
    assert mod == Catalyst.Ext.ShoutTest
    assert mod.execute(%{"text" => "hi"}, ctx).content |> hd() |> Map.get(:text) == "HI"
  end

  test "the agent can self-develop a tool and use it in the same run" do
    tmp = Path.join(System.tmp_dir!(), "selfdev_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    model = %Model{id: "faux", api: "faux", provider: "faux"}

    # Turn 1: write the tool. Turn 2: call it (now resolvable). Turn 3: done.
    script = [
      {:tool, "develop_tool", %{"name" => "shout_run", "source" => shout_run_source()}},
      {:tool, "shout_run", %{"text" => "it works"}},
      {:text, "self-extended!"}
    ]

    config = %{
      provider: Catalyst.LLM.Faux,
      model: model,
      cwd: tmp,
      # :extensions → the loop resolves the LIVE tool set every turn
      tools: :extensions,
      opts: [script: script]
    }

    {:ok, collector} = Agent.start_link(fn -> [] end)
    emit = fn ev -> Agent.update(collector, &[ev | &1]) end

    {:ok, messages, _ctx} =
      Loop.run([Message.user("extend yourself")], %{system_prompt: nil, messages: []}, config, emit)

    Agent.stop(collector)

    tool_results = Enum.filter(messages, &match?(%Message.ToolResult{}, &1))
    shout_result = Enum.find(tool_results, &(&1.tool_name == "shout_run"))

    assert shout_result, "expected the self-created tool to have been called"
    assert Content.text_of(shout_result.content) == "IT WORKS"
    assert Content.text_of(List.last(messages).content) == "self-extended!"
  end

  defp shout_run_source do
    ~S'''
    defmodule Catalyst.Ext.ShoutRun do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "shout_run"
      @impl true
      def description, do: "Uppercases text."
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
      @impl true
      def execute(%{"text" => t}, _ctx), do: result(String.upcase(t))
    end
    '''
  end
end
