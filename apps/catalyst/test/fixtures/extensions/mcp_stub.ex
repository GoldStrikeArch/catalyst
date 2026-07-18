defmodule Catalyst.Ext.McpStubState do
  @moduledoc false

  use GenServer

  @owner "mcp_stub"

  @doc false
  def start_link(initial), do: GenServer.start_link(__MODULE__, initial)

  @doc false
  def get(key), do: GenServer.call(process!(), {:get, key})

  @doc false
  def put(key, value), do: GenServer.call(process!(), {:put, key, value})

  @impl true
  def init(initial), do: {:ok, initial}

  @impl true
  def handle_call({:get, key}, _from, state), do: {:reply, Map.fetch(state, key), state}

  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, Map.put(state, key, value)}
  end

  defp process! do
    case Catalyst.Extensions.Processes.list(@owner) do
      [pid] -> pid
      _other -> raise "MCP stub process is not running"
    end
  end
end

defmodule Catalyst.Ext.McpLookupTool do
  @moduledoc false

  use Catalyst.Tools.Tool

  @impl true
  def name, do: "mcp_lookup"

  @impl true
  def description, do: "Look up a value in the process-backed MCP fixture."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{"key" => %{"type" => "string"}},
      "required" => ["key"]
    }
  end

  @impl true
  def execute(%{"key" => key}, _ctx) do
    case Catalyst.Ext.McpStubState.get(key) do
      {:ok, value} -> result("MCP #{key}=#{value}", %{key: key, value: value})
      :error -> raise "MCP key not found: #{key}"
    end
  end
end

defmodule Catalyst.Ext.McpStub do
  @moduledoc false

  use Catalyst.Extension

  @impl true
  def setup(api) do
    initial = %{"answer" => "42", "language" => "elixir"}
    {:ok, _pid} = Catalyst.ExtensionAPI.start_child(api, {Catalyst.Ext.McpStubState, initial})
    :ok
  end
end
