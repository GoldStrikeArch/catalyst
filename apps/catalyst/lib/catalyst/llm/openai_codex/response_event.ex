defmodule Catalyst.LLM.OpenAICodex.ResponseEvent do
  @moduledoc """
  Shared normalization and terminal classification for Responses API events.

  Both SSE and WebSocket transports feed these maps to the same stream parser.
  Keeping the legacy aliases and terminal set here prevents either transport
  from waiting for more data after the response has already ended.
  """

  @terminal_types ~w(response.completed response.incomplete response.failed
                     response.cancelled error)

  @doc "Normalize a decoded Responses API event into Catalyst's canonical wire shape."
  @spec normalize(map()) :: map()
  def normalize(%{"type" => "response.done"} = event),
    do: Map.put(event, "type", "response.completed")

  def normalize(event) when is_map(event), do: event

  @doc "Whether a normalized or legacy Responses API event ends the response stream."
  @spec terminal?(map()) :: boolean()
  def terminal?(event) when is_map(event) do
    event
    |> normalize()
    |> Map.get("type")
    |> then(&(&1 in @terminal_types))
  end
end
