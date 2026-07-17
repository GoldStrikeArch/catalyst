# Catalyst — Self-Extension Guide (adding features at runtime)

This guide is written **for the Catalyst agent** (and humans). It explains how to add
a new capability — a new *tool* — to Catalyst **while it is running**, including inside the
packaged, standalone macOS app, **without recompiling or restarting the binary**.

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

## In the packaged macOS app specifically

- Extensions live in **`~/.catalyst/extensions/`** (same as dev — the app and dev share
  `~/.catalyst`). A tool you create in dev is available in the `.app`, and vice versa.
- The **working directory** of the packaged app may be `/` or your home — always resolve
  paths with `Catalyst.Tools.Paths.resolve(path, ctx.cwd)` and have the user point the session
  at the right directory.
- To **see logs / errors** from the packaged app while developing an extension, run its
  launcher in a terminal instead of double-clicking:
  ```bash
  _build/prod/Catalyst.app/Contents/MacOS/run
  ```
- The `develop_tool` / `install_extension` paths work identically in the `.app` — the Elixir
  compiler is bundled in the release, so tools, providers, loop hooks, and UI pages/renderers
  load at runtime with **no external toolchain**.
- **Asset rebuilds work in the `.app` too.** The esbuild + tailwind toolchain *and* the asset
  source are bundled, so `rebuild_assets` regenerates CSS/JS at runtime. Tailwind also scans
  `~/.catalyst/extensions`, so a Tailwind class used by a component you create at runtime gets
  compiled — call `rebuild_assets` after adding it. Caveat: this writes into the app bundle's
  `priv/static`, so it only works when the `.app` is in a **user-writable** location (e.g.
  `_build/prod/Catalyst.app`); a copy installed under `/Applications` is root-owned and not
  writable, so a runtime rebuild there will fail (`{:error, …}`).

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

Everything you register is tagged with the file's name (its *owner*); reinstalling the
same file purges its old contributions first, so reloads never duplicate. Installs are
git-committed: **`rollback_extension`** reverts the last change, **`reload_extensions`**
reloads from disk, and booting with `CATALYST_SAFE_MODE=1` loads only built-ins if an
extension misbehaves.

### Applying UI changes
| Change | How to apply |
|---|---|
| New page / modal / panel / message renderer | immediate (registry) — just navigate to it |
| Markup/layout change to a page/component module | hot-swap the module, then `reload_ui` |
| New/changed CSS (Tailwind) or JS hook | `rebuild_assets` (rebuilds, then reloads the window) |
| New compiled dep / NIF / native (wx) change | needs an app rebuild + restart |
