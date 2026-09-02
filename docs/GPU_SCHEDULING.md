# GPU Scheduling on Kubernetes: Device Plugin vs. DRA

Two models exist for getting GPUs to pods. **Learn both** — the classic device plugin is what almost all production clusters run today; DRA is what they're migrating to. Being able to explain the difference is a strong interview signal.

---

## Model 1 — Device Plugin (classic, 2017–present)

**How it works:** a DaemonSet on each GPU node advertises `nvidia.com/gpu` to the kubelet as an *opaque integer resource*. You request whole units:

```yaml
resources:
  limits:
    nvidia.com/gpu: "1"
```

The scheduler treats GPUs as a countable quantity — like CPU or memory. It knows a node has "4 GPUs", nothing more.

**Limitations (this is the interview answer):**
- **No attributes.** The scheduler can't distinguish an A10G with 24GB from an H100 with 80GB. Both are just `1`.
- **No topology awareness.** It can't prefer two GPUs connected by NVLink over two that aren't — which matters enormously for multi-GPU training.
- **Sharing is bolted on.** MIG partitioning and time-slicing require separate configuration and re-advertising as different resource names.
- **Whole-device granularity.** You can't express "I need 20GB of GPU memory."

**In this repo:** `k8s/gpu/nvidia-device-plugin.yaml` + `k8s/vllm/deployment.yaml`

---

## Model 2 — Dynamic Resource Allocation (DRA)

**Status:** core DRA graduated to **GA in Kubernetes 1.34**. NVIDIA donated its DRA driver to the CNCF at KubeCon EU 2026, and the KAI Scheduler became a CNCF sandbox project. This is the direction the ecosystem is moving.

**How it works:** the driver publishes **ResourceSlices** describing each device's real attributes — memory in bytes, compute capability, MIG profile availability, NVLink topology. You then describe what you *need* via a **ResourceClaim** (or ResourceClaimTemplate) referencing a **DeviceClass**, and the scheduler matches against structured parameters.

```yaml
# Conceptually: "give me a GPU from this class" — and the scheduler
# can filter/select on real attributes rather than counting integers.
resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-gpu
```

**Why it matters:**
- Scheduler decisions based on **actual device properties**, not opaque counts
- **Topology-aware** allocation (NVLink peers) for distributed training
- Sharing (MIG, time-slicing) becomes a first-class API concern rather than side configuration
- Claims can be shared across pods in controlled ways

**API note:** DRA moved from `resource.k8s.io/v1beta1` to `resource.k8s.io/v1` at GA in 1.34 — a breaking change. Manifests written against older tutorials will not apply.

**In this repo:** `k8s/dra/`

---

## The gotcha that will come up in interviews

**DRA is not currently compatible with Karpenter or EKS Auto Mode.** You must use EKS managed node groups or self-managed nodes with the DRA drivers installed.

This is a live trade-off, and knowing it is genuinely valuable:

| | Device plugin | DRA |
|---|---|---|
| Karpenter autoscaling | ✅ works | ❌ not supported yet |
| Scheduler sees GPU attributes | ❌ integer only | ✅ structured |
| Topology / NVLink aware | ❌ | ✅ |
| Production maturity | ✅ nearly a decade | ⚠️ GA as of 1.34 |
| EKS support | all versions | 1.33+, 1.34+ recommended |

**Practical consequence for this repo:** the Karpenter exercise (Week 8) and the DRA exercise (Week 8b) can't run on the same node pool. Do them separately, and note in your write-up *why* — "I built both and hit the Karpenter/DRA incompatibility" is a far better story than either alone.

---

## Suggested exercise order

1. **Week 7:** device plugin + vLLM. Get an LLM answering requests on a GPU you scheduled. Understand what `nvidia.com/gpu: 1` actually does end-to-end — the plugin advertises, kubelet allocates, the container runtime mounts device files, and the NVIDIA driver does the real work.
2. **Week 8:** Karpenter managing the GPU pool with the device plugin (spot interruption handling).
3. **Week 8b:** tear down Karpenter, switch the managed node group to DRA. Deploy the same vLLM workload via a ResourceClaimTemplate. Compare.
4. **Week 9:** write it up — benchmarks plus the scheduling comparison. This becomes the centrepiece of the artifact README.

## Reference material

- KubeCon EU 2026: *"GPUs on Kubernetes: What Actually Happens When You Request nvidia.com/gpu: 1"* — best single video on the classic path
- Kubernetes v1.34 DRA release blog
- AWS EKS docs: "Manage hardware devices on Amazon EKS"
- NVIDIA DRA driver repo (`NVIDIA/k8s-dra-driver-gpu`)
