#!/usr/bin/env python3
"""
Streaming benchmark script for measuring model performance.
Mainly to help me tunning my llama.cpp.

Metrics:
- TTFT (Time to First Token): Latency until the first token appears.
- PP TPS (Prompt Processing): prompt_tokens / TTFT — how fast the server
  ingests context. Reported when usage info is available.
- Total TPS: Overall generation throughput (reasoning + content tokens).
- Reasoning TPS: Generation speed during the thinking phase.
- Content TPS: Generation speed of the actual answer.
- ITL P95: 95th-percentile inter-token latency from all samples across all runs.

Progress characters: 't' = reasoning/thinking token, '.' = content token.
"""

import argparse
import math
import time
import urllib.request
import urllib.error
import json


def benchmark_stream(base_url, prompt, max_tokens, model="default", num_runs=10, temperature=0.0, show_output=False, cache_prompt=False):
    headers = {"Content-Type": "application/json"}
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
        # Ask llama.cpp / OpenAI-compatible servers to include usage in the stream
        "stream_options": {"include_usage": True},
        # llama.cpp-specific: when False, force re-evaluation of the prompt every run.
        # PP TPS is meaningless if the server reuses cached KV — every call would
        # only ingest a few tokens of delta and report sky-high TTFT-derived rates.
        "cache_prompt": cache_prompt,
    }

    print(f"LLM Streaming Benchmark")
    print(f"URL: {base_url}")
    print(f"Model: {model}")
    print(f"Runs: {num_runs} (+1 warm-up) | max_tokens: {max_tokens} | temperature: {temperature}")
    print("-" * 75)

    all_results = []

    # Run 0 is a warm-up to eliminate cold-start bias
    for run in range(0, num_runs + 1):
        is_warmup = run == 0
        label = "WARM-UP" if is_warmup else f"Run {run}/{num_runs}"
        print(f"\n[{label}]", end=" ", flush=True)

        encoded = json.dumps(payload).encode("utf-8")
        start_time = time.time()

        first_token_time = None
        reasoning_start_time = None
        content_start_time = None
        last_token_time = None
        token_times = []
        finish_reason = None

        total_reasoning_tokens = 0
        total_content_tokens = 0
        prompt_tokens = None  # populated from final usage chunk if present

        try:
            req = urllib.request.Request(base_url, data=encoded, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=300) as response:
                for line in response:
                    line = line.decode("utf-8").strip()
                    if not line or not line.startswith("data: "):
                        continue

                    raw = line[6:]
                    if raw == "[DONE]":
                        break

                    try:
                        chunk = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    # Final usage chunk (sent when stream_options.include_usage=True)
                    usage = chunk.get("usage")
                    if usage:
                        prompt_tokens = usage.get("prompt_tokens", prompt_tokens)

                    choices = chunk.get("choices", [])
                    if not choices:
                        continue

                    choice = choices[0]

                    # Track finish_reason from any chunk that provides it
                    fr = choice.get("finish_reason")
                    if fr is not None:
                        finish_reason = fr

                    delta = choice.get("delta", {})
                    # Use `or ""` to handle both missing keys and explicit JSON null
                    reasoning = delta.get("reasoning_content") or ""
                    content = delta.get("content") or ""

                    if reasoning or content:
                        now = time.time()
                        if first_token_time is None:
                            first_token_time = now

                        if reasoning:
                            if reasoning_start_time is None:
                                reasoning_start_time = now
                            total_reasoning_tokens += 1

                        if content:
                            if content_start_time is None:
                                content_start_time = now
                            total_content_tokens += 1

                        last_token_time = now
                        token_times.append(now)

                        if not is_warmup:
                            if show_output:
                                if content:
                                    print(content, end="", flush=True)
                            else:
                                print("t" if reasoning else ".", end="", flush=True)

            if not is_warmup:
                total_tokens = total_reasoning_tokens + total_content_tokens

                # TTFT: from request send to first token received
                ttft = (first_token_time - start_time) if first_token_time else None

                # Total TPS: all tokens over the generation window (first token to last token).
                # Using last_token_time avoids inflating duration with HTTP teardown overhead.
                gen_duration = (
                    (last_token_time - first_token_time)
                    if (first_token_time and last_token_time and last_token_time > first_token_time)
                    else None
                )
                total_tps = total_tokens / gen_duration if gen_duration else 0

                # Reasoning TPS: reasoning tokens over their window.
                # Upper bound is content start (if content followed) or last token.
                r_tps = 0
                if total_reasoning_tokens > 0 and reasoning_start_time:
                    r_end = content_start_time if content_start_time else last_token_time
                    r_duration = r_end - reasoning_start_time
                    r_tps = total_reasoning_tokens / r_duration if r_duration > 0 else 0

                # Content TPS: content tokens over their window.
                c_tps = 0
                if total_content_tokens > 0 and content_start_time and last_token_time:
                    c_duration = last_token_time - content_start_time
                    c_tps = total_content_tokens / c_duration if c_duration > 0 else 0

                # Individual inter-token latencies — stored raw for aggregate P95 in summary.
                itls = [token_times[i] - token_times[i - 1] for i in range(1, len(token_times))]

                truncated = finish_reason == "length"

                # PP TPS: prompt tokens ingested per second (uses TTFT as ingestion window).
                # TTFT also includes a small server overhead, so this slightly underestimates
                # raw prompt-processing throughput — fine for relative comparisons.
                pp_tps = (prompt_tokens / ttft) if (prompt_tokens and ttft and ttft > 0) else 0

                all_results.append({
                    "ttft": ttft,
                    "pp_tps": pp_tps,
                    "prompt_tokens": prompt_tokens,
                    "total_tps": total_tps,
                    "r_tps": r_tps,
                    "c_tps": c_tps,
                    "itls": itls,
                    "total_tokens": total_tokens,
                    "truncated": truncated,
                })

                ttft_str = f"TTFT: {ttft * 1000:.0f}ms" if ttft is not None else "TTFT: N/A"
                pp_str = f", PP: {pp_tps:.1f} t/s" if pp_tps else ""
                tps_str = f"Total TPS: {total_tps:.1f}" if total_tps else "no tokens"
                trunc_flag = " [TRUNCATED - increase --tokens]" if truncated else ""
                prefix = "\n" if show_output else " "
                print(f"{prefix}Done. ({ttft_str}{pp_str}, {tps_str}, tokens: {total_tokens}{trunc_flag})")
            else:
                print(" Done.")

        except Exception as e:
            print(f" Error: {e}")

    # --- Summary ---
    if not all_results:
        return

    truncated_count = sum(1 for r in all_results if r["truncated"])
    if truncated_count:
        print(
            f"\n  WARNING: {truncated_count}/{len(all_results)} run(s) hit max_tokens ({max_tokens})."
            f" TPS figures are underestimated — increase --tokens."
        )

    def percentile(sorted_data, p):
        """Nearest-rank percentile (ceil-based), p in 0–100."""
        if not sorted_data:
            return 0
        idx = max(0, math.ceil(len(sorted_data) * p / 100) - 1)
        return sorted_data[idx]

    def get_stats(values):
        if not values:
            return None
        s = sorted(values)
        return min(s), max(s), sum(s) / len(s), percentile(s, 95)

    # Aggregate all individual ITLs across runs for a statistically meaningful P95.
    all_itls_ms = sorted(itl * 1000 for r in all_results for itl in r["itls"])

    print("\n" + "=" * 80)
    print(f"{'FINAL BENCHMARK SUMMARY':^80}")
    print("=" * 80)
    print(f"{'Metric':<25} {'Min':>12} {'Max':>12} {'Avg':>12} {'P95':>12}")
    print("-" * 80)

    per_run_metrics = [
        ("TTFT (ms)", [r["ttft"] * 1000 for r in all_results if r["ttft"] is not None]),
        ("PP TPS (prompt)", [r["pp_tps"] for r in all_results if r.get("pp_tps", 0) > 0]),
        ("Total TPS", [r["total_tps"] for r in all_results if r["total_tps"] > 0]),
        ("Reasoning TPS", [r["r_tps"] for r in all_results if r["r_tps"] > 0]),
        ("Content TPS", [r["c_tps"] for r in all_results if r["c_tps"] > 0]),
    ]

    for name, data in per_run_metrics:
        stats = get_stats(data)
        if stats:
            mi, ma, av, p95 = stats
            print(f"{name:<25} {mi:>12.1f} {ma:>12.1f} {av:>12.1f} {p95:>12.1f}")

    # ITL from the full distribution across all runs (not averages of averages)
    if all_itls_ms:
        mi, ma, av, p95 = get_stats(all_itls_ms)
        print(f"{'ITL (ms)':<25} {mi:>12.1f} {ma:>12.1f} {av:>12.1f} {p95:>12.1f}")
        print(f"  (ITL computed from {len(all_itls_ms)} samples across {len(all_results)} runs)")

    print("=" * 80)


def _fetch_json(url, timeout=5):
    """Fetch a URL and return parsed JSON, or None on failure."""
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def _extract_context_length(model_entry):
    """Try to extract context length from a /v1/models entry (varies by server)."""
    # vLLM: top-level max_model_len
    if "max_model_len" in model_entry:
        return model_entry["max_model_len"]
    # llama.cpp: meta.n_ctx_train
    meta = model_entry.get("meta", {})
    if "n_ctx_train" in meta:
        return meta["n_ctx_train"]
    return None


def probe_openai_compatible(base_url):
    """Check /v1/models to confirm the server is OpenAI-compatible.

    Returns (chat_completions_url, discovered_context_length, model_ids).
    discovered_context_length and model_ids are None/[] if not found.
    """
    models_url = base_url + "/v1/models"
    data = _fetch_json(models_url)
    if data is None:
        print(f"Error: could not reach {models_url}")
        return None, None, []
    if "data" not in data and "object" not in data:
        print(f"Error: {models_url} responded but does not look OpenAI-compatible.")
        return None, None, []

    print(f"OpenAI-compatible server detected at {base_url}")

    discovered_ctx = None
    model_ids = []
    for model in data.get("data", []):
        model_id = model.get("id", "?")
        model_ids.append(model_id)
        extras = []

        ctx = _extract_context_length(model)
        if ctx is not None:
            discovered_ctx = ctx
            extras.append(f"ctx={ctx}")

        # llama.cpp: surface quantization / param count if present
        meta = model.get("meta", {})
        for key, label in [("n_params", "params"), ("quantization_type", "quant")]:
            if key in meta:
                extras.append(f"{label}={meta[key]}")

        suffix = f"  ({', '.join(extras)})" if extras else ""
        print(f"  Model: {model_id}{suffix}")

    # llama.cpp /props: server-side defaults including active n_ctx
    props = _fetch_json(base_url + "/props")
    if props:
        gen = props.get("default_generation_settings", {})
        n_ctx = gen.get("n_ctx") or props.get("n_ctx")
        if n_ctx:
            print(f"  Server n_ctx (active): {n_ctx}")
            # Prefer active context window over training-time value
            discovered_ctx = n_ctx
        slots = props.get("total_slots")
        if slots is not None:
            print(f"  Total slots: {slots}")

    return base_url + "/v1/chat/completions", discovered_ctx, model_ids


def main():
    parser = argparse.ArgumentParser(description="LLM Streaming Benchmark Tool")
    parser.add_argument("-u", "--url", default="http://127.0.0.1:8080")
    parser.add_argument(
        "-p", "--prompt",
        default="What is the difference between a mutex and a semaphore? Give a concise technical explanation with a short code example.",
    )
    parser.add_argument(
        "--prompt-file",
        help="Read prompt text from a file (overrides --prompt). Useful for large/repeatable prompts when comparing server flags.",
    )
    parser.add_argument("-m", "--model", default=None,
                        help="Model ID to use (default: auto-detected if server has one model)")
    parser.add_argument("-t", "--tokens", type=int, default=None,
                        help="Max tokens to generate (default: auto from server, fallback 4096)")
    parser.add_argument("-r", "--runs", type=int, default=5)
    parser.add_argument("--temperature", type=float, default=0.0,
                        help="Sampling temperature (default 0.0 = greedy, best for reproducibility)")
    parser.add_argument("--output", action="store_true",
                        help="Print the LLM's answer text as it streams (content tokens only)")
    parser.add_argument("--cache-prompt", action="store_true",
                        help="Allow llama.cpp server to reuse cached prompt KV between runs. "
                             "Off by default so PP TPS measurements are meaningful (each run "
                             "re-ingests the full prompt).")
    args = parser.parse_args()

    if args.prompt_file:
        with open(args.prompt_file, "r") as f:
            args.prompt = f.read()

    base_url = args.url.rstrip("/")
    discovered_ctx = None
    model_ids = []
    if base_url.endswith("/v1/chat/completions"):
        url = base_url
    else:
        url, discovered_ctx, model_ids = probe_openai_compatible(base_url)
        if url is None:
            return

    if args.model is None:
        if len(model_ids) == 1:
            args.model = model_ids[0]
        elif len(model_ids) > 1:
            print(f"Error: server exposes {len(model_ids)} models. Specify one with -m. Available:")
            for mid in model_ids:
                print(f"  {mid}")
            return
        else:
            args.model = "default"

    max_tokens = args.tokens or discovered_ctx or 4096
    if args.tokens is None:
        src = f"server-discovered ({discovered_ctx})" if discovered_ctx else "fallback"
        print(f"  max_tokens: {max_tokens} ({src})")

    benchmark_stream(url, args.prompt, max_tokens, model=args.model,
                     num_runs=args.runs, temperature=args.temperature, show_output=args.output,
                     cache_prompt=args.cache_prompt)


if __name__ == "__main__":
    main()
