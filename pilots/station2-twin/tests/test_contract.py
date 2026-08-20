"""Contract tests for station2-twin.

Static-only on purpose: these run in CI with no database. The behavioural
proofs (readiness under DB loss, schema mismatch, migration refusals,
restore) are exercised against a live stack and recorded in README.md.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).parents[1]
REPO = ROOT.parents[1]


class Station2ContractTests(unittest.TestCase):
    def test_required_files_exist(self):
        for name in ("Dockerfile", "compose.yaml", ".dockerignore",
                     "config.example.env", "README.md", "app/app.py"):
            self.assertTrue((ROOT / name).is_file(), name)

    def test_app_declares_required_endpoints(self):
        source = (ROOT / "app" / "app.py").read_text()
        for endpoint in ("/health/live", "/health/ready", "/version", "/metrics"):
            self.assertIn(endpoint, source)

    def test_compose_has_minimum_security_limits(self):
        source = (ROOT / "compose.yaml").read_text()
        for setting in ("read_only: true", "no-new-privileges:true",
                        "cap_drop:", "mem_limit:", "cpus:", "pids_limit:"):
            self.assertIn(setting, source)

    def test_liveness_probe_does_not_depend_on_the_database(self):
        """Docker restarts a container whose healthcheck fails.

        Wiring the healthcheck to /health/ready would restart every replica
        whenever the database blips -- a condition restarting cannot fix --
        turning a recoverable dependency failure into a full outage.
        """
        compose = (ROOT / "compose.yaml").read_text()
        # Strip comments first. The original version of this assertion matched
        # the word "health/ready" inside the comment that explains why it is
        # NOT used -- so documenting the decision failed the test that checks
        # the decision. Assert on the directives, not on the prose.
        directives = "\n".join(l for l in compose.splitlines()
                               if not l.strip().startswith("#"))
        healthcheck = directives[directives.index("  twin:"):].split("healthcheck:")[1]
        self.assertIn("/health/live", healthcheck)
        self.assertNotIn("health/ready", healthcheck)

    def test_readiness_distinguishes_its_failure_modes(self):
        """"Not ready" is useless on its own; the cause drives the response."""
        source = (ROOT / "app" / "app.py").read_text()
        for state in ("db_unreachable", "schema_missing", "schema_mismatch", "draining"):
            self.assertIn(state, source)

    def test_expected_schema_version_matches_highest_migration(self):
        """Code and schema must move together.

        If this drifts, every deploy comes up permanently un-ready -- which is
        safe, but only fails at deploy time. Catching it here is cheaper.
        """
        versions = []
        for f in (ROOT / "migrations").glob("[0-9]*.sql"):
            m = re.match(r"^0*(\d+)_", f.name)
            self.assertIsNotNone(m, f"{f.name} has no numeric version prefix")
            versions.append(int(m.group(1)))
        self.assertTrue(versions, "no migrations found")
        highest = max(versions)

        env = (ROOT / "config.example.env").read_text()
        declared = int(re.search(r"EXPECTED_SCHEMA_VERSION=(\d+)", env).group(1))
        self.assertEqual(highest, declared,
                         "config.example.env disagrees with the migrations on disk")

        app_default = int(re.search(
            r'EXPECTED_SCHEMA_VERSION["\']?,\s*["\'](\d+)["\']',
            (ROOT / "app" / "app.py").read_text()).group(1))
        self.assertEqual(highest, app_default,
                         "app.py's default schema version disagrees with the migrations")

        # compose.yaml too. This assertion was missing, and the omission bit
        # immediately: migration 003 landed, app.py's default was bumped to 3,
        # and the service still came up refusing traffic because
        # `${EXPECTED_SCHEMA_VERSION:-2}` in compose overrides the app default.
        # The version lives in three files; a test that checks two of them
        # certifies a consistency that does not exist.
        compose_default = int(re.search(
            r"EXPECTED_SCHEMA_VERSION:\s*\$\{EXPECTED_SCHEMA_VERSION:-(\d+)\}",
            (ROOT / "compose.yaml").read_text()).group(1))
        self.assertEqual(highest, compose_default,
                         "compose.yaml's default overrides app.py and disagrees "
                         "with the migrations")

    def test_migration_versions_are_unique_and_gapless(self):
        """A duplicate version silently skips a migration: the ledger is keyed
        on version, so the second file with the same number is recorded as
        already applied and never runs."""
        versions = sorted(int(re.match(r"^0*(\d+)_", f.name).group(1))
                          for f in (ROOT / "migrations").glob("[0-9]*.sql"))
        self.assertEqual(len(versions), len(set(versions)), f"duplicate versions: {versions}")
        self.assertEqual(versions, list(range(1, len(versions) + 1)),
                         f"versions must start at 1 with no gaps: {versions}")

    def test_no_sql_string_interpolation(self):
        """Every query must be parameterised.

        asset_id comes off the URL path and metric out of a JSON body -- both
        attacker-controlled, and both are what DAST probes first.
        """
        source = (ROOT / "app" / "app.py").read_text()
        for bad in ('f"SELECT', "f'SELECT", 'f"INSERT', "f'INSERT",
                    '" + asset', "' + asset", '% (asset'):
            self.assertNotIn(bad, source, f"looks like string-built SQL: {bad}")

    def test_stateful_volume_is_covered_by_backup(self):
        """This pilot's whole point is that it holds state.

        The volume was covered by nothing when it was first created, and the
        backup still reported success -- a hand-maintained list cannot report
        what is missing from it.
        """
        backup = (REPO / "platform" / "backup" / "backup.sh").read_text()
        compose = (ROOT / "compose.yaml").read_text()
        volume = re.search(r"name:\s*(station2-twin-db)", compose).group(1)
        self.assertIn(volume, backup,
                      f"{volume} appears in no list in backup.sh")

    def test_no_secret_material_committed(self):
        example = (ROOT / "config.example.env").read_text()
        self.assertRegex(example, r"PGPASSWORD=\s*$|PGPASSWORD=\n",
                         "config.example.env must ship an empty password")
        self.assertFalse((ROOT / ".env").exists(), ".env must never be committed")


if __name__ == "__main__":
    unittest.main()


class CredentialLifecycleTests(unittest.TestCase):
    """The pool must not outlive the credential it was built with.

    psycopg_pool's ConnectionPool takes its connection string as a STRING,
    fixed at construction. The original design relied on max_lifetime to
    "fetch a fresh credential", which it cannot do -- every reconnection
    redialled with the same expired username. The service went permanently
    unready one hour after start while /health/live stayed green, so nothing
    restarted it.

    These assertions are static because the behavioural proof needs a live
    Vault (recorded in README.md); what they defend against is someone
    deleting the rebuild and leaving the comment.
    """

    def test_pool_consults_credential_expiry(self):
        source = (ROOT / "app" / "app.py").read_text()
        self.assertIn("expires_within", source,
                      "pool() must check whether the credential is near expiry")
        self.assertIn("CRED_REFRESH_MARGIN", source)

    def test_refresh_margin_is_configurable_through_compose(self):
        """A value the process reads but compose never passes is not
        configurable -- it is a constant with a misleading name. This exact
        gap made the first attempt to test the refresh silently do nothing."""
        compose = (ROOT / "compose.yaml").read_text()
        self.assertIn("CRED_REFRESH_MARGIN:", compose)

    def test_credential_source_reports_expiry_to_operators(self):
        source = (ROOT / "app" / "vault_creds.py").read_text()
        for field in ("expires_in", "ttl_seconds", "age_seconds"):
            self.assertIn(field, source,
                          "an operator must be able to see how long the live "
                          "credential has left")


class CredentialRevokedEarlyTests(unittest.TestCase):
    """A credential can die before its advertised TTL, and did.

    2026-08-20: the pilot's Vault credential was rejected by postgres with
    `password authentication failed` 29 minutes after issue, while advertising
    3600 seconds of remaining life. The role had been dropped.

    THE ADVERTISED TTL WAS THE WRONG NUMBER. The database lease is a CHILD of
    the AppRole token (token_ttl=20m), and Vault revokes child leases when the
    parent dies. Effective lifetime is min(credential TTL, token TTL) = 1200s,
    not the 3600s the credential reports. The refresh margin was scheduled
    against 3600 and would not have fired for another 26 minutes.

    A CORRECT PREDICTION IS STILL ONLY A PREDICTION. An operator revoking a
    lease, `vault lease revoke -prefix`, or a Vault restart all end a credential
    early and none of them announce it. So the pool also reacts to postgres
    actually refusing the credential.

    Proved behaviourally against live Vault: revoking the lease mid-flight gave
    `credential_rejected` on the next probe and `ready` with a DIFFERENT
    username on the one after. These static assertions defend against someone
    deleting that and leaving the comment -- which is the failure mode this
    platform keeps hitting.
    """

    @classmethod
    def setUpClass(cls):
        root = pathlib.Path(__file__).resolve().parents[1]
        cls.app = (root / "app" / "app.py").read_text()
        cls.vault = (root / "app" / "vault_creds.py").read_text()

    def test_effective_ttl_is_the_minimum_of_credential_and_token(self):
        self.assertIn("min(ttls)", self.vault,
                      "vault_creds must take the SMALLER of the credential TTL "
                      "and the parent token TTL; scheduling against the "
                      "credential's own 3600s is what let it die at 20 minutes")
        self.assertIn("token_ttl", self.vault,
                      "the parent token TTL must be read from the auth response")

    def test_zero_ttl_is_treated_as_unknown_not_as_instant_expiry(self):
        self.assertIn("if t > 0", self.vault,
                      "a missing TTL must be excluded from the minimum, not "
                      "taken as 0 -- that would mark every credential as "
                      "already expired and rebuild the pool on every request")

    def test_pool_reacts_to_an_authentication_failure(self):
        self.assertIn("_pool_is_condemned", self.app,
                      "the pool must be rebuildable on an auth failure, not "
                      "only on predicted expiry")
        self.assertIn("password authentication failed", self.app,
                      "the postgres auth-failure text is the authoritative "
                      "signal that a credential is dead")

    def test_a_network_blip_does_not_throw_away_the_credential(self):
        """Rebuilding on ANY OperationalError is a credential-churn loop.

        psycopg raises OperationalError for both "wrong password" and "host is
        down". Only the first should discard the lease; treating a brief
        outage as a dead credential fetches a new Vault lease on every blip.
        """
        self.assertIn("_AUTH_FAILURE_MARKERS", self.app,
                      "auth failures must be matched specifically, not by "
                      "catching every OperationalError")

    def test_a_rejected_credential_is_not_reported_as_db_unreachable(self):
        self.assertIn("credential_rejected", self.app,
                      "a refused credential must not be reported as "
                      "db_unreachable -- that sends the reader to a healthy "
                      "database with an outage runbook")
