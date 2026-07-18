defmodule Catalyst.Ext.UIEverythingState do
  @moduledoc false

  use GenServer

  @owner "ui_everything"

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{})

  @doc false
  def bump(key) do
    with {:ok, pid} <- process() do
      GenServer.call(pid, {:bump, key})
    end
  end

  @doc false
  def snapshot do
    with {:ok, pid} <- process() do
      {:ok, GenServer.call(pid, :snapshot)}
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:bump, key}, _from, state) do
    state = Map.update(state, key, 1, &(&1 + 1))
    {:reply, {:ok, Map.fetch!(state, key)}, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  defp process do
    case Catalyst.Extensions.Processes.list(@owner) do
      [pid] when is_pid(pid) -> {:ok, pid}
      _other -> {:error, :not_running}
    end
  end
end

defmodule Catalyst.Ext.UIEverythingTool do
  @moduledoc false

  use Catalyst.Tools.Tool

  @impl true
  def name, do: "flex_everything"

  @impl true
  def description, do: "Exercise the process-backed tool supplied by the UI-everything fixture."

  @impl true
  def parameters,
    do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    {:ok, count} = Catalyst.Ext.UIEverythingState.bump(:tool)
    result("FLEX-EVERYTHING-TOOL count=#{count}", %{ui_everything: true, count: count})
  end
end

defmodule Catalyst.Ext.UIEverythingProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message}
  alias Catalyst.LLM.Event

  @impl true
  def stream(model, context, _opts, sink) do
    {:ok, _count} = Catalyst.Ext.UIEverythingState.bump(:provider)
    record_prompt(context.system_prompt)

    assistant =
      case latest_tool_result(context.messages) do
        %Message.ToolResult{} = result -> final_message(model, result)
        nil -> tool_message(model)
      end

    emit(assistant.content, sink)
    {:ok, assistant}
  end

  defp record_prompt("FLEX-EVERYTHING-SYS" <> _rest) do
    Catalyst.Ext.UIEverythingState.bump(:prompt)
  end

  defp record_prompt(_prompt), do: :ok

  defp latest_tool_result(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn
      %Message.ToolResult{tool_name: "flex_everything"} -> true
      _message -> false
    end)
  end

  defp tool_message(model) do
    %Message.Assistant{
      content: [
        %Content.Text{text: "[ui-everything-provider] calling the owned tool"},
        %Content.ToolCall{id: "ui_everything_call", name: "flex_everything", arguments: %{}}
      ],
      api: "ui-everything",
      provider: "ui-everything",
      model: model.id,
      stop_reason: :tool_use,
      timestamp: Message.now()
    }
  end

  defp final_message(model, result) do
    text = "[ui-everything-provider] final " <> Content.text_of(result.content)

    %Message.Assistant{
      content: Content.text(text),
      api: "ui-everything",
      provider: "ui-everything",
      model: model.id,
      stop_reason: :stop,
      timestamp: Message.now()
    }
  end

  defp emit(blocks, sink) do
    Enum.each(blocks, fn
      %Content.Text{text: text} ->
        sink.(%Event.TextStart{})
        sink.(%Event.TextDelta{delta: text})
        sink.(%Event.TextEnd{})

      %Content.ToolCall{id: id, name: name, arguments: arguments} ->
        sink.(%Event.ToolCallStart{id: id, name: name})
        sink.(%Event.ToolCallEnd{id: id, name: name, arguments: arguments})

      _block ->
        :ok
    end)
  end
end

defmodule Catalyst.Ext.UIEverythingLoop do
  @moduledoc false

  @doc false
  def run(prompts, context, config, emit) do
    Catalyst.Agent.Loop.run(prompts, context, config, emit)
  end
end

defmodule Catalyst.Ext.UIEverything do
  @moduledoc false

  use Catalyst.Extension
  use CatalystWeb, :html

  alias Catalyst.{Content, Message}
  alias Catalyst.ExtensionAPI
  alias Catalyst.LLM.ProviderConfig

  @impl true
  def metadata do
    %{
      name: "UI Everything",
      description: "Every owner-aware runtime category in one fixture"
    }
  end

  @impl true
  def setup(api) do
    {:ok, _pid} = ExtensionAPI.start_child(api, {Catalyst.Ext.UIEverythingState, []})

    :ok =
      ExtensionAPI.register_provider(
        api,
        "ui-everything",
        %ProviderConfig{module: Catalyst.Ext.UIEverythingProvider, name: "UI Everything"}
      )

    :ok = ExtensionAPI.register_hook(api, :transform_context, &__MODULE__.transform_context/2)
    :ok = ExtensionAPI.register_hook(api, :before_tool_call, &__MODULE__.before_tool_call/1)
    :ok = ExtensionAPI.register_hook(api, :after_tool_call, &__MODULE__.after_tool_call/2)
    :ok = ExtensionAPI.register_hook(api, :prepare_next_turn, &__MODULE__.prepare_next_turn/2)

    :ok =
      ExtensionAPI.register_hook(
        api,
        :should_stop_after_turn,
        &__MODULE__.should_stop_after_turn/1
      )

    :ok = ExtensionAPI.on(api, &__MODULE__.observe/1)

    :ok =
      ExtensionAPI.register_renderer(
        api,
        :message,
        &__MODULE__.everything_result?/1,
        &__MODULE__.render_result/1
      )

    :ok =
      ExtensionAPI.register_component(api, :header_extra, &__MODULE__.header_extra/1)

    :ok =
      ExtensionAPI.register_page(api, "flex-everything", {__MODULE__, :page}, label: "Everything")

    ExtensionAPI.register_command(api, "flex-status",
      handler: &__MODULE__.command_status/2,
      label: "/flex-status — show the UI-everything process state"
    )
  end

  @doc false
  def transform_context(messages, _ctx) do
    {:ok, _count} = Catalyst.Ext.UIEverythingState.bump(:transform_context)
    {:ok, messages}
  end

  @doc false
  def before_tool_call(_ctx) do
    {:ok, _count} = Catalyst.Ext.UIEverythingState.bump(:before_tool_call)
    :cont
  end

  @doc false
  def after_tool_call({content, details, error?, terminate?}, _ctx) do
    {:ok, _count} = Catalyst.Ext.UIEverythingState.bump(:after_tool_call)

    {:ok,
     {content ++ Content.text(" [everything-after-hook]"),
      Map.put(details, :everything_after_hook, true), error?, terminate?}}
  end

  @doc false
  def prepare_next_turn({context, config}, _ctx) do
    {:ok, _count} = Catalyst.Ext.UIEverythingState.bump(:prepare_next_turn)
    {:ok, {context, config}}
  end

  @doc false
  def should_stop_after_turn(_ctx) do
    {:ok, _count} = Catalyst.Ext.UIEverythingState.bump(:should_stop_after_turn)
    :cont
  end

  @doc false
  def observe(_event) do
    Catalyst.Ext.UIEverythingState.bump(:observer)
    :ok
  end

  @doc false
  def everything_result?(%Message.ToolResult{tool_name: "flex_everything"}), do: true
  def everything_result?(_message), do: false

  @doc false
  def render_result(assigns) do
    ~H"""
    <article
      id="flex-everything-card"
      data-flex-renderer="everything"
      class="rounded-xl border border-emerald-300 bg-emerald-50 p-3 text-emerald-950"
    >
      <strong>FLEX-EVERYTHING-CARD</strong>
      <span>{Content.text_of(@msg.content)}</span>
    </article>
    """
  end

  @doc false
  def header_extra(assigns) do
    ~H"""
    <span id="flex-everything-header" data-flex-component="everything">FLEX-EVERYTHING</span>
    """
  end

  @doc false
  def page(assigns) do
    ~H"""
    <section id="flex-everything-page" data-cwd={@cwd}>
      <h1>FLEX-EVERYTHING-PAGE</h1>
    </section>
    """
  end

  @doc false
  def command_status(_arg, socket) do
    status =
      case Catalyst.Ext.UIEverythingState.snapshot() do
        {:ok, snapshot} ->
          tool = Map.get(snapshot, :tool, 0)
          observer = Map.get(snapshot, :observer, 0)
          "FLEX-STATUS tool=#{tool} observer=#{observer}"

        {:error, :not_running} ->
          "FLEX-STATUS stopped"
      end

    Phoenix.LiveView.put_flash(socket, :info, status)
  end
end
