# LocalMgr: Core User Journeys (CUJs) & Issue Mapping

This document establishes the official **Core User Journeys (CUJs)** for **LocalMgr**, mapping each user goal directly to its corresponding architectural architecture components and issue tracker (`bd`) Epics and Tasks. 

This record serves as the foundational reference for future product iterations, acceptance testing, and the generation of our **Diátaxis documentation suite** (Tutorials, How-To Guides, Reference, and Explanation).

---

## CUJ-1: Core Discover, Precise Fit & Engine Readiness

### User Persona & Primary Goal
An Apple Silicon developer or AI power user who has downloaded model weights (`.gguf` files or MLX `.safetensors` folders) and wants to:
1. Discover and inspect local model libraries without copying files.
2. Immediately know whether their machine has the required execution binaries installed (`llama-server`, `mlx_lm.server`, Kokoro).
3. Understand the exact RAM/VRAM memory pressure a model will put on their system before clicking "Start".
4. Seamlessly load and unload models while observing real-time system RAM pressure.

### Journey Breakdown & Issue Tracking Mapping

| Step | User Action / Expectation | Architectural Component | Mapped `bd` Issue ID | Current Status |
| :--- | :--- | :--- | :--- | :--- |
| **1. Vault Discovery** | User points LocalMgr to external model folders (`~/Models/GGUF`, Hugging Face cache). App lists models with zero copying. | `ModelCatalogService`<br>(Security-Scoped Bookmarks) | `localmgr-r3p.2` (Completed in Scaffold) | 🟢 Foundation Built |
| **2. Prerequisite Check** | User inspects a model card and immediately sees if the required engine (`mlx_lm.server` or `llama-server`) is installed and ready, or missing. | `EngineReadinessService`<br>(PATH & Env Scanner) | **Epic**: `localmgr-odf`<br>**Task**: `localmgr-odf.1`<br>**Task**: `localmgr-odf.3` | 🟡 P1 Next Up for Execution |
| **3. Precise Pressure Prediction** | Before loading an 8B or 14B model, user views exact memory requirements broken down by weights + context length KV cache. | `GGUFHeaderParser`<br>& `SystemMonitorService` | **Epic**: `localmgr-odf`<br>**Task**: `localmgr-odf.2` | 🟡 P1 Next Up for Execution |
| **4. Live Memory Check** | User sees live Apple Silicon RAM breakdown (Wired/Active/Free) and a Fit Badge (`🟢 Excellent Fit` vs `🔴 Exceeds RAM`). | `SystemMonitorService`<br>(Mach Host Telemetry) | `localmgr-r3p.3` (Completed in Scaffold) | 🟢 Foundation Built |
| **5. Execution & Unload** | User clicks "Start Runner", observes live terminal stdout/stderr logs, and clicks "Stop" when done. | `BackendRunnerManager`<br>(Subprocess Orchestrator) | `localmgr-r3p.4` (Completed in Scaffold) | 🟢 Foundation Built |

---

## CUJ-2: Unified Local Gateway & Multi-Engine Swapping

### User Persona & Primary Goal
A software engineer coding in Xcode or VS Code / Cursor who wants a single, reliable local API endpoint (`http://127.0.0.1:4891/v1`) that routes requests transparently to active models or wakes up models on demand without changing client configuration.

### Journey Breakdown & Issue Tracking Mapping

| Step | User Action / Expectation | Architectural Component | Mapped `bd` Issue ID | Current Status |
| :--- | :--- | :--- | :--- | :--- |
| **1. Gateway Connection** | User configures IDE / agent to point to `http://127.0.0.1:4891/v1`. | `LocalAPIGateway`<br>(Built-in Swift HTTP Server) | `localmgr-6vw` (Feature P2) | ○ Backlog |
| **2. On-Demand Launch** | API call requests `model: "cohere-mini"`. Gateway detects runner is stopped, wakes engine, and proxies request. | `LocalAPIGateway` + `BackendRunnerManager` | `localmgr-6vw` (Feature P2) | ○ Backlog |
| **3. Seamless Engine Swapping** | User swaps from a GGUF LLM (`llama-server`) to an MLX model (`mlx_lm.server`). API gateway port remains constant at `4891`. | `BackendRunnerManager` | `localmgr-6vw` (Feature P2) | ○ Backlog |

---

## CUJ-3: Hardware Auto-Tuning & Emergency Pressure Release

### User Persona & Primary Goal
A heavy multitasking developer running local models alongside intensive compilation (Xcode) or container workloads (Docker), needing LocalMgr to protect macOS system responsiveness and prevent OS freeze-ups.

### Journey Breakdown & Issue Tracking Mapping

| Step | User Action / Expectation | Architectural Component | Mapped `bd` Issue ID | Current Status |
| :--- | :--- | :--- | :--- | :--- |
| **1. Chip Tier Auto-Tuning** | User launches model on an M3 Max (64GB). App auto-configures `-ngl 99`, `--flash-attn`, and optimal context caps without manual tuning. | `HardwareAutoTuningService`<br>(`sysctlbyname("hw.model")`) | `localmgr-oi3` (Feature P2) | ○ Backlog |
| **2. Idle Reclaiming** | Model sits idle for 15 minutes while user reviews PRs. LocalMgr unloads weights from VRAM to free up memory. | `IdleTTLTimer` | `localmgr-wzu` (Feature P2) | ○ Backlog |
| **3. OS Pressure Protection** | Xcode build spikes RAM usage. LocalMgr catches macOS memory pressure alert and drains active runner before thrashing occurs. | `SystemMonitorService`<br>(`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`) | `localmgr-wzu` (Feature P2) | ○ Backlog |

---

## Future Roadmap Journeys

* **CUJ-R1: Next-Gen Gemma 4+ Execution via Lightweight SIMD Reference**
  * *Goal*: Running latest Gemma 4+ architectures via specialized CPU reference runners once upstream support ships.
  * *Mapped Issue*: `localmgr-e3b` (Roadmap P4 - Tracking `google/gemma.cpp`).

---

## Diátaxis Documentation Framework Alignment

When building public-facing docs for LocalMgr, these CUJs will structure the four quadrants of our **Diátaxis** documentation tree:

1. **Tutorials (Learning-oriented)**:
   * *Guide*: "Getting Started with Your First Local Model Vault on macOS" (Derived from CUJ-1 Steps 1, 4, 5).
2. **How-To Guides (Problem-oriented)**:
   * *Guide*: "How to Install and Configure MLX and Llama.cpp CLI Binaries" (Derived from CUJ-1 Step 2).
   * *Guide*: "Connecting Cursor and Xcode to LocalMgr's Unified API Gateway" (Derived from CUJ-2).
3. **Reference (Information-oriented)**:
   * *Guide*: "Supported GGUF & MLX Header Specifications and Quantization Table" (Derived from CUJ-1 Step 3).
   * *Guide*: "Apple Silicon Hardware Auto-Tuning Profiles & Flags Matrix" (Derived from CUJ-3 Step 1).
4. **Explanation (Understanding-oriented)**:
   * *Guide*: "Understanding Apple Silicon Unified Memory Telemetry, Page-Outs, and Fit Prediction" (Derived from CUJ-1 Step 4 & CUJ-3 Step 3).
