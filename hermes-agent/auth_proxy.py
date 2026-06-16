#!/usr/bin/env python3
"""Key-injecting reverse proxy for the Hermes OpenAI API server.

Hermes' gateway `api_server` REQUIRES `Authorization: Bearer <API_SERVER_KEY>`
on every `/v1` request (it refuses to start without a key and 401s requests
that lack one; only `/health` is public). The ACTIVATE session tunnel forwards
no upstream auth, so this shim sits on the tunnel-facing port
(`0.0.0.0:${service_port}`), injects the bearer, and forwards to the api_server
on loopback. It keeps the API key off the public port and out of inputs.sh.

Three behaviors matter for the platform:
  * Liveness probes (`GET /`, `HEAD`, `OPTIONS`, `/health`) are answered locally
    with 200 — Hermes' api_server has no root route and would 404, and a bare
    handler would 501 HEAD/OPTIONS, both of which read as "session not reachable".
  * Non-streaming responses (`/v1/models`, non-stream chat) are buffered and
    returned with a clean `Content-Length` (maximally compatible).
  * Streaming responses (`text/event-stream`) are forwarded chunked, and a
    keepalive SSE comment is injected during silent gaps. Hermes' agent goes
    quiet for several seconds while it thinks / runs tools, and the platform
    proxy resets an idle stream after only ~3s — without keepalives the chat
    dies mid-turn and the UI reports the session as unreachable.

Standard library only (Python 3.9+), so there is nothing to install.
"""
import argparse
import http.client
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Hop-by-hop headers (RFC 7230) plus framing headers we re-derive ourselves.
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host"}

# Paths the shim answers itself (liveness), instead of forwarding to Hermes.
LOCAL_OK_PATHS = {"", "/", "/health", "/healthz", "/ping"}

KEEPALIVE_SECS = 1.0   # emit an SSE comment after this many seconds of upstream silence


def make_handler(up_host, up_port, bearer, marker):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # one line per request -> stderr (auth-proxy.out)
            sys.stderr.write("proxy %s %s\n" % (self.command, self.path))
            sys.stderr.flush()

        def _ok(self, body=b'{"status":"ok"}', ctype="application/json"):
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _path(self):
            return self.path.split("?", 1)[0].rstrip("/") or "/"

        def do_OPTIONS(self):
            self.send_response(200)
            self.send_header("Allow", "GET, POST, DELETE, PATCH, HEAD, OPTIONS")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, PATCH, HEAD, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_HEAD(self):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            if self._path() == "/_agent":   # fleet-marker discovery (for the orchestrator)
                self._ok(json.dumps({"marker": marker, "kind": "hermes"}).encode())
                return
            if self._path() in LOCAL_OK_PATHS:
                self._ok()
                return
            self._proxy("GET")

        def do_POST(self):
            self._proxy("POST")

        def do_DELETE(self):
            self._proxy("DELETE")

        def do_PATCH(self):
            self._proxy("PATCH")

        def _proxy(self, method):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
            headers["Authorization"] = "Bearer " + bearer  # force our key
            headers["Host"] = "%s:%d" % (up_host, up_port)
            try:
                conn = http.client.HTTPConnection(up_host, up_port, timeout=1800)
                conn.request(method, self.path, body=body, headers=headers)
                resp = conn.getresponse()
            except Exception as exc:  # noqa: BLE001
                self.send_error(502, "upstream error: %s" % exc)
                return
            is_stream = "text/event-stream" in (resp.getheader("Content-Type") or "").lower()
            try:
                if is_stream:
                    self._relay_stream(resp)
                else:
                    self._relay_buffered(resp)
            finally:
                conn.close()

        def _relay_buffered(self, resp):
            """Non-streaming: read the whole body, send with Content-Length."""
            data = resp.read()
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except OSError:
                pass

        def _relay_stream(self, resp):
            """SSE: forward chunked, injecting a keepalive comment on silent gaps."""
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            lock = threading.Lock()
            done = threading.Event()
            data_seen = threading.Event()

            def write_chunk(raw):
                with lock:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(raw), raw))
                    self.wfile.flush()

            def keepalive():
                # Emit an SSE comment only after a full silent interval, so it
                # lands between events (never mid-event) and stays quiet while
                # real tokens are flowing.
                while not done.is_set():
                    data_seen.clear()
                    if not data_seen.wait(KEEPALIVE_SECS):
                        try:
                            write_chunk(b": keepalive\n\n")
                        except OSError:
                            return
            threading.Thread(target=keepalive, daemon=True).start()

            try:
                while True:
                    chunk = resp.read(2048)
                    if not chunk:
                        break
                    write_chunk(chunk)
                    data_seen.set()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                done.set()
                data_seen.set()
                try:
                    with lock:
                        self.wfile.write(b"0\r\n\r\n")
                        self.wfile.flush()
                except OSError:
                    pass

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:8717", help="host:port to listen on (tunnel-facing)")
    ap.add_argument("--upstream", default="127.0.0.1:8642", help="host:port of the Hermes api_server")
    ap.add_argument("--bearer", required=True, help="API_SERVER_KEY to inject")
    ap.add_argument("--marker", default="worker", help="fleet marker advertised at /_agent")
    args = ap.parse_args()
    lh, lp = args.listen.rsplit(":", 1)
    uh, up = args.upstream.rsplit(":", 1)
    handler = make_handler(uh, int(up), args.bearer, args.marker)
    print("auth_proxy: %s -> %s (injecting bearer)" % (args.listen, args.upstream), flush=True)
    ThreadingHTTPServer((lh, int(lp)), handler).serve_forever()


if __name__ == "__main__":
    main()
