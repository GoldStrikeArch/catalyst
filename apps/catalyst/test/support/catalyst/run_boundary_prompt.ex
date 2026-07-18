defmodule Catalyst.Test.RunBoundaryPrompt do
  @moduledoc false

  @behaviour Catalyst.Prompt

  alias Catalyst.Prompt.{Request, Resolution}

  @impl true
  def resolve(%Request{} = request) do
    notify(request)
    resolve_mode(Keyword.get(request.opts, :run_boundary_prompt_mode, :ok), request)
  end

  defp resolve_mode(:ok, request) do
    text =
      request.override ||
        Keyword.get(request.opts, :run_boundary_prompt_text) ||
        "prompt for #{model_id(request.model)}"

    {:ok, Resolution.new(text, [{:application, :run_boundary_test}])}
  end

  defp resolve_mode({:ok, text}, _request),
    do: {:ok, Resolution.new(text, [{:application, :run_boundary_test}])}

  defp resolve_mode({:error, reason}, _request), do: {:error, reason}
  defp resolve_mode({:invalid, value}, _request), do: value
  defp resolve_mode({:raise, message}, _request), do: raise(message)
  defp resolve_mode({:exit, reason}, _request), do: exit(reason)

  defp resolve_mode(:timeout, _request) do
    receive do
      :run_boundary_prompt_release -> {:error, :unexpected_release}
    end
  end

  defp notify(request) do
    case Keyword.get(request.opts, :run_boundary_test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:run_boundary_prompt_resolved, model_id(request.model), self()})

      _none ->
        :ok
    end
  end

  defp model_id(nil), do: :default
  defp model_id(model), do: model.id
end
