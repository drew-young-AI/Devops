# Core infrastructure resource definitions (provider-neutral contract)
# This module defines the logical structure of the platform without committing to a specific cloud provider.
# Future: Cloud-specific implementations can be created in separate modules (aws/, gcp/, azure/).
#
# Mapping:
# - Local/Docker: Variables map directly to Compose resource limits (memory, CPU, healthcheck)
# - Cloud (AWS): Variables map to EC2, VPC, Security Groups, ECS, RDS, S3
# - Cloud (GCP): Variables map to Compute Engine, VPC, Cloud Storage, Firestore
# - Cloud (Azure): Variables map to VMs, Virtual Networks, Managed Identity, Azure Storage

# Define the platform infrastructure contract
# This captures the minimum requirements for the DevOps control plane

# 1. Network Infrastructure
# In Docker/Compose: Docker networks (e.g., "devops-net")
# In Cloud: VPC, Subnets, Route Tables, Network ACLs, Security Groups
resource "null_resource" "network_contract" {
  # This is a placeholder representing network infrastructure
  # In a real provider, this would be:
  #   - AWS: aws_vpc, aws_subnet, aws_route_table, aws_security_group
  #   - GCP: google_compute_network, google_compute_subnetwork
  #   - Azure: azurerm_virtual_network, azurerm_subnet, azurerm_network_security_group
  #
  # Contract:
  triggers = {
    network_cidr              = var.network_cidr
    enable_public_access      = var.enable_public_access
    security_posture          = "public_access_gated_by_firewall_and_waf"
    encryption_in_transit     = "tls_required"
    encryption_at_rest        = "enabled"
    network_segment_isolation = "enabled"
  }

  lifecycle {
    ignore_changes = all
  }
}

# 2. Compute Resources (Application Workload)
# In Docker/Compose: Service definition in compose.yaml (mem_limit, cpus, healthcheck)
# In Cloud: EC2/VM instances, Kubernetes pods, container services (ECS, GKE, ACI)
resource "null_resource" "compute_contract" {
  # Placeholder for compute infrastructure
  # Contract: Resource limits align with Compose configuration
  triggers = {
    memory_limit_mb           = tostring(var.app_memory_mb)
    cpu_limit                 = tostring(var.app_cpu_limit)
    pids_limit                = tostring(var.app_pids_limit)
    tls_enabled               = tostring(var.tls_enabled)
    health_check_interval_sec = tostring(var.health_check_interval_seconds)
    graceful_shutdown_timeout = tostring(var.graceful_shutdown_timeout_seconds)
    deployment_strategy       = var.deployment_strategy
    security_context          = "run_as_non_root=true,read_only_filesystem=true,drop_capabilities=ALL,no_new_privileges=true"
  }

  lifecycle {
    ignore_changes = all
  }
}

# 3. Storage Infrastructure
# In Docker/Compose: Named volumes, bind mounts
# In Cloud: EBS, GCE Persistent Disk, Azure Managed Disk, S3, GCS, Azure Blob Storage
resource "null_resource" "storage_contract" {
  # Placeholder for storage infrastructure
  triggers = {
    storage_type                = var.storage_type
    storage_quota_gb            = tostring(var.storage_quota_gb)
    encryption_at_rest          = "enabled"
    backup_enabled              = var.environment != "develop" ? "true" : "false"
    point_in_time_recovery_days = tostring(var.environment == "production-like" ? 30 : 7)
    access_pattern              = "read_write"
  }

  lifecycle {
    ignore_changes = all
  }
}

# 4. Secret Management
# In Docker/Compose: Environment variables, mounted secrets (not in Git!)
# In Cloud: AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, HashiCorp Vault
resource "null_resource" "secret_contract" {
  # Placeholder for secret management infrastructure
  # CRITICAL: Secrets MUST NEVER be stored in code, Git, or logs.
  # Use environment-specific secret backends only.
  triggers = {
    secret_backend                  = var.secret_backend
    vault_server                    = var.vault_addr
    secret_rotation_enabled         = true
    secret_rotation_interval_days   = 90
    secret_audit_logging            = true
    least_privilege_access_policies = "enforced"
    encryption_in_transit           = "tls_required"
  }

  lifecycle {
    ignore_changes = all
  }
}

# 5. Observability Infrastructure
# In Docker/Compose: Prometheus, Loki, Grafana (local containers)
# In Cloud: CloudWatch, Datadog, Stackdriver, Azure Monitor, Prometheus Operator (Kubernetes)
resource "null_resource" "observability_contract" {
  # Placeholder for monitoring, logging, tracing infrastructure
  triggers = {
    metrics_collection_enabled = var.enable_monitoring ? "true" : "false"
    prometheus_retention_days  = tostring(var.prometheus_retention_days)
    logs_collection_enabled    = var.enable_monitoring ? "true" : "false"
    loki_retention_days        = tostring(var.loki_retention_days)
    tracing_enabled            = "false"
    audit_logging_enabled      = "true"
    cost_tracking_enabled      = "true"
  }

  lifecycle {
    ignore_changes = all
  }
}

# 6. Ingress & Load Balancing
# In Docker/Compose: NGINX reverse proxy (local)
# In Cloud: AWS ALB/NLB, GCP Cloud Load Balancer, Azure Load Balancer, AWS API Gateway
resource "null_resource" "ingress_contract" {
  # Placeholder for ingress/load balancer infrastructure
  triggers = {
    tls_enabled                  = var.tls_enabled ? "true" : "false"
    tls_certificate_path         = var.tls_cert_path
    public_access_enabled        = var.enable_public_access ? "true" : "false"
    public_port                  = tostring(var.public_port)
    waf_protection_enabled       = var.enable_public_access ? "true" : "false"
    ddos_protection_enabled      = var.enable_public_access ? "true" : "false"
    rate_limiting_enabled        = "true"
    health_check_path            = "/health/ready"
    health_check_interval_sec    = tostring(var.health_check_interval_seconds)
    graceful_connection_draining = tostring(var.graceful_shutdown_timeout_seconds)
    request_timeout_sec          = "30"
  }

  lifecycle {
    ignore_changes = all
  }
}

# 7. Public URL Access (Experiment)
# In Local: rathole reverse tunnel client (optional)
# In Cloud: Cloud-hosted relay server + rathole, or Cloudflare Tunnel
resource "null_resource" "public_url_contract" {
  # Placeholder for public URL experiment infrastructure
  # This is an optional feature for accessing MacBook services from the internet.
  # Two strategies:
  # A) Cloud trial VM + rathole relay + NGINX (self-hosted, more control)
  # B) Cloudflare Tunnel (convenience, zero-trust model)
  count = var.enable_public_access ? 1 : 0

  triggers = {
    strategy_type                = var.enable_cloudflare_tunnel ? "cloudflare-tunnel" : "cloud-rathole-relay"
    cloudflare_tunnel_enabled    = var.enable_cloudflare_tunnel ? "true" : "false"
    rathole_relay_enabled        = var.enable_rathole_public_url ? "true" : "false"
    public_hostname              = "devops.example.com"
    tls_enabled                  = "true"
    authentication_enabled       = "true"
    token_rotation_enabled       = "true"
    token_rotation_interval_days = "30"
    audit_logging_enabled        = "true"
    resource_cleanup_on_exit     = "true"
  }

  lifecycle {
    ignore_changes = all
  }
}

# 8. CI/CD Infrastructure Contract
# This is metadata-only; actual CI/CD runs via GitHub Actions or self-hosted runners
resource "null_resource" "cicd_contract" {
  # Placeholder for CI/CD infrastructure contract
  # Actual implementation: .github/workflows/*.yml files
  triggers = {
    trigger_type                 = "git_push"
    ci_platform                  = "github_actions"
    pipeline_stages              = "fmt,validate,checkov,plan,review,apply"
    artifact_storage_backend     = var.storage_type
    approval_required_for_apply  = var.environment != "develop"
    state_locking_enabled        = true
    change_audit_logging_enabled = true
    rollback_capability_enabled  = true
  }

  lifecycle {
    ignore_changes = all
  }
}

# 9. Policy & Compliance
# This resource represents the policy-as-code enforcement for the platform
resource "null_resource" "policy_contract" {
  # Placeholder for policy and compliance infrastructure
  # Actual implementation: Checkov rules, OPA policies, GitHub branch protection rules
  triggers = {
    security_scanning_enabled             = true
    iac_policy_enforcement_enabled        = true
    secret_scanning_enabled               = true
    container_scanning_enabled            = true
    dependency_scanning_enabled           = true
    least_privilege_principle_enforced    = true
    encryption_enforced_minimum           = "AES-256"
    logging_and_monitoring_required       = true
    backup_and_disaster_recovery_required = var.environment != "develop"
    multi_tenancy_isolation_enforced      = false # Not applicable to single MacBook
  }

  lifecycle {
    ignore_changes = all
  }
}

# 10. Resource Tagging & Cost Attribution
# All resources must have consistent tags for cost tracking and governance
locals {
  # These tags are applied to all resources (where applicable by provider)
  # Enable cost allocation, ownership attribution, environment isolation, compliance auditing
  resource_tags = merge(
    var.environment != "" ? {
      environment = var.environment
    } : {},
    var.project_name != "" ? {
      project = var.project_name
    } : {},
    var.team_name != "" ? {
      team = var.team_name
    } : {},
    {
      managed_by     = "terraform"
      created_at     = timestamp()
      git_commit_sha = var.git_commit_sha
      applied_by     = var.applied_by
    }
  )
}

# Audit trail: Record the plan and approval information
# This is metadata-only; actual state management happens in the state backend
resource "null_resource" "audit_trail" {
  triggers = {
    git_commit_sha     = var.git_commit_sha
    approval_ticket_id = var.approval_ticket_id
    applied_by         = var.applied_by
    timestamp          = timestamp()
    environment        = var.environment
    terraform_version  = "1.12.5" # OpenTofu version
  }

  lifecycle {
    ignore_changes = all
  }
}
