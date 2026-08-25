defmodule Catalyst.Session.Store do
  @moduledoc """
  Append-only JSONL persistence for a session (PI's JSONL session repo).

  Layout: `~/.catalyst/sessions/<cwd-hash>/<id>.jsonl`. Line 1 is a session
  header; each subsequent line is a `{"type":"message","message":{…}}` entry,
  appended as the single writer (`Catalyst.Session.Server`) sees `message_end`.
  `load/1` folds the lines back into a message list for resume.
  """

  require Logger

  alias Catalyst.{Content, Message, Model, Usage}
  alias Catalyst.Context.Transcript

  @type decode_error ::
          {:invalid_message, term()}
          | {:unknown_role, term()}
          | {:invalid_content, term()}
          | {:invalid_content_block, term()}
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
          workflow: String.t() | nil,
          workflow_set?: boolean(),
          system_prompt: String.t() | nil,
          system_prompt_set?: boolean(),
          parent_id: String.t() | nil,
          root_session_id: String.t() | nil,
          agent_depth: non_neg_integer()
        }
  @type persisted_settings :: %{
          model: Catalyst.Model.t() | nil,
          thinking_level: String.t() | nil,
          workflow: String.t() | nil,
          system_prompt: String.t() | nil
        }

  @doc "Root directory for all session logs (override with `config :catalyst, :sessions_root`)."
  @spec root() :: String.t()
  def root,
    do: Application.get_env(:catalyst, :sessions_root) || Catalyst.Paths.sessions()

  @doc """
  Absolute path of the session JSONL for a `{cwd, id}` pair, without touching
  disk. `Catalyst.Session.Catalog` uses it to prune entries whose transcripts
  were deleted.
  """
  @spec path_for(String.t(), String.t()) :: Path.t()
  def path_for(cwd, id) when is_binary(cwd) and is_binary(id),
    do: Path.join([root(), cwd_hash(cwd), id <> ".jsonl"])

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
        "replacement" => Enum.map(compaction.replacement, &encode/1),
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
      %{"type" => "model_change", "model" => encode_model(model)}
    end)
  end

  def append_model_change(handle, nil) do
    append_line(handle, fn -> %{"type" => "model_change", "model" => nil} end)
  end

  @doc """
  Append a `settings_snapshot` entry (authoritative snapshot of current settings).

  Every field is written on each snapshot; a `nil` is an explicit clear
  tombstone. Entries written before the `workflow`/`system_prompt` fields
  existed simply omit those keys, and the loader treats an absent key as
  "never written" rather than a clear.
  """
  @spec append_settings_snapshot(handle(), persisted_settings()) ::
          :ok | {:error, append_error()}
  def append_settings_snapshot(handle, %{} = settings) do
    case valid_settings?(settings) do
      true ->
        append_line(handle, fn ->
          %{
            "type" => "settings_snapshot",
            "model" => encode_setting_model(settings.model),
            "thinking_level" => settings.thinking_level,
            "workflow" => settings.workflow,
            "system_prompt" => settings.system_prompt
          }
        end)

      false ->
        {:error, {:build_failed, :invalid_settings_snapshot}}
    end
  end

  def append_settings_snapshot(_handle, settings),
    do: {:error, {:build_failed, {:invalid_settings_snapshot, settings}}}

  defp valid_settings?(settings) do
    match?(
      %{model: model, thinking_level: level, workflow: workflow, system_prompt: prompt}
      when (is_struct(model, Catalyst.Model) or is_nil(model)) and
             (is_binary(level) or is_nil(level)) and
             (is_binary(workflow) or is_nil(workflow)) and
             (is_binary(prompt) or is_nil(prompt)),
      settings
    )
  end

  def append_thinking_level_change(handle, level) when is_binary(level) or is_nil(level) do
    append_line(handle, fn -> %{"type" => "thinking_level_change", "level" => level} end)
  end

  # test seam. Folds the settings entries: the LAST persisted model/thinking
  # level/workflow/system prompt plus flags recording whether each setting has
  # ever been written. A written nil is an explicit clear tombstone, distinct
  # from a fresh session with no entry. Deliberately independent of `reset`
  # markers — a transcript reset does not undo a model choice.
  @doc false
  @spec load_settings(String.t()) :: %{
          model: Catalyst.Model.t() | nil,
          model_set?: boolean(),
          thinking_level: String.t() | nil,
          thinking_level_set?: boolean(),
          workflow: String.t() | nil,
          workflow_set?: boolean(),
          system_prompt: String.t() | nil,
          system_prompt_set?: boolean()
        }
  def load_settings(path) do
    case load_state(path) do
      {:ok, state} ->
        Map.take(state, settings_keys())

      {:error, reason} ->
        Logger.warning(
          "[session_store] could not load settings from #{inspect(path)}: #{inspect(reason)}"
        )

        empty_settings()
    end
  end

  defp settings_keys do
    [
      :model,
      :model_set?,
      :thinking_level,
      :thinking_level_set?,
      :workflow,
      :workflow_set?,
      :system_prompt,
      :system_prompt_set?
    ]
  end

  defp empty_settings do
    Map.take(empty_loaded_state(), settings_keys())
  end

  defp append_line(handle, build) do
    with {:ok, entry} <- build_entry(build),
         {:ok, encoded} <- encode_entry(entry),
         :ok <- write_entry(handle, encoded) do
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
      {:error, _reason} -> encode_entry_without_details(entry)
    end
  rescue
    error -> {:error, {:encode_failed, error}}
  catch
    kind, reason -> {:error, {:encode_failed, {kind, reason}}}
  end

  # Details are best-effort JSON: when the full line fails to encode, retry once
  # with the tool-result details dropped rather than losing the whole message.
  defp encode_entry_without_details(%{"message" => %{"details" => details} = message} = entry)
       when not is_nil(details) do
    case Jason.encode(%{entry | "message" => %{message | "details" => nil}}) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp encode_entry_without_details(entry), do: {:error, {:encode_failed, {:invalid_json, entry}}}

  # Deliberately re-opens the file per append: a held raw device keeps
  # "succeeding" into the unlinked inode after the JSONL is deleted or
  # replaced, silently reporting durable success for writes that are lost —
  # the exact failure the tagged {:write_failed, _} contract exists to surface
  # (pinned by the server_test failed-reset/failed-compaction tests).
  defp write_entry(%{path: path}, encoded) do
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
  def encode(%Message.User{content: content, timestamp: timestamp}) do
    %{"role" => "user", "content" => encode_content(content), "timestamp" => timestamp}
  end

  def encode(%Message.Assistant{} = message) do
    %{
      "role" => "assistant",
      "content" => encode_content(message.content),
      "api" => message.api,
      "provider" => message.provider,
      "model" => message.model,
      "usage" => encode_usage(message.usage),
      "stopReason" => to_string(message.stop_reason),
      "errorMessage" => message.error_message,
      "responseId" => message.response_id,
      "timestamp" => message.timestamp
    }
  end

  def encode(%Message.ToolResult{} = message) do
    %{
      "role" => "toolResult",
      "toolCallId" => message.tool_call_id,
      "toolName" => message.tool_name,
      "content" => encode_content(message.content),
      "isError" => message.is_error,
      "details" => message.details,
      "timestamp" => message.timestamp
    }
  end

  # test seam: decode a persisted JSON message map back into a session message.
  @doc false
  @spec decode(term()) :: {:ok, Message.t()} | {:error, decode_error()}
  def decode(%{"role" => "user"} = message) do
    with {:ok, content} <- decode_content(message["content"]) do
      {:ok, %Message.User{content: content, timestamp: message["timestamp"]}}
    end
  end

  def decode(%{"role" => "assistant"} = message) do
    with {:ok, content} <- decode_content(message["content"]) do
      {:ok,
       %Message.Assistant{
         content: content,
         api: message["api"],
         provider: message["provider"],
         model: message["model"],
         usage: decode_usage(message["usage"]),
         stop_reason: decode_reason(message["stopReason"]),
         error_message: message["errorMessage"],
         response_id: message["responseId"],
         timestamp: message["timestamp"]
       }}
    end
  end

  def decode(%{"role" => "toolResult"} = message) do
    with {:ok, content} <- decode_content(message["content"]) do
      {:ok,
       %Message.ToolResult{
         tool_call_id: message["toolCallId"],
         tool_name: message["toolName"],
         content: content,
         details: message["details"],
         is_error: message["isError"] || false,
         timestamp: message["timestamp"]
       }}
    end
  end

  def decode(%{"role" => role}), do: {:error, {:unknown_role, role}}
  def decode(invalid), do: {:error, {:invalid_message, invalid}}

  @doc "Encode a model descriptor for a persisted `model_change` entry."
  @spec encode_model(Model.t()) :: map()
  def encode_model(%Model{} = model) do
    %{
      "id" => model.id,
      "name" => model.name,
      "api" => model.api,
      "provider" => model.provider,
      "baseUrl" => model.base_url,
      "reasoning" => model.reasoning,
      "input" => Enum.map(model.input || [], &to_string/1),
      "contextWindow" => model.context_window,
      "maxContextWindow" => model.max_context_window,
      "effectiveContextWindowPercent" => model.effective_context_window_percent,
      "autoCompactTokenLimit" => model.auto_compact_token_limit,
      "contextWindowSource" => encode_context_window_source(model.context_window_source),
      "maxTokens" => model.max_tokens
    }
  end

  @doc "Decode a persisted model map, returning `:error` for an invalid shape."
  @spec decode_model(term()) :: {:ok, Model.t()} | :error
  def decode_model(%{"id" => id} = model) when is_binary(id) do
    {:ok,
     %Model{
       id: id,
       name: model["name"],
       api: model["api"],
       provider: model["provider"],
       base_url: model["baseUrl"],
       reasoning: model["reasoning"],
       input: decode_model_input(model["input"]),
       context_window: model["contextWindow"],
       max_context_window: model["maxContextWindow"],
       effective_context_window_percent: model["effectiveContextWindowPercent"],
       auto_compact_token_limit: model["autoCompactTokenLimit"],
       context_window_source: decode_context_window_source(model["contextWindowSource"]),
       max_tokens: model["maxTokens"]
     }}
  end

  def decode_model(_malformed), do: :error

  defp empty_loaded_state do
    %{
      messages: [],
      model: nil,
      model_set?: false,
      thinking_level: nil,
      thinking_level_set?: false,
      workflow: nil,
      workflow_set?: false,
      system_prompt: nil,
      system_prompt_set?: false,
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
         %{"type" => "settings_snapshot", "model" => encoded, "thinking_level" => level} = entry,
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
        |> fold_optional_setting(entry, "workflow", :workflow, :workflow_set?)
        |> fold_optional_setting(entry, "system_prompt", :system_prompt, :system_prompt_set?)

      :error ->
        state
    end
  end

  defp fold_entry(%{"type" => "message", "message" => message}, state) do
    case decode(message) do
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
         :ok <- Transcript.validate_transcript(decoded) do
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
    case decode_model(encoded) do
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

  # Legacy `settings_snapshot` lines predate the workflow/system_prompt keys:
  # only a PRESENT key is a value-or-tombstone write. An absent key must not
  # fabricate a clear, and a malformed value is skipped like any corrupt line.
  defp fold_optional_setting(state, entry, key, field, flag) do
    case Map.fetch(entry, key) do
      {:ok, value} when is_binary(value) or is_nil(value) ->
        state |> Map.put(field, value) |> Map.put(flag, true)

      _absent_or_invalid ->
        state
    end
  end

  defp decode_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn encoded, {:ok, acc} ->
      case decode(encoded) do
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
  defp encode_optional_message(message), do: encode(message)

  defp encode_setting_model(nil), do: nil
  defp encode_setting_model(%Catalyst.Model{} = model), do: encode_model(model)

  defp decode_setting_model(nil), do: {:ok, nil}
  defp decode_setting_model(%{} = model), do: decode_model(model)
  defp decode_setting_model(_model), do: :error

  defp valid_optional_id(value) when is_binary(value), do: value
  defp valid_optional_id(_value), do: nil

  defp valid_depth(value) when is_integer(value) and value >= 0, do: value
  defp valid_depth(_value), do: 0

  defp cwd_hash(cwd),
    do: :sha256 |> :crypto.hash(cwd) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp decode_model_input(input) when is_list(input) do
    Enum.flat_map(input, fn
      "text" -> [:text]
      "image" -> [:image]
      _unknown -> []
    end)
  end

  defp decode_model_input(_input), do: [:text]

  defp encode_usage(nil), do: nil

  defp encode_usage(%Usage{} = usage) do
    %{
      "input" => usage.input,
      "output" => usage.output,
      "cacheRead" => usage.cache_read,
      "cacheWrite" => usage.cache_write,
      "totalTokens" => usage.total_tokens,
      "cost" => usage.cost,
      "contextDigest" => usage.context_digest
    }
  end

  defp encode_content(content) when is_list(content), do: Enum.map(content, &encode_block/1)

  # Tool results are duck-typed (extension/LLM-authored tools return arbitrary
  # shapes), so non-list content is wrapped as a single block rather than crash.
  defp encode_content(other), do: [encode_block(other)]

  defp encode_block(%Content.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_block(%Content.Thinking{} = block) do
    %{
      "type" => "thinking",
      "thinking" => block.thinking,
      "signature" => block.signature,
      "redacted" => block.redacted
    }
  end

  defp encode_block(%Content.Image{data: data, mime_type: mime_type}) do
    %{"type" => "image", "data" => data, "mimeType" => mime_type}
  end

  defp encode_block(%Content.ToolCall{id: id, name: name, arguments: arguments}) do
    %{"type" => "toolCall", "id" => id, "name" => name, "arguments" => arguments}
  end

  # Unknown block shapes degrade to inspected text so the line stays decodable.
  defp encode_block(other), do: %{"type" => "text", "text" => inspect(other)}

  defp decode_usage(%{} = usage) do
    %Usage{
      input: usage["input"] || 0,
      output: usage["output"] || 0,
      cache_read: usage["cacheRead"] || 0,
      cache_write: usage["cacheWrite"] || 0,
      total_tokens: usage["totalTokens"] || 0,
      cost: usage["cost"] || 0.0,
      context_digest: usage["contextDigest"]
    }
  end

  defp decode_usage(_usage), do: %Usage{}

  defp decode_content(nil), do: {:ok, []}

  defp decode_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case decode_block(block) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end)
  end

  defp decode_content(invalid), do: {:error, {:invalid_content, invalid}}

  defp decode_block(%{"type" => "text", "text" => text}),
    do: {:ok, %Content.Text{text: text}}

  defp decode_block(%{"type" => "thinking"} = block) do
    {:ok,
     %Content.Thinking{
       thinking: block["thinking"],
       signature: block["signature"],
       redacted: block["redacted"] || false
     }}
  end

  defp decode_block(%{"type" => "image"} = block) do
    {:ok, %Content.Image{data: block["data"], mime_type: block["mimeType"]}}
  end

  defp decode_block(%{"type" => "toolCall"} = block) do
    {:ok,
     %Content.ToolCall{
       id: block["id"],
       name: block["name"],
       arguments: block["arguments"] || %{}
     }}
  end

  defp decode_block(invalid), do: {:error, {:invalid_content_block, invalid}}

  # Explicit clauses, not `String.to_existing_atom/1`: in an interactive
  # (lazily loaded) VM the target atom only exists once some module using it
  # has been loaded, so whitelist+to_existing_atom crashes on load order —
  # which made `Store.load_state/1` return `{:error, {:read_failed, ...}}`
  # and resume an empty transcript.
  defp decode_reason("stop"), do: :stop
  defp decode_reason("length"), do: :length
  defp decode_reason("tool_use"), do: :tool_use
  defp decode_reason("error"), do: :error
  defp decode_reason("aborted"), do: :aborted
  defp decode_reason(_reason), do: :stop

  defp encode_context_window_source(nil), do: nil
  defp encode_context_window_source(source), do: to_string(source)

  defp decode_context_window_source("session"), do: :session
  defp decode_context_window_source("catalog"), do: :catalog
  defp decode_context_window_source("persisted"), do: :persisted
  defp decode_context_window_source("fallback"), do: :fallback
  defp decode_context_window_source(_source), do: nil
end
