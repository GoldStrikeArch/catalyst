defmodule CatalystWeb.WorkflowTemplates do
  @moduledoc """
  Narrow web adapter for the workflow template store.

  The implementation is configurable with `:workflow_template_store` in the
  `:catalyst_web` application. The default is
  `Catalyst.Workflow.Store`; tests can provide a behaviour fake.
  """

  @type template :: map()
  @type attrs :: map()
  @type reason :: term()

  @callback list() :: {:ok, [template()]} | {:error, reason()}
  @callback built_ins() :: {:ok, [template()]} | {:error, reason()}
  @callback get(String.t()) :: {:ok, template()} | {:error, reason()}
  @callback create(attrs()) :: {:ok, template()} | {:error, reason()}
  @callback update(String.t(), attrs()) :: {:ok, template()} | {:error, reason()}
  @callback delete(String.t()) :: :ok | {:error, reason()}
  @callback duplicate(String.t(), attrs()) :: {:ok, template()} | {:error, reason()}
  @callback list_runs() :: [map()]
  @callback resume_run(String.t()) :: {:ok, map()} | {:error, reason()}

  @doc "Returns the configured workflow template store module."
  @spec store() :: module()
  def store do
    Application.get_env(
      :catalyst_web,
      :workflow_template_store,
      Catalyst.Workflow.Store
    )
  end

  @doc "Calls a store operation without introducing a compile-time core dependency."
  @spec call(atom(), list()) :: term()
  def call(operation, arguments \\ []) do
    module = store()

    case module == Catalyst.Workflow.Store do
      true -> core_call(operation, arguments)
      false -> external_call(module, operation, arguments)
    end
  end

  defp core_call(:list, []) do
    with {:ok, templates} <- Catalyst.Workflow.Store.list() do
      builtins = MapSet.new(Catalyst.Workflow.Builtins.ids())

      {:ok,
       templates
       |> Enum.reject(&MapSet.member?(builtins, &1.id))
       |> Enum.map(&view_template(&1, false))}
    end
  end

  defp core_call(:built_ins, []),
    do: {:ok, Enum.map(Catalyst.Workflow.Builtins.all(), &view_template(&1, true))}

  defp core_call(:get, [id]) do
    with {:ok, template} <- Catalyst.Workflow.Store.fetch(id) do
      {:ok, view_template(template, id in Catalyst.Workflow.Builtins.ids())}
    end
  end

  defp core_call(:create, [attrs]) do
    attrs
    |> Map.put("id", unique_id("workflow"))
    |> Map.put("version", 1)
    |> Map.put("stages", [default_stage()])
    |> save_view()
  end

  defp core_call(:update, [id, attrs]) do
    with {:ok, existing} <- Catalyst.Workflow.Store.fetch(id) do
      existing
      |> Catalyst.Workflow.Template.to_map()
      |> Map.merge(Map.take(attrs, ["name", "description"]))
      |> Map.put("stages", normalize_stages(attrs["stages"]))
      |> save_view()
    end
  end

  defp core_call(:delete, [id]), do: Catalyst.Workflow.Store.delete(id)

  defp core_call(:duplicate, [id, _attrs]) do
    with {:ok, existing} <- Catalyst.Workflow.Store.fetch(id) do
      existing
      |> Catalyst.Workflow.Template.to_map()
      |> Map.put("id", unique_id(id))
      |> Map.update!("name", &(&1 <> " copy"))
      |> save_view()
    end
  end

  defp core_call(:list_runs, []), do: Catalyst.WorkflowRun.list() |> Enum.take(20)

  defp core_call(:resume_run, [id]) do
    Catalyst.WorkflowRun.resume_to_parent(id)
  end

  defp core_call(_operation, _arguments), do: {:error, :store_unavailable}

  defp external_call(module, operation, arguments) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, operation, length(arguments)) do
      apply(module, operation, arguments)
    else
      _unavailable -> {:error, :store_unavailable}
    end
  end

  defp save_view(attrs) do
    with {:ok, template} <- Catalyst.Workflow.Store.save(attrs) do
      {:ok, view_template(template, false)}
    end
  end

  defp view_template(template, built_in?) do
    %{
      id: template.id,
      name: template.name,
      description: template.description,
      built_in: built_in?,
      stages: Enum.map(template.stages, &view_stage/1)
    }
  end

  defp view_stage(stage) do
    %{
      id: stage.id,
      name: stage.name,
      instructions: stage.prompt,
      preset: stage.preset,
      profile: stage.tool_profile,
      model: stage.model,
      effort: stage.reasoning_effort,
      attempts: stage.max_attempts,
      timeout_ms: stage.timeout_ms,
      inactivity_timeout_ms: stage.inactivity_timeout_ms,
      artifact: stage.artifact,
      input_artifacts: Enum.join(stage.inputs, ", ")
    }
  end

  defp normalize_stages(stages) when is_list(stages) do
    Enum.map(stages, fn stage ->
      id = stage["id"]

      %{
        "id" => id,
        "name" => stage["name"],
        "prompt" => stage["instructions"],
        "preset" => stage["preset"],
        "tool_profile" => profile(stage["profile"]),
        "model" => blank_default(stage["model"], "inherit"),
        "reasoning_effort" => blank_default(stage["effort"], "inherit"),
        "inputs" => inputs(stage["input_artifacts"]),
        "artifact" => blank_default(stage["artifact"], id),
        "inactivity_timeout_ms" =>
          blank_default(stage["inactivity_timeout_ms"], min(stage["timeout_ms"], 300_000)),
        "timeout_ms" => stage["timeout_ms"],
        "max_attempts" => stage["attempts"]
      }
    end)
  end

  defp normalize_stages(_stages), do: []

  defp default_stage do
    %{
      "id" => "research",
      "name" => "Research",
      "prompt" => "Research the goal and return a concise handoff.",
      "preset" => "research",
      "tool_profile" => "inspect",
      "model" => "inherit",
      "reasoning_effort" => "inherit",
      "inputs" => ["goal"],
      "artifact" => "research",
      "inactivity_timeout_ms" => 300_000,
      "timeout_ms" => 1_800_000,
      "max_attempts" => 3
    }
  end

  defp profile("inspect"), do: "inspect"
  defp profile(_profile), do: "coding"

  defp inputs(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["goal"]
      values -> values
    end
  end

  defp inputs(_value), do: ["goal"]
  defp blank_default(value, default) when value in [nil, ""], do: default
  defp blank_default(value, _default), do: value
  defp unique_id(prefix), do: String.slice(prefix, 0, 40) <> "-" <> Catalyst.Ids.hex(6)
end
