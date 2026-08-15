#!/usr/bin/env python3
"""Fixture-driven stub HTTP server for the platform test suite.

Exists so failure paths can be tested deterministically and without the real
services: a CI runner has no Prometheus, no Alertmanager and no MLX
endpoint, and conditions like "Prometheus is up but has zero alert rules
loaded" cannot be produced on demand against a real Prometheus at all.

Usage: stub_http.py <port> <fixture.json>

The fixture maps request paths to responses:
  {"/api/v1/rules": {"status": 200, "body": {...}},
   "/v1/chat/completions": {"status": 200, "body": {...}}}
Unlisted paths return 404. A path may also be set to {"status": 500} with no
body to simulate a broken service that is still listening.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

with open(sys.argv[2], encoding="utf-8") as handle:
    FIXTURE = json.load(handle)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep test output readable

    def _respond(self):
        path = self.path.split("?")[0]
        spec = FIXTURE.get(path)
        if spec is None:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(spec.get("body", {})).encode("utf-8")
        self.send_response(spec.get("status", 200))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._respond()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)
        self._respond()


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
