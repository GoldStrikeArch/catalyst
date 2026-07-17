defmodule Catalyst.Tools.Sd do
  @moduledoc "Find-and-replace in a file via sd (`replace` tool). In-place; regex or string mode."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Paths}

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "replace"

  @impl true
  def description,
    do:
      "Find-and-replace text in a file with sd (in place). Pattern is a regex " <>
        "unless `string_mode: true` (literal). Capture groups use $1, $2, …"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Find pattern (regex, or literal with string_mode)"
        },
        "replacement" => %{"type" => "string", "description" => "Replacement text"},
        "path" => %{"type" => "string", "description" => "File to edit in place"},
        "string_mode" => %{
          "type" => "boolean",
          "description" => "Treat pattern as a literal string (default: false)"
        }
      },
      "required" => ["pattern", "replacement", "path"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern, "replacement" => replacement, "path" => path} = args, ctx) do
    sd = Binaries.path!(:sd)
    abs = Paths.resolve(path, ctx.cwd)
    flags = if args["string_mode"], do: ["--string-mode"], else: []
    sd_args = flags ++ ["--", pattern, replacement, abs]

    case Exec.collect(sd, sd_args, cwd: ctx.cwd) do
      {:ok, %{status: 0}} ->
        result("Replaced occurrences of #{inspect(pattern)} in #{abs}", %{path: abs})

      {:ok, %{out: out, status: status}} ->
        raise "sd error (status #{status}): #{String.slice(out, 0, 200)}"

      {:error, reason} ->
        raise "sd failed: #{inspect(reason)}"
    end
  end
end
