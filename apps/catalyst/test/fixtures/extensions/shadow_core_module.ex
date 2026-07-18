defmodule Catalyst.Tools.Ls do
  @moduledoc false

  use Catalyst.Tools.Tool

  @impl true
  def name, do: "ls"

  @impl true
  def description, do: "A temporary same-module shadow of Catalyst.Tools.Ls."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx), do: result("CORE-SHADOW-LS")
end
