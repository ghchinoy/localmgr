# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Common Changelog](https://common-changelog.org/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-03

_Initial alpha release (Build 1)._

### Added
- **Bring Your Own Folder (BYOF):** attach arbitrary local directories (`~/Models/GGUF`, Hugging Face cache) via macOS Security-Scoped Bookmarks without copying or duplicating weights (`[localmgr-r3p.2]`).
- **Multi-Engine Execution Layer:** native orchestration subprocess support for `llama.cpp` (`llama-server`), Apple `MLX` (`mlx_lm.server`), Google AI Edge `LiteRT` (`litert-benchmark`), and `Kokoro` audio TTS (`[localmgr-r3p.4]`, `[localmgr-odf.1]`).
- **Precise Memory & KV Cache Footprint:** scan 128KB GGUF binary headers for exact layer and head dimensions to calculate static weights and dynamic KV cache memory pressure before launching inference (`[localmgr-odf.2]`).
- **Unified Local API Gateway:** reverse proxy listening on port `4891` that routes OpenAI-compatible requests (`/v1/chat/completions`) with on-demand model warm-up and live Combine socket rebinding (`[localmgr-6vw]`, `[localmgr-xl7]`).
- **Apple Silicon Hardware Auto-Tuning:** detect exact M1/M2/M3/M4 chip tier via `sysctlbyname("hw.model")` and RAM capacity to automatically inject `-ngl 99`, `--flash-attn on`, and safe context caps on launch (`[localmgr-oi3]`).
- **In-App Quick Test Ping:** interactive 64-token verification prompt tab inside the model inspector backed by main-actor state persistence for guaranteed UI response rendering (`[localmgr-kdg]`).
- **Hugging Face Hub Discovery & Downloader:** modal sheet supporting keyword search and direct repository URL paste, format filter pills, pre-download RAM fit badges (`🟢 Fits Comfortably` vs `🔴 Exceeds RAM`), and persistent background transfers with streaming SHA-256 validation (`[localmgr-wja]`).
- **Preferences & Emergency Safety Nets:** native macOS Settings window (`Cmd+,`) allowing auto-tuning opt-out, custom download directory overrides, idle VRAM TTL unload timers, and kernel memory pressure hooks (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`) (`[localmgr-9jg]`, `[localmgr-wzu]`).
- **macOS HIG Compliance & Dock Integration:** custom 3D neural brain app icon (`AppIcon.icns`), global `Models` menu bar items, contextual Dock menu actions (`Start Last Model`, `Stop Active Runner`), auto-focused search fields, and execution keyboard shortcuts (`Cmd+R`, `Cmd+.`) (`[localmgr-05w]`).

### Fixed
- **Flash Attention Syntax:** pass explicit `on` value to `--flash-attn` when launching `llama-server` to prevent option parsing failures.
- **Process Crash Recovery:** attach process `terminationHandler` to catch startup failures and preserve live terminal output (`lastRunModelID`) pinned on screen indefinitely after termination.
- **Astral `uv` Tool Resolution:** probe `~/.local/bin/`, `~/.cargo/bin/`, and `~/.local/share/uv/tools/` for engine binaries and recognize `litert-benchmark` as an alias for LiteRT execution.

[Unreleased]: https://github.com/ghchinoy/localmgr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ghchinoy/localmgr/releases/tag/v0.1.0
