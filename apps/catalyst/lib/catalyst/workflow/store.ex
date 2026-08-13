defmodule Catalyst.Workflow.Store do
  @moduledoc """
  Atomic file-backed storage for user-defined workflow templates.

  Each template is one JSON document named `<id>.json` below
  `Catalyst.Paths.workflows/0`. Set `config :catalyst, :workflows_dir` to
  override that directory. Built-ins are included in `fetch/1` and `list/0`
  but are immutable.
  """

  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Workflow.{Builtins, Template}

  @typedoc "Expected persistence and decoding failures."
  @type error ::
          :not_found
          | {:immutable_builtin, String.t()}
          | Template.validation_error()
          | {:read_failed, Path.t(), term()}
          | {:decode_failed, Path.t(), term()}
          | {:encode_failed, term()}
          | {:mkdir_failed, Path.t(), term()}
          | {:write_failed, Path.t(), term()}
          | {:delete_failed, Path.t(), term()}

  @doc "Directory containing user-defined workflow JSON documents."
  @spec directory() :: Path.t()
  def directory do
    Application.get_env(:catalyst, :workflows_dir) || Catalyst.Paths.workflows()
  end

  @doc "Fetch a built-in or user-defined workflow template by string id."
  @spec fetch(String.t()) :: {:ok, Template.t()} | {:error, error()}
  def fetch(id) when is_binary(id) do
    case Builtins.fetch(id) do
      {:ok, template} -> {:ok, template}
      {:error, :not_found} -> read_user(id)
    end
  end

  def fetch(id), do: {:error, {:invalid, "id", {:expected_string, id}}}

  @doc "List built-ins followed by user-defined templates sorted by id."
  @spec list() :: {:ok, [Template.t()]} | {:error, error()}
  def list do
    with {:ok, users} <- list_users() do
      {:ok, Builtins.all() ++ Enum.sort_by(users, & &1.id)}
    end
  end

  @doc """
  Validate and atomically save a user-defined template.

  Accepts a validated template or a string-keyed map. Built-in ids are
  reserved and return `{:error, {:immutable_builtin, id}}`.
  """
  @spec save(Template.t() | map()) :: {:ok, Template.t()} | {:error, error()}
  def save(%Template{} = template), do: persist(template)

  def save(attrs) do
    with {:ok, template} <- Template.new(attrs) do
      persist(template)
    end
  end

  @doc "Delete a user-defined template. A missing user file succeeds."
  @spec delete(String.t()) :: :ok | {:error, error()}
  def delete(id) when is_binary(id) do
    with :ok <- mutable(id),
         {:ok, path} <- path(id) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:delete_failed, path, reason}}
      end
    end
  end

  def delete(id), do: {:error, {:invalid, "id", {:expected_string, id}}}

  @doc "Return the user file path for a valid template id."
  @spec path(String.t()) :: {:ok, Path.t()} | {:error, Template.validation_error()}
  def path(id) do
    case Template.new(minimal(id)) do
      {:ok, _template} -> {:ok, Path.join(directory(), id <> ".json")}
      {:error, {:invalid, "id", _reason} = error} -> {:error, error}
    end
  end

  defp persist(template) do
    with :ok <- mutable(template.id),
         {:ok, path} <- path(template.id),
         {:ok, json} <- encode(template),
         :ok <- mkdir(path),
         :ok <- write(path, json) do
      {:ok, template}
    end
  end

  defp read_user(id) do
    with {:ok, path} <- path(id) do
      case File.read(path) do
        {:ok, json} -> decode(json, path)
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, {:read_failed, path, reason}}
      end
    end
  end

  defp list_users do
    case File.ls(directory()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce_while({:ok, []}, &load_entry/2)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_failed, directory(), reason}}
    end
  end

  defp load_entry(name, {:ok, acc}) do
    path = Path.join(directory(), name)

    case File.read(path) do
      {:ok, json} ->
        case decode(json, path) do
          {:ok, template} -> {:cont, {:ok, [template | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      {:error, reason} ->
        {:halt, {:error, {:read_failed, path, reason}}}
    end
  end

  defp decode(json, path) do
    with {:ok, attrs} <- decode_json(json, path),
         {:ok, template} <- Template.new(attrs),
         :ok <- filename_matches(template, path) do
      {:ok, template}
    end
  end

  defp decode_json(json, path) do
    case Jason.decode(json) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, reason} -> {:error, {:decode_failed, path, reason}}
    end
  end

  defp filename_matches(template, path) do
    case Path.basename(path, ".json") do
      id when id == template.id -> :ok
      _other -> {:error, {:decode_failed, path, :id_filename_mismatch}}
    end
  end

  defp encode(template) do
    case template |> Template.to_map() |> Jason.encode() do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp mkdir(path) do
    directory = Path.dirname(path)

    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, directory, reason}}
    end
  end

  defp write(path, json) do
    case AtomicWrite.write(path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp mutable(id) do
    case id in Builtins.ids() do
      true -> {:error, {:immutable_builtin, id}}
      false -> :ok
    end
  end

  defp minimal(id) do
    %{
      "id" => id,
      "name" => "path",
      "description" => "",
      "stages" => [
        %{
          "id" => "path",
          "name" => "path",
          "prompt" => "path",
          "preset" => "balanced",
          "tool_profile" => "read_only",
          "inputs" => ["goal"],
          "artifact" => "path",
          "timeout_ms" => 1_000,
          "max_attempts" => 1
        }
      ]
    }
  end
end
