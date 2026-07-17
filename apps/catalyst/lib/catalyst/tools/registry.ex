defmodule Catalyst.Tools.Registry do
  @moduledoc "The set of built-in tools, plus helpers to look them up and serialize them for a provider."

  alias Catalyst.Tools.{
    Read,
    Write,
    Edit,
    Ls,
    Bash,
    Ripgrep,
    Fd,
    Sd,
    AstGrep,
    DevelopTool,
    InstallExtension,
    ReloadTool,
    RollbackTool,
    ReadLog
  }

  @default [
    Read,
    Ls,
    Ripgrep,
    Fd,
    Bash,
    Write,
    Edit,
    Sd,
    AstGrep,
    DevelopTool,
    InstallExtension,
    ReloadTool,
    RollbackTool,
    ReadLog
  ]

  @doc "The default tool module list."
  def default_tools, do: @default

  @doc "Map of tool name => module for the given tool list."
  def index(tools \\ @default), do: Map.new(tools, &{&1.name(), &1})

  @doc "Look up a tool module by its name within `tools`."
  def fetch(tools, name), do: tools |> index() |> Map.get(name)

  @doc "Serialize tools to the provider shape: `[%{name, description, parameters}]`."
  def to_provider_tools(tools \\ @default) do
    Enum.map(tools, fn m ->
      %{name: m.name(), description: m.description(), parameters: m.parameters()}
    end)
  end
end
