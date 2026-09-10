# App-level (not infra-controller-level) Pod Identity roles — narrowly
# scoped AWS permissions for specific workloads, the actual K8s equivalent
# of an ECS task role (vs. the node role, which every pod on that node
# inherits by default regardless of app).

# EKS Pod Identity's trust policy — simpler than IRSA's OIDC federation:
# just trusts the pods.eks.amazonaws.com service principal directly. Which
# ServiceAccount can actually assume a given role comes from that role's
# own aws_eks_pod_identity_association, not from anything in this shared
# trust policy.
data "aws_iam_policy_document" "eks_pod_identity_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# --- faceapp — first app-level (not infra-controller-level) AWS permission
# in this repo. Storage for detected-face snapshots, ties directly to the
# actual product concept (parent notification needs the matched frame, not
# just a log line).

resource "aws_s3_bucket" "faceapp_snapshots" {
  bucket = "${var.cluster_name}-faceapp-snapshots"

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

resource "aws_iam_role" "faceapp" {
  name               = "${var.cluster_name}-faceapp"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_assume.json

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

# Scoped to exactly this one bucket — the actual "narrow, per-app
# permission" ollama/faceapp never had before this, same precision an ECS
# task role would give an application.
data "aws_iam_policy_document" "faceapp_s3" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.faceapp_snapshots.arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.faceapp_snapshots.arn]
  }
}

resource "aws_iam_role_policy" "faceapp_s3" {
  name   = "s3-snapshots"
  role   = aws_iam_role.faceapp.id
  policy = data.aws_iam_policy_document.faceapp_s3.json
}

# The actual binding: only pods using the "faceapp" ServiceAccount in the
# "faceapp" namespace can assume this role — nothing else on the cluster,
# including other pods on the same node, gets these S3 permissions.
resource "aws_eks_pod_identity_association" "faceapp" {
  cluster_name    = module.eks.cluster_name
  namespace       = "faceapp"
  service_account = "faceapp"
  role_arn        = aws_iam_role.faceapp.arn
}

# --- Fluent Bit — the "Execution Role writes to CloudWatch Logs" piece of
# ECS finally has a real K8s home: a DaemonSet (one per node, ships every
# container's logs from that node) with its own Pod Identity role, same
# pattern as faceapp's S3 access above — narrowly scoped, not the node role.

resource "aws_iam_role" "fluent_bit" {
  name               = "${var.cluster_name}-fluent-bit"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_assume.json

  tags = {
    Project = "eks-ai-playground"
    Owner   = "adam"
  }
}

data "aws_iam_policy_document" "fluent_bit_cloudwatch" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
    ]
    # Scoped to this cluster's own log group prefix, not "*" — same
    # least-privilege reasoning as every other role in this file.
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:/aws/eks/${var.cluster_name}/*"]
  }
}

resource "aws_iam_role_policy" "fluent_bit_cloudwatch" {
  name   = "cloudwatch-logs"
  role   = aws_iam_role.fluent_bit.id
  policy = data.aws_iam_policy_document.fluent_bit_cloudwatch.json
}

resource "aws_eks_pod_identity_association" "fluent_bit" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-for-fluent-bit"
  role_arn        = aws_iam_role.fluent_bit.arn
}
