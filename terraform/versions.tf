terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Week 3 exercise: move state to S3 + DynamoDB locking.
  # backend "s3" {}
}

provider "aws" {
  region  = var.aws_region
  profile = "personal"
}
