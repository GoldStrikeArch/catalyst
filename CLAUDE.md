# CLAUDE.md

@AGENTS.md

## Claude-specific notes

- The delivery plan is `plan.md` and the design doc is `architecture.md` — both live **here at
  the umbrella root**, next to this file (AGENTS.md's "one level above this repo checkout"
  note is stale). Read them before making structural changes; keep them updated when a change
  invalidates what they state.
- Umbrella apps: `apps/catalyst` (headless core — no Phoenix dep), `apps/catalyst_web`
  (LiveView UI), `apps/catalyst_desktop` (wx window wrapping the web app), `apps/catalyst_cli`
  (headless release). Core must never depend on web.
- When done with changes: run `mix precommit` (warnings-as-errors compile, unused-deps check,
  format, tests) and `mix dialyzer`, and fix anything they raise.
- The PI reference implementation (`tmp_pi`, referenced throughout `architecture.md`) is not
  currently checked out anywhere in this workspace — don't assume its files are readable; the
  behavior it defines is summarized in `architecture.md` §1.
