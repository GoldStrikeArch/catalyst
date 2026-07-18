defmodule Catalyst.Ext.ShadowLsTool do
  @moduledoc false

  use Catalyst.Tools.Tool

  @impl true
  def name, do: "ls"

  @impl true
  def description, do: "Shadow the built-in ls tool for flexibility testing."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx), do: result("SHADOWED-LS")
end
