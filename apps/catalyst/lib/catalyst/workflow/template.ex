defmodule Catalyst.Workflow.Template do
  @moduledoc """
  Validated user-defined, linear workflow templates.

  Each stage runs as a fresh child and may consume only the original `"goal"`
  or artifacts emitted by earlier stages. All persisted identifiers remain
  strings; decoding never creates atoms.

  A snapshot is a JSON-safe map containing the complete template and its
  SHA-256 digest. Consumers can persist it with a session so later edits to the
  source template cannot change an in-flight or resumed workflow.
  """

  alias Catalyst.Workflow.Stage

  @derive Jason.Encoder
  @enforce_keys [:version, :id, :name, :description, :stages]
  defstruct @enforce_keys

  @version 1
  @max_stages 16
  @max_name_bytes 120
  @max_description_bytes 2_000
  @max_prompt_bytes 16_384
  @max_inputs 16
  @timeout_range 1_000..3_600_000
  @attempt_range 1..5
  @id_regex ~r/\A[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?\z/
  @presets ~w(research implementation code_review repair security_review verification)
  @tool_profiles Catalyst.Tools.Profiles.known()
  @reasoning_efforts ~w(inherit low medium high xhigh max ultra)

  @typedoc "A validated workflow template."
  @type t :: %__MODULE__{
          version: 1,
          id: String.t(),
          name: String.t(),
          description: String.t(),
          stages: [Stage.t()]
        }

  @typedoc "A JSON-safe immutable template snapshot."
  @type snapshot :: %{
          required(String.t()) => String.t() | map()
        }

  @typedoc "A field-level validation failure."
  @type validation_error :: {:invalid, String.t(), term()}

  @doc "Supported model/execution preset names."
  @spec presets() :: [String.t()]
  def presets, do: @presets

  @doc "Supported stage tool-profile names."
  @spec tool_profiles() :: [String.t()]
  def tool_profiles, do: @tool_profiles

  @doc """
  Validate and construct a template from a string-keyed JSON map.

  Unknown keys are ignored. Expected failures return
  `{:error, {:invalid, field_path, reason}}`.
  """
  @spec new(term()) :: {:ok, t()} | {:error, validation_error()}
  def new(%{} = attrs) do
    with :ok <- version(attrs["version"]),
         {:ok, id} <- id(attrs["id"], "id"),
         {:ok, name} <- text(attrs["name"], "name", @max_name_bytes, false),
         {:ok, description} <-
           text(attrs["description"], "description", @max_description_bytes, true),
         {:ok, stages} <- stages(attrs["stages"]) do
      {:ok,
       %__MODULE__{
         version: @version,
         id: id,
         name: name,
         description: description,
         stages: stages
       }}
    end
  end

  def new(value), do: invalid("template", {:expected_object, value})

  @doc "Convert a validated template to its stable string-keyed wire map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = template) do
    %{
      "version" => template.version,
      "id" => template.id,
      "name" => template.name,
      "description" => template.description,
      "stages" => Enum.map(template.stages, &stage_map/1)
    }
  end

  @doc "Return the lowercase SHA-256 digest of a validated template."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = template) do
    template
    |> to_map()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Capture a complete JSON-safe template snapshot and digest."
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{} = template) do
    %{"digest" => digest(template), "template" => to_map(template)}
  end

  @doc "Decode a snapshot and reject malformed or digest-mismatched content."
  @spec from_snapshot(term()) ::
          {:ok, t()} | {:error, validation_error() | {:digest_mismatch, String.t(), String.t()}}
  def from_snapshot(%{"digest" => expected, "template" => attrs}) when is_binary(expected) do
    with {:ok, template} <- new(attrs),
         actual = digest(template),
         :ok <- matching_digest(expected, actual) do
      {:ok, template}
    end
  end

  def from_snapshot(value), do: invalid("snapshot", {:invalid_shape, value})

  defp stages(stages) when is_list(stages) and stages != [] and length(stages) <= @max_stages do
    stages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new(["goal"]), MapSet.new()}, &stage/2)
    |> case do
      {:ok, decoded, _available, _ids} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp stages([]), do: invalid("stages", :empty)

  defp stages(stages) when is_list(stages),
    do: invalid("stages", {:too_many, @max_stages})

  defp stages(value), do: invalid("stages", {:expected_list, value})

  defp stage({attrs, index}, {:ok, acc, available, ids}) when is_map(attrs) do
    path = "stages[#{index}]"

    with {:ok, stage_id} <- id(attrs["id"], path <> ".id"),
         :ok <- unique(stage_id, ids, path <> ".id"),
         {:ok, name} <- text(attrs["name"], path <> ".name", @max_name_bytes, false),
         {:ok, prompt} <- text(attrs["prompt"], path <> ".prompt", @max_prompt_bytes, false),
         {:ok, preset} <- member(attrs["preset"], @presets, path <> ".preset"),
         {:ok, tool_profile} <-
           member(attrs["tool_profile"], @tool_profiles, path <> ".tool_profile"),
         {:ok, model} <- optional_model(attrs["model"], path <> ".model"),
         {:ok, reasoning_effort} <-
           member(
             Map.get(attrs, "reasoning_effort", "inherit"),
             @reasoning_efforts,
             path <> ".reasoning_effort"
           ),
         {:ok, inputs} <- inputs(attrs["inputs"], available, path <> ".inputs"),
         {:ok, artifact} <- id(attrs["artifact"], path <> ".artifact"),
         :ok <- unique(artifact, available, path <> ".artifact"),
         {:ok, inactivity_timeout_ms} <-
           integer(
             Map.get(attrs, "inactivity_timeout_ms", 300_000),
             @timeout_range,
             path <> ".inactivity_timeout_ms"
           ),
         {:ok, timeout_ms} <-
           integer(attrs["timeout_ms"], @timeout_range, path <> ".timeout_ms"),
         {:ok, max_attempts} <-
           integer(attrs["max_attempts"], @attempt_range, path <> ".max_attempts") do
      stage = %Stage{
        id: stage_id,
        name: name,
        prompt: prompt,
        preset: preset,
        tool_profile: tool_profile,
        model: model,
        reasoning_effort: reasoning_effort,
        inputs: inputs,
        artifact: artifact,
        inactivity_timeout_ms: inactivity_timeout_ms,
        timeout_ms: timeout_ms,
        max_attempts: max_attempts
      }

      {:cont, {:ok, [stage | acc], MapSet.put(available, artifact), MapSet.put(ids, stage_id)}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp stage({_value, index}, _acc),
    do: {:halt, invalid("stages[#{index}]", :expected_object)}

  defp inputs(inputs, available, path)
       when is_list(inputs) and inputs != [] and length(inputs) <= @max_inputs do
    inputs
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn input, {:ok, acc, seen} ->
      cond do
        not is_binary(input) ->
          {:halt, invalid(path, {:invalid_reference, input})}

        not MapSet.member?(available, input) ->
          {:halt, invalid(path, {:unavailable_artifact, input})}

        MapSet.member?(seen, input) ->
          {:halt, invalid(path, {:duplicate_reference, input})}

        true ->
          {:cont, {:ok, [input | acc], MapSet.put(seen, input)}}
      end
    end)
    |> case do
      {:ok, decoded, _seen} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp inputs([], _available, path), do: invalid(path, :empty)
  defp inputs(inputs, _available, path) when is_list(inputs), do: invalid(path, :too_many)
  defp inputs(value, _available, path), do: invalid(path, {:expected_list, value})

  defp version(nil), do: :ok
  defp version(@version), do: :ok
  defp version(value), do: invalid("version", {:unsupported, value})

  defp id(value, path) when is_binary(value) do
    case Regex.match?(@id_regex, value) do
      true -> {:ok, value}
      false -> invalid(path, :invalid_id)
    end
  end

  defp id(_value, path), do: invalid(path, :invalid_id)

  defp text(value, path, max, blank?) when is_binary(value) do
    cond do
      not String.valid?(value) -> invalid(path, :invalid_utf8)
      byte_size(value) > max -> invalid(path, {:too_long, max})
      not blank? and String.trim(value) == "" -> invalid(path, :blank)
      true -> {:ok, value}
    end
  end

  defp text(value, path, _max, _blank?), do: invalid(path, {:expected_string, value})

  defp member(value, allowed, path) when is_binary(value) do
    case value in allowed do
      true -> {:ok, value}
      false -> invalid(path, {:unknown, value})
    end
  end

  defp member(value, _allowed, path), do: invalid(path, {:expected_string, value})

  defp optional_model(nil, _path), do: {:ok, "inherit"}
  defp optional_model("inherit", _path), do: {:ok, "inherit"}

  defp optional_model(value, path) do
    text(value, path, @max_name_bytes, false)
  end

  defp integer(value, first..last//1, path) do
    case is_integer(value) and value >= first and value <= last do
      true -> {:ok, value}
      false -> invalid(path, {:outside_range, first, last, value})
    end
  end

  defp unique(value, values, path) do
    case MapSet.member?(values, value) do
      true -> invalid(path, {:duplicate, value})
      false -> :ok
    end
  end

  defp matching_digest(value, value), do: :ok

  defp matching_digest(expected, actual),
    do: {:error, {:digest_mismatch, expected, actual}}

  defp stage_map(%Stage{} = stage) do
    %{
      "id" => stage.id,
      "name" => stage.name,
      "prompt" => stage.prompt,
      "preset" => stage.preset,
      "tool_profile" => stage.tool_profile,
      "model" => stage.model,
      "reasoning_effort" => stage.reasoning_effort,
      "inputs" => stage.inputs,
      "artifact" => stage.artifact,
      "inactivity_timeout_ms" => stage.inactivity_timeout_ms,
      "timeout_ms" => stage.timeout_ms,
      "max_attempts" => stage.max_attempts
    }
  end

  defp invalid(path, reason), do: {:error, {:invalid, path, reason}}
end
