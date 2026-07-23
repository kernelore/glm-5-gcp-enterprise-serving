#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import urllib.request

# Normalize and sanitize proxy settings to prevent SSL/hostname transport errors
for proxy_var in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"]:
    val = os.environ.get(proxy_var, "")
    if val and not val.startswith("http://") and not val.startswith("https://"):
        os.environ.pop(proxy_var, None)

project_id = os.environ.get("PROJECT_ID", "YOUR_PROJECT_ID")
dataset_id = os.environ.get("AUDIT_DATASET_ID", "glm52_enterprise_audit")
table_id = os.environ.get("AUDIT_TABLE_ID", "trajectories")

if project_id == "YOUR_PROJECT_ID" or not project_id:
    print("[FAIL] Error: Please set the PROJECT_ID environment variable (e.g. export PROJECT_ID=my-project-id)")
    sys.exit(1)

table_ref = f"{project_id}.{dataset_id}.{table_id}"
print(f"--> Verifying BigQuery Audit Sink on table: `{table_ref}`...")

success = False
total_rows = 0
sample_row = None

# Attempt 1: Google Cloud BigQuery Python Client with sanitized transport
try:
    from google.cloud import bigquery
    from google.api_core.client_options import ClientOptions

    client_options = ClientOptions()
    client = bigquery.Client(project=project_id, client_options=client_options)
    
    query = f"SELECT count(*) as total_trajectories FROM `{table_ref}`"
    query_job = client.query(query)
    results = list(query_job.result())
    if results:
        total_rows = results[0].total_trajectories
    
    if total_rows > 0:
        query_sample = f"SELECT request_id, request_timestamp, virtual_key, team_id, model, prompt_tokens, completion_tokens, total_cost_usd, ttft_ms, tpot_ms FROM `{table_ref}` ORDER BY request_timestamp DESC LIMIT 1"
        sample_res = list(client.query(query_sample).result())
        if sample_res:
            sample_row = dict(sample_res[0].items())
    success = True
except Exception as py_err:
    print(f"    [NOTE] Python BigQuery client raised exception ({py_err}). Falling back to 'bq' CLI / REST fallback...")

# Attempt 2: Fallback to `bq` CLI if Python client transport failed
if not success:
    try:
        cmd = [
            "bq", "query",
            "--nouse_legacy_sql",
            "--format=json",
            f"SELECT count(*) as total_trajectories FROM `{table_ref}`"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if res.returncode == 0:
            data = json.loads(res.stdout)
            if data and isinstance(data, list):
                total_rows = int(data[0].get("total_trajectories", 0))
            
            if total_rows > 0:
                cmd_sample = [
                    "bq", "query",
                    "--nouse_legacy_sql",
                    "--format=json",
                    f"SELECT request_id, request_timestamp, virtual_key, team_id, model, prompt_tokens, completion_tokens, total_cost_usd, ttft_ms, tpot_ms FROM `{table_ref}` ORDER BY request_timestamp DESC LIMIT 1"
                ]
                res_sample = subprocess.run(cmd_sample, capture_output=True, text=True, timeout=30)
                if res_sample.returncode == 0:
                    sample_data = json.loads(res_sample.stdout)
                    if sample_data and isinstance(sample_data, list):
                        sample_row = sample_data[0]
            success = True
        else:
            print(f"    [NOTE] bq CLI query stderr: {res.stderr.strip()}")
    except Exception as bq_err:
        print(f"    [NOTE] bq CLI query failed: {bq_err}")

# Attempt 3: Direct BigQuery REST API fallback using instance metadata token
if not success:
    try:
        token_req = urllib.request.Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
            headers={"Metadata-Flavor": "Google"}
        )
        with urllib.request.urlopen(token_req, timeout=3) as token_resp:
            token = json.loads(token_resp.read().decode())["access_token"]
            
        api_url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{project_id}/queries"
        req_body = json.dumps({"query": f"SELECT count(*) as total_trajectories FROM `{table_ref}`", "useLegacySql": False}).encode("utf-8")
        api_req = urllib.request.Request(api_url, data=req_body, headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(api_req, timeout=10) as resp:
            api_data = json.loads(resp.read().decode())
            rows = api_data.get("rows", [])
            if rows:
                total_rows = int(rows[0]["f"][0]["v"])
            success = True
    except Exception as rest_err:
        print(f"    [NOTE] REST API fallback failed: {rest_err}")

if success:
    print(f"    [PASS] BigQuery audit verification succeeded! Total recorded trajectories: {total_rows}")
    if sample_row:
        print(f"    Sample Row Telemetry: {sample_row}")
    sys.exit(0)
else:
    print(f"    [FAIL] BigQuery audit verification failed across all client, CLI, and REST transports.")
    sys.exit(1)

