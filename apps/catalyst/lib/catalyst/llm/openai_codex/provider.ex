defmodule Catalyst.LLM.OpenAICodex.Provider do
  @moduledoc """
  OpenAI Codex (ChatGPT subscription) provider over the Responses API at
  `https://chatgpt.com/backend-api/codex/responses`, streamed via SSE.

  Per the `Catalyst.LLM.Provider` contract it never raises: auth/HTTP/stream
  failures come back as a final assistant with `stop_reason: :error`.
  """

  @behaviour Catalyst.LLM.Provider

  require Logger

  alias Catalyst.{Content, Message}
  alias Catalyst.Auth.TokenStore
  alias Catalyst.LLM.SSE
  alias Catalyst.LLM.OpenAICodex.{Headers, Request, StreamParser}

  @default_base "https://chatgpt.com/backend-api"
  @auth_provider "openai-codex"
  @receive_timeout 600_000

  @impl true
  def stream(model, context, opts, sink) do
    case TokenStore.get_access_token(@auth_provider) do
      {:ok, %{access: token, account_id: account_id}} ->
        do_stream(model, context, opts, sink, token, account_id)

      {:error, reason} ->
        {:ok, error_assistant(model, "not authenticated (#{inspect(reason)}). Run Catalyst.Auth.login_openai_codex/0.")}
    end
  end

  defp do_stream(model, context, opts, sink, token, account_id) do
    url = resolve_url(model)
    session_id = opts[:session_id] || random_id()
    headers = Headers.build(token, account_id, session_id)
    body = Request.build(model, context, Keyword.put(opts, :session_id, session_id)) |> Jason.encode!()

    request = Finch.build(:post, url, headers, body)

    acc = %{status: nil, buffer: "", parser: StreamParser.new(), sink: sink, error_body: ""}

    case Finch.stream(request, Catalyst.Finch, acc, &handle_chunk/2, receive_timeout: @receive_timeout) do
      {:ok, %{status: 200, parser: parser}} ->
        {:ok, StreamParser.finalize(parser, model)}

      {:ok, %{status: status, error_body: body}} ->
        {:ok, error_assistant(model, "HTTP #{status}: #{String.slice(body, 0, 600)}")}

      {:error, reason} ->
        {:ok, error_assistant(model, "stream error: #{inspect(reason)}")}
    end
  end

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, _headers}, acc), do: acc

  defp handle_chunk({:data, chunk}, %{status: 200} = acc) do
    {buffer, events} = SSE.feed(acc.buffer, chunk)
    parser = Enum.reduce(events, acc.parser, fn ev, p -> StreamParser.handle(p, ev, acc.sink) end)
    %{acc | buffer: buffer, parser: parser}
  end

  # Non-200: collect the body so we can report the error.
  defp handle_chunk({:data, chunk}, acc), do: %{acc | error_body: acc.error_body <> chunk}

  defp resolve_url(model) do
    base = (model.base_url || @default_base) |> String.trim() |> String.replace_trailing("/", "")

    cond do
      base == "" -> @default_base <> "/codex/responses"
      String.ends_with?(base, "/codex/responses") -> base
      String.ends_with?(base, "/codex") -> base <> "/responses"
      true -> base <> "/codex/responses"
    end
  end

  defp error_assistant(model, message) do
    Logger.warning("[openai-codex] #{message}")

    %Message.Assistant{
      content: [%Content.Text{text: message}],
      api: model.api,
      provider: model.provider,
      model: model.id,
      stop_reason: :error,
      error_message: message,
      timestamp: Message.now()
    }
  end

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
