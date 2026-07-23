defmodule Catalyst.Tools.SelfModReport do
  @moduledoc """
  Shared result-text helpers for the self-modification tools
  (`develop_tool`, `install_extension`, `reload_extensions`,
  `rollback_extension`): the trailing warning sentence and the
  failed-to-load section listing `{path, reason}` pairs.
  """

  alias Catalyst.Extensions

  @doc "Append ` Warning: …` to a result sentence, or return it unchanged for `nil`."
  @spec append_warning(String.t(), String.t() | nil) :: String.t()
  def append_warning(text, nil), do: text
  def append_warning(text, warning), do: text <> " Warning: #{warning}"

  @doc """
  Render the failed-files section for a load result (empty string when nothing
  failed). `label` names the failure, e.g. `"FAILED to load"`.
  """
  @spec failures_section([{String.t(), term()}], String.t()) :: String.t()
  def failures_section(failed, label \\ "FAILED to load")
  def failures_section([], _label), do: ""

  def failures_section(failed, label),
    do: "\n#{length(failed)} file(s) #{label}:\n" <> format_failures(failed)

  @doc "Render `{path, reason}` failure pairs as indented bullet lines."
  @spec format_failures([{String.t(), term()}]) :: String.t()
  def format_failures(failed) do
    Enum.map_join(failed, "\n", fn {path, reason} ->
      "  - #{path}: #{Extensions.format_error(reason)}"
    end)
  end
end
