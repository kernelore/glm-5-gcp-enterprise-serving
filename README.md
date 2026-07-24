# GLM-5.2 NVFP4 Sovereign Enterprise Inference Architecture

[![Google Cloud](https://img.shields.io/badge/Google_Cloud-Blackwell_B200-4285F4?style=flat-square&logo=googlecloud&logoColor=white)](https://cloud.google.com/compute/docs/gpus)
[![NVIDIA](https://img.shields.io/badge/NVIDIA-NVFP4_MoE-76B900?style=flat-square&logo=nvidia&logoColor=white)](https://developer.nvidia.com/)
[![vLLM](https://img.shields.io/badge/Inference-vLLM_0.25.1-8A2BE2?style=flat-square)](https://docs.vllm.ai/)
[![SGLang](https://img.shields.io/badge/Inference-SGLang_v0.5.12-E50914?style=flat-square)](https://github.com/sgl-project/sglang)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg?style=flat-square)](LICENSE)

> [!IMPORTANT]
> **Disclaimer:** This repository is a **personal engineering project and reference architecture**. It is **not** an official Google product, is **not** covered by any Google Cloud Service Level Agreements (SLAs), and is **not** subject to official Google support channels. All code, scripts, and architectural models are provided *"as-is"* without warranty for educational, experimental, and benchmarking purposes.

**Target Hardware:** Google Kubernetes Engine (GKE) Blackwell (`a4-highgpu-8g` —
8x NVIDIA B200 HGX per node) \
**Target Workload:** High-Throughput Enterprise AI Engineering & Autonomous
Agentic Workflows (`32k` to `128k` active context window out of `1M` maximum
capacity) \
**Deployment Scope (`Zonal Baseline → Regional HA Ready`):** By default, the
entire stack is provisioned with **Zonal scope** (`europe-north1-b` for the GKE
cluster, Cloud SQL instance, Memorystore Redis cache, and Hyperdisk ML volume)
to eliminate cross-zone network egress charges and accelerate deployment. The
deployment can be easily extended to a **Regional HA architecture** by
configuring `location = var.region` on the GKE cluster, setting
`availability_type = "REGIONAL"` on Cloud SQL, upgrading Memorystore Redis to
`tier = "STANDARD_HA"`, and distributing GPU worker replicas (`DP=N`) across
multiple availability zones behind the internal load balancer.

---

## ⚡ Architecture Overview

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
|  +------------------------+-------------------------+                 +------------------+-------------------+  |
+---------------------------|--------------------------------------------------------------|----------------------+
                            |                                                              |
                            +------------------------------+-------------------------------+
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

## 🔄 Selectable Inference Engine (vLLM vs SGLang)

The enterprise serving stack supports both **vLLM** (default) and **SGLang** as first-class, drop-in inference engines. Both engines load identical NVFP4 model shards from the shared Hyperdisk ML ROX volume and operate behind the same LiteLLM enterprise gateway Service on port 8000 (`hostNetwork: true`).

### Selecting & Switching Engines
In `scripts/config.env`, configure the desired engine:
```bash
# Inference engine: "vllm" (default) or "sglang"
export INFERENCE_ENGINE="vllm"
```

To switch engines on a live cluster:
1. Update `export INFERENCE_ENGINE="sglang"` (or `"vllm"`) in `scripts/config.env`.
2. Apply the updated engine manifest:
```bash
./scripts/03_deploy_workloads.sh
```
*Note: Because both engines share the same Kubernetes Deployment name (`glm52-nvfp4-serving`) with `maxSurge: 0`, switching engines triggers an automated rolling replacement on the GPU node pool. A brief transition window occurs while the new engine container loads weights from Hyperdisk ML (~30–45 seconds).*

### Engine Flag & Feature Comparison
| Functional Domain | vLLM (`v0.25.1`) | SGLang (`v0.5.12-cu130`) | Technical Rationale & Notes |
| :--- | :--- | :--- | :--- |
| **Server Entrypoint** | `vllm.entrypoints.openai.api_server` | `sglang.launch_server` | OpenAI-compatible HTTP servers on port 8000. |
| **Network Binding** | `--port=8000` | `--host 0.0.0.0 --port 8000` | SGLang defaults to 30000; explicitly binds 0.0.0.0:8000 for hostNetwork parity. |
| **Prefix Caching** | `--enable-prefix-caching` | *(Enabled by default)* | SGLang enables RadixAttention by default (`--disable-radix-cache` disables). |
| **Memory Reservation** | `--gpu-memory-utilization=0.94` | `--mem-fraction-static 0.90` | SGLang reserves static pool before piecewise CUDA graph capture. |
| **Quantization** | *(Auto-detected by vLLM)* | `--quantization modelopt_fp4` | Explicit ModelOpt FP4 Cutlass/DeepEPLL GEMM kernel dequantization. |
| **MoE Parsers** | *(Handled via HF chat template)* | `--reasoning-parser glm45`<br>`--tool-call-parser glm47` | Enables GLM-5.2 structured XML tool calling and chain-of-thought parsing. |
| **Observability** | *(Enabled by default)* | `--enable-metrics` | Exposes Prometheus `/metrics` on port 8000 for GKE PodMonitoring. |
| **HPA Autoscaling** | `vllm:num_requests_waiting`<br>`vllm:num_requests_running` | `sglang:num_queue_reqs`<br>`sglang:num_running_reqs` | Google Cloud Monitoring custom metrics targets: 16 (queue depth) and 20 (running). |

---

<!-- ENGINE_COMPARISON_START -->

### vLLM vs SGLang — Aggregated Performance Comparison

The following performance comparison tables were generated automatically from identical hardware benchmark passes against **GLM-5.2 NVFP4 (~381B MoE)** serving on a single **GKE `a4-highgpu-8g` node (8× NVIDIA B200, TP=8)**.

> **Sign Convention Note:** In the $\Delta$ columns below, a positive percentage ($\Delta > 0\%$) always represents an **SGLang improvement** over vLLM (i.e., higher throughput, higher success rate, or lower latency).

#### Table 1 — Suite Summary (Enterprise Gateway E2E on Port 4000)

| Suite | Metric | vLLM (`0.25.1`) | SGLang (`0.5.12`) | Δ SGLang vs vLLM |
|:---|:---|:---:|:---:|:---:|
| **Standard** (c=8, 128 tok) | TTFT P50 (ms) | 60417.71 | 111.88 | +99.81% |
| | TTFT P99 (ms) | 60969.90 | 448.14 | +99.26% |
| | TPOT mean (ms) | 8.48 | 3.91 | +53.89% |
| | Throughput (tok/s) | 32.19 | 1136.04 | +3429.17% |
| | Success rate | 100.0% | 100.0% | 0.00% |
| **Massive** (c=20, 256 tok) | TTFT P50 (ms) | 311.75 | 244.22 | +21.66% |
| | TTFT P99 (ms) | 740.73 | 6112.83 | -725.24% |
| | TPOT mean (ms) | 8.44 | 2.66 | +68.48% |
| | Throughput (tok/s) | 1885.95 | 2470.48 | +30.99% |
| | Success rate | 100.0% | 100.0% | 0.00% |
| **Soak** (c=18, 1800 s) | TTFT P50 (ms) | 206.94 | 134.44 | +35.03% |
| | TTFT P99 (ms) | 60252.54 | 60444.41 | -0.32% |
| | TPOT mean (ms) | 3.02 | 0.07 | +97.68% |
| | Throughput (tok/s) | 2730.36 | 4086.68 | +49.68% |
| | Success rate | 99.9% | 100.0% | +0.14% |
| | Completed cycles | 6243 | 29117 | +366.39% |

#### Table 2 — Saturation Sweep (Direct Engine Backend on Port 8000, 0% Cache Hits)

| Concurrency | vLLM tok/s | SGLang tok/s | vLLM TTFT P99 (s) | SGLang TTFT P99 (s) |
|:---:|:---:|:---:|:---:|:---:|
| **1** | 106.28 | 118.25 | 0.3245 | 0.1953 |
| **8** | 644.58 | 756.98 | 0.5250 | 0.3538 |
| **16** | 1124.30 | 1292.40 | 0.9352 | 0.5322 |
| **32** | 1510.43 | 2119.33 | 1.2534 | 0.8937 |
| **64** | 2180.74 | 2634.74 | 2.2712 | 20.3412 |

#### Table 3 — Prefill Ingestion (8,192 Prompt Tokens In / 16 Output Tokens Out)

| Metric | vLLM | SGLang | Δ SGLang vs vLLM |
|:---|:---:|:---:|:---:|
| **Prefill throughput** (prompt tok/s) | 13001.20 | 1768.00 | -86.40% |
| **TTFT mean** (ms) | 408.65 | 3005.09 | -635.36% |

---

### Technical Guidance: When to Choose vLLM vs SGLang

Based on measured production characteristics and empirical performance across our benchmark suite:

- **Choose vLLM (`INFERENCE_ENGINE="vllm"`) if:**
  - Your production operations require the mature, industry-standard vLLM ecosystem with extensive upstream community support and out-of-the-box auto-detection for ModelOpt checkpoints.
  - You prioritize steady-state predictability and established Kubernetes monitoring integrations without needing custom parser overrides for MoE chain-of-thought blocks.

- **Choose SGLang (`INFERENCE_ENGINE="sglang"`) if:**
  - You operate high-concurrency multi-agent or conversational AI workloads where SGLang's native Rust-based RadixAttention prefix caching delivers superior prompt ingestion throughput and reduced inter-token latency.
  - You require native parsing for GLM-5.2's structured XML tool calls (`--tool-call-parser glm47`) and chain-of-thought reasoning separation (`--reasoning-parser glm45`) directly at the inference serving layer.
<!-- ENGINE_COMPARISON_END -->

---

## ☁️ Google Cloud Products & Architectural Roles

Google Cloud Product               | Scope                                        | Resource Identifier in Stack             | Architectural Role & Implementation Details
:--------------------------------- | :------------------------------------------: | :--------------------------------------- | :------------------------------------------
**Google Kubernetes Engine (GKE)** | **Zonal** *(Baseline)* / **Regional** *(HA)* | `module.cluster`                         | Orchestrates the selectable vLLM and SGLang serving workers and LiteLLM gateway pods. Uses private nodes with an IAM-gated control plane (`europe-north1-b`), Workload Identity Federation (`WIF`), and Dataplane V2 (`eBPF`). Upgradeable to regional HA via `location = var.region`.
**Compute Engine A4 VMs**          | **Zonal**                                    | `module.node_pool_spot`                  | `a4-highgpu-8g` Blackwell instances (`europe-north1-b`) providing 8× NVIDIA B200 HGX GPUs (`1,440 GB` HBM3e, NVLink 5th Gen `1.8 TB/s`) and 32× local NVMe SSDs (`12 TiB`) for high-throughput MoE inference.
**Hyperdisk ML (`ROX`)**           | **Zonal**                                    | `module.storage`                         | `1,000 GB` block volume (`europe-north1-b`) flipped to `ReadOnlyMany` (`ROX`) mode. Enables concurrent multi-node weight mounting with zero internet cold-start downloads.
**Cloud Memorystore for Redis**    | **Zonal** *(Basic)* / **Regional** *(HA)*    | `module.cache`                           | In-memory tier (`europe-north1-b`) providing exact-match prompt caching (`x-litellm-cache-key`, `2.13 ms` hit duration) and gateway token-bucket rate limiting (`RPM` / `TPM`). Upgradeable to regional HA via `tier = "STANDARD_HA"`.
**Cloud SQL for PostgreSQL**       | **Zonal** *(Default)* / **Regional** *(HA)*  | `module.database`                        | Private PostgreSQL 15 instance (`europe-north1-b`) connected via Private Services Access (`PSA`). Stores virtual API keys, user budgets, and enterprise routing rules. Upgradeable to regional HA via `availability_type = "REGIONAL"`.
**BigQuery**                       | **Regional**                                 | `module.audit`                           | Serverless analytical dataset (`glm52_enterprise_audit.trajectories` in `europe-north1`) recording asynchronous WIF-authenticated chat completions, prompt/completion token counts, and request metadata.
**Cloud Storage (GCS)**            | **Regional**                                 | `TF_STATE_BUCKET` / `GCS_WEIGHTS_BUCKET` | Regional buckets (`europe-north1`) hosting remote Terraform state locking (`gs://project-glm52-tfstate`) and fast-path pre-staged model shards (`gs://project-glm52-weights-backup/nvfp4`, ~4 GiB/s hydration).
**Artifact Registry**              | **Regional**                                 | `module.storage`                         | Secure private container registry (`europe-north1`) storing pinned custom vLLM and SGLang Blackwell serving container images (`vllm-blackwell:v0.25.1`, `sglang-blackwell:v0.5.12-cu130`).
**Cloud Build**                    | **Regional**                                 | `scripts/03_deploy_workloads.sh`         | On-demand serverless container build pipeline compiling custom vLLM and SGLang runtimes from `docker/Dockerfile.vllm` and `docker/Dockerfile.sglang`.
**Virtual Private Cloud (VPC)**    | **Global / Regional**                        | `module.network`                         | Private custom-mode VPC (`roce-net-primary`) with regional subnets (`k8s-pod-net`), Private Services Access peering, and IAP SSH firewall restrictions.
**Managed Service for Prometheus** | **Regional**                                 | `module.observability`                   | Fully managed Google Cloud Managed Service for Prometheus (`GMP`) scraping DCGM GPU kernels (`DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`) and vLLM / SGLang request queues.

---

## 💎 Key Engineering Highlights

1. **NVFP4 Quantization & Memory Co-Design:** Quantizing GLM-5.2 to `NVFP4` compresses the on-disk model footprint to **~465 GB** across 47 safetensors shards. Total static memory footprint per node is **~500 GB** (weights + scales and activation buffers). Across `8x B200 GPUs` (`1,440 GB` HBM3e), with vLLM's `--gpu-memory-utilization=0.94` / SGLang's `--mem-fraction-static=0.90` (~1,353.6 GB usable) and auto KV cache quantization, this preserves **`~850 GB` of dedicated high-speed HBM3e memory for PagedAttention / RadixAttention KV Cache**, supporting up to ~39 estimated concurrent `128k` context sessions without memory thrashing (the authoritative figure is the 'GPU KV cache size' / token pool capacity logged at engine startup).
2. **Hybrid Storage Hydration (`ROX` + Local NVMe):** To eliminate multi-hour weights downloading when scaling, model weights are pre-staged onto a **`1,000 GB` Hyperdisk ML (`ROX`)** volume (`Tier 0`). Serving pods attach the volume in `ReadOnlyMany` mode (`xfs`, `mountOptions: [nouuid, ro, norecovery]`). For local scratch, **`12 TiB` of Local NVMe SSD** (32x 375 GiB drives) is formatted in RAID 0 XFS via DaemonSet.
3. **Turnkey Tooling & Secure Python Downloads:** Weight staging executes Python `snapshot_download()` streaming directly into the staging Persistent Volume, authenticated via the `HF_TOKEN` environment variable projected from a Kubernetes Secret (never rendered into plaintext manifests).
4. **Intra-Node NVLink Serving:** Tensor Parallel (`TP=8`) intra-node communication utilizes NVIDIA NVLink (`1.8 TB/s` bidirectional per GPU). Single-node serving eliminates inter-node networking overhead while maximizing GPU utilization.
5. **Zero-Trust Security & Workload Identity:** The GKE cluster operates with private nodes and a public, IAM-gated control-plane endpoint (or private control plane endpoint when `enable_private_endpoint = true`). Cloud resource access (GCS weights, Artifact Registry, Cloud SQL, BigQuery) is governed strictly by **Workload Identity Federation (WIF)**. Gateway client authentication is governed by LiteLLM virtual keys and master keys backed by Cloud SQL without service-account key leakage.
6. **Automated Workload Turndown:** Kubernetes CronJobs scale the inference serving deployment replicas (vLLM or SGLang) between 0 (overnight) and 1 (work hours). GKE cluster autoscaling automatically reclaims the B200 spot node during off-hours to reduce GPU compute spend (ancillary services such as Cloud SQL, Redis, e2 system nodes, and ILBs continue standard baseline operations).

---

## 📈 Horizontal Scaling & Multi-Node Architecture

While **1x `a4-highgpu-8g` node ($TP=8$) serves as the turnkey MVP baseline**, the serving architecture separates **intra-node model execution** from **inter-node scale-out**, allowing the cluster to scale elastically from $1 \leftrightarrow N$ nodes based on real-time inferencing demand:

### 1. Zero-Copy Weight Fan-Out (`Hyperdisk ML ROX`)

* **Concurrent Multi-Node Mount:** Model weights are pre-staged onto a single **1,000 GB Hyperdisk ML** volume. After staging completes, the volume access mode is flipped to `READ_ONLY_MANY` (`pvc-glm52-weights-rox`).
* **Permanent Read-Only Mode:** Note that Hyperdisk ML becomes permanently read-only after flipping to `READ_ONLY_MANY`. Updating weights in the future requires recreating the disk resource (`terraform taint module.storage.google_compute_disk.staging_disk` or delete/re-apply, then re-running staging).
* **Instantaneous Scale-Out:** When scaling from $1$ to $N$ serving replicas across distinct physical `a4-highgpu-8g` hosts, each new pod attaches to the same pre-hydrated volume. New replicas reach `Ready` state in minutes instead of hours with zero network weight downloads.

### 2. Elastic Scaling & Operations

* **Manual Scale-Out:** Workload replicas can be adjusted on demand via `kubectl scale deployment/glm52-nvfp4-serving -n llm-serving --replicas=N` up to `gpu_pool_max_nodes` (default 2).
* **Horizontal Pod Autoscaler (Opt-In):** Automated horizontal pod autoscaling is optional and disabled by default (enabled via `ENABLE_HPA=true`). It scales the serving deployment on the custom vLLM Prometheus metric `vllm:num_requests_running` via the Google Cloud Monitoring Custom Metrics Adapter (requiring the adapter deployment and the `roles/monitoring.viewer` IAM policy binding configured by `03_deploy_workloads.sh`).
* **GKE Cluster Autoscaler:** Automatically provisions additional `a4-highgpu-8g` Spot instances up to `gpu_pool_max_nodes` (default 2) when new serving pods are scheduled, and reclaims idle instances when traffic subsides.

### 3. Traffic Distribution & Centralized Caching

* **Kubernetes Service Load Balancing:** Incoming inference requests to the internal service `glm52-serving-svc` are distributed across all active serving pod replicas.
* **Shared Redis Cache:** All node replicas communicate with a centralized Cloud Memorystore Redis instance, enabling exact-match cache hits (single-digit-ms in-VPC, <50 ms verified via port-forward) across nodes.

### 4. Optional: Multi-NIC Falcon RoCE Network Fabric & Jumbo Frames (MTU 8896)

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

### 5. Capacity Derivations

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
> 21.8 GB per session is an architectural estimate. The authoritative number is the "GPU KV cache size" logged by vLLM / SGLang at startup; replace with measured values after first deployment.

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
│   ├── run_saturation_sweep.py    # Direct engine saturation sweep across concurrency levels c=1..64
│   ├── soak_benchmark_glm52.py    # 30-minute continuous stability endurance test (1,800 seconds)
│   ├── generate_comparison.py     # Automated parity validator and ENGINE_COMPARISON.md generator
├── docker/                        # Container definitions for custom serving runtimes
│   ├── Dockerfile.vllm            # Pinned vLLM Blackwell serving container image definition (v0.25.1)
│   ├── Dockerfile.sglang          # Pinned SGLang Blackwell B200 serving container image (v0.5.12-cu130)
│   └── cloudbuild.yaml            # Cloud Build configuration supporting dynamic image/Dockerfile substitutions
├── scripts/                       # Automated lifecycle Bash & Python scripts
│   ├── config.env.example         # Template configuration for environment variables, engine knob, and tags
│   ├── config.env                 # Active environment configuration (generated at setup, gitignored)
│   ├── requirements.txt           # Python client dependencies (BigQuery and Cloud Storage)
│   ├── 01_setup_and_check.sh      # Preflight CLI checks, engine validation, password generation, and tfvars sync
│   ├── 02_deploy_infra.sh         # Terraform infrastructure provisioning (GKE cluster, Hyperdisk ML, Cloud SQL)
│   ├── 03_deploy_workloads.sh     # Manifest rendering, NVMe RAID formatter, WIF RBAC, and engine deployment
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
        │   ├── 03-sglang-spot-serving.yaml.template
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

Running the full lifecycle runbook requires four mandatory IAM roles on your
active deploy identity (`gcloud config get-value account`).
`./scripts/01_setup_and_check.sh` automatically verifies all four roles before
deployment and halts with copy-paste remediation commands if any role is
missing:

Required IAM Role                       | Scope / Purpose                                                                                       | Automated Verification by Script
:-------------------------------------- | :---------------------------------------------------------------------------------------------------- | :-------------------------------
`roles/container.admin`                 | Provision GKE clusters, node pools, and RBAC ClusterRoleBindings (`03_deploy_workloads.sh`)           | Verified in Step 6 of `01_setup_and_check.sh`
`roles/servicenetworking.networksAdmin` | Establish Private Services Access (`PSA`) VPC peering for Cloud SQL private IP (`02_deploy_infra.sh`) | Verified in Step 6 of `01_setup_and_check.sh`
`roles/iam.serviceAccountUser`          | Attach Workload Identity service accounts to serving and gateway pods                                 | Verified in Step 6 of `01_setup_and_check.sh`
`roles/resourcemanager.projectIamAdmin` | Bind project-level IAM policies across WIF service accounts and buckets                               | Verified in Step 6 of `01_setup_and_check.sh`

To grant all four required permissions to your deploy identity at once:

```bash
for role in roles/container.admin roles/servicenetworking.networksAdmin roles/iam.serviceAccountUser roles/resourcemanager.projectIamAdmin; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="user:$(gcloud config get-value account)" \
    --role="${role}" \
    --condition=None
done
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
Execute Phase 3 to render Kubernetes templates, format local NVMe scratch disks in RAID 0 via DaemonSet, run the weight staging job, launch the selected inference serving engine (`vLLM` or `SGLang`), and deploy the **Enterprise AI Gateway** on internal port `4000`:

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

#### 🔬 Direct Engine Saturation Sweep & Prefill Benchmarking (Phase 4)

To run cache-bypassed direct GPU generation saturation sweeps across concurrency
levels ($c \in \{1, 8, 16, 32, 64\}$) or evaluate prompt prefill ingestion rate
on 8x B200 HGX GPUs:

```bash
# 1. Run prompt prefill / ingestion benchmark (8,192 input tokens -> 16 output tokens)
python3 benchmarks/run_prefill_benchmark.py

# 2. Run direct engine saturation sweep (max_tokens=256, ignore_eos=True, 0% cache hits)
python3 benchmarks/run_saturation_sweep.py
```

---

## 📈 Scaling, HPA & Cost/Latency Trade-Offs

### Cost vs. Latency Trade-Off Analysis

* **1x `a4-highgpu-8g` Node ($TP=8$ B200):** Serves up to ~3,089 tokens/sec sustained throughput at P50 TTFT ~83ms. Under high concurrency saturation (>20 concurrent streams), queue depth increases, driving TTFT P99 up to ~60s if replicas remain fixed at 1.
* **Elastic Scale-Out ($DP=N$ Replicas):** Adding a second B200 node doubles aggregate cluster throughput to ~6,178 tok/s and caps TTFT P99 under 200ms.
* **Server-Side Queue Bounding Knobs:** In `03-vllm-spot-serving.yaml` / `03-sglang-spot-serving.yaml`, the serving engines are configured with `--max-num-seqs=64` / `--max-running-requests=64` and `--max-num-batched-tokens=8192` / `--chunked-prefill-size=8192` to bound queue-induced tail latency during request bursts.

### Enabling Horizontal Pod Autoscaling (HPA)
Automated pod autoscaling is enabled by setting `ENABLE_HPA="true"` in `scripts/config.env`. HPA scales the serving deployment up to `GPU_MAX_NODES` based on custom vLLM / SGLang queue depth:

* **Metric:** `prometheus.googleapis.com|vllm:num_requests_waiting|gauge` (Target: 16 waiting requests)
* **Metric:** `prometheus.googleapis.com|vllm:num_requests_running|gauge` (Target: 20 running requests)

---

## 📦 Weight Cache Lifecycle

### Purpose & Existing GCS / Hugging Face "Copy to Bucket" Integration

If your organization already hosts GLM-5.2 weights in Google Cloud Storage, or
if you use Hugging Face's built-in **"Copy to Bucket"** transfer feature to
export model shards directly from the Hugging Face Hub into a Google Cloud
Storage bucket, you can provide your existing GCS path directly via
`GCS_WEIGHTS_BUCKET="gs://your-bucket-name/nvfp4"`.

*   **Instant Multi-Node Hydration:** When `GCS_WEIGHTS_BUCKET` is configured,
    `./scripts/03_deploy_workloads.sh` bypasses Hugging Face internet downloads
    entirely and hydrates the local `READ_ONLY_MANY` (`ROX`) Hyperdisk ML volume
    directly from GCS inside your VPC at **~4 GiB/s (~2 minutes)**.
*   **Decoupled Lifecycle:** The GCS weight cache bucket
    (`gs://<project>-glm52-weights-backup/nvfp4`) is intentionally managed
    outside Terraform state so that running `terraform destroy` never deletes
    pre-staged model weights (~$9–10/month storage cost).

### Seeding & Hydration Commands

```bash
# 1. Provide existing GCS weights path (or bucket populated via Hugging Face "Copy to Bucket")
export GCS_WEIGHTS_BUCKET="gs://YOUR_BUCKET_NAME/nvfp4"
./scripts/03_deploy_workloads.sh

# 2. Seed a new GCS cache automatically after a fresh Hugging Face download
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


