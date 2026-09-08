terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }

  # Week 3 exercise: move state to S3 + DynamoDB locking.
  # backend "s3" {}
}

provider "aws" {
  region  = var.aws_region
  profile = "personal"
}

# Only for controllers whose Helm values genuinely depend on Terraform
# outputs (real AWS resource IDs/ARNs) — alb-controller and karpenter here.
# Everything else (ollama, faceapp, monitoring) stays Argo CD-managed, since
# their values are Git-native, not Terraform-computed. See helm-values/ for
# the split reasoning.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}
