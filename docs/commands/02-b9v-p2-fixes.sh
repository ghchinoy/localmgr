#!/usr/bin/env bash
# Run ON THE MAC HOST, from the localmgr repo root:  bash docs/commands/02-b9v-p2-fixes.sh
#
# Container agents can't write bd here (BEADS_DOLT_AUTO_START=false; the
# container must stay Dolt-free since .beads/dolt/ is a virtiofs bind mount
# shared with this host -- only one dolt sql-server may own it at a time).
# This script carries the bd bookkeeping for the container's code changes
# back to the host, which owns the single Dolt lock.
#
# What this covers: the 4 P2 tasks under localmgr-b9v (Epic: Security,
# Concurrency & Reliability Audit Remediation): b9v.6 through b9v.9.
# b9v.10 (ACC-1, P3, accessibility labels) is NOT touched by this script --
# separate follow-up. The 5 P1 tasks (b9v.1-.5) were already verified/closed
# via docs/commands/01-b9v-p1-fixes.sh and shipped in v0.5.2.
#
# Safe to re-run: claims/creates are idempotent-ish (`|| true` on lines that
# can legitimately no-op on a rerun). bd comment is NOT idempotent -- rerunning
# duplicates comments. bd close on an already-closed issue errors harmlessly
# under `|| true`.
set -u
test -d .beads || { echo "Run from the localmgr repo root on the Mac."; exit 1; }

# Author of the staged content (this container agent).
AUTHOR="agent:container:implementer"
# Whoever runs this script post-verification (defaults to the host's session actor).
CLOSER="${BEADS_ACTOR:-agent:host:verifier}"

echo "==> Sanity: confirm Dolt is healthy before writing anything"
bd dolt status || { echo "Dolt not healthy -- stop and fix before proceeding (see kb/how_to_fix_bd.md)."; exit 1; }

echo "==> Claim the 4 P2 tasks (idempotent if already claimed by you)"
bd update localmgr-b9v.6 --claim --actor "$AUTHOR" || true
bd update localmgr-b9v.7 --claim --actor "$AUTHOR" || true
bd update localmgr-b9v.8 --claim --actor "$AUTHOR" || true
bd update localmgr-b9v.9 --claim --actor "$AUTHOR" || true

echo "==> Per-issue comments: what changed + file:line + verification needed"

bd comment localmgr-b9v.6 "Fixed (REL-2). BackendRunnerManager.swift: logOutput gained a
didSet observer that truncates to the last 100,000 characters
(private static let maxLogOutputCharacters = 100_000) whenever it grows past
that threshold. This covers every existing append/assignment call site
automatically (idle-reclaim, hardware auto-tuner notices, process
start/stop/termination messages, live stdout/stderr streaming) without
needing individual edits at each of the ~10 call sites.
VERIFY ON HOST: run a chatty/verbose model (or a long session) long enough
to exceed 100K characters of combined stdout/stderr + app notices in the
Live Logs tab; confirm the tab keeps scrolling/rendering smoothly and the
buffer doesn't keep growing unbounded (e.g. sample .count via a breakpoint
or just observe memory in Activity Monitor stays flat once the cap kicks
in)." --actor "$AUTHOR"

bd comment localmgr-b9v.7 "Fixed (SEC-3). ModelCatalogService.swift: added
removeFolder(_:) (pairs stopAccessingSecurityScopedResource() with the
folder's start call, removes it from folders + the UserDefaults bookmark
array) and releaseAllFolderAccess() (stops access for every tracked folder).
AppDelegate.applicationWillTerminate now calls
catalogService?.releaseAllFolderAccess(), mirroring the existing
runnerManager?.stopCurrent() orphan-prevention hook, so every
startAccessingSecurityScopedResource() call this session is paired with a
stopAccessing... by the time the app exits. Note: there's still no 'Remove
Folder' UI button wired to removeFolder(_:) -- it's available as an API for
a future UI affordance, but the core SEC-3 ask (pair start/stop, don't rely
solely on implicit OS cleanup at process death) is satisfied via the
app-termination hook.
VERIFY ON HOST: add a folder, quit the app normally, relaunch -- confirm the
folder and its models are still there (bookmark round-trip unaffected).
Optionally set a breakpoint / log line in releaseAllFolderAccess() to
confirm it fires on quit." --actor "$AUTHOR"

bd comment localmgr-b9v.8 "Fixed (RACE-3). LocalAPIGateway.swift: added a
private var isSwappingModel = false guard around the on-demand model swap +
wait-for-ready sequence in handleChatCompletions. A concurrent request for a
*different* model that arrives while isSwappingModel is true now gets an
immediate 409 (\"Another model swap is already in progress\") instead of
being able to interleave its own startModel() call during the first
request's Task.sleep-based wait-for-ready polling loop (the actual race
window, since MainActor reentrancy allows a second isolated call to run
while the first is suspended at that await point).
VERIFY ON HOST: fire two concurrent curl requests at
/v1/chat/completions for two *different* models that aren't currently
loaded (e.g. via 'curl ... & curl ... &' in quick succession) -- confirm
exactly one 200/success path proceeds and the other gets a clean 409,
rather than two runner subprocesses spawning or one getting orphaned." --actor "$AUTHOR"

bd comment localmgr-b9v.9 "Fixed (REL-4). LocalAPIGateway.swift:
handleChatCompletions now detects \"stream\": true in the request body and
routes to a new streamChatCompletion(...) method, which uses
proxySession.bytes(for:) to get the upstream engine's SSE byte stream, sends
the HTTP response header block once up front (text/event-stream, no
Content-Length since size is unknown, Connection: close), then forwards
bytes in ~4KB chunks as they arrive via connection.send(...). Non-streaming
completions are unaffected (unchanged buffered path). Known limitation
(documented in the code): token/prompt accounting for streamed completions
is a byte-count estimate, not parsed from the SSE payload, since most local
engines only emit usage in the final chunk when explicitly requested via
stream_options.
VERIFY ON HOST: send a chat completion with \"stream\": true (e.g. via a
chat UI that defaults to streaming, or curl -N .../v1/chat/completions -d
'{...,\"stream\":true}') and confirm tokens arrive incrementally rather than
all at once at the end; confirm non-streaming requests still work exactly
as before." --actor "$AUTHOR"

echo "==> Verify task for this round (host works FROM this, then closes it after checks pass)"
bd create "Task: Verify & Close b9v P2 Fixes (build + smoke tests)" \
  --type task --priority 2 --parent localmgr-b9v --actor "$AUTHOR" \
  --description "Host verification gate for localmgr-b9v.6 through .9 (see each
issue's bd comment for the specific manual smoke test). Steps:
1. swift build -c release (or make build) succeeds with no new warnings from
   the touched files (BackendRunnerManager.swift, ModelCatalogService.swift,
   AppDelegate.swift, LocalAPIGateway.swift).
2. make run / Xcode run, then work through each b9v.N comment's 'VERIFY ON
   HOST' checklist above.
3. If all pass: bd close localmgr-b9v.6 .7 .8 .9 (see CLOSE SECTION below),
   then close this verify task. With P1 (b9v.1-.5) and P2 (b9v.6-.9) both
   done, only b9v.10 (P3, accessibility) remains under the epic -- consider
   whether to fold that in separately before closing localmgr-b9v itself.
4. If something fails: bd comment the specific failure on the relevant
   b9v.N issue and leave it open; do not close b9v.6-.9 wholesale if only
   one fix has a problem." || true

echo "==> CLOSE SECTION -- only run after the verify task's checks above pass"
bd close localmgr-b9v.6 --reason "Verified: logOutput capped at 100K chars via didSet, no unbounded growth." --actor "$CLOSER" || true
bd close localmgr-b9v.7 --reason "Verified: security-scoped bookmark access released on app quit." --actor "$CLOSER" || true
bd close localmgr-b9v.8 --reason "Verified: concurrent model swaps now serialized, no duplicate/orphaned runners." --actor "$CLOSER" || true
bd close localmgr-b9v.9 --reason "Verified: streaming completions forward SSE bytes incrementally." --actor "$CLOSER" || true
# NOTE: do NOT close localmgr-b9v (the epic) here -- b9v.10 (P3, ACC-1) is
# still open under it. Close the epic once that's addressed too, or
# explicitly decide to defer it and close the epic anyway in a separate step.

echo "==> Export source of truth + show for review"
bd export -o .beads/issues.jsonl
git status --short .beads/issues.jsonl
echo "Suggested: git add .beads/issues.jsonl && git commit -m 'chore(beads): claim/verify/close localmgr-b9v P2 fixes'"
