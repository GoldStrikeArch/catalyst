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

  # Always reach System.halt: if CatalystCli.run/1 raised and the Task died
  # (it's a :temporary child), the headless release would hang forever with no
  # exit code — convert any crash into a printed error + exit status 1.
  @spec run_and_halt() :: no_return()
  defp run_and_halt do
    code =
      try do
        case CatalystCli.run(argv()) do
          :ok -> 0
          :error -> 1
        end
      rescue
        e ->
          IO.puts(:stderr, "catalyst: " <> Exception.message(e))
          1
      catch
        kind, reason ->
          IO.puts(:stderr, "catalyst: #{kind}: #{inspect(reason)}")
          1
      end

    System.halt(code)
  end

  # Burrito's Zig wrapper passes user args as plain arguments — System.argv/0
  # is always [] inside a release, so the wrapped binary would never see its
  # arguments. Outside a wrapped binary plain arguments carry OTP runtime
  # flags, so only consult them when the wrapper marker env is present.
  # (Inlined from Burrito.Util.Args, which is not part of this release.)
  defp argv do
    if System.get_env("__BURRITO_BIN_PATH") do
      :init.get_plain_arguments() |> Enum.map(&to_string/1)
    else
      System.argv()
    end
  end
end
