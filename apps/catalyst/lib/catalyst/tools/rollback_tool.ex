defmodule Catalyst.Tools.RollbackTool do
  @moduledoc """
  Undo the most recent extension change (git revert) and reload — the recovery
  path after a bad self-modification. Requires git in the extensions dir.
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Extensions
  alias Catalyst.Extensions.Versioning

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "rollback_extension"

  @impl true
  def description,
    do:
      "Undo the most recent extension change (git revert HEAD) and reload. Use to recover from a bad self-modification."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    case Versioning.rollback(Extensions.dir()) do
      :ok ->
        Extensions.load_all()
        result("Rolled back the last extension change and reloaded.")

      {:error, reason} ->
        raise "Rollback failed: #{inspect(reason)}"
    end
  end
end
