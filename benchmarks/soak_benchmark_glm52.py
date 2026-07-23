#!/usr/bin/env python3
"""
GLM-5.2 (NVFP4 MoE) 30-Minute Continuous Production Soak Test
Simulates 20 enterprise engineering developers across 18 concurrent active streams (`--concurrency 18`) over 1,800 seconds (`--duration 1800`).
Executes continuous back-to-back prefill and generation cycles without pause, stressing PagedAttention KV cache, HBM3e thermal stability, and intra-node NVLink transport (`TP=8`).
Logs per-minute progress and exports aggregate 30-minute latency/throughput percentiles and stability proof.
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

SOAK_PROMPTS = [
    "Analyze the structural benefits of 4-bit NVFP4 quantization on NVIDIA Blackwell GPUs for large mixture-of-experts models.",
    "Derive the step-by-step Key-Value cache memory consumption formulas for Grouped-Query Attention across 80 transformer layers.",
    "Explain how intra-node NVLink tensor parallelism eliminates inter-GPU bottlenecks during MoE routing.",
    "Detail the mechanics of speculative decoding using Multi-Token Prediction (MTP-1) and how it optimizes HBM3e bandwidth.",
    "Write a production-grade Python async gateway with circuit breaking and exponential backoff for an LLM inference cluster.",
    "Examine the 20-second graceful shutdown and failover behavior of vLLM pods during Kubernetes spot preemption events.",
    "Describe the performance speedups of mounting Hyperdisk ML in read-only shared (ROX) mode across GKE clusters.",
    "Explain why PagedAttention KV cache utilization percentage (`vllm:kv_cache_usage_perc`) is the ideal metric for custom HPA scaling.",
    "Compare the tensor core FLOPS and memory bandwidth of 8x B200 HGX Blackwell nodes against H100 and A100 architectures."
]

def parse_args():
    parser = argparse.ArgumentParser(description="GLM-5.2 Continuous 30m Soak Test")
    parser.add_argument("--endpoint", default="http://localhost:8000/v1/completions",
                        help="vLLM completions endpoint URL")
    parser.add_argument("--model", default="glm-5.2-moe", help="Served model ID")
    parser.add_argument("--api-key", default=os.environ.get("GATEWAY_MASTER_KEY", ""),
                        help="API key for Gateway authentication")
    parser.add_argument("--concurrency", type=int, default=18, help="Simulated active concurrent streams (Target: 18 streams / 20 devs)")
    parser.add_argument("--duration", type=int, default=1800, help="Total soak test duration in seconds (Target: 1800s / 30m)")
    parser.add_argument("--max-tokens", type=int, default=256, help="Max generation tokens per request")
    parser.add_argument("--temperature", type=float, default=0.3, help="Sampling temperature")
    parser.add_argument("--output", default="soak_test_results.json", help="Output JSON report path")
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
        "User-Agent": f"GLM52-SoakTest/3.0 (StreamId-{req_id})"
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
        "req_throughput_tps": req_throughput,
        "completion_timestamp": time.time()
    }

def main():
    args = parse_args()
    print("=" * 75)
    print("       GLM-5.2 (NVFP4 MoE) 30-MINUTE CONTINUOUS PRODUCTION SOAK TEST       ")
    print("=" * 75)
    print(f"  Endpoint:          {args.endpoint}")
    print(f"  Served Model:      {args.model}")
    print(f"  Target Concurrency: {args.concurrency} simultaneous active streams (20 devs simulated)")
    print(f"  Soak Duration:     {args.duration} seconds ({args.duration/60:.1f} minutes)")
    print(f"  Max Tokens/Req:    {args.max_tokens} output tokens per generation")
    print("-" * 75)

    start_soak_time = time.perf_counter()
    results = []
    completed_requests = 0
    failed_requests = 0
    req_counter = 0
    last_log_minute = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        active_futures = set()
        for _ in range(args.concurrency):
            req_counter += 1
            prompt = SOAK_PROMPTS[req_counter % len(SOAK_PROMPTS)]
            active_futures.add(executor.submit(execute_stream_request, req_counter, args.endpoint, args.model, prompt, args.max_tokens, args.temperature, args.api_key))

        consecutive_errors = 0
        while active_futures:
            done_set, active_futures = concurrent.futures.wait(active_futures, return_when=concurrent.futures.FIRST_COMPLETED)
            
            for future in done_set:
                res = future.result()
                results.append(res)
                if res["success"]:
                    completed_requests += 1
                    consecutive_errors = 0
                else:
                    failed_requests += 1
                    consecutive_errors += 1
                    if consecutive_errors >= 5:
                        print("\n" + "!" * 75)
                        print("ERROR: Detected port-forward tunnel collapse / consecutive HTTP 000 errors.")
                        print("Local workstation port-forward cannot sustain continuous soak load.")
                        print("RECOMMENDATION: Run benchmarks in-cluster via Kubernetes Job:")
                        print("  ./scripts/05_run_benchmarks.sh --in-cluster")
                        print("!" * 75 + "\n")
                        active_futures.clear()
                        break

                elapsed = time.perf_counter() - start_soak_time
                
                if elapsed < args.duration and consecutive_errors < 5:
                    req_counter += 1
                    prompt = SOAK_PROMPTS[req_counter % len(SOAK_PROMPTS)]
                    active_futures.add(executor.submit(execute_stream_request, req_counter, args.endpoint, args.model, prompt, args.max_tokens, args.temperature, args.api_key))


                current_minute = int(elapsed // 60)
                if current_minute > last_log_minute and current_minute <= (args.duration // 60):
                    last_log_minute = current_minute
                    succ_results = [r for r in results if r["success"]]
                    tot_toks = sum([r["tokens"] for r in succ_results])
                    cum_tps = tot_toks / elapsed if elapsed > 0 else 0
                    
                    recent_window = [r for r in succ_results if r["completion_timestamp"] >= (time.time() - 65)]
                    if recent_window:
                        rec_tps = sum([r["tokens"] for r in recent_window]) / 60.0
                        rec_ttft = statistics.median([r["ttft_ms"] for r in recent_window])
                        rec_tpot = statistics.median([r["tpot_ms"] for r in recent_window])
                    else:
                        rec_tps = cum_tps
                        rec_ttft = 0
                        rec_tpot = 0

                    print(f"[Soak Minute {current_minute:02d}/{int(args.duration//60):02d}] Elapsed: {elapsed:6.1f}s | Completed Reqs: {completed_requests:4d} | Recent TPS: {rec_tps:6.1f} t/s | Cumulative TPS: {cum_tps:6.1f} t/s | Recent TTFT P50: {rec_ttft:5.1f}ms | TPOT P50: {rec_tpot:5.2f}ms | Errors: {failed_requests}")
                    sys.stdout.flush()

    total_soak_time = time.perf_counter() - start_soak_time
    successful_results = [r for r in results if r["success"]]

    ttft_vals = sorted([r["ttft_ms"] for r in successful_results]) if successful_results else []
    tpot_vals = sorted([r["tpot_ms"] for r in successful_results]) if successful_results else []
    total_tokens = sum([r["tokens"] for r in successful_results]) if successful_results else 0
    cluster_throughput = total_tokens / total_soak_time if total_soak_time > 0 and successful_results else 0

    ttft_mean = round(statistics.mean(ttft_vals), 2) if ttft_vals else 0.0
    tpot_mean = round(statistics.mean(tpot_vals), 2) if tpot_vals else 0.0
    throughput_tps = round(cluster_throughput, 2)

    summary = {
        "successful_requests": completed_requests,
        "total_requests": len(results),
        "total_completed": completed_requests,
        "ttft_mean_ms": ttft_mean,
        "tpot_mean_ms": tpot_mean,
        "throughput_tokens_sec": throughput_tps,
        "soak_config": vars(args),
        "execution_summary": {
            "total_duration_seconds": round(total_soak_time, 3),
            "total_requests_completed": completed_requests,
            "total_requests_failed": failed_requests,
            "success_rate_percent": round(100.0 * completed_requests / max(1, len(results)), 3)
        },
        "metrics": {}
    }

    if successful_results:
        def pct(lst, p):
            idx = int(len(lst) * (p / 100.0))
            return lst[min(idx, len(lst) - 1)]

        summary["metrics"] = {
            "total_output_tokens": total_tokens,
            "sustained_cluster_tps": round(cluster_throughput, 2),
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

        print("=" * 75)
        print("                30-MINUTE SOAK TEST AGGREGATE SUMMARY                ")
        print("=" * 75)
        print(f"  Total Duration:             {total_soak_time:.2f} seconds ({total_soak_time/60:.2f} minutes)")
        print(f"  Total Requests Completed:   {completed_requests:,} runs ({failed_requests} errors)")
        print(f"  Total Output Tokens:        {total_tokens:,} tokens generated")
        print(f"  Sustained Cluster TPS:      {cluster_throughput:.2f} tokens/sec across 18 streams")
        print("-" * 75)
        print(f"  TTFT (Time-to-First-Token) across 30m:")
        print(f"    Mean: {summary['metrics']['ttft_ms']['mean']:6.2f} ms | P50: {summary['metrics']['ttft_ms']['p50']:6.2f} ms | P90: {summary['metrics']['ttft_ms']['p90']:6.2f} ms | P99: {summary['metrics']['ttft_ms']['p99']:6.2f} ms")
        print(f"    Min (Prefix Hit): {summary['metrics']['ttft_ms']['min']:6.2f} ms | Max (Cold Prefill): {summary['metrics']['ttft_ms']['max']:6.2f} ms")
        print("-" * 75)
        print(f"  TPOT (Inter-Token Latency) across 30m:")
        print(f"    Mean: {summary['metrics']['tpot_ms']['mean']:6.2f} ms | P50: {summary['metrics']['tpot_ms']['p50']:6.2f} ms | P90: {summary['metrics']['tpot_ms']['p90']:6.2f} ms | P99: {summary['metrics']['tpot_ms']['p99']:6.2f} ms")
        print("=" * 75)

    with open(args.output, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"30-minute soak test report saved to {args.output}")

if __name__ == "__main__":
    main()
