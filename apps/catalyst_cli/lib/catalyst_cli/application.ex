defmodule CatalystCli.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Only act as a CLI when launched as the packaged release (RELEASE_NAME is
    # set by OTP releases / Burrito at runtime). Under plain `iex -S mix` /
    # `mix phx.server` this stays a no-op so dev isn't affected.
    if System.get_env("RELEASE_NAME") do
      Task.start(fn ->
        Process.sleep(50)
        CatalystCli.run(argv())
        System.halt(0)
      end)
    end

    Supervisor.start_link([], strategy: :one_for_one, name: CatalystCli.Supervisor)
  end

  # Burrito passes CLI args through its own helper; fall back to System.argv/0.
  defp argv do
    if Code.ensure_loaded?(Burrito.Util.Args) and function_exported?(Burrito.Util.Args, :argv, 0) do
      Burrito.Util.Args.argv()
    else
      System.argv()
    end
  end
end
