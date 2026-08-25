# Workload role: the scheduled rotation check.
#
# WHY THIS POLICY EXISTS AT ALL.
#
# The `rotation` scheduler job had been red for days with
# `check_rotation_due.sh: line 19: 1: Usage: ...` -- jobs.conf invoked it with
# no <path> argument. Fixing the argument alone would not have made it work:
# the script needs a Vault token and launchd hands a process almost no
# environment, so it had TWO independent breakages and would have failed on
# every run since it was added.
#
# The wrong fix is to leave a long-lived privileged token on disk for launchd.
# This policy is the right shape instead.
#
# METADATA ONLY -- NEVER `secret/data/*`.
#
# Rotation age lives in KV v2 custom_metadata (`rotated_at`), which is a
# DIFFERENT path from the secret value. So the check can do its whole job
# while being structurally incapable of reading a single secret: there is no
# grant here that `vault kv get` could use.
#
# What this credential does leak, stated plainly rather than glossed: the set
# of secret paths that exist, and when each was last rotated. That is the
# inventory, not the contents. A scheduled job that reports "3 secrets are
# overdue" has to know the paths to name them.

# List folders, to walk the tree. KV v2 puts listing under metadata/.
path "secret/metadata" {
  capabilities = ["list"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}

# Deliberately absent, and the absence is the point:
#   secret/data/*   -- would make this a secret-reading credential
#   sys/*           -- no administration
#   auth/*          -- cannot mint or escalate
