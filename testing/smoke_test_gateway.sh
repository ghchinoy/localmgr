#!/usr/bin/env bash
#
# Smoke test for LocalMgr's API gateway (Sources/LocalMgr/Services/LocalAPIGateway.swift),
# covering three real, previously-shipped bugs found while validating OpenCode
# support (epic localmgr-al0):
#
#   1. localmgr-ae9: gateway silently truncated any HTTP request body over
#      64KB (single-shot NWConnection.receive), corrupting JSON before it
#      reached the upstream engine. Triggered by OpenCode's MCP tool-schema
#      payloads, which routinely exceed 64KB.
#   2. localmgr-al0.1: gateway had no SSE streaming passthrough --
#      "stream": true requests were fully buffered or returned malformed.
#   3. localmgr-mtz: MemoryPressureGuard could kill the runner mid-request
#      for any generation lasting longer than 3 seconds, because
#      BackendRunnerManager.recentlyActive was a rolling-timestamp heuristic
#      rather than a true in-flight flag.
#
# This script does NOT require OpenCode -- it drives the gateway directly
# via curl, so it can be run standalone to catch regressions in any of the
# above before (or without) a full OpenCode session.
#
# Usage:
#   ./testing/smoke_test_gateway.sh [gateway_base_url] [model_id]
#
# Defaults: gateway_base_url=http://127.0.0.1:4891, model_id=first model
# returned by GET /v1/models.
#
# Requires: curl, python3. LocalMgr.app must already be running with the
# gateway listening (make app && open LocalMgr.app), and the target model
# must exist in an attached vault. This script WILL cause LocalMgr to launch
# a real model runner on demand if one isn't already running.

set -uo pipefail

BASE_URL="${1:-http://127.0.0.1:4891}"
PASS=0
FAIL=0

log_pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
log_fail() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }
log_info() { printf "\033[1m%s\033[0m\n" "$1"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 0. Preflight: gateway reachable? -----------------------------------
log_info "0. Preflight"
if ! curl -s --max-time 5 "$BASE_URL/v1/stats" -o "$TMP_DIR/stats0.json"; then
    log_fail "Gateway unreachable at $BASE_URL -- is LocalMgr.app running?"
    echo ""
    echo "Summary: $PASS passed, $FAIL failed (aborted early)"
    exit 1
fi
log_pass "Gateway reachable at $BASE_URL"

MODEL_ID="${2:-}"
if [[ -z "$MODEL_ID" ]]; then
    MODEL_ID=$(curl -s --max-time 5 "$BASE_URL/v1/models" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)
fi
if [[ -z "$MODEL_ID" ]]; then
    log_fail "Could not determine a model ID from GET /v1/models -- pass one explicitly as the 2nd argument."
    echo ""
    echo "Summary: $PASS passed, $FAIL failed (aborted early)"
    exit 1
fi
log_pass "Using model '$MODEL_ID'"
echo ""

# --- 1. Small non-streaming request (baseline / no-regression) ----------
log_info "1. Small non-streaming request (baseline)"
RESP=$(curl -s --max-time 60 "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in exactly 3 words\"}],\"max_tokens\":20}" \
    -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESP" | tail -1)
if [[ "$HTTP_CODE" == "200" ]]; then
    log_pass "Non-streaming request returned HTTP 200"
else
    log_fail "Non-streaming request returned HTTP $HTTP_CODE (expected 200)"
fi
echo ""

# --- 2. Small streaming request (localmgr-al0.1) -------------------------
log_info "2. Streaming request (localmgr-al0.1: SSE passthrough)"
STREAM_OUT="$TMP_DIR/stream_out.txt"
curl -s -N --max-time 60 "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in exactly 3 words\"}],\"max_tokens\":20,\"stream\":true}" \
    > "$STREAM_OUT"
CHUNK_COUNT=$(grep -c '^data:' "$STREAM_OUT")
if grep -q '^data: \[DONE\]' "$STREAM_OUT" && [[ "$CHUNK_COUNT" -gt 1 ]]; then
    log_pass "Streaming response has $CHUNK_COUNT SSE chunks and a [DONE] terminator"
else
    log_fail "Streaming response malformed (chunks=$CHUNK_COUNT, has [DONE]=$(grep -q '^data: \[DONE\]' "$STREAM_OUT" && echo yes || echo no))"
fi
echo ""

# --- 3. Large request body >64KB (localmgr-ae9) --------------------------
log_info "3. Large request body >64KB (localmgr-ae9: truncation fix)"
LARGE_PAYLOAD="$TMP_DIR/large_payload.json"
python3 - "$MODEL_ID" "$LARGE_PAYLOAD" <<'PYEOF'
import json, sys
model_id, out_path = sys.argv[1], sys.argv[2]
big_desc = (
    "Optional array of MIME types corresponding to reference_image_uris. "
    "If provided, must match the length of URIs. If not provided, inferred "
    "from extensions. "
) * 60
payload = {
    "model": model_id,
    "messages": [{"role": "user", "content": "Say hi in exactly 3 words"}],
    "max_tokens": 20,
    "tools": [
        {
            "type": "function",
            "function": {
                "name": f"tool_{i}",
                "description": big_desc,
                "parameters": {"type": "object", "properties": {}},
            },
        }
        for i in range(8)
    ],
}
with open(out_path, "w") as f:
    json.dump(payload, f)
PYEOF
PAYLOAD_BYTES=$(wc -c < "$LARGE_PAYLOAD" | tr -d ' ')
LARGE_RESP=$(curl -s --max-time 120 "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d @"$LARGE_PAYLOAD" \
    -w "\n%{http_code}")
LARGE_HTTP_CODE=$(echo "$LARGE_RESP" | tail -1)
LARGE_BODY=$(echo "$LARGE_RESP" | sed '$d')
# Success criteria: NOT a JSON parse/truncation error. A clean 200, or even a
# legitimate downstream 400 "exceeds context size" (proves the full payload
# was parsed correctly -- the model just doesn't have enough context, which
# is a config issue, not a gateway bug) both indicate no truncation occurred.
if echo "$LARGE_BODY" | grep -qi "missing closing quote\|parse_error\|invalid string"; then
    log_fail "Large payload ($PAYLOAD_BYTES bytes) triggered a JSON truncation/parse error -- gateway is truncating requests again!"
    echo "    Response: $(echo "$LARGE_BODY" | head -c 300)"
elif [[ "$LARGE_HTTP_CODE" == "200" ]]; then
    log_pass "Large payload ($PAYLOAD_BYTES bytes) succeeded with HTTP 200"
elif echo "$LARGE_BODY" | grep -qi "exceed_context_size_error\|exceeds the available context"; then
    log_pass "Large payload ($PAYLOAD_BYTES bytes) was received intact (engine reports context-size limit, not a parse error -- increase Default Context Length in Settings if you want this to fully succeed)"
else
    log_fail "Large payload ($PAYLOAD_BYTES bytes) returned unexpected HTTP $LARGE_HTTP_CODE: $(echo "$LARGE_BODY" | head -c 300)"
fi
echo ""

# --- 4. Long-duration request stays alive (localmgr-mtz) ------------------
log_info "4. Long-duration request survives memory-pressure guard (localmgr-mtz)"
echo "    (Uses a distinct large payload -- not the same as step 3 -- to avoid a KV-cache hit"
echo "     that would make this complete too fast to be a meaningful duration test. This only"
echo "     proves the request completes, not that a real WARNING pressure event was active"
echo "     during it -- see localmgr-mtz's close reason for how that was verified live.)"
LARGE_PAYLOAD_2="$TMP_DIR/large_payload_2.json"
python3 - "$MODEL_ID" "$LARGE_PAYLOAD_2" <<'PYEOF'
import json, sys
model_id, out_path = sys.argv[1], sys.argv[2]
big_desc = (
    "Distinct filler text to avoid a prompt-cache hit against step 3's payload. "
    "This array of MIME types corresponds to reference_image_uris and must match "
    "the length of URIs, else it is inferred from extensions. "
) * 60
payload = {
    "model": model_id,
    "messages": [{"role": "user", "content": "Say goodbye in exactly 3 words"}],
    "max_tokens": 20,
    "tools": [
        {
            "type": "function",
            "function": {
                "name": f"other_tool_{i}",
                "description": big_desc,
                "parameters": {"type": "object", "properties": {}},
            },
        }
        for i in range(8)
    ],
}
with open(out_path, "w") as f:
    json.dump(payload, f)
PYEOF
LONG_START=$(date +%s)
LONG_RESP=$(curl -s --max-time 180 "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d @"$LARGE_PAYLOAD_2" \
    -w "\n%{http_code}")
LONG_END=$(date +%s)
LONG_HTTP_CODE=$(echo "$LONG_RESP" | tail -1)
LONG_DURATION=$((LONG_END - LONG_START))
if [[ "$LONG_HTTP_CODE" == "200" ]] || echo "$LONG_RESP" | grep -qi "exceed_context_size_error"; then
    log_pass "Request ran for ${LONG_DURATION}s and returned a clean response (not silently dropped)"
else
    LONG_BODY=$(echo "$LONG_RESP" | sed '$d')
    log_fail "Request ran for ${LONG_DURATION}s and returned unexpected HTTP $LONG_HTTP_CODE: $(echo "$LONG_BODY" | head -c 300)"
fi
echo ""

# --- 5. GET endpoints (baseline / no-regression) --------------------------
log_info "5. GET endpoints (baseline)"
for path in "/v1/models" "/v1/stats" "/metrics"; do
    CODE=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$BASE_URL$path")
    if [[ "$CODE" == "200" ]]; then
        log_pass "GET $path returned HTTP 200"
    else
        log_fail "GET $path returned HTTP $CODE (expected 200)"
    fi
done
echo ""

# --- Summary --------------------------------------------------------------
log_info "Summary: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
