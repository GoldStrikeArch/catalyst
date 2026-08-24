defmodule CatalystACPFixture do
  def run do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        handle(line)
        run()
    end
  end

  defp handle(line) do
    log(line)
    id = request_id(line)

    cond do
      String.contains?(line, ~s("method":"initialize")) ->
        initialize(id)

      String.contains?(line, ~s("method":"session/new")) ->
        session_response(id)

      String.contains?(line, ~s("method":"session/resume")) ->
        session_response(id)

      String.contains?(line, ~s("method":"session/load")) ->
        update(
          ~s({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"replayed history"}})
        )

        session_response(id)

      String.contains?(line, ~s("method":"session/close")) ->
        puts(~s({"jsonrpc":"2.0","id":#{id},"result":{}}))

      String.contains?(line, ~s("method":"session/prompt")) ->
        prompt(id)

      true ->
        :ok
    end
  end

  defp initialize(id) do
    capabilities =
      case System.get_env("ACP_FIXTURE_RECOVERY", "resume") do
        "resume" -> ~s({"loadSession":true,"sessionCapabilities":{"resume":{},"close":{}}})
        "load" -> ~s({"loadSession":true,"sessionCapabilities":{"close":{}}})
        "none" -> ~s({"sessionCapabilities":{"close":{}}})
      end

    puts(
      ~s({"jsonrpc":"2.0","id":#{id},"result":{"protocolVersion":1,"agentCapabilities":#{capabilities},"agentInfo":{"name":"fixture","version":"1.0.0"},"authMethods":[]}})
    )
  end

  defp session_response(id) do
    puts(
      ~s({"jsonrpc":"2.0","id":#{id},"result":{"sessionId":"fixture-session","modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]},"configOptions":[{"id":"mode","name":"Mode","type":"select","currentValue":"ask","options":[{"value":"ask","name":"Ask"},{"value":"code","name":"Code"}]}]}})
    )
  end

  defp prompt(id) do
    case System.get_env("ACP_FIXTURE_PROMPT") do
      "hang" -> wait_for_cancel()
      "parallel" -> parallel_prompt(id)
      "incomplete" -> incomplete_prompt(id)
      _normal -> complete_prompt(id)
    end
  end

  defp complete_prompt(id) do
    puts(
      ~s({"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"fixture-session","toolCall":{"toolCallId":"tool-1"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"allow-always","name":"Always allow","kind":"allow_always"}]}})
    )

    permission = IO.read(:stdio, :line)
    log(permission)

    update(
      ~s({"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}})
    )

    update(
      ~s({"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"Fixture tool","kind":"execute","status":"pending","rawInput":{"command":"true"}})
    )

    update(
      ~s({"sessionUpdate":"tool_call_update","toolCallId":"tool-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"tool complete"}}]})
    )

    update(
      ~s({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"fixture answer"}})
    )

    update(
      ~s({"sessionUpdate":"config_option_update","configOptions":[{"id":"mode","name":"Mode","type":"select","currentValue":"code","options":[{"value":"ask","name":"Ask"},{"value":"code","name":"Code"}]}]})
    )

    puts(~s({"jsonrpc":"2.0","id":#{id},"result":{"stopReason":"end_turn"}}))
  end

  defp parallel_prompt(id) do
    update(
      ~s({"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"First tool","kind":"execute","status":"pending","rawInput":{"command":"first"}})
    )

    update(
      ~s({"sessionUpdate":"tool_call","toolCallId":"tool-2","title":"Second tool","kind":"execute","status":"pending","rawInput":{"command":"second"}})
    )

    update(
      ~s({"sessionUpdate":"tool_call_update","toolCallId":"tool-2","status":"completed","content":[{"type":"content","content":{"type":"text","text":"second complete"}}]})
    )

    update(
      ~s({"sessionUpdate":"tool_call_update","toolCallId":"tool-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"first complete"}}]})
    )

    update(
      ~s({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"parallel answer"}})
    )

    puts(~s({"jsonrpc":"2.0","id":#{id},"result":{"stopReason":"end_turn"}}))
  end

  defp incomplete_prompt(id) do
    update(
      ~s({"sessionUpdate":"tool_call","toolCallId":"tool-incomplete","title":"Incomplete tool","kind":"execute","status":"pending","rawInput":{"command":"wait"}})
    )

    puts(~s({"jsonrpc":"2.0","id":#{id},"result":{"stopReason":"end_turn"}}))
  end

  defp wait_for_cancel do
    :stdio
    |> IO.read(:line)
    |> log()
  end

  defp update(update) do
    puts(
      ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture-session","update":#{update}}})
    )
  end

  defp log(line) when is_binary(line) do
    case System.get_env("ACP_FIXTURE_LOG") do
      nil -> :ok
      path -> File.write!(path, line, [:append])
    end
  end

  defp log(_line), do: :ok

  defp request_id(line) do
    case Regex.run(~r/"id":(\d+)/, line) do
      [_, id] -> id
      _no_id -> "0"
    end
  end

  defp puts(line) do
    IO.puts(line)
    :ok
  end
end

CatalystACPFixture.run()
