# GEMINI.md

## Project Overview
**LocalMgr** is a standalone macOS application built with Swift 6 and SwiftUI, designed to manage and orchestrate local AI models (GGUF, MLX Safetensors, Google LiteRT `.tflite`, Kokoro RS) and execution engines (`llama-server`, `mlx_lm.server`, `litert-lm`).

## Architecture & Tech Stack
- **Language**: Swift 6 (Strict Concurrency)
- **UI Framework**: SwiftUI (macOS 14+)
- **Build & Packaging**: Swift Package Manager (`Package.swift`) + `Makefile` for macOS `.app` bundling (`LocalMgr.app`)

### Supported Engines & Binaries
- **`llama-server`**: GGUF LLMs, dynamic port allocation, `-ngl 99` Metal offload, Flash Attention.
- **`mlx_lm.server`**: MLX Safetensors, native Apple Silicon zero-copy unified memory sharing.
- **`litert-lm` / `litert-benchmark`**: Google AI Edge LiteRT (`.tflite` / `.task`) Metal backend execution.
- **`kokoro-server`**: High-speed local ONNX / Rust Text-to-Speech (TTS).
- **Resolution Policy & Astral `uv` Preference**:
  - The user prefers **Astral `uv`** (`uv tool install <pkg>`) over global `pip`.
  - Binaries are probed across `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `~/.local/bin/`, `~/.cargo/bin/`, and `~/.local/share/uv/tools/*/bin/`, with automatic fallback to `~/Library/Application Support/LocalMgr/Engines/`.
  - Account for binary aliases: for LiteRT, probe for both `litert-lm` and `litert-benchmark`.

### Key Services & Gateways
- `ModelCatalogService`: Manages local folders via Security-Scoped Bookmarks and inspects `.gguf`, `.tflite`, and MLX headers.
- `SystemMonitorService`: Real-time telemetry for Apple Silicon Wired/Active RAM, kernel memory pressure hooks (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`), and Predictive Fit Scores.
- `BackendRunnerManager`: Subprocess orchestrator managing lifecycle, idle VRAM reclaiming, and hardware auto-tuning.
- `LocalAPIGateway`: Built-in reverse proxy on port `4891` (`NWListener`) routing OpenAI-compatible requests (`/v1/chat/completions`) with on-demand model warm-up.
- `EngineReadinessService`: Scans installation environments and populates UI readiness badges (`🟢 Ready` vs. `🔴 Missing Engine`).
- `HubDownloaderService`: Curated Hugging Face Hub downloader with streaming SHA-256 hash checks via `CryptoKit`.

## Coding & Architectural Best Practices

### Swift 6 Strict Concurrency & Networking
- **Nonisolated Networking**: When implementing `Network.framework` (`NWListener` / `NWConnection`) callbacks inside a `@MainActor` class, always mark connection handlers and response emitters as `nonisolated`. Dispatch UI and state mutations back to the main thread via `Task { @MainActor in ... }` or `await MainActor.run`.
- **Thread-Safe Darwin Queries**: Use thread-safe POSIX functions (such as `getpagesize()`) rather than non-concurrency-safe global C variables when querying system page dimensions or host properties.

### Settings & Live Combine Rebinding
- **`@Published` vs. `@AppStorage`**: When a setting requires live Combine publisher subscriptions (such as dynamically rebinding network listening ports on the fly without restarting the application), declare the property as `@Published` backed by `UserDefaults.standard` inside `didSet`, rather than `@AppStorage` (which projects a `Binding<Value>` instead of a Combine `Publisher`).

### App Icon & Asset Bundling
- **Icon Generation (`sips` + `iconutil`)**: To convert PNG artwork into `AppIcon.icns`, generate `AppIcon.iconset` sizes (`16x16` through `512x512@2x`) using `sips` and compile with `iconutil -c icns`. Ensure `CFBundleIconFile` is declared in `Info.plist` and run `touch LocalMgr.app` after bundling.
- **Resource Path Resolution**: When loading image resources in SwiftUI from an SPM app bundle, resolve paths using `Bundle.main.path(forResource:ofType:) ?? Bundle.main.bundlePath.appending("/Contents/Resources/<file>")`.

### AppKit Integration & Swift 6 Concurrency
- **`@MainActor` Application Delegates**: When bridging AppKit delegates (`NSApplicationDelegate` via `@NSApplicationDelegateAdaptor`) to handle Dock menus or quit events (`applicationWillTerminate`), always annotate the class with `@MainActor` and ensure both `import Cocoa` and `import SwiftUI` are present at the top of the file to prevent Swift 6 isolation data races.

### Reasoning Model Completion Parsing
- **`reasoning_content` Extraction**: When parsing OpenAI-compatible chat completions (`/v1/chat/completions`) in verification tools or client wrappers, always check for and extract `choices[0].message.reasoning_content` alongside `content`. Ensure verification prompts allocate a sufficient token budget (`max_tokens >= 256`) so thinking models (e.g., Gemma 4, DeepSeek-R1) do not hit truncation limits before emitting their final answer.

### Subprocess Lifecycle & App Exit Protection
- **Orphan Prevention**: Subprocesses spawned via `Process` (`NSTask`) survive parent GUI termination by default. Always maintain a hook in `AppDelegate.applicationWillTerminate(_:)` that invokes `runnerManager.stopCurrent()` (controlled via an explicit user setting in `AppSettings`) so lingering engine servers (`llama-server`, `mlx_lm.server`) never orphan local network sockets.

### Inference Routing Guardrails
- **Fast-Fail on Active Conflicts**: When implementing local reverse proxies over single-model engines (`llama-server`, `mlx_lm.server`), never auto-swap models if another runner session is actively running. If an incoming API request (`/v1/chat/completions`) specifies a model that differs from the currently active runner, return an explicit HTTP `409 Conflict` (unless requested as `"default"` or `"local"`) to protect active developer sessions and prevent VRAM swap thrashing.

### Telemetry Persistence & KV Cache Accounting
- **Append-Only JSONL Storage**: When persisting continuous inference telemetry (`history.jsonl`) from high-frequency HTTP proxy streams, use append-only file operations (`FileHandle.seekToEndOfFile()`) rather than re-encoding entire historical arrays on `@MainActor` to prevent UI frame drops during high tokens-per-second generation.
- **Prefix Cache Hit Rate**: When parsing `usage` from OpenAI-compatible local engines (`llama-server`), check for `prompt_tokens_details.cached_tokens`. Calculate prefix optimization as `cached_tokens / prompt_tokens` to provide developers with real-time insight into prompt reuse efficiency.

### Reverse Proxy Networking & Timeouts
- **Long-Duration Inference Timeouts**: When implementing local HTTP reverse proxies or gateways (`LocalAPIGateway`) in Swift that route LLM completions (`/v1/chat/completions`), never use `URLSession.shared` (which enforces a strict 60-second request timeout). Always configure a dedicated `URLSession` and `URLRequest.timeoutInterval` of at least 30 minutes (`1800.0s`) so large token generations (`max_tokens >= 2048`) do not drop mid-stream.

### Hugging Face Hub API Integration
- **Recursive Tree & Credential Injection**: When querying repository file trees via `https://huggingface.co/api/models/<repo>/tree/main`, always pass `?recursive=true` so weight files nested in subdirectories (`gguf/`, `model/`) are discovered. Always probe `~/.cache/huggingface/token` and `ProcessInfo.processInfo.environment["HF_TOKEN"]` to attach `Authorization: Bearer <token>` for gated repository access.

## Build & Run Commands
- Compile release build: `make build` or `swift build -c release`
- Bundle macOS App: `make app`
- Run Application: `make run` or `open LocalMgr.app`

## Release Management & Versioning Protocol

When preparing a release, patch bump, or milestone completion, agents must execute the following synchronized release checklist:

1. **plist & Build Number Synchronization**:
   - Update `CFBundleShortVersionString` (semantic version, e.g., `0.1.1`) and increment `CFBundleVersion` (monotonically increasing integer build number, e.g., `2`) in `Info.plist`.
2. **UI Version Parity**:
   - Verify and update all user-facing version strings across the application (specifically the header subtitle in `SidebarView.swift`, e.g., `v0.1.1 • macOS Apple Silicon`).
3. **Curated Changelog Protocol (`CHANGELOG.md`)**:
   - Adhere strictly to **Keep a Changelog v1.1.0** and **Common Changelog** standards.
   - Transition completed items from `## [Unreleased]` into a new version block: `## [X.Y.Z] - YYYY-MM-DD` with an italicized notice (e.g., `_Patch release (Build 2)..._`).
   - Group entries into standard categories (`Added`, `Changed`, `Fixed`) with bold impact prefixes and issue IDs (`[localmgr-...]`).
   - Update bottom comparison reference links (`[Unreleased]: ...compare/vX.Y.Z...HEAD` and `[X.Y.Z]: ...compare/vOLD...vX.Y.Z`).
4. **Annotated Git Tagging**:
   - Compile the app (`make app`) and commit the release preparation commit (e.g., `release(v0.1.1): bump patch version...`).
   - Create an annotated git tag immediately following the commit: `git tag -a vX.Y.Z -m "Release vX.Y.Z (Build N)"`.
5. **Documentation Audit & Synchronization Protocol**:
   - At the conclusion of a feature sprint or milestone release, agents must verify that architectural blueprints and user-facing docs reflect implemented code. To conserve context and ensure thoroughness, **delegate this audit to a subagent (`self` or `research`)** executing a 4-point sweep:
     1. **`README.md` Parity**: Verify all new user-facing HTTP endpoints (`/metrics`, `/v1/stats`), CLI commands, and installation steps (`make install`) are documented with concrete examples.
     2. **`USER_JOURNEYS.md` Promotion**: Move completed features from `## Future Roadmap Journeys` up into `## Implemented Core User Journeys`, updating mapped `bd` issue IDs and status badges (`● Completed / Closed`).
     3. **`ARCHITECTURE_PLAN.md` Alignment**: Register new storage directories (`history.jsonl`), Swift actors/services (`TelemetryStore`), and gateway routing rules inside the architecture breakdown. Ensure all media links (e.g., `architecture.webp`) use valid relative paths inside `docs/`.
     4. **Issue Tracker Parity**: Ensure all completed tasks and epics are closed in `beads` (`bd close <id>`) prior to tagging the release.

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.
