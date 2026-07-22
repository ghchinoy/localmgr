# AGENTS.md — Local Model Session

This file instructs AI coding agents on how to work effectively when the active
provider is a **local model via LocalMgr's gateway** (`http://127.0.0.1:4891/v1`).

Copy this file to your project root when starting a session against a local model.
Remove or replace it when switching back to a hosted provider.

---

## Context Budget

Local models have hard context limits set by your machine's unified RAM:

| Machine RAM | Effective context window |
|---|---|
| < 30 GB | ~8,000 tokens |
| 30–60 GB | ~16,000 tokens |
| 60 GB+ | ~32,000 tokens |

**Treat every token as expensive.** Prefer targeted reads and precise searches over
broad scans. Avoid dumping large files into context when a focused grep or symbol
lookup will do.

---

## Shell Commands: Always Use `rtk`

When running shell commands, **always prefix with `rtk`**. This suppresses verbose
success output, keeping only errors and failures in context. It passes through
unchanged for any command it doesn't recognize — always safe to use.

```bash
# Build (shows errors only, not the full compile transcript)
rtk swift build

# Git (compact output)
rtk git status
rtk git diff
rtk git log

# Search and file ops (filtered output)
rtk grep <pattern>
rtk find <pattern>
```

In command chains, prefix each segment:

```bash
rtk git add . && rtk git commit -m "message"
```

For debugging a specific failure where you need full output, use the raw command
without the `rtk` prefix.

---

## Model Constraints

- **One model at a time.** LocalMgr runs a single model runner. Do not request a
  different model mid-session; it will return `409 gateway-model-conflict`.
- **No API key.** The gateway performs no `Authorization` check.
- **Streaming is on by default** and works correctly (SSE passthrough).
- **Thinking model output.** Gemma 4 and similar reasoning models write
  chain-of-thought to `reasoning_content` before the final answer in `content`.
  If a response appears empty, the model spent its token budget reasoning. Use
  higher `max_tokens` (≥ 512) for any non-trivial prompt.

---

## Verification

```bash
# Confirm the gateway and runner are up before starting
curl -s http://127.0.0.1:4891/v1/stats | jq '{status: .runner_status, model: .active_model}'

# List available models
curl -s http://127.0.0.1:4891/v1/models | jq -r '.data[].id'
```

---

*Full best-practices guide: [`docs/AGENT_CLIENT_GUIDE.md`](../docs/AGENT_CLIENT_GUIDE.md)*
