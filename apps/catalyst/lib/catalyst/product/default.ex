defmodule Catalyst.Product.Default do
  @moduledoc "Default coding-agent product composition."

  @behaviour Catalyst.Product

  alias Catalyst.Tools.{
    AppleScript,
    AstGrep,
    Bash,
    Clipboard,
    Computer,
    DevelopTool,
    Edit,
    Fd,
    Fetch,
    InstallExtension,
    ListAgents,
    ListApps,
    Ls,
    OpenApp,
    Read,
    ReadLog,
    ReloadTool,
    Ripgrep,
    RollbackTool,
    RuntimeGraph,
    Sd,
    ShellSession,
    SpawnAgent,
    Write
  }

  @tools [
    Read,
    Ls,
    Ripgrep,
    Fd,
    Bash,
    Write,
    Edit,
    Sd,
    AstGrep,
    Computer,
    DevelopTool,
    InstallExtension,
    ReloadTool,
    RollbackTool,
    ReadLog,
    RuntimeGraph,
    ListAgents,
    SpawnAgent,
    Fetch,
    AppleScript,
    OpenApp,
    ListApps,
    Clipboard,
    ShellSession
  ]

  @impl true
  def id, do: "coding-agent"

  @doc "Return the coding-agent initial composition."
  @spec spec() :: Catalyst.Product.Spec.t()
  @impl true
  def spec do
    Catalyst.Product.Spec.new!(%{
      id: id(),
      packs: [
        "catalyst.meta-runtime",
        "catalyst.agent.default",
        "catalyst.workbench.default",
        "catalyst.provider.faux",
        "catalyst.provider.openai",
        "catalyst.provider.grok",
        "catalyst.tools.coding",
        "catalyst.tools.computer",
        "catalyst.tools.shell",
        "catalyst.tools.self-development"
      ],
      tools: @tools,
      hosts: [:web, :desktop]
    })
  end

  @doc "Return the coding-agent tools installed by this product."
  @spec tools() :: [module()]
  @impl true
  def tools, do: @tools
end
