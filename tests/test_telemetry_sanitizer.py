#!/usr/bin/env python3
import unittest
import json
import sys
import os

# Add benchmarks directory to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "benchmarks")))
from telemetry_sanitizer import sanitize_telemetry

class TestTelemetrySanitizer(unittest.TestCase):
    def test_sanitize_secrets_and_paths(self):
        raw_data = {
            "api_key": "sk-glm52-0123456789abcdef0123456789abcdef",
            "output": "/usr/local/google/home/testuser/.gemini/jetski/worktrees/repo/benchmarks/results/vllm/standard_results.json",
            "benchmark_config": {
                "api_key": "sk-glm52-0123456789abcdef0123456789abcdef",
                "output": "/home/testuser/benchmarks/results/vllm/standard_results.json",
                "metadata": json.dumps({
                    "api_key": "sk-glm52-0123456789abcdef0123456789abcdef",
                    "output": "/usr/local/google/home/testuser/benchmarks/results/vllm/standard_results.json",
                    "image": "docker.pkg.dev/secret-project-123/glm-prod/vllm-blackwell:v0.25.1",
                    "launch_flags": "export KEY=sk-glm52-0123456789abcdef0123456789abcdef"
                })
            }
        }
        
        sanitized = sanitize_telemetry(raw_data, "benchmarks/results/vllm/standard_results.json")
        
        # Verify top level
        self.assertEqual(sanitized["api_key"], "REDACTED")
        self.assertEqual(sanitized["output"], "benchmarks/results/vllm/standard_results.json")
        
        # Verify config block
        cfg = sanitized["benchmark_config"]
        self.assertEqual(cfg["api_key"], "REDACTED")
        self.assertEqual(cfg["output"], "benchmarks/results/vllm/standard_results.json")
        
        # Verify embedded JSON string
        meta = json.loads(cfg["metadata"])
        self.assertEqual(meta["api_key"], "REDACTED")
        self.assertEqual(meta["output"], "benchmarks/results/vllm/standard_results.json")
        self.assertEqual(meta["image"], "docker.pkg.dev/YOUR_PROJECT_ID/glm-prod/vllm-blackwell:v0.25.1")
        self.assertNotIn("sk-glm52-0123456789abcdef0123456789abcdef", meta["launch_flags"])
        self.assertIn("REDACTED", meta["launch_flags"])

if __name__ == "__main__":
    unittest.main()
