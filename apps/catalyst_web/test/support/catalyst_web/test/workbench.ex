defmodule CatalystWeb.Test.Workbench do
  @moduledoc false

  @behaviour Catalyst.Contracts.Workbench.V1

  @impl true
  def mount(%{runtime: %{owner: "test.workbench-hanging"}}) do
    receive do
      :never -> {:error, :unexpected}
    end
  end

  def mount(context) do
    with {:ok, state, effects} <- CatalystWeb.Workbench.IDE.mount(context) do
      owner = get_in(context, [:runtime, :owner])
      target = if owner == "test.workbench-broken", do: "missing", else: "ide"

      {:ok, state |> Map.put(:output, "mounted workbench #{owner}") |> Map.put(:target, target),
       effects}
    end
  end

  @impl true
  defdelegate event(event, params, state, context), to: CatalystWeb.Workbench.IDE

  @impl true
  defdelegate info(message, state, context), to: CatalystWeb.Workbench.IDE

  @impl true
  def render_target(state), do: state.target

  @impl true
  defdelegate forms(state), to: CatalystWeb.Workbench.IDE
end
