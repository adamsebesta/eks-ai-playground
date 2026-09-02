# ECS → EKS (+ GPUs): the transition map

Written for someone with 5 years of production ECS/Terraform/AWS experience moving toward Kubernetes and GPU workloads. The point of this doc is to be precise about **what transfers, what's genuinely new, and where the real gap is** — so learning time goes to the right places.

---

## 1. The one mental model shift

**ECS is mostly imperative.** You call an API — "run 3 copies of this task definition" — and AWS acts. When something breaks, you debug a call: what did I ask for, what did AWS do, what did the response say.

**Kubernetes is reconciliation.** You declare desired state, and a pile of independent controllers continuously compare desired vs. actual and correct the drift. Nothing "runs your command" — the Deployment controller notices a ReplicaSet doesn't match spec, the ReplicaSet controller notices pods are missing, the scheduler notices unbound pods, kubelet notices assigned pods that aren't running.

When something breaks in Kubernetes you're debugging **a loop**: *why does this controller keep believing it needs to act?* That reframing is the single biggest adjustment.

> **Good news:** if you write Terraform, you already think this way. Declaring desired state and letting something reconcile it is exactly `terraform apply`. Kubernetes just never stops applying.

---

## 2. Concept mapping

### Workloads

| ECS | EKS / Kubernetes | Notes |
|---|---|---|
| Task definition | Pod template (inside a Deployment) | The pod, not the container, is the unit of scheduling |
| Task | Pod | A pod can hold multiple containers sharing network + volumes |
| Service (desired count) | Deployment → ReplicaSet | Deployment adds rollout/rollback semantics ECS handles differently |
| — | StatefulSet | Stable identity + storage per replica; no ECS equivalent |
| Daemon scheduling strategy | DaemonSet | One pod per node — how the GPU device plugin ships |
| Scheduled task (EventBridge) | CronJob | Native object rather than an external trigger |
| Run task (one-off) | Job | With retry/completion semantics built in |
| Container `essential: true` | Pod restart policy + probes | Health semantics are richer: liveness, readiness, startup |
| Task placement constraints | nodeSelector, affinity/anti-affinity, taints/tolerations, topology spread | **Vastly deeper — this is where GPU scheduling lives** |
| Capacity provider | Node group / Karpenter | Karpenter ≈ smarter, faster capacity provider |

### Networking

| ECS | EKS / Kubernetes | Notes |
|---|---|---|
| awsvpc mode (ENI per task) | VPC CNI (ENI-backed pod IPs) | **Closest analog in the whole list** — pods get real VPC IPs |
| ALB + target group | Service + Ingress + AWS LB Controller | Ingress is a spec; the controller provisions the ALB |
| Service discovery (Cloud Map) | Service + CoreDNS | `svc-name.namespace.svc.cluster.local` resolves in-cluster |
| — | ClusterIP / kube-proxy | Virtual IPs load-balanced by iptables/IPVS; no ECS equivalent |
| Security groups | Security groups **+** NetworkPolicy | NetworkPolicy is pod-level, enforced by the CNI |
| — | Service mesh / Cilium / eBPF | Advanced surface Anthropic-tier roles explicitly ask about |

> Networking is the area that generates the most confusion coming from ECS — **[section 3](#3-networking-in-detail-the-biggest-ecs-brain-confusion) expands every row above.**

### Identity, config, storage

| ECS | EKS / Kubernetes | Notes |
|---|---|---|
| Task IAM role | IRSA / EKS Pod Identity | Direct analog: AWS identity scoped to a workload |
| Execution role | Node IAM role | Pulls images, writes logs |
| Secrets from SSM/Secrets Manager | Secret objects (+ External Secrets Operator) | K8s Secrets are base64, *not* encrypted by default — enable encryption at rest |
| Environment variables in task def | ConfigMap / Secret | Decoupled from the workload spec |
| EFS/EBS volume in task def | PV / PVC / StorageClass / CSI driver | An abstraction layer ECS doesn't have |

### Operations

| ECS | EKS / Kubernetes | Notes |
|---|---|---|
| Service auto scaling (target tracking) | HPA (+ KEDA for event-driven) | HPA on custom metrics needs a metrics adapter |
| Cluster auto scaling | Cluster Autoscaler / Karpenter | Karpenter provisions right-sized nodes directly |
| `aws ecs execute-command` | `kubectl exec` / `kubectl debug` | `kubectl debug` (ephemeral containers) has no ECS equivalent |
| CloudWatch Container Insights | Metrics Server, Prometheus, **Datadog** | Your Datadog experience transfers directly — their K8s integration is strong |
| Deployment circuit breaker | Rollout strategy + probes (+ Argo Rollouts) | Progressive delivery is a whole ecosystem here |
| — | CRDs + Operators | **No ECS equivalent.** The platform is programmable — why every vendor ships an operator |
| — | RBAC | Cluster-internal authz, separate from IAM. CKS territory |
| — | Admission controllers / policy engines | Gatekeeper, Kyverno, Pod Security Standards |

---

## 3. Networking in detail (the biggest ECS-brain confusion)

The one-line table rows above undersell this, and it's the area that generates the most "wait, is that real or is it a Kubernetes thing?" questions. Short answer: **the AWS parts are all real. Nothing is replaced by an in-cluster imitation.**

### 3.1 The VPC is your VPC

EKS runs in the VPC you provision — the one in this repo's `terraform/main.tf`: three AZs, private subnets for nodes, single NAT. Nodes are ordinary EC2 instances in your subnets. There is no hidden AWS-managed network.

### 3.2 VPC CNI — pods get real VPC IPs

This is the single most important networking fact about EKS, and it's *unusual* among Kubernetes distributions.

Most Kubernetes uses an **overlay network**: pods get IPs from a fake cluster-internal CIDR that doesn't exist in the underlying network, and inter-node traffic is encapsulated (VXLAN etc.).

**EKS's default VPC CNI doesn't do that.** Pods receive real VPC IP addresses, allocated as secondary IPs on the node's ENIs. Functionally this is the same model as **awsvpc mode on ECS**, where each task gets an ENI and a real VPC IP.

Consequences — all good for you:
- Security groups, NACLs, route tables, VPC flow logs apply to **pod** traffic
- VPC peering, PrivateLink, Transit Gateway, Direct Connect all just work
- Your existing VPC mental model transfers essentially intact

### 3.3 ⚠️ The gotcha: IP exhaustion

Because pod IPs are real VPC IPs, **you can run out of them.** Each instance type supports a fixed number of ENIs and IPs per ENI, which hard-caps pods per node *regardless of free CPU and memory*.

Rough formula: `(ENIs × (IPs per ENI − 1)) + 2`

A `t3.medium` — what this repo's system node group uses — tops out around **17 pods**. Not a memory limit. Not a CPU limit. An *address* limit.

Fixes, in order of preference:
1. **Prefix delegation** — assign /28 prefixes instead of individual IPs; massively increases density on Nitro instances
2. Larger instance types (more ENIs)
3. Secondary CIDR on the VPC

**Planning implication:** size your subnets for *pods*, not nodes. This has no ECS equivalent and it surprises everyone.

### 3.4 Load balancers — real ALBs and NLBs, created differently

On ECS you write the ALB, listener, and target group in Terraform, then point the target group at your service. **You** provision the load balancer.

On EKS you can still do that — but the idiomatic path is to declare intent in Kubernetes and let the **AWS Load Balancer Controller** (installed into the cluster) call the AWS API and provision the real resource. Same ALB, same cost, same console entry.

| You declare | Controller provisions |
|---|---|
| `Service` with `type: LoadBalancer` | **NLB** (layer 4) |
| `Ingress` with `ingressClassName: alb` | **ALB** (layer 7 — path routing, TLS, WAF) |

**Target modes** — this matters and it's a good interview detail:
- **`instance` mode** — traffic goes to a NodePort, then kube-proxy forwards it to a pod. Extra hop.
- **`ip` mode** — the target group registers **pod IPs directly**, possible precisely because of the VPC CNI (3.2). Fewer hops, and essentially identical to how your awsvpc ECS tasks register today. **Prefer this.**

> **Terraform tension worth naming:** with the controller, your load balancers are no longer in Terraform state — a cluster controller creates them in response to a manifest. That bothers IaC-minded engineers, reasonably. You *can* keep provisioning ALBs in Terraform pointed at NodePorts, but you lose pod-level target registration. The controller path is the mainstream production choice; know the trade-off and be able to argue it.

### 3.5 What actually is "embedded"

East-west (pod-to-pod) traffic. **Service ClusterIPs** come from a separate service CIDR that exists *only* inside the cluster — implemented as iptables or IPVS rules on every node, resolved by CoreDNS, not routable in the VPC, invisible to AWS.

On ECS you'd have reached for Cloud Map service discovery or an internal ALB for this. So the embedded layer is real — but it sits *underneath* the AWS load balancers, not instead of them.

### 3.6 Control plane endpoint (and where VPN comes in)

The EKS API server endpoint can be public, private, or both. This repo currently sets `cluster_endpoint_public_access = true` — fine for a playground, flagged for Week 10.

Setting it private means `kubectl` only works from inside the VPC, which is what a **Client VPN**, Site-to-Site VPN, or bastion is for. AWS VPN itself is VPC-level and completely unchanged by Kubernetes. Locking this down is a solid CKS-adjacent hardening exercise.

### 3.7 Beyond the default: Cilium

The VPC CNI isn't the only option. **Cilium** (eBPF-based) can replace it and brings richer NetworkPolicy, better observability (Hubble), and eBPF-based load balancing that bypasses iptables.

Worth knowing because **Anthropic's infrastructure postings name Cilium and eBPF explicitly.** Not a week-1 concern — but it's on the path, and it's the natural depth to build after CKA/CKS.

---

## 4. GPUs: what's actually new

The plumbing is unglamorous. A GPU node has the hardware plus the NVIDIA driver. A DaemonSet (device plugin) tells kubelet "this node has N GPUs." Your pod requests one. The scheduler places it, kubelet allocates the device, and the container runtime mounts `/dev/nvidia*` into the container so CUDA can see it.

**What makes it hard is not the plumbing — it's these four things:**

### GPUs don't share like CPU
CPU is fractional and time-sliced by the kernel: request `0.5` and it works. A GPU is **one indivisible lump by default** — one pod takes the whole card. Sharing requires deliberate mechanisms, each with real tradeoffs:
- **MIG** — hardware partitioning (A100/H100 only), strong isolation, fixed profiles
- **Time-slicing** — context-switching between processes, no memory isolation
- **MPS** — concurrent kernels, moderate isolation

### GPU memory isn't enforced by cgroups
Node memory limits protect you; **GPU memory does not work that way**. Two processes on one GPU can OOM each other, and the failure is often opaque. This surprises everyone arriving from CPU workloads. It's why `--gpu-memory-utilization` exists in vLLM's args.

### Cold starts are brutal
Model weights are gigabytes. A pod that would be ready in 2 seconds on ECS may take 5–10 minutes because it's downloading and loading a model into VRAM. Caching (PVC, EFS, baked images, prefetch DaemonSets) becomes an **architecture decision**, not an optimization. Note the `initialDelaySeconds: 60` + `failureThreshold: 40` in this repo's vLLM readiness probe — that's this reality in YAML form.

### Cost changes your posture
A GPU node is 10–50× a CPU node per hour. On ECS, imperfect placement costs a rounding error. Here an idle GPU is real money — which is exactly *why* scheduling sophistication exists, and why DRA was built (see [GPU_SCHEDULING.md](GPU_SCHEDULING.md)). Spot interruptions also hurt more, because reloading a model isn't instant.

---

## 5. What transfers (don't undersell this)

Most of the job, honestly:

- **Containers** — identical. Images, registries, layers, runtime behavior.
- **Terraform / IaC** — identical discipline, different resources.
- **VPC, subnets, routing, security groups** — transfers nearly wholesale.
- **IAM → IRSA** — a direct conceptual analog.
- **Observability (Datadog)** — transfers; Datadog's K8s support is first-class.
- **Incident response, on-call, runbooks, DR** — fully transferable, and *rarer than Kubernetes knowledge*.
- **CI/CD** — transfers; becomes GitOps (Argo/Flux) in this world.
- **Security posture, least privilege, NIST alignment** — becomes RBAC, Pod Security Standards, NetworkPolicy, admission control. This is the CKS path and it's a genuine differentiator.

> An engineer with a CKA and no production ownership has a **harder** gap to close than you do. They have to learn what 3 a.m. feels like; you already know.

---

## 6. The gap, ranked

1. **GPU operational reality** — sharing, VRAM, cold starts, cost efficiency. Genuinely new; nothing in ECS prepares you. *→ Weeks 7–9 of the plan.*
2. **Scheduling depth** — ECS never asked you to think hard about placement. Now it's the job: affinity, taints, priority/preemption, topology, QoS classes. *→ Weeks 3–6.*
3. **K8s object model + reconciliation** — a few weeks of real work; smaller than it looks from outside. *→ Weeks 1–2.*
4. **Go** — required at Anthropic-tier, optional for the stepping-stone role. One real tool closes the objection. *→ Week 11.*
5. **Cluster-scale thinking** — multi-tenancy, noisy neighbours, fleet-level upgrades. Comes with the job, not before it.

---

## 7. Learning resources

### Verified video links

- [GPUs, Kubernetes & AI Infrastructure Realities](https://www.youtube.com/watch?v=BrqvJD6O7xw)
- [vLLM Deployment on Kubernetes — Scalable LLM Inference with GPUs](https://www.youtube.com/watch?v=FjBEgpTCC28)
- KubeCon EU 2026 — [*"GPUs on Kubernetes: What Actually Happens When You Request nvidia.com/gpu: 1"*](https://kccnceu2026.sched.com/event/2CW1Q/gpus-on-kubernetes-what-actually-happens-when-you-request-nvidiacomgpu-1-gulcan-topcu-daniele-polencic-learnkube) — session page; find the recording on the CNCF channel

### Channels

*(Handles below are the standard ones; if a link 404s, search the channel name on YouTube.)*

**Kubernetes fundamentals — Weeks 1–6**
- [TechWorld with Nana](https://www.youtube.com/@TechWorldwithNana) — clearest explainers; the free full course is the most-watched K8s content anywhere
- [KodeKloud](https://www.youtube.com/@KodeKloud) — hands-on labs aligned to CKA/CKS exam format
- [DevOps Toolkit — Viktor Farcic](https://www.youtube.com/@DevOpsToolkit) — **best fit for your level**: opinionated and architectural rather than tutorial-grade; strong on Karpenter, Argo, Crossplane

**GPU + AI infrastructure — Weeks 7–12**
- [CNCF](https://www.youtube.com/@cncf) — where KubeCon talks land; the real advanced material. Search their uploads for GPU scheduling, DRA, multi-tenancy
- [NVIDIA Developer](https://www.youtube.com/@NVIDIADeveloper) — device plugin, MIG, time-slicing, GPU Operator internals
- [Anyscale](https://www.youtube.com/@anyscale) — distributed compute and inference serving
- [Jeff Geerling](https://www.youtube.com/@JeffGeerling) — homelab-flavoured but excellent on real hardware and cluster failure modes

### Written references

- [Kubernetes — Schedule GPUs](https://www.kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)
- [Kubernetes v1.34 — DRA updates](https://v1-34.docs.kubernetes.io/blog/2025/09/01/kubernetes-v1-34-dra-updates) (DRA went GA; API moved `v1beta1` → `v1`)
- [AWS — Manage hardware devices on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/device-management.html) (incl. the **DRA/Karpenter incompatibility**)
- [How Kubernetes Schedules GPUs: Device Plugins, MIG, and Time-Slicing](https://www.kubenatives.com/p/how-kubernetes-schedules-gpus)
- [NVIDIA at KubeCon 2026 — DRA driver donated to CNCF](https://blogs.nvidia.com/blog/nvidia-at-kubecon-2026/)

---

## 8. How to use this doc

Re-read section 6 whenever you're deciding what to study next — it's easy to over-invest in the parts that already transfer (they feel productive because they're familiar) and under-invest in GPU operational reality, which is the thing you're actually being hired for.
