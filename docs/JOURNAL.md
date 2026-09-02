# Learning Journal

Log ~5 lines every Friday: what you built, what broke, what you learned, what's next.
This becomes your interview prep — concrete stories beat generic claims.

## Week 1 — 2026-08-30

**Built:**
- Set up a `personal` AWS SSO profile (separate `sso-session` from work's `magpie`) in `~/.aws/config`, pinned to `eu-central-1` — kept separate since it's a different IAM Identity Center org.
- Installed `kind` + confirmed Docker running.
- `make local-up` — 3-node kind cluster (1 control-plane, 2 workers), each node = one Docker container (`docker ps` confirmed: `ai-playground-control-plane`, `-worker`, `-worker2`).
- `make local-inference` — deployed Ollama (`local/manifests/ollama.yaml`) into the `inference` namespace, pulled `qwen2.5:0.5b`.
- `make local-chat` — port-forwarded and got a real completion back from the model running in-cluster. First AI workload served through Kubernetes.

**Concepts clarified (my questions + the answers):**
- *Deployment vs. Task Definition:* a Deployment isn't a sequencer — `spec.template` inside it **is** the pod spec (≈ Task Definition). The Deployment just wraps that template with replica count + rollout strategy. ECS bundles "keep N running" + "load balancer wiring" into one Service resource; K8s splits that into two independent objects — Deployment (replicas/rollout) and Service (networking) — that don't reference each other by name.
- *How Service finds its Pods:* label matching, not a name/ID reference. `service.spec.selector` (`app: ollama`) is continuously matched against live pod `labels`. Same mechanism a ReplicaSet uses to find "its" pods. This is why a Service can sit in front of pods from two different Deployments at once (canary/blue-green) — worth trying as a drill later.
- `kubectl get endpoints -n inference ollama` shows the live pod IP(s) a Service is actually routing to, populated/depopulated automatically as pods come and go. (`v1 Endpoints` is deprecated in favor of `EndpointSlice`, discovery.k8s.io/v1 — same idea, newer API.)
- *Control-plane vs. worker nodes:* control-plane = API server + etcd + scheduler + controller-manager (cluster brain, no workloads); workers = kubelet + container runtime, where pods actually execute. Confirmed via the `node-role.kubernetes.io/control-plane:NoSchedule` taint — pods don't land there unless they explicitly tolerate it.
- *This has no Fargate equivalent* — Fargate abstracts the node away entirely; there's no `docker ps`, no node object, nothing to inspect. Plain K8s always keeps nodes visible/inspectable by default (EKS has a Fargate-like "Auto Mode" but that's out of scope for this plan — managed node groups are the deliberate choice).
- *Pod naming chain:* `ollama` (Deployment) → `ollama-<template-hash>` (ReplicaSet, hash of the pod template) → `ollama-<template-hash>-<random>` (Pod). The template-hash label is what lets two ReplicaSets (old + new pod template) coexist during a rolling update without their selectors overlapping — the Service ignores this and matches on `app` alone, so it serves both old and new pods mid-rollout.
- *`kubectl port-forward svc/ollama 11434:11434`:* despite targeting the Service, this does **not** proxy through the Service or load-balance across replicas. It resolves the Service to one specific backing pod *once*, at connection time, then tunnels straight to that pod — authenticated tunnel through the API server into the pod's network namespace, not real network routing. That's also why the pod's actual IP (`10.244.x.x`, the CNI overlay network) isn't reachable directly from my laptop — no route to it exists outside the cluster.

**Self-heal test (done):**
- `kubectl delete pod -n inference -l app=ollama` — ReplicaSet noticed the gap and created a replacement within ~1s, new name/new IP. Deployment/ReplicaSet healed correctly.
- BUT: `local-chat` port-forward died the moment its target pod was deleted (`curl` → `Empty reply from server`) — confirms port-forward tunnels to one specific pod at connection time and does *not* follow the Service's live routing. Had to re-run `make local-chat` to reconnect to the new pod.
- New pod's `ollama list` came back empty — the pulled model lived only in the old pod's `emptyDir`, which is ephemeral and died with the pod. Self-healing fixed the *pod*, not the *data*. This is the concrete case for the `# Week 2 exercise: replace with a PVC` comment in `ollama.yaml` — confirmed hands-on, not just read about.

**Root cause, precisely:** the model pull (`ollama pull`, in the Makefile's `local-inference` target) is a manual `kubectl exec` run *after* the pod is already up — it's not declared anywhere in the pod spec. So any fresh pod (self-heal, scale-up, rollout) just runs the bare `ollama/ollama:latest` image with no models; nothing in the Deployment "knows" to reproduce that step. Two separate problems stacked: (1) no persistence — emptyDir dies with the pod, and (2) no re-pull mechanism — even with a PVC, a *new* replica (not a replacement) would still start empty since nothing in the pod spec guarantees the model is present before serving. Production fix for (2): an **init container** that runs `ollama pull` to completion before the main container starts, paired with a PVC so the pull only actually happens once.

**Next:**
- Fix the emptyDir gap with a PVC so the model survives pod restarts (Week 2 exercise).
- Stretch: add an init container to guarantee the model is present on any new pod, not just persisted across restarts.
- Scale to 3 replicas — since `port-forward svc/...` only ever hits one pod, watch cluster-internal traffic instead (curl the Service from another pod) to actually see load-balancing across replicas.
- Try a manual canary: second Deployment, same `app: ollama` label, different `version` label, same Service in front of both.

## Week 2 — 2026-08-31

**Built:**
- Fixed the `emptyDir` gap in `ollama.yaml`: added a `PersistentVolumeClaim` (5Gi, `ReadWriteOnce`), swapped the Deployment's `volumes.emptyDir: {}` for `volumes.persistentVolumeClaim.claimName: ollama`. Verified end-to-end — deleted the pod, new pod came up, `ollama list` still showed `qwen2.5:0.5b` (previously came back empty). PVC dynamically provisioned a real PV via kind's `standard`/local-path StorageClass.
- Added a `ConfigMap` (`ollama-config`, key `keep-alive: "24h"`) and wired it into the Deployment as an env var (`OLLAMA_KEEP_ALIVE`) via `valueFrom.configMapKeyRef`. Verified with `kubectl exec ... printenv`.

**Concepts clarified:**
- *PVC vs PV:* same decoupling pattern as Service/Pod — PVC is a *request* for storage, PV is the actual backing volume (dynamically provisioned here by a StorageClass; will be EBS via the EBS CSI driver on real EKS).
- *Deployment + PVC vs StatefulSet:* the real dividing line isn't "can Deployments use PVCs" (they can) — it's whether replicas need their *own* distinct volume. Shared/single volume → Deployment + PVC is fine. Each replica needs its own dedicated, identity-tied volume → StatefulSet + `volumeClaimTemplates`.
- *Access modes:* `ReadWriteOnce` = one node (practically ~one pod) can mount read-write at a time — most cloud block storage (EBS, kind's local-path). `ReadWriteMany` allows true concurrent multi-pod writes but needs NFS/EFS-backed storage — not something EBS supports.
- *Root cause of the self-heal data loss last session, precisely:* the `ollama pull` step is an imperative `kubectl exec` run manually after the pod is up — never declared in the pod spec — so no fresh pod (however created) ever "knows" to re-pull. PVC fixes persistence across *restarts of the same claim*; a first-time new replica would still need an explicit pull (or an init container) regardless of PVC.
- *ConfigMap vs Secret:* same shape (`data:` k/v map), Secret values are base64-**encoded**, not encrypted, by default — trivially reversible by anyone with API read access. Real encryption-at-rest needs etcd encryption enabled explicitly (CKS-level cluster hardening, not default behavior) — flag for `docs/SECURITY.md` later.
- *`valueFrom` is a union type:* not itself the object with `key`/`name` — `configMapKeyRef` (or `secretKeyRef`, etc.) nests one level inside it. Two different `name` fields at play: outer `env[].name` is the env var name inside the container; `configMapKeyRef.name` is the ConfigMap object's own `metadata.name`.
- *Debugging lesson:* edited the manifest, re-ran `printenv`, got nothing — root cause was simply forgetting to `kubectl apply` after the edit. Manifests are inert files until applied; the API server only knows what's actually been sent to it. This will be the most common "why isn't this working" cause going forward — check it first.

**Secrets (done):**
- Created imperatively: `kubectl create secret generic ollama-secret -n inference --from-literal=dummy-api-key=sk-test-12345`. Inspected `-o yaml`, manually `base64 -d`'d the stored value myself — came back as plaintext with no key/password needed.
- Wired it in via `secretKeyRef` (identical shape to `configMapKeyRef`). `kubectl exec ... printenv TEST_SECRET` returned the plaintext `sk-test-12345`, not the base64 blob.
- *Why plaintext at the container, base64 at rest:* base64 is a storage/transport encoding for the API layer only (etcd/YAML/JSON are text formats, can't hold raw bytes directly) — not a security boundary. The kubelet decodes it server-side before injecting into the container; the app never sees the encoded form. The actual protection on a Secret is **RBAC** (who can `get`/`list` Secrets) plus, for defense-in-depth, **etcd encryption-at-rest** — both explicit config, not defaults. Putting something in a Secret ≠ it being protected. Flag for `docs/SECURITY.md`.

**DaemonSet (read, not applied):** studied `k8s/gpu/nvidia-device-plugin.yaml` — no `replicas:` field (node count IS the count), `tolerations` reuses the same taint mechanism as the control-plane taint from Week 1, `nodeSelector` scopes it to specific nodes rather than literally every node, `hostPath` volume breaks container isolation deliberately (CSK flag). ECS analog: the `DAEMON` scheduling strategy. Key gotcha: a DaemonSet with zero matching nodes creates **zero Pod objects**, not a `Pending` one — different failure signature than a ReplicaSet's stuck-pending pod, worth remembering when debugging "why isn't my DaemonSet running."

**Job (done):** `local/manifests/pull-model-job.yaml` — pulled a second model (`tinyllama`) via a Job instead of manual `kubectl exec`. Confirmed to completion (`COMPLETIONS: 1/1`, pod status `Completed`). Two things learned:
- `restartPolicy` must be `Never`/`OnFailure` for Jobs (not `Always`, the Deployment default) — makes sense, "restart forever" contradicts "run to completion."
- The Job's container talked to the existing Ollama pod via `OLLAMA_HOST: ollama:11434` — the **Service's DNS name**, not an IP. First real exercise of in-cluster Service DNS + kube-proxy routing (vs. `port-forward`, which bypasses Service routing entirely and pins to one pod). If Ollama had multiple replicas, kube-proxy would've load-balanced across them for real.

**Ingress (done):** installed `ingress-nginx` (kind provider manifest — nothing ships by default, confirmed from Week 1 prediction). Wrote `local/manifests/ollama-ingress.yaml` — `ingressClassName: nginx`, host `ollama.local`, `pathType: Prefix`. `ADDRESS` stayed blank on `kubectl get ingress` — expected on kind (no cloud provider to assign a LoadBalancer IP; this is exactly where the ALB's DNS name will show up on real EKS in Phase 2).
- Tested via `port-forward` into the controller's Service (not the Ollama Service directly — Ingress traffic flows through the controller, which then proxies internally).
- Confirmed the **`Host` header is the actual routing key**, not path or port alone: one controller Service on port 80 can back many different Ingress objects/hostnames simultaneously (standard HTTP virtual hosting, same idea as nginx/Apache vhosts). `curl` with `-H "Host: ollama.local"` → real completion; without it (defaults to `Host: localhost`, matches no rule) → clean `404` from nginx's default backend. Both outcomes matched prediction before running.
- Read the controller's access log line: `[inference-ollama-11434] ... 10.244.2.6:11434` — upstream name is `<namespace>-<service>-<port>`, and the real pod IP it proxied to is visible directly, closing the full **Ingress → Service → Pod** chain, same pod-network space from Week 1.
- Full request-path picture for this repo now covered end-to-end: Ingress (L7 routing) → Service (label-selected virtual IP + kube-proxy) → Pod. This is architecturally identical to the EKS + AWS Load Balancer Controller setup coming in Phase 2 — same object (`Ingress`), different controller provisioning a real ALB instead of nginx.

**Next:**
- Init container to guarantee model presence on any new replica (deferred from Week 1).
- StatefulSets — conceptual only for now (no natural single-replica fit here); revisit if a genuinely multi-replica, per-pod-identity workload comes up.
- `kubectl` fluency drills: `-o yaml --dry-run=client`, `explain`, `debug`.
- Canary drill and 3-replica scaling test (deferred from Week 1).
- Start a CKA course (KodeKloud/killer.sh) in parallel per the plan — hasn't started yet.
- Phase 1 core-objects list is now effectively done (Deployment, Service, Namespace, PVC/PV, ConfigMap, Secret, DaemonSet [read], Job, Ingress) — good point to shift some time toward `kubectl` drills before moving into Phase 2 (EKS via Terraform).

## Phase 2 — EKS via Terraform (2026-08-31 → 2026-09-01)

**AWS profile setup:** created a `personal` SSO profile in `~/.aws/config`, separate `sso-session` from work's `magpie`. Hit a real, multi-hour `InvalidClientTokenId` debugging saga — AWS CLI worked fine with the profile the whole time, only Terraform's provider failed. Tried, in order: clearing shell env vars (not it), pinning `profile = "personal"` directly in the provider block (not it alone), switching from the newer `[sso-session]`-referenced config format to the older flat format (this is what it ended up being, or at minimum correlates with when it started working — never got a clean debug-log confirmation, so treat as "most likely cause," not certain). **Lesson for next time:** get `TF_LOG=DEBUG` output early rather than iterating on hypotheses one at a time — would have saved real time.

**Terraform module choice:** discussed vanilla `aws_eks_cluster` vs. the `terraform-aws-modules/eks/aws` community module. Kept the module — given the stated gap is K8s-specific not IaC-specific (5 yrs Terraform already), and the module is what's actually used in production, not a black box (every resource inspectable via `terraform state list`/`terraform show`).

**Read the full plan before applying:** `Plan: 71 to add` — categorized into VPC/networking (17, all familiar from ECS work), EKS cluster core (~20: cluster, IAM roles, the OIDC provider for IRSA, security groups/rules for control-plane↔node comms, KMS key for etcd secrets encryption, EKS Access Entries — the modern replacement for the old `aws-auth` ConfigMap hack, ties IAM identity directly to K8s auth), and node groups ×2 (~24, matches the `system`/`gpu` split in `main.tf`).

**Applied successfully.** `make eks-up` now does `terraform plan -out=tfplan && terraform apply tfplan` (Makefile changed) so the reviewed plan is what actually gets applied, no drift between review and apply.

**Real VPC networking confirmed:** `kubectl get pods -A -o wide` on EKS showed real `10.42.x.x` VPC IPs (matching `vpc_cidr`) vs. kind's `10.244.x.x` overlay network. `kube-system` pods are 1:1 with the 4 `cluster_addons` declared in `main.tf` (`aws-node`=vpc-cni, `kube-proxy`, `coredns`, `eks-pod-identity-agent`) — nothing else on the cluster yet at that point. Confirmed `vpc-cni`/`kube-proxy`/`coredns` are near-universal on any EKS cluster; `eks-pod-identity-agent` is one of two competing approaches (the other being IRSA, older/more common in existing tutorials) — both give pods AWS IAM permissions, ECS task-role equivalent.

**Redeployed `ollama.yaml` onto EKS — hit three real, sequential bugs, each debugged via the same get→describe/events→dependent-objects→logs cascade:**
1. **PVC stuck `Pending`, `STORAGECLASS: <unset>`** — EKS ships no default StorageClass/CSI driver at all (unlike kind's built-in `standard`/local-path). Fixed by adding the `aws-ebs-csi-driver` managed addon + an IRSA role (`module.ebs_csi_irsa_role`, using the `iam-role-for-service-accounts-eks` submodule) scoped narrowly to the `ebs-csi-controller-sa` service account in `kube-system` — first real use of the OIDC provider resource read (but unused) in the original plan. Also had to hand-write a `gp3` StorageClass (`k8s/storageclass-gp3.yaml`, `provisioner: ebs.csi.aws.com`, marked default via the `storageclass.kubernetes.io/is-default-class` annotation) — the stale pre-existing `gp2` class used the deprecated in-tree provisioner and wasn't marked default anyway.
2. **`storageClassName` stamped empty on the PVC even after the new default existed** — that field gets set once, at creation time, by an admission controller; a pre-existing PVC doesn't retroactively pick up a newly-created default. Had to delete + recreate the PVC.
3. **`CreateContainerConfigError: secret "ollama-secret" not found`** — `ollama-secret` was created *imperatively* (`kubectl create secret generic ...`) back on the kind cluster, never captured in any YAML. Imperative objects don't travel with manifests across clusters — recreated it directly on EKS. Real argument for declarative-everything (or sealed-secrets/ESO patterns) over one-off imperative `kubectl create`.
- Also hit a stale-pod-events red herring: an early pod attempt's events (`FailedScheduling`/`PVC not found`) kept showing in `describe` output well after the underlying issue was fixed — timestamps revealed they were stale, not current. Fixed by deleting the stuck pod and letting the ReplicaSet create a fresh one — forces a brand-new scheduling attempt against *current* cluster state rather than continuing on a stale one. General lesson: check event *timestamps*, not just presence, before trusting them as the current cause.
- **New EKS-specific constraint surfaced along the way:** EBS volumes are zonal (AZ-locked) — a `FailedScheduling` event cited "node(s) didn't match PersistentVolume's node affinity," since the PV's AZ (fixed at creation) constrains which nodes in the multi-AZ `system` group can ever mount it. Invisible on kind (no AZ concept) and invisible on Fargate (AWS handles it silently) — a real thing to watch for on larger multi-AZ EKS workloads.

**Debugging methodology, consolidated (this is most of CKA's Troubleshooting domain, already exercised hands-on rather than memorized):** `kubectl get` (status, narrows which layer) → `kubectl describe` (Events section — the actual answer, not a hint, but check timestamps) → check dependent objects directly if the pod's own events are silent/stale (PVC, ConfigMap, Secret) → `kubectl logs` (only once a container's actually started).

**Learning plan updated:** added **Phase 2b — Release management: Helm + GitOps** (Helm chart authoring + `upgrade`/`rollback`/`history`, Argo CD for pull-based GitOps, drift-detection exercise) directly into `docs/LEARNING_PLAN.md` — directly relevant to current day-job release work on ECS. Flagged this as added scope on top of an already 10–15hr/week plan targeting CKA by Week 6 — worth watching whether it pushes that timeline, not yet decided how to compensate.

**Next:**
- Verify the Ollama chat completion works end-to-end on EKS (same `curl` test as Week 1, this time against a real cluster).
- AWS Load Balancer Controller + expose Ollama through a real ALB (the Ingress→Service→Pod chain from Week 2, this time with a real cloud load balancer instead of `ingress-nginx`).
- Remember: `make gpu-down` after any GPU work, `make eks-down` between sessions — control plane + 2 nodes are billing right now.
- Helm + Argo CD (Phase 2b, newly added).

**Init container + rolling-deploy deadlock (2026-09-01):** built the deferred init-container exercise for real — `pull-model` init container starts a temporary `ollama serve` in the background, polls until ready, runs `ollama pull`, kills the temp server, exits. Works because init and main containers mount the *same* PVC-backed volume via separate `volumeMounts` entries. Confirmed live: watched `Init:0/1` → `PodInitializing` → `Running` for the first time, and `ollama list` showed the model with zero manual pull.
- **Hit a real deadlock applying it:** default `RollingUpdate` strategy tries to bring up the new pod *before* killing the old one. With a `ReadWriteOnce` PVC, the new pod can't get the volume (still attached to the old pod's node) and can't land on the other node either (EBS is zonal, PV pinned to the wrong AZ) — structural conflict between `RollingUpdate` + exclusive storage on a single-replica Deployment. Fixed with `strategy.type: Recreate` (kill old pod first, accept the downtime gap, avoid the deadlock).
- **Rolling deploys, mapped directly to ECS** (this matters a lot for day-job release work): `maxUnavailable`/`maxSurge` ≈ ECS's `minimumHealthyPercent`/`maximumPercent`; `readinessProbe` gates rollout progression the same way ECS's health checks do; `kubectl rollout undo` ≈ redeploying a previous task definition revision (restores the prior ReplicaSet, kept via `revisionHistoryLimit`, default 10). **Real gap vs. ECS**: plain K8s Deployments have no automatic circuit-breaker/rollback — a stuck rollout just sits past `progressDeadlineSeconds` until a human/pipeline runs `rollout undo`. Argo Rollouts (not plain Argo CD) is the tool that adds automated analysis-based rollback, closer to ECS's circuit breaker — worth covering properly under Phase 2b.
- Discussed sidecars vs. DaemonSets for observability agents (Datadog/CloudWatch) — real architectural difference from ECS's per-task sidecar model: K8s typically runs these as one DaemonSet per *node*, not per pod, with APM trace-agent injection as the main exception still done per-pod. **Deferred as its own dedicated future session** given how central this is to current day-job work — not to be rushed.

**Next:**
- Dedicated Datadog/CloudWatch observability session (DaemonSet architecture, APM injection, IAM for the agent) — standalone, not bundled into another topic.
- Trigger a real rollout + `rollout undo` hands-on (conceptually covered, not yet actually run).

## Phase 2 milestone hit (2026-09-02): internal ALB serving Ollama, end to end

**Learning plan expanded before continuing** — added **Phase 2d (Karpenter, moved up from Week 8 and generalized beyond GPU)**, **Phase 2e (multi-cluster/cross-account service communication — VPC Lattice vs. TGW, cluster-per-environment topology, service mesh options, App Mesh deprecation)**, and **Phase 2f (Datadog on EKS — DaemonSet vs. sidecar architecture, APM injection exception, log forwarding vs. ECS)**. All were previously either chat-only discussion or buried in journal "Next" notes, never in the actual plan file — real gap, now closed.

**Cluster torn down and rebuilt fresh today — genuine test of yesterday's reproducibility fixes:**
- `terraform` state (VPC, node groups, IRSA roles) came back automatically via `make eks-up`, as expected.
- `make bootstrap` (new target, chains `kubeconfig → alb-controller → storageclass → ollama-secret`) mostly worked — caught one more gap live: the `gp3` StorageClass was a tracked file but never wired into any Makefile target, so it silently didn't get reapplied. Added `make storageclass` + folded into `bootstrap`. Also `helm` itself wasn't installed on this machine — quick `brew install helm` fix, same category as Week 1's missing `kind`.
- **Real mistake caught mid-fix:** told to `kubectl delete pvc` to force a fresh StorageClass pickup, but a Deployment doesn't own/manage a standalone PVC's lifecycle (only `StatefulSet` + `volumeClaimTemplates` does) — deleting it without reapplying `ollama.yaml` left the pod referencing a PVC that no longer existed. Fixed by reapplying the manifest. Good concrete reinforcement of yesterday's Deployment-vs-StatefulSet-PVC distinction.

**AWS Load Balancer Controller — installed via Helm, first hands-on `helm install` (not Makefile-triggered) run personally.**
- IRSA role (`module.lb_controller_irsa_role`) deliberately **separate** from the EBS CSI role — least-privilege reasoning: each role's trust policy scopes to one specific `namespace:service_account`, and merging permissions across unrelated controllers would let a compromise of one inherit the other's blast radius.
- Clarified what Helm actually did here vs. what Terraform did: Terraform only created *AWS-side* IAM permissions (an unused credential); Helm installed the actual *application* — Deployment, ServiceAccount, RBAC, webhooks, CRDs, versioned as one chart. No real ECS equivalent to "install a third-party app via a package manager" — closest analog is a Terraform module (versioned bundle + inputs), which is itself a good, credible interview point about K8s ecosystem depth vs. ECS.
- **Controller-watch mechanism, precisely** (came up as a genuine "how does this even work" question): a Helm chart doesn't wire itself to a specific Ingress object. It installs a controller *process* that continuously watches the whole cluster for any `Ingress` with a matching `ingressClassName` — same reconciliation-loop pattern as ReplicaSet/PV-controller/kube-proxy, just applied to a new object kind. The actual link between "alb" the string and "the AWS Load Balancer Controller" the process is an intermediate **`IngressClass`** object (cluster-scoped, same category as `StorageClass`) — `ingressClassName: alb` → resolves to the `IngressClass` named `alb` → that object's `spec.controller: ingress.k8s.aws/alb` → only pods watching for that exact controller string react. `alb` itself is just the chart's *default* `IngressClass` name (`helm show values` confirms it), overridable via `--set ingressClass=...` if running multiple controller installs in one cluster.
- **Reproducibility fix applied proactively this time**: added `make alb-controller` to the Makefile *before* running the raw command, rather than discovering the gap after the fact (Week 2's actual lesson, correctly applied).

**Internal ALB — private by design, per stated preference to default to private networking:**
- `alb.ingress.kubernetes.io/scheme: internal` (uses the already-tagged `kubernetes.io/role/internal-elb` private subnets from `main.tf`) + `target-type: ip` (routes ALB → pod IPs directly via VPC CNI, bypassing kube-proxy entirely — only possible because pods have real, directly-routable VPC IPs; the older `instance` mode routes through node NodePorts instead, an extra hop).
- New file `k8s/ollama-ingress-alb.yaml`, separate from the kind/`nginx` one (Ingress spec is portable; ALB-specific behavior like `scheme`/`target-type` lives entirely in annotations — the standard K8s escape hatch for controller-specific config that doesn't belong in the generic spec).
- `ADDRESS` populated with a real `internal-...elb.amazonaws.com` DNS name after ~30-60s (unlike kind's instant `ingress-nginx` reconfig — this is a genuine external AWS API call).
- **Verified via a throwaway debug pod, not `exec` into the app container**: `ollama/ollama`'s image has no `curl` installed — the fix, `kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- curl ...`, is a real, reusable debugging pattern (minimal purpose-built image, auto-cleanup via `--rm`, `--restart=Never` to avoid `kubectl run`'s default Deployment-creation behavior).
- **Confirmed working end-to-end**: real completion returned, routed through the full chain — laptop → API server → exec tunnel → pod's VPC network → internal ALB → pod IP directly. Debug pod auto-deleted on exit.

**Milestone met:** Phase 2's stated goal ("cluster up/down from scratch; CPU model served through an ALB") — done, and done privately per this session's stated preference rather than the plan's original public-ALB default.

**Next:**
- kube-prometheus-stack (Grafana/Prometheus) — still open from base Phase 2, not yet done.
- Phase 2b (Helm chart authoring + rollback, Argo CD GitOps loop) — not yet started.
- Phase 2c (deliberate AZ-mismatch reproduction + `topologySpreadConstraint` fix) — not yet started.
- Phase 2d/2e/2f (Karpenter, multi-cluster/cross-account networking, Datadog) — newly added, not yet started.
- `make eks-down` when done for the day — remember `make bootstrap` after any future `make eks-up` to restore everything non-Terraform-managed in one shot.
- AWS Load Balancer Controller + real ALB in progress next.
