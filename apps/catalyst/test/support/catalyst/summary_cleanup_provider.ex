defmodule Catalyst.Test.SummaryCleanupProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message, Usage}

  @impl true
  def stream(model, context, opts, _sink) do
    session_id = Keyword.get(opts, :session_id, "")

    case String.starts_with?(session_id, "@compact:") do
      true -> summarize(model, context, opts)
      false -> answer(model)
    end
  end

  @impl true
  def cleanup_session(session_id) do
    case Application.get_env(:catalyst, :summary_cleanup_test_pid) do
      pid when is_pid(pid) -> send(pid, {:summary_cleanup, __MODULE__, session_id})
      _none -> :ok
    end

    :ok
  end

  defp summarize(model, _context, opts) do
    notify({:summary_started, self(), Keyword.fetch!(opts, :session_id)})

    case Keyword.get(opts, :summary_cleanup_mode, :success) do
      :success -> {:ok, assistant(model, "faithful summary", :stop)}
      :error -> {:ok, assistant(model, "summary failed", :error)}
      :timeout -> await_release(model)
      :block -> await_release(model)
    end
  end

  defp await_release(model) do
    receive do
      :release_summary -> {:ok, assistant(model, "released summary", :stop)}
    end
  end

  defp answer(model), do: {:ok, assistant(model, "ordinary answer", :stop)}

  defp assistant(model, text, stop_reason) do
    %Message.Assistant{
      content: Content.text(text),
      model: model.id,
      stop_reason: stop_reason,
      error_message: if(stop_reason == :error, do: text),
      usage: %Usage{input: 10, output: 10, total_tokens: 20},
      timestamp: Message.now()
    }
  end

  defp notify(message) do
    case Application.get_env(:catalyst, :summary_cleanup_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _none -> :ok
    end
  end
end
