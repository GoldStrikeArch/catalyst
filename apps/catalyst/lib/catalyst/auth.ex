defmodule Catalyst.Auth do
  @moduledoc """
  Authentication facade for subscription-backed model providers.

  `login_openai_codex/0` runs ChatGPT's browser PKCE flow. Optional providers
  own their login and refresh flows through `Catalyst.LLM.Controls`.
  """

  require Logger
  alias Catalyst.Auth.{CallbackServer, OpenAIOAuth, PKCE, TokenStore}

  @doc "Whether the selected subscription provider has stored credentials."
  @spec logged_in?(String.t()) :: boolean()
  def logged_in?(provider \\ OpenAIOAuth.provider_id()), do: TokenStore.logged_in?(provider)

  @doc "Forget the selected subscription provider's credentials."
  @spec logout(String.t()) :: :ok | {:error, term()}
  def logout(provider \\ OpenAIOAuth.provider_id()), do: TokenStore.delete(provider)

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
      open_browser(url, opts)

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
  Open an authentication URL in the platform browser unless `:no_browser` is set.

  Optional providers use this shared edge while retaining ownership of their
  protocol. `:open_browser` may inject a one-argument function in tests.
  """
  @spec open_browser(String.t(), keyword()) :: :ok
  def open_browser(url, opts \\ []) do
    case Keyword.get(opts, :no_browser, false) do
      true ->
        :ok

      false ->
        opts
        |> Keyword.get(:open_browser, &open_system_browser/1)
        |> then(& &1.(url))

        :ok
    end
  end

  defp open_system_browser(url) do
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
