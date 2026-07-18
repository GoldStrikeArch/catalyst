defmodule CatalystWeb.UI.TableOwner do
  @moduledoc """
  Stable owner of the UI extension ETS table.

  Keeping table ownership separate from `CatalystWeb.UI.Registry` lets the
  registry process restart without discarding accepted extension contributions.
  """

  use GenServer

  @table :catalyst_ui

  @doc "Start the singleton UI table owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
      _table -> :ok
    end

    {:ok, :ok}
  end
end
