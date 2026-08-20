defmodule CatalystWeb.ComparisonLaneLive do
  @moduledoc """
  Independent transcript, controls, and session subscription for one comparison lane.
  """

  use CatalystWeb, :live_view

  alias Catalyst.Agent.Event
  alias Catalyst.{Comparison, Content, Message}
  alias Catalyst.Session.Server
  alias CatalystWeb.UI.MessageRenderer

  @impl true
  def mount(_params, %{"comparison_id" => comparison_id, "lane_id" => lane_id}, socket) do
    with {:ok, comparison} <- Comparison.get(comparison_id),
         {:ok, lane} <- Comparison.lane(comparison, lane_id) do
      socket =
        socket
        |> assign(
          comparison_id: comparison_id,
          lane: lane,
          session_pid: nil,
          session_ref: nil,
          session_ready?: false,
          subscribed?: false,
          running: false,
          streaming_text: "",
          streaming_thinking: "",
          tools: %{},
          message_count: 0,
          message_seq: 0,
          replayed_tail: [],
          prompt_form: to_form(%{"message" => ""}, as: :prompt),
          config_form: config_form(lane),
          model_options: model_options(),
          workflow_options: workflow_options()
        )
        |> stream_configure(:messages,
          dom_id: fn item ->
            "lane-#{lane_id}-message-#{item.id}"
          end
        )
        |> stream(:messages, [])

      case connected?(socket) do
        true -> {:ok, attach(socket)}
        false -> {:ok, socket}
      end
    else
      {:error, reason} -> {:ok, assign(socket, lane_id: lane_id, load_error: inspect(reason))}
    end
  end

  @impl true
  def handle_event("send", %{"prompt" => %{"message" => text}}, socket) do
    text = String.trim(text)

    case {text, session_pid(socket)} do
      {"", _session} ->
        {:noreply, socket}

      {_prompt, {:ok, pid}} ->
        case Server.submit(pid, text) do
          {:ok, _outcome} ->
            {:noreply, assign(socket, prompt_form: to_form(%{"message" => ""}, as: :prompt))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not submit: #{inspect(reason)}")}
        end

      {_prompt, :error} ->
        {:noreply, unavailable(socket)}
    end
  end

  def handle_event("abort", _params, socket) do
    case session_pid(socket) do
      {:ok, pid} ->
        Server.abort(pid)
        {:noreply, socket}

      :error ->
        {:noreply, unavailable(socket)}
    end
  end

  def handle_event("configure", %{"config" => params}, socket) do
    model = Catalyst.LLM.OpenAICodex.model(params["model"])
    prompt = Comparison.system_prompt(params["system_prompt"])

    changes = [
      model: model,
      provider: model.api,
      system_prompt: prompt,
      opts: [
        reasoning_effort: blank_to_nil(params["effort"]),
        workflow: blank_to_nil(params["workflow"])
      ]
    ]

    case session_pid(socket) do
      {:ok, _pid} ->
        configure_lane(socket, changes)

      :error ->
        {:noreply, unavailable(socket)}
    end
  end

  def handle_event("retry", _params, socket), do: {:noreply, attach(socket)}

  @impl true
  def handle_info({:agent_event, id, event}, socket) do
    case id == socket.assigns.lane["session_id"] do
      true -> {:noreply, apply_event(socket, event)}
      false -> {:noreply, socket}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{session_ref: ref}} = socket
      ) do
    {:noreply,
     socket
     |> assign(session_pid: nil, session_ref: nil, session_ready?: false, running: false)
     |> put_flash(:error, "Lane session stopped: #{inspect(reason)}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(%{assigns: %{load_error: error}} = assigns) do
    assigns = assign(assigns, :error, error)

    ~H"""
    <Layouts.app flash={@flash} flash_id={"flash-group-lane-#{@lane_id}"} class="contents">
      <div class="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
        Could not load lane: {@error}
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      flash_id={"flash-group-lane-#{@lane["id"]}"}
      class="contents"
    >
      <article
        id={"comparison-lane-#{@lane["id"]}"}
        data-comparison-lane
        class="flex h-full min-h-0 flex-col overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm dark:border-white/10 dark:bg-neutral-900"
      >
        <div
          :if={not @session_ready?}
          id={"lane-disconnected-#{@lane["id"]}"}
          class="flex shrink-0 items-center gap-2 border-b border-amber-200 bg-amber-50 px-3 py-2 text-[10px] text-amber-800 dark:border-amber-400/20 dark:bg-amber-400/10 dark:text-amber-200"
        >
          <span class="min-w-0 flex-1">The lane session is unavailable.</span>
          <button
            id={"lane-retry-#{@lane["id"]}"}
            type="button"
            phx-click="retry"
            class="rounded-lg bg-amber-900 px-2.5 py-1 font-semibold text-white transition hover:bg-amber-700 dark:bg-amber-200 dark:text-amber-950"
          >
            Retry
          </button>
        </div>

        <header class="shrink-0 border-b border-neutral-200 px-3 py-2.5 dark:border-white/10">
          <div class="flex items-center gap-2">
            <span class={[
              "size-2 rounded-full",
              @running && "animate-pulse bg-indigo-500",
              !@running && "bg-emerald-500"
            ]}>
            </span>
            <div class="min-w-0 flex-1">
              <h2 class="truncate text-xs font-semibold">{current_model(@config_form)}</h2>
              <p class="truncate text-[9px] text-neutral-400">
                Snapshot {String.slice(@lane["snapshot_id"], 0, 8)}
              </p>
            </div>
            <button
              :if={@running}
              id={"lane-abort-#{@lane["id"]}"}
              type="button"
              phx-click="abort"
              class="flex size-7 items-center justify-center rounded-lg text-neutral-400 transition hover:bg-rose-50 hover:text-rose-600 dark:hover:bg-rose-400/10 dark:hover:text-rose-300"
              title="Stop this lane"
            >
              <.icon name="hero-stop-solid" class="size-3.5" />
            </button>
          </div>

          <details class="mt-2">
            <summary class="cursor-pointer select-none text-[10px] font-medium text-neutral-400 transition hover:text-neutral-700 dark:hover:text-neutral-200">
              Model and system prompt
            </summary>
            <.form
              for={@config_form}
              id={"lane-config-form-#{@lane["id"]}"}
              phx-submit="configure"
              class="mt-3 grid gap-2"
            >
              <div class="grid grid-cols-2 gap-2">
                <.input
                  field={@config_form[:model]}
                  type="select"
                  id={"lane-model-#{@lane["id"]}"}
                  options={@model_options}
                  disabled={not @session_ready?}
                  container_class="m-0"
                />
                <.input
                  field={@config_form[:effort]}
                  type="select"
                  id={"lane-effort-#{@lane["id"]}"}
                  options={Enum.map(Catalyst.LLM.OpenAICodex.efforts(), &{String.capitalize(&1), &1})}
                  disabled={not @session_ready?}
                  container_class="m-0"
                />
              </div>
              <.input
                field={@config_form[:workflow]}
                type="select"
                id={"lane-workflow-#{@lane["id"]}"}
                options={@workflow_options}
                disabled={not @session_ready?}
                container_class="m-0"
              />
              <.input
                field={@config_form[:system_prompt]}
                type="textarea"
                id={"lane-system-prompt-#{@lane["id"]}"}
                rows="5"
                disabled={not @session_ready?}
                container_class="m-0"
                class="w-full resize-y rounded-xl border border-neutral-200 bg-neutral-50 px-2.5 py-2 font-mono text-[10px] leading-4 text-neutral-800 outline-none focus:border-indigo-400 focus:ring-2 focus:ring-indigo-500/10 dark:border-white/10 dark:bg-neutral-950 dark:text-neutral-200"
              />
              <button
                id={"lane-config-submit-#{@lane["id"]}"}
                type="submit"
                disabled={not @session_ready?}
                class="justify-self-end rounded-lg bg-neutral-900 px-3 py-1.5 text-[10px] font-semibold text-white transition hover:bg-neutral-700 dark:bg-white dark:text-neutral-900"
              >
                Apply
              </button>
            </.form>
          </details>
        </header>

        <div
          id={"lane-transcript-#{@lane["id"]}"}
          class="min-h-0 flex-1 overflow-y-auto px-3 py-4"
        >
          <p
            :if={@message_count == 0 and @streaming_text == ""}
            id={"lane-empty-#{@lane["id"]}"}
            class="text-xs leading-5 text-neutral-400"
          >
            This model has an independent clone and conversation.
          </p>

          <div
            id={"lane-message-stream-#{@lane["id"]}"}
            phx-update="stream"
            class="flex flex-col gap-3"
          >
            <div :for={{dom_id, %{msg: msg}} <- @streams.messages} id={dom_id}>
              {MessageRenderer.render_message(%{msg: msg})}
            </div>
          </div>

          <div
            :if={@streaming_text != "" or @streaming_thinking != ""}
            id={"lane-streaming-#{@lane["id"]}"}
            class="mt-3 rounded-xl bg-neutral-50 px-3 py-2 dark:bg-white/[0.03]"
          >
            <details :if={@streaming_thinking != ""} class="mb-2 text-[10px] text-neutral-400">
              <summary>Thinking</summary>
              <p class="mt-1 whitespace-pre-wrap italic">{@streaming_thinking}</p>
            </details>
            <p class="whitespace-pre-wrap text-sm leading-6">{@streaming_text}</p>
            <span class="mt-2 inline-block size-1.5 animate-pulse rounded-full bg-indigo-500"></span>
          </div>

          <div
            :for={{call_id, tool} <- @tools}
            id={"lane-#{@lane["id"]}-tool-#{call_id}"}
            class="mt-2 inline-flex items-center gap-2 rounded-full border border-neutral-200 px-2.5 py-1 text-[10px] text-neutral-500 dark:border-white/10"
          >
            <span class="size-2.5 animate-spin rounded-full border border-neutral-300 border-t-indigo-500">
            </span>
            {tool.name}
          </div>
        </div>

        <footer class="shrink-0 border-t border-neutral-200 p-2 dark:border-white/10">
          <.form
            for={@prompt_form}
            id={"lane-prompt-form-#{@lane["id"]}"}
            phx-submit="send"
            class="flex items-end gap-1 rounded-xl bg-neutral-50 px-2.5 py-1.5 focus-within:ring-2 focus-within:ring-indigo-500/10 dark:bg-neutral-950"
          >
            <.input
              field={@prompt_form[:message]}
              type="textarea"
              id={"lane-prompt-input-#{@lane["id"]}"}
              rows="1"
              disabled={not @session_ready?}
              placeholder={if(@running, do: "Queue for this model…", else: "Ask only this model…")}
              container_class="m-0 min-w-0 flex-1"
              class="w-full resize-none border-0 bg-transparent px-0 py-1 text-xs leading-5 text-neutral-900 outline-none placeholder:text-neutral-400 focus:ring-0 dark:text-white"
            />
            <button
              id={"lane-prompt-submit-#{@lane["id"]}"}
              type="submit"
              disabled={not @session_ready?}
              class="flex size-7 shrink-0 items-center justify-center rounded-lg text-neutral-400 transition hover:bg-neutral-200 hover:text-neutral-900 dark:hover:bg-white/10 dark:hover:text-white"
              aria-label={if(@running, do: "Queue prompt", else: "Send prompt")}
            >
              <.icon name="hero-arrow-up" class="size-3.5" />
            </button>
          </.form>
          <p class="mt-1 truncate px-1 font-mono text-[8px] text-neutral-300 dark:text-neutral-600">
            {@lane["cwd"]}
          </p>
        </footer>
      </article>
    </Layouts.app>
    """
  end

  defp attach(socket) do
    lane = socket.assigns.lane
    socket = subscribe_once(socket, lane["session_id"])

    case Comparison.ensure_session(lane) do
      {:ok, pid} ->
        snapshot = Server.state(pid)
        flush_stale_updates(snapshot.id)
        items = message_items(snapshot.messages)

        socket
        |> assign(
          session_pid: pid,
          session_ref: monitor_session(socket.assigns.session_ref, pid),
          session_ready?: true,
          running: snapshot.running,
          streaming_text: streaming(snapshot.streaming_message, Content.Text, :text),
          streaming_thinking: streaming(snapshot.streaming_message, Content.Thinking, :thinking),
          message_count: length(items),
          message_seq: length(items),
          replayed_tail: replayed_tail(snapshot.messages),
          config_form: config_form(snapshot)
        )
        |> stream(:messages, items, reset: true)

      {:error, reason} ->
        socket
        |> assign(session_pid: nil, session_ref: nil, session_ready?: false, running: false)
        |> put_flash(:error, "Could not start lane: #{inspect(reason)}")
    end
  end

  defp apply_event(socket, %Event.MessageUpdate{
         llm_event: %Catalyst.LLM.Event.TextDelta{delta: delta}
       }) do
    assign(socket, streaming_text: socket.assigns.streaming_text <> delta)
  end

  defp apply_event(socket, %Event.MessageUpdate{
         llm_event: %Catalyst.LLM.Event.ThinkingDelta{delta: delta}
       }) do
    assign(socket, streaming_thinking: socket.assigns.streaming_thinking <> delta)
  end

  defp apply_event(socket, %Event.MessageEnd{message: message}) do
    case split_replayed(socket.assigns.replayed_tail, message) do
      {:duplicate, rest} ->
        assign(socket, replayed_tail: rest)

      :new ->
        append_message(socket, message)
    end
  end

  defp apply_event(socket, %Event.ContextCompacted{replacement: messages})
       when is_list(messages) do
    items = message_items(messages)

    socket
    |> assign(
      message_seq: length(items),
      message_count: length(items),
      replayed_tail: replayed_tail(messages),
      streaming_text: "",
      streaming_thinking: "",
      tools: %{}
    )
    |> stream(:messages, items, reset: true)
  end

  defp apply_event(socket, %Event.AgentStart{}), do: assign(socket, running: true)

  defp apply_event(socket, %Event.AgentEnd{}) do
    assign(socket, running: false, tools: %{}, streaming_text: "", streaming_thinking: "")
  end

  defp apply_event(socket, %Event.ToolExecutionStart{call_id: id, name: name}) do
    assign(socket, tools: Map.put(socket.assigns.tools, id, %{name: name}))
  end

  defp apply_event(socket, %Event.ToolExecutionEnd{call_id: id}) do
    assign(socket, tools: Map.delete(socket.assigns.tools, id))
  end

  defp apply_event(socket, _event), do: socket

  defp clear_stream(%Message.Assistant{}, _value), do: ""
  defp clear_stream(_message, value), do: value

  defp append_message(socket, message) do
    sequence = socket.assigns.message_seq + 1

    socket
    |> assign(
      message_seq: sequence,
      message_count: sequence,
      replayed_tail: [],
      streaming_text: clear_stream(message, socket.assigns.streaming_text),
      streaming_thinking: clear_stream(message, socket.assigns.streaming_thinking)
    )
    |> stream_insert(:messages, %{id: sequence, msg: message})
  end

  defp message_items(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {message, id} -> %{id: id, msg: message} end)
  end

  defp streaming(nil, _module, _field), do: ""

  defp streaming(%Message.Assistant{content: content}, module, field) do
    content
    |> Enum.filter(&(Map.get(&1, :__struct__) == module))
    |> Enum.map_join("", &Map.fetch!(&1, field))
  end

  defp config_form(%{"model_id" => model, "system_prompt" => prompt} = lane) do
    to_form(
      %{
        "model" => model,
        "system_prompt" => prompt,
        "effort" => Map.get(lane, "reasoning_effort") || "medium",
        "workflow" => Map.get(lane, "workflow") || ""
      },
      as: :config
    )
  end

  defp config_form(snapshot) do
    to_form(
      %{
        "model" => snapshot.model.id,
        "system_prompt" => snapshot.system_prompt || "",
        "effort" => Keyword.get(snapshot.opts, :reasoning_effort, "medium"),
        "workflow" => Keyword.get(snapshot.opts, :workflow, "")
      },
      as: :config
    )
  end

  defp model_options do
    selected_model = Catalyst.LLM.OpenAICodex.model().id

    Catalyst.LLM.OpenAICodex.catalog_snapshot(selected_model).models
    |> Enum.map(&{&1.name, &1.id})
  end

  defp workflow_options do
    named =
      Catalyst.Workflow.Registry.list()
      |> Enum.reject(&(&1.name == :default))
      |> Enum.map(&{to_string(&1.name), to_string(&1.name)})

    [{"Default workflow", ""} | named]
  end

  defp current_model(form), do: form[:model].value

  defp configure_lane(socket, changes) do
    lane = socket.assigns.lane

    case Comparison.configure_lane(socket.assigns.comparison_id, lane["id"], changes) do
      {:ok, comparison} ->
        {:ok, configured_lane} = Comparison.lane(comparison, lane["id"])

        {:noreply,
         socket
         |> assign(lane: configured_lane, config_form: config_form(configured_lane))
         |> put_flash(:info, "Lane settings apply to the next run.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not configure lane: #{inspect(reason)}")}
    end
  end

  defp session_pid(%{assigns: %{session_ready?: true, session_pid: pid}}) when is_pid(pid),
    do: {:ok, pid}

  defp session_pid(_socket), do: :error

  defp unavailable(socket), do: put_flash(socket, :error, "Retry the lane session first.")

  defp subscribe_once(%{assigns: %{subscribed?: true}} = socket, _id), do: socket

  defp subscribe_once(socket, id) do
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    assign(socket, subscribed?: true)
  end

  defp monitor_session(nil, pid), do: Process.monitor(pid)

  defp monitor_session(ref, pid) do
    Process.demonitor(ref, [:flush])
    Process.monitor(pid)
  end

  defp flush_stale_updates(id) do
    receive do
      {:agent_event, ^id, %Event.MessageUpdate{}} -> flush_stale_updates(id)
    after
      0 -> :ok
    end
  end

  defp replayed_tail(messages), do: Enum.take(messages, -10)

  defp split_replayed([], _message), do: :new

  defp split_replayed(tail, message) do
    case Enum.split_while(tail, &(&1 != message)) do
      {_skipped, [^message | rest]} -> {:duplicate, rest}
      _not_replayed -> :new
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil
end
