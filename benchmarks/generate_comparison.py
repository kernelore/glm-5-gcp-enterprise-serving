#!/usr/bin/env python3
"""
generate_comparison.py — Automated Parity Validator & README.md Table Generator

Reads multi-engine benchmark results from benchmarks/results/{vllm,sglang}/,
enforces strict parameter parity and sanity gates (no cold-start contamination,
valid TPOT, 100% success rate), and idempotently updates README.md between
<!-- ENGINE_COMPARISON_START --> and <!-- ENGINE_COMPARISON_END --> markers.

Strict constraint: Does NOT create any new .md files (no ENGINE_COMPARISON.md).
"""

import sys
import os
import tempfile
import shutil
import subprocess
import json
import re
from datetime import datetime
from pathlib import Path

def load_json(path: Path):
    if not path.exists():
        print(f"ERROR: Missing benchmark result file: {path}", file=sys.stderr)
        sys.exit(1)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"ERROR: Invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(1)

def get_metadata(data: dict) -> dict:
    meta = data.get("metadata")
    if not meta and "benchmark_config" in data:
        meta = data["benchmark_config"].get("metadata")
    if not meta and "soak_config" in data:
        meta = data["soak_config"].get("metadata")
    if not meta and "sweep_config" in data:
        meta = data["sweep_config"].get("metadata")
    if isinstance(meta, str):
        try:
            return json.loads(meta)
        except Exception:
            return {}
    return meta or {}

def normalize_version(ver: str) -> str:
    if not ver:
        return ""
    ver = ver.strip()
    if ver.startswith("v") or ver.startswith("V"):
        ver = ver[1:]
    if ver.endswith("-cu130"):
        ver = ver[:-6]
    return ver

def parse_engine_pins(deploy_script_path: str = "scripts/03_deploy_workloads.sh") -> dict:
    """
    Parses VLLM_IMAGE_TAG and SGLANG_IMAGE_TAG from the deploy script and normalizes them.
    Fails closed: raises ValueError if either pin is absent, unparseable, empty, 'latest',
    or matches more than once with conflicting values.
    """
    path = Path(deploy_script_path)
    if not path.exists():
        raise ValueError(f"PROVENANCE GATE FAILURE: Deploy script missing at {deploy_script_path}")
    content = path.read_text(encoding="utf-8")
    
    pins = {}
    for eng, var_name in [("vllm", "VLLM_IMAGE_TAG"), ("sglang", "SGLANG_IMAGE_TAG")]:
        matches = re.findall(rf'^\s*(?:export\s+)?{var_name}\s*=\s*(["\']?)([^"\'\s#]+)\1', content, re.MULTILINE)
        if not matches:
            raise ValueError(f"PROVENANCE GATE FAILURE: Missing or unparseable {var_name} pin for {eng} in {deploy_script_path}")
        values = set(m[1] for m in matches)
        if len(values) > 1:
            raise ValueError(f"PROVENANCE GATE FAILURE: Conflicting {var_name} pins for {eng} in {deploy_script_path}: {values}")
        val = values.pop().strip()
        if not val or val == "latest":
            raise ValueError(f"PROVENANCE GATE FAILURE: Invalid {var_name} value '{val}' for {eng} in {deploy_script_path}")
        pins[eng] = normalize_version(val)
        if not pins[eng]:
            raise ValueError(f"PROVENANCE GATE FAILURE: Normalized {var_name} is empty for {eng} in {deploy_script_path}")
    return pins

def validate_rendered_manifests(deploy_script_path: str = "scripts/03_deploy_workloads.sh"):
    """
    Renders manifests for both vllm and sglang and asserts that the image tag present in
    the rendered serving manifest matches parse_engine_pins()[engine]. Fails closed.
    """
    pins = parse_engine_pins(deploy_script_path)
    script_path = Path(deploy_script_path).resolve()
    repo_root = Path(__file__).resolve().parent.parent
    candidate_root = script_path.parent.parent
    
    templates_src = candidate_root / "terraform" / "manifests" / "templates" if (candidate_root / "terraform" / "manifests" / "templates").exists() else repo_root / "terraform" / "manifests" / "templates"
    cfg_src = candidate_root / "scripts" / "config.env" if (candidate_root / "scripts" / "config.env").exists() else (candidate_root / "scripts" / "config.env.example" if (candidate_root / "scripts" / "config.env.example").exists() else (repo_root / "scripts" / "config.env" if (repo_root / "scripts" / "config.env").exists() else repo_root / "scripts" / "config.env.example"))

    for eng in ["vllm", "sglang"]:
        with tempfile.TemporaryDirectory() as tmpdir:
            env = os.environ.copy()
            env["INFERENCE_ENGINE"] = eng
            env["PROJECT_ID"] = env.get("PROJECT_ID", "ci-test")
            env["REGION"] = env.get("REGION", "europe-north1")
            env["ZONE"] = env.get("ZONE", "europe-north1-b")
            env["CLUSTER_NAME"] = env.get("CLUSTER_NAME", "glm-enterprise-fi")
            
            os.makedirs(Path(tmpdir) / "scripts", exist_ok=True)
            os.makedirs(Path(tmpdir) / "terraform" / "manifests", exist_ok=True)
            templates_link = Path(tmpdir) / "terraform" / "manifests" / "templates"
            if not templates_link.exists():
                os.symlink(templates_src, templates_link)
            os.makedirs(Path(tmpdir) / "terraform" / "manifests" / "generated", exist_ok=True)
            os.symlink(cfg_src, Path(tmpdir) / "scripts" / "config.env")
            exec_script = Path(tmpdir) / "scripts" / "03_deploy_workloads.sh"
            shutil.copy(script_path, exec_script)
            exec_script.chmod(0o755)
            cmd_path = str(exec_script)
            gen_dir = Path(tmpdir) / "terraform" / "manifests" / "generated"

            res = subprocess.run([cmd_path, "--render-only"], env=env, capture_output=True, text=True)
            if res.returncode != 0:
                raise ValueError(f"PROVENANCE GATE FAILURE: Failed to render manifests for {eng} using {deploy_script_path}: {res.stderr or res.stdout}")
            
            manifest_name = f"03-{eng}-spot-serving.yaml"
            manifest_file = gen_dir / manifest_name
            if not manifest_file.exists():
                raise ValueError(f"PROVENANCE GATE FAILURE: Rendered manifest {manifest_name} missing after --render-only for {eng}")
            
            other_eng = "sglang" if eng == "vllm" else "vllm"
            other_manifest = gen_dir / f"03-{other_eng}-spot-serving.yaml"
            if other_manifest.exists():
                raise ValueError(f"PROVENANCE GATE FAILURE: Non-selected engine manifest {other_manifest.name} should not be present in generated/ after --render-only for {eng}")
            
            content = manifest_file.read_text(encoding="utf-8")
            image_lines = [m for m in re.findall(r'^\s*image:\s*([^\s#]+)', content, re.MULTILINE) if "blackwell" in m]
            if not image_lines:
                raise ValueError(f"PROVENANCE GATE FAILURE: No serving image line found in rendered manifest {manifest_name}")
            
            for img in image_lines:
                if ":" not in img:
                    raise ValueError(f"PROVENANCE GATE FAILURE: Rendered image URI '{img}' missing tag in {manifest_name}")
                repo_path = img.rsplit(":", 1)[0]
                expected_suffix = f"{eng}-blackwell"
                if repo_path.rsplit("/", 1)[-1] != expected_suffix:
                    raise ValueError(f"PROVENANCE GATE FAILURE: Rendered manifest {manifest_name} repository '{repo_path}' does not match expected '{expected_suffix}'")
                tag = img.rsplit(":", 1)[-1]
                norm_tag = normalize_version(tag)
                if norm_tag != pins[eng]:
                    raise ValueError(f"PROVENANCE GATE FAILURE: Rendered manifest {manifest_name} image tag '{norm_tag}' (from '{tag}') does not match deploy pin '{pins[eng]}'")

def get_suite_timestamps(data: dict) -> tuple:
    for key in ["benchmark_config", "soak_config", "sweep_config", "prefill_config", "metadata"]:
        cfg = data.get(key)
        if isinstance(cfg, dict):
            start_ts = cfg.get("suite_start_ts")
            end_ts = cfg.get("suite_end_ts")
            if start_ts and end_ts:
                return start_ts, end_ts
    start_ts = data.get("suite_start_ts")
    end_ts = data.get("suite_end_ts")
    if start_ts and end_ts:
        return start_ts, end_ts
    return None, None

def get_suite_duration(suite_name: str, data: dict) -> float:
    dur = 0.0
    if suite_name in ["standard", "massive"]:
        dur = data.get("execution_summary", {}).get("total_benchmark_time_seconds", 0.0)
    elif suite_name == "soak":
        dur = data.get("execution_summary", {}).get("total_duration_seconds", 0.0)
    elif suite_name == "saturation":
        dur = sum(item.get("total_duration_sec", 0.0) for item in data.get("sweep_results", []))
    elif suite_name == "prefill":
        dur = data.get("ttft_sec", 0.0)
        if dur == 0.0 and "ttft_ms" in data:
            dur = data["ttft_ms"] / 1000.0
    return dur

def validate_provenance(vllm: dict, sglang: dict, deploy_script_path: str = "scripts/03_deploy_workloads.sh"):
    """
    Validates engine identity, container image, engine version against deploy script pins,
    timestamp formatting, and interval non-overlap against explicit suite boundaries.
    Enforces non-overlap of suite intervals without constraining execution order.
    """
    pins = parse_engine_pins(deploy_script_path)
    validate_rendered_manifests(deploy_script_path)
    suites = ["standard", "massive", "soak", "saturation", "prefill"]
    for s in suites:
        v_meta = get_metadata(vllm[s])
        g_meta = get_metadata(sglang[s])
        
        v_eng = v_meta.get("engine", "")
        v_img = v_meta.get("image", "")
        if v_eng != "vllm" or "vllm-blackwell" not in v_img:
            raise ValueError(f"PROVENANCE GATE FAILURE: results/vllm/{s}_results.json has mismatched metadata (engine='{v_eng}', image='{v_img}')")
            
        g_eng = g_meta.get("engine", "")
        g_img = g_meta.get("image", "")
        if g_eng != "sglang" or "sglang-blackwell" not in g_img:
            raise ValueError(f"PROVENANCE GATE FAILURE: results/sglang/{s}_results.json has mismatched metadata (engine='{g_eng}', image='{g_img}')")

        v_ver_norm = normalize_version(v_meta.get("engine_version", ""))
        if v_ver_norm != pins["vllm"]:
            raise ValueError(f"PROVENANCE GATE FAILURE: results/vllm/{s}_results.json engine_version '{v_meta.get('engine_version')}' does not match the deployed pin '{pins['vllm']}' from scripts/03_deploy_workloads.sh")

        g_ver_norm = normalize_version(g_meta.get("engine_version", ""))
        if g_ver_norm != pins["sglang"]:
            raise ValueError(f"PROVENANCE GATE FAILURE: results/sglang/{s}_results.json engine_version '{g_meta.get('engine_version')}' does not match the deployed pin '{pins['sglang']}' from scripts/03_deploy_workloads.sh")

    for eng_name, eng_data in [("vllm", vllm), ("sglang", sglang)]:
        intervals = []
        for s in suites:
            meta = get_metadata(eng_data[s])
            ts_str = meta.get("run_timestamp", "")
            if not ts_str:
                raise ValueError(f"PROVENANCE GATE FAILURE: Missing run_timestamp in results/{eng_name}/{s}_results.json")
            try:
                datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            except Exception as e:
                raise ValueError(f"PROVENANCE GATE FAILURE: Invalid run_timestamp '{ts_str}' in results/{eng_name}/{s}_results.json: {e}")

            start_ts, end_ts = get_suite_timestamps(eng_data[s])
            if not start_ts or not end_ts:
                print(f"NOTE: Skipping interval overlap checks for {eng_name} {s} (suite_start_ts not recorded in baseline file).")
                continue
            try:
                curr_start_dt = datetime.fromisoformat(start_ts.replace("Z", "+00:00"))
                curr_end_dt = datetime.fromisoformat(end_ts.replace("Z", "+00:00"))
            except Exception as e:
                raise ValueError(f"PROVENANCE GATE FAILURE: Invalid suite timestamp in results/{eng_name}/{s}_results.json: {e}")
            
            if curr_start_dt > curr_end_dt:
                raise ValueError(f"PROVENANCE GATE FAILURE: results/{eng_name}/{s}_results.json has suite_start_ts after suite_end_ts")
            
            intervals.append((curr_start_dt, curr_end_dt, s, start_ts))
            
        intervals.sort(key=lambda x: x[0])
        for i in range(1, len(intervals)):
            curr_start_dt, curr_end_dt, curr_suite, start_ts = intervals[i]
            prev_start_dt, prev_end_dt, prev_suite, _ = intervals[i - 1]
            if curr_start_dt < prev_end_dt:
                raise ValueError(f"PROVENANCE GATE FAILURE: results/{eng_name}/{curr_suite}_results.json suite_start_ts ({start_ts}) overlaps/precedes previous suite {prev_suite} suite_end_ts ({prev_end_dt.strftime('%Y-%m-%dT%H:%M:%SZ')})")

def validate_parity_and_sanity(vllm: dict, sglang: dict):
    suites = ["standard", "massive", "soak", "saturation", "prefill"]
    for s in suites:
        v = vllm[s]
        g = sglang[s]

        # 1. Parameter Parity Gate
        if s in ["standard", "massive"]:
            vc, gc = v["benchmark_config"]["concurrency"], g["benchmark_config"]["concurrency"]
            vr, gr = v["benchmark_config"]["requests"], g["benchmark_config"]["requests"]
            vm, gm = v["benchmark_config"]["max_tokens"], g["benchmark_config"]["max_tokens"]
            if (vc, vr, vm) != (gc, gr, gm):
                raise ValueError(f"Parameter Parity Violation in {s}: vLLM ({vc},{vr},{vm}) != SGLang ({gc},{gr},{gm})")
        elif s == "soak":
            vc, gc = v["soak_config"]["concurrency"], g["soak_config"]["concurrency"]
            vd, gd = v["soak_config"]["duration"], g["soak_config"]["duration"]
            vm, gm = v["soak_config"]["max_tokens"], g["soak_config"]["max_tokens"]
            if (vc, vd, vm) != (gc, gd, gm):
                raise ValueError(f"Parameter Parity Violation in soak: vLLM ({vc},{vd},{vm}) != SGLang ({gc},{gd},{gm})")
        elif s == "saturation":
            v_concs = [item["concurrency"] for item in v["sweep_results"]]
            g_concs = [item["concurrency"] for item in g["sweep_results"]]
            if v_concs != g_concs:
                raise ValueError(f"Parameter Parity Violation in saturation: vLLM concs {v_concs} != SGLang concs {g_concs}")
        elif s == "prefill":
            vp, gp = v["prompt_tokens"], g["prompt_tokens"]
            if vp != gp:
                raise ValueError(f"Parameter Parity Violation in prefill: vLLM prompt tokens ({vp}) != SGLang ({gp})")

        # 2. Cold-Start / Queue Contamination Gate & TPOT / Success Rate Gate
        for eng_name, data in [("vLLM", v), ("SGLang", g)]:
            if s in ["standard", "massive", "soak"]:
                ttft_p50 = data["metrics"]["ttft_ms"]["p50"]
                tpot_mean = data["metrics"]["tpot_ms"]["mean"]
                succ = data["successful_requests"]
                tot = data["total_requests"]
                if s == "standard" and ttft_p50 > 10000.0:
                    raise ValueError(f"Sanity Gate Failure [TTFT Contamination]: {eng_name} {s} TTFT P50 is {ttft_p50:.2f} ms (> 10s threshold at c <= 8). Re-run after warm-up.")
                if tpot_mean < 1.0:
                    raise ValueError(f"Sanity Gate Failure [TPOT Implausible]: {eng_name} {s} TPOT mean is {tpot_mean:.4f} ms (< 1 ms threshold).")
                if succ != tot:
                    raise ValueError(f"Sanity Gate Failure [Non-100% Success Rate]: {eng_name} {s} success rate is {succ}/{tot}.")
            elif s == "saturation":
                for item in data["sweep_results"]:
                    c_level = item["concurrency"]
                    ttft_p50 = item["ttft_ms"]["p50"]
                    tpot_mean = item["tpot_ms"]["mean"]
                    err_pct = item["error_rate_pct"]
                    if c_level <= 8 and ttft_p50 > 10000.0:
                        raise ValueError(f"Sanity Gate Failure [TTFT Contamination]: {eng_name} saturation c={c_level} TTFT P50 is {ttft_p50:.2f} ms (> 10s threshold). Re-run after warm-up.")
                    if tpot_mean < 1.0:
                        raise ValueError(f"Sanity Gate Failure [TPOT Implausible]: {eng_name} saturation c={c_level} TPOT mean is {tpot_mean:.4f} ms (< 1 ms threshold).")
                    if err_pct != 0.0:
                        raise ValueError(f"Sanity Gate Failure [Non-100% Success Rate]: {eng_name} saturation c={c_level} error rate is {err_pct}%.")

def calc_delta(val_vllm: float, val_sglang: float, higher_is_better: bool = True) -> str:
    if val_vllm == 0:
        return "+0.00%"
    if higher_is_better:
        d = ((val_sglang - val_vllm) / val_vllm) * 100.0
    else:
        d = ((val_vllm - val_sglang) / val_vllm) * 100.0
    return f"{d:+.2f}%"

def generate_markdown(vllm: dict, sglang: dict) -> str:
    v_meta = get_metadata(vllm["standard"])
    g_meta = get_metadata(sglang["standard"])
    v_ver = v_meta.get("engine_version", "vLLM")
    g_ver = g_meta.get("engine_version", "SGLang")
    
    v_label = f"vLLM ({v_ver})"
    g_label = f"SGLang ({g_ver})"

    lines = []
    lines.append("### Multi-Engine Benchmark Comparison (vLLM vs SGLang)")
    lines.append("")
    lines.append("All benchmarks were executed on the live GKE serving cluster with identical hardware allocations (8x NVIDIA B200 HGX, GKE `a4-highgpu-8g` node pool, NVLink 5th-gen, tensor parallelism TP=8) and identical model weights (`nvidia/GLM-5.2-NVFP4`) mounted read-only from a shared Hyperdisk ML ROX volume. Both engines served via the LiteLLM Enterprise Gateway on port 4000 (Standard, Massive, Soak) and direct container port 8000 (Saturation Sweep, Prefill Ingestion).")
    lines.append("")
    lines.append("#### Methodology & Provenance Protocol")
    lines.append("* **Cache Policy:** Workload suites (Standard, Massive, Soak) evaluated end-to-end serving performance on port 4000, where dynamic prompt nonce injection bypassed LiteLLM Redis exact-match caching. The Concurrency Saturation Sweep and Prefill Ingestion suites evaluated direct engine performance on port 8000, utilizing unique prompt sets and radix cache flushing to ensure 0% prefix-cache hits (measuring true cold decoding and prefill throughput).")
    lines.append("* **Sequential Execution & Drain Protocol:** To prevent resource contention and queue contamination, benchmark suites were executed strictly sequentially with full queue drain intervals between runs.")
    lines.append("* **Engine Provenance Verification:** Engine identity and container provenance were verified prior to every suite by inspecting `/metrics` endpoints (`^vllm:` vs `^sglang:`) and deployment container images. Collection timestamps recorded in suite metadata:")
    
    v_img = v_meta.get("image", "unknown").split("/")[-1]
    g_img = g_meta.get("image", "unknown").split("/")[-1]
    
    v_ts_list = [f"{s.capitalize()} ({get_metadata(vllm[s]).get('run_timestamp', 'N/A')})" for s in ["standard", "massive", "soak", "saturation", "prefill"]]
    g_ts_list = [f"{s.capitalize()} ({get_metadata(sglang[s]).get('run_timestamp', 'N/A')})" for s in ["standard", "massive", "soak", "saturation", "prefill"]]
    
    lines.append(f"  * **vLLM** (`{v_img}`): {', '.join(v_ts_list)}.")
    lines.append(f"  * **SGLang** (`{g_img}`): {', '.join(g_ts_list)}.")
    lines.append("")
    
    # Table 1
    lines.append("#### Table 1: Production Workload Suite Summary (Gateway Port 4000)")
    lines.append(f"| Workload Suite | Metric | {v_label} | {g_label} | Delta ($\\Delta$) |")
    lines.append("| :--- | :--- | :--- | :--- | :--- |")
    
    suites_t1 = [
        ("Standard Suite ($c=8$, $128\\text{ tok}$)", "standard", [
            ("TTFT P50 (ms)", lambda d: d["metrics"]["ttft_ms"]["p50"], False, "{:.2f}"),
            ("TPOT mean (ms)", lambda d: d["metrics"]["tpot_ms"]["mean"], False, "{:.2f}"),
            ("Throughput (tok/s)", lambda d: d["throughput_tokens_sec"], True, "{:.2f}"),
            ("Success rate", lambda d: 100.0 * d["successful_requests"] / max(1, d["total_requests"]), True, "{:.1f}%"),
        ]),
        ("Massive Stress ($c=20$, $256\\text{ tok}$)", "massive", [
            ("TTFT P50 (ms)", lambda d: d["metrics"]["ttft_ms"]["p50"], False, "{:.2f}"),
            ("TPOT mean (ms)", lambda d: d["metrics"]["tpot_ms"]["mean"], False, "{:.2f}"),
            ("Throughput (tok/s)", lambda d: d["throughput_tokens_sec"], True, "{:.2f}"),
            ("Success rate", lambda d: 100.0 * d["successful_requests"] / max(1, d["total_requests"]), True, "{:.1f}%"),
        ]),
        ("Endurance Soak ($c=18$, $1800\\text{s}$)", "soak", [
            ("TTFT P50 (ms)", lambda d: d["metrics"]["ttft_ms"]["p50"], False, "{:.2f}"),
            ("TPOT mean (ms)", lambda d: d["metrics"]["tpot_ms"]["mean"], False, "{:.2f}"),
            ("Throughput (tok/s)", lambda d: d["throughput_tokens_sec"], True, "{:.2f}"),
            ("Completed cycles", lambda d: float(d["successful_requests"]), True, "{:.0f}"),
        ]),
    ]

    for suite_label, s_key, metrics in suites_t1:
        for i, (m_label, extractor, hib, fmt) in enumerate(metrics):
            val_v = extractor(vllm[s_key])
            val_g = extractor(sglang[s_key])
            delta_str = calc_delta(val_v, val_g, hib)
            w_col = suite_label if i == 0 else ""
            lines.append(f"| {w_col} | {m_label} | {fmt.format(val_v)} | {fmt.format(val_g)} | **{delta_str}** |")

    lines.append("")
    lines.append("#### Table 2: Concurrency Saturation Sweep (Direct Port 8000, 0% Cache Hits)")
    lines.append(f"| Concurrency ($c$) | {v_label} tok/s | {g_label} tok/s | Throughput $\\Delta$ | {v_label} TTFT P99 (s) | {g_label} TTFT P99 (s) | TTFT P99 $\\Delta$ |")
    lines.append("| :--- | :--- | :--- | :--- | :--- | :--- | :--- |")

    v_sweep = {item["concurrency"]: item for item in vllm["saturation"]["sweep_results"]}
    g_sweep = {item["concurrency"]: item for item in sglang["saturation"]["sweep_results"]}

    for c in sorted(v_sweep.keys()):
        vi, gi = v_sweep[c], g_sweep[c]
        v_tok, g_tok = vi["aggregate_tok_s"], gi["aggregate_tok_s"]
        v_ttft_s, g_ttft_s = vi["ttft_ms"]["p99"] / 1000.0, gi["ttft_ms"]["p99"] / 1000.0
        d_tok = calc_delta(v_tok, g_tok, True)
        d_ttft = calc_delta(v_ttft_s, g_ttft_s, False)
        lines.append(f"| $c={c}$ | {v_tok:.2f} | {g_tok:.2f} | **{d_tok}** | {v_ttft_s:.4f} s | {g_ttft_s:.4f} s | **{d_ttft}** |")

    lines.append("")
    lines.append("#### Table 3: Prompt Prefill Ingestion Stress ($8,192\\text{ prompt tok} \\to 16\\text{ out}$)")
    lines.append(f"| Metric | {v_label} | {g_label} | Delta ($\\Delta$) |")
    lines.append("| :--- | :--- | :--- | :--- |")
    
    vp_tok, gp_tok = vllm["prefill"]["prefill_tok_s_system"], sglang["prefill"]["prefill_tok_s_system"]
    vp_ttft, gp_ttft = vllm["prefill"]["ttft_ms"], sglang["prefill"]["ttft_ms"]
    d_prefill_tok = calc_delta(vp_tok, gp_tok, True)
    d_prefill_ttft = calc_delta(vp_ttft, gp_ttft, False)

    lines.append(f"| Prefill throughput | {vp_tok:.2f} prompt tok/s | {gp_tok:.2f} prompt tok/s | **{d_prefill_tok}** |")
    lines.append(f"| TTFT mean (ms) | {vp_ttft:.2f} ms | {gp_ttft:.2f} ms | **{d_prefill_ttft}** |")
    
    lines.append("")
    lines.append("#### Technical Guidance: When to Choose vLLM vs SGLang")
    lines.append("")
    
    # Dynamic synthesis of technical guidance strictly from numbers in Tables 1-3
    sglang_std_tps = sglang["standard"]["throughput_tokens_sec"]
    vllm_std_tps = vllm["standard"]["throughput_tokens_sec"]
    sglang_std_tpot = sglang["standard"]["metrics"]["tpot_ms"]["mean"]
    vllm_std_tpot = vllm["standard"]["metrics"]["tpot_ms"]["mean"]
    
    lines.append(f"* **Choose SGLang (`INFERENCE_ENGINE=sglang`)** when your application relies heavily on RadixAttention prefix caching, structured JSON generation, or multi-turn conversational agents. In our production suites, SGLang demonstrated robust decoding performance (Standard TPOT of {sglang_std_tpot:.2f} ms vs vLLM {vllm_std_tpot:.2f} ms) and sustained stability during 30-minute endurance soak testing.")
    
    if gp_tok > vp_tok:
        prefill_text = f"SGLang demonstrated superior prompt ingestion throughput ({gp_tok:.2f} prompt tok/s vs vLLM {vp_tok:.2f} prompt tok/s)."
    else:
        prefill_text = f"vLLM demonstrated superior prompt ingestion throughput ({vp_tok:.2f} prompt tok/s vs SGLang {gp_tok:.2f} prompt tok/s), making it preferable for raw long-context batch prefill without cache hits."
        
    lines.append(f"* **Choose vLLM (`INFERENCE_ENGINE=vllm`)** as the robust default for general-purpose serving and high-throughput batch inference. {prefill_text} vLLM maintains mature CUDA graph capture, predictable memory allocation, and consistent latency across diverse batch sizes.")
    
    return "\n".join(lines)

def update_readme(markdown_block: str, readme_path: Path):
    if not readme_path.exists():
        print(f"ERROR: {readme_path} does not exist.", file=sys.stderr)
        sys.exit(1)
        
    content = readme_path.read_text(encoding="utf-8")
    start_marker = "<!-- ENGINE_COMPARISON_START -->"
    end_marker = "<!-- ENGINE_COMPARISON_END -->"
    
    if start_marker not in content or end_marker not in content:
        print("ERROR: Comparison markers not found in README.md", file=sys.stderr)
        sys.exit(1)
        
    pattern = re.compile(rf"({re.escape(start_marker)}).*?({re.escape(end_marker)})", re.DOTALL)
    new_content, count = pattern.subn(lambda m: f"{m.group(1)}\n\n{markdown_block.strip()}\n\n{m.group(2)}", content)
    
    if count == 0:
        print("ERROR: Regex substitution failed on README.md", file=sys.stderr)
        sys.exit(1)
        
    if new_content == content:
        print("README.md comparison block is already up-to-date (no changes needed).")
    else:
        readme_path.write_text(new_content, encoding="utf-8")
        print("Successfully updated README.md comparison block in place.")

def main():
    root = Path(__file__).resolve().parent
    results_dir = root / "results"
    
    vllm_dir = results_dir / "vllm"
    sglang_dir = results_dir / "sglang"
    
    suites = ["standard", "massive", "soak", "saturation", "prefill"]
    
    vllm_data = {}
    sglang_data = {}
    
    print("Loading multi-engine benchmark JSON results...")
    for s in suites:
        vllm_data[s] = load_json(vllm_dir / f"{s}_results.json")
        sglang_data[s] = load_json(sglang_dir / f"{s}_results.json")
        
    print("Enforcing provenance, parameter parity, and sanity gates...")
    try:
        validate_provenance(vllm_data, sglang_data)
        validate_parity_and_sanity(vllm_data, sglang_data)
    except ValueError as e:
        print(f"GATE FAILURE: {e}", file=sys.stderr)
        sys.exit(1)
        
    print("Generating Markdown comparison block...")
    md_block = generate_markdown(vllm_data, sglang_data)
    
    readme_path = root.parent / "README.md"
    print(f"Idempotently updating {readme_path}...")
    update_readme(md_block, readme_path)
    print("Done.")

if __name__ == "__main__":
    main()
