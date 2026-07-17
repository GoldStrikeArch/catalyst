# Catalyst — Self-Extension Guide (adding features at runtime)

This guide is written **for the Catalyst agent** (and humans). It explains how to add or change
capabilities at runtime — **tools, LLM providers, agent-loop hooks, and the UI** — **while the app
is running**, including inside the packaged, standalone macOS app, **without recompiling or
restarting it**. Start with "Where you are: the live bundled app" for the environment map and the
decision guide; everything in this guide is relative to that running app.

## Why this works (the short version)

Catalyst runs on the BEAM (the Erlang VM). The Elixir **compiler ships inside the release**,
so Catalyst can compile a new Elixir module from source and load it into the *already-running*
VM at runtime. The shipped binary never changes; new code lives **outside** it, in a
user-writable directory, and is loaded into the live VM.

- Extensions live in **`~/.catalyst/extensions/*.ex`** (one module per file is fine; multiple
  is fine too).
- They are compiled + loaded **on boot** (so they persist across restarts) and can be loaded
  **on demand** at runtime.
- A loaded module is a first-class part of the running system — it can call any Catalyst or
  Elixir/Erlang function, exactly as if it had shipped in the binary.

This is the BEAM analog of a "self-developing" agent: Catalyst writes a tool for itself and
starts using it on the next turn.

> ⚠️ This is full code execution on the user's machine, by design. Only create tools the user
> asked for. Prefer the existing built-in tools (`read`, `write`, `edit`, `bash`, `grep`,
> `find`, `replace`, `ast_grep`) when they already do the job — only `develop_tool` when you
> need a capability that doesn't exist yet.

---

## Where you are: the live bundled app

If you are reading this at `~/.catalyst/guide.md`, **you are running inside the packaged
standalone app** (`Catalyst.app`, an OTP release) — not a dev checkout. Two facts shape
everything below:

1. **Your own code is already compiled into the running VM.** Editing the app's source files
   inside the bundle does **nothing** — the `.beam` is already loaded. To change behavior you
   **load new code** (`develop_tool` / `install_extension`) or use the **runtime registries**
   (tools, providers, loop hooks, UI). You extend yourself by adding code to the live VM, not by
   editing the shipped app.
2. **Never hardcode bundle paths.** Resolve locations at runtime from inside your tools/
   extensions with `Application.app_dir/2` and `:code.priv_dir/1` — they work identically in dev
   and in the `.app`.

### Where things live

Outside the bundle — stable, user-writable, your durable workspace:

| What | Path |
|---|---|
| Extensions you create (loaded on boot, survive restarts) | `~/.catalyst/extensions/*.ex` |
| This guide | `~/.catalyst/guide.md` |
| Per-session debug log (+ `latest.log`) | `~/.catalyst/debug/<session_id>.log` |
| Auth / session transcripts | `~/.catalyst/auth.json`, `~/.catalyst/sessions/` |

Inside the bundle — resolve at runtime, don't hardcode:

| What | Resolve with |
|---|---|
| Served assets (what the window loads) | `Application.app_dir(:catalyst_web, "priv/static/assets/css/app.css")` (and `js/app.js`) |
| **Editable** CSS/JS source (rebuild from here) | `Application.app_dir(:catalyst_web, "priv/asset_build/assets/")` → `css/app.css`, `js/app.js`, `vendor/` |
| Bundled fast-tool binaries | `Application.app_dir(:catalyst, "priv/bin/")` (`rg`,`fd`,`sd`,`ast-grep`) — used automatically by `grep`/`find`/`replace`/`ast_grep`; you rarely need the path |

### How to change the running app

- **Add a tool** → `develop_tool` (writes `~/.catalyst/extensions/<name>.ex`, callable next turn).
- **Add a provider / loop hook / UI page / renderer / component** → `install_extension` with a
  module that `use Catalyst.Extension` and registers them in `setup/1` (see "Beyond tools"
  below). Live immediately, no rebuild.
- **Change CSS / styling (incl. new Tailwind classes), or a JS hook** → edit the **runtime asset
  source** under `Application.app_dir(:catalyst_web, "priv/asset_build/assets/...")`, then call the
  **`rebuild_assets`** tool; the window reloads. (Tailwind also scans `~/.catalyst/extensions`, so
  classes in components you create are compiled.)
- **Restructure a page/layout (a LiveView/component's markup or behavior)** → you can't edit the
  compiled module's file; register a replacement page/renderer via `install_extension`, or
  hot-swap the module by loading new code, then call **`reload_ui`**.
- **Recover** → `rollback_extension` (git revert + reload; pass `name` to scope it to one
  extension), `reload_extensions`, the **Extensions panel** at `/extensions` (per-extension
  reload / roll back / disable buttons), or restart with `CATALYST_SAFE_MODE=1` (built-ins only).

### Worked example: make the app background white

The canonical runtime UI change — edits the bundled CSS source via `app_dir` (no hardcoded path)
and rebuilds. Call `install_extension` with name `white_background` and this source:

```elixir
defmodule Catalyst.Ext.WhiteBackground do
  use Catalyst.Extension

  @impl true
  def setup(_api) do
    css = Application.app_dir(:catalyst_web, "priv/asset_build/assets/css/app.css")
    File.write!(css, "\nbody { background: #ffffff; color: #111827; }\n", [:append])
    CatalystWeb.Assets.rebuild()
    :ok
  end
end
```

After it loads, the window reloads white. (`CatalystWeb.Assets.rebuild/0` runs tailwind+esbuild
from the bundled toolchain and reloads connected windows; the `rebuild_assets` tool wraps it.)

### Constraints in the bundled app (read before acting)

- **Writable assets:** `rebuild_assets` writes into the bundle's `priv/static`. Works when the
  `.app` runs from a **user-writable** location (e.g. `…/_build/prod/Catalyst.app`); if copied to
  `/Applications` (root-owned) it fails — tell the user.
- **Working directory:** defaults to the user's **home**, not their project. Don't assume the cwd
  is any repo. The user repoints the session by typing **`/cd <path>`** in the chat. Resolve user
  paths with `Catalyst.Tools.Paths.resolve(path, ctx.cwd)`.
- **macOS privacy (TCC):** the `.app` cannot read `~/Desktop`, `~/Documents`, or `~/Downloads`
  without Full Disk Access — those return `:eperm` ("not owner" / "Operation not permitted"). If a
  read/bash on such a path fails that way it's not your bug: tell the user to grant Full Disk
  Access or move the project elsewhere.
- **Diagnose with `read_log`:** every step (loop, tool calls, LLM request/response, errors) is in
  `~/.catalyst/debug/latest.log`; call `read_log` when something fails.

---

## The fastest path: the `develop_tool` tool

You (the agent) already have a built-in tool named **`develop_tool`**. Call it with:

- `name` — a short identifier for the extension file (e.g. `"word_count"`). Becomes
  `~/.catalyst/extensions/word_count.ex`.
- `source` — the **full Elixir source** of a module that `use`s `Catalyst.Tools.Tool`.

`develop_tool` writes the file, compiles it, registers the tool(s) it defines, and returns the
new tool name(s). The new tool is **callable on your next turn** (the loop re-reads the live
tool set every turn).

Minimal example `source`:

```elixir
defmodule Catalyst.Ext.WordCount do
  use Catalyst.Tools.Tool

  @impl true
  def name, do: "word_count"

  @impl true
  def description, do: "Count the words in a file."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string", "description" => "File to count"}},
      "required" => ["path"]
    }
  end

  @impl true
  def execute(%{"path" => path}, ctx) do
    abs = Catalyst.Tools.Paths.resolve(path, ctx.cwd)
    n = abs |> File.read!() |> String.split(~r/\s+/, trim: true) |> length()
    result("#{n} words in #{abs}", %{count: n})
  end
end
```

After this, call `word_count` like any other tool: `{"path": "README.md"}`.

---

## The Tool contract

A tool is an Elixir module that `use Catalyst.Tools.Tool` and implements four callbacks:

| Callback | Returns | Notes |
|---|---|---|
| `name/0` | `String.t()` | The name you call the tool by. Must be unique; don't shadow a built-in unless you intend to replace it. |
| `description/0` | `String.t()` | Shown to the model. Describe what it does and when to use it. |
| `parameters/0` | `map()` | A **JSON Schema** object (`%{"type" => "object", "properties" => …, "required" => […]}`). |
| `execute/2` | a result map | `execute(args, ctx)` — see below. |
| `execution_mode/0` | `:parallel` \| `:sequential` | Optional; defaults to `:parallel`. Use `:sequential` for tools that mutate files. |

`use Catalyst.Tools.Tool` imports a `result/2` helper:

```elixir
result(text)                 # => %{content: [%Catalyst.Content.Text{text: text}], details: %{}, terminate: false}
result(text, details_map)    # attach structured details for the UI/logs
```

### `execute(args, ctx)`

- `args` — a map with **string keys**, matching your `parameters/0` schema (e.g.
  `%{"path" => "x"}`).
- `ctx` — `%{cwd: String.t(), call_id: String.t(), report: (result -> :ok)}`.
  - `ctx.cwd` — the session's working directory. **Resolve user paths against it**
    (`Catalyst.Tools.Paths.resolve(path, ctx.cwd)`).
  - `ctx.report` — optional; call it with a partial `result(...)` to stream progress.
- **Return** a result map (use the `result/…` helper).
- **On failure, `raise`** with a clear message — the runner turns a raised exception into an
  error tool-result (it will not crash the session).

---

## Helpers you can use inside a tool

- **`Catalyst.Tools.Paths.resolve(path, cwd)`** — resolve a relative/`~` path to absolute.
- **`Catalyst.Content`** — content blocks; `Catalyst.Content.text_of(list)` extracts text.
- **`Catalyst.Tools.Truncate.head(text, opts)` / `.tail(text, opts)`** — clamp big output
  (`max_lines:`, `max_bytes:`; defaults 2000 lines / 50 KB). Returns `{text, info}`.
- **`Catalyst.Tools.Exec`** — shell out:
  - `Exec.collect(path, args, cwd: cwd)` → `{:ok, %{out, status}} | {:error, reason}` (run a
    binary to completion; stderr merged).
  - `Exec.bash(command, cwd: cwd, timeout: ms)` → same shape (MuonTrap-backed; process-group
    kill on timeout/abort).
- **`Catalyst.Tools.Binaries.path!(:rg | :fd | :sd | :ast_grep)`** — absolute path to a fast
  tool binary (resolve before passing to `Exec.collect`).
- Any dependency already in the release is available — e.g. **`Req`** (HTTP), `Jason` (JSON),
  `File`, `System`, and the whole Elixir/Erlang stdlib.

### Example: a tool that shells out (ripgrep with a count)

```elixir
defmodule Catalyst.Ext.CountMatches do
  use Catalyst.Tools.Tool

  @impl true
  def name, do: "count_matches"
  @impl true
  def description, do: "Count how many lines match a pattern (ripgrep)."
  @impl true
  def parameters do
    %{"type" => "object",
      "properties" => %{"pattern" => %{"type" => "string"}, "path" => %{"type" => "string"}},
      "required" => ["pattern"]}
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, ctx) do
    rg = Catalyst.Tools.Binaries.path!(:rg)
    target = Catalyst.Tools.Paths.resolve(args["path"] || ".", ctx.cwd)

    case Catalyst.Tools.Exec.collect(rg, ["--count-matches", "--no-filename", pattern, target], cwd: ctx.cwd) do
      {:ok, %{out: out, status: s}} when s in [0, 1] ->
        total = out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1) |> Enum.sum()
        result("#{total} matches for #{inspect(pattern)}")

      {:ok, %{out: out}} -> raise "ripgrep error: #{out}"
      {:error, reason} -> raise "ripgrep failed: #{inspect(reason)}"
    end
  end
end
```

### Example: a tool that uses the network (Req)

```elixir
defmodule Catalyst.Ext.HttpGet do
  use Catalyst.Tools.Tool

  @impl true
  def name, do: "http_get"
  @impl true
  def description, do: "Fetch a URL and return the first ~100 lines of the body."
  @impl true
  def parameters do
    %{"type" => "object", "properties" => %{"url" => %{"type" => "string"}}, "required" => ["url"]}
  end

  @impl true
  def execute(%{"url" => url}, _ctx) do
    case Req.get(url) do
      {:ok, %{status: status, body: body}} ->
        text = body |> to_string() |> String.split("\n") |> Enum.take(100) |> Enum.join("\n")
        result("HTTP #{status}\n\n#{text}")

      {:error, reason} -> raise "request failed: #{inspect(reason)}"
    end
  end
end
```

---

## Constraints & conventions

- **Namespace your modules** under `Catalyst.Ext.*` to avoid clashing with built-ins.
- **`name/0` uniqueness:** reloading a file with the same tool name replaces it (last write
  wins) — handy for iterating. A *new* name adds a tool.
- **Persistence:** loaded modules vanish when the app stops, but the **source file in
  `~/.catalyst/extensions/` persists** and is recompiled+loaded on the next boot. So an
  extension you create survives restarts.
- **Errors:** `raise` for failures; never return a non-result value.
- **Mutating tools:** set `def execution_mode, do: :sequential` so they don't run concurrently
  with other file-touching tools.
- **Keep output bounded:** wrap large output in `Catalyst.Tools.Truncate.head/2`.

---

## Doing it manually (humans)

You don't have to go through the agent. To add a tool by hand:

1. Write a module (as above) to `~/.catalyst/extensions/my_tool.ex`.
2. Either **restart** Catalyst (it loads all `*.ex` on boot), or from an attached IEx:
   ```elixir
   Catalyst.Extensions.load_file(Path.expand("~/.catalyst/extensions/my_tool.ex"))
   Catalyst.Extensions.names()   # confirm it's registered
   ```

`Catalyst.Extensions` API: `tools/0`, `names/0`, `fetch/1`, `register_tool/1`,
`load_file/1`, `load_all/0`, `dir/0`.

---

## Running the bundled app from a terminal (humans)

The bundle map and runtime rules are in **"Where you are: the live bundled app"** above. The one
extra tip for humans: to watch the app's stdout/logs while it runs, launch it from a terminal
instead of double-clicking —

```bash
_build/prod/Catalyst.app/Contents/MacOS/run
```

(The agent itself should use `read_log` / `~/.catalyst/debug/latest.log`, which works regardless.)

---

## Debugging a failed run

Every session writes a debug log to **`~/.catalyst/debug/<session_id>.log`** (and
`~/.catalyst/debug/latest.log` points at the most recent one) capturing every agent-loop
step, each tool call + result, the LLM request (truncated, incl. byte size) and response/
error. Call the **`read_log`** tool to read the tail of the current session's log when a step
fails — it's the fastest way to see *what* was sent and *why* it failed. Disable with
`CATALYST_DEBUG=0`.

---

## Checklist for the agent before calling `develop_tool`

1. Does a built-in tool already do this? If yes, use it instead.
2. Module under `Catalyst.Ext.*`, `use Catalyst.Tools.Tool`, all four callbacks implemented.
3. `parameters/0` is a valid JSON-Schema object with `required`.
4. `execute/2` resolves paths via `ctx.cwd`, returns `result(...)`, and `raise`s on failure.
5. Output bounded; `execution_mode :sequential` if it writes files.
6. After creating it, tell the user the new tool's name and what it does — then use it.

---

## Beyond tools: providers, loop hooks, and the UI

`develop_tool` adds a tool. To add *other* kinds of capability at runtime, use the
**`install_extension`** tool with a file that defines a module `use Catalyst.Extension`
and a `setup(api)` callback. Inside `setup/1`, register any mix of:

- **Tools** — `Catalyst.ExtensionAPI.register_tool(api, MyTool)` (or just define a
  `use Catalyst.Tools.Tool` module in the same file; it is auto-registered).
- **LLM providers** —
  `register_provider(api, "my-api", %Catalyst.LLM.ProviderConfig{module: MyProvider, name: "My"})`,
  where `MyProvider` implements `Catalyst.LLM.Provider` (`stream/4`). Select it by
  starting a session whose model `api` is `"my-api"`. (Refactoring an *existing*
  provider needs no registration — just rewrite its module; the next call uses it.)
- **Agent-loop hooks** — `register_hook(api, point, fun)` for:
  - `:before_tool_call` — `fn ctx -> {:block, reason} | :cont end` (gate/deny a call)
  - `:after_tool_call` — `fn {content, details, is_error, terminate}, ctx -> {:ok, tuple} end`
  - `:transform_context` — `fn messages, ctx -> {:ok, messages} end` (edit the LLM request)
  - `:prepare_next_turn` — `fn {context, config}, ctx -> {:ok, {context, config}} end`
  - `:should_stop_after_turn` — `fn ctx -> true | :cont end`
  Observe every event with `Catalyst.ExtensionAPI.on(api, fn event -> ... end)`.
- **UI** — `register_page(api, "settings", {MyPage, :render})` adds a page at `/settings`;
  `register_renderer(api, :message, match_fun, render_fun)` overrides how a message or
  tool result is shown; `register_component(api, :header_extra, fun)` adds a header/
  sidebar/footer widget. Render functions are `Phoenix.Component`s.
- **Processes** — `Catalyst.ExtensionAPI.start_child(api, child_spec)` starts a
  long-lived process (watcher, poller, client connection) under a supervisor owned by
  your extension. Never use a bare `spawn`: supervised children are restarted on crash
  and torn down when your extension is purged/reloaded.

Everything you register is tagged with the file's name (its *owner*); reinstalling the
same file purges its old contributions first, so reloads never duplicate — including
**module definitions**: modules your file compiled are removed from the VM on purge, and
a module that shadowed one shipping with the app is restored from its original beam.
Installs are git-committed: **`rollback_extension`** reverts the last change (pass
`name` to undo one extension's most recent change instead), **`reload_extensions`**
reloads from disk. The **Extensions panel** (`/extensions`, the "Extensions" link in the
header) lists everything that is loaded/registered — extensions, tools, providers,
hooks, pages, renderers, components, commands — with per-extension **reload / roll
back / disable** buttons; *disable* renames the file to `.ex.disabled` (purged now,
skipped at boot) until re-enabled. Safe mode loads only built-ins: set
`CATALYST_SAFE_MODE=1` manually, or it engages **automatically** when the previous boot
crashed while extensions were active (a boot-marker file detects it; a successful
`reload_extensions` — or the panel's "Load extensions now" button — clears it, and the
UI shows a banner while it is active).

### The system prompt and the agent loop are data too

- **System prompt** — writing `~/.catalyst/system_prompt.md` replaces the built-in
  system prompt from the **next run** onward (no reload of any kind); delete the file to
  restore the default. Blank files are ignored.
- **Agent loop** — `Application.put_env(:catalyst, :agent_loop, MyLoop)` swaps the loop
  module for every subsequent run (`MyLoop.run/4` must follow `Catalyst.Agent.Loop`'s
  contract); `Application.delete_env(:catalyst, :agent_loop)` reverts to the built-in.
  Prefer this (data, reversible) over redefining `Catalyst.Agent.Loop` in place.

### Applying UI changes
| Change | How to apply |
|---|---|
| New page / modal / panel / message renderer | immediate (registry) — just navigate to it |
| Markup/layout change to a page/component module | hot-swap the module, then `reload_ui` |
| New/changed CSS (Tailwind) or JS hook | `rebuild_assets` (rebuilds, then reloads the window) |
| New compiled dep / NIF / native (wx) change | needs an app rebuild + restart |
