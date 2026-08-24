defmodule Catalyst.Workflow.ComputerUseGateTest do
  # async: false — flips the shared :catalyst computer-use app env.
  use ExUnit.Case, async: false

  alias Catalyst.Extensions
  alias Catalyst.Session.RunConfig
  alias Catalyst.Tools.Registry, as: ToolRegistry
  alias Catalyst.Workflow.Support

  defmodule PlainTool do
    @moduledoc false
    use Catalyst.Tools.Tool

    @impl true
    def name, do: "computer_gate_plain_tool"
    @impl true
    def description, do: "requires no capability"
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end

  defmodule GatedTool do
    @moduledoc false
    use Catalyst.Tools.Tool

    @impl true
    def name, do: "computer_gate_gated_tool"
    @impl true
    def description, do: "requires the computer_use capability"
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def capabilities, do: [:computer_use]
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end

  setup do
    previous = Application.fetch_env(:catalyst, :computer_backend_available)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst, :computer_backend_available, value)
        :error -> Application.delete_env(:catalyst, :computer_backend_available)
      end
    end)

    :ok
  end

  defp with_backend(available?),
    do: Application.put_env(:catalyst, :computer_backend_available, available?)

  defp config(opts),
    do: %{tools: [PlainTool, GatedTool], tool_source: [PlainTool, GatedTool], opts: opts}

  test "a gated tool is advertised only when the session grants the capability" do
    with_backend(true)

    assert Support.resolve_tools(config([])) == [PlainTool]
    assert Support.resolve_tools(config(computer_use: false)) == [PlainTool]
    assert Support.resolve_tools(config(computer_use: true)) == [PlainTool, GatedTool]
  end

  test "the grant also reads a top-level config key, like every other option" do
    with_backend(true)

    granted = config([]) |> Map.put(:computer_use, true)
    assert Support.resolve_tools(granted) == [PlainTool, GatedTool]
  end

  test "an explicit tools: list cannot re-add a gated tool" do
    with_backend(true)

    # The turn config names the gated tool directly — the filter still runs
    # last, after every tool source is resolved.
    assert Support.resolve_turn_tools(config([])).tools == [PlainTool]
    refute Map.has_key?(Support.resolve_turn_tools(config([])).tool_index, GatedTool.name())
  end

  test "an ungranted capability keeps the tool out of the provider tool set" do
    with_backend(true)

    names =
      config([])
      |> Support.resolve_turn_tools()
      |> Map.fetch!(:tool_index)
      |> ToolRegistry.to_provider_tools()
      |> Enum.map(& &1.name)

    assert names == [PlainTool.name()]
  end

  test "an unavailable backend denies the grant even when the session asks for it" do
    with_backend(false)

    assert Support.resolve_tools(config(computer_use: true)) == [PlainTool]
    assert Support.granted_capabilities(config(computer_use: true)) |> Enum.empty?()
  end

  test "an extension-registered tool declaring the capability is filtered too" do
    with_backend(true)
    owner = "computer_use_gate_#{System.unique_integer([:positive])}"
    on_exit(fn -> Extensions.uninstall(owner) end)

    assert {:ok, _module} = Extensions.register_tool(GatedTool, owner: owner)
    assert GatedTool in Extensions.tools()

    live = %{tools: :extensions, tool_source: :extensions, opts: []}
    refute GatedTool in Support.resolve_tools(live)

    granted = %{live | opts: [computer_use: true]}
    assert GatedTool in Support.resolve_tools(granted)
  end

  test "a child session spawned from a granted parent does not inherit the grant" do
    with_backend(true)

    parent_opts = [computer_use: true, reasoning_effort: "high"]
    child_opts = RunConfig.inheritable_opts(parent_opts)

    refute Keyword.has_key?(child_opts, :computer_use)
    assert child_opts == [reasoning_effort: "high"]

    # The gate agrees: the child's resolved tool set has no gated tool.
    assert Support.resolve_tools(config(parent_opts)) == [PlainTool, GatedTool]
    assert Support.resolve_tools(config(child_opts)) == [PlainTool]
  end

  test "the application default decides only when the session says nothing" do
    with_backend(true)
    previous = Application.fetch_env(:catalyst, :computer_use)
    Application.put_env(:catalyst, :computer_use, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst, :computer_use, value)
        :error -> Application.delete_env(:catalyst, :computer_use)
      end
    end)

    assert Support.resolve_tools(config([])) == [PlainTool, GatedTool]
    assert Support.resolve_tools(config(computer_use: false)) == [PlainTool]
  end

  test "a global computer_use: true default never grants a child session" do
    with_backend(true)
    previous = Application.fetch_env(:catalyst, :computer_use)
    Application.put_env(:catalyst, :computer_use, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst, :computer_use, value)
        :error -> Application.delete_env(:catalyst, :computer_use)
      end
    end)

    # A child run carries agent_depth > 0 and (via inheritable_opts/1) no
    # :computer_use opt of its own. The app-env fallback must not answer for
    # it — otherwise the global override silently re-grants every subagent.
    child_opts = RunConfig.inheritable_opts(computer_use: true)
    refute Keyword.has_key?(child_opts, :computer_use)

    assert Support.resolve_tools(config([])) == [PlainTool, GatedTool]
    assert Support.resolve_tools(config([{:agent_depth, 1} | child_opts])) == [PlainTool]

    # An explicit per-child grant made by operator code still works.
    assert Support.resolve_tools(config(agent_depth: 1, computer_use: true)) ==
             [PlainTool, GatedTool]
  end

  test "the bundled app-layer tools are gated, and fetch is not" do
    with_backend(true)

    gated = [
      Catalyst.Tools.AppleScript,
      Catalyst.Tools.OpenApp,
      Catalyst.Tools.ListApps,
      Catalyst.Tools.Clipboard
    ]

    bundled = Extensions.tools()
    builtin_config = %{tools: bundled, tool_source: bundled, opts: []}

    ungranted = Support.resolve_tools(builtin_config)
    granted = Support.resolve_tools(%{builtin_config | opts: [computer_use: true]})

    # `fetch` is curl-equivalent: it adds nothing `bash` already grants, so
    # gating it would cost tokens without buying safety.
    assert Catalyst.Tools.Fetch in ungranted
    assert Catalyst.Tools.Fetch in granted

    assert Enum.all?(gated, &(&1 not in ungranted))
    assert Enum.all?(gated, &(&1 in granted))
  end
end
