defmodule Catalyst.Tools.ListAgents do
  @moduledoc """
  Discovers the file-backed subagent definitions available for `spawn_agent`.

  Definitions are read fresh from the configured agents directory on every
  execution. Only safe `*.md` basenames are admitted; the model-provided name is
  never interpolated into a path. V1 intentionally has no frontmatter parser.
  """

  use Catalyst.Tools.Tool

  alias Catalyst.Tools.Truncate

  @name_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @preview_bytes 200

  @typedoc "One validated file-backed agent definition."
  @type entry :: %{name: String.t(), path: Path.t(), preview: String.t()}

  @impl true
  def name, do: "list_agents"

  @impl true
  def description do
    "List file-backed subagents available to spawn, including their source paths and prompt previews."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{},
      "additionalProperties" => false
    }
  end

  @impl true
  def execute(_args, _ctx) do
    case list() do
      {:ok, []} ->
        result("No subagent definitions are available in #{agents_dir()}.", %{agents: []})

      {:ok, entries} ->
        text = Enum.map_join(entries, "\n", &format_entry/1)
        result(text, %{agents: entries})

      {:error, reason} ->
        raise "list_agents failed: #{inspect(reason)}"
    end
  end

  @doc "Enumerate and preview every valid agent definition."
  @spec list() :: {:ok, [entry()]} | {:error, term()}
  def list do
    dir = agents_dir()

    case File.ls(dir) do
      {:ok, names} -> {:ok, entries(dir, names)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:list_agents_dir, dir, reason}}
    end
  end

  @doc "Resolve and freshly read a named definition without joining an unvalidated argument."
  @spec fetch(String.t()) :: {:ok, %{entry: entry(), prompt: String.t()}} | {:error, term()}
  def fetch(name) do
    with :ok <- validate_name(name),
         {:ok, agents} <- list(),
         {:ok, entry} <- find_entry(agents, name),
         {:ok, prompt} <- read_prompt(entry) do
      {:ok, %{entry: entry, prompt: prompt}}
    end
  end

  @doc "Validate a V1 agent name (1-64 ASCII letters, digits, underscores, or hyphens)."
  @spec validate_name(term()) :: :ok | {:error, term()}
  def validate_name(name) do
    case is_binary(name) and String.valid?(name) and Regex.match?(@name_pattern, name) do
      true -> :ok
      false -> {:error, {:invalid_agent_name, name}}
    end
  end

  @doc "The fresh agent-definition directory (test-overridable with `config :catalyst, :agents_dir`)."
  @spec agents_dir() :: Path.t()
  def agents_dir do
    :catalyst
    |> Application.get_env(:agents_dir, Catalyst.Paths.agents())
    |> Path.expand()
  end

  defp entries(dir, names) do
    names
    |> Enum.flat_map(&entry(dir, &1))
    |> Enum.sort_by(& &1.name)
  end

  defp entry(dir, filename) do
    with true <- Path.extname(filename) == ".md",
         name = Path.rootname(filename, ".md"),
         :ok <- validate_name(name),
         path = Path.join(dir, filename),
         true <- File.regular?(path),
         {:ok, preview} <- preview(path) do
      [%{name: name, path: path, preview: preview}]
    else
      _invalid_or_unreadable -> []
    end
  end

  defp preview(path) do
    path
    |> File.stream!(:line, [])
    |> Enum.find_value("", fn line ->
      line = line |> Truncate.scrub_utf8() |> String.trim()

      case line do
        "" -> false
        nonblank -> nonblank
      end
    end)
    |> Truncate.head(max_lines: 1, max_bytes: @preview_bytes)
    |> then(fn {text, _info} -> {:ok, text} end)
  rescue
    error -> {:error, {:read_agent_preview, path, Exception.message(error)}}
  end

  defp find_entry(entries, name) do
    case Enum.find(entries, &(&1.name == name)) do
      nil -> {:error, {:unknown_agent, name}}
      entry -> {:ok, entry}
    end
  end

  defp read_prompt(entry) do
    case File.read(entry.path) do
      {:ok, prompt} -> normalize_prompt(entry.name, prompt)
      {:error, reason} -> {:error, {:read_agent, entry.path, reason}}
    end
  end

  defp normalize_prompt(name, prompt) do
    prompt = Truncate.scrub_utf8(prompt)

    case String.trim(prompt) do
      "" -> {:error, {:blank_agent_prompt, name}}
      _nonblank -> {:ok, prompt}
    end
  end

  defp format_entry(entry) do
    preview =
      case entry.preview do
        "" -> "(blank prompt)"
        nonblank -> nonblank
      end

    "#{entry.name} — #{preview} (#{entry.path})"
  end
end
