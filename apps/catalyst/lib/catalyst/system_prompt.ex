defmodule Catalyst.SystemPrompt do
  @moduledoc """
  The agent's system prompt, resolved as **data** rather than compiled code.

  Resolution (fresh on every run, in `Catalyst.Session.Server.start_run/2`):

    1. the session's explicit `:system_prompt` option, if set;
    2. `~/.catalyst/system_prompt.md`, if present and non-blank — user- and
       agent-editable with the ordinary file tools, takes effect on the next
       run with no reload;
    3. the built-in default below.

  This makes the prompt one of the self-modifiable surfaces: the agent can
  rewrite its own instructions by editing a file, and reverting is deleting it.
  """

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

  @doc "Resolve the effective system prompt (override file, else default)."
  def get do
    with {:ok, text} <- File.read(path()),
         false <- String.trim(text) == "" do
      text
    else
      _ -> default()
    end
  end

  @doc "The built-in default prompt."
  def default, do: @default

  @doc "Path of the override file (`~/.catalyst/system_prompt.md`; test-overridable)."
  def path do
    Application.get_env(:catalyst, :system_prompt_path) ||
      Path.expand("~/.catalyst/system_prompt.md")
  end
end
