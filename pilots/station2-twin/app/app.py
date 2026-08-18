#!/usr/local/bin/python
"""station2-twin -- the digital twin query/API layer.

Pilot 2 exists to break assumptions Pilot 1 could not. station1-hello is
stateless: it holds nothing, so backup, restore, migration and credential
rotation were all untestable against it. This service has a database, and
therefore has the problems a database brings.

THE READINESS CONTRACT IS THE POINT.

  /health/live   the process is running. Failing means "restart me".
  /health/ready  this instance can correctly serve traffic. Failing means
                 "route around me" -- and must NOT trigger a restart.

Conflating them is the classic stateful-service outage: a DB blip fails the
liveness probe, the orchestrator restarts every replica at once, and a
recoverable dependency failure becomes a full outage with cold caches.

So readiness here fails on two distinct conditions, and says which:

  1. the database is unreachable
  2. the database schema is not the version this code was written for

Condition 2 is the one people leave out. During a blue/green switch the two
colours can be running different code against ONE shared database. If green
expects schema v3 and the database is still at v2, green will start, pass a
naive "SELECT 1" health check, and then fail on real queries -- after taking
production traffic. Refusing readiness on a version mismatch turns that into
a deploy that never receives traffic, which is a non-event instead of an
incident.
"""
import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import psycopg
from psycopg_pool import ConnectionPool

import surveillance
import vault_creds

PORT = int(os.environ.get("PORT", "8080"))
APP_VERSION = os.environ.get("APP_VERSION", "dev")

# The schema this build was written against. Bumped in the same commit as the
# migration that introduces it, so code and schema move together or not at all.
EXPECTED_SCHEMA_VERSION = int(os.environ.get("EXPECTED_SCHEMA_VERSION", "5"))

DEFAULT_DISEASE = os.environ.get("DEFAULT_DISEASE", "influenza_like_illness")

GRACEFUL_DRAIN_SECONDS = float(os.environ.get("GRACEFUL_DRAIN_SECONDS", "3"))

started_at = time.time()
shutting_down = False
request_count = 0
error_count = 0
db_error_count = 0

# A pool, not a connection per request. Dynamic credentials from Vault have a
# TTL, so connections are recycled deliberately: max_lifetime keeps a
# long-lived pool from holding a connection opened with a credential that has
# since been revoked.
_pool = None


CREDENTIALS = vault_creds.CredentialSource()


def dsn():
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    # Vault when an AppRole is configured, the static password otherwise.
    # The fallback is explicit rather than implicit: an operator who thinks
    # the service is using dynamic credentials and is wrong has no way to
    # notice, so /health/ready and /version both report which mode is live.
    return CREDENTIALS.dsn(
        host=os.environ.get("PGHOST", "db"),
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "twin"),
        static_user=os.environ.get("PGUSER", "twin"),
        static_password=os.environ.get("PGPASSWORD", ""),
    )


def pool():
    global _pool
    if _pool is None:
        _pool = ConnectionPool(
            dsn(),
            min_size=1,
            max_size=int(os.environ.get("DB_POOL_MAX", "5")),
            max_lifetime=float(os.environ.get("DB_CONN_MAX_LIFETIME", "1800")),
            timeout=float(os.environ.get("DB_POOL_TIMEOUT", "3")),
            open=False,
        )
        _pool.open()
    return _pool


def log(event, **fields):
    print(json.dumps({"event": event, "ts": time.time(), **fields}), flush=True)


def schema_version():
    """Highest applied migration, or None if the table is absent/unreadable."""
    with pool().connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT to_regclass('public.schema_migrations') IS NOT NULL
            """)
            if not cur.fetchone()[0]:
                return None
            cur.execute("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
            return cur.fetchone()[0]


def readiness():
    """(ok, payload). Distinguishes the failure modes rather than merging them."""
    if shutting_down:
        return False, {"status": "draining"}
    try:
        version = schema_version()
    except vault_creds.VaultUnavailable as exc:
        # Distinct from db_unreachable on purpose: the database may be
        # perfectly healthy and simply unreachable BY US because no valid
        # credential could be obtained. Merging the two sends whoever is
        # paged to the wrong system.
        CREDENTIALS.last_error = str(exc)
        return False, {"status": "credentials_unavailable", "detail": str(exc)}
    except Exception as exc:
        return False, {"status": "db_unreachable", "detail": type(exc).__name__}
    if version is None:
        return False, {"status": "schema_missing",
                       "detail": "schema_migrations table absent -- migrations never ran"}
    if version != EXPECTED_SCHEMA_VERSION:
        return False, {"status": "schema_mismatch",
                       "expected": EXPECTED_SCHEMA_VERSION, "actual": version}
    return True, {"status": "ready", "schema_version": version,
                  "credentials": CREDENTIALS.status()}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log("http_request", message=fmt % args, correlation_id=self._cid())

    def _cid(self):
        return self.headers.get("X-Correlation-Id") or f"gen-{int(time.time()*1000)}"

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Correlation-Id", self._cid())
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global request_count, error_count, db_error_count
        request_count += 1
        parsed = urlparse(self.path)
        path, query = parsed.path, parse_qs(parsed.query)

        if path == "/health/live":
            # Deliberately does NOT touch the database. See module docstring.
            return self.send_json(200, {"status": "alive",
                                        "uptime_seconds": round(time.time() - started_at, 1)})

        if path == "/health/ready":
            ok, payload = readiness()
            return self.send_json(200 if ok else 503, payload)

        if path == "/version":
            return self.send_json(200, {"service": "station2-twin", "version": APP_VERSION,
                                        "expected_schema_version": EXPECTED_SCHEMA_VERSION,
                                        "credentials": CREDENTIALS.status()})

        if path == "/metrics":
            try:
                sv = schema_version() or -1
            except Exception:
                sv = -1
            body = (
                "# HELP station2_requests_total Total HTTP requests.\n"
                "# TYPE station2_requests_total counter\n"
                f"station2_requests_total {request_count}\n"
                "# HELP station2_errors_total Total 4xx/5xx responses.\n"
                "# TYPE station2_errors_total counter\n"
                f"station2_errors_total {error_count}\n"
                "# HELP station2_db_errors_total Failed database operations.\n"
                "# TYPE station2_db_errors_total counter\n"
                f"station2_db_errors_total {db_error_count}\n"
                "# HELP station2_schema_version Applied schema version, -1 if unknown.\n"
                "# TYPE station2_schema_version gauge\n"
                f"station2_schema_version {sv}\n"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)

        parts = [p for p in path.split("/") if p]
        try:
            if len(parts) == 2 and parts[0] == "twin":
                return self._latest(parts[1])
            if len(parts) == 3 and parts[0] == "twin" and parts[2] == "history":
                return self._history(parts[1], query)
            # --- the surveillance twin ---
            if parts == ["surveillance", "scan"]:
                return self._scan(query)
            if len(parts) == 2 and parts[0] == "surveillance":
                return self._county(parts[1], query)
        except Exception as exc:
            db_error_count += 1
            error_count += 1
            log("db_error", error=type(exc).__name__, path=path)
            return self.send_json(503, {"error": "database_unavailable"})

        error_count += 1
        return self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        global request_count, error_count, db_error_count
        request_count += 1
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]

        if not (len(parts) == 3 and parts[0] == "twin" and parts[2] == "observation"):
            error_count += 1
            return self.send_json(404, {"error": "not_found"})

        length = int(self.headers.get("Content-Length") or 0)
        # A body limit, because "read whatever the client sends" is a memory
        # exhaustion primitive on an endpoint reachable from a reverse proxy.
        if length > 64 * 1024:
            error_count += 1
            return self.send_json(413, {"error": "payload_too_large"})
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            error_count += 1
            return self.send_json(400, {"error": "invalid_json"})

        metric = payload.get("metric")
        value = payload.get("value")
        if not isinstance(metric, str) or not metric or not isinstance(value, (int, float)):
            error_count += 1
            return self.send_json(400, {"error": "metric (string) and value (number) required"})

        try:
            with pool().connection() as conn:
                with conn.cursor() as cur:
                    # Parameterised. The asset id comes straight off the URL
                    # path and the metric name out of a JSON body; both are
                    # attacker-controlled on any endpoint DAST will probe.
                    cur.execute(
                        "INSERT INTO observations (asset_id, metric, value) "
                        "VALUES (%s, %s, %s) RETURNING id, observed_at",
                        (parts[1], metric, float(value)),
                    )
                    row = cur.fetchone()
            return self.send_json(201, {"id": row[0], "asset_id": parts[1],
                                        "metric": metric, "value": float(value),
                                        "observed_at": row[1].isoformat()})
        except Exception as exc:
            db_error_count += 1
            error_count += 1
            log("db_error", error=type(exc).__name__, path=parsed.path)
            return self.send_json(503, {"error": "database_unavailable"})

    def _latest(self, asset_id):
        with pool().connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT metric, value, observed_at FROM observations "
                    "WHERE asset_id = %s ORDER BY observed_at DESC LIMIT 1",
                    (asset_id,),
                )
                row = cur.fetchone()
        if not row:
            return self.send_json(404, {"error": "no_observations", "asset_id": asset_id})
        return self.send_json(200, {"asset_id": asset_id, "metric": row[0],
                                    "value": float(row[1]), "observed_at": row[2].isoformat()})

    def _week_args(self, query, cur, disease):
        """Default to the newest week present, not to 'now'.

        The feed lags reality by about two weeks. Defaulting to the current
        calendar week would return an empty result and render as zero cases
        -- a silent all-clear produced by a reporting delay.
        """
        if "year" in query and "week" in query:
            return int(query["year"][0]), int(query["week"][0])
        return surveillance.latest_week(cur, disease)

    def _county(self, county_code, query):
        disease = query.get("disease", [DEFAULT_DISEASE])[0]
        weeks = min(int(query.get("weeks", ["26"])[0]), 520)
        with pool().connection() as conn:
            with conn.cursor() as cur:
                year, week = self._week_args(query, cur, disease)
                if year is None:
                    return self.send_json(404, {"error": "no_data", "disease": disease})
                payload = surveillance.divergence(cur, disease, county_code, year, week)
                payload["series"] = surveillance.series(cur, disease, county_code, weeks)
        if payload["baseline_n"] == 0 and not payload["series"]:
            return self.send_json(404, {"error": "unknown_county", "county_code": county_code})
        return self.send_json(200, payload)

    def _scan(self, query):
        disease = query.get("disease", [DEFAULT_DISEASE])[0]
        with pool().connection() as conn:
            with conn.cursor() as cur:
                year, week = self._week_args(query, cur, disease)
                if year is None:
                    return self.send_json(404, {"error": "no_data", "disease": disease})
                rows = surveillance.scan(cur, disease, year, week)
        return self.send_json(200, {
            "disease": disease, "epi_year": year, "epi_week": week,
            "counties": len(rows),
            "alerting": sum(1 for r in rows if r["alert"]),
            "method": "historical limits (mean +/- 2sd of same week +/-1 over "
                      f"previous {surveillance.BASELINE_YEARS} years)",
            "results": rows,
        })

    def _history(self, asset_id, query):
        try:
            limit = min(int(query.get("limit", ["100"])[0]), 1000)
        except ValueError:
            return self.send_json(400, {"error": "limit must be an integer"})
        with pool().connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT metric, value, observed_at FROM observations "
                    "WHERE asset_id = %s ORDER BY observed_at DESC LIMIT %s",
                    (asset_id, limit),
                )
                rows = cur.fetchall()
        return self.send_json(200, {
            "asset_id": asset_id, "count": len(rows),
            "observations": [{"metric": r[0], "value": float(r[1]),
                              "observed_at": r[2].isoformat()} for r in rows],
        })


def stop(server, _signum, _frame):
    """Drain, then stop.

    Same shape as station1-hello, and for the same measured reason: calling
    server.shutdown() straight away means serve_forever() breaks out of its
    loop without handling the connection that woke it, so clients see a reset
    rather than a 503 and the readiness flag is never actually observed.
    Here the drain window matters more, because in-flight requests hold
    database connections that need to be returned to the pool.
    """
    global shutting_down
    shutting_down = True
    log("draining", seconds=GRACEFUL_DRAIN_SECONDS)

    def delayed():
        time.sleep(GRACEFUL_DRAIN_SECONDS)
        server.shutdown()

    threading.Thread(target=delayed, daemon=True).start()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    signal.signal(signal.SIGTERM, lambda s, f: stop(server, s, f))
    signal.signal(signal.SIGINT, lambda s, f: stop(server, s, f))
    log("server_started", port=PORT, expected_schema_version=EXPECTED_SCHEMA_VERSION)
    server.serve_forever()
    server.server_close()
    if _pool is not None:
        _pool.close()
    log("server_stopped")
