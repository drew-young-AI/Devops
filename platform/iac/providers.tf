# Provider configuration for multi-cloud support
# This skeleton validates provider-neutral IaC patterns without committing to a single cloud vendor.
# Future: AWS, GCP, Azure, or hybrid deployments can be added by uncommenting and configuring the provider blocks below.

terraform {
  required_version = ">= 1.0"
  required_providers {
    # Future: Uncomment and configure for your target cloud provider
    # aws = {
    #   source  = "hashicorp/aws"
    #   version = "~> 5.0"
    # }
    # google = {
    #   source  = "hashicorp/google"
    #   version = "~> 5.0"
    # }
    # azurerm = {
    #   source  = "hashicorp/azurerm"
    #   version = "~> 3.0"
    # }
  }

  # State management strategy:
  # Phase 1: Local encrypted state (current)
  # Phase 2: MinIO S3-compatible backend (optional experiment)
  # Phase 3: Cloud provider backend (AWS S3, GCS, Azure Storage, etc.)
  #
  # CRITICAL: State files MUST NEVER be committed to Git.
  # Ensure .gitignore includes: *.tfstate, *.tfstate.*, .terraform/
  #
  # For multi-team scenarios, use:
  #   backend "s3" {
  #     bucket         = "devops-state"
  #     key            = "platform/iac/terraform.tfstate"
  #     region         = "us-east-1"
  #     encrypt        = true
  #     dynamodb_table = "terraform_locks"
  #   }
}

# Provider declarations (commented out; uncomment and configure for your environment)
#
# Example AWS provider:
# provider "aws" {
#   region = var.aws_region
#
#   default_tags {
#     tags = local.common_tags
#   }
# }
#
# Example GCP provider:
# provider "google" {
#   project = var.gcp_project_id
#   region  = var.gcp_region
# }
#
# Example Azure provider:
# provider "azurerm" {
#   features {}
#
#   subscription_id = var.azure_subscription_id
#   tenant_id       = var.azure_tenant_id
# }

locals {
  # Common tagging strategy for all resources (applies to AWS, GCP, Azure)
  # Enables cost tracking, ownership attribution, environment isolation, compliance auditing
  common_tags = {
    project     = "devops-poc"
    environment = var.environment
    team        = "platform"
    managed_by  = "terraform"
    created_at  = timestamp()
    git_commit  = try(var.git_commit_sha, "unknown")
  }
}
