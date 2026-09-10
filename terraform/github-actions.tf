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
