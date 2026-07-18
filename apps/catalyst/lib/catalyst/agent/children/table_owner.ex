defmodule Catalyst.Agent.Children.TableOwner do
  @moduledoc """
  Owns the public child-accounting ETS table independently of the coordinator.

  Keeping table ownership outside `Catalyst.Agent.Children` lets that GenServer
  restart and rebuild monitors without forgetting live watchdog/child leases.
  """

  use GenServer

  @doc "Start the table owner. Tests may provide an alternate table and name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      registered -> GenServer.start_link(__MODULE__, opts, name: registered)
    end
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, Catalyst.Agent.Children.table())
    ensure_table(table)
    {:ok, table}
  end

  defp ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :public,
          :bag,
          read_concurrency: true,
          write_concurrency: true
        ])

      _existing ->
        table
    end
  end
end
