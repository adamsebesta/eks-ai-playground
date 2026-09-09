# VPC: 3 AZs, private subnets for nodes, single NAT to keep costs down.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true # cost over HA — this is a playground

  # Required for the AWS Load Balancer Controller (Week 4)
  public_subnet_tags = { "kubernetes.io/role/elb" = 1 }
  # karpenter.sh/discovery: tag-based lookup, not hardcoded subnet IDs — the
  # standard production pattern. EC2NodeClass finds these declaratively.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Playground: public API endpoint, creator gets admin. Week 10: lock this down.
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Same discovery-tag pattern as the subnets above — EC2NodeClass finds
  # this security group by tag, not a hardcoded ID.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
    metrics-server         = {} # required for HPA — exposes the metrics.k8s.io API
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    # Always-on system pool — platform infra only (CoreDNS, Argo CD,
    # Karpenter, ALB Controller, monitoring). App workloads now live on the
    # Karpenter `general` pool instead (see k8s/karpenter/), so this stays
    # small and static on purpose.
    #
    # NOTE: min_size alone can't fix a capacity crunch here — EKS's
    # UpdateNodegroupConfig API requires desired >= min in the SAME call,
    # and desired_size is permanently ignore_changes'd by this module
    # (confirmed twice: this pool and the earlier GPU scale-up attempt).
    # If more headroom is ever needed, bump instance_types instead —
    # that field isn't ignored — or do a one-time manual
    # `aws eks update-nodegroup-config` outside Terraform.
    system = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }

    # GPU pool — spot g5.xlarge, scaled to 0 by default (make gpu-up / gpu-down)
    gpu = {
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = var.gpu_instance_types
      capacity_type  = "SPOT"
      min_size       = 0
      max_size       = 2
      desired_size   = var.gpu_desired_size

      labels = {
        workload = "gpu-inference"
      }

      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

# IRSA role for the EBS CSI driver — it needs real EC2 permissions
# (create/attach/delete volumes) to satisfy PersistentVolumeClaims.
# EKS ships no default StorageClass/CSI driver, so PVCs sit Pending without this.
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

# IRSA role for the AWS Load Balancer Controller — it needs real ELB/EC2
# permissions to provision an ALB/NLB in response to Ingress/Service objects.
module "lb_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${var.cluster_name}-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

# IMMUTABLE tags: once pushed, a tag can never be overwritten — forces every
# release to use a distinct tag (e.g. the commit SHA), which is what actually
# makes "the image tag IS the deploy trigger" (from the Argo CD work) a safe
# guarantee rather than a convention someone can accidentally violate.
resource "aws_ecr_repository" "faceapp" {
  name                 = "${var.cluster_name}-faceapp"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

# Centralized Helm chart hosting — same ECR account, OCI artifacts instead
# of container images. Named "charts/<name>" so the resulting reference
# reads naturally: oci://<registry>/charts/ollama:0.1.0. Deliberately
# MUTABLE (unlike the image repo) — chart versions get bumped in Chart.yaml
# per release, same convention as any public Helm chart repo.
resource "aws_ecr_repository" "chart_ollama" {
  name = "charts/ollama"

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

resource "aws_ecr_repository" "chart_faceapp" {
  name = "charts/faceapp"

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

# GitHub Actions OIDC — lets CI assume an AWS role without any long-lived
# access keys stored as GitHub secrets. The thumbprint isn't hardcoded: the
# module fetches GitHub's actual live TLS cert at apply time and computes
# the fingerprint from it, so it never goes stale across cert rotations.
module "github_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "~> 5.48"

  url = "https://token.actions.githubusercontent.com"

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.github_oidc_provider.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to main branch only — no PR/other-branch workflow can assume
    # this role, matching the same least-privilege reasoning as every other
    # IRSA role in this file (blast radius, not blanket trust).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # GitHub's "immutable subject claims" default embeds numeric owner/repo
      # IDs, not just names — confirmed by decoding the actual token, not
      # guessed. More secure than the name-only format: this repo's real
      # identity can never be spoofed by renaming/recreating a repo with the
      # same name.
      values = ["repo:adamsebesta@61263842/eks-ai-playground@1354764108:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.cluster_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

data "aws_iam_policy_document" "github_actions_ecr_push" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this specific action doesn't support resource-level scoping
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    # OCI Helm charts use the same underlying ECR registry API as container
    # images — same actions, just two more repository ARNs in scope.
    resources = [
      aws_ecr_repository.faceapp.arn,
      aws_ecr_repository.chart_ollama.arn,
      aws_ecr_repository.chart_faceapp.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr_push.json
}

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

# Moved from an imperative `make alb-controller`/`make karpenter` Helm call
# to Terraform's own helm_release — these two need real Terraform-computed
# values (VPC ID, IRSA role ARN, the auto-generated queue name), which a
# declarative Argo CD Application has no way to fetch at sync time. Static
# config lives in helm-values/; only genuinely per-deploy values are set here.
resource "helm_release" "alb_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = true

  values = [file("${path.module}/../helm-values/alb-controller/values.yaml")]

  set = [
    { name = "clusterName", value = module.eks.cluster_name },
    { name = "region", value = var.aws_region },
    { name = "vpcId", value = module.vpc.vpc_id },
    { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn", value = module.lb_controller_irsa_role.iam_role_arn },
  ]

  depends_on = [module.eks]
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
