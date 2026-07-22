# AGENTS.md

## Progressive Agent Onboarding & Context

To gain a progressive, comprehensive understanding of **LocalMgr**, agents should follow this reading hierarchy:
1. **[GEMINI.md](GEMINI.md)**: Start here for the core project overview, architecture stack, build commands (`make app`), and key service roles.
2. **[docs/](docs/) Directory**: Review the deep-dive architectural blueprints and Core User Journeys:
   - [docs/ARCHITECTURE_PLAN.md](docs/ARCHITECTURE_PLAN.md): Detailed multi-backend architecture, system diagrams, and engine routing.
   - [docs/USER_JOURNEYS.md](docs/USER_JOURNEYS.md): Mapped CUJs (`CUJ-1`, `CUJ-2`, `CUJ-3`), issue tracking IDs, and Diátaxis documentation alignment.

---

## Verification & Testing Protocol

**LocalMgr currently has no automated test target** (see `localmgr-jhj.1`, tracked to add one). Until that lands, `swift build` succeeding is necessary but **not sufficient** evidence that a change works — it only proves the code is syntactically/type valid, not that its runtime behavior is correct. A `bd close` reason of "implemented and compiles" is not acceptable verification; close reasons should cite what was actually exercised and observed. Use whichever of the following techniques fit the change:

1. **Standalone SwiftPM verification harness (pure logic).** For any new pure type/algorithm (e.g. `MemoryPressureGuard`, `HardwareAutoTuner` classification, `CompatibilityTier` rules), scaffold a throwaway `swift-tools-version: 6.0` package under `/tmp/`, copy in only the files under test (plus a minimal `AppLog`/`LogCategory` stub if needed — most `Services/`/`Models/` files depend on it), and write real assertions (synthetic input sequences, fake clocks/injected dependencies, edge cases) rather than eyeballing the code. Run with `swift run`. **This has already caught a real bug** (an explicit `init() {}` that silently suppressed Swift's memberwise-initializer synthesis, making a type's documented "injectable for tests" claim false) that a full read-through missed. Delete the harness when done — do not commit it or leave it in the repo.
2. **Live end-to-end testing against real engines.** This dev machine has `llama-server`, `mlx_lm.server`, and real GGUF/MLX models available locally (see `EngineReadinessService`'s search paths). For any change touching `BackendRunnerManager`, `LocalAPIGateway`, `EngineReadinessService`, or `HardwareAutoTuner`, actually run `make app`, `open LocalMgr.app`, and exercise it with `curl` against `http://127.0.0.1:4891` (gateway) and/or by starting a real model — don't just trace the code path by reading it. Real memory/thermal conditions on this machine have already surfaced genuine behavior (e.g. `MemoryPressureGuard` soft-evicting an idle runner under actual WARNING pressure) that a mocked test would not exercise.
3. **UI verification via AppleScript/System Events.** For SwiftUI view changes, don't just confirm the build compiles — actually launch the app and drive it:
   ```bash
   osascript -e 'tell application "LocalMgr" to activate'
   osascript -e 'tell application "System Events" to keystroke "," using command down'  # open Settings
   osascript << 'EOF'
   tell application "System Events"
       tell process "LocalMgr"
           set win to window "Hardware & Engines"
           set allEls to entire contents of win
           repeat with el in allEls
               try
                   if class of el is checkbox then log (value of el)
               end try
           end repeat
       end tell
   end tell
   EOF
   ```
   Reading live `static text`/`checkbox` element values this way is what caught a real bug this session: a sidebar list that appeared correct on read-through was actually bypassing new gating logic and still rendering disabled state incorrectly. Click buttons/toggles (`click button "..."`, `click checkbox`) and re-read values to confirm state actually changes, rather than assuming a binding is wired correctly.
4. **Confirm log/error output matches user-facing output.** When a change touches `AppLog`/`LocalMgrError`/`DiagnosticCheck`, verify with `log show --predicate 'subsystem == "com.localmgr.mac"' --last '10m'` (note: use `/usr/bin/log`, not a shadowed `log` alias/function, and pass duration as a single quoted argument, e.g. `'10m'`) that what's logged internally actually matches what a `curl` response or UI banner shows — these are supposed to be the same object (`LocalMgrError`), and this is the cheapest way to prove it.
5. **Clean up after testing.** Kill any spawned processes (`pkill -f "LocalMgr.app/Contents/MacOS/LocalMgr"`, `pkill -f llama-server`) and delete throwaway `/tmp` harnesses before finishing a task. Verify with `ps aux | grep -i localmgr` that nothing was left running.
6. **Version/CHANGELOG discipline.** Any user-facing change ships with a version bump (patch for fixes, minor for new functionality — ask if ambiguous) in `Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`) and a corresponding `CHANGELOG.md` entry with `bd` issue-ID references, following the existing per-version format. Rebuild (`make app`) and re-check the bundled `Info.plist` after bumping, don't just trust the source edit.

---

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.

**Quick reference:**
- `bd ready` - Find unblocked work
- `bd create "Title" --type task --priority 2` - Create issue
- `bd close <id>` - Complete work
- `bd dolt push` - Push beads to remote

For full workflow details: `bd prime`


<!-- headroom:rtk-instructions -->
# RTK (Rust Token Killer) - Token-Optimized Commands

When running shell commands, **always prefix with `rtk`**. This reduces context
usage by 60-90% with zero behavior change. If rtk has no filter for a command,
it passes through unchanged — so it is always safe to use.

## Key Commands
```bash
# Git (59-80% savings)
rtk git status          rtk git diff            rtk git log

# Files & Search (60-75% savings)
rtk ls <path>           rtk read <file>         rtk grep <pattern>
rtk find <pattern>      rtk diff <file>

# Test (90-99% savings) — shows failures only
rtk pytest tests/       rtk cargo test          rtk test <cmd>

# Build & Lint (80-90% savings) — shows errors only
rtk tsc                 rtk lint                rtk cargo build
rtk prettier --check    rtk mypy                rtk ruff check

# Analysis (70-90% savings)
rtk err <cmd>           rtk log <file>          rtk json <file>
rtk summary <cmd>       rtk deps                rtk env

# GitHub (26-87% savings)
rtk gh pr view <n>      rtk gh run list         rtk gh issue list

# Infrastructure (85% savings)
rtk docker ps           rtk kubectl get         rtk docker logs <c>

# Package managers (70-90% savings)
rtk pip list            rtk pnpm install        rtk npm run <script>
```

## Rules
- In command chains, prefix each segment: `rtk git add . && rtk git commit -m "msg"`
- For debugging, use raw command without rtk prefix
- `rtk proxy <cmd>` runs command without filtering but tracks usage
<!-- /headroom:rtk-instructions -->

<!-- BEGIN BEADS INTEGRATION v:1 profile:full hash:19cc25d9 -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Dolt-powered version control with native sync
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update <id> --claim --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task atomically**: `bd update <id> --claim`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Quality
- Use `--acceptance` and `--design` fields when creating issues
- Use `--validate` to check description completeness

### Lifecycle
- `bd defer <id>` / `bd supersede <id>` for issue management
- `bd stale` / `bd orphans` / `bd lint` for hygiene
- `bd human <id>` to flag for human decisions
- `bd formula list` / `bd mol pour <name>` for structured workflows

### Sync

bd stores issue history in Dolt:

- Each write auto-commits to Dolt history
- Use `bd dolt push`/`bd dolt pull` for remote sync
- Do not treat `.beads/issues.jsonl` as the sync protocol

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.

<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
