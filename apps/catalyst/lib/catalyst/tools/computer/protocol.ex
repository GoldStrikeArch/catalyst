defmodule Catalyst.Tools.Computer.Protocol do
  @moduledoc """
  Pure codec for the `catalyst-input` helper's newline-delimited JSON protocol
  (plan §2), plus keyboard-chord parsing.

  The helper reads one JSON object per line on stdin and writes one per line on
  stdout. Every request carries an `id` that is echoed on the response:

    * request  — `%{"id" => id, "op" => op, ...args}`
    * success  — `%{"id" => id, "result" => map}`
    * failure  — `%{"id" => id, "error" => message}`

  This module owns encoding requests and decoding response lines into tagged
  tuples. It performs no IO — the GenServer that owns the `Port` uses it.

  ## Examples

      iex> line = Catalyst.Tools.Computer.Protocol.encode(7, "cursor", %{})
      iex> Catalyst.Tools.Computer.Protocol.decode_line(line)
      {:request, 7, "cursor", %{}}
  """

  @typedoc "A request id — any JSON-encodable scalar; integers in practice."
  @type id :: integer() | String.t()

  @typedoc "Decoded response: success result map or an error message."
  @type response :: {:ok, map()} | {:error, String.t()}

  @doc """
  Encode an op + args map into a single-line JSON request string (no trailing
  newline; the caller frames lines). `id` is embedded and echoed by the helper.

  ## Examples

      iex> line = Catalyst.Tools.Computer.Protocol.encode(1, "click", %{"coordinate" => [10, 20]})
      iex> Jason.decode!(line)
      %{"coordinate" => [10, 20], "id" => 1, "op" => "click"}
  """
  @spec encode(id(), String.t(), map()) :: String.t()
  def encode(id, op, args) when is_binary(op) and is_map(args) do
    args
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("id", id)
    |> Map.put("op", op)
    |> Jason.encode!()
  end

  @doc """
  Decode one response line from the helper.

  Returns:

    * `{:ok, id, {:ok, result_map}}` for a success line,
    * `{:ok, id, {:error, message}}` for an error line carrying an id,
    * `{:error, :invalid_json}` when the line is not JSON,
    * `{:error, {:malformed, term}}` when the JSON is not a recognised shape.

  ## Examples

      iex> Catalyst.Tools.Computer.Protocol.decode_response(~s({"id":3,"result":{"x":1}}))
      {:ok, 3, {:ok, %{"x" => 1}}}

      iex> Catalyst.Tools.Computer.Protocol.decode_response(~s({"id":4,"error":"unknown_op: foo"}))
      {:ok, 4, {:error, "unknown_op: foo"}}

      iex> Catalyst.Tools.Computer.Protocol.decode_response("not json")
      {:error, :invalid_json}
  """
  @spec decode_response(String.t()) ::
          {:ok, id() | nil, response()} | {:error, :invalid_json | {:malformed, term()}}
  def decode_response(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> classify_response(decoded)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp classify_response(%{"error" => message} = map),
    do: {:ok, Map.get(map, "id"), {:error, message}}

  defp classify_response(%{"result" => result} = map) when is_map(result),
    do: {:ok, Map.get(map, "id"), {:ok, result}}

  defp classify_response(other), do: {:error, {:malformed, other}}

  @doc """
  Decode any single protocol line into a tagged shape — a request (used by the
  test target and tests) or a response. Prefer `decode_response/1` on the client
  side.

  ## Examples

      iex> Catalyst.Tools.Computer.Protocol.decode_line(~s({"id":1,"op":"screens"}))
      {:request, 1, "screens", %{}}
  """
  @spec decode_line(String.t()) ::
          {:request, id() | nil, String.t(), map()}
          | {:ok, id() | nil, response()}
          | {:error, :invalid_json | {:malformed, term()}}
  def decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"op" => op} = map} when is_binary(op) ->
        {:request, Map.get(map, "id"), op, Map.drop(map, ["id", "op"])}

      {:ok, decoded} ->
        classify_response(decoded)

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  # Canonical modifier names the helper understands.
  @modifier_aliases %{
    "cmd" => "command",
    "command" => "command",
    "shift" => "shift",
    "ctrl" => "control",
    "control" => "control",
    "opt" => "option",
    "option" => "option",
    "alt" => "option",
    "fn" => "function",
    "function" => "function"
  }

  @doc """
  Parse a keyboard chord such as `"cmd+shift+s"` into normalized modifiers and a
  key name. The final `+`-separated token is the key; the rest must be known
  modifiers.

  Modifiers normalize to `"command" | "shift" | "control" | "option" |
  "function"`, deduplicated and in that canonical order. The key is preserved
  verbatim (the helper resolves it against the active keyboard layout), except a
  lone `"+"` key is accepted (e.g. `"cmd++"`).

  Returns `{:ok, %{modifiers: [String.t()], key: String.t()}}` or
  `{:error, reason}` for an unknown modifier or an empty key.

  ## Examples

      iex> Catalyst.Tools.Computer.Protocol.parse_chord("cmd+shift+s")
      {:ok, %{modifiers: ["command", "shift"], key: "s"}}

      iex> Catalyst.Tools.Computer.Protocol.parse_chord("Return")
      {:ok, %{modifiers: [], key: "Return"}}

      iex> Catalyst.Tools.Computer.Protocol.parse_chord("hyper+s")
      {:error, {:unknown_modifier, "hyper"}}

      iex> Catalyst.Tools.Computer.Protocol.parse_chord("")
      {:error, :empty_key}
  """
  @spec parse_chord(String.t()) ::
          {:ok, %{modifiers: [String.t()], key: String.t()}}
          | {:error, :empty_key | {:unknown_modifier, String.t()}}
  def parse_chord(chord) when is_binary(chord) do
    case split_chord(chord) do
      {:error, _} = err -> err
      {mods, key} -> normalize_chord(mods, key)
    end
  end

  # Split on "+" but treat a trailing empty token as the literal "+" key.
  defp split_chord(chord) do
    case String.split(chord, "+") do
      [""] -> {:error, :empty_key}
      [key] -> {[], key}
      parts -> split_trailing(parts)
    end
  end

  defp split_trailing(parts) do
    {mods, [key]} = Enum.split(parts, -1)

    case key do
      # "cmd++" → last two tokens are "" then "" ; key is the literal "+"
      "" -> {Enum.drop(mods, -1), "+"}
      key -> {mods, key}
    end
  end

  defp normalize_chord(_mods, ""), do: {:error, :empty_key}

  defp normalize_chord(mods, key) do
    with {:ok, normalized} <- normalize_modifiers(mods) do
      {:ok, %{modifiers: normalized, key: key}}
    end
  end

  @doc """
  Parse a `+`-separated modifier list (no key), e.g. `"cmd+shift"` — the shape
  click actions accept for held modifiers. Normalizes exactly like
  `parse_chord/1`; an empty or `nil` value is no modifiers.

  ## Examples

      iex> Catalyst.Tools.Computer.Protocol.parse_modifiers("cmd+shift")
      {:ok, ["command", "shift"]}

      iex> Catalyst.Tools.Computer.Protocol.parse_modifiers(nil)
      {:ok, []}

      iex> Catalyst.Tools.Computer.Protocol.parse_modifiers("hyper")
      {:error, {:unknown_modifier, "hyper"}}
  """
  @spec parse_modifiers(String.t() | nil) ::
          {:ok, [String.t()]} | {:error, {:unknown_modifier, String.t()}}
  def parse_modifiers(nil), do: {:ok, []}
  def parse_modifiers(""), do: {:ok, []}

  def parse_modifiers(text) when is_binary(text) do
    text
    |> String.split("+", trim: true)
    |> normalize_modifiers()
  end

  @canonical_order ["command", "shift", "control", "option", "function"]

  defp normalize_modifiers(mods) do
    Enum.reduce_while(mods, {:ok, []}, fn mod, {:ok, acc} ->
      case Map.fetch(@modifier_aliases, String.downcase(mod)) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        :error -> {:halt, {:error, {:unknown_modifier, mod}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, order_modifiers(list)}
      err -> err
    end
  end

  defp order_modifiers(list) do
    uniq = Enum.uniq(list)
    Enum.filter(@canonical_order, &(&1 in uniq))
  end
end
