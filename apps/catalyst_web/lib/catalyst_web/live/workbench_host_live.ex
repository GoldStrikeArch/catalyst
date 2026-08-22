defmodule CatalystWeb.WorkbenchHostLive do
  @moduledoc "Stable socket/effect host for a mount-pinned replaceable workbench."

  use CatalystWeb, :live_view

  alias Catalyst.Resources
  alias CatalystWeb.ShellLive.SessionLifecycle
  alias CatalystWeb.UI.SafeRender
  alias CatalystWeb.Workbench
  alias CatalystWeb.Workbench.{IDEView, RenderTarget, Workspace}

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        page_title: "Catalyst IDE",
        workbench_handle: nil,
        workbench_state: nil,
        workbench_context: nil,
        workbench_target: nil,
        workbench_metadata: %{},
        workbench_error: nil,
        workbench_forms: %{},
        workbench_effects: MapSet.new()
      )

    case mount_workbench(session, socket) do
      {:ok, socket, effects} -> {:ok, maybe_start_effects(socket, effects)}
      {:error, reason, socket} -> {:ok, assign(socket, :workbench_error, reason)}
    end
  end

  @impl true
  def handle_event("workbench:host:remount", _params, socket) do
    {:noreply, remount_workbench(socket)}
  end

  def handle_event("workbench:" <> event, params, socket) do
    {:noreply, transition(socket, &Workbench.event(&1, event, params, &2, &3))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:workbench_effect, request_id}, {:ok, result}, socket) do
    message = {:effect_result, request_id, result}

    socket = finish_effect(socket, request_id)
    {:noreply, transition(socket, &Workbench.info(&1, message, &2, &3))}
  end

  def handle_async({:workbench_effect, request_id}, {:exit, reason}, socket) do
    message = {:effect_result, request_id, {:error, {:task_exit, reason}}}

    socket = finish_effect(socket, request_id)
    {:noreply, transition(socket, &Workbench.info(&1, message, &2, &3))}
  end

  @impl true
  def handle_info({:workbench_info, message}, socket) do
    {:noreply, transition(socket, &Workbench.info(&1, message, &2, &3))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :workbench_handle) do
      %Catalyst.Runtime.Handle{} = handle -> Workbench.release(handle)
      _unmounted -> :ok
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} flash_id="workbench-flash-group">
      <div
        id="workbench-host"
        data-workbench-owner={owner(@workbench_metadata)}
        data-workbench-generation={@workbench_metadata[:generation]}
        data-workbench-target={target_id(@workbench_target)}
      >
        <%= case @workbench_error do %>
          <% nil -> %>
            {render_workbench(assigns)}
          <% reason -> %>
            {error_view(assign(assigns, :reason, reason))}
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp mount_workbench(session, socket) do
    with {:ok, workspace} <- workspace(session),
         runtime_context = %{metadata: %{workspace_path: workspace}},
         {:ok, handle} <- Workbench.resolve_and_pin(runtime_context, self()) do
      context = %{workspace: workspace, runtime: Workbench.metadata(handle.resolution)}
      finish_mount(handle, context, socket)
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  defp finish_mount(handle, context, socket) do
    with {:ok, state, effects} <- Workbench.mount(handle, context),
         {:ok, target} <- pin_target(handle, state),
         {:ok, forms} <- Workbench.forms(handle, state) do
      socket =
        assign(socket,
          workbench_handle: handle,
          workbench_state: state,
          workbench_context: context,
          workbench_target: target,
          workbench_metadata: context.runtime,
          workbench_forms: to_forms(forms)
        )

      {:ok, socket, effects}
    else
      {:error, reason} ->
        :ok = Workbench.release(handle)
        {:error, reason, socket}
    end
  end

  defp transition(%{assigns: %{workbench_handle: nil}} = socket, _callback), do: socket

  defp transition(socket, callback) do
    handle = socket.assigns.workbench_handle
    state = socket.assigns.workbench_state
    context = socket.assigns.workbench_context

    case callback.(handle, state, context) do
      {:ok, next_state, effects} -> apply_transition(socket, next_state, effects)
      {:error, reason} -> assign(socket, :workbench_error, reason)
    end
  end

  defp apply_transition(socket, state, effects) do
    handle = socket.assigns.workbench_handle

    with :ok <- validate_pinned_target(handle, state, socket.assigns.workbench_target),
         {:ok, forms} <- Workbench.forms(handle, state) do
      socket
      |> assign(
        workbench_state: state,
        workbench_forms: to_forms(forms),
        workbench_error: nil
      )
      |> maybe_start_effects(effects)
    else
      {:error, reason} -> assign(socket, :workbench_error, reason)
    end
  end

  defp remount_workbench(%{assigns: %{workbench_handle: nil}} = socket), do: socket

  defp remount_workbench(socket) do
    case MapSet.size(socket.assigns.workbench_effects) do
      0 -> perform_remount(socket)
      _active -> put_flash(socket, :error, "Wait for current workbench tasks before applying it.")
    end
  end

  defp perform_remount(socket) do
    old_handle = socket.assigns.workbench_handle
    old_state = socket.assigns.workbench_state
    workspace = workspace!(socket)
    runtime_context = %{metadata: %{workspace_path: workspace}}

    with {:ok, capsule} <- Workbench.snapshot(old_handle, old_state),
         {:ok, new_handle} <- Workbench.resolve_and_pin(runtime_context, self()),
         new_context = %{
           workspace: workspace,
           runtime: Workbench.metadata(new_handle.resolution)
         } do
      restore_remount(socket, old_handle, new_handle, capsule, new_context)
    else
      {:error, reason} -> remount_error(socket, reason)
    end
  end

  defp restore_remount(socket, old_handle, new_handle, capsule, context) do
    with {:ok, state, effects} <- Workbench.restore(new_handle, capsule, context),
         {:ok, target} <- pin_target(new_handle, state),
         {:ok, forms} <- Workbench.forms(new_handle, state) do
      socket =
        assign(socket,
          workbench_handle: new_handle,
          workbench_state: state,
          workbench_context: context,
          workbench_target: target,
          workbench_metadata: context.runtime,
          workbench_forms: to_forms(forms),
          workbench_error: nil
        )

      :ok = Workbench.release(old_handle)
      maybe_start_effects(socket, effects)
    else
      {:error, reason} ->
        :ok = Workbench.release(new_handle)
        remount_error(socket, reason)
    end
  end

  defp remount_error(socket, reason) do
    put_flash(socket, :error, "Could not apply active workbench: #{inspect(reason)}")
  end

  defp pin_target(handle, state) do
    with {:ok, id} <- Workbench.render_target(handle, state),
         {:ok, target} <- RenderTarget.capture(id, handle) do
      {:ok, target}
    end
  end

  defp validate_pinned_target(handle, state, target) do
    with {:ok, id} <- Workbench.render_target(handle, state) do
      RenderTarget.validate_id(target, id)
    end
  end

  defp to_forms(forms),
    do: Map.new(forms, fn {name, values} -> {name, to_form(values, as: name)} end)

  defp maybe_start_effects(socket, effects) do
    case connected?(socket) do
      true -> Enum.reduce(effects, socket, &start_effect/2)
      false -> socket
    end
  end

  defp start_effect({:workspace, :list, request_id}, socket) do
    workspace = workspace!(socket)

    start_brokered_effect(socket, request_id, :list, %{type: :workspace, path: workspace}, fn ->
      Workspace.list_files(workspace)
    end)
  end

  defp start_effect({:workspace, :read, request_id, path}, socket) do
    workspace = workspace!(socket)

    start_brokered_effect(socket, request_id, :read, file_resource(workspace, path), fn ->
      Workspace.read_file(workspace, path)
    end)
  end

  defp start_effect({:workspace, :write, request_id, path, content}, socket) do
    workspace = workspace!(socket)

    start_brokered_effect(socket, request_id, :write, file_resource(workspace, path), fn ->
      Workspace.write_file(workspace, path, content)
    end)
  end

  defp start_effect({:command, :run, request_id, command}, socket) do
    workspace = workspace!(socket)
    resource = %{type: :process, cwd: workspace, command: command}

    start_brokered_effect(socket, request_id, :run_command, resource, fn ->
      Workspace.run_command(workspace, command)
    end)
  end

  defp start_effect({:navigate, path}, socket), do: push_navigate(socket, to: path)

  defp start_effect_task(socket, request_id, task) do
    case MapSet.member?(socket.assigns.workbench_effects, request_id) do
      true ->
        assign(socket, :workbench_error, {:duplicate_active_workbench_effect, request_id})

      false ->
        socket
        |> assign(:workbench_effects, MapSet.put(socket.assigns.workbench_effects, request_id))
        |> start_async({:workbench_effect, request_id}, task)
    end
  end

  defp start_brokered_effect(socket, request_id, operation, resource, task) do
    principal = %{
      type: :human,
      surface: :workbench,
      owner: socket.assigns.workbench_metadata[:owner]
    }

    action = %{type: :workbench_effect, operation: operation, request_id: request_id}
    context = %{cwd: workspace!(socket), runtime: socket.assigns.workbench_metadata}

    start_effect_task(socket, request_id, fn ->
      case Resources.request(action, principal, resource, context, task) do
        {:ok, result} -> result
        {:error, _reason} = error -> error
      end
    end)
  end

  defp file_resource(workspace, path),
    do: %{type: :filesystem, workspace: workspace, path: path}

  defp finish_effect(socket, request_id) do
    assign(
      socket,
      :workbench_effects,
      MapSet.delete(socket.assigns.workbench_effects, request_id)
    )
  end

  defp workspace!(socket), do: socket.assigns.workbench_context.workspace

  defp workspace(session) do
    requested = Map.get(session, "workbench_workspace") || SessionLifecycle.default_cwd()

    case Workspace.root(requested) do
      {:ok, root} -> {:ok, root}
      {:error, _reason} -> Workspace.root(SessionLifecycle.default_cwd())
    end
  end

  defp render_workbench(
         %{
           workbench_target: %RenderTarget{module: IDEView, function: :render},
           workbench_metadata: %{owner: :builtin}
         } = assigns
       ),
       do: IDEView.render(assigns)

  defp render_workbench(
         %{workbench_target: %RenderTarget{module: module, function: function}} = assigns
       ) do
    view_assigns =
      Map.take(assigns, [:workbench_state, :workbench_forms, :workbench_metadata])

    SafeRender.forced_iodata(
      fn -> apply(module, function, [view_assigns]) end,
      "workbench #{inspect(module)}.#{function}",
      fn -> error_view(assign(assigns, :reason, :workbench_render_failed)) end
    )
  end

  defp error_view(assigns) do
    ~H"""
    <main
      id="workbench-error"
      class="flex min-h-screen items-center justify-center bg-bg px-6 text-ink"
    >
      <div class="w-full max-w-lg rounded-2xl border border-danger/30 bg-surface p-8 shadow-xl">
        <div class="mb-4 flex size-11 items-center justify-center rounded-xl bg-danger/10 text-danger">
          <.icon name="hero-exclamation-triangle" class="size-6" />
        </div>
        <h1 class="text-lg font-semibold">Workbench unavailable</h1>
        <p class="mt-2 text-sm leading-6 text-muted">
          The selected workbench could not be mounted safely. The existing chat shell is still available.
        </p>
        <pre
          id="workbench-error-reason"
          class="mt-4 overflow-auto rounded-lg bg-raised p-3 text-xs text-danger"
        >{inspect(@reason)}</pre>
        <.link
          id="workbench-error-chat-link"
          navigate={~p"/"}
          class="mt-5 inline-flex items-center gap-2 rounded-lg bg-accent px-4 py-2 text-sm font-semibold text-white"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" /> Return to agent chat
        </.link>
      </div>
    </main>
    """
  end

  defp owner(metadata), do: metadata |> Map.get(:owner, :unavailable) |> to_string()

  defp target_id(%RenderTarget{id: {module, function}}),
    do: "#{inspect(module)}.#{function}/1"

  defp target_id(%RenderTarget{id: id}), do: id
  defp target_id(_unmounted), do: nil
end
