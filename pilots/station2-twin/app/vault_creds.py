"""Fetch short-lived database credentials from Vault at runtime.

The application no longer holds a database password. It holds an AppRole
identity, exchanges that for a Vault token, and asks Vault for a credential
that expires.

WHY THIS IS NOT JUST "THE PASSWORD COMES FROM SOMEWHERE ELSE".

A static password in an environment variable has three properties that make
incidents worse: it is shared (so revoking it stops everything at once), it
is permanent (so a leak from a year ago still works), and it is anonymous (so
a query in the audit log cannot be attributed to a caller). A dynamic
credential inverts all three -- each process gets its own user, it expires,
and the username in `pg_stat_activity` names the lease that issued it.

FAILURE BEHAVIOUR IS THE DESIGN.

Vault being unavailable must not look like the database being unavailable,
and neither must look like "everything is fine". So:

  - startup with Vault unreachable  -> readiness reports it, service stays up
  - credential rejected mid-life    -> refetch once, then surface the error
  - no AppRole configured at all    -> fall back to the static password and
                                       SAY SO, rather than silently doing
                                       something different from what the
                                       operator thinks is happening

CREDENTIAL EXPIRY -- AND THE MITIGATION THAT DID NOT WORK.

This module previously claimed:

    "NOT IMPLEMENTED, ON PURPOSE: continuous lease renewal. The connection
     pool's max_lifetime is set shorter than the credential TTL, so
     connections are recycled and a fresh credential is fetched before the
     old one expires."

The first half was a real decision. The second half was false, and it was
false in the way that is hardest to notice: psycopg_pool's ConnectionPool
takes its connection string as a STRING, evaluated once at construction.
max_lifetime does recycle connections -- and every reconnection dials with the
same, now-expired username and password. Nothing ever fetched a fresh
credential.

Observed, not theorised: one hour and one minute after start, the pilot went
to `db_unreachable: PoolTimeout` and stayed there. /health/live stayed green
throughout, because the process was perfectly healthy; it simply could no
longer log in. Docker therefore never restarted it, which is correct
behaviour for liveness and exactly why the failure could persist for five
hours before a metric caught it.

This is the third time on this platform that a written-down mitigation turned
out to do nothing while reading as correct. The pattern is worth naming: a
comment describing a mechanism is not evidence the mechanism exists.

WHAT IS IMPLEMENTED NOW: the pool is rebuilt when the credential is inside a
margin of expiry (see app.py's pool()). Still not a renewal loop -- the lease
is allowed to expire and a new one is issued, which keeps credentials
genuinely short-lived instead of holding one open indefinitely.
"""
import json
import os
import time
import urllib.error
import urllib.request

VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://host.docker.internal:18200")
VAULT_ROLE_ID = os.environ.get("VAULT_ROLE_ID", "")
VAULT_SECRET_ID = os.environ.get("VAULT_SECRET_ID", "")
VAULT_DB_ROLE = os.environ.get("VAULT_DB_ROLE", "station2-twin")
VAULT_TIMEOUT = float(os.environ.get("VAULT_TIMEOUT", "5"))


class VaultUnavailable(RuntimeError):
    """Vault could not issue a credential. Distinct from the DB being down."""


def enabled():
    return bool(VAULT_ROLE_ID and VAULT_SECRET_ID)


def _post(path, payload, token=None):
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Content-Type": "application/json",
                 **({"X-Vault-Token": token} if token else {})},
        method="POST" if payload is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=VAULT_TIMEOUT) as r:
        return json.loads(r.read())


def _get(path, token):
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/{path}", headers={"X-Vault-Token": token})
    with urllib.request.urlopen(req, timeout=VAULT_TIMEOUT) as r:
        return json.loads(r.read())


# Vault's HTTP codes carry the diagnosis; collapsing them into one message
# throws it away. This mapping exists because the first version reported EVERY
# login failure as "secret_id may be expired or revoked", and on 2026-08-19 a
# Docker Desktop restart brought Vault back SEALED -- which answers login with
# 503. The credential was fine. The message sent the reader to rotate a secret
# that did not need rotating, while the actual fix was one `operator unseal`.
#
# Same defect shape as the CI smoke test reporting "graceful drain window is
# not working" for a container that never had an HTTP endpoint: the failure is
# real, the stated cause is fiction, and fiction costs more than silence.
_LOGIN_FAILURE = {
    400: "AppRole login rejected (HTTP 400) -- malformed request; role_id or "
         "secret_id is empty or not a valid UUID",
    403: "AppRole login rejected (HTTP 403) -- secret_id is expired, revoked, "
         "or past its use limit. This one really is a credential problem",
    500: "Vault internal error (HTTP 500) -- check the Vault server log; not a "
         "credential problem",
    501: "Vault is NOT INITIALIZED (HTTP 501) -- run init_and_unseal.sh. No "
         "credential exists yet",
    503: "Vault is SEALED (HTTP 503) -- run platform/vault/scripts/"
         "init_and_unseal.sh. The credential is fine; Vault cannot decrypt its "
         "own storage until it is unsealed. Expected after any restart, "
         "because this deployment has no auto-unseal",
}


def _login_failure(code):
    return _LOGIN_FAILURE.get(
        code, f"AppRole login rejected (HTTP {code}) -- unmapped Vault status; "
              f"read the Vault server log before assuming a credential fault")


def fetch_credentials():
    """Returns (username, password, lease_id, ttl_seconds).

    Raises VaultUnavailable with a reason that distinguishes the failure
    modes -- "wrong secret_id" and "Vault is down" need different responses
    from whoever reads the log.
    """
    if not enabled():
        raise VaultUnavailable("no AppRole configured")

    try:
        auth = _post("auth/approle/login",
                     {"role_id": VAULT_ROLE_ID, "secret_id": VAULT_SECRET_ID})
    except urllib.error.HTTPError as exc:
        raise VaultUnavailable(_login_failure(exc.code)) from exc
    except (urllib.error.URLError, OSError) as exc:
        raise VaultUnavailable(f"Vault unreachable at {VAULT_ADDR}: {exc}") from exc

    token = auth["auth"]["client_token"]

    try:
        creds = _get(f"database/creds/{VAULT_DB_ROLE}", token)
    except urllib.error.HTTPError as exc:
        if exc.code in (501, 503):
            raise VaultUnavailable(_login_failure(exc.code)) from exc
        raise VaultUnavailable(
            f"credential request denied (HTTP {exc.code}) -- the token is "
            f"valid but the policy may not grant database/creds/"
            f"{VAULT_DB_ROLE}, or postgres rejected the CREATE ROLE") from exc
    except (urllib.error.URLError, OSError) as exc:
        raise VaultUnavailable(f"Vault unreachable: {exc}") from exc

    return (creds["data"]["username"], creds["data"]["password"],
            creds.get("lease_id", ""), creds.get("lease_duration", 0))


class CredentialSource:
    """Holds the current credential and knows how to replace it."""

    def __init__(self):
        self.username = None
        self.lease_id = None
        self.issued_at = None
        self.ttl = None
        self.mode = "static" if not enabled() else "vault"
        self.last_error = None

    def dsn(self, host, port, dbname, static_user, static_password):
        if not enabled():
            self.mode = "static"
            self.username = static_user
            return (f"host={host} port={port} dbname={dbname} "
                    f"user={static_user} password={static_password}")

        user, password, lease, ttl = fetch_credentials()
        self.mode = "vault"
        self.username = user
        self.lease_id = lease
        self.ttl = ttl
        self.issued_at = time.time()
        self.last_error = None
        return (f"host={host} port={port} dbname={dbname} "
                f"user={user} password={password}")

    def expires_within(self, margin_seconds):
        """True when the credential is inside `margin` of expiry, or already gone.

        Static credentials never expire, so this is always False for them --
        which is the whole difference between the two modes and the reason the
        caller does not need to branch on mode itself.
        """
        if self.mode != "vault" or not self.issued_at or not self.ttl:
            return False
        return (time.time() - self.issued_at) >= (self.ttl - margin_seconds)

    def status(self):
        """Reported by /health/ready and /version, so an operator can tell
        which credential the running process is actually using -- the single
        most common source of 'but I rotated it' confusion."""
        out = {"mode": self.mode, "username": self.username}
        if self.mode == "vault" and self.issued_at:
            age = int(time.time() - self.issued_at)
            out.update(lease_id=self.lease_id, ttl_seconds=self.ttl,
                       age_seconds=age,
                       expires_in=max(0, (self.ttl or 0) - age))
        if self.last_error:
            out["last_error"] = self.last_error
        return out
