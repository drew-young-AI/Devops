# Workload role: the CI/build pipeline.
#
# The narrowest policy in the platform, on purpose: CI runs untrusted-ish
# code (whatever is in the commit being built) with a credential attached.
# It gets exactly the one secret it needs to push an image, and nothing
# else -- notably NOT secret/devops/github, the git PAT, which a build has
# no reason to hold.
#
# This is why platform/vault/README.md keeps the two GitHub credentials at
# separate paths instead of reusing one token: separate paths are what makes
# separate grants possible. A single shared credential would have forced
# this policy to grant everything that credential can do.

path "secret/data/devops/ghcr" {
  capabilities = ["read"]
}

path "secret/metadata/devops/ghcr" {
  capabilities = ["read"]
}
