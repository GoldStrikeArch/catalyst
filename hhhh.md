# Catalyst — Claude Code and ACP Integration

**Status:** standalone design proposal  
**Research baseline:** 2026-08-20  
**Implementation status:** not started  
**Scope:** two independent external-agent integrations:

1. the official Claude Code executable in non-interactive `claude -p` mode; and
2. a generic Agent Client Protocol client, with Claude ACP as its first configured agent.

This document is the complete design and delivery outline for both tracks. It deliberately does
not fold the proposal into `architecture.md` or `plan.md` until the direction is accepted and the
implementation begins.

## 1. Executive decision

Catalyst should support Claude through two separate backends with different ownership models:

| Track              | Catalyst launches       | Who owns the model loop? | Who owns tools?                              | Session strategy                                  |
| ------------------ | ----------------------- | ------------------------ | -------------------------------------------- | ------------------------------------------------- |
| Direct Claude Code | `claude -p`             | Claude Code              | Claude Code                                  | one process per prompt, continued with `--resume` |
| Generic ACP        | an ACP agent executable | the ACP agent            | the ACP agent, with optional client services | one supervised process per Catalyst session       |

Neither backend should implement `Catalyst.LLM.Provider`.

`Catalyst.LLM.Provider` represents one model turn inside Catalyst's own loop. Both proposed
backends are complete agents: they own model calls, context management, tool selection, tool
execution, retries, and compaction. The correct existing extension seam is `Catalyst.Workflow`,
which owns one complete Catalyst run.

The two tracks should share only established Catalyst infrastructure:

- sessions and persistence;
- workflow selection;
- agent events;
- prompt resolution;
- hooks and permission policy;
- CLI and LiveView presentation;
- a bounded NDJSON framer, but only after both implementations prove that sharing it removes real
  duplication.

They should not share a speculative `ExternalAgent` behaviour. Their protocols, process
lifetimes, continuation rules, and capabilities are materially different.

## 2. What we want to achieve

### 2.1 Product goals

- Let a user run Claude Code from Catalyst while using the subscription authentication already
  managed by the official Claude Code installation.
- Avoid reading, copying, proxying, or storing Anthropic OAuth credentials in Catalyst.
- Let Catalyst append to or replace Claude Code's system prompt through documented CLI options.
- Stream Claude text, thinking, tool activity, usage, completion, and failures through Catalyst's
  existing event and transcript model.
- Preserve Claude conversation continuity across Catalyst prompts.
- Add a standards-based ACP client that can run Claude ACP and other compliant agents without
  Claude-specific branches in the generic transport.
- Keep direct Claude Code and ACP independently testable, releasable, and removable.
- Keep ordinary automated tests completely offline.
- Make subscription-only behavior explicit and reject configurations that would unexpectedly
  route to separately billed API or usage-credit paths.

### 2.2 Architecture goals

- Reuse `Catalyst.Workflow`; do not distort the one-turn provider abstraction.
- Keep `Session.Server` responsive and free of blocking process or network work.
- Supervise every external process and guarantee bounded cancellation and cleanup.
- Reuse existing message, event, persistence, prompt, and hook contracts.
- Store external continuation identifiers in existing persisted fields.
- Validate all external input at protocol boundaries.
- Use direct executable spawning rather than shell command construction.
- Add no runtime downloader, JavaScript sidecar, Python sidecar, or stale protocol package.
- Advertise the minimum ACP client capabilities Catalyst actually implements.

### 2.3 Non-goals for the first release

- Implementing Anthropic login or OAuth inside Catalyst.
- Reading or exporting Claude Code credentials.
- Calling Anthropic's HTTP API with subscription credentials.
- Scraping Claude's interactive terminal UI.
- Reimplementing Claude Code's tool loop in the direct backend.
- Exposing Fable by default in subscription-only mode.
- Supporting ACP v2 while it remains a draft.
- Providing ACP filesystem, terminal, MCP, or elicitation client services before each trust
  boundary has a dedicated design.
- Bundling Claude Code, Claude ACP, Node, or npm in Catalyst releases.
- Building a Catalyst-to-Claude MCP bridge in the first direct integration.
- Adding a second transcript or checkpoint database.
- Supporting seamless backend changes inside one existing conversation.

## 3. Time-sensitive policy and billing conclusions

These conclusions describe the documented state researched on **2026-08-20**. Anthropic can change
its product terms, authentication precedence, subscription treatment, model availability, or CLI
behavior. They must be rechecked immediately before implementation and before each public release.

This document is an engineering interpretation, not legal advice.

### 3.1 Subscription use

Anthropic's current support material says that previously announced billing changes are paused and
that supported Claude Code print mode, Agent SDK, and third-party application usage can draw from a
Claude subscription's limits.

That does not justify a blanket promise that every invocation is covered by the subscription:

- `ANTHROPIC_API_KEY` and other explicit API or cloud-provider routing can take precedence and
  produce separately billed usage.
- Optional usage credits can incur charges after subscription limits or for features/models not
  covered by the plan.
- Non-interactive operation can remove an interactive warning that would otherwise make a billing
  transition obvious.
- Anthropic can change this treatment after the research date.

Catalyst should therefore call the mode **subscription-only**, not **free**, and enforce it with a
preflight rather than relying on UI copy.

### 3.2 Authentication boundary

Catalyst should require the user to:

1. install the official Claude Code executable;
2. run `claude auth login` outside Catalyst; and
3. keep credentials under Claude Code's ownership.

Catalyst should:

- locate the executable;
- invoke the documented JSON form of `claude auth status`;
- inspect only the reported authentication/routing status needed for the preflight;
- reject a subscription-only run when API-key, token, or cloud-provider routing would win;
- never display, persist, copy, or refresh Claude credentials; and
- never offer a Claude login form.

### 3.3 Distribution and policy risk

There is a meaningful distinction between:

- automating an official, user-installed Claude Code executable; and
- implementing a third-party product that captures Claude.ai login credentials or routes those
  credentials to another service.

The first is the proposed design. The second is explicitly out of scope.

Anthropic's legal and compliance guidance also indicates that third-party products should use
approved API-key paths rather than offer Claude.ai login or credential routing. Because Catalyst is
intended to become a distributed product rather than only a private script, written clarification
or approval from Anthropic is still advisable before advertising subscription-backed Claude
support publicly.

The feature should remain local, explicit, and marked experimental until that review is complete.

### 3.4 Fable

Fable is not treated as a safe subscription-only model in this design.

The CLI may technically accept a Fable model selection, but current non-interactive behavior can
consume separately billed usage credits without an interactive consent step. Therefore:

- the default direct-Claude model is the stable `sonnet` alias;
- Fable is hidden when `subscription_only: true`;
- Catalyst never silently enables usage credits;
- Catalyst never silently falls back from subscription routing to API billing; and
- a future `allow_usage_credits: true` control may expose Fable only with explicit billing copy and
  a second confirmation.

This is a billing guard, not a claim that the executable is technically unable to run Fable.

## 4. System-prompt and ownership semantics

### 4.1 Plain `claude -p`

Plain `claude -p` runs Claude Code's agent and therefore uses Claude Code's own system prompt,
tool instructions, safety policy, loop, settings, and built-in tools.

The documented prompt controls provide two useful modes:

- **append:** retain Claude Code's default system prompt and append Catalyst's resolved system
  prompt;
- **replace:** replace Claude Code's default system prompt with Catalyst's resolved system prompt.

Appending is the initial default. It preserves the instructions Claude Code expects for its own
tools and execution model while still adding Catalyst's guidance. Replacement is useful for
experimentation but may reduce tool quality because Catalyst would then be responsible for all
necessary tool-use guidance.

The implementation should use the file-based prompt options and a private mode-`0600` temporary
file rather than putting the full system prompt in the process list.

### 4.2 Generic ACP

ACP defines how a client and an external agent communicate. It does not define one universal system
prompt.

For a generic ACP agent:

- the agent controls its model, base prompt, context, loop, and tools;
- Catalyst can send only standard ACP fields and capabilities;
- Catalyst must not assume that an arbitrary agent accepts a system-prompt override.

For Claude ACP specifically, the current adapter exposes a documented `_meta.systemPrompt`
extension:

- a string replaces the prompt; and
- the Claude Code preset form can retain the Claude Code prompt and append Catalyst's guidance.

That extension belongs in the Claude ACP adapter, not in the generic ACP transport.

### 4.3 Practical answer

- **Direct `claude -p`:** Catalyst can use its own system prompt, either appended to or replacing
  Claude Code's prompt. Claude Code still owns the loop and tools.
- **Generic ACP:** Catalyst is an agent client. The external agent owns the loop and usually the
  system prompt. Prompt customization is available only when that agent documents an extension.
- **Claude ACP:** its current extension gives Catalyst explicit append/replace control, but Claude
  ACP still owns the agent loop.

## 5. Lessons from other harnesses

### 5.1 OpenCode

OpenCode previously had a direct Anthropic OAuth integration and removed that route after an
Anthropic legal request.

Lesson for Catalyst:

- do not reproduce or reverse-engineer direct Claude.ai OAuth;
- do not extract Claude Code tokens;
- do not route those tokens into an Anthropic HTTP client;
- keep the official executable as the authentication boundary.

OpenCode remains useful as a reference for provider catalogs, streamed event normalization, and
tool presentation, but not as a policy precedent for subscription OAuth.

### 5.2 T3 Code

T3 Code delegates Claude work to the official Claude Agent SDK and Claude executable. It uses the
Claude Code prompt preset and persistent agent sessions rather than pretending Claude is a
single-turn model provider.

Lesson for Catalyst:

- model Claude Code as a complete external agent;
- treat session ownership and cancellation as first-class;
- preserve the official runtime's prompt/tool assumptions by default;
- do not place it behind Catalyst's `LLM.Provider`.

T3's SDK-based approach is informative, but Catalyst does not need a Node or Python Agent SDK
sidecar for the first direct implementation. The documented CLI stream is the smaller dependency
surface.

### 5.3 Pi

Pi demonstrates a compact agent loop and provider abstraction, but its direct OAuth history and
current warnings about third-party subscription use are not a safe route to copy for Catalyst.

Lesson for Catalyst:

- reuse architectural ideas, not credentials or undocumented authentication behavior;
- keep billing and authentication explicit at the boundary;
- prefer documented official execution paths.

### 5.4 ACP ecosystem and Zed

ACP validates the external-agent model: the editor or harness acts as a client while an independent
agent process owns its loop. The client presents updates, answers permission requests, and may
provide explicitly negotiated services.

Lesson for Catalyst:

- implement ACP as a bidirectional JSON-RPC client;
- negotiate and retain capabilities;
- do not assume every agent has Claude-specific behavior;
- keep client capabilities minimal until implemented securely.

### 5.5 Ponytail design discipline

The Ponytail approach reinforces several choices in this proposal:

1. reuse an existing abstraction before adding a new one;
2. prefer the standard library and existing dependencies;
3. begin with the smallest end-to-end implementation;
4. do not build speculative protocol or capability layers;
5. preserve clear ownership and cleanup boundaries.

Applied here:

- use `Catalyst.Workflow`, not a new external-agent framework;
- use Elixir ports, OTP supervision, and existing `Jason`;
- use one documented CLI process per direct prompt before considering a persistent SDK sidecar;
- implement only stable ACP v1 methods and capabilities Catalyst needs;
- add shared framing code only after duplication exists.

## 6. Fit with Catalyst's current architecture

### 6.1 Existing ownership

The current ordinary path is:

```text
Session.Server
  -> Catalyst.Agent.Loop workflow
    -> Catalyst.LLM.Provider for one model turn
      -> Catalyst-owned tool execution
```

The proposed paths are:

```text
Session.Server
  -> Catalyst.ClaudeCode.Workflow
    -> claude -p
      -> Claude-owned model/tool loop
```

```text
Session.Server
  -> Catalyst.ACP.Workflow
    -> Catalyst.ACP.Client
      -> configured ACP agent
        -> agent-owned model/tool loop
```

### 6.2 Why `Catalyst.Workflow` is the right seam

A workflow already owns one complete run and can:

- receive the accepted user input and session state;
- emit the normal `Catalyst.Agent.Event` stream;
- return chronological messages;
- participate in run supervision and cancellation;
- reuse prompt and hook registries;
- persist through the normal session path.

This lets `Session.Server`, JSONL persistence, PubSub, CLI rendering, and LiveView rendering remain
backend-neutral.

### 6.3 Shared prerequisite: providerless workflows

The current session start path performs provider resolution before the selected workflow runs.
That assumption blocks a workflow which needs no `LLM.Provider`.

The minimal change is:

1. resolve the workflow inside the supervised run path;
2. resolve the provider there as a tagged result;
3. carry either the provider or its resolution error in the run configuration;
4. let `Catalyst.Agent.Loop` surface the error when it requests a provider;
5. let providerless external workflows ignore the provider field.

This preserves the existing provider contract, avoids a fake provider, and keeps potentially
fallible extension resolution outside the session GenServer.

`prompt/2` should remain synchronous only for host-owned acceptance checks such as invalid input or
`:busy`. A later configuration failure should become the normal persisted error assistant and
balanced `AgentEnd`.

### 6.4 Durable backend identity

Use workflow names as durable backend identifiers:

- `"agent-loop"` or the existing default for Catalyst's native loop;
- `"claude-code"` for direct print mode;
- `"acp/<agent-id>"` for an ACP descriptor.

The selected workflow already belongs in the session settings snapshot.

Changing backend creates a new Catalyst session. Catalyst must not append visible messages from one
backend to another backend's unrelated hidden context. Model, effort, or mode changes within one
backend may continue the same session when the external runtime supports them.

### 6.5 External continuation identifiers

Reuse `Message.Assistant.response_id` for the external session id:

- direct Claude stores the Claude Code session id;
- ACP stores the ACP session id.

Tag each assistant with matching `api` and `provider` metadata. Resume only from the latest
assistant whose backend identity matches the selected workflow.

Consequences:

- no second checkpoint store;
- existing JSONL persistence carries the continuation id;
- reset naturally removes continuation state;
- a missing external session produces a recoverable error and asks for a new Catalyst session;
- Catalyst never silently starts a fresh hidden context under an old visible transcript.

### 6.6 Event and message invariants

Both workflows must:

- call the existing observed-emission path;
- emit one balanced `AgentStart` and `AgentEnd`;
- stream text and thinking through existing delta events;
- represent each external tool execution with balanced start/update/end events;
- persist assistant tool calls before corresponding tool results;
- finalize an open assistant message before a tool result or terminal completion;
- return chronological messages through the existing workflow contract;
- produce a persisted assistant error for expected launch, protocol, auth, billing, timeout, and
  cancellation failures.

The external runtime owns context limits and compaction. These workflows do not call Catalyst's
provider context guard.

## 7. Track A — Direct official `claude -p`

### 7.1 Runtime model

`Catalyst.ClaudeCode.Workflow` launches one official Claude Code process for each accepted Catalyst
prompt and for each subsequently drained follow-up.

The first prompt starts a Claude session. A later Catalyst run selects the latest matching
`response_id` and adds `--resume <claude-session-id>`.

This is intentionally simpler than a persistent Agent SDK control process:

- no Node or Python sidecar;
- no idle external process between prompts;
- no dependency on undocumented control messages;
- no second long-lived supervisor for the direct track;
- easier fixture-based testing and cleanup.

The known cost is process startup on every prompt. Persistent streaming input should be considered
only after measuring that cost and confirming a stable documented protocol.

### 7.2 Intended invocation

The argument builder should produce the documented equivalent of:

```text
claude -p <prompt>
  --output-format stream-json
  --verbose
  --include-partial-messages
  --safe-mode
  --model <alias>
  [--effort <level>]
  [--resume <claude-session-id>]
  [--system-prompt-file <private-file>]
  [--append-system-prompt-file <private-file>]
  [--tools <validated-tool-list>]
  [--permission-mode <validated-mode>]
```

The implementation launches the resolved executable directly. It does not construct a shell
command and does not use a PTY.

Before implementation, the wire spike must verify the exact current compatibility of:

- `--safe-mode`;
- stream JSON and partial messages;
- prompt replacement and append file options;
- resume;
- selected permission modes;
- the installed CLI's auth-status JSON.

No production parser should depend on behavior observed only in the interactive TUI.

### 7.3 Safe mode and settings isolation

Use `--safe-mode`, not `--bare`.

The intended behavior is:

- retain Claude Code's normal subscription authentication;
- disable untrusted project and user hooks;
- disable ambient plugins, MCP servers, skills, memory, and `CLAUDE.md`;
- make Catalyst's prompt and options the explicit run configuration.

`--bare` is not appropriate because it does not use the normal OAuth/keychain path required for
the subscription-backed use case.

The exact interaction between safe mode, prompt files, tool configuration, and authentication is a
release gate to verify against the installed CLI version.

### 7.4 Prompt modes

Resolve Catalyst's normal model/API-aware system prompt, then support:

- `:append` — initial default, through the append prompt-file option;
- `:replace` — explicit advanced mode, through the replacement prompt-file option;
- `:claude_default` — optional diagnostic mode with no Catalyst system-prompt modification.

Write the resolved system prompt to a private temporary file:

- random non-user-controlled name;
- owner read/write only;
- deleted after process startup/completion as allowed by platform semantics;
- cleanup in normal, error, cancellation, and owner-death paths.

Do not log the complete prompt at normal log levels.

### 7.5 Model and billing guard

Initial catalog:

- default: `sonnet`;
- other documented subscription-safe aliases only after verification;
- Fable omitted while `subscription_only: true`.

Before launch:

1. resolve the executable;
2. run `claude auth status` in its documented JSON mode;
3. inspect the effective auth and routing source;
4. reject explicit API-key, auth-token, or cloud-provider routing in subscription-only mode;
5. reject settings which enable separately billed usage credits unless the user explicitly opted
   in;
6. report a structured remediation message without exposing credentials.

The check must fail closed when the installed CLI returns an unknown auth shape.

### 7.6 Tool and permission policy

V1 uses Claude Code's built-in tools. Catalyst observes and renders those tool events but does not
execute the tools itself.

Requirements:

- pass only validated documented tool names;
- make the permission mode explicit in session settings;
- do not use `--dangerously-skip-permissions`;
- do not inherit project MCP configuration;
- do not add a Catalyst MCP server in V1;
- surface denied operations as ordinary tool/error events.

A later Catalyst MCP bridge is justified only when a Catalyst-only tool must be exposed. That
design would need explicit MCP configuration, capability scoping, and a clear alternative to safe
mode because safe mode disables MCP loading.

### 7.7 Stream parsing

Treat stdout as bounded NDJSON protocol data. Treat stderr as bounded diagnostics, never as JSON
protocol input.

The parser must:

- handle arbitrary chunk boundaries;
- enforce a maximum buffered line size;
- enforce a maximum decoded message size;
- reject malformed JSON with a tagged protocol error;
- ignore unknown fields;
- tolerate unknown event kinds with bounded debug logging;
- require a terminal result;
- retain the last bounded stderr excerpt for diagnostics;
- reject output after configured total limits.

Expected mapping:

- `system/init` -> actual model, tools, capabilities, Claude session id, and initialization
  diagnostics;
- partial content events -> Catalyst text/thinking deltas;
- complete assistant content -> persisted assistant content;
- tool-use content -> assistant tool-call message and `ToolExecutionStart`;
- tool-result content -> tool message and update/end events;
- terminal `result` -> stop reason, usage, success/error state, and continuation id.

All model and stop-reason strings are mapped through explicit known-value functions. External
strings never become atoms dynamically.

### 7.8 Cancellation and process ownership

The supervised workflow task owns the Claude process.

On cancellation, task death, session death, timeout, or shutdown:

1. request graceful termination;
2. wait a bounded grace interval;
3. force-kill the process tree;
4. reap the operating-system process;
5. finalize any open tool/message state;
6. emit a balanced terminal event.

Killing only the immediate port process is insufficient if Claude has spawned tool subprocesses.
The implementation needs a tested process-group or platform-specific tree strategy.

Steering received while one opaque `claude -p` call is active is queued for the next resumed
invocation. V1 must not advertise true mid-model-turn steering.

### 7.9 Direct-track module responsibilities

The initial cohesive modules should own concepts rather than layers:

- `Catalyst.ClaudeCode.Workflow` — run orchestration and Catalyst contract;
- `Catalyst.ClaudeCode.Command` — validated executable, auth, model, and argv decisions;
- `Catalyst.ClaudeCode.Stream` — bounded NDJSON framing and event decoding;
- `Catalyst.ClaudeCode.Mapper` — pure Claude-event to Catalyst-event/message transitions;
- `Catalyst.ClaudeCode.Process` — process launch, stderr capture, termination, and reaping.

Exact names may change during implementation, but parsing, pure mapping, and process side effects
should remain separate.

### 7.10 Direct-track failure contract

Expected failures should be tagged and rendered with actionable messages:

- executable not found;
- unsupported CLI version or flags;
- not logged in;
- disallowed API/cloud billing route;
- usage-credit requirement;
- unsupported model;
- invalid permission/tool option;
- failed process launch;
- malformed or oversized stream;
- missing terminal result;
- non-zero process exit;
- timeout;
- cancellation;
- missing Claude session on resume.

Unexpected internal invariant violations should crash the supervised task.

## 8. Track B — Generic ACP client

### 8.1 Protocol baseline

Implement stable **ACP v1** over newline-delimited JSON-RPC 2.0 stdio.

ACP v2 is a draft at the research baseline and must not be negotiated accidentally. Reject an
incompatible selected protocol version with a clear error.

Use existing `Jason` decoding and validated maps for the surface Catalyst implements. Do not:

- add a stale Elixir ACP package;
- dynamically create atoms from method names or payload fields;
- generate a full schema layer for unused methods;
- claim capabilities that have no implementation.

Retain the released v1 schema and protocol examples as test oracles.

### 8.2 Agent descriptors

Represent each configured executable with an explicit validated shape:

```elixir
%Catalyst.ACP.Agent{
  id: "claude",
  name: "Claude ACP",
  command: "claude-agent-acp",
  args: [],
  env: []
}
```

Validation requirements:

- stable non-empty string id;
- display name bounded in length;
- executable resolved to a real file;
- argument list contains only binaries;
- environment is an allowlisted binary key/value collection;
- duplicate ids rejected;
- workflow name derived as `"acp/" <> id`;
- no shell syntax or interpolation.

Launch with a direct executable port such as
`Port.open({:spawn_executable, resolved_path}, options)`.

### 8.3 Configuration

Start with application configuration:

```elixir
config :catalyst, :acp_agents, [
  %{
    "id" => "claude",
    "name" => "Claude ACP",
    "command" => "claude-agent-acp",
    "args" => [],
    "env" => %{}
  }
]
```

Use string keys at the external boundary and convert only known fields into an internal struct.

A user-editable JSON catalog can be added later if application configuration is inadequate for
packaged desktop use. It is not needed to prove the generic client.

### 8.4 Supervision and ownership

Baseline ACP agents are not required to keep session state after their process exits. Unlike the
direct backend, Catalyst should therefore keep one ACP process alive per active
`{Catalyst session, agent}` pair.

Proposed ownership:

```text
Catalyst.ACP.Registry
Catalyst.ACP.DynamicSupervisor
  -> Catalyst.ACP.Client for {catalyst_session_id, agent_id}
       -> one ACP agent subprocess
```

`Catalyst.ACP.Client` is a GenServer because it must remain responsive while:

- correlating outgoing requests and incoming responses;
- receiving asynchronous `session/update` notifications;
- answering agent-to-client requests such as permission requests;
- monitoring the owning `Session.Server`;
- monitoring the current workflow caller;
- enforcing request, idle, and cancellation deadlines;
- handling port exit.

The client terminates with its owning Catalyst session. A caller death sends `session/cancel`; a
failed bounded cancellation closes and reaps the process.

### 8.5 Connection lifecycle

The stable lifecycle is:

1. resolve and launch the configured executable;
2. send `initialize` with ACP v1, Catalyst implementation metadata, and minimal capabilities;
3. validate the selected protocol version;
4. retain advertised agent capabilities, modes, and configuration options;
5. create `session/new`;
6. send `session/prompt` for an accepted Catalyst prompt;
7. route concurrent updates and inbound requests;
8. validate the correlated prompt response and stop reason;
9. reuse the live ACP session for the next Catalyst prompt;
10. send `session/cancel` on abort;
11. send `session/close` on normal teardown when advertised.

After application or process recovery:

1. prefer `session/resume` when advertised;
2. otherwise use `session/load` when advertised;
3. suppress replayed historical updates already represented in Catalyst;
4. use the matching persisted ACP session id from `response_id`;
5. fail recoverably when the agent cannot recover the session.

Do not silently create a new hidden ACP session under an existing visible Catalyst transcript.

### 8.6 JSON-RPC transport requirements

The connection must:

- accept integer and string JSON-RPC ids;
- keep ids as binaries/integers, never atoms;
- correlate concurrent requests;
- distinguish request, notification, success response, and error response;
- handle valid batches;
- reject invalid empty batches;
- answer unknown inbound methods with `method_not_found`;
- bound line size, decoded message size, batch size, and pending request count;
- enforce initialize, request, prompt, cancellation, and idle deadlines;
- fail all pending callers when the port exits;
- retain only bounded stderr and malformed-input diagnostics;
- redact configured secrets from logs.

The transport should not know Claude-specific `_meta` fields.

### 8.7 Initial client capabilities

Advertise only capabilities Catalyst actually implements.

Initial V1 position:

- filesystem service: not advertised;
- terminal service: not advertised;
- client MCP service: not advertised;
- elicitation: not advertised;
- permission requests: implemented;
- session updates: implemented;
- modes/configuration options: consumed for UI when advertised;
- load/resume: used only when advertised.

Each future capability requires:

- validated request and response shapes;
- path/command/resource scoping;
- permission and timeout policy;
- supervision and cancellation;
- user-visible controls;
- dedicated tests.

### 8.8 Permission bridge

ACP agents can ask the client to select a permission option. Map
`session/request_permission` through Catalyst's existing `before_tool_call` hook policy.

Initial decision algorithm:

1. validate the tool call and offered options;
2. construct the existing Catalyst hook context;
3. run the hook/gate;
4. choose `reject_once` when blocked or invalid;
5. otherwise prefer `allow_once` when available;
6. never choose `allow_always` automatically;
7. reject if no safe supported option exists.

The UI can later offer interactive selection, but headless behavior must remain deterministic and
safe.

### 8.9 ACP update mapping

Map ACP updates into existing Catalyst concepts:

| ACP update            | Catalyst representation                               |
| --------------------- | ----------------------------------------------------- |
| `agent_message_chunk` | text delta and accumulated assistant content          |
| `agent_thought_chunk` | thinking delta and accumulated thinking               |
| `tool_call`           | assistant tool-call message plus `ToolExecutionStart` |
| `tool_call_update`    | tool update/end event and balanced tool result        |
| `usage_update`        | transient status and final `Usage`                    |
| `plan`                | retained plan/status metadata                         |
| available commands    | backend metadata and controls                         |
| mode/config updates   | backend metadata and controls                         |
| session info          | continuation/display metadata                         |
| unknown update        | bounded debug log, otherwise ignored                  |

The mapper must:

- finalize open assistant content before tool messages or prompt completion;
- preserve tool-call ids;
- keep starts and ends balanced;
- allow `Session.Reducer` to repair an interrupted run;
- map ACP stop reasons explicitly;
- stamp final assistants with `api: "acp"`, `provider: <agent-id>`, and the ACP session id in
  `response_id`.

### 8.10 Generic versus agent-specific behavior

Keep three boundaries:

1. **Transport:** JSON-RPC/NDJSON, ids, deadlines, ports, request correlation.
2. **ACP workflow adapter:** stable ACP methods, session lifecycle, event/message mapping.
3. **Agent descriptor/extension:** agent-specific command, environment, `_meta`, auth preflight,
   and model filtering.

`Catalyst.ACP.Client` must be able to run a second fixture agent without any Claude branch.

## 9. Claude ACP as the first ACP agent

### 9.1 Installation boundary

The built-in descriptor expects an externally installed `claude-agent-acp` executable from the
current `@agentclientprotocol/claude-agent-acp` package and its supported Node runtime
(Node >= 22 at the research baseline).

Catalyst should:

- discover the executable;
- report installation/version problems;
- launch it directly;
- never run `npx -y`;
- never download package code at runtime;
- never bundle Node or npm artifacts in the first release.

### 9.2 Claude-specific metadata

The descriptor/adapter may populate documented Claude ACP extensions:

- `_meta.systemPrompt` for replace or Claude-Code-preset append behavior;
- `_meta.claudeCode.options.settingSources` to control which settings sources are loaded.

Default to controlled settings rather than ambient user/project/local configuration. Unknown
Claude-specific fields should be absent, not guessed.

### 9.3 Authentication, billing, and models

Apply the same policy as direct Claude:

- use the user's external Claude authentication;
- never read or store credentials;
- perform the supported auth/routing preflight;
- reject API/cloud routes in subscription-only mode;
- default to a subscription-safe `sonnet` alias;
- hide Fable unless usage credits are explicitly enabled;
- fail closed on unknown billing/auth state.

The exact preflight may differ if the ACP executable reports auth through its own initialization
metadata. Claude-specific detection remains outside the generic ACP transport.

### 9.4 Prompt ownership

Claude ACP owns the model loop. Catalyst's system prompt is an adapter extension:

- append mode retains the Claude Code prompt preset and adds Catalyst guidance;
- replace mode sends Catalyst's resolved prompt as the replacement;
- generic ACP agents receive no such field unless their own adapter documents it.

## 10. Shared user experience

### 10.1 Agent selector

Add an **Agent** selector separate from model selection.

Initial entries:

- `Catalyst / Codex` or the existing native agent-loop label;
- `Claude Code`;
- `ACP / Claude`;
- one `ACP / <name>` entry per validated configured agent.

Changing Agent creates a new Catalyst session. The UI should explain that this prevents hidden
context from one agent being mixed with another.

### 10.2 Backend-specific controls

For direct Claude Code, show only:

- model;
- effort;
- system-prompt mode;
- permission mode;
- allowed tools;
- subscription-only status.

For ACP, show:

- configured agent;
- advertised modes;
- advertised configuration options;
- connection/session status;
- agent-specific controls supplied by its adapter.

Do not hardcode Claude's ACP modes into the generic UI. Render only validated options advertised by
the live agent.

### 10.3 Status and errors

Surface actionable states:

- executable missing;
- unsupported version;
- login required;
- subscription route active;
- API/cloud billing route rejected;
- usage credits required;
- agent initializing;
- session resumed;
- external session missing;
- permission requested/denied;
- cancellation in progress;
- protocol error;
- external process exited.

Never render credential values, full environment dumps, or unrestricted stderr.

### 10.4 Headless behavior

The CLI must have deterministic equivalents for every required choice:

- selected workflow/agent;
- model;
- prompt mode;
- permission policy;
- subscription-only versus explicit usage-credit opt-in.

No workflow may block waiting for an interactive desktop-only permission dialog unless the caller
explicitly selected an interactive mode.

## 11. Delivery plan

The tracks share one prerequisite and then proceed independently.

### Phase S0 — Revalidate policy and wire contracts

Before production code:

- re-read Anthropic billing, legal/compliance, Claude Code CLI, headless, and system-prompt docs;
- record the installed Claude version;
- capture `claude auth status` JSON for subscription, API-key, and unauthenticated states without
  committing secrets;
- verify the documented safe-mode, prompt-file, stream, resume, model, effort, tool, and permission
  flags;
- capture direct stream fixtures for text, thinking, tool use/result, retry, failure, cancellation,
  and resume;
- pin the stable ACP v1 schema used by tests;
- record the Claude ACP package/version and extension fields;
- seek written Anthropic clarification before public subscription-backed distribution.

**Exit:** the command and protocol assumptions in this document are confirmed against current
released software, and any differences are reflected here before implementation.

### Phase S1 — Enable providerless workflows

- move provider resolution into the supervised run context;
- preserve existing native-agent error behavior;
- register durable external workflow names;
- prove a fixture workflow can run and persist without any provider;
- add backend-aware continuation-id selection;
- enforce new-session-on-backend-switch semantics.

**Exit:** an offline providerless fixture workflow streams and persists a balanced run through a
real `Session.Server`; all existing provider workflows remain unchanged.

### Track A1 — Direct wire and process core

- implement validated command/auth/billing decisions;
- implement private prompt-file lifecycle;
- launch the executable directly;
- implement bounded stdout NDJSON and stderr capture;
- implement cancellation and process-tree reaping;
- add offline fixture executable tests.

**Exit:** fixture events can be parsed and the process is always reaped on completion, failure,
timeout, caller death, and cancellation.

### Track A2 — Direct Catalyst workflow

- implement pure event/message mapper;
- emit balanced Catalyst run/tool events;
- persist actual Claude session id in `response_id`;
- resume a second prompt;
- support append/replace/default prompt modes;
- handle missing external sessions as recoverable errors;
- queue steering for the next invocation.

**Exit:** a two-prompt offline fixture run survives persistence/reload, resumes with the captured
Claude id, and leaves no orphan process.

### Track A3 — Direct controls and UI

- add the Agent selector entry;
- add model, effort, prompt, tool, and permission controls;
- default to Sonnet and subscription-only;
- hide Fable without explicit usage-credit opt-in;
- display auth/billing/version/process errors;
- add CLI equivalents.

**Exit:** browser, desktop, and CLI can configure the same direct workflow without exposing a
Claude login or credential path.

### Track B1 — Generic ACP transport

- implement validated descriptors;
- implement direct port launch;
- implement bounded NDJSON/JSON-RPC parsing;
- implement ids, correlation, batches, error responses, and deadlines;
- negotiate ACP v1 and retain capabilities;
- build a tiny fake ACP executable.

**Exit:** the fake agent proves initialize and bidirectional request handling, including malformed
input, batches, unknown methods, timeout, and process exit.

### Track B2 — ACP session lifecycle

- add Registry and DynamicSupervisor;
- start one client per `{Catalyst session, agent}`;
- implement new, prompt, cancel, close;
- implement owner/caller monitoring;
- implement bounded cancellation and process reaping;
- implement resume/load with replay suppression when advertised.

**Exit:** the fake agent handles two prompts, cancellation, owner death, process recovery, and an
unrecoverable missing-session error without leaks or deadlocks.

### Track B3 — ACP Catalyst mapping and permissions

- map message/thought/tool/usage updates;
- persist balanced messages and tool events;
- map stop reasons explicitly;
- retain modes/config/session metadata;
- implement `session/request_permission` through existing hooks;
- advertise no unimplemented client service.

**Exit:** a full fake-agent run persists/reloads correctly, gate denial selects `reject_once`, and
allowed requests prefer `allow_once`.

### Track B4 — Claude ACP descriptor

- add the externally installed Claude descriptor;
- validate runtime/package version;
- add documented `_meta` system-prompt/settings extensions;
- add Claude auth/billing/model guard;
- run opt-in live initialization and two-prompt smoke tests.

**Exit:** Claude ACP works through the same generic client used by the fixture agent, with no Claude
branch in the transport.

### Track B5 — Generic ACP UI and configuration

- list all configured agents in the Agent selector;
- render advertised modes/config options;
- expose connection/session/capability status;
- add CLI selection;
- decide whether packaged desktop use actually requires a user JSON catalog.

**Exit:** a second configured fixture agent appears and runs without code changes.

### Final integration gate

- run `mix precommit`;
- run `mix dialyzer`;
- run release tests;
- manually smoke executable discovery in packaged CLI and desktop releases;
- verify process cleanup on supported operating systems;
- recheck current policy/billing documentation;
- keep live account tests opt-in and outside ordinary CI.

## 12. Test strategy

### 12.1 Always-on direct tests

Use a fixture executable, never a network account, to cover:

- init metadata;
- partial text and thinking;
- complete assistant messages;
- one and multiple tool calls/results;
- retry/status events;
- usage;
- successful result;
- model/auth/usage-limit error result;
- malformed JSON;
- oversized line/message/total output;
- unknown event and field;
- missing terminal result;
- non-zero exit;
- resume id selection;
- prompt-file cleanup;
- cancellation and timeout;
- workflow caller death;
- process-tree cleanup.

### 12.2 Always-on ACP tests

Use a tiny fake ACP executable to cover:

- initialize/version negotiation;
- capability retention;
- integer and string request ids;
- concurrent correlation;
- batches;
- unknown methods;
- malformed JSON and invalid envelopes;
- line/message/pending limits;
- new/prompt/cancel/close;
- resume/load and replay suppression;
- text/thought/tool/usage updates;
- permission allow/reject decisions;
- prompt timeout;
- caller and owner death;
- process exit and restart;
- a second non-Claude descriptor.

### 12.3 Workflow integration tests

For both tracks:

- start supervised processes with `start_supervised!/1`;
- use monitors rather than sleeps for shutdown assertions;
- prove no provider is configured or called;
- run through a real `Session.Server`;
- assert balanced events and messages;
- persist and reload JSONL;
- verify continuation selection is backend-specific;
- verify reset removes continuation;
- verify backend switch requires a new session.

### 12.4 LiveView tests

Add stable DOM ids for:

- Agent selector;
- direct model selector;
- direct prompt-mode selector;
- direct permission selector;
- ACP mode/config controls;
- backend status;
- new-session confirmation.

Use `has_element?/2`, `element/2`, and interaction helpers against those ids. Test outcomes rather
than raw HTML or mutable label text.

### 12.5 Opt-in live tests

Live tests are explicit and skipped unless the executable and opt-in environment are present:

- direct Claude: auth preflight plus two resumed Sonnet prompts;
- Claude ACP: initialize plus two prompts;
- cancellation smoke;
- packaged executable discovery.

The test must refuse to run when API/cloud routing is detected in subscription-only mode. It must
not enable usage credits.

## 13. Security and reliability requirements

### 13.1 Process execution

- Resolve real executables.
- Never invoke through a shell.
- Never use user input as an executable path without descriptor validation.
- Bound argv, environment, stdout, stderr, line, message, and pending-request sizes.
- Use explicit working directories.
- Remove secrets from inherited environment where not required.
- Reap complete process trees.

### 13.2 Data handling

- Never persist Anthropic credentials.
- Never log credential-bearing auth output.
- Restrict system-prompt temporary files to the current user.
- Treat all agent output, `_meta`, tool names, paths, and diagnostics as untrusted.
- Never create atoms from protocol strings.
- Keep unknown metadata bounded.

### 13.3 Protocol behavior

- Validate at the boundary and convert to explicit internal shapes.
- Return tagged errors for expected external failures.
- Crash supervised processes on impossible internal invariants.
- Apply deadlines to every request that can otherwise wait forever.
- Fail all pending callers when the connection dies.
- Never report a successful Catalyst run without the protocol's terminal success.

### 13.4 Permissions

- Do not use Claude's dangerous permission bypass.
- Do not auto-select ACP `allow_always`.
- Route supported permission requests through existing hooks.
- Reject unsupported client service requests.
- Make interactive versus deterministic headless behavior explicit.

## 14. Risks and mitigations

| Risk                                | Mitigation                                                                        |
| ----------------------------------- | --------------------------------------------------------------------------------- |
| Anthropic policy or billing changes | revalidate before implementation/release; fail closed; seek written clarification |
| API key overrides subscription      | auth-status and environment/routing preflight                                     |
| Fable consumes usage credits        | hide in subscription-only mode; explicit future opt-in                            |
| Claude stream schema changes        | bounded tolerant decoder; fixture capture; unknown-field tolerance                |
| CLI flag behavior changes           | versioned wire spike and actionable unsupported-version error                     |
| process-per-prompt latency          | measure first; defer persistent input until justified                             |
| orphan Claude/tool processes        | monitored ownership, graceful TERM, forced tree kill, OS-specific tests           |
| Claude session expires/disappears   | recoverable new-session error; never silent hidden reset                          |
| ACP protocol drift                  | pin stable v1 oracle; reject v2/incompatible negotiation                          |
| bidirectional JSON-RPC deadlock     | responsive GenServer, correlated requests, deadlines, pending bounds              |
| ACP agent cannot recover state      | retain live process; use advertised resume/load; fail clearly otherwise           |
| adapter `_meta` changes             | isolate in Claude descriptor and test against pinned package                      |
| capability overreach                | advertise only implemented services                                               |
| transcript imbalance                | pure stateful mapper and reducer-focused interruption tests                       |
| packaged PATH/runtime differences   | explicit discovery diagnostics and packaged release smoke                         |
| public distribution is challenged   | no OAuth/token handling; local experimental status; written review                |

## 15. Deliberately deferred work

- ACP v2.
- A generated full ACP schema model.
- ACP client filesystem service.
- ACP client terminal service.
- ACP client MCP service.
- ACP elicitation UI.
- Direct Claude MCP bridge.
- Persistent direct-CLI streaming input.
- True mid-Claude-turn direct steering.
- Bundled Claude Code or Claude ACP.
- Bundled Node/npm runtime.
- Runtime package downloads.
- Interactive TUI parsing.
- Direct Anthropic OAuth.
- API calls using extracted subscription credentials.
- A second external-session checkpoint store.
- Cross-backend hidden-context migration.

Each item should be reconsidered only in response to a concrete user requirement or measured
limitation.

## 16. Acceptance criteria

### 16.1 Shared architecture

- Provider-backed native workflows behave exactly as before.
- A workflow can run with no `LLM.Provider`.
- Backend identity persists in the session settings.
- Backend switching creates a new Catalyst session.
- External continuation ids persist without a second store.
- All runs emit balanced terminal events.

### 16.2 Direct Claude Code

- Uses only a user-installed official `claude` executable.
- Uses no Catalyst-managed Claude credentials.
- Subscription-only preflight rejects API/cloud/unknown routing.
- Sonnet is the default and Fable is hidden without credit opt-in.
- Append and replace prompt modes work through documented options.
- Text, thinking, tool activity, usage, and errors stream into Catalyst.
- A second prompt resumes the same Claude session.
- Cancellation leaves no external process tree.
- Always-on tests require no Claude account or network.

### 16.3 Generic ACP

- Implements stable ACP v1 over bounded JSON-RPC NDJSON stdio.
- Runs at least two different fixture/configured agents through the same transport.
- Supports initialize, new, prompt, updates, permissions, cancel, and close.
- Uses resume/load only when advertised.
- Rejects incompatible protocol versions.
- Advertises no unimplemented client capabilities.
- Handles malformed input, timeouts, batches, owner death, and process exit without deadlock.
- Persists balanced Catalyst messages/events.

### 16.4 Claude ACP

- Uses an externally installed supported executable/runtime.
- Requires no generic-transport Claude branch.
- Uses only documented Claude-specific metadata.
- Applies the same auth, billing, model, and prompt policy as direct Claude where applicable.
- Completes an opt-in two-prompt live smoke.

### 16.5 Release quality

- Focused tests pass.
- `mix precommit` passes.
- `mix dialyzer` reports no new errors.
- Release tests pass.
- Packaged CLI and desktop discover or clearly reject external executables.
- Policy and billing findings are revalidated against current documentation.

## 17. Open decisions before implementation

1. Has Anthropic provided sufficient written clarification for public subscription-backed
   integration, or should the feature remain local/experimental?
2. What exact minimum Claude Code version supports the verified flag combination?
3. Does safe mode preserve the required subscription authentication and prompt controls in that
   version on every supported operating system?
4. Which non-Fable model aliases are demonstrably subscription-safe?
5. What operating-system process-tree strategy will be used on macOS, Linux, and Windows?
6. Is putting the user prompt in argv acceptable for V1, or is a documented stdin mode with a
   safely closable input channel required before release?
7. Which Claude ACP package/runtime versions become the supported baseline?
8. Does packaged desktop use require a user-editable ACP catalog in V1?
9. Should permission requests remain deterministic `allow_once`/`reject_once`, or does the first
   release require an interactive approval UI?

These are implementation gates, not reasons to merge the two tracks.

## 18. Research sources

### Anthropic

- [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms)
- [Use the Claude Agent SDK with your Claude plan](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Using Claude Code with your Pro or Max plan](https://support.anthropic.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Run Claude Code programmatically](https://code.claude.com/docs/en/headless.md)
- [Modify system prompts](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts.md)

### ACP

- [Agent Client Protocol](https://agentclientprotocol.com)
- [ACP repository](https://github.com/agentclientprotocol/agent-client-protocol)
- [ACP research snapshot `2093951`](https://github.com/agentclientprotocol/agent-client-protocol/commit/209395199c0aa34389947399de79b7e7180be905)
- [Claude Agent ACP](https://github.com/zed-industries/claude-agent-acp)
- [Claude Agent ACP research snapshot `d334766`](https://github.com/zed-industries/claude-agent-acp/commit/d334766ef95dd89201979d42252e3d2a5a259cb9)

Research baseline versions:

- stable ACP v1 schema release: `v1.20.0`;
- ACP v2: draft;
- Claude Agent ACP package: `0.70.0`;
- ACP SDK used by that snapshot: `1.3.0`;
- Claude Agent SDK used by that snapshot: `0.3.232`;
- Claude Agent ACP runtime requirement: Node >= 22.

These versions are observations, not permanent dependency pins. Phase S0 decides the actual
supported baseline.

### Harnesses and design references

- [OpenCode](https://github.com/anomalyco/opencode)
- [T3 Code](https://github.com/pingdotgg/t3code)
- [Pi](https://github.com/earendil-works/pi)
- [Ponytail](https://github.com/dietrichgebert/ponytail)

## 19. Final recommendation

Proceed with both integrations, but keep them separate:

- implement direct `claude -p` first as the smallest official subscription-backed path;
- implement ACP as a real generic external-agent client, not as a Claude-specific wrapper;
- use Claude ACP as the first production descriptor and compatibility test;
- make append mode, Sonnet, safe settings, and subscription-only enforcement the defaults;
- require explicit opt-in for any separately billed path;
- obtain policy clarification before presenting the feature as generally supported in a public
  release.

This gives Catalyst a practical Claude path now and a standards-based external-agent path for the
future without compromising the existing provider/agent-loop architecture.
