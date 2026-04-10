#!/usr/bin/env python3
"""
Streaming benchmark script for measuring model performance.
Mainly to help me tunning my llama.cpp.

Metrics:
- TTFT (Time to First Token): Latency until the first token appears.
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


def benchmark_stream(base_url, prompt, max_tokens, num_runs=10, temperature=0.0, show_output=False):
    headers = {"Content-Type": "application/json"}
    payload = {
        "model": "default",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
    }

    print(f"LLM Streaming Benchmark")
    print(f"URL: {base_url}")
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

        try:
            req = urllib.request.Request(base_url, data=encoded, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=120) as response:
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

                all_results.append({
                    "ttft": ttft,
                    "total_tps": total_tps,
                    "r_tps": r_tps,
                    "c_tps": c_tps,
                    "itls": itls,
                    "total_tokens": total_tokens,
                    "truncated": truncated,
                })

                ttft_str = f"TTFT: {ttft * 1000:.0f}ms" if ttft is not None else "TTFT: N/A"
                tps_str = f"Total TPS: {total_tps:.1f}" if total_tps else "no tokens"
                trunc_flag = " [TRUNCATED - increase --tokens]" if truncated else ""
                prefix = "\n" if show_output else " "
                print(f"{prefix}Done. ({ttft_str}, {tps_str}, tokens: {total_tokens}{trunc_flag})")
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


def probe_openai_compatible(base_url):
    """Check /v1/models to confirm the server is OpenAI-compatible, return chat completions URL."""
    models_url = base_url + "/v1/models"
    try:
        req = urllib.request.Request(models_url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        if "data" not in data and "object" not in data:
            print(f"Error: {models_url} responded but does not look OpenAI-compatible.")
            return None
        model_ids = [m.get("id", "?") for m in data.get("data", [])]
        print(f"OpenAI-compatible server detected at {base_url}")
        if model_ids:
            print(f"Available models: {', '.join(model_ids)}")
    except urllib.error.HTTPError as e:
        print(f"Error: {models_url} returned HTTP {e.code}. Is this an OpenAI-compatible server?")
        return None
    except Exception as e:
        print(f"Error: could not reach {models_url}: {e}")
        return None
    return base_url + "/v1/chat/completions"


def main():
    parser = argparse.ArgumentParser(description="LLM Streaming Benchmark Tool")
    parser.add_argument("-u", "--url", default="http://127.0.0.1:8080")
    parser.add_argument(
        "-p", "--prompt",
        default="What is the difference between a mutex and a semaphore? Give a concise technical explanation with a short code example.",
    )
    parser.add_argument("-t", "--tokens", type=int, default=4096)
    parser.add_argument("-r", "--runs", type=int, default=5)
    parser.add_argument("--temperature", type=float, default=0.0,
                        help="Sampling temperature (default 0.0 = greedy, best for reproducibility)")
    parser.add_argument("--output", action="store_true",
                        help="Print the LLM's answer text as it streams (content tokens only)")
    args = parser.parse_args()

    base_url = args.url.rstrip("/")
    if base_url.endswith("/v1/chat/completions"):
        url = base_url
    else:
        url = probe_openai_compatible(base_url)
        if url is None:
            return

    benchmark_stream(url, args.prompt, args.tokens, num_runs=args.runs,
                     temperature=args.temperature, show_output=args.output)


if __name__ == "__main__":
    main()
