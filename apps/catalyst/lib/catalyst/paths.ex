defmodule Catalyst.Paths do
  @moduledoc """
  Paths for Catalyst-owned user data below `~/.catalyst`.

  Set `config :catalyst, :home` to relocate all default user data together;
  the `CATALYST_HOME` environment variable does the same for packaged releases
  (where no config file is editable), with the app env taking precedence.
  The narrower `:extensions_dir` override affects only extensions, so changing
  where source files are loaded cannot silently move credentials, transcripts,
  debug logs, system prompts, or downloaded binaries.
  """

  @doc "Catalyst's user-data home directory."
  @spec home() :: Path.t()
  def home do
    Application.get_env(:catalyst, :home) ||
      System.get_env("CATALYST_HOME") ||
      Path.expand("~/.catalyst")
  end

  @doc "Join a relative path or path-segment list below `home/0`."
  @spec join(Path.t() | [Path.t()]) :: Path.t()
  def join(path) when is_binary(path), do: Path.join(home(), path)
  def join(parts) when is_list(parts), do: Path.join([home() | parts])

  @doc "Default extensions directory."
  @spec extensions() :: Path.t()
  def extensions do
    Application.get_env(:catalyst, :extensions_dir) || join("extensions")
  end

  @doc "Default session-store root."
  @spec sessions() :: Path.t()
  def sessions, do: join("sessions")

  @doc "Default debug-log directory."
  @spec debug() :: Path.t()
  def debug, do: join("debug")

  @doc "Default OAuth credential file."
  @spec auth() :: Path.t()
  def auth, do: join("auth.json")

  @doc "Default system-prompt override file."
  @spec system_prompt() :: Path.t()
  def system_prompt, do: join("system_prompt.md")

  @doc "Default extension boot marker."
  @spec boot_marker() :: Path.t()
  def boot_marker, do: join("boot_marker")
end
