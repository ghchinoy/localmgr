# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Common Changelog](https://common-changelog.org/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-07-03

_Minor release (Build 5) delivering persistent telemetry history, enterprise Ops monitoring dashboard, automated benchmark harness, and make install target._

### Added
- **Persistent Telemetry Store:** record proxy completion events to `~/Library/Application Support/LocalMgr/Telemetry/history.jsonl` surviving application restarts (`[localmgr-uej]`).
- **Enterprise Ops Monitoring Dashboard:** add interactive `OpsDashboardView` (`Cmd+Shift+O`) aggregating lifetime requests, token volumes, average TTFT, generation speed (`tok/s`), and KV cache hit rate percentages per model (`[localmgr-uej]`, `[localmgr-khk.3]`).
- **One-Click Benchmark Matrix:** provide in-dashboard evaluation harness firing standardized prompts against active runners and appending baseline telemetry directly into persistent history (`[localmgr-khk.4]`).
- **Apple Silicon Thermal Correlation:** track and display live kernel thermal states (`ProcessInfo.processInfo.thermalState`) inside metrics records and dashboard headers (`[localmgr-khk.2]`).
- **Makefile Install Target:** add `make install` target copying compiled bundles cleanly into `/Applications/LocalMgr.app`.

## [0.3.0] - 2026-07-03

_Minor release (Build 4) delivering Phase 1 observability foundation, Prometheus metrics, structured telemetry, and routing conflict guardrails._

### Added
- **Prometheus Exposition Endpoint:** serve `GET /metrics` formatted with standardized Envoy AI Gateway stat names (`ai_gateway_llm_requests_total`, `ai_gateway_llm_token_usage_total`, `ai_gateway_llm_upstream_health_status`) as outlined in RFC 001 (`[localmgr-khk.6]`).
- **Structured JSON Telemetry:** expose `GET /v1/stats` and `/health` reporting live uptime, listening ports, request counters, token throughput, TTFT, and TPS generation speeds (`[localmgr-khk.6]`).
- **Active Model Catalog Marker:** inject `"active": true` into `GET /v1/models` responses for whichever engine is currently active on the gateway (`[localmgr-khk.5]`).
- **Live Speedometer & Timing Telemetry:** track Time-to-First-Token (TTFT) and Tokens Per Second (`tok/s`) across proxy streams, displaying a real-time speedometer inside the UI Gateway card (`[localmgr-khk.1]`).
- **Inference Routing Guardrails:** return explicit HTTP `409 Conflict` payloads when an external client requests a different model while an engine runner is actively hosting a session, preventing unexpected VRAM swap thrashing (`[localmgr-khk.1]`).

## [0.2.0] - 2026-07-03

_Minor release (Build 3) delivering catalog refresh controls, clean session log resets, app exit runner auto-termination, and API gateway documentation._

### Added
- **Catalog Refresh Controls:** add manual refresh buttons in sidebar header and model list bar, accompanied by global `Cmd+Shift+R` keyboard shortcut to instantly re-scan external BYOF vaults without restarting (`[localmgr-yxi]`).
- **Expanded LiteRT Discovery:** recognize `.tfl`, `.tflite`, `.task`, and `.litert` file extensions across bookmarked vaults (`[localmgr-yxi]`).
- **Graceful Subprocess Auto-Termination:** hook into `applicationWillTerminate(_:)` to automatically terminate background runner processes when `LocalMgr` quits, configurable via a toggle switch in Preferences (`[localmgr-yxi]`).
- **Gateway cURL Documentation:** add practical copy-pasteable reverse proxy `curl` example to `README.md` (`[localmgr-yxi]`).
- **Manual Log & Output Clearing:** add trash icon action buttons inside Live Logs and Quick Test Ping tabs for on-demand output clearing (`[localmgr-yxi]`).

### Changed
- **Pristine Session Start:** automatically reset live terminal log output and test ping responses whenever a new runner session is initiated via `startModel(_:)`, preventing old logs from cluttering active runs (`[localmgr-yxi]`).

## [0.1.1] - 2026-07-03

_Patch release (Build 2) introducing reasoning content support for thinking models._

### Added
- **Reasoning Model Verification:** parse `"reasoning_content"` inside OpenAI-compatible `/v1/chat/completions` response payloads so thinking models (e.g. Gemma 4 reasoning variants, DeepSeek-R1) display their chain-of-thought clearly above final answers in the Quick Test Ping tab (`[localmgr-kdg]`).

### Changed
- **Verification Token Budget:** increase Quick Test Ping generation allowance from `64` to `256` tokens (`max_tokens: 256`) to give reasoning models sufficient token runway to complete their thinking process before hitting truncation limits.

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

[Unreleased]: https://github.com/ghchinoy/localmgr/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/ghchinoy/localmgr/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ghchinoy/localmgr/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ghchinoy/localmgr/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/ghchinoy/localmgr/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ghchinoy/localmgr/releases/tag/v0.1.0
