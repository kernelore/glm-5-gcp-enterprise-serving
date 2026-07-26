#!/usr/bin/env python3
import json
import re

def sanitize_telemetry(data, out_path=None):
    if not isinstance(data, dict):
        return data
    if "api_key" in data:
        data["api_key"] = "REDACTED"
    if "output" in data and isinstance(data["output"], str):
        p = out_path.replace("\\", "/") if out_path else data["output"].replace("\\", "/")
        if "benchmarks/results/" in p:
            data["output"] = "benchmarks/results/" + p.split("benchmarks/results/")[-1]
        else:
            data["output"] = re.sub(r"^(.*?)(/home/[^/]+/|/usr/local/google/home/[^/]+/.gemini/jetski/worktrees/[^/]+/[^/]+/)", "", p)
    for k in ["benchmark_config", "soak_config", "sweep_config", "prefill_config", "metadata"]:
        if k in data and isinstance(data[k], dict):
            sanitize_telemetry(data[k], out_path)
        elif k in data and isinstance(data[k], str):
            try:
                m = json.loads(data[k])
                if isinstance(m, dict):
                    if "api_key" in m:
                        m["api_key"] = "REDACTED"
                    if "output" in m and isinstance(m["output"], str):
                        p2 = out_path.replace("\\", "/") if out_path else m["output"].replace("\\", "/")
                        if "benchmarks/results/" in p2:
                            m["output"] = "benchmarks/results/" + p2.split("benchmarks/results/")[-1]
                        else:
                            m["output"] = re.sub(r"^(.*?)(/home/[^/]+/|/usr/local/google/home/[^/]+/.gemini/jetski/worktrees/[^/]+/[^/]+/)", "", p2)
                    for mk, mv in m.items():
                        if isinstance(mv, str):
                            mv = re.sub(r"sk-glm52-[a-fA-F0-9]{16,}", "REDACTED", mv)
                            mv = re.sub(r"docker\.pkg\.dev/[^/]+", "docker.pkg.dev/YOUR_PROJECT_ID", mv)
                            mv = re.sub(r"^(.*?)(/home/[^/]+/|/usr/local/google/home/[^/]+/.gemini/jetski/worktrees/[^/]+/[^/]+/)", "", mv)
                            m[mk] = mv
                    data[k] = json.dumps(m)
            except Exception:
                pass
    return data
