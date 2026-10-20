#!/usr/bin/env python3
"""
LocalMgr API Gateway Client Example (Zero-Dependency Python 3)

Demonstrates:
  1. Checking gateway status and telemetry (`GET /v1/stats`)
  2. Listing available models in attached vaults (`GET /v1/models`)
  3. Sending a buffered chat completion with Gemma 4 reasoning extraction (`POST /v1/chat/completions`)
  4. Streaming tokens incrementally over Server-Sent Events (`"stream": true`)

Usage:
  python3 examples/python/gateway_client.py
  python3 examples/python/gateway_client.py --model mlx-gemma-4-e2b --stream
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from typing import Any


DEFAULT_BASE_URL = "http://127.0.0.1:4891"
PREFERRED_MODELS = [
    "gemma-4-E2B-it-Q4_K_M",
    "mlx-gemma-4-e2b",
    "gemma-4-E4B-it-Q4_K_M",
    "mlx-gemma-4-e4b",
    "mlx-gemma-4-12b-it",
]


def http_get_json(url: str, timeout: float = 10.0) -> dict[str, Any]:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def select_target_model(models_payload: dict[str, Any], requested: str | None) -> str:
    data = models_payload.get("data", [])
    # 1. If the user explicitly passed a model name, honor it.
    if requested:
        return requested
    # 2. If a runner is already active in LocalMgr, use that model to avoid a 409 conflict.
    for item in data:
        if item.get("active") is True and item.get("id"):
            return str(item["id"])
    # 3. Otherwise pick a preferred Gemma 4 model if present, or fall back to the first model.
    available_ids = [str(item["id"]) for item in data if item.get("id")]
    for candidate in PREFERRED_MODELS:
        if candidate in available_ids:
            return candidate
    return available_ids[0] if available_ids else "default"


def run_buffered_completion(
    base_url: str, model: str, prompt: str, max_tokens: int
) -> None:
    print(f"\n--- 1. Buffered Chat Completion (model={model!r}) ---")
    url = f"{base_url}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a concise technical assistant."},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": max_tokens,
        "stream": False,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=300.0) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        err_body = err.read().decode("utf-8", errors="replace")
        print(f"HTTP {err.code} Error from Gateway:\n{err_body}", file=sys.stderr)
        sys.exit(1)

    choice = (result.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    # llama-server uses `reasoning_content`; mlx_lm.server (0.32.2+) uses `reasoning`.
    thinking = message.get("reasoning_content") or message.get("reasoning") or ""
    content = message.get("content") or ""
    usage = result.get("usage") or {}

    if thinking.strip():
        print(f"[Reasoning Trace]:\n{thinking.strip()}\n")
    print(f"[Assistant Answer]:\n{content.strip()}")
    if usage:
        print(
            f"\n[Usage]: prompt_tokens={usage.get('prompt_tokens', 0)}, "
            f"completion_tokens={usage.get('completion_tokens', 0)}, "
            f"total_tokens={usage.get('total_tokens', 0)}"
        )


def run_streaming_completion(
    base_url: str, model: str, prompt: str, max_tokens: int
) -> None:
    print(f"\n--- 2. Streaming SSE Chat Completion (model={model!r}) ---")
    url = f"{base_url}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "You are a concise technical assistant."},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": max_tokens,
        "stream": True,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    in_thinking = False
    in_answer = False

    try:
        with urllib.request.urlopen(req, timeout=300.0) as resp:
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data_str = line[len("data:") :].strip()
                if data_str == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                choices = chunk.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                reasoning_piece = (
                    delta.get("reasoning_content") or delta.get("reasoning") or ""
                )
                content_piece = delta.get("content") or ""

                if reasoning_piece:
                    if not in_thinking:
                        print("[Thinking]: ", end="", flush=True)
                        in_thinking = True
                    print(reasoning_piece, end="", flush=True)

                if content_piece:
                    if not in_answer:
                        if in_thinking:
                            print("\n")
                        print("[Answer]: ", end="", flush=True)
                        in_answer = True
                    print(content_piece, end="", flush=True)
        print()
    except urllib.error.HTTPError as err:
        err_body = err.read().decode("utf-8", errors="replace")
        print(f"\nHTTP {err.code} Error from Gateway:\n{err_body}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Example Python client for the LocalMgr OpenAI-compatible gateway."
    )
    parser.add_argument(
        "--base-url",
        default=DEFAULT_BASE_URL,
        help=f"Gateway base URL (default: {DEFAULT_BASE_URL})",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Model ID from /v1/models (defaults to active runner or mlx-gemma-4-e2b)",
    )
    parser.add_argument(
        "--prompt",
        default="Explain Apple Silicon zero-copy unified memory in one concise sentence.",
        help="User prompt to send to the model",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=512,
        help="Max completion tokens (use >= 512 for Gemma 4 thinking models)",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        help="Run only the SSE streaming completion example",
    )
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")

    try:
        stats = http_get_json(f"{base_url}/v1/stats")
        models = http_get_json(f"{base_url}/v1/models")
    except Exception as exc:
        print(
            f"Could not connect to LocalMgr gateway at {base_url}: {exc}\n"
            "Hint: Launch LocalMgr (`open /Applications/LocalMgr.app`) first.",
            file=sys.stderr,
        )
        sys.exit(1)

    active_runner = stats.get("active_runner", {})
    print(
        f"Gateway Status: {stats.get('status')} | "
        f"Runner Status: {active_runner.get('status')} | "
        f"Active Model: {active_runner.get('model', 'None (will wake on demand)')}"
    )

    available = [m.get("id") for m in models.get("data", [])]
    print(f"Discovered Vault Models ({len(available)}): {', '.join(available)}")

    target_model = select_target_model(models, args.model)

    if args.stream:
        run_streaming_completion(base_url, target_model, args.prompt, args.max_tokens)
    else:
        run_buffered_completion(base_url, target_model, args.prompt, args.max_tokens)
        run_streaming_completion(base_url, target_model, args.prompt, args.max_tokens)


if __name__ == "__main__":
    main()
