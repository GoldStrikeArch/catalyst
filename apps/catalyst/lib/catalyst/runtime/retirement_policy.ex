defmodule Catalyst.Runtime.RetirementPolicy do
  @moduledoc """
  Configured deadline and timeout action for draining runtime generations.

  The default is deliberately non-destructive: an overdue generation remains
  retained and visible until its leases drain or an operator explicitly forces
  retirement. `:cancel_owners` is available for products that prefer bounded
  retirement and accept terminating processes that still own old code.
  """

  @enforce_keys [:drain_timeout, :on_timeout]
  defstruct @enforce_keys

  @type drain_timeout :: non_neg_integer() | :infinity
  @type timeout_action :: :retain | :cancel_owners
  @type t :: %__MODULE__{
          drain_timeout: drain_timeout(),
          on_timeout: timeout_action()
        }

  @default_drain_timeout :infinity
  @default_timeout_action :retain

  @doc "Read and validate the current generation-retirement policy."
  @spec current() :: t()
  def current do
    case Application.fetch_env(:catalyst, :runtime_generation_retirement) do
      {:ok, opts} ->
        new!(opts)

      :error ->
        new!(
          drain_timeout:
            Application.get_env(:catalyst, :runtime_generation_drain_timeout, :infinity),
          on_timeout: :cancel_owners
        )
    end
  end

  @doc "Build a validated retirement policy."
  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = policy), do: validate(policy)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    policy = %__MODULE__{
      drain_timeout: Map.get(opts, :drain_timeout, @default_drain_timeout),
      on_timeout: Map.get(opts, :on_timeout, @default_timeout_action)
    }

    validate(policy)
  end

  def new(opts), do: {:error, {:invalid_retirement_policy, opts}}

  @doc "Build a policy or raise for invalid application configuration."
  @spec new!(keyword() | map() | t()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid retirement policy: #{inspect(reason)}"
    end
  end

  @doc "Calculate a monotonic deadline, or return `:infinity`."
  @spec deadline(t()) :: integer() | :infinity
  def deadline(%__MODULE__{drain_timeout: :infinity}), do: :infinity

  def deadline(%__MODULE__{drain_timeout: timeout}),
    do: System.monotonic_time(:millisecond) + timeout

  defp validate(%__MODULE__{drain_timeout: timeout, on_timeout: action} = policy)
       when (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) and
              action in [:retain, :cancel_owners],
       do: {:ok, policy}

  defp validate(%__MODULE__{} = policy), do: {:error, {:invalid_retirement_policy, policy}}
end
