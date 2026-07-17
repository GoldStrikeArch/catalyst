defmodule Catalyst.LLM.OpenAICodex.Headers do
  @moduledoc "Builds the Codex Responses SSE request headers (ported from PI's buildSSEHeaders)."

  @doc "Header list for a streamed Codex request."
  def build(token, account_id, session_id) do
    [
      {"authorization", "Bearer #{token}"},
      {"chatgpt-account-id", account_id},
      {"originator", "catalyst"},
      {"user-agent", user_agent()},
      {"openai-beta", "responses=experimental"},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"},
      {"session-id", session_id},
      {"x-client-request-id", session_id}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp user_agent do
    arch = :erlang.system_info(:system_architecture) |> to_string()
    "catalyst (#{arch})"
  end
end
