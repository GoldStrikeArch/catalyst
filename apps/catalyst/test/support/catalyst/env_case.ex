defmodule Catalyst.EnvCase do
  @moduledoc """
  Shared helpers for core tests: exact application-environment restoration,
  bounded condition polling, and runtime-policy snapshots.

  Most core test files use bare `ExUnit.Case`; import the helpers you need
  instead of adopting a case template:

      import Catalyst.EnvCase, only: [restore_env: 2, wait_until: 1]

  The canonical implementations live in `Catalyst.Flex.Harness`; this module
  is the thin, `:catalyst`-scoped surface for the ordinary (non-flex) suite.
  """

  alias Catalyst.Flex.Harness

  @doc """
  Restore a `:catalyst` application-environment snapshot taken with
  `Application.fetch_env/2`.

  Always snapshot with `Application.fetch_env/2` (never `get_env/2`): the
  `:error`-tagged form is the only one that can distinguish an explicitly
  stored `nil` (`{:ok, nil}`) from an unset key (`:error`) — a distinction
  `Catalyst.Context.Registry` makes when reading its config.
  """
  @spec restore_env(atom(), {:ok, term()} | :error) :: :ok
  def restore_env(key, snapshot), do: Harness.restore_app_env(:catalyst, key, snapshot)

  @doc """
  Set one `:catalyst` env key and schedule exact restoration via `on_exit`.
  Returns the prior snapshot (`{:ok, value} | :error`).
  """
  @spec put_env(atom(), term()) :: {:ok, term()} | :error
  def put_env(key, value), do: Harness.with_app_env(:catalyst, key, value)

  @doc """
  Bounded monotonic poll for a condition with no observable message — OS-pid
  death, Registry-name clearance, boot-marker files, named-process restarts.

  This is the sanctioned exception to the no-`Process.sleep` test rule: use it
  only when there is nothing to `assert_receive` or monitor. Flunks with
  `message` at the deadline. The predicate may return `true`, `{:ok, value}`
  (returned), or `false`/`nil` to keep polling.
  """
  @spec wait_until((-> boolean() | nil | {:ok, term()}), non_neg_integer(), String.t()) :: term()
  def wait_until(predicate, timeout \\ 2_000, message \\ "condition did not become true") do
    Harness.wait_until!(predicate, timeout, message)
  end

  @doc "Snapshot the current runtime `{:policy, :default}` entry of a registry."
  @spec runtime_policy(module()) :: map() | nil
  def runtime_policy(Catalyst.Prompt.Registry) do
    runtime_entry(:prompt, {:policy, :default})
  end

  def runtime_policy(Catalyst.Context.Registry) do
    runtime_entry(:context_policy, :default)
  end

  @doc "Restore a snapshot taken with `runtime_policy/1` (no-op when it was absent)."
  @spec restore_runtime_policy(module(), map() | nil) :: :ok | {:ok, term()} | {:error, term()}
  def restore_runtime_policy(_registry, nil), do: :ok

  def restore_runtime_policy(registry, entry) do
    registry.register_policy(entry.value, owner: entry.owner)
  end

  defp runtime_entry(kind, key) do
    case Catalyst.Runtime.Registry.fetch(kind, key) do
      {:ok, value, owner} -> %{key: key, value: value, owner: owner}
      :error -> nil
    end
  end
end
