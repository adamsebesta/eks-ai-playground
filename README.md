# eks-ai-playground

A hands-on platform for learning to run AI inference workloads on Kubernetes — locally with [kind](https://kind.sigs.k8s.io/), and on AWS with EKS + GPU nodes, provisioned entirely through Terraform.

> Companion to [docs/LEARNING_PLAN.md](docs/LEARNING_PLAN.md) — a 12-week path from ECS background to a public GPU inference platform artifact (CKA → CKS along the way).

## What's here

```
├── docs/
│   ├── LEARNING_PLAN.md      # the 12-week plan
│   ├── ECS_TO_EKS.md         # concept mapping from ECS + where the real gap is
│   ├── GPU_SCHEDULING.md     # device plugin vs. DRA
│   └── JOURNAL.md            # weekly learning log (interview prep for free)
├── local/                    # kind cluster + CPU inference (no AWS costs)
│   ├── kind-config.yaml
│   └── manifests/ollama.yaml # Ollama serving a small model on CPU
├── terraform/                # EKS cluster: VPC, control plane, CPU + GPU node groups
├── k8s/
│   ├── gpu/                  # NVIDIA device plugin (classic GPU scheduling)
│   ├── vllm/                 # vLLM serving Qwen2.5-1.5B (OpenAI-compatible API)
│   └── dra/                  # same workload via Dynamic Resource Allocation (modern)
├── .github/workflows/ci.yaml # terraform fmt/validate + manifest linting
└── Makefile                  # every workflow, one command each
```

## Quick start — local (free)

```bash
make local-up          # kind cluster
make local-inference   # deploy Ollama + pull a small model (CPU)
make local-chat        # port-forward and test a completion
make local-down
```

## Quick start — EKS

```bash
# Prereqs: aws cli authenticated, terraform >= 1.9, kubectl, helm
make eks-up            # ~15 min: VPC + EKS + CPU node group; GPU capacity is Karpenter-managed, provisioned on demand
make bootstrap         # everything non-Terraform-managed: Argo CD, apps, Karpenter NodePools
make gpu-plugin        # NVIDIA device plugin — required on any GPU node regardless of how it was provisioned
make eks-down          # destroy everything
```

## Cost guardrails

| Thing | Cost | Rule |
|---|---|---|
| EKS control plane | ~$0.10/hr (~$73/mo) | `make eks-down` between practice weeks |
| 2× t3.medium (system) | ~$0.08/hr | destroyed with the cluster |
| g5.xlarge GPU (spot) | ~$0.30–0.45/hr | `make gpu-down` after every session |
| NAT gateway | ~$0.045/hr + data | destroyed with the cluster |

Everything is IaC — **destroying and re-provisioning is the practice.** A full rebuild should get under 30 minutes by Week 4.

## The artifact

By Week 9 this repo should demonstrate, publicly:
- An LLM served on your own EKS cluster via vLLM (OpenAI-compatible endpoint)
- **Both GPU scheduling models** — the classic device plugin *and* DRA — with a written comparison ([docs/GPU_SCHEDULING.md](docs/GPU_SCHEDULING.md))
- Benchmarks: tokens/sec, TTFT, concurrency behavior (recorded below)
- Autoscaling with Karpenter incl. spot interruption handling — and why it can't coexist with DRA
- CKS-grade hardening documented in `docs/SECURITY.md`

### Benchmarks

_(fill in during Week 8 — model, instance, tokens/sec, TTFT, cost per 1M tokens)_

## License

MIT
