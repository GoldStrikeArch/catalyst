defmodule Catalyst.Auth do
  @moduledoc """
  Authentication facade for subscription-backed model providers.

  `login_openai_codex/0` runs ChatGPT's browser PKCE flow;
  `login_grok/0` runs xAI's device authorization flow for SuperGrok.
  """

  require Logger
  alias Catalyst.Auth.{CallbackServer, Flow, OpenAIOAuth, PKCE, TokenStore, XAIOAuth}

  @doc "Whether the selected subscription provider has stored credentials."
  @spec logged_in?(String.t()) :: boolean()
  def logged_in?(provider \\ OpenAIOAuth.provider_id()), do: TokenStore.logged_in?(provider)

  @doc "Forget the selected subscription provider's credentials."
  @spec logout(String.t()) :: :ok | {:error, term()}
  def logout(provider \\ OpenAIOAuth.provider_id()), do: TokenStore.delete(provider)

  @doc "Run the authentication flow registered for `provider`."
  @spec login(String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def login(provider, opts \\ []) when is_binary(provider) and is_list(opts) do
    with {:ok, flow} <- Flow.resolve(provider) do
      flow.login(opts)
    end
  end

  @doc "Human-facing label for a registered authentication provider."
  @spec label(String.t()) :: {:ok, String.t()} | {:error, term()}
  def label(provider) when is_binary(provider) do
    with {:ok, flow} <- Flow.resolve(provider) do
      {:ok, flow.label()}
    end
  end

  @doc """
  Run the ChatGPT OAuth PKCE flow: open the browser, capture the redirect on
  :1455, exchange the code, and store credentials. Returns `{:ok, account_id}`.
  """
  @spec login_openai_codex(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def login_openai_codex(opts \\ []) do
    %{verifier: verifier, challenge: challenge} = PKCE.generate()
    state = PKCE.state()
    url = OpenAIOAuth.authorize_url(challenge, state)

    with {:ok, callback} <- CallbackServer.start(state) do
      maybe_open_browser(url, opts)

      IO.puts("""
      Opening your browser to sign in to ChatGPT (Codex subscription).
      If it doesn't open automatically, visit:

        #{url}
      """)

      with {:ok, code} <- CallbackServer.await(callback),
           {:ok, creds} <- OpenAIOAuth.exchange_code(code, verifier),
           :ok <- TokenStore.put(OpenAIOAuth.provider_id(), creds) do
        {:ok, creds["account_id"]}
      end
    end
  end

  @doc """
  Run xAI's device OAuth flow and store credentials for the SuperGrok-backed
  provider. The browser opens xAI's verification page while this call polls
  until the user approves, rejects, or the code expires.
  """
  @spec login_grok(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def login_grok(opts \\ []) do
    with {:ok, device} <- XAIOAuth.request_device_code(opts) do
      url = device.verification_uri_complete || device.verification_uri
      maybe_open_browser(url, opts)

      IO.puts("""
      Opening your browser to sign in to SuperGrok.
      If it doesn't open automatically, visit:

        #{device.verification_uri}

      and enter code: #{device.user_code}
      """)

      with {:ok, creds} <- XAIOAuth.await_device_code(device, opts),
           :ok <- TokenStore.put(XAIOAuth.provider_id(), creds) do
        {:ok, creds["account_id"]}
      end
    end
  end

  defp maybe_open_browser(url, opts) do
    case Keyword.get(opts, :no_browser, false) do
      true ->
        :ok

      false ->
        opts
        |> Keyword.get(:open_browser, &open_browser/1)
        |> then(& &1.(url))

        :ok
    end
  end

  defp open_browser(url) do
    cmd =
      case :os.type() do
        {:unix, :darwin} ->
          {"open", [url]}

        # Not `cmd /c start`: ERTS only quotes args containing whitespace, so
        # the whitespace-free URL reaches cmd.exe unquoted, where `&` is a
        # command separator — the browser gets the URL truncated at the first
        # query param and the rest runs as bogus commands. rundll32 hands the
        # URL straight to the default-browser handler, bypassing cmd's
        # metacharacter parsing entirely.
        {:win32, _} ->
          {"rundll32", ["url.dll,FileProtocolHandler", url]}

        _ ->
          {"xdg-open", [url]}
      end

    {bin, args} = cmd

    case System.find_executable(bin) do
      nil -> Logger.warning("[auth] could not find #{bin} to open the browser")
      _ -> System.cmd(bin, args, stderr_to_stdout: true)
    end
  end
end
