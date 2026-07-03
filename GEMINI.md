# GEMINI.md

## Project Overview
**LocalMgr** is a standalone macOS application built with Swift 6 and SwiftUI, designed to manage and orchestrate local AI models (GGUF, MLX, Kokoro RS) and execution engines (`llama-server`, `mlx_lm.server`).

## Architecture & Tech Stack
- **Language**: Swift 6
- **UI Framework**: SwiftUI (macOS 14+)
- **Build & Packaging**: Swift Package Manager (`Package.swift`) + `Makefile` for macOS `.app` bundling (`LocalMgr.app`)
- **Key Services**:
  - `ModelCatalogService`: Manages local folders via Security-Scoped Bookmarks and inspects `.gguf` / MLX headers.
  - `SystemMonitorService`: Real-time telemetry for Apple Silicon Unified Memory and Metal working set allocations.
  - `BackendRunnerManager`: Subprocess orchestrator for local inference engines.

## Build & Run Commands
- Compile release build: `make build` or `swift build -c release`
- Bundle macOS App: `make app`
- Run Application: `make run` or `open LocalMgr.app`

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.
