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

  @typedoc "Tool name => module lookup map, as built by `index/1`."
  @type index :: %{optional(String.t()) => module()}

  @doc "The default tool module list."
  @spec default_tools() :: [module()]
  def default_tools, do: @default

  @doc """
  Map of tool name => module for the given tool list.

  Build this once per batch and pass it to `fetch/2` to avoid re-deriving the
  map (and calling each tool's `name/0`) on every lookup.
  """
  @spec index([module()]) :: index()
  def index(tools \\ @default), do: Map.new(tools, &{&1.name(), &1})

  @doc """
  Look up a tool module by its name.

  Accepts either a tool module list or a prebuilt `index/1` map and returns
  `{:ok, module}`, or `:error` when no tool has that name.
  """
  @spec fetch([module()] | index(), String.t()) :: {:ok, module()} | :error
  def fetch(tools, name) when is_list(tools), do: tools |> index() |> Map.fetch(name)
  def fetch(index, name) when is_map(index), do: Map.fetch(index, name)

  @doc "Serialize tools to the provider shape: `[%{name, description, parameters}]`."
  @spec to_provider_tools([module()]) :: [
          %{name: String.t(), description: String.t(), parameters: map()}
        ]
  def to_provider_tools(tools \\ @default) do
    Enum.map(tools, fn m ->
      %{name: m.name(), description: m.description(), parameters: m.parameters()}
    end)
  end
end
