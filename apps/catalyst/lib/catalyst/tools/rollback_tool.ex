defmodule Catalyst.Tools.RollbackTool do
  @moduledoc """
  Undo the most recent extension change that hasn't already been rolled back
  (git revert of the newest non-reverted commit) and reload — the recovery path
  after a bad self-modification. Repeated calls walk backwards through the
  change history (LIFO); they never re-apply a reverted change by reverting the
  revert. An optional `name` scopes the walk to one extension's file. Requires
  git in the extensions dir.
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Extensions

  import Catalyst.Tools.SelfModReport, only: [failures_section: 2]

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "rollback_extension"

  @impl true
  def description,
    do:
      "Undo the most recent extension change that hasn't already been rolled back " <>
        "(git revert) and reload. Calling it again rolls back the next older change " <>
        "— it never re-applies a change you already rolled back. Pass `name` to " <>
        "scope the rollback to one extension. Use to recover from a bad " <>
        "self-modification."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" =>
            "Extension owner id (source file basename without .ex). When given, only " <>
              "that extension's most recent non-reverted change is undone; when " <>
              "omitted, the most recent change across all extensions."
        }
      },
      "required" => []
    }
  end

  # Presentation only — the lock → revert → reload orchestration is the
  # tagged `Extensions.rollback/1` domain operation.
  @impl true
  def execute(args, _ctx) do
    name = normalize_name(args["name"])

    case Extensions.rollback(name) do
      {:ok, %{loaded: loaded, failed: failed}} ->
        result(
          "Rolled back the most recent non-reverted extension change#{scope_label(name)} " <>
            "and reloaded #{length(loaded)} file(s)." <>
            failures_section(failed, "FAILED to load after the revert"),
          %{files: length(loaded), failed: length(failed)}
        )

      {:error, :nothing_to_rollback} ->
        raise "Rollback failed: every extension change in recent history has already " <>
                "been rolled back — there is nothing left to revert."

      {:error, :no_file} ->
        raise "Rollback failed: no extension source file found for that name. " <>
                "Loaded extensions: #{Enum.join(loaded_owners(), ", ")}"

      {:error, {:reload_failed, reason}} ->
        raise "Rollback applied, but the reload failed: #{Extensions.format_error(reason)}"

      {:error, reason} ->
        # Includes "nothing to revert" cases (e.g. only the empty init commit
        # exists): git's message is surfaced so the agent can tell them apart.
        raise "Rollback failed: #{Extensions.format_error(reason)}"
    end
  end

  defp normalize_name(name) when is_binary(name) and name != "", do: name
  defp normalize_name(_none), do: nil

  defp scope_label(name) when is_binary(name) and name != "", do: " to #{name}"
  defp scope_label(_none), do: ""

  defp loaded_owners do
    case Enum.map(Extensions.list_loaded(), & &1.owner) do
      [] -> ["(none)"]
      owners -> owners
    end
  end
end
