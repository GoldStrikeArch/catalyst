defmodule Catalyst.Auth do
  @moduledoc """
  Authentication facade. `login_openai_codex/0` runs the ChatGPT (Codex
  subscription) browser OAuth flow end to end and stores the credentials.
  """

  require Logger
  alias Catalyst.Auth.{CallbackServer, OpenAIOAuth, PKCE, TokenStore}

  # TokenStore key for the Codex credentials (single source).
  @provider Catalyst.Auth.OpenAIOAuth.provider_id()

  @doc "Whether we have Codex credentials."
  def logged_in?, do: TokenStore.logged_in?(@provider)

  @doc "Forget the stored Codex credentials."
  def logout, do: TokenStore.delete(@provider)

  @doc """
  Run the ChatGPT OAuth PKCE flow: open the browser, capture the redirect on
  :1455, exchange the code, and store credentials. Returns `{:ok, account_id}`.
  """
  def login_openai_codex(opts \\ []) do
    %{verifier: verifier, challenge: challenge} = PKCE.generate()
    state = PKCE.state()
    url = OpenAIOAuth.authorize_url(challenge, state)

    unless opts[:no_browser], do: open_browser(url)

    IO.puts("""
    Opening your browser to sign in to ChatGPT (Codex subscription).
    If it doesn't open automatically, visit:

      #{url}
    """)

    with {:ok, code} <- CallbackServer.await(state),
         {:ok, creds} <- OpenAIOAuth.exchange_code(code, verifier),
         :ok <- TokenStore.put(@provider, creds) do
      {:ok, creds["account_id"]}
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
