# Karpenter: replaces the static `gpu` node group's fixed desired_size (which
# Terraform can never actually control — the module hardcodes
# ignore_changes on that field so it doesn't fight an autoscaler). Karpenter
# watches for unschedulable pods and provisions exactly-fitting nodes,
# instead of a pre-declared fixed size.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  # Pod Identity, not IRSA — closes the loop on the eks-pod-identity-agent
  # addon that's been installed since Day 1 but never actually used yet.
  enable_pod_identity             = true
  create_pod_identity_association = true

  enable_spot_termination = true # real spot interruption handling, Week 8's story

  # Pinned explicitly (same convention as lb_controller_irsa_role's
  # role_name) instead of letting the module auto-generate a random-suffix
  # name. That was the actual root problem — a static, predictable name
  # means EC2NodeClass can reference it directly as committed YAML, no
  # terraform output/sed step needed, and no CI-tool-coupling issue under
  # Atlantis or any other Terraform runner.
  # use_name_prefix defaults to true in this module — without setting it
  # false, node_iam_role_name is treated as a PREFIX and AWS still appends
  # random characters for uniqueness, exactly the problem this was meant
  # to eliminate. Confirmed by the actual apply output still showing a
  # random suffix despite this being set.
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false

  namespace       = "karpenter"
  service_account = "karpenter"

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.14.1"
  namespace        = "karpenter"
  create_namespace = true

  values = [file("${path.module}/../helm-values/karpenter/values.yaml")]

  set = [
    { name = "settings.clusterName", value = module.eks.cluster_name },
    { name = "settings.interruptionQueue", value = module.karpenter.queue_name },
  ]

  depends_on = [module.karpenter]
}
