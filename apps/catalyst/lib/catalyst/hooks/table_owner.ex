defmodule Catalyst.Hooks.TableOwner do
  @moduledoc """
  Crash-isolated owner of the `:catalyst_hooks` ETS table.

  When `Catalyst.Hooks` created the table in its own `init/1`, a Hooks crash
  destroyed every registered handler with it: `before_tool_call` gates silently
  failed open and nothing re-registered extension hooks until their files were
  reloaded. Owning the table here — in a process whose init creates the table
  and then does nothing else, so it has nothing to crash on — keeps handlers
  alive across Hooks restarts.

  Invariant: the table is `:public` only so that a restarted `Catalyst.Hooks`
  can keep using it; ALL writes still flow through the `Catalyst.Hooks`
  GenServer (register/unregister/clear are GenServer calls — that's what
  serializes the `seq` ordering). No other process may write to it.

  Must be started immediately before `Catalyst.Hooks` in the supervision tree.
  """

  use GenServer

  @table :catalyst_hooks

  @doc "Start the singleton ETS table owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Catalyst.Hooks.invalidate_runtime_generation()

    # Idempotent: a restart of this process after a supervisor-level restart
    # (or a test that created the table first) must not crash on a clash.
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
      _table -> :ok
    end

    {:ok, :ok}
  end
end
