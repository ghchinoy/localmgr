# LocalMgr

**LocalMgr** is a standalone, native macOS application built with Swift 6 and SwiftUI, designed to orchestrate and manage local AI execution engines and models on Apple Silicon. It provides zero-copy unified memory protection, real-time hardware telemetry, and an built-in OpenAI-compatible reverse proxy.

<img width="1424" height="1038" alt="Image" src="https://github.com/user-attachments/assets/21218300-a4b0-43fc-a7b0-d7e3a29efb89" />

---

## Value Proposition & Scope

### What LocalMgr Solves
- **Multi-Engine Orchestration**: Manages local execution lifecycles for four distinct model formats: GGUF (`llama-server`), Apple MLX Safetensors (`mlx_lm.server`), Google AI Edge LiteRT `.tflite` (`litert-lm` / `litert-benchmark`), and Kokoro RS / ONNX audio TTS (`kokoro-server`).
- **Zero-Copy Unified Memory Protection**: Leverages native Apple Silicon hardware telemetry (`vm_stat`, `mach_host_basic_info`) to compute a real-time **Predictive Fit Score** before loading models, preventing system freezes and swap thrashing.
- **Kernel Memory Hooks**: Registers macOS kernel memory pressure event sources (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`) to proactively drain or unload idle runners before operating system swap thrashing occurs.
- **Transparent API Gateway**: Embeds a reverse proxy on port `4891` (`http://127.0.0.1:4891/v1`) that dynamically routes requests, auto-wakes stopped model runners on demand, and supports live port rebinding.
- **Hardware Auto-Tuning**: Automatically applies optimal Apple Silicon execution flags (`-ngl 99` Metal offload, `--flash-attn on`, dynamic context sizing) tailored to your specific M-series chip tier.

### What LocalMgr Explicitly Does NOT Solve (Non-Goals)
- **Not a Cloud Hosting Service**: LocalMgr operates 100% locally on your machine; it does not host endpoints in the cloud, proxy external cloud LLM APIs, or manage remote cloud compute instances.
- **Not a Cluster Orchestrator**: It is designed for single-host Apple Silicon workstations and laptops, not multi-node distributed Kubernetes or Slurm clusters.
- **Not a Web UI Chat Wrapper**: It is a developer-focused infrastructure manager, model catalog, and API gateway—not a web-based chat interface or chatbot frontend like OpenWebUI or LibreChat.
- **Not an Opaque Model Silo**: It does **not** duplicate, copy, or re-download model weight blobs into proprietary or hidden black-box directories. It respects your existing model storage structure via a zero-copy Bring Your Own Folder (BYOF) architecture.

---

## Prerequisites & Environment

Before building or running LocalMgr, ensure your system meets the minimum runtime and compilation requirements:

### Minimum System & Build Requirements
- **Operating System**: macOS 14.0 (Sonoma) or newer.
- **Hardware architecture**: Apple Silicon (M1, M2, M3, M4 series recommended for native Metal unified memory sharing).
- **Compiler Toolchain**: Swift 6.0+ and Xcode 16.0+ command-line tools (`xcode-select --install`).

### Required Execution Engines (CLI Tools)
LocalMgr automatically scans system PATHs (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, and `~/.local/share/uv/tools/*/bin`) as well as the fallback directory `~/Library/Application Support/LocalMgr/Engines/`. We recommend installing backend CLI engines via **Astral `uv`** and Homebrew:

```bash
# 1. GGUF execution engine (llama.cpp)
brew install llama.cpp

# 2. Apple Silicon native MLX engine (.safetensors)
uv tool install mlx-lm

# 3. Hugging Face Hub CLI integration (for model discovery & background downloads)
uv tool install huggingface_hub

# 4. Google AI Edge LiteRT engine (.tflite / .task)
uv tool install ai-edge-litert
```

> **Note on Kokoro TTS**: For audio generation, place the compiled `kokoro-server` binary into your `$PATH` or directly into `~/Library/Application Support/LocalMgr/Engines/`.

---

## Quick Installation

Build, bundle, and install the native macOS application with a single command sequence from the project root:

```bash
make app && make install && make run
```

### What this does:
1. **`make app`**: Compiles release binaries with Swift 6 strict concurrency (`.build/release/LocalMgr`), bundles resource assets and AppIcon artwork into `LocalMgr.app`, and flushes the macOS LaunchServices icon cache.
2. **`make install`**: Copies the compiled bundle to `/Applications/LocalMgr.app`.
3. **`make run`**: Launches the native GUI application.

---

## Usage Guide

### Send completions through the API Gateway
LocalMgr runs an OpenAI-compatible reverse proxy listening on port `4891` by default. Point your developer tools, scripts, or IDEs (Cursor, VS Code, Xcode) to `http://127.0.0.1:4891/v1`. If the target model runner is idle or stopped, the gateway automatically boots the engine into memory before serving completion tokens:

```bash
curl http://127.0.0.1:4891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-E2B-it-Q4_K_M",
    "messages": [
      {"role": "system", "content": "You are a concise coding assistant."},
      {"role": "user", "content": "Explain Apple Silicon unified memory in one sentence."}
    ],
    "max_tokens": 128
  }'
```

### Scrape live Prometheus metrics and JSON stats
LocalMgr records continuous runtime telemetry—including token volume, generation speed (`tok/s`), Time-to-First-Token (`TTFT`), KV cache hit rates, and thermal state—stored in append-only JSONL format at `~/Library/Application Support/LocalMgr/Telemetry/history.jsonl`. Scrape live observability endpoints directly from the gateway:

```bash
# 1. Scrape Prometheus text exposition metrics
curl http://127.0.0.1:4891/metrics

# 2. Query structured JSON live statistics and active runner status
curl http://127.0.0.1:4891/v1/stats

# 3. Inspect registered models available to the gateway
curl http://127.0.0.1:4891/v1/models
```

### Attach an external model vault (BYOF)
LocalMgr adheres strictly to a **Bring Your Own Folder (BYOF)** design:
- Open **Preferences** (`Cmd+,`) or click **Attach Vault** in the sidebar.
- Select your existing model directories (e.g., external NVMe drives, `~/Models/GGUF`, or local Hugging Face cache folders).
- LocalMgr uses macOS Security-Scoped Bookmarks to maintain persistent read/write access without moving, copying, or duplicating multi-gigabyte weight files.

### Discover and download models from Hugging Face Hub
Use the built-in **Hub Discovery** panel (`Cmd+Shift+H`) or paste Hugging Face repository URLs directly:
- Filter models by format badge (`GGUF`, `MLX`, `LiteRT`, `ONNX`).
- View real-time **RAM Fit Warnings** before initiating downloads.
- Downloads run as resilient background transfers with streaming SHA-256 hash verification via `CryptoKit`, saving by default to `~/Library/Application Support/LocalMgr/Models/` or your active external vault bookmark.

### Monitor Apple Silicon thermal rating and unified memory
Open the **Ops Dashboard** (`Cmd+Shift+O`) or inspect the sidebar telemetry header:
- Track real-time memory allocations across **Wired**, **Active**, and **Free** unified RAM pools.
- Inspect GGUF binary headers for precise tensor dimensions and dynamic KV cache memory pressure estimates.
- Rely on automated kernel hooks that evict idle model runners when system memory pressure reaches warning thresholds.

---

## Documentation

For deep dives into internal design decisions, routing architectures, and user workflows, explore the project documentation:
- [User & Persona Guide](docs/USER_GUIDE.md): Practical step-by-step walkthroughs, reasoning model cURL recipes, and persona tutorials.
- [Architecture & UX Blueprint](docs/ARCHITECTURE_PLAN.md): Multi-backend engine orchestration, subprocess lifecycle management, and system diagrams.
- [Core User Journeys (CUJs) & Diátaxis Mapping](docs/USER_JOURNEYS.md): End-to-end developer workflows and issue tracker alignment.
- [RFC 001: Envoy AI Gateway Hybrid Cloud Federation](docs/RFC_001_ENVOY_AI_GATEWAY_HYBRID_FEDERATION.md): Blueprint for federating local execution engines with Envoy proxies.
- [Changelog](CHANGELOG.md): Keep a Changelog compliant release history and versioning protocol.

---

## How to Contribute

We welcome contributions! To ensure high reliability across macOS environments, please follow our development workflow:

1. **Verify Your Environment**: Ensure Xcode 16+ and Swift 6 are installed. Verify builds pass locally using `make app`.
2. **Issue Tracking with Beads (`bd`)**: This project uses **bd (beads)** for decentralized issue tracking:
   - Check unblocked tasks: `bd ready`
   - Create a new issue before starting work: `bd create "Feature or Bug Title" --type task --priority 2`
   - Close completed issues: `bd close <id>`
   - Review full workflow context: `bd prime`
3. **Strict Concurrency**: All Swift code must compile under Swift 6 strict concurrency (`-strict-concurrency=complete`). When interfacing with non-isolated system APIs or network listeners (`NWListener`), ensure UI state updates are explicitly dispatched via `@MainActor`.
4. **Submitting Changes**: Ensure tests pass, format code cleanly, and submit a pull request referencing the relevant bead issue ID.

---

## License

This project is licensed under the **Apache License, Version 2.0**. See the [LICENSE](LICENSE) file for full legal terms and distribution conditions.

---

## Disclaimer

This is not an officially supported Google product. This project is not eligible for the [Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).
