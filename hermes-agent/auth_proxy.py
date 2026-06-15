#!/usr/bin/env python3
"""Key-injecting reverse proxy for the Hermes OpenAI API server.

Hermes' gateway `api_server` REQUIRES `Authorization: Bearer <API_SERVER_KEY>`
on every `/v1` request (it refuses to start without a key and 401s requests
that lack one; only `/health` is public). The ACTIVATE session tunnel forwards
no upstream auth, so this shim sits on the tunnel-facing port
(`0.0.0.0:${service_port}`), injects the bearer, and forwards to the api_server
on loopback. Responses — including SSE streams — are passed through. The shim
keeps the API key off the public port and out of inputs.sh.

Standard library only (Python 3.9+), so there is nothing to install.
"""
import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Hop-by-hop headers (RFC 7230) plus framing headers we re-derive ourselves.
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host"}


def make_handler(up_host, up_port, bearer):
    class Handler(BaseHTTPRequestHandler):
        # HTTP/1.1 + chunked so streamed (SSE) replies reach the platform proxy
        # cleanly; the 0-chunk marks a clean end of stream.
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):  # quiet
            pass

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
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                while True:
                    chunk = resp.read(2048)   # incremental -> streams SSE through
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass   # client went away mid-stream
            finally:
                conn.close()

        def do_GET(self):
            self._proxy("GET")

        def do_POST(self):
            self._proxy("POST")

        def do_DELETE(self):
            self._proxy("DELETE")

        def do_PATCH(self):
            self._proxy("PATCH")

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:8717", help="host:port to listen on (tunnel-facing)")
    ap.add_argument("--upstream", default="127.0.0.1:8642", help="host:port of the Hermes api_server")
    ap.add_argument("--bearer", required=True, help="API_SERVER_KEY to inject")
    args = ap.parse_args()
    lh, lp = args.listen.rsplit(":", 1)
    uh, up = args.upstream.rsplit(":", 1)
    handler = make_handler(uh, int(up), args.bearer)
    print("auth_proxy: %s -> %s (injecting bearer)" % (args.listen, args.upstream), flush=True)
    ThreadingHTTPServer((lh, int(lp)), handler).serve_forever()


if __name__ == "__main__":
    main()
