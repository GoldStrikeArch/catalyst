defmodule CatalystWeb.ShellLive.Workflows do
  @moduledoc """
  Workflow-template page state transitions.

  This module only translates form parameters and maintains LiveView streams.
  Validation and persistence remain owned by the configured template store.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 1]
  import Phoenix.LiveView, only: [put_flash: 3, stream: 4, stream_insert: 3]

  alias CatalystWeb.WorkflowTemplates

  @presets %{
    "research" => {"Research", "Research the goal and produce a concise handoff.", "inspect"},
    "implementation" => {"Implement", "Implement the goal with focused tests.", "coding"},
    "code_review" => {"Code review", "Independently review the current changes.", "inspect"},
    "repair" => {"Repair", "Verify and address actionable review findings.", "coding"},
    "security_review" =>
      {"Security review", "Independently perform an adversarial security review.", "inspect"},
    "verification" => {"Verify", "Run required checks and summarize the result.", "coding"}
  }

  @doc "Initializes workflow forms and streams."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    socket
    |> assign(
      workflow_template: :none,
      workflow_selected_stage: :none,
      workflow_form: template_form(),
      workflow_error: nil,
      workflow_presets: preset_options(),
      workflow_runs_empty?: true
    )
    |> stream(:workflow_templates, [], dom_id: &"workflow-template-#{id(&1)}")
    |> stream(:workflow_stages, [], dom_id: &"workflow-stage-#{id(&1)}")
    |> stream(:workflow_runs, [], dom_id: &"workflow-run-#{&1["id"]}")
  end

  @doc "Loads templates when the workflow page becomes active."
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    with {:ok, custom} <- WorkflowTemplates.call(:list),
         {:ok, built_ins} <- WorkflowTemplates.call(:built_ins) do
      templates =
        Enum.map(built_ins, &Map.put(&1, :built_in, true)) ++
          Enum.map(custom, &Map.put_new(&1, :built_in, false))

      runs = runs()

      socket
      |> assign(:workflow_error, nil)
      |> assign(:workflow_runs_empty?, runs == [])
      |> stream(:workflow_templates, templates, reset: true)
      |> stream(:workflow_runs, runs, reset: true)
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

  @doc "Explicitly resumes an interrupted durable workflow run."
  @spec resume_run(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def resume_run(socket, id) do
    with :ok <- Catalyst.WorkflowRun.subscribe(id),
         {:ok, _run} <- WorkflowTemplates.call(:resume_run, [id]) do
      socket
      |> refresh_runs()
      |> put_flash(:info, "Workflow run resumed.")
    else
      {:error, reason} -> put_flash(socket, :error, error_message(reason))
    end
  end

  @doc "Refreshes durable run status after a terminal workflow event."
  @spec run_event(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def run_event(socket, %{"type" => status, "checkpoint" => checkpoint})
      when status in ["completed", "failed", "cancelled"] do
    socket
    |> assign(:workflow_runs_empty?, false)
    |> stream_insert(:workflow_runs, checkpoint)
  end

  def run_event(socket, %{"type" => status})
      when status in ["completed", "failed", "cancelled"] do
    refresh_runs(socket)
  end

  def run_event(socket, _event), do: socket

  defp refresh_runs(socket) do
    runs = runs()

    socket
    |> assign(:workflow_runs_empty?, runs == [])
    |> stream(:workflow_runs, runs, reset: true)
  end

  defp runs do
    case WorkflowTemplates.call(:list_runs) do
      runs when is_list(runs) -> runs
      _unavailable -> []
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
      {:ok, {name, instructions, profile}} ->
        current_stages = stages(template)
        stage_id = next_stage_id(current_stages)

        stage = %{
          id: stage_id,
          name: name,
          instructions: instructions,
          preset: preset,
          profile: profile,
          model: "inherit",
          effort: "inherit",
          attempts: 3,
          timeout_ms: 1_800_000,
          inactivity_timeout_ms: 300_000,
          artifact: stage_id,
          input_artifacts: "goal"
        }

        current_stages
        |> Kernel.++([stage])
        |> then(&put_stages(socket, template, &1))
        |> select_stage(stage_id)

      :error ->
        put_flash(socket, :error, "Unknown stage preset.")
    end
  end

  def add_stage(socket, _preset), do: socket

  @doc "Selects a compact stage node for metadata inspection or editing."
  @spec select_stage(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def select_stage(%{assigns: %{workflow_template: template}} = socket, stage_id)
      when is_map(template) do
    case Enum.find(stages(template), &(to_string(id(&1)) == stage_id)) do
      nil ->
        socket

      stage ->
        socket
        |> assign(:workflow_selected_stage, stage_view(stage))
        |> stream(:workflow_stages, stage_views(stages(template)), reset: true)
    end
  end

  def select_stage(socket, _stage_id), do: socket

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
        |> assign(
          workflow_template: :none,
          workflow_selected_stage: :none,
          workflow_form: template_form()
        )
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
      workflow_selected_stage: :none,
      workflow_form:
        template_form(%{
          "name" => value(template, :name, ""),
          "description" => value(template, :description, "")
        })
    )
    |> stream(:workflow_stages, stage_views(stages(template)), reset: true)
  end

  defp put_stages(socket, template, stages) do
    updated = Map.put(template, :stages, stages)
    selected_stage = selected_stage(stages, socket.assigns.workflow_selected_stage)

    socket
    |> assign(workflow_template: updated, workflow_selected_stage: selected_stage)
    |> stream(:workflow_stages, stage_views(stages), reset: true)
  end

  defp stage_view(stage, position \\ nil) do
    stage
    |> Map.put(:id, id(stage))
    |> Map.put(:form, stage |> stringify() |> to_form())
    |> maybe_put_position(position)
  end

  defp stage_views(stages) do
    stages
    |> Enum.with_index(1)
    |> Enum.map(fn {stage, position} -> stage_view(stage, position) end)
  end

  defp maybe_put_position(stage, nil), do: stage
  defp maybe_put_position(stage, position), do: Map.put(stage, :position, position)

  defp selected_stage(_stages, :none), do: :none

  defp selected_stage(stages, selected) do
    case Enum.find(stages, &(id(&1) == id(selected))) do
      nil -> :none
      stage -> stage_view(stage)
    end
  end

  defp normalize_stage(params) do
    params
    |> Map.take(~w(name instructions profile model effort attempts timeout_ms input_artifacts))
    |> Map.update("attempts", 1, &integer(&1, 1))
    |> Map.update("timeout_ms", 300_000, &integer(&1, 300_000))
    |> atomize_known()
  end

  defp persisted_stage(stage), do: stage |> Map.drop([:form]) |> stringify()

  defp next_stage_id(stages) do
    used = MapSet.new(stages, &(id(&1) |> to_string()))

    Enum.find_value(1..(length(stages) + 1), fn index ->
      candidate = "draft-#{index}"
      candidate not in used && candidate
    end)
  end

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
  defp preset_options, do: Enum.map(@presets, fn {key, {name, _, _}} -> {name, key} end)

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
