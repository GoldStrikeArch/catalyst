defmodule Catalyst.Tools.Ls do
  @moduledoc "List a directory's entries (non-recursive), directories suffixed with `/`."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Listing, Paths}

  @default_limit 500

  @impl true
  def name, do: "ls"

  @impl true
  def description,
    do:
      "List directory entries (non-recursive), alphabetically; directories get a trailing slash."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Directory to list (default: current directory)"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum entries (default: 500)",
          "minimum" => 1,
          "maximum" => 10_000
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(args, ctx) do
    abs = Paths.resolve(args["path"] || ".", ctx.cwd)
    limit = args["limit"] || @default_limit

    names =
      abs
      |> File.ls!()
      |> Enum.sort_by(&String.downcase/1)

    limited? = length(names) > limit

    shown =
      names
      |> Enum.take(limit)
      |> Enum.map(fn name ->
        if File.dir?(Path.join(abs, name)), do: name <> "/", else: name
      end)

    {text, details} =
      shown
      |> Enum.join("\n")
      |> Listing.render(
        count: length(shown),
        noun: "entries",
        limited?: limited?,
        limit: limit,
        total: length(names)
      )

    result(text, Map.put(details, :path, abs))
  end
end
