defmodule Catalyst.Tools.Bash do
  @moduledoc "Run a shell command in the session cwd (muontrap-wrapped for group kill; output capped and tail-truncated)."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Exec, Truncate}

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "bash"

  @default_timeout_s 120

  @impl true
  def description,
    do:
      "Run a bash/sh command in the working directory. Output (stdout+stderr) is tail-truncated " <>
        "to 2000 lines / 50KB. Commands time out after #{@default_timeout_s}s unless `timeout` is given. " <>
        "Commands run without a stdin; anything interactive will hit the timeout."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "Shell command to run"},
        "timeout" => %{
          "type" => "integer",
          "description" => "Timeout in seconds (default #{@default_timeout_s})"
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = args, ctx) do
    timeout_s = timeout_seconds(args["timeout"])

    case Exec.bash(command, cwd: ctx.cwd, timeout: timeout_s * 1000) do
      {:ok, %{out: out, status: status} = res} ->
        # truncated: true means Exec.bash killed the command at its output
        # cap — tell the model, the way a timeout is reported.
        capped? = Map.get(res, :truncated, false)
        {text, info} = Truncate.tail(out)

        text =
          text
          |> Truncate.notice(info, :tail)
          |> Exec.append_capped_notice(
            capped?,
            Exec.bash_max_output_bytes(),
            "command killed before completion"
          )

        body = if status == 0, do: text, else: text <> "\n[exit status: #{status}]"
        result(body, %{exit_status: status, output_capped: capped?, truncation: info})

      {:error, {:timeout, partial}} ->
        {tail, _info} = Truncate.tail(partial, max_lines: 50)

        raise "bash command timed out after #{timeout_s}s" <>
                if(tail == "", do: "", else: ". Output before timeout:\n" <> tail)

      {:error, reason} ->
        raise "bash failed: #{inspect(reason)}"
    end
  end

  defp timeout_seconds(s) when is_integer(s) and s > 0, do: s
  defp timeout_seconds(s) when is_float(s) and s > 0, do: round(s)
  defp timeout_seconds(_), do: @default_timeout_s
end
