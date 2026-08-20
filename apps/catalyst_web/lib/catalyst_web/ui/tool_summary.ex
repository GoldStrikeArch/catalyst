defmodule CatalystWeb.UI.ToolSummary do
  @moduledoc """
  One-line summaries of tool calls for the transcript.

  A tool call collapses to `{label, detail}`: the label names the action
  ("Read", "Bash") and the detail carries the one argument that identifies
  *this* call (a path, a pattern, the command). The renderer shows the pair on
  a single line; the full arguments live in the disclosure body, so the detail
  is allowed to be lossy — it is truncated, never wrapped.

  Argument keys mirror the `parameters/0` schemas of the built-in tools in
  `Catalyst.Tools.*`. A tool this module does not know — an extension tool, or
  a built-in whose arguments are still streaming in — falls back to a
  humanized name plus compact JSON.

  Pure: no assigns, no markup, no side effects.
  """

  # Details render on one line next to the label; commands get a tighter
  # budget because they are shown in a monospaced face.
  @detail_limit 80
  @command_limit 70

  @doc """
  Summarize a tool call as `{label, detail}`.

  Both halves are plain text ready for interpolation; `detail` is `""` when
  the call carries nothing worth showing.

      iex> CatalystWeb.UI.ToolSummary.summarize("read", %{"path" => "lib/app.ex"})
      {"Read", "lib/app.ex"}

      iex> CatalystWeb.UI.ToolSummary.summarize("grep", %{"pattern" => "defp", "path" => "lib"})
      {"Grep", "defp (lib)"}

      iex> CatalystWeb.UI.ToolSummary.summarize("ls", %{})
      {"List", "."}

      iex> CatalystWeb.UI.ToolSummary.summarize("mystery_tool", %{"depth" => 2})
      {"Mystery tool", "{\\"depth\\":2}"}
  """
  @spec summarize(String.t(), map()) :: {String.t(), String.t()}
  def summarize("read", %{"path" => path}) when is_binary(path), do: {"Read", truncate(path)}

  def summarize("write", %{"path" => path}) when is_binary(path), do: {"Write", truncate(path)}

  def summarize("edit", %{"path" => path} = args) when is_binary(path),
    do: {"Edit", truncate(path <> edit_note(args["edits"]))}

  def summarize("bash", %{"command" => command}) when is_binary(command),
    do: {"Bash", command |> first_line() |> truncate(@command_limit)}

  def summarize("grep", %{"pattern" => pattern} = args) when is_binary(pattern),
    do: {"Grep", truncate(with_path(pattern, args))}

  def summarize("find", %{"pattern" => pattern} = args) when is_binary(pattern),
    do: {"Find", truncate(with_path(pattern, args))}

  def summarize("ast_grep", %{"pattern" => pattern, "lang" => lang})
      when is_binary(pattern) and is_binary(lang),
      do: {"Ast grep", truncate("#{pattern} (#{lang})")}

  def summarize("ls", args) when is_map(args), do: {"List", truncate(path_or_cwd(args))}

  def summarize("replace", %{"pattern" => pattern, "replacement" => to, "path" => path})
      when is_binary(pattern) and is_binary(to) and is_binary(path),
      do: {"Replace", truncate("#{pattern} → #{to} in #{path}")}

  def summarize("fetch", %{"url" => url}) when is_binary(url), do: {"Fetch", truncate(url)}

  def summarize("shell_session", %{"chars" => chars}) when is_binary(chars),
    do: {"Shell", chars |> first_line() |> truncate(@command_limit)}

  def summarize("shell_session", %{"action" => action}) when is_binary(action),
    do: {"Shell", truncate(action)}

  def summarize("spawn_agent", %{"task" => task}) when is_binary(task),
    do: {"Agent", task |> first_line() |> truncate()}

  def summarize("computer", %{"action" => action}) when is_binary(action),
    do: {"Computer", truncate(action)}

  def summarize(name, arguments) when is_binary(name),
    do: {humanize(name), compact_args(arguments)}

  @doc """
  Truncate `text` to `limit` characters, marking the cut with an ellipsis.

      iex> CatalystWeb.UI.ToolSummary.truncate("abcdef", 4)
      "abc…"

      iex> CatalystWeb.UI.ToolSummary.truncate("abc", 4)
      "abc"
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, limit \\ @detail_limit)

  def truncate(text, limit) when is_binary(text) do
    case String.length(text) > limit do
      true -> String.slice(text, 0, limit - 1) <> "…"
      false -> text
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp first_line(text) do
    text
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp with_path(text, %{"path" => path}) when is_binary(path), do: "#{text} (#{path})"
  defp with_path(text, _args), do: text

  defp path_or_cwd(%{"path" => path}) when is_binary(path) and path != "", do: path
  defp path_or_cwd(_args), do: "."

  defp edit_note(edits) when is_list(edits), do: " (#{edit_count(length(edits))})"
  defp edit_note(_edits), do: ""

  defp edit_count(1), do: "1 edit"
  defp edit_count(n), do: "#{n} edits"

  defp compact_args(args) when is_map(args) and map_size(args) == 0, do: ""

  defp compact_args(args) when is_map(args),
    do: args |> Jason.encode!() |> String.slice(0, @detail_limit)

  # "spawn_agent" -> "Spawn agent"; leaves an already-capitalized name alone.
  defp humanize(name) do
    name
    |> String.replace(["_", "-"], " ")
    |> capitalize_first()
  end

  defp capitalize_first(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest

  defp capitalize_first(text), do: text
end
