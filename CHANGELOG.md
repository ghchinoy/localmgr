# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Common Changelog](https://common-changelog.org/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.3] - 2026-07-19

_Patch release (Build 14) fixing MemoryPressureGuard killing a runner mid-generation on any request longer than 3 seconds._

### Fixed
- **Memory Pressure Guard Killed Long-Running Requests:** `BackendRunnerManager.recentlyActive` was a rolling-timestamp heuristic (`recordActivity()` called once when a request arrived, valid for a hardcoded 3-second window) rather than a true in-flight flag. Any single gateway request whose upstream processing exceeded 3 seconds — trivially the case for large-context, tool-heavy coding-agent prompts (OpenCode, Claude Code, etc.) — was incorrectly treated as "idle" by `MemoryPressureGuard`'s warning-level `stopIfIdle` check, so a WARNING-level memory pressure event during that window would silently kill the runner process mid-generation, with the client receiving no error and no answer. `BackendRunnerManager` now tracks an explicit `inFlightRequestCount` via `beginRequest()`/`endRequest()`, incremented for the full duration of every gateway chat-completion request (streaming and non-streaming) and Quick Test Ping, so `recentlyActive` reflects true in-flight state regardless of how long a request takes (`[localmgr-mtz]`).
- **Verified live:** reproduced the fix's effect with a real ~29,000-token request (matching the magnitude of the original failure) taking ~35 seconds end-to-end — confirmed via a temporary debug probe that the runner's in-flight flag stayed `true` continuously for the entire duration and only cleared immediately after completion, closing the ~31-second window in which the old 3-second heuristic would have incorrectly reported the runner as idle. Confirmed no regression to small requests, streaming, GET endpoints, or the existing `MemoryPressureGuard.warningDeferWindow` (60s) backstop that intentionally still allows a deferred WARNING-level eviction to proceed even mid-request after a bounded wait.

## [0.7.2] - 2026-07-19

_Patch release (Build 13) fixing a request-body truncation bug that broke every request from tool-heavy coding-agent clients like OpenCode._

### Fixed
- **Gateway Truncated Request Bodies Over 64KB:** `LocalAPIGateway.handleConnection()` read exactly one `NWConnection.receive` chunk (capped at 64KB) and treated it as the complete HTTP request, with no loop to keep reading until the full `Content-Length` body arrived. Any POST body larger than ~64KB was silently truncated mid-JSON-string before being forwarded upstream, which llama-server/mlx_lm.server then rejected with a raw parser error (`json.exception.parse_error.101 ... missing closing quote`) surfaced straight to the client. Discovered via a real OpenCode session: OpenCode's `@ai-sdk/openai-compatible` provider serializes the full MCP tool schema (name/description/parameters for every registered MCP server — Veo, Gemini, nanobanana, avtool, Stitch, etc.) into every chat completion request, routinely exceeding 64KB and hitting this bug on effectively every request. The connection handler now accumulates reads in a loop against the parsed `Content-Length` header until the full body has arrived (or the peer closes), with a 25MB hard cap enforced via a new `413 gateway-request-too-large` `LocalMgrError` rather than an unbounded read (`[localmgr-ae9]`).
- **Verified live:** reproduced the exact truncation (~65KB boundary, identical `missing closing quote` error) with a synthetic 78862-byte payload before the fix; confirmed the same payload is now received intact after the fix (llama-server correctly computed 16236 prompt tokens from the full body and returned its own `exceed_context_size_error`, proving no truncation occurred). Confirmed no regression to small (<64KB) requests, GET endpoints, and the streaming path (`localmgr-al0.1`); confirmed the new 25MB cap correctly returns `413` with AppLog/response message parity.

## [0.7.1] - 2026-07-19

_Patch release (Build 12) adding Server-Sent Events streaming passthrough to the API gateway, unblocking coding-agent clients (OpenCode, etc.) that default to `"stream": true`._

### Fixed
- **Gateway Streaming Passthrough:** `LocalAPIGateway.handleChatCompletions()` previously used `URLSession.data(for:)` for every request, fully buffering the upstream response before replying — a `"stream": true` request from a coding-agent client (OpenCode's `@ai-sdk/openai-compatible` provider, Claude Code, etc.) either hung until generation finished or returned a malformed body. The gateway now detects `"stream": true` and proxies via `URLSession.bytes(for:)`, forwarding upstream SSE `data:` chunks to the client incrementally as they arrive, with `text/event-stream` response headers and a proper `[DONE]` sentinel. Non-streaming requests are unaffected (`[localmgr-al0.1]`).
- **Real Time-to-First-Token for Streaming:** the streaming path now measures actual TTFT from the first non-empty SSE chunk (`ttftMs`), replacing the `durationMs * 0.2` estimate used by the buffered path — `/v1/stats` and `history.jsonl` telemetry now reflect genuine per-request TTFT for streamed completions (`[localmgr-al0.1]`).
- **Verified live** against a real `llama-server` (Gemma 4 GGUF) instance through the actual LocalMgr gateway: confirmed incremental (non-buffered) chunk delivery via timestamped curl, correct `/v1/stats` population (`last_ttft_ms`, `last_tps`, `total_tokens_processed`), no regression to the non-streaming path or the existing 409 model-conflict/503 no-runner error paths, and graceful recovery (log/response parity preserved) when the upstream engine was killed mid-stream.

## [0.7.0] - 2026-07-18

_Minor release (Build 11) adding a per-engine enable/disable toggle: Kokoro TTS and `gemma.cpp` now ship off by default as experimental engines, so machines without them installed no longer show permanent "Missing Engine" noise in the sidebar or Diagnostics view._

### Added
- **Per-Engine Enable/Disable Toggle:** new "Execution Engines" section in Settings → Hardware & Engines lets each engine (llama.cpp, MLX, LiteRT, Kokoro TTS, gemma.cpp) be independently turned on/off, persisted via `AppSettings.isEngineEnabled(_:)` (`@AppStorage` keyed by Swift enum case name, not the display string, so a future label change can't silently reset a saved preference). llama.cpp/MLX/LiteRT default **on**; Kokoro TTS and `gemma.cpp` default **off** as experimental engines — Kokoro has no model-scanning path yet in the catalog, and `gemma.cpp` is tracked pending upstream Gemma 4+ support (`localmgr-e3b`) (`[localmgr-lvb.1]`, `[localmgr-lvb.4]`).
- **Readiness Checks Respect Enablement:** `EngineReadinessService` now omits disabled engines from its readiness checks entirely, instead of showing them as a permanently failing "Missing" check — this directly fixes gemma.cpp/Kokoro cluttering the sidebar's Component Readiness list and the Diagnostics Health Checks section with red status on machines that never installed them (`[localmgr-lvb.2]`, `[localmgr-lvb.3]`).
- **Distinct "Engine Disabled" State:** model readiness badges (model list, inspector) now distinguish "🔴 Missing Engine" (binary genuinely not installed) from "⚪️ Engine Disabled" (turned off in Settings) — previously conflated into one boolean (`[localmgr-lvb.5]`).
- **Enforced at Launch:** `BackendRunnerManager` now refuses to start a model whose engine is disabled, surfacing a structured `LocalMgrError` (`kind: "engine-disabled"`) rather than silently attempting (and failing) a launch (`[localmgr-lvb.6]`).

### Fixed
- **Sidebar Readiness List Bypassed Enablement Gating:** `SidebarView`'s Component Readiness list iterated all engine types directly rather than the gated readiness set, so a disabled engine could still incorrectly render as "Missing" — caught during live testing of this release and fixed before shipping (`[localmgr-lvb.4]`).

## [0.6.0] - 2026-07-18

_Minor release (Build 10) adding proactive memory-pressure protection, structured diagnostics/error reporting, richer hardware detection, and model-compatibility signaling — a set of reliability/UX patterns adapted from a comparative review against MTPLX (github.com/youssofal/MTPLX)._

### Added
- **Memory-Pressure Guard:** new `MemoryPressureGuard` polls `kern.memorystatus_vm_pressure_level` directly and applies edge-triggered hysteresis (act only on the rising edge into WARNING/CRITICAL, ~120s re-arm cooldown, defer WARNING-level action up to 60s if a runner is actively serving a request) instead of the previous unconditional CRITICAL-only reaction. Wired into `SystemMonitorService`, which now asks `BackendRunnerManager` to soft-evict an idle runner on WARNING or hard-evict unconditionally on CRITICAL (`[localmgr-2l5.1]`, `[localmgr-2l5.2]`). Verified live in production during testing: a real WARNING-pressure event correctly soft-evicted an idle `llama-server` runner without touching an active generation.
- **Structured Diagnostic Checks:** new `DiagnosticCheck` type (status/observed/expected/fix/command) is now the uniform result shape for engine-readiness checks. `EngineReadinessService` emits a `[DiagnosticCheck]` per engine instead of ad hoc booleans, and `DiagnosticsView` (`Cmd+Shift+L`) gained a "Health Checks" section with an overall pass/warn/fail rollup, plus a "Copy Diagnostics Bundle" export combining health checks and recent log entries in one pasteable block for bug reports (`[localmgr-2l5.3]`, `[localmgr-2l5.4]`, `[localmgr-2l5.5]`).
- **Structured Error Contract (`LocalMgrError`):** new `LocalMgrError` type (message/kind/detail/fix/command) replaces bare `String` error state in `HubDownloaderService` and `LocalAPIGateway`. Download failures now carry a stable `kind` (`auth-invalid-token`, `auth-license-not-accepted`, `network-transport`, `file-io`, etc.) instead of only a human-readable string, and gateway failures (409 conflicts, 503 no-runner, 502 upstream-unreachable/timeout, 400 malformed-request) are now logged via `AppLog` and serialized into the HTTP JSON error body from the exact same object, so a developer's curl/IDE output and the in-app Diagnostics view can never disagree about what happened (`[localmgr-2l5.6]`, `[localmgr-2l5.7]`, `[localmgr-2l5.8]`).
- **Richer Hardware Detection:** `HardwareAutoTuner` now classifies a normalized `ChipTier` (M1–M5) from `hw.model`, reads performance/efficiency core counts via `hw.perflevel0/1.physicalcpu`, and offers an opt-in `gpuCoreCount()` probe via `system_profiler SPDisplaysDataType -json` (bounded 5s wait, not on the hot model-launch path). Any RAM-tiered capability inference (e.g. max safe context length) is now explicitly flagged as unconfirmed via `InferredCapability` rather than presented with the same confidence as a measured result (`[localmgr-2l5.9]`).
- **Model Compatibility Tiers:** new `CompatibilityTier` classification (Verified / Recognized-Unverified / Unrecognized Architecture / Unparseable) for scanned GGUF and MLX models, surfaced as a badge in `ModelInspectorView`'s header (distinct from the existing engine-readiness badge) plus an inline actionable notice for any non-verified tier (`[localmgr-2l5.10]`, `[localmgr-2l5.11]`).

## [0.5.1] - 2026-07-16

_Patch release (Build 9) fixing the curated model catalog's broken download paths._

### Fixed
- **Curated Catalog 404s:** all 3 entries in the curated Hugging Face Hub catalog pointed to repos that don't exist (`cohere/north-mini-code-gguf`, `google/gemma-2-9b-it-GGUF`, `meta-llama/Meta-Llama-3.1-8B-Instruct-GGUF`) — Google/Meta/Cohere don't publish GGUF quantizations under their own orgs. Every curated one-click download would 404/401. Corrected to the real, verified `bartowski/*` quantization repos (`[localmgr-3iz]`).
- **Curated Size Labels:** corrected inaccurate `sizeFormatted` labels using real file sizes from the HF Hub tree API — "Cohere North Mini Code" was mislabeled as a 7B model at 4.8 GB when it's actually a 30B-A3B MoE at 18.7 GB; Gemma 2 9B IT was under-labeled at 5.4 GB vs actual 5.8 GB (`[localmgr-3iz]`).
- **Curated Download Speed Calculation:** `CuratedModel` now carries its real byte size (`sizeBytes`), fixing `downloadModel()`, which previously hardcoded a `5_000_000_000`-byte placeholder for every curated model regardless of actual size, throwing off the post-download MB/s speed readout by up to ~4x (`[localmgr-3iz]`).

## [0.5.0] - 2026-07-16

_Minor release (Build 8) adding application-level diagnostic logging and an in-app Diagnostics viewer._

### Added
- **Unified Logging (`AppLog`):** all app-internal events (download/gateway/runner failures, auto-tuner decisions, bookmark I/O errors) now flow through `os.Logger` under subsystem `com.localmgr.mac`, inspectable in Console.app or via `log show --predicate 'subsystem == "com.localmgr.mac"'` even after the app has quit — previously the app had no unified-logging integration at all, only 2 stray `print()` calls (`[localmgr-cve.1]`, `[localmgr-cve.2]`).
- **In-App Diagnostics Viewer:** new `DiagnosticsView` (`Cmd+Shift+L`, or Models → View App Diagnostics...) showing a live, filterable, category-tagged feed of the same events, distinct from the existing model-runner "Live Logs" tab which only shows spawned engine subprocess stdout/stderr (`[localmgr-cve.3]`).
- **Copy / Export Diagnostics:** one-click "Copy" (clipboard) and "Export..." (timestamped `.log` file via save panel) actions in the Diagnostics viewer, so a user can attach real diagnostic output to a bug report instead of only describing symptoms after the fact (`[localmgr-cve.4]`).

## [0.4.2] - 2026-07-16

_Patch release (Build 7) fixing Hugging Face Hub download authentication and error visibility._

### Fixed
- **HF Download Authentication:** attach the resolved `HF_TOKEN` / cached CLI token to the actual model download request (`resolve/main/<file>`) in `HubDownloaderService`, not just repo-listing calls. Gated repos — including the built-in `meta-llama/Meta-Llama-3.1-8B-Instruct-GGUF` curated entry — previously failed with an instant, unauthenticated 401/403.
- **Disappearing Download Notification:** decouple the download error message from the `isDownloading` flag that tears down the in-progress banner. A persistent `lastError` is now surfaced via `.alert()` and dismissible inline banners so failures no longer flash and disappear before they can be read.
- **Unauthenticated Retry Fallback:** automatically retry Hub Discovery listing and downloads without the `Authorization` header when a token is rejected with 401/403, so a stale/expired `HF_TOKEN` no longer permanently blocks repositories that are actually public (`[localmgr-dt2.1]`).
- **Silent Repo Inspection Failures:** `HubDiscoveryView` now surfaces `HuggingFaceAPIClient.errorMessage` (warning icon + Retry button) instead of always showing a generic "no compatible weight files" message regardless of the actual failure cause (`[localmgr-dt2.2]`).
- **Actionable Gated-Model Errors:** distinguish HTTP 401 (invalid/expired token) from 403 (valid token, license not accepted) with specific remediation guidance, shared by the downloader and Hub inspector (`[localmgr-dt2.3]`).

## [0.4.1] - 2026-07-03

_Patch release (Build 6) delivering 30-minute reverse proxy timeouts, recursive Hugging Face Hub tree discovery with token authorization, clickable UI speedometers, and modal sheet dismiss controls._

### Added
- **Interactive Speedometer Navigation:** make the `⚡️ tok/s • TTFT` gauge in `SidebarView` clickable so users can directly open the Enterprise Ops Telemetry Dashboard (`[localmgr-3h0.3]`).
- **Modal Sheet Dismiss Control:** add an explicit `Close` toolbar button and `Esc` hotkey binding inside `OpsDashboardView` (`[localmgr-3h0.4]`).

### Fixed
- **Proxy Timeout for Large Completions:** replace `URLSession.shared` (60s default timeout) with a custom `proxySession` configured with `timeoutIntervalForRequest = 1800.0` (30 minutes), preventing `The request timed out.` errors during 2048+ token generations (`[localmgr-3h0.5]`).
- **Recursive Hugging Face Tree & Token Auth:** update `HuggingFaceAPIClient` to query repository trees recursively (`?recursive=true`) and automatically inject cached credentials (`HF_TOKEN` / `~/.cache/huggingface/token`) so subfolder weight files and gated repositories resolve cleanly (`[localmgr-3h0.1]`).
- **BYOF Documentation Clarity:** update `USER_GUIDE.md` to remove external SSD emphasis and align terminology with standard local directory attachments (`[localmgr-3h0.2]`).

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

[Unreleased]: https://github.com/ghchinoy/localmgr/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/ghchinoy/localmgr/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/ghchinoy/localmgr/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/ghchinoy/localmgr/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/ghchinoy/localmgr/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/ghchinoy/localmgr/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/ghchinoy/localmgr/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/ghchinoy/localmgr/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ghchinoy/localmgr/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ghchinoy/localmgr/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/ghchinoy/localmgr/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ghchinoy/localmgr/releases/tag/v0.1.0
