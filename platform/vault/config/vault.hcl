# HashiCorp Vault Community server configuration — local, file-backed storage.
#
# Deliberately NOT "vault server -dev": dev mode is in-memory (data lost on
# restart), auto-unsealed, and runs with a fixed known root token — none of
# that validates the real init/unseal/policy pattern this platform needs to
# prove out (see docs/IaC.md "Secret：HashiCorp Vault Community；.env 只作
# migration source"). File storage + real init/unseal is the closest local
# equivalent to how a real deployment behaves, without needing a cloud KMS
# auto-unseal mechanism (out of scope until there's an actual cloud adapter).

storage "file" {
  # /vault/file (not /vault/data) matches the official image's own
  # convention — its docker-entrypoint.sh auto-chowns exactly this path
  # (along with /vault/config and /vault/logs) to the vault user when the
  # container starts as root and self-demotes via su-exec. Picking a
  # different path would leave it root-owned and unwritable by the vault
  # process — verified locally (this exact failure mode, reproduced with
  # /vault/data before switching to /vault/file).
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
  # TLS is intentionally off at Vault's own listener: it is published only
  # to 127.0.0.1 (see compose.yaml) and never reached from outside this
  # Mac, the same posture already used for Prometheus/Loki/Grafana in
  # platform/observability/. If Vault ever needs to be reachable through
  # the NGINX adapter, terminate TLS there instead of duplicating certs.
}

api_addr     = "http://127.0.0.1:8200"
ui           = true
disable_mlock = true
# disable_mlock: mlock (preventing secrets from being swapped to disk) isn't
# available in the container's default seccomp/capability profile without
# granting IPC_LOCK, which would widen this container's capability set
# beyond what platform/nginx/ and pilots/station1-hello/ already establish
# as the norm (cap_drop: ALL). Acceptable for local development; a real
# deployment on dedicated infrastructure should grant IPC_LOCK instead.
