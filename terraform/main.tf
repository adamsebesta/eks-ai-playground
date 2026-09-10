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

    # No static gpu group anymore — fully replaced by the Karpenter-managed
    # `gpu` NodePool (k8s/karpenter/nodepool-gpu.yaml). This was the
    # original Week 7 "classic path" group, built before the ignore_changes
    # bug forced a pivot to Karpenter mid-session; it sat unused at
    # desired_size 0 ever since. Removed rather than left as confusing dead
    # weight — faceapp has used the Karpenter version exclusively all along.
  }

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}
