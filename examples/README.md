# LocalMgr API Gateway Examples (Python & Go)

This directory contains runnable **Python** and **Go** client examples demonstrating how to interact with LocalMgr's built-in OpenAI-compatible API Gateway (`http://127.0.0.1:4891`).

Both examples use only their language's standard library (zero third-party dependencies required) and cover:
1. **Gateway Health & Telemetry** (`GET /v1/stats`)
2. **Model Catalog Discovery** (`GET /v1/models`)
3. **Buffered Chat Completions & Gemma 4 Reasoning Extraction** (`POST /v1/chat/completions`)
4. **Incremental Server-Sent Events (SSE) Streaming** (`POST /v1/chat/completions` with `"stream": true`)

---

## Prerequisites

1. Launch **LocalMgr** (`open /Applications/LocalMgr.app` or `make run`).
2. Ensure at least one model vault is attached (e.g., `/Users/ghchinoy/projects/gemma`).
   - You do **not** need to manually start a model runner first: if no runner is active, passing a `"model"` ID (such as `"mlx-gemma-4-e2b"` or `"gemma-4-E2B-it-Q4_K_M"`) triggers **on-demand wake-up** automatically.
   - If a model runner is already active, either pass that active model's ID or pass `"default"` / `"local"` (requesting a *different* model while one is active returns HTTP `409 Conflict` to protect active sessions from VRAM swap thrashing).

---

## 1. Python Example (`examples/python/gateway_client.py`)

### Run Buffered + Streaming Demo
```bash
python3 examples/python/gateway_client.py
```

### Run With Specific Model or Streaming Only
```bash
# Target a specific Gemma 4 MLX or GGUF model
python3 examples/python/gateway_client.py --model mlx-gemma-4-e2b

# Stream tokens in real time via SSE
python3 examples/python/gateway_client.py --model mlx-gemma-4-e2b --stream \
  --prompt "Write a 3-line haiku about Apple Silicon unified memory."
```

### Using the Official `openai` Python SDK
Because LocalMgr's gateway is OpenAI-compatible, you can also point the standard `openai` package directly at `http://127.0.0.1:4891/v1`:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:4891/v1",
    api_key="localmgr",  # Any non-empty string; loopback requires no auth
)

models = client.models.list()
print("Available models:", [m.id for m in models.data])

resp = client.chat.completions.create(
    model="mlx-gemma-4-e2b",
    messages=[{"role": "user", "content": "Explain unified memory in one sentence."}],
    max_tokens=512,  # Allocate >= 512 tokens for thinking models (Gemma 4, DeepSeek-R1)
)
print(resp.choices[0].message.content)
```

---

## 2. Go Example (`examples/go/main.go`)

### Run Buffered + Streaming Demo
```bash
cd examples/go
go run .
```

### Run With Specific Model or Flags
```bash
cd examples/go
go run . -model mlx-gemma-4-e2b -stream -prompt "List 3 advantages of Metal unified memory."
```

---

## Handling Thinking / Reasoning Models (Gemma 4)

Reasoning models emit their internal chain-of-thought before emitting the final answer:
- **`llama-server` (GGUF)** places the thinking trace in `choices[0].message.reasoning_content` (and `delta.reasoning_content` when streaming).
- **`mlx_lm.server` (MLX 0.32.2+)** places the thinking trace in `choices[0].message.reasoning` (and `delta.reasoning` when streaming).
- Both engines place the final user-facing answer in `choices[0].message.content` (`delta.content`).

Always set `max_tokens >= 512` when querying Gemma 4 so the model has enough token budget to finish its reasoning trace and emit the final response. Both [`gateway_client.py`](python/gateway_client.py) and [`main.go`](go/main.go) inspect both `reasoning_content` and `reasoning` automatically.
