#!/usr/local/bin/python
import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PORT = int(os.environ.get("PORT", "8080"))
started_at = time.time()
shutting_down = False
request_count = 0
error_count = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(json.dumps({"event": "http_request", "message": fmt % args}), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global request_count, error_count
        request_count += 1
        if self.path == "/health/live":
            self.send_json(200, {"status": "alive"})
        elif self.path == "/health/ready":
            status = 503 if shutting_down else 200
            self.send_json(status, {"status": "ready" if status == 200 else "draining"})
        elif self.path == "/":
            self.send_json(200, {"message": "hello world", "service": "station1-hello"})
        elif self.path == "/version":
            self.send_json(200, {"service": "station1-hello", "version": os.environ.get("APP_VERSION", "dev")})
        elif self.path == "/metrics":
            body = (
                "# HELP station1_requests_total Total HTTP requests.\n"
                "# TYPE station1_requests_total counter\n"
                f"station1_requests_total {request_count}\n"
                "# HELP station1_errors_total Total 404 responses.\n"
                "# TYPE station1_errors_total counter\n"
                f"station1_errors_total {error_count}\n"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            error_count += 1
            self.send_json(404, {"error": "not_found"})


GRACEFUL_DRAIN_SECONDS = float(os.environ.get("GRACEFUL_DRAIN_SECONDS", "3"))


def stop(server, _signum, _frame):
    global shutting_down
    shutting_down = True

    # Calling server.shutdown() immediately does NOT give a usable drain
    # window: BaseServer.serve_forever() re-checks __shutdown_request right
    # after selector.select() wakes up and, if true, breaks out WITHOUT
    # calling _handle_request_noblock() -- so any connection that caused
    # select() to wake is simply never accepted, and the client sees a
    # reset/refused connection instead of a 503. Verified empirically: two
    # independent methods (host-side sub-millisecond polling, and the
    # container's own request log) both showed zero 503 responses ever
    # served -- a hard transition from 200 straight to connection failure.
    #
    # Fix: keep serve_forever() running (still accepting + handling
    # connections, so /health/ready's `shutting_down` check actually gets
    # to run and return 503) for a real grace period, and only THEN call
    # server.shutdown() to stop the loop and let server_close() run.
    def delayed_shutdown():
        time.sleep(GRACEFUL_DRAIN_SECONDS)
        server.shutdown()

    threading.Thread(target=delayed_shutdown, daemon=True).start()


server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
signal.signal(signal.SIGTERM, lambda signum, frame: stop(server, signum, frame))
signal.signal(signal.SIGINT, lambda signum, frame: stop(server, signum, frame))
print(json.dumps({"event": "server_started", "port": PORT, "started_at": started_at}), flush=True)
server.serve_forever()
server.server_close()
print(json.dumps({"event": "server_stopped"}), flush=True)
