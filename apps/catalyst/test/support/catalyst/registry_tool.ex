defmodule Catalyst.Test.RegistryTool do
  @moduledoc false

  @doc false
  def name, do: observe(:name, "registry_fixture")

  @doc false
  def description, do: observe(:description, "Registry cache fixture")

  @doc false
  def parameters, do: observe(:parameters, %{"type" => "object"})

  @doc false
  def execute(_args, _ctx), do: :ok

  defp observe(callback, value) do
    case :persistent_term.get({__MODULE__, :observer}, nil) do
      pid when is_pid(pid) -> send(pid, {:metadata_callback, callback})
      nil -> :ok
    end

    value
  end
end
