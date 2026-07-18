defmodule CatalystWeb.ShellLive.Commands do
  @moduledoc """
  Parses and dispatches slash commands submitted through the shell chat input.

  Runtime command handlers are an extension boundary, so execution is isolated:
  a handler failure becomes a flash rather than crashing the LiveView.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias CatalystWeb.ShellLive.SessionLifecycle
  alias CatalystWeb.UI.Registry

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Parses `/name` or `/name argument` and rejects ordinary slash-prefixed text."
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse(text) do
    case Regex.run(~r/^\/([a-z0-9_-]+)(?:\s+(.*))?$/s, text) do
      [_, name] -> {:ok, name, ""}
      [_, name, argument] -> {:ok, name, String.trim(argument)}
      nil -> :error
    end
  end

  @doc "Dispatches a parsed command through the live UI registry."
  @spec dispatch(String.t(), String.t(), socket()) :: socket()
  def dispatch(name, argument, socket) do
    case Registry.fetch_command(name) do
      {:ok, %{handler: handler}} when is_function(handler, 2) ->
        safely_invoke(handler, argument, socket)

      {:ok, _entry_without_handler} ->
        put_flash(socket, :error, "command /#{name} has no handler")

      :error ->
        put_flash(socket, :error, unknown_command_message(name))
    end
  end

  @doc "Built-in `/cd` handler registered in the same runtime registry as extension commands."
  @spec change_directory(String.t(), socket()) :: socket()
  def change_directory("", socket), do: put_flash(socket, :error, "usage: /cd <path>")
  def change_directory(path, socket), do: SessionLifecycle.change_cwd(socket, path)

  defp safely_invoke(handler, argument, socket) do
    %Phoenix.LiveView.Socket{} = handler.(argument, socket)
  rescue
    error -> put_flash(socket, :error, "command failed: #{Exception.message(error)}")
  catch
    kind, reason -> put_flash(socket, :error, "command failed: #{kind} #{inspect(reason)}")
  end

  defp unknown_command_message(name) do
    known =
      Registry.list_commands()
      |> Enum.map(&("/" <> &1.name))
      |> Enum.sort()
      |> Enum.join(", ")

    "unknown command /#{name} (known: #{known})"
  end
end
