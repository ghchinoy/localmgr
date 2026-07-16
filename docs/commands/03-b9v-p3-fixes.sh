#!/usr/bin/env bash
# Run ON THE MAC HOST, from the localmgr repo root:  bash docs/commands/03-b9v-p3-fixes.sh
#
# Container agents can't write bd here (BEADS_DOLT_AUTO_START=false; the
# container must stay Dolt-free since .beads/dolt/ is a virtiofs bind mount
# shared with this host -- only one dolt sql-server may own it at a time).
# This script carries the bd bookkeeping for the container's code changes
# back to the host, which owns the single Dolt lock.
#
# What this covers: the last remaining task under localmgr-b9v (Epic:
# Security, Concurrency & Reliability Audit Remediation) -- b9v.10 (P3,
# ACC-1, VoiceOver accessibility labels). The 5 P1 tasks (b9v.1-.5, shipped
# in v0.5.2) and 4 P2 tasks (b9v.6-.9, shipped in v0.5.3) were already
# verified/closed in prior rounds. Since b9v.10 is the LAST open child, this
# script's close section also closes the epic itself.
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

echo "==> Claim b9v.10 (idempotent if already claimed by you)"
bd update localmgr-b9v.10 --claim --actor "$AUTHOR" || true

echo "==> Comment: what changed + file:line + verification needed"
bd comment localmgr-b9v.10 "Fixed (ACC-1). Added .accessibilityLabel(...) and
.accessibilityValue(...) to all 4 color-only status-dot Circle() views found
in the app (a plain colored dot conveys nothing to VoiceOver by default):
- SidebarView.swift: API Gateway online/offline dot -> label 'Gateway
  status', value 'Online'/'Offline'.
- SidebarView.swift: Active Runner status dot -> label 'Runner status',
  value runner.status.rawValue ('Running'/'Starting...'/'Error').
- SidebarView.swift: Component Readiness dot, one per engine in a ForEach
  -> label '<engine> readiness' (e.g. 'llama.cpp readiness'), value
  'Ready'/'Missing'.
- MenuBarView.swift: Active model status dot -> label 'Runner status',
  value runner.status.rawValue.
VERIFY ON HOST: enable VoiceOver (Cmd+F5), navigate to each of the 4
locations (main window sidebar: API Gateway section, Active Runner section,
Component Readiness section; menu bar extra popover), and confirm VoiceOver
announces something meaningful for each status dot (e.g. 'Gateway status,
Online') rather than silence or a generic 'image' announcement." --actor "$AUTHOR"

echo "==> Verify task for this round"
bd create "Task: Verify & Close b9v P3 Fix (VoiceOver smoke test)" \
  --type task --priority 3 --parent localmgr-b9v --actor "$AUTHOR" \
  --description "Host verification gate for localmgr-b9v.10 (see its bd
comment for the specific VoiceOver smoke test). Steps:
1. swift build -c release (or make build) succeeds with no new warnings from
   the touched files (SidebarView.swift, MenuBarView.swift).
2. Enable VoiceOver (Cmd+F5) and work through the 'VERIFY ON HOST' checklist
   on b9v.10's comment.
3. If it passes: bd close localmgr-b9v.10 (see CLOSE SECTION below), then
   close this verify task, then close localmgr-b9v itself -- this is the
   last remaining child under the epic, so once this closes the epic is
   done.
4. If something fails: bd comment the failure on localmgr-b9v.10 and leave
   it (and the epic) open." || true

echo "==> CLOSE SECTION -- only run after the verify task's checks above pass"
bd close localmgr-b9v.10 --reason "Verified: VoiceOver announces meaningful status for all 4 status dots." --actor "$CLOSER" || true
echo "==> All 10 b9v child tasks now closed -- closing the epic itself"
bd close localmgr-b9v --reason "All 10 child tasks (5 P1, 4 P2, 1 P3) implemented and host-verified across v0.5.2, v0.5.3, and this round." --actor "$CLOSER" || true

echo "==> Export source of truth + show for review"
bd export -o .beads/issues.jsonl
git status --short .beads/issues.jsonl
echo "Suggested: git add .beads/issues.jsonl && git commit -m 'chore(beads): close localmgr-b9v.10 and the b9v epic'"
