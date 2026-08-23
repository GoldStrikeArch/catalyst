defmodule CatalystWeb.WorkbenchHostLive do
  @moduledoc "Stable socket/effect host for a mount-pinned replaceable workbench."

  use CatalystWeb, :live_view

  alias Catalyst.{Content, Message, Resources}
  alias Catalyst.LLM.Models
  alias Catalyst.Session.{Catalog, Manager, Server}
  alias CatalystWeb.FileSearch
  alias CatalystWeb.ShellLive.SessionLifecycle
  alias CatalystWeb.ShellLive.Threads
  alias CatalystWeb.UI.ImageStore
  alias CatalystWeb.UI.SafeRender
  alias CatalystWeb.Workbench
  alias CatalystWeb.Workbench.{IDEView, RenderTarget, Workspace}

  @max_projected_messages 200
  @max_projected_transcript_bytes 8_388_608
  @max_projected_message_characters 250_000

  @impl true
  def mount(params, session, socket) do
    slot = Map.get(params, "workbench", "default")

    socket =
      socket
      |> assign(
        page_title: page_title(slot),
        workbench_handle: nil,
        workbench_state: nil,
        workbench_context: nil,
        workbench_target: nil,
        workbench_metadata: %{},
        workbench_error: nil,
        workbench_forms: %{},
        workbench_effects: MapSet.new(),
        workbench_session_id: nil,
        workbench_session_pid: nil,
        workbench_session_ref: nil,
        workbench_session_provider: nil
      )
      |> allow_upload(:image,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 4,
        max_file_size: 5_000_000,
        auto_upload: true
      )

    case mount_workbench(slot, session, socket) do
      {:ok, socket, effects} -> {:ok, maybe_start_effects(socket, effects)}
      {:error, reason, socket} -> {:ok, assign(socket, :workbench_error, reason)}
    end
  end

  @impl true
  def handle_event("workbench:host:remount", _params, socket) do
    {:noreply, remount_workbench(socket)}
  end

  def handle_event("workbench:host:cancel-image", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("workbench:chat:submit", params, socket) do
    case uploading_images?(socket) do
      true ->
        {:noreply, put_flash(socket, :error, "Wait for image uploads to finish.")}

      false ->
        case consume_prompt_images(socket) do
          {:ok, images} ->
            params = Map.put(params, "attachments", images)
            {:noreply, transition(socket, &Workbench.event(&1, "chat:submit", params, &2, &3))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, prompt_image_error(reason))}
        end
    end
  end

  def handle_event("workbench:" <> event, params, socket) do
    {:noreply, transition(socket, &Workbench.event(&1, event, params, &2, &3))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:workbench_effect, request_id},
        {:ok, {:session_opened, id, pid, provider_id}},
        socket
      ) do
    socket =
      socket
      |> finish_effect(request_id)
      |> attach_session(id, pid, provider_id)

    result =
      with {:ok, snapshot} <- session_state(pid) do
        provider_id = provider_id || provider_for_model(snapshot.model)
        {:ok, project_session(id, snapshot, provider_id, true)}
      end

    socket =
      case result do
        {:ok, %{selected_model: %{provider: provider_id}}} ->
          assign(socket, :workbench_session_provider, provider_id)

        _error_or_unknown_provider ->
          socket
      end

    message = {:effect_result, request_id, result}
    {:noreply, transition(socket, &Workbench.info(&1, message, &2, &3))}
  end

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
  def handle_info(
        {:agent_event, id, event},
        %{assigns: %{workbench_session_id: id}} = socket
      ) do
    message = {:session_event, id, event}
    {:noreply, transition(socket, &Workbench.info(&1, message, &2, &3))}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{
          assigns: %{
            workbench_session_id: id,
            workbench_session_pid: pid,
            workbench_session_ref: ref
          }
        } = socket
      )
      when is_binary(id) do
    message = {:session_exit, id, reason}

    socket =
      assign(socket,
        workbench_session_id: nil,
        workbench_session_pid: nil,
        workbench_session_ref: nil,
        workbench_session_provider: nil
      )

    {:noreply, transition(socket, &Workbench.info(&1, message, &2, &3))}
  end

  def handle_info({:workbench_info, message}, socket) do
    {:noreply, transition(socket, &Workbench.info(&1, message, &2, &3))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    _socket = detach_session(socket)

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

  defp mount_workbench(slot, session, socket) do
    with {:ok, workspace} <- workspace(session),
         runtime_context = %{
           metadata: %{workspace_path: workspace, workbench_slot: slot}
         },
         {:ok, handle} <- Workbench.resolve_and_pin(runtime_context, self()) do
      context = %{
        workspace: workspace,
        slot: slot,
        runtime: Workbench.metadata(handle.resolution)
      }

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
    slot = socket.assigns.workbench_context.slot
    runtime_context = %{metadata: %{workspace_path: workspace, workbench_slot: slot}}

    with {:ok, capsule} <- Workbench.snapshot(old_handle, old_state),
         {:ok, new_handle} <- Workbench.resolve_and_pin(runtime_context, self()),
         new_context = %{
           workspace: workspace,
           slot: slot,
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

  defp start_effect({:workspace, :search, request_id, query}, socket) do
    workspace = workspace!(socket)
    resource = %{type: :workspace, path: workspace, query: query}

    start_brokered_effect(socket, request_id, :search, resource, fn ->
      {:ok, %{query: query, results: FileSearch.search(workspace, query)}}
    end)
  end

  defp start_effect({:command, :run, request_id, command}, socket) do
    workspace = workspace!(socket)
    resource = %{type: :process, cwd: workspace, command: command}

    start_brokered_effect(socket, request_id, :run_command, resource, fn ->
      Workspace.run_command(workspace, command)
    end)
  end

  defp start_effect({:models, :list, request_id}, socket) do
    result =
      with {:ok, models} <- Models.list() do
        {:ok, Enum.map(models, &project_model/1)}
      end

    deliver_effect_result(socket, request_id, result)
  end

  defp start_effect({:session, :open, request_id}, socket) do
    workspace = workspace!(socket)
    start_effect_task(socket, request_id, fn -> open_initial_session(workspace) end)
  end

  defp start_effect({:session, :open, request_id, settings}, socket) do
    workspace = Map.get(settings, "cwd", workspace!(socket))
    start_effect_task(socket, request_id, fn -> open_new_session(workspace, settings) end)
  end

  defp start_effect({:session, :submit, request_id, session_id, prompt}, socket) do
    result =
      with {:ok, pid} <- current_session(socket, session_id) do
        input = session_prompt(prompt)
        maybe_title_session(session_id, input)

        with {:ok, status} <- Server.submit(pid, input) do
          {:ok, %{status: status, threads: project_threads(session_id)}}
        end
      end

    deliver_effect_result(socket, request_id, result)
  end

  defp start_effect({:session, :abort, request_id, session_id}, socket) do
    result =
      with {:ok, pid} <- current_session(socket, session_id) do
        Server.abort(pid)
      end

    deliver_effect_result(socket, request_id, result)
  end

  defp start_effect({:session, :snapshot, request_id, session_id}, socket) do
    result =
      with {:ok, pid} <- current_session(socket, session_id) do
        {:ok,
         project_session(
           session_id,
           Server.state(pid),
           socket.assigns.workbench_session_provider
         )}
      end

    deliver_effect_result(socket, request_id, result)
  end

  defp start_effect({:session, :list, request_id, session_id}, socket) do
    deliver_effect_result(socket, request_id, {:ok, project_threads(session_id)})
  end

  defp start_effect({:session, :attach, request_id, session_id}, socket) do
    start_effect_task(socket, request_id, fn -> open_cataloged_session(session_id) end)
  end

  defp start_effect({:session, :close, request_id, session_id}, socket) do
    socket =
      case socket.assigns.workbench_session_id == session_id do
        true -> detach_session(socket)
        false -> socket
      end

    result =
      with :ok <- Manager.stop(session_id),
           :ok <- Catalog.forget(session_id) do
        :ok
      end

    deliver_effect_result(socket, request_id, result)
  end

  defp start_effect({:session, :configure, request_id, session_id, settings}, socket) do
    with {:ok, pid} <- current_session(socket, session_id),
         {:ok, {provider_id, model}} <- resolve_model(settings),
         :ok <- Server.configure(pid, model: model) do
      socket = assign(socket, :workbench_session_provider, provider_id)
      snapshot = project_session(session_id, Server.state(pid), provider_id)
      deliver_effect_result(socket, request_id, {:ok, snapshot})
    else
      {:error, _reason} = error -> deliver_effect_result(socket, request_id, error)
    end
  end

  defp start_effect({:client, :push, event, payload}, socket),
    do: push_event(socket, event, payload)

  defp start_effect({:navigate, path}, socket), do: push_navigate(socket, to: path)

  defp start_effect_task(socket, request_id, task) do
    case MapSet.member?(socket.assigns.workbench_effects, request_id) do
      true ->
        put_flash(socket, :error, "That workbench operation is already running.")

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

  defp deliver_effect_result(socket, request_id, result) do
    message = {:effect_result, request_id, result}
    transition(socket, &Workbench.info(&1, message, &2, &3))
  end

  defp open_initial_session(workspace) do
    case Application.get_env(:catalyst_web, :reattach_sessions, true) do
      true ->
        case Catalog.most_recent() do
          {:ok, %{id: id}} -> open_cataloged_session(id)
          {:error, _reason} -> open_new_session(workspace, %{})
        end

      false ->
        open_new_session(workspace, %{})
    end
  end

  defp open_new_session(workspace, settings) do
    with {:ok, {provider_id, model}} <- resolve_model(settings),
         {:ok, %{id: id, pid: pid}} <- Manager.start_session(cwd: workspace, model: model) do
      _result = Catalog.remember(id, workspace)
      {:session_opened, id, pid, provider_id}
    end
  end

  defp open_cataloged_session(id) do
    with {:ok, %{cwd: cwd}} <- Catalog.lookup(id) do
      case Manager.whereis(id) do
        {:ok, pid} ->
          {:session_opened, id, pid, nil}

        :error ->
          with {:ok, {provider_id, model}} <- resolve_model(%{}),
               {:ok, %{id: ^id, pid: pid}} <-
                 Manager.start_session(id: id, cwd: cwd, model: model) do
            {:session_opened, id, pid, provider_id}
          end
      end
    end
  end

  defp resolve_model(%{"provider" => provider_id, "model" => model_id}),
    do: Models.resolve(provider_id, model_id)

  defp resolve_model(_settings) do
    with {:ok, %{provider_id: provider_id, model_id: model_id}} <- Models.default_selection() do
      Models.resolve(provider_id, model_id)
    end
  end

  defp attach_session(socket, id, pid, provider_id) do
    socket = detach_session(socket)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assign(socket,
      workbench_session_id: id,
      workbench_session_pid: pid,
      workbench_session_ref: Process.monitor(pid),
      workbench_session_provider: provider_id
    )
  end

  defp detach_session(socket) do
    unsubscribe_session(socket.assigns.workbench_session_id)
    demonitor_session(socket.assigns.workbench_session_ref)

    assign(socket,
      workbench_session_id: nil,
      workbench_session_pid: nil,
      workbench_session_ref: nil,
      workbench_session_provider: nil
    )
  end

  defp unsubscribe_session(id) when is_binary(id),
    do: Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))

  defp unsubscribe_session(_missing), do: :ok

  defp demonitor_session(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor_session(_missing), do: true

  defp current_session(
         %{assigns: %{workbench_session_id: id, workbench_session_pid: pid}},
         id
       )
       when is_binary(id) and is_pid(pid),
       do: {:ok, pid}

  defp current_session(_socket, session_id),
    do: {:error, {:workbench_session_unavailable, session_id}}

  defp session_state(pid) when is_pid(pid) do
    try do
      {:ok, Server.state(pid)}
    catch
      :exit, reason -> {:error, {:workbench_session_unavailable, reason}}
    end
  end

  defp project_session(id, snapshot, provider_id, include_threads? \\ false) do
    {messages, messages_truncated} =
      project_messages(snapshot.messages, snapshot.streaming_message)

    projection = %{
      session_id: id,
      workspace: snapshot.cwd,
      messages: messages,
      messages_truncated: messages_truncated,
      running: snapshot.running,
      error: snapshot.error_message,
      selected_model: selected_model(provider_id, snapshot.model)
    }

    case include_threads? do
      true -> Map.put(projection, :threads, project_threads(id))
      false -> projection
    end
  end

  defp project_messages(messages, streaming_message) do
    entries =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {message, index} -> {message, "message-#{index}"} end)
      |> maybe_append_streaming(streaming_message)

    {projected, bytes, count} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, 0}, fn {message, id}, {projected, bytes, count} ->
        projection = message |> project_message(id) |> bound_message_projection()
        projection_bytes = encoded_size(projection)

        case count < @max_projected_messages and
               bytes + projection_bytes <= @max_projected_transcript_bytes do
          true ->
            {:cont, {[projection | projected], bytes + projection_bytes, count + 1}}

          false ->
            {:halt, {projected, bytes, count}}
        end
      end)

    _bounded_bytes = bytes
    {projected, max(length(entries) - count, 0)}
  end

  defp maybe_append_streaming(entries, nil), do: entries

  defp maybe_append_streaming(entries, message),
    do: entries ++ [{message, "message-streaming"}]

  defp bound_message_projection(projection) do
    case encoded_size(projection) <= @max_projected_transcript_bytes do
      true ->
        projection

      false ->
        projection
        |> Map.put(:text, truncate_projection_text(projection.text))
        |> Map.put(:blocks, [
          %{
            type: "text",
            text:
              truncate_projection_text(projection.text) <>
                "\n\n[Structured content was truncated in the live projection.]"
          }
        ])
    end
  end

  defp truncate_projection_text(text) when is_binary(text) do
    case String.length(text) > @max_projected_message_characters do
      true ->
        String.slice(text, 0, @max_projected_message_characters) <> "\n\n[Message truncated.]"

      false ->
        text
    end
  end

  defp encoded_size(term) do
    term
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp project_message(%Message.User{} = message, id),
    do: message_projection(id, "user", message.content, nil, %{})

  defp project_message(%Message.Assistant{} = message, id),
    do: message_projection(id, "assistant", message.content, message.error_message, %{})

  defp project_message(%Message.ToolResult{} = message, id),
    do:
      message_projection(id, "tool", message.content, tool_error(message), %{
        tool_name: message.tool_name,
        tool_error: message.is_error
      })

  defp message_projection(id, role, content, error, metadata) do
    Map.merge(
      %{
        id: id,
        role: role,
        text: Content.text_of(content),
        blocks: Enum.map(content, &project_block/1),
        error: error
      },
      metadata
    )
  end

  defp project_block(%Content.Text{text: text}), do: %{type: "text", text: text}

  defp project_block(%Content.Thinking{thinking: thinking}),
    do: %{type: "thinking", text: thinking}

  defp project_block(%Content.ToolCall{id: id, name: name, arguments: arguments}) do
    %{type: "tool_call", id: id, name: name, arguments: arguments}
  end

  defp project_block(%Content.Image{data: data, mime_type: mime_type}) do
    case ImageStore.register(data, mime_type) do
      {:ok, digest} -> %{type: "image", src: "/image/#{digest}", mime_type: mime_type}
      :error -> %{type: "image", src: nil, mime_type: mime_type}
    end
  end

  defp tool_error(%Message.ToolResult{is_error: true, tool_name: name}),
    do: "#{name} failed"

  defp tool_error(%Message.ToolResult{}), do: nil

  defp project_model(entry) do
    provider_id = Map.get(entry, :provider, "unknown")

    %{
      id: entry.id,
      name: Map.get(entry, :name, entry.id),
      provider: provider_id,
      provider_name: Map.get(entry, :provider_name, provider_id),
      efforts: Map.get(entry, :efforts, []),
      default_effort: Map.get(entry, :default_effort),
      fast: Map.get(entry, :fast?, false)
    }
  end

  defp selected_model(provider_id, %{id: model_id}) when is_binary(provider_id),
    do: %{provider: provider_id, model: model_id}

  defp selected_model(_provider_id, _model), do: nil

  defp provider_for_model(%{id: model_id, api: api}) do
    case Models.list() do
      {:ok, models} ->
        case Enum.find(models, &(Map.get(&1, :id) == model_id and Map.get(&1, :api) == api)) do
          entry when is_map(entry) -> Map.get(entry, :provider)
          _missing -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp provider_for_model(_model), do: nil

  defp project_threads(current_id) do
    keep_ids =
      [current_id | Enum.map(Manager.list_live(), &elem(&1, 0))]
      |> Enum.filter(&is_binary/1)

    case Catalog.forget_untitled(keep_ids) do
      {:ok, entries} ->
        entries |> ensure_current_thread(current_id) |> Threads.project(current_id)

      {:error, _reason} ->
        %{projects: []}
    end
  end

  defp ensure_current_thread(entries, current_id) when is_binary(current_id) do
    case Enum.any?(entries, &(&1.id == current_id)) do
      true ->
        entries

      false ->
        case Manager.whereis(current_id) do
          {:ok, pid} ->
            snapshot = Server.state(pid)
            [%{id: current_id, cwd: snapshot.cwd, title: nil} | entries]

          :error ->
            entries
        end
    end
  end

  defp ensure_current_thread(entries, _current_id), do: entries

  defp session_prompt(prompt) when is_binary(prompt), do: prompt

  defp session_prompt(%{"text" => text, "images" => images}) do
    text_blocks =
      case text do
        "" -> []
        text -> [%Content.Text{text: text}]
      end

    image_blocks =
      Enum.map(images, fn %{"data" => data, "mime_type" => mime_type} ->
        %Content.Image{data: data, mime_type: mime_type}
      end)

    text_blocks ++ image_blocks
  end

  defp maybe_title_session(id, input) do
    text =
      case input do
        text when is_binary(text) -> text
        content when is_list(content) -> Content.text_of(content)
      end

    _result = Catalog.put_title_if_blank(id, Catalog.title_from_text(text))
    :ok
  end

  defp uploading_images?(socket) do
    Enum.any?(socket.assigns.uploads.image.entries, &(not &1.done?))
  end

  defp consume_prompt_images(socket) do
    results =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        {:ok, prompt_image(path, entry)}
      end)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, image} -> image end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_image(path, entry) do
    with {:ok, mime_type} <- prompt_image_mime(entry),
         {:ok, data} <- File.read(path) do
      {:ok, %{"data" => Base.encode64(data), "mime_type" => mime_type}}
    else
      {:error, reason} -> {:error, {:invalid_prompt_image, entry.client_name, reason}}
    end
  end

  defp prompt_image_mime(%{client_type: type})
       when type in ~w(image/png image/jpeg image/gif image/webp),
       do: {:ok, type}

  defp prompt_image_mime(%{client_type: "image/jpg"}), do: {:ok, "image/jpeg"}

  defp prompt_image_mime(%{client_name: name}) do
    case name |> Path.extname() |> String.downcase() do
      ".png" -> {:ok, "image/png"}
      extension when extension in [".jpg", ".jpeg"] -> {:ok, "image/jpeg"}
      ".gif" -> {:ok, "image/gif"}
      ".webp" -> {:ok, "image/webp"}
      _unsupported -> {:error, :unsupported_media_type}
    end
  end

  defp prompt_image_error({:invalid_prompt_image, name, reason}),
    do: "Could not attach #{name}: #{inspect(reason)}"

  defp prompt_image_error(reason), do: "Could not attach that image: #{inspect(reason)}"

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
      Map.take(assigns, [:workbench_state, :workbench_forms, :workbench_metadata, :uploads])

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

  defp page_title("chat"), do: "Catalyst Chat"
  defp page_title(_slot), do: "Catalyst IDE"

  defp target_id(%RenderTarget{id: {module, function}}),
    do: "#{inspect(module)}.#{function}/1"

  defp target_id(%RenderTarget{id: id}), do: id
  defp target_id(_unmounted), do: nil
end
