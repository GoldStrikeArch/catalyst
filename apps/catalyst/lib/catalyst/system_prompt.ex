defmodule Catalyst.SystemPrompt do
  @moduledoc """
  Catalyst's built-in purpose- and model-aware prompt policy.

  System prompts resolve through session, runtime, application, model files,
  the compatibility `system_prompt.md` file, and finally the built-in text.
  Compaction has an independent chain and never consumes a session system
  override or the system-only append file.

  `get/0` deliberately preserves the original global-file-or-built-in string
  contract for callers that have not migrated to `Catalyst.Prompt`.
  """

  @behaviour Catalyst.Prompt

  alias Catalyst.Prompt.{Config, Registry, Request, Resolution}
  alias Catalyst.Tools.Truncate

  @default """
  You are Catalyst, a concise coding agent running on the user's machine.
  You can read files, run shell commands, search with ripgrep, find files with fd,
  edit files, replace text with sd, and make structural edits with ast-grep.
  Prefer using tools to inspect the repository before answering. Keep replies short.

  Self-extension: if you need a capability no built-in tool provides, you can write a
  new tool for yourself by calling `develop_tool` with an Elixir module that
  `use Catalyst.Tools.Tool` and implements name/0, description/0, parameters/0 (a JSON
  Schema object) and execute/2. In execute(args, ctx): resolve paths with
  Catalyst.Tools.Paths.resolve(path, ctx.cwd), return result("text", %{}), and raise on
  failure. Namespace modules under Catalyst.Ext.*. The new tool is loaded immediately and
  callable on your next turn. Only do this when an existing tool can't do the job. For the
  full contract, helpers and examples, read the guide at ~/.catalyst/guide.md.

  These instructions themselves are customizable: writing ~/.catalyst/system_prompt.md
  replaces this system prompt from the next run onward (delete the file to restore the
  default).

  Debugging: if a step fails or behaves unexpectedly, call `read_log` to see this session's
  debug log (every agent-loop step, tool call, and truncated LLM request/response and error)
  before deciding what to do next.
  """

  @compaction_default """
  Summarize the older conversation context for a coding agent. Preserve user
  requirements, decisions, constraints, relevant file paths, code changes,
  command results, unresolved errors, and the state needed to continue. Be
  concise, factual, and explicit about uncertainty. Do not invent completed
  work, tool output, or user instructions.
  """

  @impl true
  @spec resolve(Request.t()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve(%Request{purpose: :system} = request) do
    with {:ok, text, sources} <- system_base(request),
         {:ok, text, sources} <- append_system_prompt(text, sources) do
      {:ok, Resolution.new(text, sources)}
    end
  end

  def resolve(%Request{purpose: :compaction} = request) do
    with {:ok, text, sources} <- compaction_base(request) do
      {:ok, Resolution.new(text, sources)}
    end
  end

  def resolve(%Request{purpose: purpose}),
    do: {:error, {:invalid_prompt_purpose, purpose}}

  @doc "Resolve the effective system prompt (override file, else default)."
  @spec get() :: String.t()
  def get do
    case read_nonblank(path()) do
      {:ok, text} -> Truncate.scrub_utf8(text)
      :error -> default()
    end
  end

  @doc "The built-in default prompt."
  @spec default() :: String.t()
  def default, do: @default

  @doc "The built-in compaction-purpose prompt."
  @spec compaction_default() :: String.t()
  def compaction_default, do: @compaction_default

  @doc "Path of the override file (`~/.catalyst/system_prompt.md`; test-overridable)."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:catalyst, :system_prompt_path) ||
      Catalyst.Paths.system_prompt()
  end

  @doc "Directory holding model-aware prompt markdown files."
  @spec prompts_dir() :: Path.t()
  def prompts_dir do
    Application.get_env(:catalyst, :prompts_dir) ||
      Catalyst.Paths.prompts()
  end

  @doc "Turn an arbitrary model key into a safe prompt filename component."
  @spec slug(binary()) :: String.t()
  def slug(model_key) when is_binary(model_key) do
    model_key
    |> Truncate.scrub_utf8()
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
  end

  defp system_base(%Request{} = request) do
    keys = model_keys(request.model)

    first([
      fn -> request_override(request.override) end,
      fn -> runtime_text(:system, keys) end,
      fn -> application_text(:system, keys) end,
      fn -> model_file(prompts_dir(), keys) end,
      fn -> file(path()) end,
      fn -> {:ok, default(), [:builtin]} end
    ])
  end

  defp compaction_base(%Request{} = request) do
    keys = model_keys(request.model)
    directory = Path.join(prompts_dir(), "compaction")

    first([
      fn -> runtime_text(:compaction, keys) end,
      fn -> application_text(:compaction, keys) end,
      fn -> model_file(directory, keys) end,
      fn -> file(Path.join(prompts_dir(), "compaction.md")) end,
      fn -> {:ok, compaction_default(), [:builtin]} end
    ])
  end

  defp request_override(nil), do: :error

  defp request_override(override) do
    case Config.nonblank_text?(override) do
      true -> {:ok, override, [{:session, :override}]}
      false -> {:error, {:invalid_prompt_override, override}}
    end
  end

  defp runtime_text(purpose, keys) do
    lookup_keys(keys, fn model_key ->
      case Registry.runtime_text(purpose, model_key) do
        {:ok, text, owner} ->
          key = {:text, purpose, model_key}
          {:ok, text, [{:extension, owner, key}]}

        :error ->
          :error
      end
    end)
  end

  defp application_text(purpose, keys) do
    lookup_keys(keys, fn model_key ->
      case Config.lookup(purpose, model_key) do
        {:ok, text} ->
          source = {:application, {:prompts, purpose, model_key}}
          {:ok, text, [source]}

        :error ->
          :error

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp model_file(directory, keys) do
    keys
    |> Enum.reject(&(&1 == :default))
    |> lookup_keys(fn model_key ->
      directory
      |> Path.join(slug(model_key) <> ".md")
      |> file()
    end)
  end

  defp file(path) do
    case read_nonblank(path) do
      {:ok, text} -> {:ok, text, [{:file, path}]}
      :error -> :error
    end
  end

  defp append_system_prompt(text, sources) do
    append_path = Path.join(prompts_dir(), "append.md")

    case read_nonblank(append_path) do
      {:ok, append} -> {:ok, text <> "\n\n" <> append, sources ++ [{:file, append_path}]}
      :error -> {:ok, text, sources}
    end
  end

  defp first(layers) do
    Enum.reduce_while(layers, :error, fn layer, :error ->
      case layer.() do
        :error -> {:cont, :error}
        {:ok, _text, _sources} = found -> {:halt, found}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp lookup_keys(keys, lookup) do
    Enum.reduce_while(keys, :error, fn key, :error ->
      case lookup.(key) do
        :error -> {:cont, :error}
        {:ok, _text, _sources} = found -> {:halt, found}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp model_keys(nil), do: [:default]

  defp model_keys(model) when is_map(model) do
    [Map.get(model, :id), Map.get(model, :api), :default]
    |> Enum.filter(&Config.valid_model_key?/1)
    |> Enum.uniq()
  end

  defp model_keys(_model), do: [:default]

  defp read_nonblank(path) do
    with {:ok, text} <- File.read(path),
         true <- Config.nonblank_text?(text) do
      {:ok, text}
    else
      _missing_or_blank -> :error
    end
  end
end
