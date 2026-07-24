#!/usr/bin/env python3
"""GLM-5.2 (381B MoE NVFP4) Prompt-Ingestion / Prefill Benchmark

Measures actual prompt processing rate (prompt tokens / sec) on 8x B200 GPUs.
Sends an ~8192 token input prompt with max_tokens=16 and measures TTFT and
prompt throughput.
"""

import argparse
import json
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
            and chunk["choices"][0].get("text")
        ):
          if t_first is None:
            t_first = time.time()
        if (
            "usage" in chunk
            and chunk["usage"]
            and chunk["usage"].get("prompt_tokens")
        ):
          prompt_tokens = chunk["usage"]["prompt_tokens"]
      except Exception:
        pass

  t_end = time.time()
  ttft = (t_first - t_start) if t_first else (t_end - t_start)
  prefill_tok_s = prompt_tokens / ttft if ttft > 0 else 0.0

  result = {
      "prompt_tokens": prompt_tokens,
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
  result["metadata"] = meta
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
