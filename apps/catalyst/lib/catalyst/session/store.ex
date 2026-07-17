defmodule Catalyst.Session.Store do
  @moduledoc """
  Append-only JSONL persistence for a session (PI's JSONL session repo).

  Layout: `~/.catalyst/sessions/<cwd-hash>/<id>.jsonl`. Line 1 is a session
  header; each subsequent line is a `{"type":"message","message":{…}}` entry,
  appended as the single writer (`Catalyst.Session.Server`) sees `message_end`.
  `load/1` folds the lines back into a message list for resume.
  """

  alias Catalyst.Message
  alias Catalyst.Session.Store.Codec

  require Logger

  @type handle :: %{id: String.t(), path: String.t(), cwd: String.t()}
  @type loaded_state :: %{
          messages: [Message.t()],
          model: Catalyst.Model.t() | nil,
          model_set?: boolean(),
          thinking_level: String.t() | nil,
          thinking_level_set?: boolean()
        }

  @doc "Root directory for all session logs (override with `config :catalyst, :sessions_root`)."
  def root,
    do: Application.get_env(:catalyst, :sessions_root) || Catalyst.Paths.sessions()

  @doc """
  Open the session file for an id, creating it with a header line if it does
  not exist yet; returns its handle. An existing file is left untouched so a
  crash-restarted `Session.Server` can resume it via `load/1`.
  """
  @spec new(String.t(), keyword()) :: handle()
  def new(cwd, opts \\ []) do
    id = Keyword.get(opts, :id) || gen_id()
    dir = Path.join(root(), cwd_hash(cwd))
    File.mkdir_p!(dir)
    path = Path.join(dir, id <> ".jsonl")

    header = %{
      "type" => "session",
      "version" => 1,
      "id" => id,
      "cwd" => cwd,
      "timestamp" => Message.now()
    }

    case File.exists?(path) do
      true -> :ok
      false -> File.write!(path, line(header))
    end

    %{id: id, path: path, cwd: cwd}
  end

  @doc """
  Append one message as a JSONL line. Best-effort, like `load/1`: the session
  server (the single caller) appends inline while folding run events, so an
  encode or disk failure is logged and swallowed rather than crashing the run.
  """
  @spec append_message(handle(), Message.t()) :: :ok
  def append_message(handle, message) do
    append_line(handle, fn -> %{"type" => "message", "message" => encode(message)} end)
  end

  @doc """
  Append a reset marker. `load/1` discards every message before the last
  marker, so a session reset survives crash-restarts without rewriting the
  append-only file. Best-effort, like `append_message/2`.
  """
  @spec append_reset(handle()) :: :ok
  def append_reset(handle) do
    append_line(handle, fn -> %{"type" => "reset"} end)
  end

  @doc """
  Append a `model_change` entry (PI's session entry type): the session was
  switched to this model, and a crash-restarted server should resume with it
  rather than the boot default. Best-effort like `append_message/2`.
  """
  @spec append_model_change(handle(), Catalyst.Model.t() | nil) :: :ok
  def append_model_change(handle, %Catalyst.Model{} = model) do
    append_line(handle, fn ->
      %{"type" => "model_change", "model" => Codec.encode_model(model)}
    end)
  end

  def append_model_change(handle, nil) do
    append_line(handle, fn -> %{"type" => "model_change", "model" => nil} end)
  end

  @doc "Append a `thinking_level_change` entry (the session's reasoning effort changed)."
  @spec append_thinking_level_change(handle(), String.t() | nil) :: :ok
  def append_thinking_level_change(handle, level) when is_binary(level) do
    append_line(handle, fn -> %{"type" => "thinking_level_change", "level" => level} end)
  end

  def append_thinking_level_change(handle, nil) do
    append_line(handle, fn -> %{"type" => "thinking_level_change", "level" => nil} end)
  end

  @doc """
  Fold the settings entries: the LAST persisted model/thinking level plus flags
  recording whether each setting has ever been written. A written `nil` is an
  explicit clear tombstone, distinct from a fresh session with no entry.
  Deliberately independent of `reset` markers — a transcript reset does not
  undo a model choice.
  """
  @spec load_settings(String.t()) :: %{
          model: Catalyst.Model.t() | nil,
          model_set?: boolean(),
          thinking_level: String.t() | nil,
          thinking_level_set?: boolean()
        }
  def load_settings(path) do
    path
    |> load_state()
    |> Map.take([:model, :model_set?, :thinking_level, :thinking_level_set?])
  rescue
    _ -> empty_settings()
  end

  defp empty_settings do
    Map.take(empty_loaded_state(), [:model, :model_set?, :thinking_level, :thinking_level_set?])
  end

  # Encode + write inside the rescue, so neither a Jason failure (tool results
  # can carry values JSON can't represent) nor a disk error propagates into the
  # session server.
  defp append_line(%{id: id, path: path}, build) do
    File.write!(path, line(build.()), [:append])
  rescue
    error ->
      Logger.warning("session #{id}: failed to append to #{path}: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Load the transcript and persisted settings in one pass through a session file.

  Messages are chronological and only those after the last reset are returned.
  Setting changes are independent of reset markers. The `*_set?` fields
  distinguish an explicit `nil` tombstone from a setting that was never written.
  Corrupt and unknown lines are skipped.
  """
  @spec load_state(String.t()) :: loaded_state()
  def load_state(path) do
    path
    |> File.stream!()
    |> Enum.reduce(empty_loaded_state(), &fold_state_line/2)
    |> Map.update!(:messages, &Enum.reverse/1)
  end

  @doc "Load the messages from a session file (header skipped, last reset honored)."
  @spec load(String.t()) :: [Message.t()]
  def load(path), do: load_state(path).messages

  defp line(map), do: Jason.encode!(map) <> "\n"

  @doc "Encode a session message into its persisted JSON map."
  @spec encode(Message.t()) :: map()
  defdelegate encode(message), to: Codec

  @doc "Decode a persisted JSON message map back into a session message."
  @spec decode(map()) :: Message.t()
  defdelegate decode(message), to: Codec

  defp empty_loaded_state do
    %{
      messages: [],
      model: nil,
      model_set?: false,
      thinking_level: nil,
      thinking_level_set?: false
    }
  end

  # Decode each JSON line once. Failures are isolated to the line so a corrupt
  # or forward-versioned entry cannot make the whole session unloadable.
  defp fold_state_line(line, state) do
    case Jason.decode(String.trim(line)) do
      {:ok, entry} -> fold_entry(entry, state)
      {:error, _reason} -> state
    end
  rescue
    _error -> state
  end

  defp fold_entry(%{"type" => "message", "message" => message}, state) do
    %{state | messages: [Codec.decode(message) | state.messages]}
  end

  defp fold_entry(%{"type" => "reset"}, state), do: %{state | messages: []}

  defp fold_entry(%{"type" => "model_change", "model" => nil}, state) do
    %{state | model: nil, model_set?: true}
  end

  defp fold_entry(%{"type" => "model_change", "model" => encoded}, state)
       when is_map(encoded) do
    case Codec.decode_model(encoded) do
      {:ok, model} -> %{state | model: model, model_set?: true}
      :error -> state
    end
  end

  defp fold_entry(
         %{"type" => "thinking_level_change", "level" => level},
         state
       )
       when is_binary(level) do
    %{state | thinking_level: level, thinking_level_set?: true}
  end

  defp fold_entry(%{"type" => "thinking_level_change", "level" => nil}, state) do
    %{state | thinking_level: nil, thinking_level_set?: true}
  end

  defp fold_entry(_entry, state), do: state

  # ---- helpers --------------------------------------------------------------

  defp gen_id, do: Catalyst.Ids.hex(16)

  defp cwd_hash(cwd),
    do: :sha256 |> :crypto.hash(cwd) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
