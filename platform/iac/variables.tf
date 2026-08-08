# Input variables for provider-neutral infrastructure contract
# These variables define the "shape" of the infrastructure without committing to a specific cloud provider.
# They map to Compose service configuration (pilots/station1-hello/compose.yaml) and platform requirements.

# Environment identification (required)
variable "environment" {
  type        = string
  description = "Deployment environment: develop, staging, production-like. Determines resource sizing, cost optimization, and security policy strictness."
  validation {
    condition     = contains(["develop", "staging", "production-like"], var.environment)
    error_message = "Environment must be 'develop', 'staging', or 'production-like'."
  }
}

# Project and ownership metadata
variable "project_name" {
  type        = string
  default     = "devops-poc"
  description = "Project identifier used for resource naming, tagging, and billing allocation."
}

variable "team_name" {
  type        = string
  default     = "platform"
  description = "Team responsible for managing this infrastructure (used in tags and notifications)."
}

# Compute resource configuration (maps to Compose service resource limits)
variable "app_memory_mb" {
  type        = number
  default     = 128
  description = "Application memory allocation in MB. Must match or exceed Compose mem_limit. Example: station1-hello uses 128MB."
  validation {
    condition     = var.app_memory_mb >= 64 && var.app_memory_mb <= 2048
    error_message = "Memory must be between 64MB and 2048MB."
  }
}

variable "app_cpu_limit" {
  type        = number
  default     = 0.25
  description = "Application CPU limit as fraction of one core. Example: 0.25 = 25% CPU. Matches Compose 'cpus' setting."
  validation {
    condition     = var.app_cpu_limit > 0 && var.app_cpu_limit <= 4
    error_message = "CPU limit must be between 0 and 4 cores."
  }
}

variable "app_pids_limit" {
  type        = number
  default     = 64
  description = "Maximum number of processes per container. Prevents fork bombs and resource exhaustion."
  validation {
    condition     = var.app_pids_limit >= 16 && var.app_pids_limit <= 512
    error_message = "PID limit must be between 16 and 512."
  }
}

# Storage configuration
variable "storage_type" {
  type        = string
  default     = "local"
  description = "Storage backend: 'local' (Mac /tmp, development only), 'minio' (S3-compatible), 'cloud' (AWS S3, GCS, Azure Blob)."
  validation {
    condition     = contains(["local", "minio", "cloud"], var.storage_type)
    error_message = "Storage must be 'local', 'minio', or 'cloud'."
  }
}

variable "storage_quota_gb" {
  type        = number
  default     = 10
  description = "Storage quota for application persistent volumes. Prevents runaway disk usage."
}

# Network configuration (contract)
variable "network_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "Network CIDR block for the platform infrastructure. In Compose, maps to 'networks'. For cloud: VPC/VNet CIDR."
}

variable "enable_public_access" {
  type        = bool
  default     = false
  description = "If true, allow public internet access to services. Requires WAF, DDoS protection, and strict security policies in production."
}

variable "public_port" {
  type        = number
  default     = 443
  description = "Public HTTPS port exposed to internet (if enable_public_access = true). Default: 443 (HTTPS)."
  validation {
    condition     = var.public_port >= 1024 && var.public_port <= 65535
    error_message = "Port must be between 1024 and 65535."
  }
}

# TLS/Certificate configuration
variable "tls_enabled" {
  type        = bool
  default     = true
  description = "Enable TLS/HTTPS. For develop: self-signed cert via mkcert. For production: managed certificate."
}

variable "tls_cert_path" {
  type        = string
  default     = "/etc/nginx/certs/devops.local.crt"
  description = "Path to TLS certificate file (local or mounted from secret manager)."
}

variable "tls_key_path" {
  type        = string
  default     = "/etc/nginx/certs/devops.local.key"
  description = "Path to TLS private key (must be stored securely, never committed to Git)."
  sensitive   = true
}

# Secret management
variable "secret_backend" {
  type        = string
  default     = "vault"
  description = "Secret backend: 'vault' (HashiCorp Vault Community), 'cloud' (AWS Secrets Manager, GCP Secret Manager, Azure Key Vault)."
  validation {
    condition     = contains(["vault", "cloud", "env"], var.secret_backend)
    error_message = "Secret backend must be 'vault', 'cloud', or 'env' (development only)."
  }
}

variable "vault_addr" {
  type        = string
  default     = "http://127.0.0.1:8200"
  description = "HashiCorp Vault server address. For local development: 127.0.0.1:8200."
}

# Observability configuration (maps to platform/observability/)
variable "enable_monitoring" {
  type        = bool
  default     = true
  description = "Enable metrics collection via Prometheus and log aggregation via Loki."
}

variable "prometheus_retention_days" {
  type        = number
  default     = 7
  description = "Prometheus time-series retention period in days. Development: 7 days; production: 30-90 days."
  validation {
    condition     = var.prometheus_retention_days >= 1 && var.prometheus_retention_days <= 365
    error_message = "Retention must be 1-365 days."
  }
}

variable "loki_retention_days" {
  type        = number
  default     = 7
  description = "Loki log retention period in days."
  validation {
    condition     = var.loki_retention_days >= 1 && var.loki_retention_days <= 365
    error_message = "Retention must be 1-365 days."
  }
}

# Deployment & rollback strategy
variable "deployment_strategy" {
  type        = string
  default     = "rolling"
  description = "Deployment strategy: 'rolling' (gradual replacement), 'blue-green' (parallel environments), 'canary' (percentage-based rollout)."
  validation {
    condition     = contains(["rolling", "blue-green", "canary"], var.deployment_strategy)
    error_message = "Strategy must be 'rolling', 'blue-green', or 'canary'."
  }
}

variable "health_check_interval_seconds" {
  type        = number
  default     = 5
  description = "Health check interval in seconds (for liveness and readiness probes). Matches Compose healthcheck 'interval'."
  validation {
    condition     = var.health_check_interval_seconds >= 1 && var.health_check_interval_seconds <= 60
    error_message = "Interval must be 1-60 seconds."
  }
}

variable "graceful_shutdown_timeout_seconds" {
  type        = number
  default     = 30
  description = "Time allowed for graceful shutdown before SIGKILL. Matches Compose 'stop_grace_period'."
  validation {
    condition     = var.graceful_shutdown_timeout_seconds >= 5 && var.graceful_shutdown_timeout_seconds <= 300
    error_message = "Timeout must be 5-300 seconds."
  }
}

# Git and audit trail
variable "git_commit_sha" {
  type        = string
  default     = "unknown"
  description = "Git commit SHA of the Terraform code that produced this plan. Used for audit trail and rollback."
}

variable "applied_by" {
  type        = string
  default     = "terraform-automation"
  description = "Identity of the actor performing the apply operation (for audit log)."
}

variable "approval_ticket_id" {
  type        = string
  default     = "none"
  description = "Ticket ID or approval reference (e.g., GitHub PR #123, Jira TICKET-456) for compliance and audit trail."
}

# Feature flags (for gradual rollout of new capabilities)
variable "enable_rathole_public_url" {
  type        = bool
  default     = false
  description = "Enable rathole reverse tunnel for public URL access (experimental feature)."
}

variable "enable_cloudflare_tunnel" {
  type        = bool
  default     = false
  description = "Enable Cloudflare Tunnel as alternative to rathole for public URL (convenience, not self-hosted)."
}

# Region/Zone selection (used by cloud providers)
variable "cloud_region" {
  type        = string
  default     = "us-east-1"
  description = "Cloud region for AWS/GCP/Azure deployment (future; not used in local development)."
}

variable "availability_zones" {
  type        = list(string)
  default     = []
  description = "List of availability zones for multi-AZ deployment (production-like only; empty for develop)."
}
