defmodule Catalyst.Context.Summarizer do
  @moduledoc """
  Bounded, provider-backed summarization of removed transcript history.

  `Catalyst.Context.Window` keeps the cut/fit arithmetic and delegates the side
  effects here: rendering removed messages to bounded text, resolving the
  compaction prompt, one supervised provider stream under a run-scoped
  resource registration, and normalization of the summary result. A failed,
  oversized, or timed-out summary is never fatal — `summarize/2` returns `nil`
  and the caller retries its deterministic summary-free cut.
  """

  alias Catalyst.{Content, Message, Tasks}
  alias Catalyst.Context.Window
  alias Catalyst.LLM.Context, as: LLMContext
  alias Catalyst.Tools.Truncate

  @summary_prefix "[Compacted context summary]\n"
  @summary_result_limit 16_000
  @tool_result_limit 2_000
  @default_policy_timeout 30_000

  @doc """
  Summarize removed messages into one user message, or `nil` when no summary
  is available.

  The summarizer runs in a supervised task bounded by `:compaction_timeout`
  (falling back to the configured `:context_policy_timeout`). `context` may
  supply a `:summary_fun` seam; otherwise the `:provider`/`:model` pair is
  streamed with the resolved compaction prompt. Timeouts, provider errors,
  blank, oversized, or invalid results all normalize to `nil`.
  """
  @spec summarize([Message.t()], map()) :: Message.User.t() | nil
  def summarize([], _context), do: nil

  def summarize(removed, context) do
    task = Tasks.async(fn -> run_summarizer(removed, context) end)
    timeout = Map.get(context, :compaction_timeout, policy_timeout())

    case Tasks.await(task, timeout) do
      {:ok, {:ok, text}} -> summary_message(text)
      {:ok, text} when is_binary(text) -> summary_message(text)
      _failure -> nil
    end
  end

  @doc "Unique provider continuation namespace for one compaction attempt."
  @spec companion_id(String.t()) :: String.t()
  def companion_id(session_id) when is_binary(session_id) do
    digest = :crypto.hash(:sha256, session_id) |> Base.url_encode64(padding: false)
    attempt = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "@compact:" <> digest <> ":" <> attempt
  end

  @doc """
  Render one message to the provider-neutral text used both as summarizer
  input and as the byte basis of the coarse fallback token estimate.
  """
  @spec render_message(Message.t() | term()) :: String.t()
  def render_message(%Message.User{content: content}),
    do: "User: " <> render_content(content)

  def render_message(%Message.Assistant{content: content}),
    do: "Assistant: " <> render_content(content)

  def render_message(%Message.ToolResult{tool_name: name, content: content}) do
    text =
      content |> render_content() |> Truncate.scrub_utf8() |> String.slice(0, @tool_result_limit)

    "Tool result (#{name}): " <> text
  end

  def render_message(other), do: inspect(other, limit: 20, printable_limit: 2_000)

  defp run_summarizer(removed, context) do
    case Map.get(context, :summary_fun) do
      fun when is_function(fun, 2) -> normalize_summary(fun.(removed, context))
      fun when is_function(fun, 1) -> normalize_summary(fun.(removed))
      _none -> provider_summary(removed, context)
    end
  end

  defp provider_summary(removed, context) do
    provider = Map.get(context, :provider)
    model = Map.get(context, :model)

    case is_atom(provider) and not is_nil(provider) and function_exported?(provider, :stream, 4) and
           not is_nil(model) do
      true -> stream_summary(provider, model, removed, context)
      false -> {:error, :no_summarizer}
    end
  end

  defp stream_summary(provider, model, removed, context) do
    session_id = companion_id(to_string(Map.get(context, :session_id, "unknown")))
    source = removed |> render_messages() |> bound_summary_source(model)

    with :ok <- register_resource(context, provider, session_id) do
      try do
        with {:ok, prompt} <- compaction_prompt(model, context) do
          llm_context = %LLMContext{
            system_prompt: prompt,
            messages: [Message.user(source)],
            tools: []
          }

          opts = context |> Map.get(:opts, []) |> Keyword.put(:session_id, session_id)

          case provider.stream(model, llm_context, opts, fn _event -> :ok end) do
            {:ok, %Message.Assistant{stop_reason: reason} = assistant}
            when reason in [:stop, :length] ->
              normalize_summary(Content.text_of(assistant.content))

            {:ok, _invalid} ->
              {:error, :invalid_summary}

            {:error, _reason} = error ->
              error
          end
        end
      after
        cleanup_provider(provider, session_id)
      end
    end
  end

  defp compaction_prompt(model, context) do
    request =
      struct(Catalyst.Prompt.Request,
        purpose: :compaction,
        model: model,
        cwd: Map.get(context, :cwd),
        session_id: Map.get(context, :session_id),
        opts: Map.get(context, :opts, [])
      )

    case Catalyst.Prompt.resolve_bounded(request) do
      {:ok, resolution} -> {:ok, resolution.text}
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:compaction_prompt_exception, Exception.message(error)}}
  end

  defp register_resource(context, provider, session_id) do
    resource = %{provider: provider, session_id: session_id}

    case Map.get(context, :register_resource) do
      fun when is_function(fun, 1) -> normalize_resource_registration(fun.(resource))
      _none -> :ok
    end
  end

  defp normalize_resource_registration({:error, _reason} = error), do: error
  defp normalize_resource_registration(_result), do: :ok

  defp cleanup_provider(provider, session_id) do
    case function_exported?(provider, :cleanup_session, 1) do
      true -> provider.cleanup_session(session_id)
      false -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp normalize_summary({:ok, text}), do: normalize_summary(text)

  defp normalize_summary(text) when is_binary(text) do
    text = Truncate.scrub_utf8(text)

    case byte_size(text) > @summary_result_limit do
      true -> {:error, :summary_too_large}
      false -> normalize_trimmed_summary(String.trim(text))
    end
  end

  defp normalize_summary(_invalid), do: {:error, :invalid_summary}

  defp normalize_trimmed_summary(""), do: {:error, :blank_summary}
  defp normalize_trimmed_summary(text), do: {:ok, text}

  defp summary_message({:ok, text}), do: summary_message(text)

  defp summary_message(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      value -> Message.user(@summary_prefix <> value)
    end
  end

  defp summary_message(_invalid), do: nil

  defp bound_summary_source(source, model) do
    max_bytes =
      case Window.effective_window(model) do
        {:ok, window} -> max(1, min(200_000, floor(window * 0.50) * 4))
        :error -> 120_000
      end

    elem(Truncate.head(source, max_bytes: max_bytes), 0)
  end

  defp render_messages(messages), do: Enum.map_join(messages, "\n\n", &render_message/1)

  defp render_content(content) do
    Enum.map_join(List.wrap(content), "", fn
      %Content.Text{text: text} ->
        text

      %Content.Thinking{thinking: thinking} ->
        "[thinking: #{thinking}]"

      %Content.Image{mime_type: mime} ->
        "[image: #{mime}]"

      %Content.ToolCall{name: name, arguments: args} ->
        "[tool call: #{name} #{inspect(args, limit: 20, printable_limit: 1_000)}]"

      other ->
        inspect(other, limit: 10, printable_limit: 500)
    end)
  end

  defp policy_timeout,
    do: Application.get_env(:catalyst, :context_policy_timeout, @default_policy_timeout)
end
