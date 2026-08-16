# Human role: platform viewer -- metadata only, NEVER secret values.
#
# This role exists to make one distinction real: "can see that a secret
# exists, when it was last rotated, and how many versions it has" is a
# completely different privilege from "can read the secret".
#
# KV v2 makes this enforceable because it splits the two into separate API
# paths: secret/metadata/* holds names, versions, timestamps and custom
# metadata, while secret/data/* holds the actual values. Granting the first
# and withholding the second is not a convention or a UI setting -- it is
# two different paths with two different capabilities, checked by Vault.
#
# This is the "資料擁有者可以查詢，但不能取用" tier: an auditor, a data
# owner, or a manager checking rotation compliance can answer "is this
# credential overdue for rotation?" (see scripts/check_rotation_due.sh)
# without ever being able to read the credential itself.

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

# Explicitly denied rather than merely unlisted. Vault defaults to deny, so
# this is redundant for enforcement -- it is here because an explicit deny
# survives someone later adding a broader grant above it (deny always wins
# in Vault's policy evaluation), and because it documents the intent to the
# next person editing this file.
path "secret/data/*" {
  capabilities = ["deny"]
}
