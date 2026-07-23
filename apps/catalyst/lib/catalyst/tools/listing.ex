defmodule Catalyst.Tools.Listing do
  @moduledoc """
  Shared output tail for the list-producing tools (`ls`, `find`, `grep`,
  `ast_grep`).

  Applies the result-limit marker plus head truncation with its visible notice
  (`Catalyst.Tools.Truncate.listing/2`), appends the shared "output capped"
  notice when the child's output hit `:max_output_bytes`
  (`Catalyst.Tools.Exec.append_capped_notice/4`), and produces the uniform
  details keys every listing tool reports:
  `:count`, `:limit_reached`, `:output_capped`, `:truncation`.
  """

  alias Catalyst.Tools.{Exec, Truncate}

  @default_capped_hint "narrow the pattern or path"

  # Shared child-stdout cap for listing tools whose underlying binary has no
  # output bound of its own (fd, ripgrep, ast-grep).
  @max_output_bytes 8 * 1024 * 1024

  @doc "The shared byte cap applied to a listing child's stdout (8 MiB)."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc """
  Decode one-JSON-object-per-line child output (`rg --json`,
  `ast-grep --json=stream`).

  Each decoded object is mapped through `fun`, which returns zero or more
  rendered entries; lines that fail to parse (e.g. stderr noise merged into
  stdout) are dropped.
  """
  @spec decode_json_lines(String.t(), (map() -> [entry])) :: [entry] when entry: var
  def decode_json_lines(out, fun) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> fun.(decoded)
        {:error, _reason} -> []
      end
    end)
  end

  @type details :: %{
          count: non_neg_integer(),
          limit_reached: boolean(),
          output_capped: boolean(),
          truncation: Truncate.info()
        }

  @doc """
  Render a listing tool's joined output into `{text, details}`.

  Options:

    * `:count` (required) — entries/matches actually shown
    * `:noun` (required) — `"entries"`, `"results"`, `"matches"`
    * `:limited?` — the result limit was hit (default `false`)
    * `:limit` — the limit that applied (meaningful when `:limited?`)
    * `:total` — true total, or `:unknown` when only bounded child output was
      seen (default `:unknown`)
    * `:capped?` — the child's output hit its byte cap (default `false`)
    * `:max_output_bytes` — the cap, for the notice (required when `:capped?`)
    * `:capped_hint` — remedy shown in the capped notice
      (default `#{inspect(@default_capped_hint)}`)
    * `:note` — extra trailing note appended after all notices (e.g. fd's
      unsearchable-path note)
  """
  @spec render(String.t(), keyword()) :: {String.t(), details()}
  def render(text, opts) when is_binary(text) and is_list(opts) do
    limited? = Keyword.get(opts, :limited?, false)
    capped? = Keyword.get(opts, :capped?, false)

    {body, info} =
      Truncate.listing(text,
        limited?: limited?,
        limit: Keyword.get(opts, :limit, 0),
        total: Keyword.get(opts, :total, :unknown),
        noun: Keyword.fetch!(opts, :noun)
      )

    body =
      body
      |> append_capped(capped?, opts)
      |> append_note(Keyword.get(opts, :note))

    {body,
     %{
       count: Keyword.fetch!(opts, :count),
       limit_reached: limited?,
       output_capped: capped?,
       truncation: info
     }}
  end

  defp append_capped(body, false = _capped?, _opts), do: body

  defp append_capped(body, true = _capped?, opts) do
    Exec.append_capped_notice(
      body,
      true,
      Keyword.fetch!(opts, :max_output_bytes),
      Keyword.get(opts, :capped_hint, @default_capped_hint)
    )
  end

  defp append_note(body, nil), do: body
  defp append_note(body, note), do: body <> "\n" <> note
end
