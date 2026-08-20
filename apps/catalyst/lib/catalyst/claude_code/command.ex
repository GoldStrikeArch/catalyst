defmodule Catalyst.ClaudeCode.Command do
  @moduledoc """
  Validates and builds one official `claude -p` invocation.

  Claude Code's default system prompt remains untouched unless the Catalyst
  session has an explicit override. Overrides are passed through a private
  temporary file rather than process arguments.
  """

  @enforce_keys [:executable, :args]
  defstruct [:executable, :args, :prompt_dir]

  @type t :: %__MODULE__{
          executable: Path.t(),
          args: [String.t()],
          prompt_dir: Path.t() | nil
        }

  @doc "Build one direct Claude command from a user prompt and run configuration."
  @spec build(String.t(), map(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def build(prompt, config, resume_id) when is_binary(prompt) and is_map(config) do
    with :ok <- nonblank(:prompt, prompt),
         {:ok, executable} <- executable(config.opts),
         {:ok, permission_args} <- permission_args(config.opts),
         {:ok, resume_args} <- resume_args(resume_id),
         {:ok, safe_mode_args} <- safe_mode_args(config.opts),
         {:ok, option_args} <- option_args(config.opts),
         {:ok, prompt_args, prompt_dir} <- prompt_args(config) do
      # ponytail: the local macOS experiment passes the prompt in argv; use a
      # half-close-capable stdin helper if same-user process-list privacy matters.
      args =
        [
          "-p",
          prompt,
          "--output-format",
          "stream-json",
          "--verbose",
          "--include-partial-messages"
        ] ++
          safe_mode_args ++
          permission_args ++ resume_args ++ prompt_args ++ option_args

      {:ok, %__MODULE__{executable: executable, args: args, prompt_dir: prompt_dir}}
    end
  end

  def build(prompt, _config, _resume_id), do: {:error, {:invalid_prompt, prompt}}

  @doc "Remove temporary prompt material created for a command."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{prompt_dir: nil}), do: :ok

  def cleanup(%__MODULE__{prompt_dir: dir}) do
    _result = File.rm_rf(dir)
    :ok
  end

  defp executable(opts) do
    configured = Keyword.get(opts, :claude_executable, "claude")

    path =
      case configured do
        path when is_binary(path) ->
          case Path.type(path) do
            :absolute -> path
            _relative -> System.find_executable(path)
          end

        _invalid ->
          nil
      end

    case is_binary(path) and File.regular?(path) do
      true -> {:ok, path}
      false -> {:error, {:claude_executable_not_found, configured}}
    end
  end

  defp prompt_args(%{prompt_override: nil}), do: {:ok, [], nil}

  defp prompt_args(%{prompt_override: prompt, opts: opts}) when is_binary(prompt) do
    mode = Keyword.get(opts, :claude_prompt_mode, :replace)

    with :ok <- nonblank(:system_prompt, prompt),
         {:ok, flag} <- prompt_flag(mode),
         {:ok, dir, path} <- write_prompt(prompt) do
      {:ok, [flag, path], dir}
    end
  end

  defp prompt_args(%{prompt_override: prompt}),
    do: {:error, {:invalid_system_prompt, prompt}}

  defp prompt_flag(:replace), do: {:ok, "--system-prompt-file"}
  defp prompt_flag(:append), do: {:ok, "--append-system-prompt-file"}
  defp prompt_flag(mode), do: {:error, {:invalid_claude_prompt_mode, mode}}

  defp permission_args(opts) do
    case Keyword.get(opts, :claude_permission_mode, :bypass) do
      :bypass ->
        {:ok, ["--dangerously-skip-permissions"]}

      mode when mode in ~w(default acceptEdits plan auto dontAsk manual) ->
        {:ok, ["--permission-mode", mode]}

      mode ->
        {:error, {:invalid_claude_permission_mode, mode}}
    end
  end

  defp resume_args(nil), do: {:ok, []}
  defp resume_args(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, ["--resume", id]}
  defp resume_args(id), do: {:error, {:invalid_claude_session_id, id}}

  defp option_args(opts) do
    with {:ok, model} <- optional_value(opts, :claude_model, "--model"),
         {:ok, effort} <- optional_value(opts, :claude_effort, "--effort"),
         {:ok, tools} <- tools_args(Keyword.get(opts, :claude_tools)) do
      {:ok, model ++ effort ++ tools}
    end
  end

  defp optional_value(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> {:ok, []}
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, [flag, value]}
      value -> {:error, {:invalid_claude_option, key, value}}
    end
  end

  defp tools_args(nil), do: {:ok, []}

  defp tools_args(tools) when is_list(tools) do
    case Enum.all?(tools, &(is_binary(&1) and byte_size(&1) > 0)) do
      true -> {:ok, ["--tools", Enum.join(tools, ",")]}
      false -> {:error, {:invalid_claude_tools, tools}}
    end
  end

  defp tools_args(tools), do: {:error, {:invalid_claude_tools, tools}}

  defp safe_mode_args(opts) do
    case Keyword.get(opts, :claude_safe_mode, true) do
      true -> {:ok, ["--safe-mode"]}
      false -> {:ok, []}
      invalid -> {:error, {:invalid_claude_safe_mode, invalid}}
    end
  end

  defp write_prompt(prompt) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst-claude-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    path = Path.join(dir, "system-prompt")

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, prompt, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, dir, path}
    else
      {:error, reason} ->
        _result = File.rm_rf(dir)
        {:error, {:prompt_file, reason}}
    end
  end

  defp nonblank(_field, value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonblank(field, value), do: {:error, {:invalid_claude_input, field, value}}
end
