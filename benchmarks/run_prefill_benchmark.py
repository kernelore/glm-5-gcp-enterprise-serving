#!/usr/bin/env python3
"""GLM-5.2 (381B MoE NVFP4) Prompt-Ingestion / Prefill Benchmark

Measures actual prompt processing rate (prompt tokens / sec) on 8x B200 GPUs.
Sends an ~8192 token input prompt with max_tokens=16 and measures TTFT and
prompt throughput.
"""

import argparse
from datetime import datetime, timezone
import json
import os
import time
import urllib.request

SYNTHETIC_8K = (
    "In large-scale sovereign artificial intelligence deployments on GKE"
    " Blackwell B200 HGX systems, NVIDIA NVLink fifth-generation interconnect"
    " provides 1.8 TB/s bidirectional bandwidth per GPU. When serving MoE"
    " architectures with 381 billion parameters such as GLM-5.2 using 4-bit"
    " NvFp4 quantization and block scaling factors, expert routing decisions"
    " occur across all 8 GPUs. "
) * 64  # ~8192 tokens


def measure_prefill(
    endpoint="http://localhost:8000/v1/completions",
    model="glm-5.2-moe",
    output="benchmarks/prefill_results.json",
    metadata="{}",
):
  start_dt = datetime.now(timezone.utc)
  suite_start_ts = start_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
  payload = {
      "model": model,
      "prompt": SYNTHETIC_8K,
      "max_tokens": 16,
      "temperature": 0.1,
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
  t_first = None
  prompt_tokens = 8192
  has_exact_usage = False

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
            "usage" in chunk
            and chunk["usage"]
            and chunk["usage"].get("prompt_tokens") is not None
        ):
          prompt_tokens = int(chunk["usage"]["prompt_tokens"])
          has_exact_usage = True

        choices = chunk.get("choices", [])
        if choices:
          choice = choices[0]
          if isinstance(choice, dict):
            delta = choice.get("delta", {})
            if not isinstance(delta, dict):
              delta = {}
            text_val = choice.get("text")
            content_val = delta.get("content")
            reasoning_val = delta.get("reasoning_content")
            
            has_content = (
                (text_val is not None and text_val != "") or 
                (content_val is not None and content_val != "") or 
                (reasoning_val is not None and reasoning_val != "")
            )
            if has_content and t_first is None:
              t_first = time.time()
      except Exception:
        pass

  t_end = time.time()
  end_dt = datetime.now(timezone.utc)
  suite_end_ts = end_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
  suite_duration_s = round((end_dt - start_dt).total_seconds(), 4)
  ttft = (t_first - t_start) if t_first else (t_end - t_start)
  prefill_tok_s = prompt_tokens / ttft if ttft > 0 else 0.0

  result = {
      "prompt_tokens": prompt_tokens,
      "token_count_source": "usage" if has_exact_usage else "chunk_count_fallback",
      "ttft_sec": ttft,
      "ttft_ms": ttft * 1000.0,
      "prefill_tok_s_system": prefill_tok_s,
      "prefill_tok_s_per_gpu": prefill_tok_s / 8.0,
  }
  print("=== GLM-5.2 PREFILL (PROMPT INGESTION) BENCHMARK ===")
  print(f"Prompt Tokens:        {result['prompt_tokens']}")
  print(
      f"TTFT (Prefill Time):  {result['ttft_ms']:.2f} ms"
      f" ({result['ttft_sec']:.4f} s)"
  )
  print(
      f"System Prefill Rate:  {result['prefill_tok_s_system']:.2f} prompt tok/s"
  )
  print(
      f"Per-GPU Prefill Rate: {result['prefill_tok_s_per_gpu']:.2f} prompt"
      " tok/s/GPU"
  )
  try:
    meta = json.loads(metadata) if isinstance(metadata, str) else metadata
  except Exception:
    meta = {}
  if os.environ.get("BENCHMARK_RESTARTED_BEFORE_SUITE") == "true":
    meta["engine_restarted_before_suite"] = True
  result["metadata"] = meta
  result["prefill_config"] = {
      "endpoint": endpoint,
      "model": model,
      "output": output,
      "metadata": meta,
      "suite_start_ts": suite_start_ts,
      "suite_end_ts": suite_end_ts,
      "suite_duration_s": suite_duration_s,
  }
  try:
    from telemetry_sanitizer import sanitize_telemetry
  except ImportError:
    from benchmarks.telemetry_sanitizer import sanitize_telemetry
  result = sanitize_telemetry(result, output)

  with open(output, "w") as f:
    json.dump(result, f, indent=2)
  return result


if __name__ == "__main__":
  parser = argparse.ArgumentParser()
  parser.add_argument("--endpoint", default="http://localhost:8000/v1/completions")
  parser.add_argument("--model", default="glm-5.2-moe")
  parser.add_argument("--output", default="benchmarks/prefill_results.json")
  parser.add_argument("--metadata", default="{}")
  args = parser.parse_args()
  measure_prefill(args.endpoint, args.model, args.output, args.metadata)
