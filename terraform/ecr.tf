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
