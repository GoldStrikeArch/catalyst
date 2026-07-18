defmodule Catalyst.Session.Store do
  @moduledoc """
  Append-only JSONL persistence for a session (PI's JSONL session repo).

  Layout: `~/.catalyst/sessions/<cwd-hash>/<id>.jsonl`. Line 1 is a session
  header; each subsequent line is a `{"type":"message","message":{…}}` entry,
  appended as the single writer (`Catalyst.Session.Server`) sees `message_end`.
  `load/1` folds the lines back into a message list for resume.
  """

  require Logger

  alias Catalyst.Context.Window
  alias Catalyst.Message
  alias Catalyst.Session.Store.Codec

  @type handle :: %{id: String.t(), path: String.t(), cwd: String.t()}
  @type open_error ::
          {:invalid_cwd, term()}
          | {:invalid_store_path, term()}
          | {:mkdir_failed, File.posix()}
          | {:write_failed, File.posix()}
          | {:encode_failed, term()}
  @type load_error :: {:invalid_store_path, term()} | {:read_failed, term()}
  @type append_error ::
          {:build_failed, term()}
          | {:encode_failed, term()}
          | {:write_failed, File.posix()}
  @type loaded_state :: %{
          messages: [Message.t()],
          model: Catalyst.Model.t() | nil,
          model_set?: boolean(),
          thinking_level: String.t() | nil,
          thinking_level_set?: boolean(),
          parent_id: String.t() | nil,
          root_session_id: String.t() | nil,
          agent_depth: non_neg_integer()
        }

  @doc "Root directory for all session logs (override with `config :catalyst, :sessions_root`)."
  def root,
    do: Application.get_env(:catalyst, :sessions_root) || Catalyst.Paths.sessions()

  @doc """
  Open the session file for an id, creating it with a header line if it does
  not exist yet; returns `{:ok, handle}`. An existing file is left untouched so
  a crash-restarted `Session.Server` can resume it via `load/1`.
  """
  @spec open(String.t(), keyword()) :: {:ok, handle()} | {:error, open_error()}
  def open(cwd, opts \\ [])

  def open(cwd, opts) when is_binary(cwd) and is_list(opts) do
    with {:ok, handle, header} <- handle_and_header(cwd, opts),
         :ok <- ensure_session_file(handle.path, header) do
      {:ok, handle}
    end
  end

  def open(cwd, _opts), do: {:error, {:invalid_cwd, cwd}}

  @doc """
  Legacy wrapper for `open/2` that raises on failure. Prefer `open/2`.
  """
  @spec new(String.t(), keyword()) :: handle()
  def new(cwd, opts \\ []) do
    case open(cwd, opts) do
      {:ok, handle} -> handle
      {:error, reason} -> raise "failed to open session store: #{inspect(reason)}"
    end
  end

  @doc """
  Exclusively create a fresh session file. Existing live or on-disk child ids
  are collisions and are never resumed/adopted by `spawn_agent`.
  """
  @spec create_new(String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def create_new(cwd, opts \\ [])

  def create_new(cwd, opts) when is_binary(cwd) and is_list(opts) do
    case handle_and_header(cwd, opts) do
      {:ok, handle, header} ->
        with {:ok, encoded} <- encode_header(header),
             :ok <- create_file(handle.path, encoded) do
          {:ok, handle}
        else
          {:error, :eexist} -> {:error, {:session_exists, handle.id}}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def create_new(cwd, _opts), do: {:error, {:invalid_cwd, cwd}}

  @doc """
  Append one message as a JSONL line.

  The session server deliberately treats ordinary message failures as
  best-effort. Callers that require durability, such as context compaction,
  must propagate the tagged error.
  """
  @spec append_message(handle(), Message.t()) :: :ok | {:error, append_error()}
  def append_message(handle, message) do
    append_line(handle, fn -> %{"type" => "message", "message" => encode(message)} end)
  end

  @doc """
  Append a reset marker. `load/1` discards every message before the last
  marker, so a session reset survives crash-restarts without rewriting the
  append-only file.
  """
  @spec append_reset(handle()) :: :ok | {:error, append_error()}
  def append_reset(handle) do
    append_line(handle, fn -> %{"type" => "reset"} end)
  end

  @doc "Append an authoritative chronological transcript replacement."
  @spec append_compaction(handle(), Catalyst.Agent.Event.ContextCompacted.t() | map()) ::
          :ok | {:error, append_error()}
  def append_compaction(handle, compaction) do
    append_line(handle, fn ->
      %{
        "type" => "compaction",
        "replacement" => Enum.map(compaction.replacement, &Codec.encode/1),
        "summary" => encode_optional_message(Map.get(compaction, :summary)),
        "replacedCount" => Map.get(compaction, :replaced_count),
        "tokensBefore" => Map.get(compaction, :tokens_before),
        "tokensAfter" => Map.get(compaction, :tokens_after),
        "policy" => inspect(Map.get(compaction, :policy))
      }
    end)
  end

  @doc """
  Append a `model_change` entry (PI's session entry type): the session was
  switched to this model, and a crash-restarted server should resume with it
  rather than the boot default.
  """
  @spec append_model_change(handle(), Catalyst.Model.t() | nil) ::
          :ok | {:error, append_error()}
  def append_model_change(handle, %Catalyst.Model{} = model) do
    append_line(handle, fn ->
      %{"type" => "model_change", "model" => Codec.encode_model(model)}
    end)
  end

  def append_model_change(handle, nil) do
    append_line(handle, fn -> %{"type" => "model_change", "model" => nil} end)
  end

  @doc """
  Append a `settings_snapshot` entry (authoritative snapshot of current settings).
  """
  @spec append_settings_snapshot(handle(), Catalyst.Model.t() | nil, String.t() | nil) ::
          :ok | {:error, append_error()}
  def append_settings_snapshot(handle, model, level)
      when (is_struct(model, Catalyst.Model) or is_nil(model)) and
             (is_binary(level) or is_nil(level)) do
    append_line(handle, fn ->
      %{
        "type" => "settings_snapshot",
        "model" => encode_setting_model(model),
        "thinking_level" => level
      }
    end)
  end

  def append_settings_snapshot(_handle, _model, _level),
    do: {:error, {:build_failed, :invalid_settings_snapshot}}

  def append_thinking_level_change(handle, level) when is_binary(level) or is_nil(level) do
    append_line(handle, fn -> %{"type" => "thinking_level_change", "level" => level} end)
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
    case load_state(path) do
      {:ok, state} ->
        Map.take(state, [:model, :model_set?, :thinking_level, :thinking_level_set?])

      {:error, reason} ->
        Logger.warning(
          "[session_store] could not load settings from #{inspect(path)}: #{inspect(reason)}"
        )

        empty_settings()
    end
  end

  defp empty_settings do
    Map.take(empty_loaded_state(), [:model, :model_set?, :thinking_level, :thinking_level_set?])
  end

  defp append_line(%{path: path}, build) do
    with {:ok, entry} <- build_entry(build),
         {:ok, encoded} <- encode_entry(entry),
         :ok <- write_entry(path, encoded) do
      :ok
    end
  end

  defp build_entry(build) do
    {:ok, build.()}
  rescue
    error -> {:error, {:build_failed, error}}
  catch
    kind, reason -> {:error, {:build_failed, {kind, reason}}}
  end

  defp encode_entry(entry) do
    case Jason.encode(entry) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  rescue
    error -> {:error, {:encode_failed, error}}
  catch
    kind, reason -> {:error, {:encode_failed, {kind, reason}}}
  end

  defp write_entry(path, encoded) do
    case File.write(path, encoded <> "\n", [:append]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp ensure_session_file(path, header) do
    with {:ok, encoded} <- encode_header(header) do
      case create_file(path, encoded) do
        :ok -> :ok
        {:error, :eexist} -> ensure_regular_file(path)
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    end
  end

  defp encode_header(header) do
    case Jason.encode(header) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp create_file(path, encoded) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          IO.binwrite(io, encoded)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_store_path, type}}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp read_state(io) do
    try do
      state =
        io
        |> IO.binstream(:line)
        |> Enum.reduce(empty_loaded_state(), &fold_state_line/2)
        |> Map.update!(:messages, &Enum.reverse/1)

      {:ok, state}
    rescue
      error in File.Error -> {:error, {:read_failed, error.reason}}
    catch
      kind, reason -> {:error, {:read_failed, {kind, reason}}}
    after
      File.close(io)
    end
  end

  @doc """
  Load the transcript and persisted settings in one pass through a session file.

  Messages are chronological and only those after the last reset are returned.
  Setting changes are independent of reset markers. The `*_set?` fields
  distinguish an explicit `nil` tombstone from a setting that was never written.
  Corrupt and unknown lines are skipped.
  """
  @spec load_state(String.t()) :: {:ok, loaded_state()} | {:error, load_error()}
  def load_state(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} -> read_state(io)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  def load_state(path), do: {:error, {:invalid_store_path, path}}

  @doc "Load the messages from a session file (header skipped, last reset honored)."
  @spec load(String.t()) :: [Message.t()]
  def load(path) do
    case load_state(path) do
      {:ok, state} -> state.messages
      {:error, _} -> []
    end
  end

  @doc "Encode a session message into its persisted JSON map."
  @spec encode(Message.t()) :: map()
  defdelegate encode(message), to: Codec

  @doc "Decode a persisted JSON message map back into a session message."
  @spec decode(term()) :: {:ok, Message.t()} | {:error, Codec.decode_error()}
  defdelegate decode(message), to: Codec

  defp empty_loaded_state do
    %{
      messages: [],
      model: nil,
      model_set?: false,
      thinking_level: nil,
      thinking_level_set?: false,
      parent_id: nil,
      root_session_id: nil,
      agent_depth: 0
    }
  end

  # Decode each JSON line once. Failures are isolated to the line so a corrupt
  # or forward-versioned entry cannot make the whole session unloadable.
  defp fold_state_line(line, state) do
    case Jason.decode(String.trim(line)) do
      {:ok, entry} -> fold_entry(entry, state)
      {:error, _reason} -> state
    end
  end

  defp fold_entry(
         %{"type" => "settings_snapshot", "model" => encoded, "thinking_level" => level},
         state
       )
       when is_binary(level) or is_nil(level) do
    case decode_setting_model(encoded) do
      {:ok, model} ->
        %{
          state
          | model: model,
            model_set?: true,
            thinking_level: level,
            thinking_level_set?: true
        }

      :error ->
        state
    end
  end

  defp fold_entry(%{"type" => "message", "message" => message}, state) do
    case Codec.decode(message) do
      {:ok, decoded} -> %{state | messages: [decoded | state.messages]}
      {:error, _reason} -> state
    end
  end

  defp fold_entry(%{"type" => "session"} = header, state) do
    %{
      state
      | parent_id: valid_optional_id(header["parentId"]),
        root_session_id: valid_optional_id(header["rootSessionId"]),
        agent_depth: valid_depth(header["agentDepth"])
    }
  end

  defp fold_entry(%{"type" => "compaction", "replacement" => replacement}, state)
       when is_list(replacement) and replacement != [] do
    with {:ok, decoded} <- decode_messages(replacement),
         :ok <- Window.validate_transcript(decoded) do
      %{state | messages: Enum.reverse(decoded)}
    else
      {:error, _reason} -> state
    end
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

  defp decode_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn encoded, {:ok, acc} ->
      case Codec.decode(encoded) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end)
  end

  # ---- helpers --------------------------------------------------------------

  defp gen_id, do: Catalyst.Ids.hex(16)

  defp handle_and_header(cwd, opts) do
    id = Keyword.get(opts, :id) || gen_id()
    dir = Path.join(root(), cwd_hash(cwd))

    case File.mkdir_p(dir) do
      :ok ->
        path = Path.join(dir, id <> ".jsonl")

        header =
          %{
            "type" => "session",
            "version" => 1,
            "id" => id,
            "cwd" => cwd,
            "timestamp" => Message.now()
          }
          |> maybe_put("parentId", Keyword.get(opts, :parent_id))
          |> maybe_put("rootSessionId", Keyword.get(opts, :root_session_id))
          |> maybe_put("agentDepth", Keyword.get(opts, :agent_depth))

        {:ok, %{id: id, path: path, cwd: cwd}, header}

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encode_optional_message(nil), do: nil
  defp encode_optional_message(message), do: Codec.encode(message)

  defp encode_setting_model(nil), do: nil
  defp encode_setting_model(%Catalyst.Model{} = model), do: Codec.encode_model(model)

  defp decode_setting_model(nil), do: {:ok, nil}
  defp decode_setting_model(%{} = model), do: Codec.decode_model(model)
  defp decode_setting_model(_model), do: :error

  defp valid_optional_id(value) when is_binary(value), do: value
  defp valid_optional_id(_value), do: nil

  defp valid_depth(value) when is_integer(value) and value >= 0, do: value
  defp valid_depth(_value), do: 0

  defp cwd_hash(cwd),
    do: :sha256 |> :crypto.hash(cwd) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
