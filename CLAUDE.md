# CLAUDE.md

Context for Claude Code when working in this repository.

## What this repo is

A **learning platform**, not a product. Adam Sebesta is transitioning from 5 years of production AWS/ECS/Terraform into Kubernetes and GPU/AI infrastructure. This repo is both the practice environment and the public artifact he'll show employers.

Target outcome: a remote Kubernetes production contract role (~$200k) with GPU/AI infrastructure exposure, workable as an EU-based contractor from Italy, within 4–6 months.

## Working style — read this before helping

**Adam is learning. Do not just solve things for him.**

- When he hits an error, help him *diagnose* it — point at the right `kubectl` command, explain what the controller is doing, ask what he's already checked. Don't paste a fixed manifest unless he asks for one.
- Explain the *why* behind Kubernetes behaviour, especially where it differs from ECS. He knows containers, IaC, networking, and IAM cold — don't over-explain those. He does not yet know the K8s object model, scheduling depth, or GPU operational realities.
- When there's more than one way to do something, say which is idiomatic in production and why.
- If he asks for code, write it — but leave the reasoning visible in comments, and flag anything he should verify himself.

Existing manifests intentionally contain `# Week N exercise:` comments marking things left incomplete for him to build. **Don't silently complete them.** If he's working on that week, coach; otherwise leave them.

## Background — what transfers, what doesn't

**Strong already:** AWS (ECS, Control Tower, multi-account, org migrations), Terraform (5 yrs production), CI/CD, Datadog observability + incident response, Okta, NIST-aligned security, CITI-certified for US children's PII, TypeScript/Node.

**Learning:** Kubernetes object model and reconciliation, scheduling depth, GPU operations (sharing, VRAM, cold starts, cost), Go (week 11).

See `docs/ECS_TO_EKS.md` for the full mapping and gap analysis.

## Repo layout

```
docs/
  LEARNING_PLAN.md    # 12-week plan — the spine of the project
  ECS_TO_EKS.md       # concept mapping + resources; start here
  GPU_SCHEDULING.md   # device plugin vs. DRA
  JOURNAL.md          # weekly log; encourage him to fill it
local/                # kind cluster + Ollama CPU inference (free)
app/faceapp/          # the real project: InsightFace GPU service (Phase 4 pivot)
terraform/            # VPC, EKS, system node group (static), IRSA/Pod Identity
                       # roles, ECR, Karpenter controller — split by concern into
                       # main.tf/iam-controllers.tf/karpenter.tf/ecr.tf/
                       # github-actions.tf/pod-identity.tf. No GPU node group —
                       # Karpenter provisions GPU/general capacity dynamically.
helm-values/          # static Helm config for Terraform-managed controllers
                       # (alb-controller, argocd, karpenter) — per-deploy values
                       # (ARNs, VPC ID) stay as Terraform `set` overrides, not here.
charts/                # ollama, faceapp — authored Helm charts, Argo CD-managed
k8s/argocd-apps/        # every Argo CD Application (root's own watch path) —
                        # ollama, ollama-dev, faceapp, monitoring, fluent-bit,
                        # karpenter-resources
k8s/karpenter/          # NodePool/EC2NodeClass (gpu, general) — Argo CD-managed,
                        # NOT Terraform (see karpenter-resources.yaml above)
k8s/root-app.yaml       # the app-of-apps root — watches k8s/argocd-apps/
k8s/gpu/              # NVIDIA device plugin (node-level requirement regardless
                      # of static vs. Karpenter-provisioned GPU nodes)
k8s/vllm/             # vLLM via nvidia.com/gpu integer resource — reference/
                      # comparison material only, faceapp is the active GPU workload
k8s/dra/              # same workload via Dynamic Resource Allocation — needs a
                      # static GPU node group reintroduced when reached (DRA and
                      # Karpenter are mutually exclusive, see Hard constraints)
Makefile              # every workflow is one target
```

## Hard constraints — do not violate

**Cost.** GPU nodes are ~$0.30–0.45/hr spot; the EKS control plane is ~$73/mo. GPU capacity is **Karpenter-managed** (`k8s/karpenter/nodepool-gpu.yaml`), not a static node group — there's no `gpu_desired_size` variable or `make gpu-up`/`gpu-down` toggle anymore (removed once the static group was found to be dead weight after the Karpenter pivot). Cost control now comes from the `NodePool`'s `limits` ceiling plus `consolidationPolicy: WhenEmptyOrUnderutilized` auto-scaling to zero when nothing needs GPU capacity — genuinely automatic, not a manual step to remind him about. Still always remind him to `make eks-down` between practice weeks.

**DRA and Karpenter are mutually exclusive.** DRA does not work with Karpenter or EKS Auto Mode — managed node groups only. Week 8 (Karpenter + device plugin) and Week 8b (DRA) are deliberately separate exercises. Don't try to combine them. **Real consequence of the above**: since the static GPU node group was removed entirely (Karpenter now handles all GPU provisioning), Week 8b's DRA exercise will need a static GPU node group reintroduced — or the Karpenter `gpu` NodePool temporarily disabled — specifically for that exercise when he gets there. Not currently possible with the committed Terraform as-is.

**Kubernetes 1.34+ is required** for DRA (it went GA there; the API moved `resource.k8s.io/v1beta1` → `v1`). Terraform defaults to 1.34. Manifests written against older tutorials will not apply cleanly.

**The DRA manifests in `k8s/dra/` are unverified** against a live cluster — written to the v1 API shape but never applied. If he's debugging them, treat that as expected and coach him through `kubectl explain`; don't assume the files are correct.

## Conventions

- All infrastructure through Terraform — nothing clicked in the console, nothing `kubectl create` without a manifest.
- `terraform fmt` before committing; CI enforces it.
- Manifests are plain YAML for now. Helm/Kustomize is a deliberate later exercise, not a refactor to suggest unprompted.
- Keep the README's benchmark section current — it's the artifact's centrepiece.

## Things worth proactively suggesting

- Filling in `docs/JOURNAL.md` after a working session (it doubles as interview prep and LinkedIn post material).
- Recording real numbers in the README benchmark table once vLLM is serving.
- When he solves something non-obvious, noting it as a potential post — visible learning in public is part of the job-search strategy.

## Out of scope here

Job search, CV, and application material live in `~/Desktop/Job Search/`, not this repo. Keep this repo purely technical — it's public.
