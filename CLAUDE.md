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
terraform/            # VPC + EKS, CPU node group + GPU node group
k8s/gpu/              # NVIDIA device plugin (classic path)
k8s/vllm/             # vLLM via nvidia.com/gpu integer resource
k8s/dra/              # same workload via Dynamic Resource Allocation
Makefile              # every workflow is one target
```

## Hard constraints — do not violate

**Cost.** GPU nodes are ~$0.30–0.45/hr spot; the EKS control plane is ~$73/mo. The GPU node group **defaults to 0 nodes** and that default must stay. Always remind him to `make gpu-down` after a session and `make eks-down` between practice weeks. Never suggest raising `gpu_desired_size` in the committed default.

**DRA and Karpenter are mutually exclusive.** DRA does not work with Karpenter or EKS Auto Mode — managed node groups only. Week 8 (Karpenter + device plugin) and Week 8b (DRA) are deliberately separate exercises. Don't try to combine them.

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
