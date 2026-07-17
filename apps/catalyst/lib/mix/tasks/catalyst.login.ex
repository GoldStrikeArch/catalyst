defmodule Mix.Tasks.Catalyst.Login do
  @shortdoc "Sign in to ChatGPT (Codex subscription) via OAuth"
  @moduledoc """
  Runs the ChatGPT (Codex subscription) OAuth flow: opens your browser, captures
  the redirect on http://localhost:1455, and stores credentials in
  `~/.catalyst/auth.json`.

      mix catalyst.login
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    case Catalyst.Auth.login_openai_codex() do
      {:ok, account_id} ->
        Mix.shell().info("\n✓ Signed in to ChatGPT. account_id=#{account_id}")

      {:error, reason} ->
        Mix.shell().error("\n✗ Login failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
