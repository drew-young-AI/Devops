import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class Station1ContractTests(unittest.TestCase):
    def test_required_files_exist(self):
        for name in ("app.py", "Dockerfile", "compose.yaml", ".dockerignore"):
            self.assertTrue((ROOT / name).is_file(), name)

    def test_app_declares_required_endpoints(self):
        source = (ROOT / "app.py").read_text()
        for endpoint in ("/health/live", "/health/ready", "/version", "/metrics"):
            self.assertIn(endpoint, source)

    def test_compose_has_minimum_security_limits(self):
        source = (ROOT / "compose.yaml").read_text()
        for setting in ("read_only: true", "no-new-privileges:true", "cap_drop:", "mem_limit:", "cpus:"):
            self.assertIn(setting, source)


if __name__ == "__main__":
    unittest.main()
