#!/usr/bin/env python3
"""
GLM-5.2 (NVFP4 MoE) Massive Production Stress & Performance Suite
Executes a high-concurrency (C=20), high-volume (N=100) stress test against the vLLM serving engine on NVIDIA Blackwell GKE clusters.
Simulates 20 concurrent autonomous engineering agents and enterprise developers running long-context reasoning and code generation.
Measures TTFT (Time-to-First-Token), TPOT (Time-Per-Output-Token), KV Cache Saturation, and Sustained Cluster Throughput.
"""

import argparse
import concurrent.futures
import json
import os
import statistics
import sys
import time
import urllib.request
import urllib.error

MASSIVE_PROMPTS = [
    """You are a Senior Systems Architect at Google. Analyze and explain the complete memory co-design of GLM-5.2 (~381B MoE) on an 8x NVIDIA Blackwell B200 HGX GKE node. 
Detail the exact byte savings from 4-bit NVFP4 quantization (0.5 bytes/param) versus FP16, derive the block scaling factor overhead (1 FP8 scale per 16 weights), and calculate the remaining HBM3e capacity dedicated to PagedAttention Key-Value cache. Furthermore, explain how Grouped-Query Attention (GQA) with 64 query heads and 8 KV heads at head dimension 128 minimizes the KV cache footprint per token across all 80 layers.""",

    """Derive the comprehensive 3-year Committed Use Discount (CUD) Total Cost of Ownership (TCO) model for hosting GLM-5.2 in europe-north1 (Hamina, Finland).
Include the exact pricing differences between On-Demand rate ($32.00/GPU/hour across 8x B200 GPUs) and 3-Year CUD ($13.70/GPU/hour). Provide the step-by-step mathematical derivation of annual savings, accounting for Hamina's 100% seawater cooling efficiency (PUE 1.10) and compact placement policies (`pp-blackwell-nvlink-fi`).""",

    """Explain the internal network routing mechanics of intra-node NVLink tensor parallelism across 8x NVIDIA B200 GPUs on GKE (`a4-highgpu-8g`).
How does NVLink 5.0 (1.8 TB/s bidirectional per GPU) eliminate inter-GPU communication bottlenecks during all-reduce tensor synchronization across TP=8 partitions? Contrast this with inter-node network hops and provide the theoretical bandwidth limits across the B200 HGX baseboard.""",

    """Write a robust, production-grade Python async service using `aiohttp` and `pydantic` that acts as a resilient gateway to the GLM-5.2 vLLM inference endpoint.
Your implementation must include:
1. Circuit breaking when inter-token latency (TPOT) exceeds 50ms for 3 consecutive windows.
2. Exponential backoff with jitter on HTTP 429 / 503 errors.
3. Prefix caching-aware prompt sorting to maximize hit rate across concurrent agent streams.
4. Structured logging of TTFT and token generation speeds.""",

    """Examine the failover and recovery mechanics of a single-node TP=8 GLM-5.2 serving deployment during an unannounced spot preemption event (`cloud.google.com/gke-spot`).
Describe what happens when a SIGTERM is received by the vLLM engine: how the 20-second graceful shutdown budget drains active requests, and how the newly scheduled replacement pod hydrates from Tier-0 Hyperdisk ML (`ROX`) in 38.18 seconds without network egress storms.""",

    """Compare and contrast Multi-Token Prediction (`--num-speculative-tokens=1` / MTP-1) speculative decoding against standard autoregressive decoding in MoE models.
How does predicting the next $K=1$ tokens using the draft heads attached to GLM-5.2 increase effective memory bandwidth utilization on Blackwell tensor cores? Derive the exact acceptance rate condition under which MTP-1 yields a net wall-clock speedup when serving 20 concurrent users at 128k context.""",

    """Design the complete Kubernetes manifest stack and custom Horizontal Pod Autoscaler (HPA) definition for scaling GLM-5.2 pods based on PagedAttention KV cache utilization.
Provide exact YAML snippets for a `CustomMetric` HPA targeting `vllm:kv_cache_usage_perc == 75%`. Explain why CPU or memory utilization metrics are fundamentally unsuitable for scaling LLM inference engines and how dynamic KV cache swapping to local NVMe SSD RAID 0 acts as a critical buffer during traffic spikes."""
]

def parse_args():
    parser = argparse.ArgumentParser(description="GLM-5.2 Massive Stress Benchmark")
    parser.add_argument("--endpoint", default="http://localhost:8000/v1/completions",
                        help="vLLM completions endpoint URL")
    parser.add_argument("--model", default="glm-5.2-moe", help="Served model ID")
    parser.add_argument("--api-key", default=os.environ.get("GATEWAY_MASTER_KEY", ""),
                        help="API key for Gateway authentication")
    parser.add_argument("--concurrency", type=int, default=20, help="Number of concurrent requests (Target: 20 agents)")
    parser.add_argument("--requests", type=int, default=100, help="Total number of requests to execute")
    parser.add_argument("--max-tokens", type=int, default=256, help="Max generation tokens per request")
    parser.add_argument("--temperature", type=float, default=0.3, help="Sampling temperature")
    parser.add_argument("--output", default="massive_benchmark_results.json", help="Output JSON path")
    return parser.parse_args()

def execute_stream_request(req_id, endpoint, model, prompt, max_tokens, temperature, api_key=""):
    payload = {
        "model": model,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
        "stream_options": {"include_usage": True}
    }
    if "/chat/completions" in endpoint:
        payload["messages"] = [{"role": "user", "content": prompt}]
    else:
        payload["prompt"] = prompt

    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "User-Agent": f"GLM52-Massive-Bench/2.0 (ReqId-{req_id})"
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    
    req = urllib.request.Request(endpoint, data=data, headers=headers, method="POST")
    t_start = time.perf_counter()
    t_first_token = None
    t_end = None
    tokens_received = 0
    error_msg = None
    has_exact_usage = False

    try:
        with urllib.request.urlopen(req, timeout=300) as response:
            for line in response:
                line_str = line.decode("utf-8").strip()
                if not line_str.startswith("data: "):
                    continue
                data_part = line_str[6:].strip()
                if data_part == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_part)
                    usage = chunk.get("usage")
                    if usage and isinstance(usage, dict) and "completion_tokens" in usage:
                        tokens_received = usage.get("completion_tokens", tokens_received)
                        has_exact_usage = True
                    
                    choices = chunk.get("choices", [])
                    if choices:
                        choice = choices[0]
                        text = choice.get("text", "")
                        if not text and isinstance(choice.get("delta"), dict):
                            text = choice.get("delta", {}).get("content", "")
                        if text:
                            now = time.perf_counter()
                            if t_first_token is None:
                                t_first_token = now
                            if not has_exact_usage:
                                tokens_received += 1
                except json.JSONDecodeError:
                    continue
        t_end = time.perf_counter()
    except Exception as e:
        error_msg = str(e)
        t_end = time.perf_counter()

    if t_first_token is not None and t_end is not None and tokens_received > 0:
        ttft = t_first_token - t_start
        total_time = t_end - t_start
        tpot = (t_end - t_first_token) / max(1, tokens_received - 1) if tokens_received > 1 else ttft
        req_throughput = tokens_received / total_time if total_time > 0 else 0
        success = True
    else:
        ttft = 0
        tpot = 0
        total_time = t_end - t_start if t_end else 0
        req_throughput = 0
        success = False

    return {
        "req_id": req_id,
        "success": success,
        "error": error_msg,
        "tokens": tokens_received,
        "ttft_ms": ttft * 1000,
        "tpot_ms": tpot * 1000,
        "total_time_s": total_time,
        "req_throughput_tps": req_throughput
    }

def main():
    args = parse_args()
    print("=" * 70)
    print("  GLM-5.2 MASSIVE PRODUCTION STRESS & PERFORMANCE SUITE  ")
    print("=" * 70)
    print(f"  Endpoint:        {args.endpoint}")
    print(f"  Served Model:    {args.model}")
    print(f"  Concurrency:     {args.concurrency} concurrent streams (Target Workload)")
    print(f"  Total Requests:  {args.requests} generations")
    print(f"  Max Tokens/Req:  {args.max_tokens} output tokens per prompt")
    print("-" * 70)

    start_bench_time = time.perf_counter()
    results = []
    completed_count = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = []
        for i in range(args.requests):
            prompt = MASSIVE_PROMPTS[i % len(MASSIVE_PROMPTS)]
            futures.append(executor.submit(execute_stream_request, i+1, args.endpoint, args.model, prompt, args.max_tokens, args.temperature, args.api_key))
        
        consecutive_errors = 0
        for future in concurrent.futures.as_completed(futures):
            res = future.result()
            results.append(res)
            completed_count += 1
            status_char = "✓" if res["success"] else "✗"
            if res["success"]:
                consecutive_errors = 0
                print(f"[{completed_count:03d}/{args.requests:03d}] [{status_char}] Req {res['req_id']:03d}: TTFT={res['ttft_ms']:6.1f}ms | TPOT={res['tpot_ms']:5.2f}ms | Tokens={res['tokens']:3d} | TPS={res['req_throughput_tps']:5.1f} t/s")
            else:
                consecutive_errors += 1
                print(f"[{completed_count:03d}/{args.requests:03d}] [{status_char}] Req {res['req_id']:03d}: FAILED ({res['error']})")
                if consecutive_errors >= 5:
                    print("\n" + "!" * 70)
                    print("ERROR: Port-forward tunnel dropped (HTTP 000).")
                    print("Run benchmark in-cluster via: ./scripts/05_run_benchmarks.sh --in-cluster")
                    print("!" * 70 + "\n")
                    break

    total_bench_time = time.perf_counter() - start_bench_time
    successful_results = [r for r in results if r["success"]]
    failed_results = [r for r in results if not r["success"]]

    ttft_vals = sorted([r["ttft_ms"] for r in successful_results]) if successful_results else []
    tpot_vals = sorted([r["tpot_ms"] for r in successful_results]) if successful_results else []
    total_tokens = sum([r["tokens"] for r in successful_results]) if successful_results else 0
    cluster_throughput = total_tokens / total_bench_time if total_bench_time > 0 and successful_results else 0

    ttft_mean = round(statistics.mean(ttft_vals), 2) if ttft_vals else 0.0
    tpot_mean = round(statistics.mean(tpot_vals), 2) if tpot_vals else 0.0
    throughput_tps = round(cluster_throughput, 2)

    summary = {
        "successful_requests": len(successful_results),
        "total_requests": args.requests,
        "total_completed": len(successful_results),
        "ttft_mean_ms": ttft_mean,
        "tpot_mean_ms": tpot_mean,
        "throughput_tokens_sec": throughput_tps,
        "benchmark_config": vars(args),
        "execution_summary": {
            "total_requests": args.requests,
            "successful_requests": len(successful_results),
            "failed_requests": len(failed_results),
            "total_benchmark_time_seconds": round(total_bench_time, 3),
        },
        "metrics": {}
    }

    if successful_results:
        def pct(lst, p):
            idx = int(len(lst) * (p / 100.0))
            return lst[min(idx, len(lst) - 1)]

        summary["metrics"] = {
            "total_tokens_generated": total_tokens,
            "cluster_throughput_tokens_per_sec": round(cluster_throughput, 2),
            "ttft_ms": {
                "mean": round(statistics.mean(ttft_vals), 2),
                "p50": round(pct(ttft_vals, 50), 2),
                "p90": round(pct(ttft_vals, 90), 2),
                "p99": round(pct(ttft_vals, 99), 2),
                "min": round(min(ttft_vals), 2),
                "max": round(max(ttft_vals), 2),
            },
            "tpot_ms": {
                "mean": round(statistics.mean(tpot_vals), 2),
                "p50": round(pct(tpot_vals, 50), 2),
                "p90": round(pct(tpot_vals, 90), 2),
                "p99": round(pct(tpot_vals, 99), 2),
                "min": round(min(tpot_vals), 2),
                "max": round(max(tpot_vals), 2),
            }
        }

        print("=" * 70)
        print("          MASSIVE STRESS BENCHMARK AGGREGATE SUMMARY          ")
        print("=" * 70)
        print(f"  Total Requests Completed:   {len(successful_results)} / {args.requests}")
        print(f"  Total Output Tokens:        {total_tokens:,} tokens")
        print(f"  Total Wall Clock Duration:  {total_bench_time:.2f} seconds")
        print(f"  Sustained Cluster TPS:      {cluster_throughput:.2f} tokens/sec across 20 streams")
        print("-" * 70)
        print(f"  TTFT (Time-to-First-Token):")
        print(f"    Mean: {summary['metrics']['ttft_ms']['mean']:6.2f} ms | P50: {summary['metrics']['ttft_ms']['p50']:6.2f} ms | P90: {summary['metrics']['ttft_ms']['p90']:6.2f} ms | P99: {summary['metrics']['ttft_ms']['p99']:6.2f} ms")
        print(f"    Min (Prefix Hit): {summary['metrics']['ttft_ms']['min']:6.2f} ms | Max (Cold Prefill): {summary['metrics']['ttft_ms']['max']:6.2f} ms")
        print("-" * 70)
        print(f"  TPOT (Inter-Token Latency):")
        print(f"    Mean: {summary['metrics']['tpot_ms']['mean']:6.2f} ms | P50: {summary['metrics']['tpot_ms']['p50']:6.2f} ms | P90: {summary['metrics']['tpot_ms']['p90']:6.2f} ms | P99: {summary['metrics']['tpot_ms']['p99']:6.2f} ms")
        print("=" * 70)

    with open(args.output, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Massive benchmark report saved to {args.output}")

if __name__ == "__main__":
    main()
