defmodule Catalyst.Tools.Fd do
  @moduledoc "Filename search via fd (`find` tool). Glob mode; respects .gitignore."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Paths, Truncate}

  @default_limit 1000

  @impl true
  def name, do: "find"

  @impl true
  def description,
    do: "Find files by glob pattern with fd (respects .gitignore). Returns matching paths."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Glob pattern, e.g. '*.ex' or '**/*.json'"
        },
        "path" => %{"type" => "string", "description" => "Directory to search (default: cwd)"},
        "limit" => %{"type" => "integer", "description" => "Max results (default: 1000)"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, ctx) do
    fd = Binaries.path!(:fd)
    target = Paths.resolve(args["path"] || ".", ctx.cwd)
    limit = args["limit"] || @default_limit

    # `--` keeps a leading-dash pattern from being parsed as fd flags (e.g. -x = exec).
    # --exclude .git: --hidden would otherwise surface .git internals.
    # --max-results limit+1: bounds child output while keeping limited? detection.
    fd_args =
      [
        "--color",
        "never",
        "--hidden",
        "--exclude",
        ".git",
        "--max-results",
        Integer.to_string(limit + 1),
        "--glob",
        "--",
        pattern,
        target
      ]

    case Exec.collect(fd, fd_args, cwd: ctx.cwd) do
      # fd exits 0 on a clean run (even with zero matches) — unlike rg,
      # where 1 means "no matches".
      {:ok, %{out: out, status: 0}} ->
        respond(String.split(out, "\n", trim: true), limit, nil)

      # fd exits 1 when ANY error occurred (missing/unreadable search path),
      # possibly alongside real results. The errors are stderr "[fd error]"
      # lines merged into stdout by Exec.collect's :stderr_to_stdout — drop
      # them so they aren't returned to the model as file paths, salvage the
      # real paths with a note, and only raise when nothing was found at all.
      {:ok, %{out: out, status: 1}} ->
        {error_lines, results} = partition_errors(out)

        case results do
          [] ->
            raise "fd error (status 1): #{String.slice(Enum.join(error_lines, "\n"), 0, 200)}"

          _ ->
            respond(results, limit, error_note(error_lines))
        end

      {:ok, %{out: out, status: status}} ->
        raise "fd error (status #{status}): #{String.slice(out, 0, 200)}"

      {:error, reason} ->
        raise "fd failed: #{inspect(reason)}"
    end
  end

  @doc false
  # Public for tests (a mixed errors+results run isn't reproducible with a
  # single search path): split fd's stderr "[fd error]" lines, merged into
  # stdout, from real result paths.
  @spec partition_errors(String.t()) :: {[String.t()], [String.t()]}
  def partition_errors(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.split_with(&String.starts_with?(&1, "[fd error]"))
  end

  defp respond(results, limit, note) do
    limited? = length(results) > limit
    shown = Enum.take(results, limit)

    text =
      case shown do
        [] -> "No files found."
        _ -> Enum.join(shown, "\n")
      end

    # Total is :unknown — fd's output was capped at limit + 1 results.
    {text, info} =
      Truncate.listing(text,
        limited?: limited?,
        limit: limit,
        total: :unknown,
        noun: "results"
      )

    result(append_note(text, note), %{
      result_count: length(shown),
      result_limit_reached: limited?,
      truncation: info
    })
  end

  defp error_note([]), do: "... [some paths could not be searched]"

  defp error_note([sample | _]),
    do: "... [some paths could not be searched: #{String.slice(sample, 0, 200)}]"

  defp append_note(text, nil), do: text
  defp append_note(text, note), do: text <> "\n" <> note
end
