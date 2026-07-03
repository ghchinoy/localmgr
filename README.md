# LocalMgr

**LocalMgr** is a standalone, native macOS application built with Swift 6 and SwiftUI, designed to orchestrate and manage local AI models (GGUF, MLX Safetensors, Kokoro RS) and execution engines (`llama-server`, `mlx_lm.server`).

## Features

- **Bring Your Own Folder (BYOF)**: Attach existing external model directories (`~/Models/GGUF`, Hugging Face cache) via macOS Security-Scoped Bookmarks without copying or duplicating weights.
- **Apple Silicon Hardware Telemetry**: Real-time monitoring of Wired, Active, and Free Unified Memory (`vm_stat`, `mach_host_basic_info`) with a **Predictive Fit Gauge** that warns before loading models that cause swap thrashing.
- **Engine Readiness Scanner**: Automatically probes system PATHs, Homebrew, conda, and Application Support to detect installed execution binaries and displays clear `🟢 Ready` vs. `🔴 Missing Engine` badges.
- **Precise KV Cache Footprint**: Inspects GGUF binary headers for exact tensor and layer dimensions to compute combined static weight and dynamic KV cache memory pressure across context lengths.
- **Unified Local API Gateway**: Built-in HTTP gateway (`http://127.0.0.1:4891/v1`) that transparently reverse-proxies OpenAI-compatible requests to whichever backend engine is active, with on-demand model warm-up.

## Getting Started

### Requirements
- macOS 14.0+ (Apple Silicon recommended)
- Swift 6.0 toolchain / Xcode 16+

### Build & Run
Compile and bundle the native macOS application:
```bash
make app
make run
```
Or open `LocalMgr.app` directly from Finder.

## Documentation
- [Architecture & UX Blueprint](docs/ARCHITECTURE_PLAN.md)
- [Core User Journeys (CUJs) & Diátaxis Mapping](docs/USER_JOURNEYS.md)

## Issue Tracking
This project uses **bd (beads)** for multi-agent issue tracking:
```bash
bd prime
bd list
```
