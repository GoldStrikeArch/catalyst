defmodule Catalyst.Flex.Fixtures do
  @moduledoc """
  Source-fixture and checked-guide helpers shared by the flexibility suite.

  Extension fixtures are data only: they are read from `test/fixtures/extensions`
  and enter the VM exclusively through the production extension loader.
  """

  @guide_block ~r/^[ \t]*```elixir[ \t]*\n(.*?)^[ \t]*```[ \t]*$/ms

  @type guide_block :: %{
          id: String.t(),
          source: String.t(),
          fingerprint: String.t()
        }

  @doc "Absolute path to a source-only extension fixture."
  @spec extension_path(String.t()) :: Path.t()
  def extension_path(name) do
    Path.expand("../../fixtures/extensions/#{normalize_name(name)}.ex", __DIR__)
  end

  @doc "Read a source-only extension fixture."
  @spec extension_source!(String.t()) :: String.t()
  def extension_source!(name), do: name |> extension_path() |> File.read!()

  @doc "Extract and classify every Elixir block from the bundled user guide."
  @spec guide_blocks() :: [guide_block()]
  def guide_blocks do
    guide_path()
    |> File.read!()
    |> then(&Regex.scan(@guide_block, &1, capture: :all_but_first))
    |> Enum.map(fn [source] ->
      %{id: guide_id(source), source: source, fingerprint: fingerprint(source)}
    end)
  end

  @doc "SHA-256 fingerprint used by the checked guide manifest."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  @doc "Path of the guide bundled into the core application."
  @spec guide_path() :: Path.t()
  def guide_path, do: Path.join(to_string(:code.priv_dir(:catalyst)), "guide.md")

  defp guide_id(source) do
    cond do
      source =~ "Catalyst.Ext.WhiteBackground" -> "white_background"
      source =~ "Catalyst.Ext.WordCount" -> "word_count"
      source =~ "result(text)" -> "result_helpers"
      source =~ "Catalyst.Ext.CountMatches" -> "count_matches"
      source =~ "Catalyst.Ext.HttpGet" -> "http_get"
      source =~ "Catalyst.Ext.ComputerUseGate" -> "computer_use_gate"
      source =~ "Catalyst.Extensions.load_file" -> "manual_load"
      true -> raise "unclassified Elixir guide block:\n#{source}"
    end
  end

  defp normalize_name(name), do: String.replace_suffix(name, ".ex", "")
end
