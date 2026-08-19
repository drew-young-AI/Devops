# A named TEST FIXTURE, not a service.
#
# This replaces workload-station1-hello.hcl, deleted with its pilot on
# 2026-08-19. That policy was doing two jobs: it was station1-hello's real
# identity, and it was the only thing proving the per-pilot kv isolation rule
# ("every workload gets an identity scoped to its own secrets, and cannot read
# another's"). Retiring the pilot would have taken four assertions in
# verify_identity.sh with it.
#
# Rather than re-point those assertions at station2-twin -- whose real policy
# grants no secret/ access at all, because it uses dynamic database
# credentials -- the fixture is separated from the service and named as such.
# The rule under test is a property of the PLATFORM and has to keep being
# provable whether or not any current pilot happens to store a static secret.
#
# Nothing runs as this identity. If you find it holding a live credential,
# that is the bug.
#
# The dynamic-secrets seam this file used to reserve is no longer a seam:
# station2-twin reads database/creds/station2-twin for real, and
# platform/vault/scripts/setup_database_secrets.sh writes that policy.

path "secret/data/pilots/pilot-fixture/*" {
  capabilities = ["read"]
}

path "secret/metadata/pilots/pilot-fixture/*" {
  capabilities = ["read", "list"]
}
