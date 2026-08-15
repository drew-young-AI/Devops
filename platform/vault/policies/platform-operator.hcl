# Human role: platform operator.
#
# Can read the secrets needed to run deployments, and nothing else. The
# deliberate exclusions are the point of the role: no policy writes, no auth
# method changes, no new secret engines. An operator who can edit policies
# is not an operator, they are an admin with extra steps.

path "secret/data/devops/*" {
  capabilities = ["read"]
}

path "secret/metadata/devops/*" {
  capabilities = ["read", "list"]
}

# Pilot secrets follow secret/<pilot-name>/* per platform/vault/README.md's
# "Known Gaps". Operators need them to deploy; the wildcard is scoped to
# that convention rather than granting secret/* outright.
path "secret/data/pilots/*" {
  capabilities = ["read"]
}

path "secret/metadata/pilots/*" {
  capabilities = ["read", "list"]
}

# Read-only visibility into what exists, so an operator can diagnose without
# being able to change the shape of the system.
path "sys/mounts" {
  capabilities = ["read"]
}
