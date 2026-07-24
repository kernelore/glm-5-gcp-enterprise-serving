#!/usr/bin/env python3
"""GLM-5.2 (381B MoE NVFP4) Saturation & Throughput-Ceiling Sweep

Measures peak GPU-generated aggregate throughput, per-user tok/s, TTFT/TPOT
percentiles,
and the interactive SLA knee across concurrency levels c in [1, 8, 16, 32, 64].
Connects directly to vLLM on port 8000 to guarantee 0% cache hit rate.
"""

import argparse
import concurrent.futures
import json
import random
import statistics
import string
import time
import urllib.error
import urllib.request

SYNTHETIC_BASE_1K = (
    "In large-scale distributed artificial intelligence deployments on"
    " sovereign cloud infrastructure, NVIDIA Blackwell B200 HGX systems provide"
    " 8 GPUs connected via fifth-generation NVLink with 1.8 TB/s bidirectional"
    " bandwidth per GPU. When serving MoE architectures with 381 billion"
    " parameters such as GLM-5.2 using 4-bit NvFp4 quantization and block"
    " scaling factors, expert routing decisions occur across all 8 GPUs with"
    " minimal communication latency. Furthermore, the ReadOnlyMany Hyperdisk ML"
    " storage architecture enables multi-node horizontal pod scaling without"
    " redundant checkpoint downloads. "
) * 8  # ~1024 tokens (~6400 chars)


def generate_unique_prompt(idx, c):
  nonce = "".join(random.choices(string.ascii_letters + string.digits, k=16))
  return f"[Sweep C={c} ReqId={idx} Nonce={nonce}] {SYNTHETIC_BASE_1K}"


def execute_single_request(
    req_idx, c, endpoint, model, max_tokens, temperature
):
  prompt = generate_unique_prompt(req_idx, c)
  payload = {
      "model": model,
      "prompt": prompt,
      "max_tokens": max_tokens,
      "temperature": temperature,
      "ignore_eos": True,
      "stream": True,
      "stream_options": {"include_usage": True},
  }
  req_body = json.dumps(payload).encode("utf-8")
  req = urllib.request.Request(
      endpoint,
      data=req_body,
      headers={
          "Content-Type": "application/json",
          "Accept": "text/event-stream",
      },
      method="POST",
  )

  t_start = time.time()
  t_first_token = None
  token_timestamps = []
  generated_tokens = 0

  try:
    with urllib.request.urlopen(req, timeout=300) as resp:
      for line in resp:
        decoded = line.decode("utf-8").strip()
        if not decoded.startswith("data: "):
          continue
        data_str = decoded[6:]
        if data_str == "[DONE]":
          break
        try:
          chunk = json.loads(data_str)
          if (
              "choices" in chunk
              and chunk["choices"]
              and "text" in chunk["choices"][0]
          ):
            txt = chunk["choices"][0].get("text")
            if txt is not None and len(txt) > 0:
              now = time.time()
              if t_first_token is None:
                t_first_token = now
              token_timestamps.append(now)
              generated_tokens += 1
          elif "usage" in chunk and chunk["usage"]:
            if chunk["usage"].get("completion_tokens"):
              generated_tokens = chunk["usage"]["completion_tokens"]
        except Exception:
          pass
    t_end = time.time()
    ttft_ms = (
        (t_first_token - t_start) * 1000.0
        if t_first_token
        else (t_end - t_start) * 1000.0
    )
    tpots = []
    if len(token_timestamps) > 1:
      tpots = [
          (token_timestamps[i] - token_timestamps[i - 1]) * 1000.0
          for i in range(1, len(token_timestamps))
      ]
    mean_tpot = statistics.mean(tpots) if tpots else 0.0
    duration = t_end - t_start
    throughput = generated_tokens / duration if duration > 0 else 0.0
    return {
        "success": True,
        "ttft_ms": ttft_ms,
        "mean_tpot_ms": mean_tpot,
        "all_tpots_ms": tpots,
        "tokens": generated_tokens,
        "duration": duration,
        "throughput": throughput,
    }
  except Exception as e:
    return {"success": False, "error": str(e)}


def run_sweep_concurrency(c, requests_per_c, endpoint, model, max_tokens):
  print(f"\n============================================================")
  print(
      f"Executing Saturation Sweep at Concurrency = {c} ({requests_per_c} total"
      " requests)..."
  )
  print(f"============================================================")

  results = []
  start_time = time.time()
  with concurrent.futures.ThreadPoolExecutor(max_workers=c) as executor:
    futures = [
        executor.submit(
            execute_single_request, i, c, endpoint, model, max_tokens, 0.2
        )
        for i in range(requests_per_c)
    ]
    for f in concurrent.futures.as_completed(futures):
      results.append(f.result())
  total_duration = time.time() - start_time

  successful = [r for r in results if r["success"]]
  failed = [r for r in results if not r["success"]]
  err_rate = (len(failed) / len(results)) * 100.0 if results else 100.0

  if successful:
    ttfts = sorted([r["ttft_ms"] for r in successful])
    tpots = []
    for r in successful:
      tpots.extend([val for val in r.get("all_tpots_ms", []) if val > 0])
    tpots.sort()
    total_tokens = sum(r["tokens"] for r in successful)
    agg_tok_s = total_tokens / total_duration
    per_gpu_tok_s = agg_tok_s / 8.0
    per_user_tok_s = agg_tok_s / c

    def pctl(arr, p):
      if not arr:
        return 0.0
      idx = int(len(arr) * p / 100.0)
      return arr[min(idx, len(arr) - 1)]

    summary = {
        "concurrency": c,
        "requests": len(results),
        "successful": len(successful),
        "error_rate_pct": err_rate,
        "total_tokens": total_tokens,
        "total_duration_sec": total_duration,
        "aggregate_tok_s": agg_tok_s,
        "per_gpu_tok_s": per_gpu_tok_s,
        "per_user_tok_s": per_user_tok_s,
        "ttft_ms": {
            "mean": statistics.mean(ttfts),
            "p50": pctl(ttfts, 50),
            "p90": pctl(ttfts, 90),
            "p99": pctl(ttfts, 99),
        },
        "tpot_ms": {
            "mean": statistics.mean(tpots) if tpots else 0.0,
            "p50": pctl(tpots, 50),
            "p90": pctl(tpots, 90),
            "p99": pctl(tpots, 99),
        },
    }
    print(
        f"  Agg Throughput:  {agg_tok_s:.2f} tok/s ({per_gpu_tok_s:.2f}"
        " tok/s/GPU)"
    )
    print(f"  Per-User TPS:    {per_user_tok_s:.2f} tok/s")
    print(
        f"  TTFT (P50/P90):  {summary['ttft_ms']['p50']:.1f} ms /"
        f" {summary['ttft_ms']['p90']:.1f} ms"
    )
    print(
        f"  TPOT (P50/P90):  {summary['tpot_ms']['p50']:.2f} ms /"
        f" {summary['tpot_ms']['p90']:.2f} ms"
    )
    print(f"  Error Rate:      {err_rate:.1f}%")
    return summary
  else:
    print(f"  All requests failed at Concurrency={c}!")
    return {"concurrency": c, "error_rate_pct": 100.0, "aggregate_tok_s": 0.0}


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument(
      "--endpoint", default="http://localhost:8000/v1/completions"
  )
  parser.add_argument("--model", default="glm-5.2-moe")
  parser.add_argument(
      "--output", default="benchmarks/saturation_sweep_results.json"
  )
  parser.add_argument("--metadata", default="{}", help="JSON metadata string")
  args = parser.parse_args()

  sweep_levels = [1, 8, 16, 32, 64]
  sweep_results = []

  for c in sweep_levels:
    try:
      base_url = args.endpoint.split("/v1/")[0].split("/inference/")[0].rstrip("/")
      urllib.request.urlopen(urllib.request.Request(f"{base_url}/flush_cache", method="POST"), timeout=2)
    except Exception:
      pass
    requests = max(c * 2, 8)  # Run at least 2 full waves per concurrency level
    res = run_sweep_concurrency(
        c, requests, args.endpoint, args.model, max_tokens=1024
    )
    sweep_results.append(res)
    time.sleep(2)

  try:
    meta = json.loads(args.metadata) if isinstance(args.metadata, str) else args.metadata
  except Exception:
    meta = {}
  with open(args.output, "w") as f:
    json.dump({"metadata": meta, "sweep_results": sweep_results}, f, indent=2)
  print(f"\nSaved full saturation sweep results to {args.output}")


if __name__ == "__main__":
  main()
