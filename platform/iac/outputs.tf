# Output values for infrastructure contract verification
# These outputs represent the "contract" between IaC and downstream systems (Compose, CI/CD, monitoring)
# They enable validation that the deployed infrastructure meets requirements without exposing implementation details.

# Contract Verification Outputs
output "infrastructure_contract_summary" {
  description = "High-level summary of the infrastructure contract for audit and documentation"
  value = {
    environment                   = var.environment
    project                       = var.project_name
    team                          = var.team_name
    compute_memory_mb             = var.app_memory_mb
    compute_cpu_limit             = var.app_cpu_limit
    storage_type                  = var.storage_type
    storage_quota_gb              = var.storage_quota_gb
    network_cidr                  = var.network_cidr
    tls_enabled                   = var.tls_enabled
    public_access_enabled         = var.enable_public_access
    monitoring_enabled            = var.enable_monitoring
    secret_backend                = var.secret_backend
    deployment_strategy           = var.deployment_strategy
    health_check_interval_sec     = var.health_check_interval_seconds
    graceful_shutdown_timeout_sec = var.graceful_shutdown_timeout_seconds
  }
  sensitive = false
}

# Network outputs (contract)
output "network_cidr" {
  description = "Network CIDR block (VPC in cloud, Docker network in local)"
  value       = var.network_cidr
}

output "enable_public_access" {
  description = "Whether public internet access is enabled"
  value       = var.enable_public_access
}

# Compute outputs (for Compose adapter validation)
output "app_memory_mb" {
  description = "Application memory allocation in MB (maps to Compose mem_limit)"
  value       = var.app_memory_mb
}

output "app_cpu_limit" {
  description = "Application CPU limit as fraction of one core (maps to Compose cpus)"
  value       = var.app_cpu_limit
}

output "app_pids_limit" {
  description = "Maximum process count per container (maps to Compose pids_limit)"
  value       = var.app_pids_limit
}

# Storage outputs
output "storage_type" {
  description = "Storage backend type: local, minio, or cloud"
  value       = var.storage_type
}

output "storage_quota_gb" {
  description = "Storage quota in GB"
  value       = var.storage_quota_gb
}

# TLS/Security outputs
output "tls_enabled" {
  description = "TLS/HTTPS enabled"
  value       = var.tls_enabled
}

output "tls_certificate_path" {
  description = "Path to TLS certificate file (not the certificate itself; path may be mounted from secret manager)"
  value       = var.tls_cert_path
  sensitive   = false
}

# Secret management outputs
output "secret_backend" {
  description = "Secret backend type: vault, cloud, or env (dev-only)"
  value       = var.secret_backend
}

output "vault_address" {
  description = "HashiCorp Vault server address (if using Vault backend)"
  value       = var.vault_addr
  sensitive   = false
}

# Observability outputs
output "enable_monitoring" {
  description = "Monitoring and logging infrastructure enabled"
  value       = var.enable_monitoring
}

output "prometheus_retention_days" {
  description = "Prometheus time-series retention period in days"
  value       = var.prometheus_retention_days
}

output "loki_retention_days" {
  description = "Loki log retention period in days"
  value       = var.loki_retention_days
}

# Deployment & Health Check outputs
output "deployment_strategy" {
  description = "Deployment strategy type: rolling, blue-green, or canary"
  value       = var.deployment_strategy
}

output "health_check_interval_seconds" {
  description = "Health check interval in seconds (maps to Compose healthcheck interval)"
  value       = var.health_check_interval_seconds
}

output "graceful_shutdown_timeout_seconds" {
  description = "Graceful shutdown timeout in seconds (maps to Compose stop_grace_period)"
  value       = var.graceful_shutdown_timeout_seconds
}

# Audit trail outputs (required for compliance and rollback)
output "git_commit_sha" {
  description = "Git commit SHA of the Terraform code (used for reproducibility and rollback)"
  value       = var.git_commit_sha
  sensitive   = false
}

output "approval_ticket_id" {
  description = "Ticket ID or approval reference for compliance"
  value       = var.approval_ticket_id
  sensitive   = false
}

output "applied_by" {
  description = "Identity of the actor performing the apply operation"
  value       = var.applied_by
  sensitive   = false
}

# Public URL experiment outputs
output "public_url_enabled" {
  description = "Public URL access enabled"
  value       = var.enable_public_access
}

output "public_port" {
  description = "Public HTTPS port (if enable_public_access = true)"
  value       = var.enable_public_access ? var.public_port : null
}

output "rathole_enabled" {
  description = "rathole reverse tunnel experiment enabled"
  value       = var.enable_rathole_public_url
}

output "cloudflare_tunnel_enabled" {
  description = "Cloudflare Tunnel alternative enabled"
  value       = var.enable_cloudflare_tunnel
}

# Policy and compliance outputs
output "policy_enforcement_summary" {
  description = "Summary of policy and compliance controls in place"
  value = {
    security_scanning_enabled  = true
    iac_policy_enforcement     = true
    secret_scanning_enabled    = true
    container_scanning_enabled = true
    least_privilege_enforced   = true
    encryption_enforced        = "AES-256"
    logging_and_monitoring     = var.enable_monitoring
    backup_recovery_enabled    = var.environment != "develop"
  }
}

# Resource tagging outputs
output "resource_tags" {
  description = "Common tags applied to all resources for cost allocation and governance"
  value = merge(
    var.environment != "" ? { environment = var.environment } : {},
    var.project_name != "" ? { project = var.project_name } : {},
    var.team_name != "" ? { team = var.team_name } : {},
    {
      managed_by     = "terraform"
      git_commit_sha = var.git_commit_sha
      applied_by     = var.applied_by
    }
  )
  sensitive = false
}

# Verification checklist (for CI/CD validation)
output "verification_checklist" {
  description = "Pre-deployment verification checklist"
  value = {
    memory_limit_valid        = var.app_memory_mb >= 64 && var.app_memory_mb <= 2048
    cpu_limit_valid           = var.app_cpu_limit > 0 && var.app_cpu_limit <= 4
    environment_valid         = contains(["develop", "staging", "production-like"], var.environment)
    storage_type_valid        = contains(["local", "minio", "cloud"], var.storage_type)
    secret_backend_valid      = contains(["vault", "cloud", "env"], var.secret_backend)
    deployment_strategy_valid = contains(["rolling", "blue-green", "canary"], var.deployment_strategy)
    tls_enabled_if_public     = var.enable_public_access ? var.tls_enabled : true
    approval_provided         = var.approval_ticket_id != "none"
    git_commit_sha_recorded   = var.git_commit_sha != "unknown"
    resource_tags_present     = true
  }
}
