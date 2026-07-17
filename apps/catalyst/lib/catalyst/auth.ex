defmodule Catalyst.Auth do
  @moduledoc """
  Authentication facade. `login_openai_codex/0` runs the ChatGPT (Codex
  subscription) browser OAuth flow end to end and stores the credentials.
  """

  require Logger
  alias Catalyst.Auth.{CallbackServer, OpenAIOAuth, PKCE, TokenStore}

  @provider "openai-codex"

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

        # cmd's `start` quoting trap: an unquoted `&` in the URL splits the
        # command, but quoting the URL makes `start` read it as the window
        # TITLE (start treats the first quoted arg as the title). Passing an
        # explicit empty title makes the URL land in the command position.
        {:win32, _} ->
          {"cmd", ["/c", "start", "", url]}

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
