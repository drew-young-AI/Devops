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
