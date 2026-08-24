defmodule Catalyst.LLM.GrokSubscription.Provider do
  @moduledoc """
  Direct SuperGrok subscription provider over xAI's Grok Build Chat Completions
  proxy. It uses xAI device OAuth credentials, not an API key and not ACP.
  """

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Ids, Message, Usage}
  alias Catalyst.Auth.{TokenStore, XAIOAuth}

  alias Catalyst.LLM.GrokSubscription.{
    Request,
    StreamParser,
    Transport
  }

  @auth_provider XAIOAuth.provider_id()

  @impl true
  @spec stream(
          Catalyst.Model.t() | nil,
          Catalyst.LLM.Context.t(),
          keyword(),
          Catalyst.LLM.Provider.sink()
        ) :: {:ok, Message.Assistant.t()} | {:error, term()}
  def stream(nil, _context, _opts, _sink) do
    {:ok, error_assistant(nil, "no Grok model is configured for this session")}
  end

  def stream(model, context, opts, sink) do
    case credentials() do
      {:ok, token, account_id} ->
        do_stream(model, context, opts, sink, token, account_id)

      {:error, message} ->
        {:ok, error_assistant(model, message)}
    end
  end

  defp credentials do
    case TokenStore.get_access_token(@auth_provider) do
      {:ok, %{access: token, account_id: account_id}} ->
        {:ok, token, account_id}

      {:error, reason} ->
        {:error,
         "not authenticated (#{inspect(reason)}). Sign in to SuperGrok from the sign-in button " <>
           "(or run Catalyst.Auth.login_grok/0)."}
    end
  end

  defp do_stream(model, context, opts, sink, token, account_id) do
    case attempt(model, context, opts, sink, token, account_id) do
      {:unauthorized, body} -> retry_unauthorized(model, context, opts, sink, body)
      {:ok, assistant} -> {:ok, assistant}
    end
  end

  defp retry_unauthorized(model, context, opts, sink, body) do
    :ok = TokenStore.invalidate(@auth_provider)

    case credentials() do
      {:ok, token, account_id} ->
        case attempt(model, context, opts, sink, token, account_id) do
          {:unauthorized, second_body} ->
            {:ok, error_assistant(model, http_error(401, second_body))}

          {:ok, assistant} ->
            {:ok, assistant}
        end

      {:error, message} ->
        {:ok, error_assistant(model, "#{http_error(401, body)} (#{message})")}
    end
  end

  defp attempt(model, context, opts, sink, token, account_id) do
    session_id = opts[:session_id] || Ids.hex(16)
    body = Request.build(model, context, opts)
    url = String.trim_trailing(model.base_url, "/") <> "/chat/completions"
    headers = headers(token, account_id, model.id, session_id)

    case Transport.stream(url, headers, body, sink) do
      {:ok, parser} ->
        {:ok, StreamParser.finalize(parser, model)}

      {:unauthorized, response_body} ->
        {:unauthorized, response_body}

      {:http_error, status, response_body} ->
        {:ok, error_assistant(model, http_error(status, response_body))}

      {:error, reason} ->
        {:ok, error_assistant(model, "Grok transport failed: #{inspect(reason)}")}
    end
  end

  defp headers(token, account_id, model_id, session_id) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"},
      {"user-agent", "catalyst"},
      {"x-xai-token-auth", "xai-grok-cli"},
      {"x-authenticateresponse", "authenticate-response"},
      {"x-grok-client-version", version()},
      {"x-grok-model-override", model_id},
      {"x-grok-conv-id", session_id},
      {"x-grok-session-id", session_id},
      {"x-grok-req-id", Ids.hex(16)},
      {"x-grok-agent-id", "catalyst"},
      {"x-grok-client-identifier", "catalyst"},
      {"x-grok-client-mode", "interactive"}
    ]
    |> maybe_user_id(account_id)
  end

  defp maybe_user_id(headers, account_id) when is_binary(account_id) and account_id != "",
    do: [{"x-userid", account_id} | headers]

  defp maybe_user_id(headers, _account_id), do: headers

  defp version do
    case Application.spec(:catalyst, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  defp http_error(429, body),
    do: structured_error(body) || "You have hit your SuperGrok usage limit. Try again later."

  defp http_error(status, body),
    do: structured_error(body) || "Grok HTTP #{status}: #{String.slice(body, 0, 600)}"

  defp structured_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      {:ok, %{"message" => message}} when is_binary(message) -> message
      _unstructured -> nil
    end
  end

  defp error_assistant(model, message) do
    {api, provider, model_id} = model_metadata(model)

    %Message.Assistant{
      content: [%Content.Text{text: message}],
      api: api,
      provider: provider,
      model: model_id,
      usage: %Usage{},
      stop_reason: :error,
      error_message: message,
      timestamp: Message.now()
    }
  end

  defp model_metadata(nil),
    do: {"grok-subscription-chat-completions", "grok-subscription", nil}

  defp model_metadata(model), do: {model.api, model.provider, model.id}
end
