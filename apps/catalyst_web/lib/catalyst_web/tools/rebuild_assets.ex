defmodule CatalystWeb.Tools.RebuildAssets do
  @moduledoc """
  Self-modification tool: rebuild the front-end assets (tailwind CSS + esbuild JS)
  and reload connected windows. Use after changing styles or adding a JS hook.
  Requires the bundled toolchain.
  """
  use Catalyst.Tools.Tool

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "rebuild_assets"

  @impl true
  def description,
    do:
      "Rebuild the UI assets (CSS via tailwind, JS via esbuild) and reload open windows. " <>
        "Use after changing CSS classes that weren't precompiled or after adding a JS hook."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    case CatalystWeb.Assets.rebuild() do
      :ok -> result("Rebuilt assets and requested a UI reload.")
      {:error, reason} -> raise "Asset rebuild failed: #{inspect(reason)}"
    end
  end
end
