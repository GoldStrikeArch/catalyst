defmodule Catalyst.Tools.Ls do
  @moduledoc "List a directory's entries (non-recursive), directories suffixed with `/`."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Paths, Truncate}

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
        "limit" => %{"type" => "integer", "description" => "Maximum entries (default: 500)"}
      },
      "required" => []
    }
  end

  @impl true
  def execute(args, ctx) do
    abs = Paths.resolve(args["path"] || ".", ctx.cwd)
    limit = args["limit"] || @default_limit

    entries =
      abs
      |> File.ls!()
      |> Enum.sort_by(&String.downcase/1)
      |> Enum.map(fn name ->
        if File.dir?(Path.join(abs, name)), do: name <> "/", else: name
      end)

    shown = Enum.take(entries, limit)
    limited? = length(entries) > limit

    {text, info} =
      shown
      |> Enum.join("\n")
      |> Truncate.listing(
        limited?: limited?,
        limit: limit,
        total: length(entries),
        noun: "entries"
      )

    result(text, %{
      path: abs,
      truncation: info,
      entry_limit_reached: limited?
    })
  end
end
