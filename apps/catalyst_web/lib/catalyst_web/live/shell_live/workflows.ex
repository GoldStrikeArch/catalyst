defmodule CatalystWeb.ShellLive.Workflows do
  @moduledoc """
  Workflow-template page state transitions.

  This module only translates form parameters and maintains LiveView streams.
  Validation and persistence remain owned by the configured template store.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 1]
  import Phoenix.LiveView, only: [put_flash: 3, stream: 4]

  alias CatalystWeb.WorkflowTemplates

  @presets %{
    "plan" => {"Plan", "Understand the request and produce an implementation plan."},
    "implement" => {"Implement", "Implement the approved changes with focused tests."},
    "review" => {"Review", "Review the result, address issues, and summarize verification."},
    "verify" => {"Verify", "Run validation and report any remaining gaps."}
  }

  @doc "Initializes workflow forms and streams."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    socket
    |> assign(
      workflow_template: :none,
      workflow_form: template_form(),
      workflow_error: nil,
      workflow_presets: preset_options()
    )
    |> stream(:workflow_templates, [], dom_id: &"workflow-template-#{id(&1)}")
    |> stream(:workflow_stages, [], dom_id: &"workflow-stage-#{id(&1)}")
  end

  @doc "Loads templates when the workflow page becomes active."
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    with {:ok, custom} <- WorkflowTemplates.call(:list),
         {:ok, built_ins} <- WorkflowTemplates.call(:built_ins) do
      templates =
        Enum.map(built_ins, &Map.put(&1, :built_in, true)) ++
          Enum.map(custom, &Map.put_new(&1, :built_in, false))

      socket
      |> assign(:workflow_error, nil)
      |> stream(:workflow_templates, templates, reset: true)
    else
      {:error, reason} ->
        assign(socket, :workflow_error, error_message(reason))
    end
  end

  @doc "Selects a template for inspection or editing."
  @spec select(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def select(socket, id) do
    case WorkflowTemplates.call(:get, [id]) do
      {:ok, template} -> put_template(socket, template)
      {:error, reason} -> put_flash(socket, :error, error_message(reason))
    end
  end

  @doc "Creates a blank editable template."
  @spec create(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def create(socket) do
    case WorkflowTemplates.call(:create, [
           %{"name" => "Untitled workflow", "description" => "", "stages" => []}
         ]) do
      {:ok, template} -> socket |> refresh() |> put_template(template)
      {:error, reason} -> put_flash(socket, :error, error_message(reason))
    end
  end

  @doc "Clones an immutable built-in template."
  @spec clone(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def clone(socket, id) do
    case WorkflowTemplates.call(:duplicate, [id, %{}]) do
      {:ok, template} -> socket |> refresh() |> put_template(template)
      {:error, reason} -> put_flash(socket, :error, error_message(reason))
    end
  end

  @doc "Adds a preset stage to the current draft."
  @spec add_stage(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def add_stage(%{assigns: %{workflow_template: template}} = socket, preset)
      when is_map(template) do
    case Map.fetch(@presets, preset) do
      {:ok, {name, instructions}} ->
        current_stages = stages(template)

        stage = %{
          id: "draft-#{length(current_stages) + 1}",
          name: name,
          instructions: instructions,
          profile: "default",
          model: "",
          effort: "medium",
          attempts: 1,
          timeout_ms: 300_000,
          input_artifacts: ""
        }

        current_stages
        |> Kernel.++([stage])
        |> then(&put_stages(socket, template, &1))

      :error ->
        put_flash(socket, :error, "Unknown stage preset.")
    end
  end

  def add_stage(socket, _preset), do: socket

  @doc "Updates a stage draft from submitted form parameters."
  @spec update_stage(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def update_stage(%{assigns: %{workflow_template: template}} = socket, stage_id, params) do
    updated =
      template
      |> stages()
      |> Enum.map(fn stage ->
        case to_string(id(stage)) == stage_id do
          true -> Map.merge(stage, normalize_stage(params))
          false -> stage
        end
      end)

    put_stages(socket, template, updated)
  end

  @doc "Moves a stage one position up or down."
  @spec move_stage(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def move_stage(%{assigns: %{workflow_template: template}} = socket, stage_id, direction) do
    reordered = move(stages(template), stage_id, direction)
    put_stages(socket, template, reordered)
  end

  @doc "Deletes a stage from the draft."
  @spec delete_stage(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def delete_stage(%{assigns: %{workflow_template: template}} = socket, stage_id) do
    remaining = Enum.reject(stages(template), &(to_string(id(&1)) == stage_id))
    put_stages(socket, template, remaining)
  end

  @doc "Validates and saves the complete current draft through the store."
  @spec save(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def save(%{assigns: %{workflow_template: template}} = socket, params) when is_map(template) do
    attrs =
      params
      |> Map.take(["name", "description"])
      |> Map.put("stages", Enum.map(stages(template), &persisted_stage/1))

    case WorkflowTemplates.call(:update, [to_string(id(template)), attrs]) do
      {:ok, saved} ->
        socket
        |> refresh()
        |> put_template(saved)
        |> put_flash(:info, "Workflow saved.")

      {:error, reason} ->
        socket
        |> assign(:workflow_form, to_form(params))
        |> put_flash(:error, error_message(reason))
    end
  end

  def save(socket, _params), do: socket

  @doc "Deletes the selected custom template."
  @spec delete(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def delete(%{assigns: %{workflow_template: template}} = socket) when is_map(template) do
    case WorkflowTemplates.call(:delete, [to_string(id(template))]) do
      :ok ->
        socket
        |> assign(workflow_template: :none, workflow_form: template_form())
        |> stream(:workflow_stages, [], reset: true)
        |> refresh()
        |> put_flash(:info, "Workflow deleted.")

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  def delete(socket), do: socket

  defp put_template(socket, template) do
    socket
    |> assign(
      workflow_template: template,
      workflow_form:
        template_form(%{
          "name" => value(template, :name, ""),
          "description" => value(template, :description, "")
        })
    )
    |> stream(:workflow_stages, Enum.map(stages(template), &stage_view/1), reset: true)
  end

  defp put_stages(socket, template, stages) do
    updated = Map.put(template, :stages, stages)

    socket
    |> assign(:workflow_template, updated)
    |> stream(:workflow_stages, Enum.map(stages, &stage_view/1), reset: true)
  end

  defp stage_view(stage) do
    stage
    |> Map.put(:id, id(stage))
    |> Map.put(:form, stage |> stringify() |> to_form())
  end

  defp normalize_stage(params) do
    params
    |> Map.take(~w(name instructions profile model effort attempts timeout_ms input_artifacts))
    |> Map.update("attempts", 1, &integer(&1, 1))
    |> Map.update("timeout_ms", 300_000, &integer(&1, 300_000))
    |> atomize_known()
  end

  defp persisted_stage(stage), do: stage |> Map.drop([:form]) |> stringify()

  defp move(stages, stage_id, direction) do
    index = Enum.find_index(stages, &(to_string(id(&1)) == stage_id))
    target = target_index(index, direction, length(stages))

    case is_integer(index) and is_integer(target) do
      true ->
        stages
        |> List.replace_at(index, Enum.at(stages, target))
        |> List.replace_at(target, Enum.at(stages, index))

      false ->
        stages
    end
  end

  defp target_index(index, "up", _length) when is_integer(index) and index > 0, do: index - 1

  defp target_index(index, "down", length) when is_integer(index) and index < length - 1,
    do: index + 1

  defp target_index(_index, _direction, _length), do: nil

  defp stages(template), do: value(template, :stages, [])
  defp id(value), do: value(value, :id, "")
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp template_form(params \\ %{"name" => "", "description" => ""}), do: to_form(params)
  defp preset_options, do: Enum.map(@presets, fn {key, {name, _}} -> {name, key} end)

  defp integer(value, default) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _invalid -> default
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp atomize_known(map) do
    Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp error_message(:store_unavailable), do: "Workflow template storage is not available yet."
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(reason), do: "Workflow action failed: #{inspect(reason)}"
end
