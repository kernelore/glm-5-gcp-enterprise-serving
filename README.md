# GLM-5.2 NVFP4 Sovereign Enterprise Inference Architecture

[![Google Cloud](https://img.shields.io/badge/Google_Cloud-Blackwell_B200-4285F4?style=flat-square&logo=googlecloud&logoColor=white)](https://cloud.google.com/compute/docs/gpus)
[![NVIDIA](https://img.shields.io/badge/NVIDIA-NVFP4_MoE-76B900?style=flat-square&logo=nvidia&logoColor=white)](https://developer.nvidia.com/)
[![vLLM](https://img.shields.io/badge/Inference-vLLM_0.25.1-8A2BE2?style=flat-square)](https://docs.vllm.ai/)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg?style=flat-square)](LICENSE)

> [!IMPORTANT]
> **Disclaimer:** This repository is a **personal engineering project and reference architecture**. It is **not** an official Google product, is **not** covered by any Google Cloud Service Level Agreements (SLAs), and is **not** subject to official Google support channels. All code, scripts, and architectural models are provided *"as-is"* without warranty for educational, experimental, and benchmarking purposes.

**Target Hardware:** Google Kubernetes Engine (GKE) Blackwell (`a4-highgpu-8g` — 8x NVIDIA B200 HGX per node)  
**Target Workload:** High-Throughput Enterprise AI Engineering & Autonomous Agentic Workflows (`32k` to `128k` active context window out of `1M` maximum capacity)  

---

## ⚡ Executive Summary & Architecture Overview

This repository provides production-ready infrastructure engineering specifications and automated deployment scripts for hosting **GLM-5.2 (~381B total parameters, 47 safetensors shards, ~465 GB on disk)** in a secure, private, and sovereign Google Cloud environment.

To achieve breakthrough economics and sub-second token latency, this architecture co-designs **NVIDIA Blackwell (`B200`)** accelerators with **NVFP4 (4-bit floating point)** quantization. While intra-node serving utilizes **Tensor Parallelism (`TP=8`)** across high-speed NVLink (`1.8 TB/s`), the architecture is built on a decoupled storage model that scales out horizontally to **$N$ nodes via Data Parallelism (`DP=N`)** backed by a shared read-only **Hyperdisk ML (`ROX`)** volume.

```
+-----------------------------------------------------------------------------------------------------------------+
|                                       Private VPC High-Performance Network                                      |
|                 (Private Nodes, IAM-Gated Control Plane / Optional Private Endpoint, Private ILB)                |
+--------------------------------------------------------+--------------------------------------------------------+
                                                         |
                                                         v
+-----------------------------------------------------------------------------------------------------------------+
|                      Tier 1: Enterprise AI Gateway Layer (LiteLLM + Cloud SQL + Redis)                          |
|  - Virtual API Key Authentication (Internal Load Balancer Port 4000)                                            |
|  - Token-Bucket Rate Limiting (TPM / RPM) & Exact-Match Prompt Caching on Cloud Memorystore Redis               |
|  - Upstream distribution across N active serving nodes via Kubernetes Cluster Service                           |
+--------------------------------------------------------+--------------------------------------------------------+
                                                         |
                                                         v
+-----------------------------------------------------------------------------------------------------------------+
|          GKE Blackwell Auto-Scaling Node Pool (`a4-highgpu-8g` | min: 0, max: `gpu_pool_max_nodes` (default 2))    |
|                    Horizontally Scalable Compute Cluster (Data Parallelism DP=N Replicas)                       |
|                                                                                                                 |
|  +--------------------------------------------------+       ...       +--------------------------------------+  |
|  |           Serving Pod Replica 1 (Node 1)         |                 |        Serving Pod Replica N (Node N)|  |
|  |  8x NVIDIA B200 HGX GPUs (1,440 GB HBM3e)        |                 |  8x NVIDIA B200 HGX GPUs (1,440 GB)  |  |
|  |  - Tensor Parallelism: TP=8 over NVLink (1.8TB/s)|                 |  - Tensor Parallelism: TP=8 (NVLink) |  |
|  |  - Static Model Footprint: ~500 GB HBM3e         |                 |  - Static Model Footprint: ~500 GB   |  |
|  |  - Dedicated KV Cache Pool: ~850 GB HBM3e        |                 |  - Dedicated KV Cache Pool: ~850 GB  |  |
|  |    (~39 Estimated 128k Context Sessions)         |                 |    (~39 Estimated 128k Sessions)     |  |
|  +--------------------------+-----------------------+                 +------------------+-------------------+  |
+-----------------------------|------------------------------------------------------------|----------------------+
                              |                                                            |
                              +-----------------------------+------------------------------+
                                                            | (Concurrent ReadOnlyMany Attach)
                                                            v
+-----------------------------------------------------------------------------------------------------------------+
|                                   Tier 0: Hyperdisk ML (`ROX` Multi-Node Storage)                               |
|                             `1,000 GB` Pre-Hydrated Shared Model Weight Volume (XFS)                            |
|  - Instant Pod Hydration (target fast boot time) concurrently attached to all N serving nodes                   |
|  - Zero Cold-Start Network Downloads when scaling from 1 to N nodes                                             |
+-----------------------------------------------------------------------------------------------------------------+
```

### 📚 Model Background & Resources

GLM-5.2 is designed for high-concurrency enterprise inferencing:

* **LMSYS Chatbot Arena Leaderboard:** Performance on the global crowd-sourced Elo rating index.  
  🔗 [LMSYS Chatbot Arena](https://lmarena.ai/) | [Hugging Face Arena Space](https://huggingface.co/spaces/lmsys/chatbot-arena-leaderboard)
* **Hugging Face Model Hub:** Official NVFP4 quantized weights repository.  
  🔗 [Hugging Face Model Repository (nvidia/GLM-5.2-NVFP4)](https://huggingface.co/nvidia/GLM-5.2-NVFP4)

---

## ☁️ Google Cloud Products & Architectural Roles

| Google Cloud Product | Resource Identifier in Stack | Architectural Role & Implementation Details |
| :--- | :--- | :--- |
| **Google Kubernetes Engine (GKE)** | `module.cluster` | Private nodes with public, IAM-gated control-plane endpoint (or fully private with `enable_private_endpoint = true`) orchestrating vLLM serving pods, Workload Identity Federation, and node pool autoscaling. |
| **Compute Engine A4 VMs** | `module.node_pool_spot` | `a4-highgpu-8g` Blackwell instances equipped with 8x NVIDIA B200 GPUs (1,440 GB HBM3e) and 32x local NVMe SSDs (12 TiB). |
| **Hyperdisk ML (`ROX`)** | `module.storage` | 1,000 GB high-throughput block volume flipped to `ReadOnlyMany` mode for shared, zero-cold-start weight mounting. |
| **Cloud Memorystore for Redis** | `module.cache` | In-memory tier for exact-match prompt caching (single-digit-ms in-VPC, <50 ms verified via port-forward) and gateway token-bucket rate limiting (RPM/TPM). |
| **Cloud SQL for PostgreSQL** | `module.database` | Private database accessed via Cloud SQL Auth Proxy storing virtual API keys, user budgets, and gateway config. |
| **BigQuery** | `module.audit` | Serverless audit dataset (`glm52_enterprise_audit`) for asynchronous logging of conversation trajectories and token metrics. |
| **Cloud Storage (GCS)** | `TF_STATE_BUCKET` / `GCS_WEIGHTS_BUCKET` | Remote Terraform state versioning and optional high-speed weight hydration backup (estimated multi-GiB/s, hardware dependent). |
| **Artifact Registry** | `module.storage` | Secure private container registry hosting pinned custom vLLM Blackwell serving images (`vllm-blackwell:v0.25.1`). |
| **Cloud Build** | `scripts/03_deploy_workloads.sh` | Serverless build pipeline for automated, self-healing image compilation from `docker/Dockerfile`. |
| **Virtual Private Cloud (VPC)** | `module.network` | Private network topology with Private Services Access (PSA) and IAP SSH restrictions. |
| **Managed Service for Prometheus (GMP)** | `module.observability` | Native metrics pipeline capturing NVIDIA DCGM GPU metrics (`DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`) and vLLM request metrics. |

---

## 💎 Key Engineering Highlights

1. **NVFP4 Quantization & Memory Co-Design:** Quantizing GLM-5.2 to `NVFP4` compresses the on-disk model footprint to **~465 GB** across 47 safetensors shards. Total static memory footprint per node is **~500 GB** (weights + scales and activation buffers). Across `8x B200 GPUs` (`1,440 GB` HBM3e), with `--gpu-memory-utilization=0.94` (~1,353.6 GB usable) and `--kv-cache-dtype=auto`, this preserves **`~850 GB` of dedicated high-speed HBM3e memory for PagedAttention KV Cache**, supporting up to ~39 estimated concurrent `128k` context sessions without memory thrashing (the authoritative figure is the 'GPU KV cache size' logged by vLLM at startup).
2. **Hybrid Storage Hydration (`ROX` + Local NVMe):** To eliminate multi-hour weights downloading when scaling, model weights are pre-staged onto a **`1,000 GB` Hyperdisk ML (`ROX`)** volume (`Tier 0`). Serving pods attach the volume in `ReadOnlyMany` mode (`xfs`, `mountOptions: [nouuid, ro, norecovery]`). For local scratch, **`12 TiB` of Local NVMe SSD** (32x 375 GiB drives) is formatted in RAID 0 XFS via DaemonSet.
3. **Turnkey Tooling & Secure Python Downloads:** Weight staging executes Python `snapshot_download()` streaming directly into the staging Persistent Volume, authenticated via the `HF_TOKEN` environment variable projected from a Kubernetes Secret (never rendered into plaintext manifests).
4. **Intra-Node NVLink Serving:** Tensor Parallel (`TP=8`) intra-node communication utilizes NVIDIA NVLink (`1.8 TB/s` bidirectional per GPU). Single-node serving eliminates inter-node networking overhead while maximizing GPU utilization.
5. **Zero-Trust Security & Workload Identity:** The GKE cluster operates with private nodes and a public, IAM-gated control-plane endpoint (or private control plane endpoint when `enable_private_endpoint = true`). Cloud resource access (GCS weights, Artifact Registry, Cloud SQL, BigQuery) is governed strictly by **Workload Identity Federation (WIF)**. Gateway client authentication is governed by LiteLLM virtual keys and master keys backed by Cloud SQL without service-account key leakage.
6. **Automated Workload Turndown:** Kubernetes CronJobs scale the vLLM serving deployment replicas between 0 (overnight) and 1 (work hours). GKE cluster autoscaling automatically reclaims the B200 spot node during off-hours to reduce GPU compute spend (ancillary services such as Cloud SQL, Redis, e2 system nodes, and ILBs continue standard baseline operations).

---

## 📈 Horizontal Scaling & Multi-Node Architecture

While **1x `a4-highgpu-8g` node ($TP=8$) serves as the turnkey MVP baseline**, the serving architecture separates **intra-node model execution** from **inter-node scale-out**, allowing the cluster to scale elastically from $1 \leftrightarrow N$ nodes based on real-time inferencing demand:

### 1. Zero-Copy Weight Fan-Out (`Hyperdisk ML ROX`)

* **Concurrent Multi-Node Mount:** Model weights are pre-staged onto a single **1,000 GB Hyperdisk ML** volume. After staging completes, the volume access mode is flipped to `READ_ONLY_MANY` (`pvc-glm52-weights-rox`).
* **Permanent Read-Only Mode:** Note that Hyperdisk ML becomes permanently read-only after flipping to `READ_ONLY_MANY`. Updating weights in the future requires recreating the disk resource (`terraform taint module.storage.google_compute_disk.staging_disk` or delete/re-apply, then re-running staging).
* **Instantaneous Scale-Out:** When scaling from $1$ to $N$ serving replicas across distinct physical `a4-highgpu-8g` hosts, each new pod attaches to the same pre-hydrated volume. New replicas reach `Ready` state in minutes instead of hours with zero network weight downloads.

### 2. Elastic Scaling & Operations

* **Manual Scale-Out:** Workload replicas can be adjusted on demand via `kubectl scale deployment/glm52-nvfp4-serving -n llm-serving --replicas=N` up to `gpu_pool_max_nodes` (default 2).
* **Horizontal Pod Autoscaler (Opt-In):** Automated horizontal pod autoscaling is optional and disabled by default (enabled via `ENABLE_HPA=true`). It scales the serving deployment on the custom vLLM Prometheus metric `vllm:num_requests_running` via the Custom Metrics Stackdriver Adapter (requiring the adapter deployment and the `roles/monitoring.viewer` IAM policy binding configured by `03_deploy_workloads.sh`).
* **GKE Cluster Autoscaler:** Automatically provisions additional `a4-highgpu-8g` Spot instances up to `gpu_pool_max_nodes` (default 2) when new serving pods are scheduled, and reclaims idle instances when traffic subsides.

### 3. Traffic Distribution & Centralized Caching

* **Kubernetes Service Load Balancing:** Incoming inference requests to the internal service `glm52-serving-svc` are distributed across all active serving pod replicas.
* **Shared Redis Cache:** All node replicas communicate with a centralized Cloud Memorystore Redis instance, enabling exact-match cache hits (single-digit-ms in-VPC, <50 ms verified via port-forward) across nodes.

### 4. 🌐 Optional: Multi-NIC Falcon RoCE Network Fabric & Jumbo Frames (MTU 8896)

#### Why RoCE / Multi-NIC is NOT Required for Single-Node Serving

* **Intra-Node NVLink:** The GLM-5.2 NVFP4 model is loaded onto an `a4-highgpu-8g` node using Tensor Parallelism ($TP=8$). All inter-GPU tensor synchronization (all-reduce, KV cache transfer) occurs over **5th-Gen NVLink / NVSwitch at 1.8 TB/s per GPU** (14.4 TB/s aggregate bidirectional bandwidth) inside the physical HGX B200 board.
* **Data Parallel Scale-Out ($DP=N$):** Scaling horizontally across nodes creates independent model replicas. Replicas never exchange tensor data; incoming user queries are standard HTTP/gRPC requests routed by the LiteLLM gateway over standard **gVNIC (MTU 1500)**.
* **GCP MTU Limits:** GCP VPC subnets support MTU 1500 (or max 8896 for A4 secondary interfaces). Standard Ethernet MTU 9000 is not a supported VPC parameter on Google Cloud.

#### How to Enable Multi-NIC RoCE (For Multi-Node TP > 8 or Distributed Training)
If extending this codebase to multi-node distributed training or serving ultra-large models requiring Multi-Host Tensor Parallelism ($TP > 8$ or $PP > 1$):

1. Enable the Multi-NIC feature flag in `terraform.tfvars`:

    ```hcl
    enable_roce_multinic = true
    ```
2. Uncomment the secondary RoCE network resources in `terraform/modules/network/main.tf` and `terraform/modules/node_pool_spot/main.tf`.
3. Apply the updated Terraform plan to provision 8 dedicated secondary subnets (`MTU 8896`) and attach them to the B200 Titanium NIC interfaces.

---

### 4. Mathematical Capacity Derivations

For a cluster scaled out to $N$ active `a4-highgpu-8g` nodes ($DP=N$, $TP=8$):

#### Total Cluster HBM3e Memory
$$ \text{Total Cluster HBM3e Memory} = N \times (8 \times 180\text{ GB}) = N \times 1,440\text{ GB} $$

#### Dedicated Cluster KV Cache Pool
$$ \text{Total Static Weights per Node} \approx 465\text{ GB (weights)} + 35\text{ GB (scales and activation buffers)} = 500\text{ GB} $$
$$ \text{Dedicated KV Cache Pool} \approx N \times (1,353.6\text{ GB (usable at 0.94 utilization)} - 500\text{ GB}) \approx N \times 850\text{ GB} $$

#### Max Concurrent 128k Context Sessions (Estimate)
Assuming standard PagedAttention allocation for 128k context windows ($\approx 21.8\text{ GB}$ per session at the model's default KV-cache precision):
$$ \text{Max Concurrent 128k Sessions} \approx N \times \left\lfloor \frac{850\text{ GB}}{21.8\text{ GB}} \right\rfloor \approx N \times 39\text{ concurrent streams} $$

> [!NOTE]
> 21.8 GB per session is an architectural estimate. The authoritative number is the "GPU KV cache size" logged by vLLM at startup; replace with measured values after first deployment.

#### Aggregate Token Throughput
Because intra-model tensor communication is 100% contained within 5th-Gen NVLink ($1.8\text{ TB/s}$ per GPU) inside each node, inter-node network overhead is zero. Total aggregate output token throughput scales linearly:
$$ \text{Aggregate Output Throughput} \approx N \times R_{\text{single\_node}} $$

#### Cluster Capacity Scaling Reference Table

| Cluster Scale ($N$ Nodes) | Total B200 GPUs | Total HBM3e Memory | Dedicated KV Cache Pool | Max Concurrent 128k Streams | Aggregate Output Throughput |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **$1\times$ Node ($DP=1$, MVP Baseline)** | 8 | 1,440 GB | ~850 GB | ~39 sessions | $1.0\times$ ($R_{\text{single}}$) |
| **$2\times$ Nodes ($DP=2$)** | 16 | 2,880 GB | ~1,700 GB | ~78 sessions | $2.0\times$ ($2 R_{\text{single}}$) |
| **$4\times$ Nodes ($DP=4$)** | 32 | 5,760 GB | ~3,400 GB | ~156 sessions | $4.0\times$ ($4 R_{\text{single}}$) |
| **$8\times$ Nodes ($DP=8$)** | 64 | 11,520 GB | ~6,800 GB | ~312 sessions | $8.0\times$ ($8 R_{\text{single}}$) |
| **$N\times$ Nodes ($DP=N$)** | $8N$ | $N \times 1,440\text{ GB}$ | $N \times 850\text{ GB}$ | $N \times 39\text{ sessions}$ | $N \times R_{\text{single}}$ |

*Note: $N > 2$ requires raising `gpu_pool_max_nodes` in Terraform and having sufficient NVIDIA B200 spot quota in the region.*

---

## 📁 Repository Directory Structure

```
glm-5.2-gcp-enterprise-serving/
├── .github/
│   └── workflows/
│       └── ci.yml                 # Automated static checks (Terraform, ShellCheck, Python, Kubeconform)
├── LICENSE                        # Apache-2.0 License
├── README.md                      # Executive overview and operational documentation (this file)
├── benchmarks/                    # Synthetic load testing and stress benchmark Python suites
│   ├── benchmark_glm52.py         # Standard enterprise performance benchmark (TTFT, TPOT, Throughput)
│   ├── massive_benchmark_glm52.py # High-concurrency stress test simulating 20 autonomous agent streams
│   ├── run_prefill_benchmark.py   # Empirical prompt-ingestion prefill benchmark (8k-in/16-out prompt tok/s)
│   ├── run_saturation_sweep.py    # Direct vLLM engine saturation sweep across concurrency levels c=1..64
│   └── soak_benchmark_glm52.py    # 30-minute continuous stability endurance test (1,800 seconds)
├── docker/                        # Container definitions for custom serving runtimes
│   └── Dockerfile                 # Pinned vLLM Blackwell serving container image definition (v0.25.1)
├── scripts/                       # Automated lifecycle Bash & Python scripts
│   ├── config.env.example         # Template configuration for environment variables and resource tags
│   ├── config.env                 # Active environment configuration (generated at setup, gitignored)
│   ├── requirements.txt           # Python client dependencies (BigQuery and Cloud Storage)
│   ├── 01_setup_and_check.sh      # Preflight CLI checks, password generation, API enablement, and tfvars sync
│   ├── 02_deploy_infra.sh         # Terraform infrastructure provisioning (GKE cluster, Hyperdisk ML, Cloud SQL)
│   ├── 03_deploy_workloads.sh     # Manifest rendering, NVMe RAID formatter, WIF RBAC, and vLLM deployment
│   ├── 04_verify_cluster.sh       # 5-point verification suite (Nodes, Gateway, Virtual Keys, Caching, and BigQuery)
│   ├── 05_run_benchmarks.sh       # Automated benchmark runner with automatic port-forwarding and summary output
│   ├── 06_destroy_all.sh          # Safe teardown deleting workloads, PVCs, and Terraform resources
│   ├── check_bq.py                # Python audit client querying real-time BigQuery trajectory streams
│   └── test_live_gateway.py       # Turnkey live chat completion script for verifying authenticated gateway inference
└── terraform/                     # Modular, enterprise-grade Terraform infrastructure definitions
    ├── main.tf                    # Root composition module integrating cluster, network, and storage modules
    ├── variables.tf               # Global input variable definitions and resource labeling contracts
    ├── outputs.tf                 # Cluster endpoint, storage, and database outputs
    ├── terraform.tfvars.example   # Example variables template
    ├── modules/
    │   ├── cluster/               # GKE cluster (private nodes; public, IAM-gated control-plane endpoint), WIF IAM bindings
    │   ├── network/               # Primary VPC, Cloud NAT, and secure firewall rules
    │   ├── node_pool_spot/        # Blackwell B200 Spot GPU node pools with compact placement policies
    │   ├── storage/               # 1,000 GB Hyperdisk ML ROX staging volume, Artifact Registry, trajectory bucket
    │   ├── database/              # Cloud SQL PostgreSQL instance (`glm52_gateway`) & Private Services Access (`PSA`)
    │   ├── cache/                 # Cloud Memorystore for Redis instance (`gateway_cache`) for rate-limiting & caching
    │   ├── audit/                 # BigQuery audit dataset (`glm52_enterprise_audit`)
    │   ├── gateway_iam/           # Workload Identity SA bindings for proxy database and audit access
    │   └── observability/         # Google Cloud Managed Service for Prometheus (GMP) dashboard configurations
    └── manifests/
        ├── templates/             # Parameterized .template manifests for automated rendering
        │   ├── 00-local-nvme-raid.yaml.template
        │   ├── 01-rbac-wif.yaml.template
        │   ├── 02-staging-pvc.yaml.template
        │   ├── 02-download-weights.yaml.template
        │   ├── 02-hydrate-weights-gcs.yaml.template
        │   ├── 03-vllm-spot-serving.yaml.template
        │   ├── 04-enterprise-gateway-config.yaml.template
        │   ├── 05-enterprise-gateway-deployment.yaml.template
        │   └── 06-model-observability-podmonitoring.yaml.template
        └── generated/             # Rendered runtime Kubernetes YAML manifests applied to GKE
```

---

## 🚀 Quickstart & Operational Guide

### Step 1: Environment & Virtual Environment Setup
To prevent PEP 668 system Python package conflicts on Debian/Ubuntu GCE environments, all scripts automatically configure and prioritize an isolated project virtual environment (`.venv`):

```bash
# Create and activate isolated Python virtualenv
python3 -m venv .venv
source .venv/bin/activate
pip install -r scripts/requirements.txt
```

### Step 2: Configure Environment Variables & IAM Prerequisites
Copy the configuration template and configure your project and compliance tags:

```bash
cp scripts/config.env.example scripts/config.env
nano scripts/config.env
```

#### 🛡️ Mandatory IAM Prerequisites
Running the full lifecycle runbook (infrastructure provisioning, GKE ClusterRole bindings, WIF, and BigQuery audit streaming) requires the following IAM roles on the operator identity:

* `roles/container.admin` (or `roles/container.clusterAdmin`): Required for creating GKE ClusterRole/ClusterRoleBindings in `03_deploy_workloads.sh`.
* `roles/servicenetworking.networksAdmin`: Required for Cloud SQL private IP to establish a Private Services Access VPC peering in `02_deploy_infra.sh`.
* `roles/iam.serviceAccountUser`: Required for attaching Workload Identity service accounts to GKE pods.
* `roles/resourcemanager.projectIamAdmin` (or `roles/editor`): Required for applying IAM policy bindings in Terraform and scripts.

To grant the required permissions:

```bash
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/container.admin"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/servicenetworking.networksAdmin" --condition=None
```

### Step 3: Run Preflight Checks & Synchronize Configuration
Run the setup script to verify prerequisite CLI dependencies, check GKE RBAC privileges, verify Python dependency imports (`google.cloud.bigquery`, `google.cloud.storage`), auto-generate secure passwords (`DB_PASSWORD` and `GATEWAY_MASTER_KEY`), and auto-populate `terraform/terraform.tfvars`:

```bash
./scripts/01_setup_and_check.sh
```

### Step 4: Provision Infrastructure via Terraform
Execute Phase 1 & 2 to build the private VPC network, GKE cluster, Blackwell Spot node pools, Cloud SQL PostgreSQL instance, Cloud Memorystore Redis, BigQuery dataset, and 1,000 GB Hyperdisk ML volume:

```bash
./scripts/02_deploy_infra.sh
```
*Note: `02_deploy_infra.sh` checks for pre-existing state in `gs://${TF_STATE_BUCKET}` and warns if existing tracked resources are detected.*

### Step 5: Render Manifests & Deploy Workloads
Execute Phase 3 to render Kubernetes templates, format local NVMe scratch disks in RAID 0 via DaemonSet, run the weight staging job, launch the `vLLM` Blackwell serving engine, and deploy the **Enterprise AI Gateway** on internal port `4000`:

```bash
./scripts/03_deploy_workloads.sh
```

### Step 6: Verify Cluster Health, Exact Caching & BigQuery Audits
Run the 5-point integration verification suite to check node readiness, authentication, virtual key generation, budget quota enforcement, Redis exact-match caching, and BigQuery trajectory streaming:

```bash
./scripts/04_verify_cluster.sh
```

### Step 7: Run Production & In-Cluster Performance Benchmarks
To evaluate inference latency (`TTFT`, `TPOT`, and `Throughput`), choose the appropriate benchmark mode:

#### ⚡ In-Cluster Benchmark Execution (Recommended for Sustained / Soak Testing)
`kubectl port-forward` tunnels are prone to socket resets under high concurrency or continuous load. For sustained or 30-minute soak benchmarks, run the benchmark as a **Kubernetes Job** inside the cluster targeting the Gateway ClusterIP DNS endpoint (`http://glm52-gateway-svc.llm-serving.svc.cluster.local:4000`):

```bash
# Run in-cluster soak benchmark (tolerates spot nodes, runs on system pool)
./scripts/05_run_benchmarks.sh --mode soak --in-cluster
```

#### 🖥️ Workstation Smoke Testing (Quick Verification)
For quick smoke tests from your local workstation via automatic port-forward:

```bash
./scripts/05_run_benchmarks.sh --mode standard --target gateway
```
*Note: Benchmark scripts detect port-forward tunnel drops (HTTP 000) and fail fast with actionable guidance to switch to `--in-cluster` mode.*

---

## 📈 Scaling, HPA & Cost/Latency Trade-Offs

### Cost vs. Latency Trade-Off Analysis

* **1x `a4-highgpu-8g` Node ($TP=8$ B200):** Serves up to ~3,089 tokens/sec sustained throughput at P50 TTFT ~83ms. Under high concurrency saturation (>20 concurrent streams), queue depth increases, driving TTFT P99 up to ~60s if replicas remain fixed at 1.
* **Elastic Scale-Out ($DP=N$ Replicas):** Adding a second B200 node doubles aggregate cluster throughput to ~6,178 tok/s and caps TTFT P99 under 200ms.
* **Server-Side Queue Bounding Knobs:** In `03-vllm-spot-serving.yaml`, vLLM is configured with `--max-num-seqs=64` and `--max-num-batched-tokens=8192` to bound queue-induced tail latency during request bursts.

### Enabling Horizontal Pod Autoscaling (HPA)
Automated pod autoscaling is enabled by setting `ENABLE_HPA="true"` in `scripts/config.env`. HPA scales the serving deployment up to `GPU_MAX_NODES` based on custom vLLM queue depth:

* **Metric:** `prometheus.googleapis.com|vllm:num_requests_waiting|gauge` (Target: 16 waiting requests)
* **Metric:** `prometheus.googleapis.com|vllm:num_requests_running|gauge` (Target: 20 running requests)

--------------------------------------------------------------------------------

### Phase 4 Direct Engine Saturation Sweep & Prefill Benchmarking

To run cache-bypassed direct GPU generation saturation sweeps across concurrency
levels ($c \in \{1, 8, 16, 32, 64\}$) or evaluate prompt prefill ingestion rate
on 8x B200 HGX GPUs:

```bash
# 1. Run prompt prefill / ingestion benchmark (8,192 input tokens -> 16 output tokens)
python3 benchmarks/run_prefill_benchmark.py

# 2. Run direct vLLM engine saturation sweep (max_tokens=256, ignore_eos=True, 0% cache hits)
python3 benchmarks/run_saturation_sweep.py
```

---

## 📦 Weight Cache Lifecycle

### Purpose & Storage Cost
A GCS weight cache bucket (`gs://<project>-glm52-weights-backup/nvfp4`) holds pre-converted safetensors shards (~433 GiB) for `nvidia/GLM-5.2-NVFP4`. Hydrating Hyperdisk ML from GCS takes **~2 minutes at ~4 GiB/s**, bypassing the ~10-minute Hugging Face Xet download. Storage costs ~$9–10/month and is intentionally kept outside Terraform state (`terraform/modules/storage/main.tf` does not manage it).

### Seeding & Hydration Commands

```bash
# 1. Use an existing GCS weight cache during deploy
export GCS_WEIGHTS_BUCKET="gs://YOUR_PROJECT_ID-glm52-weights-backup/nvfp4"
./scripts/03_deploy_workloads.sh

# 2. Seed the GCS cache automatically after a fresh Hugging Face download
export POPULATE_WEIGHTS_CACHE="true"
export GCS_WEIGHTS_BUCKET="gs://YOUR_PROJECT_ID-glm52-weights-backup/nvfp4"
./scripts/03_deploy_workloads.sh
```

### Protection & Purge Opt-In
By default, `./scripts/06_destroy_all.sh` retains the weight cache bucket and lists it in the **INTENTIONALLY RETAINED BUCKET INVENTORY** summary. To explicitly delete the cache bucket during teardown:

```bash
# Force teardown including the persistent GCS weight cache bucket
PURGE_WEIGHTS_CACHE=true ./scripts/06_destroy_all.sh
```

---

## 🧹 Idempotent Teardown & Clean Purge

### Automated Teardown
When testing is complete, run the teardown script to safely drain Kubernetes workloads, release Persistent Volumes, and run `terraform destroy`:

```bash
./scripts/06_destroy_all.sh
```

`06_destroy_all.sh` is completely idempotent and self-healing:

1. Proactively deletes Cloud SQL databases (`glm52_gateway`) to release owned database roles before Terraform user deletion (preventing role drop dependency errors).
2. Sets `deletion_policy = "ABANDON"` on `google_service_networking_connection` and automatically cleans up dangling compute VPC peerings if Google Cloud SDN propagation delay occurs.

### Retained Storage & Bucket Purge Guide
To prevent accidental data loss, Terraform retains certain shared storage buckets. To completely purge retained buckets and ensure zero ongoing cloud spend:

```bash
# 1. Purge and delete the Terraform remote state bucket
gcloud storage rm --recursive "gs://${PROJECT_ID}-glm52-tfstate"

# 2. Purge and delete the Trajectory audit backup bucket
gcloud storage rm --recursive "gs://${PROJECT_ID}-glm52-trajectories"

# 3. (Optional) Delete custom weights cache bucket if created
gcloud storage rm --recursive "gs://${PROJECT_ID}-glm52-weights"
```

---

## ✅ Teardown Verification Checklist

Before considering a project teardown complete, verify the following:

* [x] **Kubernetes Workloads:** `kubectl get ns llm-serving` returns `NotFound`.
* [x] **Spot GPU Nodes:** `gcloud compute instances list --filter="name ~ glm-enterprise"` returns 0 instances.
* [x] **Cloud SQL:** `gcloud sql instances list --filter="name=glm52-gateway-db"` returns 0 instances.
* [x] **Cloud Memorystore Redis:** `gcloud redis instances list --region=europe-north1` returns 0 instances.
* [x] **Hyperdisk ML Volume:** `gcloud compute disks list --filter="name=glm-52-weights-rox"` returns 0 disks.
* [x] **Service Networking Peerings:** `gcloud compute networks peerings list --network=glm-enterprise-fi-primary` returns no active peerings.
* [x] **GCS Buckets:** Verified or purged `gs://${PROJECT_ID}-glm52-tfstate` and `gs://${PROJECT_ID}-glm52-trajectories`.

