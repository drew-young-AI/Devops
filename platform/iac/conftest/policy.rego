# OPA/Conftest policies for Terraform validation
# These policies enforce governance rules for infrastructure-as-code
# Reference: https://www.conftest.dev/

# Package declaration
package main

# Policy 1: Deny resources without proper tagging
# All resources should have environment, project, and team tags for cost allocation
deny[msg] {
    resource := input.resource
    resource_type := resource[_][_]
    not resource_type.tags
    msg := sprintf("Resource %s missing required tags", [resource])
}

# Policy 2: Enforce TLS for public-facing resources
# If enable_public_access is true, TLS must be enabled
deny[msg] {
    input.variable.enable_public_access == true
    input.variable.tls_enabled == false
    msg := "TLS must be enabled when public access is enabled"
}

# Policy 3: Memory allocation validation
# Application memory must be within acceptable range
deny[msg] {
    memory := input.variable.app_memory_mb
    memory < 64
    msg := sprintf("Application memory %dMB is below minimum of 64MB", [memory])
}

deny[msg] {
    memory := input.variable.app_memory_mb
    memory > 2048
    msg := sprintf("Application memory %dMB exceeds maximum of 2048MB", [memory])
}

# Policy 4: CPU allocation validation
# Application CPU must be within acceptable range
deny[msg] {
    cpu := input.variable.app_cpu_limit
    cpu <= 0
    msg := "Application CPU must be greater than 0"
}

deny[msg] {
    cpu := input.variable.app_cpu_limit
    cpu > 4
    msg := sprintf("Application CPU %.2f exceeds maximum of 4 cores", [cpu])
}

# Policy 5: Environment validation
# Only allowed environments
deny[msg] {
    env := input.variable.environment
    allowed := ["develop", "staging", "production-like"]
    not contains(allowed, env)
    msg := sprintf("Environment '%s' not in allowed values: %v", [env, allowed])
}

# Policy 6: Storage type validation
deny[msg] {
    storage := input.variable.storage_type
    allowed := ["local", "minio", "cloud"]
    not contains(allowed, storage)
    msg := sprintf("Storage type '%s' not in allowed values: %v", [storage, allowed])
}

# Policy 7: Secret backend validation
# Only allowed secret backends
deny[msg] {
    backend := input.variable.secret_backend
    allowed := ["vault", "cloud", "env"]
    not contains(allowed, backend)
    msg := sprintf("Secret backend '%s' not in allowed values: %v", [backend, allowed])
}

# Policy 8: Restrict plain-text .env in production
deny[msg] {
    input.variable.environment == "production-like"
    input.variable.secret_backend == "env"
    msg := "Plain-text environment variables (.env) are not allowed in production-like environments; use Vault or cloud secret manager"
}

# Policy 9: Deployment strategy validation
deny[msg] {
    strategy := input.variable.deployment_strategy
    allowed := ["rolling", "blue-green", "canary"]
    not contains(allowed, strategy)
    msg := sprintf("Deployment strategy '%s' not in allowed values: %v", [strategy, allowed])
}

# Policy 10: Health check interval validation
deny[msg] {
    interval := input.variable.health_check_interval_seconds
    interval < 1
    msg := "Health check interval must be at least 1 second"
}

deny[msg] {
    interval := input.variable.health_check_interval_seconds
    interval > 60
    msg := "Health check interval exceeds 60 seconds; may miss failures"
}

# Policy 11: Graceful shutdown timeout validation
deny[msg] {
    timeout := input.variable.graceful_shutdown_timeout_seconds
    timeout < 5
    msg := "Graceful shutdown timeout must be at least 5 seconds"
}

deny[msg] {
    timeout := input.variable.graceful_shutdown_timeout_seconds
    timeout > 300
    msg := "Graceful shutdown timeout exceeds 300 seconds (5 minutes)"
}

# Policy 12: Approval required for non-development changes
deny[msg] {
    input.variable.environment != "develop"
    input.variable.approval_ticket_id == "none"
    msg := "Non-development environment changes require approval ticket reference"
}

# Policy 13: Git commit SHA must be recorded
deny[msg] {
    input.variable.environment != "develop"
    input.variable.git_commit_sha == "unknown"
    msg := "Production-like changes must include git_commit_sha for audit trail"
}

# Policy 14: Restrict public access to MacBook during development
warn[msg] {
    input.variable.environment == "develop"
    input.variable.enable_public_access == true
    msg := "WARNING: Public access enabled in development environment; ensure this is intentional and temporary"
}

# Policy 15: Rathole and Cloudflare Tunnel exclusivity
deny[msg] {
    input.variable.enable_rathole_public_url == true
    input.variable.enable_cloudflare_tunnel == true
    msg := "Cannot enable both rathole and Cloudflare Tunnel simultaneously; choose one"
}

# Helper function
contains(array, element) {
    array[_] == element
}

# Audit trail warnings
warn[msg] {
    input.variable.applied_by == "terraform-automation"
    msg := "Automated apply detected; ensure approvals were granted in CI/CD pipeline"
}
