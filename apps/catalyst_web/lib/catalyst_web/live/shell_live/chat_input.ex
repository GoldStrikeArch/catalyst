defmodule CatalystWeb.ShellLive.ChatInput do
  @moduledoc """
  Owns the shell chat form, `@` file references, and pasted-image prompt input.

  File-search labels remain display-friendly in the form and are expanded to
  working-directory-relative paths only when a prompt is submitted.
  """

  import Phoenix.Component, only: [assign: 2, to_form: 1]
  import Phoenix.LiveView, only: [consume_uploaded_entries: 3]

  alias Catalyst.Content
  alias CatalystWeb.FileSearch

  @type socket :: Phoenix.LiveView.Socket.t()
  @type file_refs :: %{optional(String.t()) => String.t()}

  @doc "Builds the chat form from its current input text."
  @spec form(String.t()) :: Phoenix.HTML.Form.t()
  def form(input), do: to_form(%{"message" => input})

  @doc "Replaces the current chat input while preserving the rest of the socket."
  @spec put_text(socket(), String.t()) :: socket()
  def put_text(socket, text), do: assign(socket, chat_form: form(text))

  @doc "Updates the trailing `@query` file search for the current input asynchronously."
  @spec search_files(socket(), String.t()) :: socket()
  def search_files(socket, text) do
    case active_file_query(text) do
      nil ->
        assign(socket, file_search: nil)

      query ->
        token = make_ref()
        cwd = socket.assigns.cwd

        # Phoenix 1.1 doesn't have run_async, but we use a supervised task.
        # ShellLive handles the task completion.
        task =
          Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
            results = FileSearch.search(cwd, query)
            %{token: token, query: query, results: results}
          end)

        assign(socket, file_search_token: token, file_search_ref: task.ref)
    end
  end

  @doc "Applies the result of an async file search if it's still current."
  @spec apply_search(socket(), map()) :: socket()
  def apply_search(socket, %{token: token, query: query, results: results}) do
    case socket.assigns.file_search_token == token do
      true -> assign(socket, file_search: %{query: query, results: results})
      false -> socket
    end
  end

  @doc "Selects a file-search result and records how its inserted label expands."
  @spec pick_file(socket(), String.t(), String.t(), String.t()) :: socket()
  def pick_file(socket, text, label, path) do
    new_text = Regex.replace(~r/@\S*$/, text, fn _match -> label <> " " end)

    socket
    |> put_text(new_text)
    |> assign(
      file_search: nil,
      file_refs: Map.put(socket.assigns.file_refs, label, path)
    )
  end

  @doc "Expands selected file labels into paths, longest label first."
  @spec expand_refs(file_refs(), String.t()) :: String.t()
  def expand_refs(refs, text) when refs == %{}, do: text

  def expand_refs(refs, text) do
    refs
    |> Enum.sort_by(fn {label, _path} -> -byte_size(label) end)
    |> Enum.reduce(text, fn {label, path}, text -> String.replace(text, label, path) end)
  end

  @doc "Returns whether at least one image upload is complete."
  @spec completed_images?(socket()) :: boolean()
  def completed_images?(socket) do
    Enum.any?(socket.assigns.uploads.image.entries, & &1.done?)
  end

  @doc "Returns whether any image upload is still in progress."
  @spec uploading_images?(socket()) :: boolean()
  def uploading_images?(socket) do
    Enum.any?(socket.assigns.uploads.image.entries, &(not &1.done?))
  end

  @doc "Consumes completed uploads and builds the content accepted by `Session.Server.prompt/2`."
  @spec consume_prompt(socket(), String.t()) :: String.t() | [struct()]
  def consume_prompt(socket, text) do
    images =
      consume_uploaded_entries(socket, :image, fn meta, _entry ->
        {:ok, meta.prepared}
      end)

    case images do
      [] -> text
      _images -> text_block(text) ++ images
    end
  end

  @doc "Prepares an image upload entry asynchronously."
  @spec prepare_image(socket(), Phoenix.LiveView.UploadEntry.t()) :: socket()
  def prepare_image(socket, entry) do
    # Phoenix 1.1 doesn't have run_async, but we use a supervised task.
    # ShellLive handles the task completion.
    task =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        case Phoenix.LiveView.consume_uploaded_entry(socket, entry, fn %{path: path} ->
               case File.read(path) do
                 {:ok, data} ->
                   {:ok,
                    %Content.Image{
                      data: Base.encode64(data),
                      mime_type: entry.client_type || "image/png"
                    }}

                 {:error, reason} ->
                   {:error, reason}
               end
             end) do
          {:ok, prepared} -> {:ok, prepared}
          {:error, reason} -> {:error, reason}
        end
      end)

    assign(socket,
      image_prep_refs: Map.put(socket.assigns.image_prep_refs || %{}, task.ref, entry.ref)
    )
  end

  defp active_file_query(text) do
    case Regex.run(~r/(?:^|\s)@(\S*)$/, text) do
      [_, query] -> query
      _no_match -> nil
    end
  end

  defp text_block(""), do: []
  defp text_block(text), do: [%Content.Text{text: text}]
end
