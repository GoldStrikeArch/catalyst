defmodule Catalyst.ACP.Agent do
  @moduledoc """
  Validated configuration for one externally installed ACP agent.
  """

  @enforce_keys [:id, :name, :command]
  defstruct [:id, :name, :command, :adapter, args: [], env: []]

  @id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @env_key ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @adapters %{"claude" => Catalyst.ACP.Claude}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          command: String.t(),
          adapter: module() | nil,
          args: [String.t()],
          env: [{String.t(), String.t()}]
        }

  @doc "Validate and build an ACP agent descriptor."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    id = value(attrs, :id)
    name = value(attrs, :name)
    command = value(attrs, :command)
    args = value(attrs, :args, [])
    env = normalize_env(value(attrs, :env, []))
    adapter = normalize_adapter(value(attrs, :adapter))

    with :ok <- nonblank(:id, id),
         :ok <- bounded_name(name),
         :ok <- nonblank(:command, command),
         :ok <- string_list(:args, args),
         {:ok, env} <- env,
         {:ok, adapter} <- adapter do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         command: command,
         args: args,
         env: env,
         adapter: adapter
       }}
    end
  end

  def new(attrs), do: {:error, {:invalid_agent, attrs}}

  @doc "Fetch a configured ACP agent by id."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, term()}
  def fetch(id) when is_binary(id) do
    with {:ok, agents} <- configured() do
      case Enum.find(agents, &(&1.id == id)) do
        %__MODULE__{} = agent -> {:ok, agent}
        nil -> {:error, {:unknown_acp_agent, id}}
      end
    end
  end

  @doc "List every validated configured ACP agent."
  @spec list() :: {:ok, [t()]} | {:error, term()}
  def list, do: configured()

  @doc "Resolve the configured command to an executable file."
  @spec executable(t()) :: {:ok, Path.t()} | {:error, term()}
  def executable(%__MODULE__{command: command}) do
    path =
      case Path.type(command) do
        :absolute -> command
        _relative -> System.find_executable(command)
      end

    case is_binary(path) and File.regular?(path) do
      true -> {:ok, path}
      false -> {:error, {:executable_not_found, command}}
    end
  end

  @doc "Build validated lifecycle `_meta` for this agent and run configuration."
  @spec session_meta(t(), map()) :: {:ok, map()} | {:error, term()}
  def session_meta(%__MODULE__{} = agent, %{opts: opts} = config) when is_list(opts) do
    with {:ok, adapter_meta} <- adapter_meta(agent.adapter, config),
         {:ok, runtime_meta} <- runtime_meta(opts),
         meta = deep_merge(adapter_meta, runtime_meta),
         {:ok, _json} <- Jason.encode(meta) do
      {:ok, meta}
    else
      {:error, %Jason.EncodeError{} = error} -> {:error, {:invalid_acp_session_meta, error}}
      {:error, _reason} = error -> error
    end
  end

  def session_meta(_agent, config), do: {:error, {:invalid_acp_session_meta_config, config}}

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp nonblank(:id, value) when is_binary(value) do
    case Regex.match?(@id, value) do
      true -> :ok
      false -> {:error, {:invalid_agent_field, :id, value}}
    end
  end

  defp nonblank(_field, value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonblank(field, value), do: {:error, {:invalid_agent_field, field, value}}

  defp bounded_name(value) when is_binary(value) and byte_size(value) in 1..200, do: :ok
  defp bounded_name(value), do: {:error, {:invalid_agent_field, :name, value}}

  defp string_list(_field, values) when is_list(values) do
    case Enum.all?(values, &is_binary/1) do
      true -> :ok
      false -> {:error, {:invalid_agent_field, :args, values}}
    end
  end

  defp string_list(field, value), do: {:error, {:invalid_agent_field, field, value}}

  defp normalize_env(env) when is_map(env), do: normalize_env(Map.to_list(env))

  defp normalize_env(env) when is_list(env) do
    case Enum.all?(env, fn {key, value} ->
           is_binary(key) and Regex.match?(@env_key, key) and is_binary(value)
         end) do
      true -> {:ok, env}
      false -> {:error, {:invalid_agent_field, :env, env}}
    end
  end

  defp normalize_env(env), do: {:error, {:invalid_agent_field, :env, env}}

  defp normalize_adapter(nil), do: {:ok, nil}

  defp normalize_adapter(adapter) when is_binary(adapter) do
    case Map.fetch(@adapters, adapter) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:invalid_agent_field, :adapter, adapter}}
    end
  end

  defp normalize_adapter(adapter) when is_atom(adapter) do
    case Code.ensure_loaded?(adapter) and function_exported?(adapter, :session_meta, 1) do
      true -> {:ok, adapter}
      false -> {:error, {:invalid_agent_field, :adapter, adapter}}
    end
  end

  defp normalize_adapter(adapter), do: {:error, {:invalid_agent_field, :adapter, adapter}}

  defp adapter_meta(nil, _config), do: {:ok, %{}}
  defp adapter_meta(adapter, config), do: adapter.session_meta(config)

  defp runtime_meta(opts) do
    case Keyword.get(opts, :acp_session_meta, %{}) do
      meta when is_map(meta) -> {:ok, meta}
      meta -> {:error, {:invalid_acp_session_meta, meta}}
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      case {left_value, right_value} do
        {%{} = left_map, %{} = right_map} -> deep_merge(left_map, right_map)
        {_left_value, right_value} -> right_value
      end
    end)
  end

  defp configured do
    case Application.get_env(:catalyst, :acp_agents, []) do
      agents when is_list(agents) ->
        with {:ok, agents} <- build_all(agents),
             :ok <- unique_ids(agents) do
          {:ok, agents}
        end

      invalid ->
        {:error, {:invalid_acp_agents, invalid}}
    end
  end

  defp build_all(agents) do
    Enum.reduce_while(agents, {:ok, []}, fn attrs, {:ok, acc} ->
      case new(attrs) do
        {:ok, agent} -> {:cont, {:ok, [agent | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, Enum.reverse(agents)}
      {:error, _reason} = error -> error
    end
  end

  defp unique_ids(agents) do
    ids = Enum.map(agents, & &1.id)

    case Enum.uniq(ids) == ids do
      true -> :ok
      false -> {:error, :duplicate_acp_agent_id}
    end
  end
end
