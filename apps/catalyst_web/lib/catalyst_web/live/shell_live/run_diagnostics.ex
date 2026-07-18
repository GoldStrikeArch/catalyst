defmodule CatalystWeb.ShellLive.RunDiagnostics do
  @moduledoc """
  Loads prompt previews and refreshes read-only run diagnostics for the shell.

  Prompt resolution is deliberately performed in a supervised task. This keeps
  extension prompt-policy code out of both the LiveView and Session.Server
  processes while still giving never-run sessions a useful preview.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.Model
  alias Catalyst.Prompt.Resolution
  alias Catalyst.Session.{RunContext, Server}

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Starts a supervised prompt preview for the attached session."
  @spec preview(socket()) :: socket()
  def preview(%{assigns: %{session_pid: pid}} = socket) when is_pid(pid) do
    socket = cancel_preview(socket)

    task =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        snapshot = Server.state(pid)
        model = effective_preview_model(snapshot.model)

        case RunContext.resolve_prompt(snapshot, model) do
          {:ok, %Resolution{} = resolution} ->
            {:ok, preview_map(resolution, model)}

          {:error, _reason} = error ->
            error
        end
      end)

    assign(socket,
      prompt_preview: :loading,
      prompt_preview_ref: task.ref,
      prompt_preview_pid: task.pid
    )
  end

  def preview(socket) do
    socket
    |> cancel_preview()
    |> assign(prompt_preview: nil, prompt_preview_ref: nil, prompt_preview_pid: nil)
  end

  @doc "Folds the matching prompt-preview task result into shell assigns."
  @spec finish_preview(socket(), term()) :: socket()
  def finish_preview(socket, result) do
    assign(socket,
      prompt_preview: normalize_preview_result(result),
      prompt_preview_ref: nil,
      prompt_preview_pid: nil
    )
  end

  @doc "Refreshes run metadata from the authoritative session snapshot."
  @spec refresh(socket(), keyword()) :: socket()
  def refresh(socket, opts \\ [])

  def refresh(%{assigns: %{session_pid: pid}} = socket, opts) when is_pid(pid) do
    snapshot = Server.state(pid)
    metadata = Map.get(snapshot, :run_metadata)

    case Keyword.get(opts, :preserve_status, false) do
      true -> refresh_preserving_status(socket, metadata)
      false -> assign_metadata(socket, metadata)
    end
  catch
    :exit, _reason -> socket
  end

  def refresh(socket, _opts), do: socket

  defp refresh_preserving_status(socket, %{} = metadata) do
    status = socket.assigns.context_status
    metadata = if is_map(status), do: Map.put(metadata, :context_status, status), else: metadata
    assign_metadata(socket, metadata)
  end

  defp refresh_preserving_status(socket, _metadata), do: socket

  defp assign_metadata(socket, metadata) do
    assign(socket,
      run_metadata: metadata,
      context_status: context_status(metadata)
    )
  end

  defp context_status(%{context_status: %{} = status}), do: status
  defp context_status(_metadata), do: nil

  defp cancel_preview(%{assigns: %{prompt_preview_pid: pid, prompt_preview_ref: ref}} = socket)
       when is_pid(pid) and is_reference(ref) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    assign(socket, prompt_preview_ref: nil, prompt_preview_pid: nil)
  end

  defp cancel_preview(socket), do: socket

  # Mirror RunContext's pre-request catalog refresh: a custom prompt policy
  # reading model limits must preview against the same effective metadata the
  # next run will resolve, not the raw persisted snapshot model.
  defp effective_preview_model(%Model{api: "openai-codex-responses", id: id} = model) do
    # resolve_epoch_model/2 cannot error on a %Model{} input; the type checker
    # rejects an unreachable {:error, _} fallback clause here.
    {:ok, resolved} = RunContext.resolve_epoch_model(model, OpenAICodex.catalog_snapshot(id))
    resolved
  end

  defp effective_preview_model(model), do: model

  defp preview_map(resolution, model) do
    %{
      text: resolution.text,
      digest: resolution.digest,
      sources: resolution.sources,
      model_id: model && model.id,
      api: model && model.api
    }
  end

  defp normalize_preview_result({:ok, %{} = preview}), do: {:ok, preview}
  defp normalize_preview_result({:error, reason}), do: {:error, reason}
  defp normalize_preview_result(other), do: {:error, {:invalid_preview_result, other}}
end
