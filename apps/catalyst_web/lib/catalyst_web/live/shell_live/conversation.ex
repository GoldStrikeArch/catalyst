defmodule CatalystWeb.ShellLive.Conversation do
  @moduledoc """
  Projects session events and snapshots into the chat-related LiveView assigns.

  The session remains the source of truth. This module owns only the transient UI
  projection: message streams, the in-flight assistant bubble, tool indicators,
  and the short replay-deduplication window used when a view reattaches.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3, stream: 3, stream: 4, stream_insert: 3]

  alias Catalyst.Agent.Event
  alias Catalyst.Message
  alias Catalyst.Session.Server
  alias CatalystWeb.UI.Markdown

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Initializes the conversation assigns and streams for a newly mounted shell."
  @spec init(socket()) :: socket()
  def init(socket) do
    socket
    |> clear_projection()
    |> stream(:messages, [])
    |> stream(:stream_blocks, [])
  end

  @doc "Clears the transient conversation projection for a newly started session."
  @spec reset(socket()) :: socket()
  def reset(socket) do
    socket
    |> clear_projection()
    |> stream(:messages, [], reset: true)
    |> stream(:stream_blocks, [], reset: true)
  end

  defp clear_projection(socket) do
    socket
    |> assign(
      streaming: nil,
      running: false,
      tools: %{},
      replayed_tail: [],
      run_metadata: nil,
      context_status: nil,
      queued: []
    )
    |> set_message_count(0)
  end

  @doc "Rebuilds the conversation projection from a live session snapshot."
  @spec replay(socket(), pid()) :: socket()
  def replay(socket, pid) do
    snapshot = Server.state(pid)
    flush_stale_updates(snapshot.id)

    {socket, message_count} = replace_messages(socket, snapshot.messages)
    run_metadata = Map.get(snapshot, :run_metadata)

    socket
    |> set_message_count(message_count)
    |> assign(
      cwd: snapshot.cwd,
      running: snapshot.running,
      streaming: nil,
      tools: %{},
      session_model: snapshot.model,
      session_opts: Map.get(snapshot, :opts, []),
      replayed_tail: replayed_tail(snapshot.messages),
      run_metadata: run_metadata,
      context_status: metadata_context_status(run_metadata),
      queued: []
    )
    |> seed_streaming(snapshot.streaming_message)
  end

  @doc "Applies one session event to the LiveView conversation projection."
  @spec apply_event(term(), socket()) :: socket()
  def apply_event(%Event.MessageStart{message: %Message.Assistant{}}, socket) do
    case socket.assigns.streaming do
      nil -> start_stream_bubble(socket)
      _streaming -> socket
    end
  end

  def apply_event(
        %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.TextDelta{delta: delta}},
        socket
      ) do
    # The client appends first; a later commit then replaces the tail with the
    # post-commit remainder.
    socket
    |> ensure_streaming()
    |> push_stream_delta("text", delta)
    |> accumulate_stream_text(delta)
  end

  def apply_event(
        %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.ThinkingDelta{delta: delta}},
        socket
      ) do
    socket
    |> ensure_streaming()
    |> push_stream_delta("thinking", delta)
  end

  def apply_event(%Event.MessageEnd{message: message}, socket) do
    case split_replayed(socket.assigns.replayed_tail, message) do
      {:duplicate, rest} ->
        assign(socket, replayed_tail: rest)

      :new ->
        append_message(socket, message)
    end
  end

  def apply_event(%Event.ToolExecutionStart{call_id: id, name: name, args: args}, socket) do
    assign(socket, tools: Map.put(socket.assigns.tools, id, %{name: name, args: args}))
  end

  def apply_event(%Event.ToolExecutionUpdate{call_id: id, partial: partial}, socket) do
    case socket.assigns.tools do
      %{^id => info} = tools ->
        assign(socket, tools: Map.put(tools, id, Map.put(info, :partial, partial_text(partial))))

      _unknown ->
        socket
    end
  end

  def apply_event(%Event.ToolExecutionEnd{call_id: id}, socket) do
    assign(socket, tools: Map.delete(socket.assigns.tools, id))
  end

  def apply_event(%Event.ContextStatus{} = status, socket) do
    status = Map.from_struct(status)

    assign(socket,
      context_status: status,
      run_metadata: put_context_status(socket.assigns.run_metadata, status)
    )
  end

  def apply_event(%Event.ContextCompacted{replacement: replacement}, socket)
      when is_list(replacement) do
    {socket, message_count} = replace_messages(socket, replacement)

    socket
    |> set_message_count(message_count)
    |> assign(replayed_tail: replayed_tail(replacement))
  end

  def apply_event(%Event.AgentStart{}, socket), do: assign(socket, running: true)

  def apply_event(%Event.AgentEnd{}, socket) do
    socket
    |> assign(running: false, tools: %{}, queued: [])
    |> clear_stream_bubble()
  end

  def apply_event(_event, socket), do: socket

  defp replace_messages(socket, messages) do
    items =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {message, sequence} -> %{id: sequence, msg: message} end)

    {stream(socket, :messages, items, reset: true), length(items)}
  end

  defp replayed_tail(messages) do
    Enum.take(messages, -10)
  end

  defp metadata_context_status(%{context_status: %{} = status}), do: status
  defp metadata_context_status(_metadata), do: nil

  defp put_context_status(%{} = metadata, status),
    do: Map.put(metadata, :context_status, status)

  defp put_context_status(_metadata, status), do: %{context_status: status}

  defp append_message(socket, message) do
    socket =
      socket
      |> maybe_clear_streaming(message)
      |> bump_message_count()
      |> assign(replayed_tail: [])

    stream_insert(socket, :messages, %{id: socket.assigns.message_seq, msg: message})
  end

  defp set_message_count(socket, count),
    do: assign(socket, message_seq: count, message_count: count)

  defp bump_message_count(socket) do
    assign(socket,
      message_seq: socket.assigns.message_seq + 1,
      message_count: socket.assigns.message_count + 1
    )
  end

  defp maybe_clear_streaming(socket, %Message.Assistant{}), do: clear_stream_bubble(socket)
  defp maybe_clear_streaming(socket, _message), do: socket

  defp ensure_streaming(socket) do
    case socket.assigns.streaming do
      nil -> start_stream_bubble(socket)
      _streaming -> socket
    end
  end

  defp start_stream_bubble(socket) do
    socket
    |> assign(streaming: empty_stream_seed())
    |> stream(:stream_blocks, [], reset: true)
  end

  defp clear_stream_bubble(socket) do
    socket
    |> assign(streaming: nil)
    |> stream(:stream_blocks, [], reset: true)
  end

  # `:acc` holds the streamed text as a reversed chunk list: appending a delta
  # is O(1), and the full string is materialized only at the newline-bearing
  # parse boundaries that need it (see `stream_text/1`).
  defp empty_stream_seed do
    %{thinking: "", tail: "", preview: [], acc: [], committed: 0, epoch: unique_epoch()}
  end

  defp unique_epoch, do: System.unique_integer([:positive])

  defp stream_text(%{acc: chunks}), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp accumulate_stream_text(socket, delta) do
    streaming = socket.assigns.streaming
    socket = assign(socket, streaming: %{streaming | acc: [delta | streaming.acc]})

    case String.contains?(delta, "\n") do
      true -> commit_stable_blocks(socket)
      false -> socket
    end
  end

  defp commit_stable_blocks(socket) do
    streaming = socket.assigns.streaming
    {blocks, tail} = Markdown.stable_split(stream_text(streaming))
    {preview, raw} = Markdown.preview_tail(tail)
    block_count = length(blocks)

    socket =
      case block_count > streaming.committed do
        true -> insert_new_blocks(socket, streaming, blocks)
        false -> socket
      end

    socket
    |> assign(streaming: %{streaming | committed: block_count, tail: raw, preview: preview})
    |> push_event("stream_tail", %{text: raw})
  end

  defp insert_new_blocks(socket, streaming, blocks) do
    blocks
    |> Enum.drop(streaming.committed)
    |> Enum.with_index(streaming.committed)
    |> Enum.reduce(socket, fn {block, index}, socket ->
      item = %{id: "sb#{streaming.epoch}-#{index}", block: block}
      stream_insert(socket, :stream_blocks, item)
    end)
  end

  defp seed_streaming(socket, %Message.Assistant{content: content}) do
    thinking =
      content
      |> Enum.filter(&match?(%Catalyst.Content.Thinking{}, &1))
      |> Enum.map_join("", & &1.thinking)

    text =
      content
      |> Enum.filter(&match?(%Catalyst.Content.Text{}, &1))
      |> Enum.map_join("", & &1.text)

    {blocks, tail} = Markdown.stable_split(text)
    {preview, raw} = Markdown.preview_tail(tail)
    epoch = unique_epoch()

    seed = %{
      thinking: thinking,
      tail: raw,
      preview: preview,
      acc: [text],
      committed: length(blocks),
      epoch: epoch
    }

    socket =
      socket
      |> assign(streaming: seed)
      |> stream(:stream_blocks, [], reset: true)

    blocks
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {block, index}, socket ->
      stream_insert(socket, :stream_blocks, %{id: "sb#{epoch}-#{index}", block: block})
    end)
  end

  defp seed_streaming(socket, _message), do: socket

  defp flush_stale_updates(id) do
    receive do
      {:agent_event, ^id, %Event.MessageUpdate{}} -> flush_stale_updates(id)
    after
      0 -> :ok
    end
  end

  defp push_stream_delta(socket, kind, delta) do
    push_event(socket, "stream_delta", %{kind: kind, delta: delta})
  end

  defp partial_text(%{output: output}) when is_binary(output), do: output
  defp partial_text(output) when is_binary(output), do: output
  defp partial_text(_partial), do: nil

  defp split_replayed([], _message), do: :new

  defp split_replayed(tail, message) do
    case Enum.split_while(tail, &(&1 != message)) do
      {_skipped, [^message | rest]} -> {:duplicate, rest}
      _not_replayed -> :new
    end
  end
end
