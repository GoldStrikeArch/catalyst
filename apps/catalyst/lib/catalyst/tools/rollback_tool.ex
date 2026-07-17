defmodule Catalyst.Tools.RollbackTool do
  @moduledoc """
  Undo the most recent extension change that hasn't already been rolled back
  (git revert of the newest non-reverted commit) and reload — the recovery path
  after a bad self-modification. Repeated calls walk backwards through the
  change history (LIFO); they never re-apply a reverted change by reverting the
  revert. Requires git in the extensions dir.
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
      "Undo the most recent extension change that hasn't already been rolled back " <>
        "(git revert) and reload. Calling it again rolls back the next older change " <>
        "— it never re-applies a change you already rolled back. Use to recover " <>
        "from a bad self-modification."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    case Versioning.rollback(Extensions.dir()) do
      :ok ->
        {:ok, %{loaded: loaded, failed: failed}} = Extensions.load_all()

        result(
          "Rolled back the most recent non-reverted extension change and reloaded " <>
            "#{length(loaded)} file(s)." <> failures_section(failed),
          %{files: length(loaded), failed: length(failed)}
        )

      {:error, :nothing_to_rollback} ->
        raise "Rollback failed: every extension change in recent history has already " <>
                "been rolled back — there is nothing left to revert."

      {:error, reason} ->
        # Includes "nothing to revert" cases (e.g. only the empty init commit
        # exists): git's message is surfaced so the agent can tell them apart.
        raise "Rollback failed: #{inspect(reason)}"
    end
  end

  defp failures_section([]), do: ""

  defp failures_section(failed) do
    "\n#{length(failed)} file(s) FAILED to load after the revert:\n" <>
      Enum.map_join(failed, "\n", fn {path, reason} -> "  - #{path}: #{inspect(reason)}" end)
  end
end
