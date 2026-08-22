defmodule Catalyst.Runtime.Context do
  @moduledoc """
  Identity dimensions available while resolving runtime claims.

  Dimensions are deliberately explicit. Catalyst does not currently assign all
  of them, but reserving their stable names avoids treating a filesystem path as
  a permanent workspace identity.
  """

  @dimensions [
    :product_id,
    :user_id,
    :workspace_id,
    :project_id,
    :session_id,
    :run_id,
    :experiment_id
  ]

  defstruct @dimensions ++ [metadata: %{}]

  @type dimension ::
          :product_id
          | :user_id
          | :workspace_id
          | :project_id
          | :session_id
          | :run_id
          | :experiment_id

  @type t :: %__MODULE__{
          product_id: String.t() | nil,
          user_id: String.t() | nil,
          workspace_id: String.t() | nil,
          project_id: String.t() | nil,
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          experiment_id: String.t() | nil,
          metadata: map()
        }

  @doc "Build a runtime context from a map or keyword list."
  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = context), do: context
  def new(context) when is_list(context), do: context |> Map.new() |> new()

  def new(context) when is_map(context) do
    values = Map.take(context, @dimensions ++ [:metadata])
    struct!(__MODULE__, values)
  end

  @doc "Build a host resolution context with the active product identity filled in."
  @spec host(t() | map() | keyword()) :: t()
  def host(context) do
    case new(context) do
      %__MODULE__{product_id: nil} = context -> %{context | product_id: Catalyst.Product.id()}
      %__MODULE__{} = context -> context
    end
  end

  @doc "The supported identity dimensions."
  @spec dimensions() :: [dimension()]
  def dimensions, do: @dimensions
end
