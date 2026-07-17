defmodule Catalyst.Tools.ReadLog do
  @moduledoc """
  Read the tail of the current session's debug log (agent-loop steps, tool calls,
  LLM requests/responses, and errors). The agent uses this to self-diagnose a
  failed run.
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Debug

  @impl true
  def name, do: "read_log"

  @impl true
  def description,
    do:
      "Read the tail of THIS session's debug log: every agent-loop step, tool call, and " <>
        "(truncated) LLM request/response and error. Use it to understand why a previous step " <>
        "failed before deciding what to do."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "lines" => %{
          "type" => "integer",
          "description" => "trailing lines to return (default 120)"
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(args, ctx) do
    n = args["lines"] || 120

    case ctx[:session_id] do
      nil ->
        result("(no session id available — debug log not accessible from here)")

      sid ->
        path = Debug.path(sid)

        case File.read(path) do
          {:ok, content} ->
            tail = content |> String.split("\n") |> Enum.take(-n) |> Enum.join("\n")
            result(tail, %{path: path})

          {:error, _} ->
            result("(no debug log yet at #{path})")
        end
    end
  end
end
