defmodule Catalyst.LLM.OpenAICodex.Headers do
  @moduledoc """
  Builds the Codex Responses request headers — `build/3` for SSE (ported from
  PI's `buildSSEHeaders`), `websocket/3` for the websocket upgrade (per the
  Codex CLI's `build_websocket_headers`: same identity headers, the
  `responses_websockets` beta tag, and no accept/content-type).
  """

  @ws_beta "responses_websockets=2026-02-06"

  @doc "Header list for a streamed Codex request (nil-valued headers are dropped)."
  @spec build(String.t(), String.t() | nil, String.t()) :: [{String.t(), String.t()}]
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

  @doc "Header list for the websocket upgrade request."
  @spec websocket(String.t(), String.t() | nil, String.t()) :: [{String.t(), String.t()}]
  def websocket(token, account_id, session_id) do
    [
      {"authorization", "Bearer #{token}"},
      {"chatgpt-account-id", account_id},
      {"originator", "catalyst"},
      {"user-agent", user_agent()},
      {"openai-beta", @ws_beta},
      {"session-id", session_id},
      {"x-client-request-id", session_id}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "Return the first case-insensitive response-header value, or `nil`."
  @spec get([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def get(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      case String.downcase(key) == String.downcase(name) do
        true -> value
        false -> nil
      end
    end)
  end

  defp user_agent do
    arch = :erlang.system_info(:system_architecture) |> to_string()
    "catalyst (#{arch})"
  end
end
