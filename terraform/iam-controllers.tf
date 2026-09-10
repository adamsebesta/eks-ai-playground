# IRSA roles for infra controllers that install via Terraform's helm_release
# (main.tf VPC/EKS module outputs are what these actually depend on).

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

# Moved from an imperative `make alb-controller` Helm call to Terraform's own
# helm_release — needs real Terraform-computed values (VPC ID, IRSA role
# ARN), which a declarative Argo CD Application has no way to fetch at sync
# time. Static config lives in helm-values/; only genuinely per-deploy
# values are set here.
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
