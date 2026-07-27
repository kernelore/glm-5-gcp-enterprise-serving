#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

# Normalize and sanitize proxy settings to prevent SSL/hostname transport errors
for proxy_var in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"]:
    val = os.environ.get(proxy_var, "")
    if val and not val.startswith("http://") and not val.startswith("https://"):
        os.environ.pop(proxy_var, None)

def run_bq_query(query: str, project_id: str, timeout: int = 30) -> tuple[bool, list]:
    # Attempt 1: bq CLI
    try:
        cmd = ["bq", "query", "--nouse_legacy_sql", "--format=json", query]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if res.returncode == 0:
            data = json.loads(res.stdout) if res.stdout.strip() else []
            return True, data
    except Exception as e:
        pass

    # Attempt 2: REST API
    try:
        token_req = urllib.request.Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
            headers={"Metadata-Flavor": "Google"}
        )
        with urllib.request.urlopen(token_req, timeout=3) as token_resp:
            token = json.loads(token_resp.read().decode())["access_token"]
        api_url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{project_id}/queries"
        req_body = json.dumps({"query": query, "useLegacySql": False}).encode("utf-8")
        api_req = urllib.request.Request(api_url, data=req_body, headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(api_req, timeout=timeout) as resp:
            api_data = json.loads(resp.read().decode())
            rows = api_data.get("rows", [])
            schema = api_data.get("schema", {}).get("fields", [])
            col_names = [f["name"] for f in schema]
            parsed_rows = []
            for r in rows:
                row_dict = {}
                for idx, col in enumerate(col_names):
                    row_dict[col] = r["f"][idx]["v"]
                parsed_rows.append(row_dict)
            return True, parsed_rows
    except Exception as e:
        pass

    # Attempt 3: Python client
    try:
        from google.cloud import bigquery
        from google.api_core.client_options import ClientOptions
        client = bigquery.Client(project=project_id, client_options=ClientOptions())
        query_job = client.query(query)
        results = list(query_job.result())
        parsed_rows = [dict(r.items()) for r in results]
        return True, parsed_rows
    except Exception as e:
        pass

    return False, []

def get_row_count_and_sample(table_ref: str, project_id: str) -> tuple[bool, int, dict | None]:
    success, rows = run_bq_query(f"SELECT count(*) as total_trajectories FROM `{table_ref}`", project_id)
    if not success or not rows:
        return False, 0, None
    total_rows = int(rows[0].get("total_trajectories", 0))
    sample_row = None
    if total_rows > 0:
        s_success, s_rows = run_bq_query(
            f"SELECT request_id, request_timestamp, virtual_key, team_id, model, prompt_tokens, completion_tokens, total_cost_usd, ttft_ms, tpot_ms FROM `{table_ref}` ORDER BY request_timestamp DESC LIMIT 1",
            project_id
        )
        if s_success and s_rows:
            sample_row = s_rows[0]
    return True, total_rows, sample_row

def main():
    parser = argparse.ArgumentParser(description="Verify BigQuery Audit Sink")
    parser.add_argument("--count-only", action="store_true", help="Print row count only and exit")
    parser.add_argument("--verify-id", type=str, help="Poll until request ID is observed")
    parser.add_argument("--count-before", type=int, default=0, help="Initial row count before test request")
    parser.add_argument("--timeout", type=int, default=180, help="Timeout in seconds for polling")
    args = parser.parse_args()

    project_id = os.environ.get("PROJECT_ID", "YOUR_PROJECT_ID")
    dataset_id = os.environ.get("AUDIT_DATASET_ID", "glm52_enterprise_audit")
    table_id = os.environ.get("AUDIT_TABLE_ID", "trajectories")

    if project_id == "YOUR_PROJECT_ID" or not project_id:
        print("[FAIL] Error: Please set the PROJECT_ID environment variable (e.g. export PROJECT_ID=my-project-id)", file=sys.stderr)
        sys.exit(1)

    table_ref = f"{project_id}.{dataset_id}.{table_id}"

    if args.count_only:
        success, total_rows, _ = get_row_count_and_sample(table_ref, project_id)
        if success:
            print(total_rows)
            sys.exit(0)
        else:
            print(f"[FAIL] Could not query BigQuery table `{table_ref}` across any transport.", file=sys.stderr)
            sys.exit(1)

    if args.verify_id:
        print(f"--> Polling BigQuery table `{table_ref}` for delivery of request ID '{args.verify_id}' (timeout: {args.timeout}s)...")
        start_time = time.time()
        while time.time() - start_time < args.timeout:
            success, total_rows, _ = get_row_count_and_sample(table_ref, project_id)
            if success and total_rows > args.count_before:
                q_id = f"SELECT request_id, request_timestamp, virtual_key, team_id, model, prompt_tokens, completion_tokens, total_cost_usd, ttft_ms, tpot_ms FROM `{table_ref}` WHERE request_id = '{args.verify_id}' OR team_id = '{args.verify_id}' LIMIT 1"
                id_success, id_rows = run_bq_query(q_id, project_id)
                if id_success and id_rows:
                    print(f"    [PASS] BigQuery audit verification succeeded! Trajectory delivered for ID '{args.verify_id}'. Total trajectories: {total_rows} (was {args.count_before}).")
                    print(f"    Sample Row Telemetry: {id_rows[0]}")
                    sys.exit(0)
            time.sleep(5)
        print(f"    [FAIL] BigQuery audit verification timed out waiting for row delivery of ID '{args.verify_id}'!", file=sys.stderr)
        sys.exit(1)

    # Default standalone check
    print(f"--> Verifying BigQuery Audit Sink on table: `{table_ref}`...")
    success, total_rows, sample_row = get_row_count_and_sample(table_ref, project_id)
    if success and total_rows > 0:
        print(f"    [PASS] BigQuery audit verification succeeded! Total recorded trajectories: {total_rows}")
        if sample_row:
            print(f"    Sample Row Telemetry: {sample_row}")
        sys.exit(0)
    else:
        print(f"    [FAIL] BigQuery audit verification failed: total_rows is {total_rows} (must be > 0) or all transports failed.", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()

