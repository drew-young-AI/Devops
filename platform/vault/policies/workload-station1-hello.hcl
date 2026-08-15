# Workload role: the station1-hello pilot service.
#
# station1-hello is stateless and has no secrets today. This policy exists
# anyway, granting only its own namespace, because the mechanism being
# proven is "every workload gets an identity scoped to its own secrets" --
# and a mechanism with zero instances is a design document, not a mechanism.
# When the first pilot secret appears it lands here with no policy change.
#
# ---------------------------------------------------------------------
# DYNAMIC SECRETS SEAM -- intentionally kept, intentionally not enabled.
#
# The platform currently uses long-lived static credentials (a decision, not
# an oversight: there is no database to issue dynamic credentials against
# yet). The migration to dynamic, short-lived credentials must not require
# redesigning identity, so the shape is reserved here:
#
#   path "database/creds/station1-hello" {
#     capabilities = ["read"]
#   }
#
# Reading that path makes Vault mint a brand-new database username/password
# with a TTL, valid only for this workload, revoked automatically on expiry.
# Note what does NOT change when that day comes: the AppRole, the workload's
# identity, how it authenticates, and who administers it. Only the path it
# is allowed to read changes -- static `secret/data/...` becomes dynamic
# `database/creds/...`. That is the whole reason to build identity first and
# credentials second: identity is the expensive thing to retrofit.
# ---------------------------------------------------------------------

path "secret/data/pilots/station1-hello/*" {
  capabilities = ["read"]
}

path "secret/metadata/pilots/station1-hello/*" {
  capabilities = ["read", "list"]
}
