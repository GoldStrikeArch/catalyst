defmodule Catalyst.Runtime.Scope do
  @moduledoc """
  Conjunctive identity constraints for a runtime claim.

  A global scope has no constraints. A scoped claim matches only when every
  constrained dimension equals the corresponding runtime context value.
  Specificity is the number of constrained dimensions; equal-specificity
  claims at the same priority are deliberately ambiguous rather than relying on
  installation order.
  """

  alias Catalyst.Runtime.Context

  @enforce_keys [:constraints]
  defstruct @enforce_keys

  @type t :: %__MODULE__{constraints: %{optional(Context.dimension()) => String.t()}}

  @doc "Return the unconstrained global scope."
  @spec global() :: t()
  def global, do: %__MODULE__{constraints: %{}}

  @doc "Build a validated scope from identity constraints."
  @spec new(:global | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(:global), do: {:ok, global()}
  def new(constraints) when is_list(constraints), do: constraints |> Map.new() |> new()

  def new(constraints) when is_map(constraints) do
    case Enum.find(constraints, &invalid_constraint?/1) do
      nil -> {:ok, %__MODULE__{constraints: constraints}}
      constraint -> {:error, {:invalid_scope_constraint, constraint}}
    end
  end

  def new(scope), do: {:error, {:invalid_scope, scope}}

  @doc "Build a scope, raising `ArgumentError` when invalid."
  @spec new!(:global | map() | keyword()) :: t()
  def new!(scope) do
    case new(scope) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "invalid runtime scope: #{inspect(reason)}"
    end
  end

  @doc "Whether every scope constraint matches the supplied context."
  @spec matches?(t(), Context.t()) :: boolean()
  def matches?(%__MODULE__{constraints: constraints}, %Context{} = context) do
    Enum.all?(constraints, fn {dimension, value} -> Map.fetch!(context, dimension) == value end)
  end

  @doc "Number of constrained identity dimensions."
  @spec specificity(t()) :: non_neg_integer()
  def specificity(%__MODULE__{constraints: constraints}), do: map_size(constraints)

  defp invalid_constraint?({dimension, value}),
    do: dimension not in Context.dimensions() or not is_binary(value) or value == ""
end
