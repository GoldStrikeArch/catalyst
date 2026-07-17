defmodule Catalyst.Tools.Write do
  @moduledoc "Create or overwrite a file, creating parent directories."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.Paths

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "write"

  @impl true
  def description,
    do: "Create or overwrite a file with the given content. Parent directories are created."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path (relative to cwd or absolute)"
        },
        "content" => %{"type" => "string", "description" => "Full file content to write"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}, ctx) do
    abs = Paths.resolve(path, ctx.cwd)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
    result("Wrote #{byte_size(content)} bytes to #{abs}", %{path: abs, bytes: byte_size(content)})
  end
end
