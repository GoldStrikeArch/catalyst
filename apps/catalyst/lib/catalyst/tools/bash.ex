defmodule Catalyst.Tools.Bash do
  @moduledoc "Run a shell command in the session cwd (MuonTrap-backed, tail-truncated output)."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Exec, Truncate}

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "bash"

  @impl true
  def description,
    do: "Run a bash/sh command in the working directory. Output (stdout+stderr) is tail-truncated to 2000 lines / 50KB."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "Shell command to run"},
        "timeout" => %{"type" => "integer", "description" => "Timeout in seconds (optional)"}
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = args, ctx) do
    timeout_ms = if args["timeout"], do: args["timeout"] * 1000, else: nil

    case Exec.bash(command, cwd: ctx.cwd, timeout: timeout_ms) do
      {:ok, %{out: out, status: status}} ->
        {text, info} = Truncate.tail(out)
        body = if status == 0, do: text, else: text <> "\n[exit status: #{status}]"
        result(body, %{exit_status: status, truncation: info})

      {:error, :timeout} ->
        raise "bash command timed out after #{args["timeout"]}s"

      {:error, reason} ->
        raise "bash failed: #{inspect(reason)}"
    end
  end
end
