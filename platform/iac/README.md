---
type: platform-adapter
title: IaC Adapter（OpenTofu）
description: OpenTofu skeleton with a provider-neutral contract, Checkov and OPA policy gates, and why nothing is applied yet.
tags:
  - iac
  - opentofu
  - policy
timestamp: 2026-08-09T01:15:06+08:00
---
# Infrastructure as Code (IaC) — DevOps Platform

This directory contains the **provider-neutral infrastructure contract** for the DevOps platform. It defines the logical structure of the platform without committing to a specific cloud vendor (AWS, GCP, Azure).

## 📋 Overview

- **Engine**: OpenTofu (v1.12.5+)
- **Philosophy**: Provider-neutral contract with future cloud adapters
- **Goal**: Validate infrastructure patterns, enforce security policies, and enable platform portability

## 📁 File Structure

```
platform/iac/
├── README.md                          # This file
├── providers.tf                       # Cloud provider configuration (commented out)
├── variables.tf                       # Input variables (resource requests, environment config)
├── main.tf                            # Core resource definitions (contract)
├── outputs.tf                         # Output values for downstream systems
├── terraform.tfvars.example           # Example variable values (copy and customize)
├── checkov.yaml                       # Security scanning configuration
├── conftest/
│   └── policy.rego                    # OPA/Conftest governance rules
└── (no .tfstate files — see .gitignore)
```

## 🚀 Quick Start

### 1. Initialize and Validate

```bash
cd platform/iac

# Initialize OpenTofu backend (local state)
tofu init

# Check format
tofu fmt -check -recursive .

# Validate syntax
tofu validate
```

### 2. Run Security Scans

```bash
# Checkov: Terraform security scanning
checkov --directory . --framework terraform --config-file checkov.yaml

# Conftest: Custom OPA policies
conftest test -p conftest/ -d . *.tf
```

### 3. Generate Plan (Preview)

```bash
# Create a plan using example variables
tofu plan \
  -var-file="terraform.tfvars.example" \
  -var="git_commit_sha=$(git rev-parse HEAD)" \
  -var="applied_by=manual-testing" \
  -out=tfplan

# View plan in human-readable format
tofu show tfplan

# View plan in JSON format (for CI/CD processing)
tofu show -json tfplan > plan.json
```

### 4. Apply (Manual, Requires Approval)

**⚠️ IMPORTANT**: Apply requires explicit approval. This is not automated.

```bash
# Only after approval and security review
tofu apply tfplan
```

## 📊 Variables & Mapping

All variables are defined in `variables.tf` with validation and documentation.

### Key Mappings

| Variable | Compose Mapping | Cloud Mapping |
|---|---|---|
| `app_memory_mb` | `mem_limit` | EC2/VM memory, ECS task memory |
| `app_cpu_limit` | `cpus` | EC2/VM CPU, ECS task CPU |
| `app_pids_limit` | `pids_limit` | Process limit |
| `network_cidr` | Docker network | VPC/VNet CIDR |
| `tls_enabled` | NGINX cert mount | AWS ACM, GCP Managed Cert |
| `storage_type` | Volume drivers | S3, GCS, Azure Blob Storage |

### Default Values (Development)

```hcl
environment                    = "develop"
app_memory_mb                  = 128       # Matches station1-hello
app_cpu_limit                  = 0.25
storage_type                   = "local"
tls_enabled                    = true
secret_backend                 = "vault"
enable_monitoring              = true
deployment_strategy            = "rolling"
enable_public_access           = false
```

## 🔒 Security Policies

### Checkov Checks

- ✅ Encryption at rest and in transit
- ✅ Least privilege IAM policies
- ✅ Public access restrictions
- ✅ Logging and monitoring enforcement
- ✅ Backup and disaster recovery

### OPA/Conftest Policies

Custom policies enforce:
- Resource tagging for cost allocation
- Memory/CPU bounds (64-2048 MB, 0-4 CPUs)
- Secret backend validation (Vault, cloud, not env in prod)
- TLS required for public access
- Approval tickets for non-development
- Git commit SHA recording for audit trail

**View policies**: `conftest/policy.rego`

## 📝 State Management

### Local State (Phase 1)

```bash
# State stored locally
ls terraform.tfstate           # ⚠️ Never commit this to Git
ls terraform.tfstate.backup
```

**Ensure `.gitignore` includes**:
```
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
```

### Future: Remote State (Phase 2+)

```hcl
# Uncomment in providers.tf for cloud deployment
backend "s3" {
  bucket         = "devops-state"
  key            = "platform/iac/terraform.tfstate"
  encrypt        = true
  dynamodb_table = "terraform_locks"
}
```

## 🔄 GitHub Actions Workflow

### Automated on Push/PR

The workflow `.github/workflows/iac-validate.yml` runs:

1. **Format Check** — Ensure consistent style
2. **Syntax Validation** — Catch typos and invalid HCL
3. **Checkov Scan** — Security policy enforcement
4. **Terraform Plan** — Preview changes (no apply)
5. **OPA Validation** — Custom governance rules
6. **Evidence Generation** — Metadata for audit trail

### Artifacts

All check results saved to `evidence/`:
- `checkov_results.json` — Security findings
- `tfsec_results.sarif` — Additional Terraform security scan
- `iac_metadata.json` — Workflow metadata (commit, author, timestamp)

## 🌍 Cloud Adapter Examples

### AWS Example (Uncommment in `providers.tf`)

```hcl
provider "aws" {
  region = var.cloud_region
  default_tags {
    tags = local.common_tags
  }
}

resource "aws_vpc" "platform" {
  cidr_block = var.network_cidr
  tags       = local.common_tags
}

resource "aws_ec2_instance" "app" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.small"
  
  tags = merge(
    local.common_tags,
    { Name = "devops-app" }
  )
}
```

### Kubernetes Adapter (Future)

```hcl
provider "kubernetes" {
  config_path = var.kube_config_path
}

resource "kubernetes_deployment" "app" {
  metadata {
    name = var.project_name
  }
  # ... spec ...
}
```

## 🧪 Testing the Contract

### Validation Checklist

```bash
# 1. Format
tofu fmt -check -recursive .

# 2. Validate
tofu init && tofu validate

# 3. Checkov
checkov -d . --framework terraform

# 4. Plan
tofu plan -var-file="terraform.tfvars.example"

# 5. Verify outputs
tofu show tfplan | grep "infrastructure_contract_summary"
```

### Integration Test (with Docker Compose)

The platform should be able to use outputs from `tofu show` to configure Compose deployments:

```bash
# Generate outputs as JSON
tofu show -json tfplan > /tmp/iac_outputs.json

# Use in Compose adapter (future)
# python3 platform/compose/generate_compose.py /tmp/iac_outputs.json
```

## 📚 Documentation

- **Architecture**: `docs/Architecture.md`
- **Network Design**: `docs/Network.md`
- **Security Requirements**: `docs/Security.md`
- **Observability Contract**: `docs/Observability.md`
- **Detailed Planning**: `docs/Plan-detail.md`

## 🔧 Troubleshooting

### Error: `Could not load plugin`

```bash
# Ensure OpenTofu is installed
tofu version

# Reinstall if needed
brew reinstall opentofu
```

### Error: `Invalid or unsupported provider configuration`

The provider blocks are commented out. Uncomment and configure only one for your environment.

### Error: `Checkov not found`

```bash
# Install Checkov
pip install checkov

# Or via Homebrew
brew install checkov
```

### Error: `Conftest not found`

```bash
# Install Conftest
brew install conftest

# Or via binary
curl -LO https://github.com/open-policy-agent/conftest/releases/download/v0.50.0/conftest_linux_amd64.tar.gz
```

## 📋 Checklist for Deployment

Before applying any changes:

- [ ] All format checks pass: `tofu fmt -check -recursive .`
- [ ] Validation succeeds: `tofu validate`
- [ ] Checkov findings reviewed: `checkov -d .`
- [ ] OPA policies pass: `conftest test -p conftest/`
- [ ] Plan reviewed by team: `tofu plan -out=tfplan`
- [ ] Approval ticket created and referenced
- [ ] Git commit SHA recorded for audit trail
- [ ] State file backed up (if applying)
- [ ] Rollback plan prepared
- [ ] Monitoring alerts configured

## 📞 Support & Escalation

- **Questions about variables?** See `variables.tf` — all have detailed descriptions
- **Security findings?** Review `conftest/policy.rego` and `checkov.yaml`
- **Need to add a new resource type?** Document in `main.tf` using `null_resource` as example
- **Cloud-specific issue?** Create a new provider-specific module in `aws/`, `gcp/`, `azure/`

## 🎯 Next Steps

1. **Configure for your cloud provider**
   - Uncomment provider block in `providers.tf`
   - Update `variables.tf` with provider-specific variables
   - Create cloud-specific resources

2. **Set up Vault for secrets**
   - `export VAULT_ADDR=http://127.0.0.1:8200`
   - Create Vault policies for Terraform access
   - Test with `vault login`

3. **Integrate with CI/CD**
   - GitHub Actions workflow already set up
   - Configure approval gates for production
   - Set up Slack/email notifications

4. **Monitor and audit**
   - Track all applies in `evidence/iac_metadata.json`
   - Review Checkov findings regularly
   - Rotate credentials per `docs/Security.md`

---

**Last Updated**: 2026-08-09  
**Maintained by**: Platform Team  
**License**: Internal Use Only
