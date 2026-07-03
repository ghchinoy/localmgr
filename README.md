# LocalMgr

**LocalMgr** is a standalone, native macOS application built with Swift 6 and SwiftUI, designed to orchestrate and manage local AI models (GGUF, MLX Safetensors, Google LiteRT `.tflite`, Kokoro RS) and execution engines (`llama-server`, `mlx_lm.server`, `litert-lm`).

## Features

- **Bring Your Own Folder (BYOF)**: Attach existing external model directories (`~/Models/GGUF`, Hugging Face cache) via macOS Security-Scoped Bookmarks without copying or duplicating weights.
- **Apple Silicon Hardware Telemetry**: Real-time monitoring of Wired, Active, and Free Unified Memory (`vm_stat`, `mach_host_basic_info`) with a **Predictive Fit Gauge** that warns before loading models that cause swap thrashing.
- **Engine Readiness Scanner**: Automatically probes system PATHs, Homebrew, conda, and Astral `uv` environments (`~/.local/bin`, `~/.local/share/uv/tools/`) to detect installed execution binaries with clear `🟢 Ready` vs. `🔴 Missing Engine` badges.
- **Multi-Engine Execution**: First-class support for `llama.cpp` (GGUF), Apple `MLX` (.safetensors), Google `LiteRT-LM` (.tflite / AI Edge), and `Kokoro` audio TTS.
- **Precise KV Cache Footprint**: Inspects GGUF binary headers for exact tensor and layer dimensions to compute combined static weight and dynamic KV cache memory pressure across context lengths.
- **Unified Local API Gateway**: Built-in HTTP gateway (`http://127.0.0.1:4891/v1`) that transparently reverse-proxies OpenAI-compatible requests to whichever backend engine is active, with on-demand model warm-up and live port rebinding.
- **Hardware Auto-Tuning & In-App Quick Ping**: Automatically configures optimal Apple Silicon flags (`-ngl 99`, `--flash-attn on`, context caps) per chip tier, and includes an interactive 256-token verification ping tab in the inspector.
- **Hugging Face Hub Discovery & Background Downloader**: Dedicated discovery panel supporting keyword searches and direct URL pastes, format filters, pre-download RAM fit warnings, and persistent background transfers with SHA-256 verification.
- **Native Preferences & Safety Nets**: Configurable Settings window (`Cmd+,`) allowing auto-tuning opt-out, custom download folder overrides, idle VRAM TTL unload timers, auto-terminating engines on app exit, and macOS kernel memory pressure hooks (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`) to drain active runners before swap thrashing occurs.

## Unified Local API Gateway (`curl` Example)

LocalMgr includes an OpenAI-compatible reverse proxy listening on port `4891` by default. Point your IDEs (Cursor, Xcode, VS Code) or shell scripts directly to `http://127.0.0.1:4891/v1`. If a model is active, the gateway proxies requests instantly; if stopped, it automatically wakes up the engine before serving completion tokens:

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

## Enterprise Observability & Telemetry (`curl` Examples)

LocalMgr includes standardized, persistent observability endpoints built directly into the reverse proxy (`LocalAPIGateway`). Telemetry records (including token volume, generation speed `tok/s`, Time-to-First-Token `TTFT`, KV cache hit rates, and kernel thermal states) are stored continuously in `~/Library/Application Support/LocalMgr/Telemetry/history.jsonl` and can be inspected via the interactive **Ops Dashboard** (`Cmd+Shift+O`) or programmatically:

```bash
# 1. Scrape Prometheus text exposition metrics (/metrics)
curl http://127.0.0.1:4891/metrics

# 2. Query structured JSON live statistics and active runner state (/v1/stats or /health)
curl http://127.0.0.1:4891/v1/stats
```

## Model Storage & Vaults

LocalMgr operates on a **Bring Your Own Folder (BYOF)** architecture:
- **Default Download Storage**: By default, models downloaded via Hugging Face Hub are saved to `~/Library/Application Support/LocalMgr/Models/`. You can change this default storage destination at any time in Preferences (`Cmd+,`).
- **External Vault Bookmarks**: You can attach multiple existing model directories (such as external NVMe SSDs or existing `~/Models` folders) via macOS Security-Scoped Bookmarks, and select any bookmarked folder as the destination for new downloads.

## Requirements & Tool Installation (TL;DR)

LocalMgr discovers models and manages background engine subprocesses. To run specific model formats, install the required command-line engines using Astral `uv` (recommended), Homebrew, or pip:

```bash
# 1. For GGUF models (llama-server)
brew install llama.cpp

# 2. For Apple Silicon native MLX models (.safetensors)
uv tool install mlx-lm
# Or: pip install mlx-lm

# 3. For Hugging Face Hub CLI integration
uv tool install huggingface_hub
# Or: pip install huggingface_hub[cli]

# 4. For Google AI Edge LiteRT models (.tflite / litert-benchmark)
uv tool install ai-edge-litert
# Or: pip install ai-edge-litert
```

> **Tip**: If an engine binary isn't in your standard system `$PATH`, you can also place compiled binaries directly into `~/Library/Application Support/LocalMgr/Engines/`.

## Getting Started

### Requirements
- macOS 14.0+ (Apple Silicon recommended)
- Swift 6.0 toolchain / Xcode 16+

### Build & Run
Compile, bundle, and install the native macOS application:
```bash
make app
make install
make run
```
Or open `/Applications/LocalMgr.app` directly from Finder.

## Documentation
- [Architecture & UX Blueprint](docs/ARCHITECTURE_PLAN.md)
- [Core User Journeys (CUJs) & Diátaxis Mapping](docs/USER_JOURNEYS.md)
- [RFC 001: Envoy AI Gateway Hybrid Cloud Federation](docs/RFC_001_ENVOY_AI_GATEWAY_HYBRID_FEDERATION.md)

## Disclaimer

This is not an officially supported Google product. This project is not
eligible for the [Google Open Source Software Vulnerability Rewards
Program](https://bughunters.google.com/open-source-security).