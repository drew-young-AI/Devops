# Least-privilege policy for platform automation (CI, deploy scripts) that
# needs to READ secrets under secret/devops/* but must never be able to
# write, delete, list other paths, or perform any admin operation (create
# policies, manage auth methods, seal/unseal, etc.).
#
# Verified (see platform/vault/README.md "Verified End-to-End"): a token
# under this policy can read secret/devops/github but is denied listing
# secret engines, listing policies, and reading sys/health with a
# permission error, not a silent empty response.

path "secret/data/devops/*" {
  capabilities = ["read"]
}

path "secret/metadata/devops/*" {
  capabilities = ["read", "list"]
}
