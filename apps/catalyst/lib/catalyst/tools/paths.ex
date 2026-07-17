defmodule Catalyst.Tools.Paths do
  @moduledoc "Path resolution for tools: expand `~`, resolve relative to the session cwd."

  @doc "Resolve a tool-supplied path against `cwd`, expanding a leading `~`."
  def resolve(path, cwd) when is_binary(path) do
    cond do
      path == "~" ->
        System.user_home!()

      String.starts_with?(path, "~/") ->
        Path.join(System.user_home!(), binary_slice(path, 2..-1//1))

      true ->
        Path.expand(path, cwd)
    end
  end
end
