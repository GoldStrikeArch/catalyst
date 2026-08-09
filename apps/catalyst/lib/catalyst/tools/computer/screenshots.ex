defmodule Catalyst.Tools.Computer.Screenshots do
  @moduledoc """
  Optional screenshot pruning (plan §5.3), off by default.

  `config :catalyst, :computer_screenshot_retain` is `:all` (default — prune
  nothing) or a non-negative integer N: a built-in `:transform_context` hook
  replaces every `computer`-tool screenshot image **except the last N** with a
  deterministic text placeholder before each LLM call.

  "Keep the last N by position" is deterministic and **idempotent**, which the
  hook point requires — `transform_context` documents double invocation (the
  ordinary request and the staged compaction candidate see the hook
  independently): placeholders are plain text blocks, so a second pass counts
  only the surviving images and changes nothing.

  Two documented costs (the user's trade, hence opt-in): rewriting history
  invalidates the Codex delta-upload prefix check, so every turn re-uploads in
  full; and compaction persists its replacement untransformed, so pruning
  shrinks the *request*, not the durable transcript.

  Registered at boot by `Catalyst.Application` (plus an
  `Catalyst.Extensions.register_reseeder/2` entry so extension-runtime restarts
  and `load_all` re-seed it); `register_hooks/0` is idempotent — it revokes the
  owner's prior registration first.
  """

  alias Catalyst.{Content, Hooks, Message}

  @owner :computer_use_builtin
  @hook_id :computer_screenshot_prune

  @doc """
  (Re-)register the pruning hook. Idempotent in the strictest sense: when the
  **current** handler function is already registered it changes nothing at all
  (no seq bump — reseeds after `load_all` must be invisible to runtime-state
  snapshots); a missing or stale-generation handler is replaced.
  """
  @spec register_hooks() :: :ok
  def register_hooks do
    handler = &prune_hook/2

    case registered_current?(handler) do
      true ->
        :ok

      false ->
        :ok = Hooks.unregister(@owner)
        :ok = Hooks.register(:transform_context, handler, owner: @owner, id: @hook_id)
    end
  end

  defp registered_current?(handler) do
    :transform_context
    |> Hooks.handlers()
    |> Enum.any?(&(&1.owner == @owner and &1.id == @hook_id and &1.fun == handler))
  end

  @doc """
  The `:transform_context` handler: prunes per the live
  `:computer_screenshot_retain` setting. `:all` (or an invalid value) is a
  fast no-op.
  """
  @spec prune_hook([term()], term()) :: {:ok, [term()]}
  def prune_hook(messages, _ctx) do
    case Application.get_env(:catalyst, :computer_screenshot_retain, :all) do
      retain when is_integer(retain) and retain >= 0 -> {:ok, prune(messages, retain)}
      _all_or_invalid -> {:ok, messages}
    end
  end

  @doc """
  Replace all but the last `keep` screenshot images (images inside `computer`
  tool results) with text placeholders. Pure and idempotent.
  """
  @spec prune([term()], non_neg_integer()) :: [term()]
  def prune(messages, keep) when is_list(messages) and is_integer(keep) and keep >= 0 do
    excess = max(count_screenshots(messages) - keep, 0)

    case excess do
      0 ->
        messages

      _positive ->
        {pruned, _remaining} = Enum.map_reduce(messages, excess, &prune_message/2)
        pruned
    end
  end

  defp count_screenshots(messages) do
    messages
    |> Enum.map(&message_image_count/1)
    |> Enum.sum()
  end

  defp message_image_count(%Message.ToolResult{tool_name: "computer", content: content})
       when is_list(content),
       do: Enum.count(content, &match?(%Content.Image{}, &1))

  defp message_image_count(_message), do: 0

  defp prune_message(%Message.ToolResult{tool_name: "computer"} = message, remaining)
       when remaining > 0 and is_list(message.content) do
    {content, remaining} =
      Enum.map_reduce(message.content, remaining, fn
        %Content.Image{} = image, left when left > 0 -> {placeholder(image), left - 1}
        block, left -> {block, left}
      end)

    {%{message | content: content}, remaining}
  end

  defp prune_message(message, remaining), do: {message, remaining}

  defp placeholder(%Content.Image{data: data, mime_type: mime}) do
    digest = :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

    %Content.Text{
      text:
        "[screenshot pruned by computer_screenshot_retain: #{mime}, " <>
          "#{byte_size(data)} base64 bytes, sha256 #{binary_part(digest, 0, 12)}]"
    }
  end
end
