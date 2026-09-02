variable "aws_region" {
  description = "AWS region. eu-south-1 (Milan) is closest to Italy; check g5 spot availability, us-east-1 is the fallback."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-ai-playground"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. 1.34+ required for DRA (Dynamic Resource Allocation) GA — see docs/GPU_SCHEDULING.md"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.42.0.0/16"
}

variable "gpu_instance_types" {
  description = "GPU instance types for the inference node group (g5.xlarge = 1x A10G 24GB)"
  type        = list(string)
  default     = ["g5.xlarge"]
}

variable "gpu_desired_size" {
  description = "GPU nodes. Keep at 0 when not practicing — this is the cost lever (make gpu-up / gpu-down)."
  type        = number
  default     = 0
}
