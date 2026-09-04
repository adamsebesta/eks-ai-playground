output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "lb_controller_role_arn" {
  value = module.lb_controller_irsa_role.iam_role_arn
}

output "faceapp_ecr_repository_url" {
  value = aws_ecr_repository.faceapp.repository_url
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
