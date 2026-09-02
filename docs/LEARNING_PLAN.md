# 3-Month EKS + AI Workloads Learning Plan

**Goal:** Production-credible EKS + GPU inference skills, a public artifact repo, and CKA passed — positioned to win a Kubernetes-heavy contract (stepping-stone role) by month 6.

**Time budget:** 10–15 hrs/week. You already have Terraform, AWS, ECS, CI/CD, and security depth — this plan spends zero time on those and everything on the gap: Kubernetes internals, GPU workloads, and Go exposure.

**Certs (in order):**
1. **CKA** — target end of Week 6. The universally-requested credential. ($445, kubernetes.io/training)
2. **CKS** — target Month 4–5 (needs active CKA first). Your security background makes this your differentiator — CKS holders are scarce and it maps directly to what AI companies list (pod security standards, RBAC, node hardening).
3. **NCP-AII (NVIDIA AI Infrastructure)** — later, optional. Wants 2–3 yrs hands-on with NVIDIA data-center hardware; revisit after the stepping-stone job gives you real GPU fleet exposure.
4. Skip CKAD (overlaps CKA, you're not the target audience) and KCNA (too entry-level for you).

---

> **Start here:** [ECS_TO_EKS.md](ECS_TO_EKS.md) — concept mapping from what you already run on ECS, what transfers, and the gap ranked by priority. It also holds the video/reference list for every phase below.

## Phase 1 — Kubernetes fundamentals, locally (Weeks 1–2)

- Spin up the local cluster in this repo: `make local-up` (kind). Break it, rebuild it.
- Core objects until they're muscle memory: Deployments, Services, ConfigMaps/Secrets, StatefulSets, DaemonSets, Jobs, Ingress, PV/PVC.
- `kubectl` fluency drills — imperative commands, `-o yaml --dry-run=client`, `explain`, `debug`.
- Deploy the CPU inference workload locally (`make local-inference` → Ollama serving a small model in kind). This is your first "AI workload on K8s" even without a GPU.
- Start a CKA course (KodeKloud or killer.sh practice environments are the standard).
- **Milestone:** you can deploy, expose, scale, and debug an app on kind without looking anything up.

## Phase 2 — EKS for real, via Terraform (Weeks 3–4)

- Provision the cluster in `terraform/`: `make eks-up`. Read every resource the modules create — the VPC/subnet layout, IAM roles, and the EKS access entries are interview material.
- Understand what's different from ECS: the VPC CNI (pods get real VPC IPs), IRSA / EKS Pod Identity vs task roles, kubeconfig/auth flow.
- Install the AWS Load Balancer Controller and expose the CPU inference service through an ALB.
- Wire up observability: kube-prometheus-stack via Helm, look at every default dashboard.
- **Cost control:** control plane is ~$73/mo — `make eks-down` when not actively using it. Everything is IaC; destroying and re-provisioning IS the practice.
- **Milestone:** cluster up/down from scratch in under 30 min; CPU model served through an ALB with dashboards.

### Phase 2b — Release management: Helm + GitOps (added Week 2, directly relevant to current ECS release work)

- **Helm as a package manager, not just an install tool:** by this point you'll have already run `helm install` once (AWS LB Controller). Go one level deeper — write a minimal chart for the Ollama/vLLM manifests (`helm create`, templatize the image tag + replica count as values), then practice `helm upgrade`, `helm rollback`, and `helm history`. This is your direct ECS analog: a chart release ≈ a task definition revision + service update, but with a real rollback command instead of re-registering an old revision.
- **GitOps via Argo CD (recommended over Flux to start — larger community, better UI for learning to read sync state):** install it in-cluster, point it at this repo's `k8s/` or a Helm chart, and watch it reconcile automatically on a manifest change — no `kubectl apply`/`helm upgrade` run by hand. This is the actual mental model shift from CodePipeline: **the cluster pulls, CI doesn't push.** A pipeline's job becomes "build image, update the tag in a manifest/values file, commit" — Argo CD does the rest.
- **Drift and sync-status practice:** manually `kubectl edit` something Argo CD manages, and watch it detect and revert the drift (or flag `OutOfSync` if auto-sync is off) — this is the property that makes GitOps valuable for release safety: the cluster's actual state can never silently diverge from what's in Git for long.
- **Milestone:** a Helm chart release rolled back live via `helm rollback` (or Argo CD's UI equivalent), and one full GitOps loop demonstrated — commit a change, watch Argo CD pick it up and reconcile without any manual `kubectl`/`helm` command run by hand.
- **Secrets management, done properly (added Week 2)**: real Secrets currently live outside any chart/manifest (`make ollama-secret`, imperative) — correct for now, but not "complete." Add **External Secrets Operator (ESO)** — another Helm-installed controller (same IRSA-role-then-Helm pattern as EBS CSI/ALB Controller by this point), watching a CRD (`ExternalSecret`) that syncs a real value from **AWS Secrets Manager** (created via Terraform, never plaintext in git) into an actual K8s `Secret` your Deployment references unchanged. This is the genuinely production-grade answer to "where do secret values actually live," vs. the imperative stopgap used so far.

### Phase 2c — Multi-AZ scheduling & storage (added Week 2, surfaced organically debugging the EBS CSI setup)

- **Why it matters here specifically:** the `system` node group spans 3 AZs, but EBS volumes are zonal — a PV's AZ gets fixed at creation, and only nodes in that same AZ can ever mount it again. Already hit this once as a `FailedScheduling` event ("didn't match PersistentVolume's node affinity"). No ECS/Fargate equivalent — AWS handles AZ placement invisibly there.
- **`topologySpreadConstraints`** — the actual K8s mechanism for deliberately spreading replicas across AZs/nodes/any topology key, rather than leaving it to the scheduler's default (loose) balancing heuristic. Compare/contrast with pod anti-affinity (older, clunkier way to express similar intent).
- **StatefulSets + zonal storage compound this problem** — each replica's PVC is pinned to whatever AZ it was first created in; losing that AZ effectively strands the replica's data unless using a cross-AZ-replicated storage class (EFS) instead of EBS. Worth understanding conceptually even without hands-on (ties back to the earlier Deployment-vs-StatefulSet PVC discussion).
- **`volumeBindingMode` revisited** — `WaitForFirstConsumer` (what you're using) delays volume creation until a pod's scheduled, so the volume lands in the *right* AZ automatically. `Immediate` mode can create a volume before any pod exists, in an AZ that might not have available capacity — a common real-world footgun.
- **Milestone:** deliberately reproduce the AZ-mismatch failure on purpose (rather than stumbling into it), then fix it with a `topologySpreadConstraint`, and write a short note on when EBS zonal storage is the wrong choice vs. EFS.

### Phase 2d — Karpenter fundamentals (added Week 2, moved up from Week 8 — foundational, not GPU-specific)

- **What it replaces:** static `eks_managed_node_groups` (what `main.tf` uses today) pre-declare fixed instance types/sizes ahead of time. Karpenter instead watches for unschedulable pods and provisions **exactly-fitting** nodes on demand, then consolidates/deprovisions idle ones — closer to how you'd want capacity to behave, not a fixed shape you guessed at upfront.
- **Core CRDs**: `NodePool` (what instance types/capacity types/limits are allowed) and `EC2NodeClass` (AMI, subnets, security groups, IAM instance profile — the actual AWS-side node config). Install via Helm (same IRSA-role-then-Helm-install pattern as the AWS Load Balancer Controller — you'll recognize the shape immediately).
- **Try it on the `system` pool first** — lower stakes than GPU capacity, good place to actually watch consolidation happen (scale a deployment up, watch Karpenter provision a node; scale down, watch it deprovision after the idle timeout).
- **Milestone:** `system` node group capacity managed by Karpenter instead of the static managed node group, with a demonstrated scale-up/consolidation cycle. This groundwork makes **Week 8's** GPU/spot-interruption exercise an *application* of already-understood Karpenter mechanics, not a first exposure — Week 8 stays focused on the GPU-specific parts (spot interruption handling, `nvidia.com/gpu` NodePool requirements) rather than re-teaching Karpenter from scratch.

### Phase 2e — Multi-cluster & cross-account service communication (added Week 2, directly relevant to current day-job private networking work)

- **Cluster topology:** standard pattern is cluster-per-environment (dev/staging/prod), sometimes cluster-per-business-unit for blast-radius isolation — not one shared mega-cluster. Namespaces give some isolation within a cluster but not IAM/network/version-upgrade isolation, so the cluster boundary tends to follow the same lines your existing ECS cluster boundaries already do.
- **Cross-cluster / cross-account connectivity — two real options, know both:**
  - **VPC Lattice** — AWS's newer (2023+) purpose-built service-networking layer for cross-VPC/cross-account/cross-cluster service calls, with IAM-based auth built in. Increasingly the recommended default over hand-rolled TGW route tables for service-to-service traffic specifically.
  - **Transit Gateway** — still the right tool for general network reachability (not service-specific), and for cases VPC Lattice doesn't cover.
  - Either way, **account boundaries are an IAM boundary as much as a network one** — a cross-account service call typically needs both the network path *and* an assumed role (IRSA/Pod Identity on the K8s side), same pattern as cross-account ECS task roles.
- **Service mesh — split the two problems it gets conflated under:** basic Service DNS + kube-proxy (already covered, Week 1–2) is free and sufficient for same-cluster traffic. A real mesh (Istio, Linkerd, or Cilium's eBPF mesh mode) adds mTLS, retries/circuit-breaking, fine-grained traffic splitting, deep L7 observability — via sidecars or eBPF. Note: **AWS App Mesh is being deprecated** — don't build toward it; VPC Lattice or an OSS mesh are the current answers.
- **GitOps + CodePipeline integration** (ties to Phase 2b): CodePipeline doesn't push directly to EKS the way it does to ECS. Standard pattern is CodeBuild updates an image tag in a Git-tracked manifest/values file and commits — Argo CD (already in the plan) picks up the change and reconciles in-cluster. Worth building this as one real pipeline, not just discussing it.
- **Milestone:** a documented (written, not necessarily fully built) architecture decision — given a hypothetical 2-cluster, 2-account scenario resembling real work, choose and justify VPC Lattice vs. TGW vs. a mesh, and explain the IAM side of the cross-account call. This is interview material as much as hands-on skill.

### Phase 2f — Datadog on EKS (added Week 2, standalone given day-job relevance — DD used for everything incl. log forwarding + APM)

- **DaemonSet vs. sidecar, the real production split:** the Datadog Cluster Agent + node Agent deploy as a **DaemonSet** (one per node, not one per pod) via the official `datadog-agent` Helm chart — collects infra metrics/logs from every pod on that node via the container runtime/kubelet, avoiding per-pod agent duplication. This is the default; reserve actual per-pod sidecars for things that need per-pod context specifically.
- **APM/tracing is the exception** — Datadog's Admission Controller can auto-inject a trace-agent **sidecar** per-pod (or use library injection) specifically for distributed tracing, layered on top of the DaemonSet metrics agent, not instead of it. Understand why tracing needs per-pod context that node-level metrics collection doesn't.
- **Log forwarding**: DaemonSet agent tails container logs directly from the node (via the container runtime's log driver) — no `stdout`-shipping sidecar needed per pod, unlike some older logging patterns (e.g. a Fluentd sidecar). Compare directly against however log forwarding is currently wired on ECS.
- **IAM for the agent** — if pulling AWS-side metrics (e.g. EC2/EBS/ELB metrics via the DD-AWS integration) rather than just K8s/container metrics, the agent needs its own IRSA role — same pattern as EBS CSI and the Load Balancer Controller by this point, should be quick to wire up given the repetition.
- **Milestone:** DD Cluster Agent + node Agent running via Helm, Ollama's logs and infra metrics visible in Datadog, and one APM trace captured end-to-end through a real request — written comparison of DaemonSet-agent vs. ECS-sidecar-agent tradeoffs (resource overhead, blast radius, upgrade story).

## Phase 3 — CKA exam + hardening (Weeks 5–6)

- killer.sh mock exams (2 attempts included with registration; treat them as the real thing).
- Weak-area drills: etcd backup/restore, cluster upgrades, NetworkPolicies, troubleshooting broken nodes — the CKA is speed-based.
- **Sit the CKA at the end of Week 6.**
- **Milestone:** CKA passed → immediately add to resume + LinkedIn + tracker applications.

## Phase 4 — GPU inference platform (Weeks 7–9) ← the artifact

Read [GPU_SCHEDULING.md](GPU_SCHEDULING.md) first — you're going to build **both** GPU scheduling models and compare them. That comparison is what makes this artifact stand out.

**Week 7 — classic path (device plugin)**
- Scale up the GPU node group (`make gpu-up`): g5.xlarge spot (~$0.30–0.45/hr — always `make gpu-down` after sessions).
- NVIDIA device plugin DaemonSet, GPU taints/tolerations, `nvidia.com/gpu` resource scheduling.
- Deploy vLLM serving Qwen2.5-1.5B-Instruct (`k8s/vllm/`) — OpenAI-compatible API on your own cluster.
- Benchmark it: tokens/sec, time-to-first-token, concurrency behavior. Record numbers in the README.

**Week 8 — autoscaling (device plugin only)**
- HPA on custom metrics, then extend the Karpenter setup from Phase 2d to manage GPU capacity specifically — a `NodePool`/`EC2NodeClass` for `g5.xlarge` spot, `nvidia.com/gpu` requirements, and spot interruption handling. You already know Karpenter's mechanics from Phase 2d; this week is the GPU-specific application, not a first exposure.

**Week 8b — DRA path (modern)**
- Tear down Karpenter first: **DRA is not compatible with Karpenter or EKS Auto Mode** — managed node groups only. Hitting this constraint deliberately is itself an interview story.
- `make dra-driver` → `make dra-inspect`: read the ResourceSlices. Memory in bytes, MIG profiles, NVLink topology — everything the integer model discarded.
- `make dra-vllm`: same workload, scheduled via ResourceClaimTemplate instead of `nvidia.com/gpu: 1`.
- Diff `k8s/vllm/deployment.yaml` against `k8s/dra/vllm-dra.yaml` and write up what changed and why.
- Note: DRA went GA in Kubernetes 1.34 (API moved `v1beta1` → `v1`), so older tutorials won't apply cleanly — expect to debug this. That's the exercise.

**Week 9 — stretch + write-up**
- A second model + routing layer, or KEDA scale-to-zero for the GPU pool.
- **Milestone:** public repo serving an LLM on EKS, with benchmarks, a cost breakdown, *and* a device-plugin-vs-DRA comparison — that last piece is what makes you sound current rather than merely competent.

## Phase 5 — Security + Go + polish (Weeks 10–12)

- Harden the cluster like a CKS candidate: Pod Security Standards, NetworkPolicies, image scanning (Trivy) in CI, RBAC audit, secrets encryption, node hardening. Document each control in `docs/SECURITY.md` — NIST-mapped, which is your existing language.
- Go: write one small tool in Go — e.g. a CLI that watches GPU utilization across the cluster, or a Kubernetes operator tutorial (kubebuilder). One real Go artifact in the repo is enough to claim "working Go".
- Write the README like a case study: architecture diagram, decisions, benchmarks, costs. Optionally a blog post / LinkedIn write-up — recruiters do read these.
- Begin CKS prep (exam in Month 4–5).
- **Milestone:** repo public + pinned on GitHub, resume updated ("built and benchmarked a GPU inference platform on EKS: vLLM, Karpenter, CKS-grade hardening").

---

## Month 4–6 — the stepping-stone hunt

- CKS exam.
- Retarget the nightly job tracker toward EKS/K8s contract roles (the searches can be re-weighted).
- Apply with the artifact repo in every application; for K8s-contract interviews your story is: "founding engineer, 75k users, org migration — and here is my K8s platform work, public."
- Target: GPU clouds (CoreWeave, Lambda), AI startups, observability/platform companies hiring EU remote (Grafana-type), and K8s contract roles from the tracker.

## Weekly rhythm

- 2 weekday evenings: course/drills (~2 hrs each)
- 1 weekend block: hands-on in this repo (~4–6 hrs)
- Friday 30 min: log what you learned in `docs/JOURNAL.md` — this becomes interview prep for free
