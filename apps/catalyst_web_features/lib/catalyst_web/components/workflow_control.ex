defmodule CatalystWeb.Components.WorkflowControl do
  @moduledoc """
  Optional workflow picker for the shell.

  Workflow state and backend-switch behavior live with the workflow feature.
  The kernel shell only hosts this registered LiveComponent and dispatches its
  explicitly requested parent actions.
  """

  use CatalystWeb, :live_component

  alias Catalyst.Session.Server
  alias Catalyst.Workflow
  alias Catalyst.Workflow.Registry, as: WorkflowRegistry
  alias CatalystWeb.ShellLive.SessionLifecycle

  @prefs_key {CatalystWeb.ShellLive, :workflow_prefs}

  @doc "Validated workflow option contributed when a new shell session starts."
  @spec session_options() :: keyword()
  def session_options do
    case selected() do
      nil ->
        []

      name ->
        case WorkflowRegistry.fetch(name) do
          {:ok, _module} -> [workflow: name]
          {:error, _reason} -> []
        end
    end
  end

  @impl true
  def update(%{shell: shell}, socket) do
    workflow = selected_workflow(shell)
    persist(workflow)
    options = workflow_options(workflow)

    {:ok,
     assign(socket,
       workflow: workflow,
       options: options,
       form: to_form(%{"workflow" => workflow || ""}),
       open: Map.get(socket.assigns, :open, false)
     )}
  end

  @impl true
  def handle_event("toggle_menu", _params, socket),
    do: {:noreply, assign(socket, open: !socket.assigns.open)}

  def handle_event("select_workflow", %{"workflow" => value}, socket) do
    send(self(), {:ui_component, __MODULE__, {:select, value}})
    {:noreply, assign(socket, open: false)}
  end

  @doc "Apply a validated workflow selection to the parent shell session."
  @spec handle_shell_action(term(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_shell_action({:select, value}, socket) do
    case normalize(value) do
      {:ok, workflow} -> apply_workflow(socket, workflow)
      {:error, reason} -> put_flash(socket, :error, workflow_error(reason))
    end
  end

  def handle_shell_action(_action, socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <div id="workflow-control-root">
      <div :if={show_picker?(@options, @workflow)} class="relative">
        <.form
          for={@form}
          id="workflow-form"
          phx-change="select_workflow"
          phx-target={@myself}
          class="sr-only"
        >
          <.input
            field={@form[:workflow]}
            id="workflow-select"
            type="select"
            options={select_options(@options)}
            container_class="m-0"
            class="h-7 rounded-md border border-edge bg-bg px-2 text-[11px] text-muted"
            title="Agent workflow (applies to the next run)"
          />
        </.form>

        <button
          id="workflow-menu"
          type="button"
          phx-click="toggle_menu"
          phx-target={@myself}
          aria-expanded={to_string(@open)}
          title="Agent workflow (applies to the next run)"
          class="flex h-6 max-w-36 items-center gap-1 rounded-md px-1.5 text-[11px] text-faint transition hover:bg-raised hover:text-ink"
        >
          <span class="truncate">{workflow_label(@workflow, @options)}</span>
          <.icon name="hero-chevron-up-down" class="size-3 shrink-0" />
        </button>

        <div
          :if={@open}
          id="workflow-menu-options"
          class="absolute bottom-8 right-0 z-50 min-w-44 rounded-lg border border-edge bg-surface p-1 shadow-xl"
        >
          <button
            :for={option <- @options}
            id={"workflow-option-#{option_value(option) || "default"}"}
            type="button"
            phx-click="select_workflow"
            phx-value-workflow={option_value(option)}
            phx-target={@myself}
            class={[
              "flex w-full rounded-md px-2 py-1 text-left text-xs transition hover:bg-raised",
              selected?(option, @workflow) && "bg-raised text-ink",
              !selected?(option, @workflow) && "text-muted"
            ]}
          >
            {option_label(option)}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp selected do
    case :persistent_term.get(@prefs_key, nil) do
      %{workflow: workflow} -> valid_workflow(workflow)
      _not_saved -> nil
    end
  end

  defp selected_workflow(%{session_pid: nil}), do: selected()

  defp selected_workflow(%{session_opts: opts}) do
    opts = opts || []

    opts
    |> Keyword.get(:workflow)
    |> valid_workflow()
  end

  defp persist(workflow), do: :persistent_term.put(@prefs_key, %{workflow: workflow})

  defp workflow_options(workflow) do
    rows = WorkflowRegistry.list()

    case workflow && Enum.any?(rows, &(&1.name == workflow)) do
      false when is_binary(workflow) ->
        rows ++ [%{name: workflow, module: nil, source: :unavailable}]

      _available_or_default ->
        rows
    end
  end

  defp normalize(""), do: {:ok, nil}

  defp normalize(name) when is_binary(name) do
    case WorkflowRegistry.fetch(name) do
      {:ok, _module} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(other), do: {:error, {:invalid_workflow, other}}

  defp apply_workflow(socket, workflow) do
    case socket.assigns.session_pid do
      pid when is_pid(pid) -> configure_workflow(socket, pid, workflow)
      _no_session -> commit(socket, workflow)
    end
  end

  defp configure_workflow(socket, pid, workflow) do
    current = valid_workflow(Keyword.get(socket.assigns.session_opts || [], :workflow))

    case external_backend_switch?(current, workflow) and backend_boundary_present?(pid) do
      true ->
        socket
        |> commit(workflow)
        |> SessionLifecycle.start()

      false ->
        configure_current(socket, pid, workflow)
    end
  end

  defp configure_current(socket, pid, workflow) do
    opts = [workflow: workflow]

    try do
      case Server.configure(pid, opts: opts) do
        :ok ->
          socket
          |> commit(workflow)
          |> assign(session_opts: merge_opts(socket.assigns.session_opts || [], opts))

        {:error, reason} ->
          put_flash(socket, :error, workflow_error(reason))
      end
    catch
      :exit, _reason -> put_flash(socket, :error, "Session is restarting — try again.")
    end
  end

  defp commit(socket, workflow) do
    persist(workflow)
    socket
  end

  defp external_backend_switch?(workflow, workflow), do: false

  defp external_backend_switch?(current, selected),
    do: external_workflow?(current) or external_workflow?(selected)

  defp external_workflow?(workflow) do
    with {:ok, selection} <- WorkflowRegistry.resolve(workflow: workflow) do
      Workflow.session_backend(selection, workflow: workflow) != :internal
    else
      {:error, _reason} -> false
    end
  end

  defp backend_boundary_present?(pid) do
    snapshot = Server.state(pid)
    snapshot.running or snapshot.messages != []
  catch
    :exit, _reason -> false
  end

  defp merge_opts(opts, changes) do
    Enum.reduce(changes, opts, fn
      {key, nil}, acc -> Keyword.delete(acc, key)
      {key, value}, acc -> Keyword.put(acc, key, value)
    end)
  end

  defp valid_workflow(name) when is_binary(name), do: name
  defp valid_workflow(_absent_or_invalid), do: nil

  defp show_picker?(options, workflow), do: length(options) > 1 or not is_nil(workflow)
  defp select_options(options), do: Enum.map(options, &{option_label(&1), option_value(&1)})
  defp option_value(%{name: :default}), do: ""
  defp option_value(%{name: name}), do: name
  defp selected?(%{name: :default}, nil), do: true
  defp selected?(%{name: name}, name), do: true
  defp selected?(_option, _workflow), do: false

  defp option_label(%{name: :default, source: source}), do: "default" <> suffix(source)
  defp option_label(%{name: name, source: source}), do: name <> suffix(source)

  defp workflow_label(nil, _options), do: "default"

  defp workflow_label(name, options) do
    case Enum.find(options, &(option_value(&1) == name)) do
      nil -> name
      option -> option_label(option)
    end
  end

  defp suffix(:builtin), do: ""
  defp suffix(:unavailable), do: " (unavailable)"
  defp suffix({:runtime, _owner, _key}), do: " (extension)"
  defp suffix({:application, _setting}), do: " (config)"
  defp suffix({:template, _metadata}), do: " (template)"
  defp suffix(_source), do: ""

  defp workflow_error({:unknown_workflow, name}) do
    "workflow #{inspect(name)} is no longer available (its extension may have been unloaded) — pick another or default"
  end

  defp workflow_error(reason), do: "could not select workflow: #{inspect(reason)}"
end
