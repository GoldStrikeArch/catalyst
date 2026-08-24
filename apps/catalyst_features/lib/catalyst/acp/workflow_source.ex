defmodule Catalyst.ACP.WorkflowSource do
  @moduledoc false

  @behaviour Catalyst.Workflow.Source

  @impl true
  def list do
    case Catalyst.ACP.Agent.list() do
      {:ok, agents} -> Enum.map(agents, &"acp/#{&1.id}")
      {:error, _reason} -> []
    end
  end

  @impl true
  def fetch("acp/" <> id) when id != "" do
    case Catalyst.ACP.Agent.fetch(id) do
      {:ok, _agent} ->
        {:ok, Catalyst.ACP.Workflow, %{source: {:application, {:acp_agent, id}}}}

      {:error, _reason} = error ->
        error
    end
  end

  def fetch(_name), do: :error
end
