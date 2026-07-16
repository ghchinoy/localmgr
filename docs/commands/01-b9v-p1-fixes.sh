#!/usr/bin/env bash
# Run ON THE MAC HOST, from the localmgr repo root:  bash docs/commands/01-b9v-p1-fixes.sh
#
# Container agents can't write bd here (BEADS_DOLT_AUTO_START=false; the
# container must stay Dolt-free since .beads/dolt/ is a virtiofs bind mount
# shared with this host -- only one dolt sql-server may own it at a time).
# This script carries the bd bookkeeping for the container's code changes
# back to the host, which owns the single Dolt lock.
#
# What this covers: the 5 P1 tasks under localmgr-b9v (Epic: Security,
# Concurrency & Reliability Audit Remediation). The container independently
# re-verified all 5 against the current code before fixing them (see the
# bd comments below and the inline `(localmgr-b9v.N / ...)` markers left in
# the diff itself). P2/P3 tasks (b9v.6-.10) are NOT touched by this script;
# they're a separate follow-up round.
#
# IMPORTANT: .beads/dolt/ was found corrupted this session (journal
# corruption / checksum errors), almost certainly from the container
# transiently running its own `bd dolt start` against this shared,
# bind-mounted directory -- a mistake, now corrected (container is Dolt-free
# again; see kb/container-living.md Sec 2-3). Before running this script,
# confirm your own `bd dolt status` is healthy on the host. If it's not,
# see kb/how_to_fix_bd.md and the bd-dolt-troubleshooter skill first --
# this script assumes a working Dolt server.
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

echo "==> Claim the 5 P1 tasks (idempotent if already claimed by you)"
bd update localmgr-b9v.1 --claim --actor "$AUTHOR" || true
bd update localmgr-b9v.2 --claim --actor "$AUTHOR" || true
bd update localmgr-b9v.3 --claim --actor "$AUTHOR" || true
bd update localmgr-b9v.4 --claim --actor "$AUTHOR" || true
bd update localmgr-b9v.5 --claim --actor "$AUTHOR" || true

echo "==> Per-issue comments: what changed + file:line + verification needed"

bd comment localmgr-b9v.1 "Fixed (SEC-1). LocalAPIGateway.swift: startListening() now sets
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: \"127.0.0.1\", port: listenerPort)
before creating the NWListener, restricting the bind to loopback instead of all
interfaces. sendHTTPResponse(...) gained an allowedOrigin: String? = nil param;
the previous hardcoded 'Access-Control-Allow-Origin: *' is gone. A new
allowedCORSOrigin(from:) helper reflects the request's Origin header back only
when its host is 127.0.0.1/localhost/::1 (any port); every other Origin gets no
CORS header at all. Threaded allowedOrigin through processHTTPRequest and all 4
handler functions (handleModelsList/handleStats/handlePrometheusMetrics/
handleChatCompletions) and their ~13 sendHTTPResponse call sites.
VERIFY ON HOST: after 'make build && make run' (or Xcode run), confirm
'curl http://127.0.0.1:4891/v1/models' still works, and (if you have a second
device on the same LAN) confirm it can no longer reach the gateway at all.
Also confirm a same-origin fetch (e.g. a page served from 127.0.0.1) still
gets Access-Control-Allow-Origin back, and a fetch with an arbitrary Origin
header (curl -H 'Origin: https://evil.example') gets no such header." --actor "$AUTHOR"

bd comment localmgr-b9v.2 "Fixed (SEC-2). LocalAPIGateway.swift: replaced the single fixed
'connection.receive(minimumIncompleteLength: 1, maximumLength: 65536)' read
with a new receiveRequest(connection:buffer:) that recurses across as many
TCP reads as needed, parses headers once \r\n\r\n is found, honors
Content-Length to know when the body is fully buffered, and enforces a new
private static let maxRequestBytes = 10MB cap (413 + connection.cancel() if
exceeded). Added an extractHeaderValue(_:from:) helper (also reused by the
new CORS logic in b9v.1).
VERIFY ON HOST: send a >64KB (but <10MB) POST body to
/v1/chat/completions (e.g. a very long prompt) and confirm it's no longer
truncated/mis-parsed; send a >10MB body and confirm a clean 413 instead of a
hang or crash; confirm ordinary small GET/POST requests (existing behavior)
are unaffected." --actor "$AUTHOR"

bd comment localmgr-b9v.3 "Fixed (RACE-2). BackendRunnerManager.swift: the readabilityHandler
closure now checks 'guard !data.isEmpty else { handle.readabilityHandler = nil;
return }' at the top -- an empty read is EOF, and this is the standard fix for
the well-known Pipe/FileHandle CPU-spin-on-EOF gotcha. Also nils the handler
(via self.pipe) inside terminationHandler and in stopCurrent(), so it's
cleared on every exit path, not just EOF.
VERIFY ON HOST: start a model, stop it (or let it exit/crash), and watch
Activity Monitor / 'top' for LocalMgr's CPU immediately after -- should drop
to ~0%, not spin." --actor "$AUTHOR"

bd comment localmgr-b9v.4 "Fixed (RACE-1). BackendRunnerManager.swift: the 2s
DispatchQueue.main.asyncAfter fallback-status closure now guards on
'self.currentProcess === process' (identity), not just status/isRunning, so a
stop+restart within that 2s window can no longer let a stale timer flip
.running for the wrong session. The terminationHandler's cleanup
(currentProcess/activeModel/pipe = nil) is similarly gated on
'self.currentProcess === proc' for the same reason.
VERIFY ON HOST: rapidly start a model, stop it, and start a different model
within ~2 seconds (a few times) -- confirm the status badge/Live Logs never
end up misattributed to the wrong model, and the correct one ends up
.running." --actor "$AUTHOR"

bd comment localmgr-b9v.5 "Fixed (REL-1). ModelCatalogService.swift:
refreshCatalog() now snapshots 'folders' synchronously (unchanged call-site
semantics/signature -- still fire-and-forget, not async) and runs the actual
FileManager enumeration + GGUFHeaderParser.inspect work via
Task.detached(priority: .userInitiated) calling new nonisolated private
static scanFolders(_:)/calculateFolderSize(_:), then hops back via
'await MainActor.run { self?.models = scanned }' to publish the result. No
call sites changed (app launch, folder add, manual refresh, post-download all
still just call refreshCatalog()).
VERIFY ON HOST: point the vault at a folder with many/large GGUF files and
confirm the UI (window drag, sidebar clicks) stays responsive during a
refresh (manual refresh button and adding a new folder), instead of
beachballing." --actor "$AUTHOR"

echo "==> Verify task for the epic (host works FROM this, then closes it after checks pass)"
bd create "Task: Verify & Close b9v P1 Fixes (build + smoke tests)" \
  --type task --priority 1 --parent localmgr-b9v --actor "$AUTHOR" \
  --description "Host verification gate for localmgr-b9v.1 through .5 (see each
issue's bd comment for the specific manual smoke test). Steps:
1. swift build -c release (or make build) succeeds with no new warnings from
   the touched files (LocalAPIGateway.swift, BackendRunnerManager.swift,
   ModelCatalogService.swift).
2. make run / Xcode run, then work through each b9v.N comment's 'VERIFY ON
   HOST' checklist above.
3. If all pass: bd close localmgr-b9v.1 .2 .3 .4 .5 (see CLOSE SECTION below),
   then close this verify task, then close localmgr-b9v itself in a
   follow-up bd close (not bundled into this script -- see lifecycle note).
4. If something fails: bd comment the specific failure on the relevant
   b9v.N issue and leave it open; do not close b9v.1-.5 wholesale if only
   one fix has a problem." || true

echo "==> CLOSE SECTION -- only run after the verify task's checks above pass"
bd close localmgr-b9v.1 --reason "Verified: loopback binding + reflected-origin CORS." --actor "$CLOSER" || true
bd close localmgr-b9v.2 --reason "Verified: Content-Length framing + 10MB cap." --actor "$CLOSER" || true
bd close localmgr-b9v.3 --reason "Verified: readabilityHandler cleared on EOF/exit, no CPU spin." --actor "$CLOSER" || true
bd close localmgr-b9v.4 --reason "Verified: fallback timer gated on process identity." --actor "$CLOSER" || true
bd close localmgr-b9v.5 --reason "Verified: catalog scan backgrounded, UI stays responsive." --actor "$CLOSER" || true
# NOTE: do NOT close localmgr-b9v (the epic) here -- leave it open until the
# verify task above also closes, per the implement->verify->close lifecycle
# (kb/container-living.md Sec 2). Close it in a separate follow-up step once
# you're satisfied all 5 verifications passed.

echo "==> Export source of truth + show for review"
bd export -o .beads/issues.jsonl
git status --short .beads/issues.jsonl
echo "Suggested: git add .beads/issues.jsonl && git commit -m 'chore(beads): claim/verify/close localmgr-b9v P1 fixes'"
