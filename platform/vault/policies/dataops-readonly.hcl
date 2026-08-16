# Least-privilege policy for a future DataOps/MLOps pipeline (running in a
# separate repo, per docs/Future-DataOps.md's platform-as-a-service decision)
# that needs to READ secrets under secret/dataops/* but must never write,
# delete, list other paths, or perform any admin operation. Mirrors
# platform/vault/policies/devops-readonly.hcl exactly -- same pattern, new
# namespace, so a future DataOps repo gets the identical least-privilege
# guarantee this platform already proved for secret/devops/*.
#
# Verified (see platform/vault/README.md "DataOps Namespace"): a token under
# this policy can read secret/dataops/* but is denied listing secret
# engines, listing policies, and reading secret/devops/* with a permission
# error, not a silent empty response.

path "secret/data/dataops/*" {
  capabilities = ["read"]
}

path "secret/metadata/dataops/*" {
  capabilities = ["read", "list"]
}
