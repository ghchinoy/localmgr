# LocalMgr User & Persona Guide
**Step-by-Step Walkthroughs & Practical How-To Guides (Diátaxis Framework)**

Welcome to the **LocalMgr User Guide**! While our `README.md` provides a high-level technical summary and `ARCHITECTURE_PLAN.md` details internal blueprints, this document is a **practical, persona-focused handbook**. It provides step-by-step instructions, troubleshooting tips, rich cURL examples, and visual walkthrough steps for executing every Core User Journey (CUJ).

---

## Persona Matrix: Who is this guide for?

| Persona | Primary Needs & Goals | Core Journeys |
| :--- | :--- | :--- |
| **Local AI Developer / Power User** | Wants to run local LLMs inside Cursor/Xcode/VS Code, attach existing external SSD vaults without copying weights, and optimize Apple Silicon memory. | CUJ-1 (BYOF Vaults)<br>CUJ-2 (API Gateway)<br>CUJ-3 (Auto-Tuning) |
| **Model Researcher & Audio Creator** | Wants to discover new quantized weights on Hugging Face Hub, check if they fit physical RAM before downloading, and run Kokoro TTS. | CUJ-4 (Hub Downloader)<br>CUJ-1 (Format Scanning) |
| **Enterprise AI Lead / Ops Engineer** | Wants persistent inference telemetry (`history.jsonl`), Prometheus metrics scraping, and automated benchmark matrices to evaluate hardware efficiency. | CUJ-5 (Ops Dashboard)<br>CUJ-6 (Next-Gen Telemetry) |

---

## Guide 1: Managing Local Model Folders & Vaults (BYOF) — CUJ-1

LocalMgr operates on a **Bring Your Own Folder (BYOF)** architecture. It never duplicates your multi-gigabyte `.gguf` or `.safetensors` files into hidden folders.

### Step-by-Step: Attaching an Existing Model Directory
1. Launch `/Applications/LocalMgr.app`.
2. In the sidebar under **Model Vaults**, click the small `+` icon or open **Preferences** (`Cmd+,`).
3. Click **Attach Vault Folder** and navigate to any existing directory containing your model files (e.g., `~/Models`, `~/Downloads`, or `~/.cache/huggingface/hub`).
4. Select **Grant Access**. LocalMgr stores a macOS Security-Scoped Bookmark so read/write access persists across restarts without copying data.

![Model Catalog & Format Filtering](screenshots/model_catalog_vaults.webp)

### Understanding Engine Readiness Badges
In the sidebar and inspector, LocalMgr scans your system `$PATH` and `~/Library/Application Support/LocalMgr/Engines/` to check if required CLI backends are installed:
- `🟢 Ready`: The required CLI engine (`llama-server`, `mlx_lm.server`, `ai-edge-litert`) is installed and ready.
- `🔴 Missing Engine`: The binary was not found. Install it using Astral `uv` or Homebrew as prompted in the UI.

---

## Guide 2: Serving Completions via the API Gateway — CUJ-2

LocalMgr embeds a lightweight reverse proxy listening by default on loopback port `4891` (`http://127.0.0.1:4891/v1`). It acts as a transparent, auto-waking bridge between your developer IDEs and local model binaries.

### Connecting Your IDE (Cursor, VS Code, Xcode)
In your editor's AI settings:
- **Base URL / Endpoint**: `http://127.0.0.1:4891/v1`
- **API Key**: `localmgr` (or leave blank; LocalMgr accepts arbitrary local keys).
- **Model Name**: Enter the exact filename of a model in your vault (e.g., `gemma-4-E2B-it-Q4_K_M`).

When your editor fires its first request, if the engine is asleep, LocalMgr intercepts the POST request, boots the model into Apple Silicon unified memory on demand, waits for the readiness probe, and proxies your completion!

---

### Connecting OpenCode

[OpenCode](https://opencode.ai) talks to local models through its `@ai-sdk/openai-compatible` provider. Add a provider block to `opencode.jsonc` pointing at LocalMgr's gateway:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "localmgr": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LocalMgr (local)",
      "options": {
        "baseURL": "http://127.0.0.1:4891/v1"
      },
      "models": {
        "gemma-4-E2B-it-Q4_K_M": {
          "name": "Gemma 4 E2B (LocalMgr)"
        }
      }
    }
  }
}
```

A few things specific to using LocalMgr as an agent-harness backend rather than an interactive IDE chat panel:

- **No API key required.** `LocalAPIGateway` performs no `Authorization` header check, so `apiKey` can be omitted entirely from the provider block.
- **Streaming works.** The gateway forwards `"stream": true` requests (OpenCode's default) as incremental Server-Sent Events rather than buffering the full response, so token-by-token output in OpenCode's UI behaves the same as against a hosted provider.
- **One model per provider entry.** LocalMgr runs a single model at a time. If a request specifies a model different from the one currently active, the gateway returns `409 gateway-model-conflict` rather than automatically switching — it will not stop your current runner out from under an in-progress session. List only the model(s) you intend to use for a given LocalMgr session under `models` above, and switch models from LocalMgr's own UI (or restart the runner) rather than by pointing OpenCode at a different model name mid-session.

---

### Deep Dive: Querying Thinking & Reasoning Models (`reasoning_content`)

When querying modern **Reasoning / Thinking Models** (such as **Gemma 4**, **DeepSeek-R1**, or reasoning-tuned Qwen variants), you must format your requests carefully to prevent empty or truncated responses.

#### Why Responses Can Appear Empty
Thinking models divide their output into two streams:
1. **The Chain-of-Thought (CoT)**: Emitted first into `choices[0].message.reasoning_content`.
2. **The Final Answer**: Emitted second into `choices[0].message.content`.

If your cURL payload sets a restrictive limit like `"max_tokens": 128`, the model may spend all 128 tokens reasoning inside `reasoning_content`. The engine hits the token limit (`finish_reason: "length"`) before it ever reaches the final answer, leaving `.content` completely empty (`""`)!

#### Practical Solution: Allocate Headroom & Inspect Both Fields
Always set `"max_tokens": 512` or higher for thinking models, and use `jq` to inspect both the internal reasoning and the final completion:

```bash
curl -s http://127.0.0.1:4891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-E2B-it-Q4_K_M",
    "messages": [
      {"role": "user", "content": "Explain Apple Silicon zero-copy unified memory in one sentence."}
    ],
    "max_tokens": 512
  }' | jq '{answer: .choices[0].message.content, thinking: .choices[0].message.reasoning_content}'
```

---

## Guide 3: Hardware Auto-Tuning & Memory Safety Nets — CUJ-3

Apple Silicon Macs share a single physical memory pool across CPU and GPU cores. LocalMgr helps you maximize model scale without triggering system thrashing.

### Reading the Predictive Fit Score
Before launching a model, click its card to open **Model Inspector**:
- **Wired / Active / Free RAM**: Live breakdown of Apple Silicon host allocations.
- **Predictive Fit Badge**: LocalMgr parses tensor layer dimensions from `.gguf` and `.safetensors` headers, calculating required weight RAM plus dynamic KV cache footprint:
  - `🟢 Fits comfortably`: Ample free RAM; model will run at 100% Metal speed.
  - `🟡 Tight fit`: Model will fit, but close other heavy apps (like Chrome or Xcode) to prevent page-outs.
  - `🔴 Exceeds RAM`: Model exceeds physical memory; loading will cause severe macOS swap thrashing.

![Model Inspector & Predictive Fit Score](screenshots/inspector_memory_fit.webp)

### Apple Silicon Flags & Kernel Eviction
- **Metal Offload (`-ngl 99`)**: LocalMgr auto-detects M-series chips and forces 100% GPU layer offloading and Flash Attention (`--flash-attn on`).
- **Kernel Memory Pressure Protection**: LocalMgr registers macOS kernel event hooks (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`). If your operating system enters `Serious` or `Critical` memory pressure, LocalMgr automatically unloads idle engine runners before your Mac locks up.

---

## Guide 4: Discovering & Downloading Models — CUJ-4

You do not need external browsers or Python scripts to download models from Hugging Face Hub.

### Using the Built-in Hub Discovery Panel
1. Press `Cmd+Shift+H` or click **Hub Discovery** in the toolbar.
2. Search by keyword (`"gemma 2 9b"`) or paste a repository ID (`bartowski/Llama-3.2-8B-Instruct-GGUF`).
3. Click a model repository to view all available quantization files (`Q4_K_M`, `Q8_0`).
4. Look at the **Fit Badge** next to each file. Pick the largest quantization that displays `🟢 Fits comfortably`.
5. Click **Download**. The transfer runs asynchronously in the background with live progress in your toolbar and status bar, automatically verifying SHA-256 checksums upon completion.

---

## Guide 5: Enterprise Ops Monitoring & Benchmarking — CUJ-5 & CUJ-6

For engineering leads managing shared Mac Studio inference racks, LocalMgr acts as a persistent observability plane.

### Step-by-Step: Using the Ops Telemetry Dashboard
1. Press `Cmd+Shift+O` or click **Ops Dashboard** in the top toolbar.
2. **Lifetime KPI Cards**: View aggregate requests, total token throughput, global generation speed (`tok/s`), and global KV cache hit percentages across all sessions.
3. **Host Thermal Rating Gauge**: Monitor whether sustained inference is heating the M-series SoC (`Nominal`, `Fair`, `Serious`, `Critical`).
4. **Per-Model Ranking Table**: Inspect exact average Time-to-First-Token (`TTFT`) and generation speeds per model format.

![Enterprise Ops Monitoring Dashboard](screenshots/ops_dashboard_matrix.webp)

### Running an Automated Benchmark Matrix
To evaluate how fast a new model runs on your hardware:
1. Ensure the target model is active or ready in your vault.
2. Open the **Ops Dashboard** (`Cmd+Shift+O`).
3. Click **Run Benchmark Matrix**. LocalMgr fires a standardized evaluation prompt through the local gateway, records the exact TTFT and generation speed (`tok/s`), and appends the verified benchmark directly into your persistent history table.

### Scraping Prometheus Metrics (`/metrics`)
Connect corporate Prometheus or Grafana monitoring scrapers directly to the gateway port:

```bash
curl -s http://127.0.0.1:4891/metrics
```
Expected output (adhering to Envoy AI Gateway naming standards):
```text
# HELP ai_gateway_llm_requests_total Total HTTP requests handled by the gateway.
# TYPE ai_gateway_llm_requests_total counter
ai_gateway_llm_requests_total{backend="localmgr"} 42

# HELP ai_gateway_llm_upstream_health_status Real-time health status of execution backend.
# TYPE ai_gateway_llm_upstream_health_status gauge
ai_gateway_llm_upstream_health_status{backend="localmgr",engine="llamaCpp"} 1.0

# HELP ai_gateway_llm_token_usage_total Total tokens processed across completions.
# TYPE ai_gateway_llm_token_usage_total counter
ai_gateway_llm_token_usage_total{model="gemma-4-E2B-it-Q4_K_M",backend="localmgr"} 1480
```
All historical events persist across application restarts in **`~/Library/Application Support/LocalMgr/Telemetry/history.jsonl`**.
