#!/usr/bin/env python3
"""
GLM-5.2 (NVFP4 MoE) Production Performance Benchmark Suite
Executes high-concurrency synthetic load testing against vLLM serving endpoints on NVIDIA Blackwell GKE clusters.
Measures Time-to-First-Token (TTFT), Time-Per-Output-Token (TPOT / Inter-Token Latency), and Total Cluster Throughput.
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

ENTERPRISE_PROMPTS = [
    "Explain the architectural advantages of using 4-bit NVFP4 quantization and block scaling factors on NVIDIA Blackwell GPUs.",
    "Derive the exact memory footprint equations for PagedAttention Key-Value cache in Grouped-Query Attention models.",
    "Detail how intra-node NVLink tensor parallelism eliminates inter-GPU communication bottlenecks during MoE routing.",
    "What are the primary tradeoffs between Multi-Token Prediction (MTP-1) speculative decoding and standard autoregressive sampling?",
    "Describe the failover and recovery behavior of an active vLLM serving deployment during spot preemption events.",
    "Analyze the latency benefits of using NVMe-over-Fabric Hyperdisk ML read-only shared storage compared to network hydration.",
    "How does custom metric Horizontal Pod Autoscaling based on PagedAttention KV cache utilization prevent OOM drops?",
    "Compare the computational density and HBM3e bandwidth of 8x B200 HGX nodes versus prior H100 generation clusters."
]

def parse_args():
    parser = argparse.ArgumentParser(description="GLM-5.2 Enterprise Performance Benchmark")
    parser.add_argument("--endpoint", default="http://localhost:8000/v1/completions",
                        help="vLLM completions endpoint URL")
    parser.add_argument("--model", default="glm-5.2-moe", help="Served model ID")
    parser.add_argument("--api-key", default=os.environ.get("GATEWAY_MASTER_KEY", ""),
                        help="API key for Gateway authentication")
    parser.add_argument("--concurrency", type=int, default=8, help="Number of concurrent requests")
    parser.add_argument("--requests", type=int, default=16, help="Total number of requests to execute")
    parser.add_argument("--max-tokens", type=int, default=128, help="Max generation tokens per request")
    parser.add_argument("--temperature", type=float, default=0.2, help="Sampling temperature")
    parser.add_argument("--output", default="benchmark_results.json", help="Output JSON path")
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
        "User-Agent": f"GLM52-Benchmark-Client/1.0 (ReqId-{req_id})"
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
        with urllib.request.urlopen(req, timeout=120) as response:
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
    print(f"=== GLM-5.2 Production Performance Benchmark Suite ===")
    print(f"Endpoint:    {args.endpoint}")
    print(f"Model:       {args.model}")
    print(f"Concurrency: {args.concurrency} worker threads")
    print(f"Requests:    {args.requests} total runs")
    print(f"Max Tokens:  {args.max_tokens}")
    print("-" * 55)

    start_bench_time = time.perf_counter()
    results = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = []
        for i in range(args.requests):
            prompt = ENTERPRISE_PROMPTS[i % len(ENTERPRISE_PROMPTS)]
            futures.append(executor.submit(execute_stream_request, i+1, args.endpoint, args.model, prompt, args.max_tokens, args.temperature, args.api_key))
        
        consecutive_errors = 0
        for future in concurrent.futures.as_completed(futures):
            res = future.result()
            results.append(res)
            status_char = "✓" if res["success"] else "✗"
            if res["success"]:
                consecutive_errors = 0
                print(f"[{status_char}] Req {res['req_id']:02d}: TTFT={res['ttft_ms']:6.2f}ms | TPOT={res['tpot_ms']:6.2f}ms | Tokens={res['tokens']} | Throughput={res['req_throughput_tps']:6.2f} t/s")
            else:
                consecutive_errors += 1
                print(f"[{status_char}] Req {res['req_id']:02d}: FAILED ({res['error']})")
                if consecutive_errors >= 5:
                    print("\n" + "!" * 55)
                    print("ERROR: Port-forward tunnel dropped (HTTP 000).")
                    print("Run benchmark in-cluster via: ./scripts/05_run_benchmarks.sh --in-cluster")
                    print("!" * 55 + "\n")
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

        print("-" * 55)
        print("=== BENCHMARK AGGREGATE SUMMARY ===")
        print(f"Total Tokens Generated: {total_tokens}")
        print(f"Total Wall Clock Time:  {total_bench_time:.2f} s")
        print(f"Aggregate Cluster TPS:  {cluster_throughput:.2f} tokens/s")
        print(f"TTFT (Time to 1st Token): Mean={summary['metrics']['ttft_ms']['mean']}ms | P50={summary['metrics']['ttft_ms']['p50']}ms | P90={summary['metrics']['ttft_ms']['p90']}ms | P99={summary['metrics']['ttft_ms']['p99']}ms")
        print(f"TPOT (Inter-Token Lat):   Mean={summary['metrics']['tpot_ms']['mean']}ms | P50={summary['metrics']['tpot_ms']['p50']}ms | P90={summary['metrics']['tpot_ms']['p90']}ms | P99={summary['metrics']['tpot_ms']['p99']}ms")
        print("-" * 55)

    with open(args.output, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Benchmark report saved to {args.output}")

if __name__ == "__main__":
    main()
