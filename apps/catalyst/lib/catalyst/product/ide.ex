defmodule Catalyst.Product.IDE do
  @moduledoc "IDE-oriented Catalyst product composition."

  @behaviour Catalyst.Product

  @doc "Return the stable IDE product identifier."
  @impl true
  def id, do: "ide"

  @doc "Return the IDE coding tool set."
  @impl true
  def tools, do: Catalyst.Product.Default.tools()

  @doc "Return the IDE-oriented initial composition."
  @impl true
  def spec do
    default = Catalyst.Product.Default.spec()

    Catalyst.Product.Spec.new!(%{
      id: id(),
      packs: default.packs ++ ["catalyst.ide.core"],
      tools: default.tools,
      hosts: [:web, :desktop]
    })
  end
end
