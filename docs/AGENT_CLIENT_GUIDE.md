# LocalMgr: Agent Client Best Practices

**How to use LocalMgr's API gateway as a backend for coding agents (OpenCode, Claude Code, etc.)**

This guide is for users who want to run an AI coding agent against a local model via LocalMgr's gateway (`http://127.0.0.1:4891/v1`), rather than using a hosted provider. Local models behave differently from hosted APIs in ways that matter for agent workloads — this document explains the failure modes and how to avoid them.

---

## The Core Problem: Context Windows and Agent Payload Sizes

Hosted model APIs (OpenAI, Anthropic, etc.) typically offer 128K–200K token context windows. Local models — even large quantized ones — are practically capped much lower by your machine's unified RAM. LocalMgr's hardware auto-tuner sets the engine's context window at launch based on your physical memory:

| Machine RAM | Auto-tuner context cap |
|---|---|
| < 30 GB | 8,192 tokens |
| 30–60 GB | 16,384 tokens |
| 60 GB+ | 32,768 tokens |

You can override the ceiling in **Settings → Hardware & Engines → Inference Defaults** (up to 32K), but the auto-tuner will apply `min(your setting, RAM-tier cap)` — so a 32K setting on a 16 GB machine still launches the engine at 8,192.

Coding agent clients make this worse in two ways:

### Layer 1: The Initial Payload (MCP Tool Schemas)

When you start an agent session, the client serializes the full JSON schema for every registered MCP server into the system prompt — **on every single request**. A daily-driver config with many MCP servers (filesystem, code tools, browser, Veo, Gemini image generation, etc.) can produce payloads exceeding **100,000–200,000 tokens before you type a single word**.

This means the very first request to a local model will be rejected with:

```
The local engine rejected the streaming request: request (167015 tokens) exceeds
the available context size (32768 tokens)
```

This is not a LocalMgr bug — it is the engine correctly enforcing its context window. The fix is to reduce the payload before it reaches the engine.

### Layer 2: Accumulated History (Command Output)

Even with a lean initial payload, subsequent turns that execute shell commands (build output, grep results, test logs, git diffs) can rapidly fill the remaining context window. A single successful `swift build` transcript can be 2,000+ tokens of noise; a failing one with full diagnostics even more.

---

## Fix: Layer 1 — Use a Minimal Agent Config

Keep a **separate, minimal agent config** that omits MCP servers you don't need for a local-model session, and swap to it when using LocalMgr as your backend.

A ready-made starting point for OpenCode is in this repo:

```
testing/opencode.jsonc
```

It contains only the LocalMgr provider with no MCP servers — enough to run a real coding session against a local model, but with a payload that fits comfortably inside any context window. Copy and adapt it:

```bash
# Find your active model ID first
curl -s http://127.0.0.1:4891/v1/models | jq -r '.data[].id'

# Back up your daily-driver config and switch to the minimal one
cp ~/.config/opencode/opencode.jsonc ~/.config/opencode/opencode.jsonc.bak
cp testing/opencode.jsonc ~/.config/opencode/opencode.jsonc
```

Or use the `OPENCODE_CONFIG` environment variable if your OpenCode build supports it, to avoid clobbering your daily-driver config:

```bash
OPENCODE_CONFIG=testing/opencode.jsonc opencode
```

A sample `AGENTS.md` for use inside any project you want to run with a local model is also in this repo at `testing/AGENTS.md`. It documents the `rtk` workflow and sets expectations around context limits — copy it to your project root and adjust as needed.

### What to cut from your daily-driver config

When working with local models, prioritize removing MCP servers whose tool schemas are large but whose tools you won't need for the session:

- **Image/video generation servers** (Veo, Gemini image, etc.) — large schemas, irrelevant for code work
- **Browser/web automation** — large schemas, rarely needed for pure coding tasks
- **Cloud infrastructure tools** — unless your session specifically needs them

Keep: filesystem access, git, any tools you'll actually invoke.

---

## Fix: Layer 2 — Filter Command Output with `rtk`

`rtk` (Rust Token Killer) wraps shell commands to suppress verbose success output, returning only errors and failures. This keeps subsequent-turn context from being dominated by multi-hundred-line build transcripts.

### Install

```bash
# Via cargo
cargo install rtk

# Or check https://github.com/restatedev/rtk for pre-built binaries
```

### Usage

Prefix any shell command with `rtk`:

```bash
# Without rtk: 40+ lines of successful compile output, all going into context
swift build

# With rtk: silent on success, shows errors only
rtk swift build

# Other high-value uses with local model sessions
rtk git diff          # compact diff output
rtk git log           # condensed log
rtk git status        # minimal status
```

A ready-made `AGENTS.md` that instructs your agent to use `rtk` automatically is at `testing/AGENTS.md` in this repo — place it at your project root and the agent will pick it up.

---

## Quick-Start Checklist

Before starting an agent session against a local model:

- [ ] LocalMgr is running and the target model is active (check `http://127.0.0.1:4891/v1/stats`)
- [ ] Agent config uses a minimal provider block (no heavy MCP servers) — see `testing/opencode.jsonc`
- [ ] Model ID in the config matches what's running (`curl http://127.0.0.1:4891/v1/models`)
- [ ] `rtk` is installed and your project's `AGENTS.md` instructs the agent to use it
- [ ] `max_tokens` in any manual curl requests is set high enough for thinking models (≥ 512 for Gemma 4; see below)

---

## Thinking / Reasoning Models (Gemma 4, DeepSeek-R1, etc.)

Gemma 4 and other reasoning models split their output into two streams:

1. **Chain-of-thought** → `choices[0].message.reasoning_content`
2. **Final answer** → `choices[0].message.content`

If `max_tokens` is set too low (e.g. 128), the model can exhaust its token budget entirely on internal reasoning before producing any answer, leaving `content` empty. Set `max_tokens` to 512 or higher for any thinking model:

```bash
curl -s http://127.0.0.1:4891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-E2B-it-Q4_K_M",
    "messages": [{"role": "user", "content": "Explain unified memory in one sentence."}],
    "max_tokens": 512
  }' | jq '{answer: .choices[0].message.content, thinking: .choices[0].message.reasoning_content}'
```

---

## Known Warnings and Non-Issues

### Gemma 4 chat template warning

```
W common_chat_try_specialized_template: detected an outdated gemma4 chat template,
applying compatibility workarounds. Consider updating to the official template.
```

This is printed to stderr by `llama-server` at startup when a GGUF file contains an older `tokenizer.chat_template` metadata string. **No action is required.** `llama-server` automatically detects this and applies its built-in Gemma 4 specialized template as a fallback. It has no effect on output quality or token generation. The warning is purely informational — the compatibility workaround is fully functional.

---

## Smoke Testing Your Setup

The repo includes a standalone regression test that exercises the gateway without requiring a full agent session:

```bash
./testing/smoke_test_gateway.sh
```

It covers: small non-streaming requests, SSE streaming passthrough, large request bodies (>64KB), and long-running generations. Run it after any LocalMgr update or config change to confirm the gateway is working before starting an agent session.

---

*See also: [User Guide → Connecting OpenCode](USER_GUIDE.md#connecting-opencode) for the basic provider setup, and [Architecture Plan](ARCHITECTURE_PLAN.md) for gateway internals.*
