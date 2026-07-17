defmodule Catalyst.Tools.Paths do
  @moduledoc """
  Path resolution for tools: expand a leading `~` and resolve relative paths
  against the session cwd (both handled by `Path.expand/2`).

  Deliberately **no workspace confinement**: absolute paths and `..` resolve
  anywhere on the filesystem. This is consistent with the self-modification
  design — the agent may read and edit its own installation outside the
  workspace.
  """

  @doc "Resolve a tool-supplied path against `cwd`, expanding a leading `~`."
  @spec resolve(String.t(), String.t()) :: String.t()
  def resolve(path, cwd) when is_binary(path), do: Path.expand(path, cwd)
end
