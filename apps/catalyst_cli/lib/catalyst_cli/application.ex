defmodule CatalystCli.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Only act as a CLI when launched as the packaged release (RELEASE_NAME is
    # set by OTP releases / Burrito at runtime). Under plain `iex -S mix` /
    # `mix phx.server` this stays a no-op so dev isn't affected.
    children = if System.get_env("RELEASE_NAME"), do: [{Task, &run_and_halt/0}], else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: CatalystCli.Supervisor)
  end

  @spec run_and_halt() :: no_return()
  defp run_and_halt do
    code = if CatalystCli.run(argv()) == :ok, do: 0, else: 1
    System.halt(code)
  end

  # Burrito passes CLI args through its own helper; fall back to System.argv/0.
  defp argv do
    module = Burrito.Util.Args

    if Code.ensure_loaded?(module) and function_exported?(module, :argv, 0) do
      apply(module, :argv, [])
    else
      System.argv()
    end
  end
end
