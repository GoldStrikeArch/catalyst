defmodule Catalyst.Tools.Profiles do
  @moduledoc """
  Mechanically enforced tool limits for persisted workflow stage profiles.

  Profiles are applied to the resolved live tool set. The `coding` profile
  preserves that set unchanged, while `inspect` permits only built-in tools
  whose implementations are unambiguously read-only. Unknown profiles fail
  closed.
  """

  alias Catalyst.Tools.{Fd, ListAgents, Ls, Read, ReadLog, Ripgrep}

  @coding "coding"
  @inspect "inspect"
  @known [@coding, @inspect]
  @inspect_tools MapSet.new([Read, Ls, Ripgrep, Fd, ReadLog, ListAgents])

  @typedoc "Stable persisted tool profile identifier."
  @type name :: String.t()

  @doc "Return the stable identifiers accepted as persisted tool profiles."
  @spec known() :: [name()]
  def known, do: @known

  @doc """
  Apply a final profile limit to an already resolved tool list.

  `coding` is intentionally an identity operation. `inspect` uses module
  identity rather than advertised tool names, so an extension cannot shadow a
  safe name to enter the allowlist. Unknown values return no tools.
  """
  @spec filter([module()], term()) :: [module()]
  def filter(tools, profile) when is_list(tools) do
    case normalize(profile) do
      {:ok, @coding} -> tools
      {:ok, @inspect} -> Enum.filter(tools, &MapSet.member?(@inspect_tools, &1))
      :error -> []
    end
  end

  @doc "Normalize a supported atom or persisted string profile identifier."
  @spec normalize(term()) :: {:ok, name()} | :error
  def normalize(@coding), do: {:ok, @coding}
  def normalize(:coding), do: {:ok, @coding}
  def normalize(@inspect), do: {:ok, @inspect}
  def normalize(:inspect), do: {:ok, @inspect}
  def normalize(_profile), do: :error
end
