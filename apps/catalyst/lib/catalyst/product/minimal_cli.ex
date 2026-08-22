defmodule Catalyst.Product.MinimalCLI do
  @moduledoc "Minimal headless Catalyst product composition."

  @behaviour Catalyst.Product

  @tools [
    Catalyst.Tools.Read,
    Catalyst.Tools.Ls,
    Catalyst.Tools.Ripgrep,
    Catalyst.Tools.Fd,
    Catalyst.Tools.Bash,
    Catalyst.Tools.Write,
    Catalyst.Tools.Edit
  ]

  @doc "Return the stable minimal CLI product identifier."
  @impl true
  def id, do: "minimal-cli"

  @doc "Return the minimal CLI tool set."
  @impl true
  def tools, do: @tools

  @doc "Return the minimal headless initial composition."
  @impl true
  def spec do
    Catalyst.Product.Spec.new!(%{
      id: id(),
      packs: [
        "catalyst.meta-runtime",
        "catalyst.agent.default",
        "catalyst.provider.faux",
        "catalyst.provider.openai",
        "catalyst.tools.coding"
      ],
      tools: @tools,
      hosts: [:cli]
    })
  end
end
