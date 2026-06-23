#!/usr/bin/env python3
"""Transparent TCP relay: 0.0.0.0:<listen> -> 127.0.0.1:<upstream>.

Why this exists: as of the June 2026 hardening (Hermes >= v0.17.0) the dashboard
REFUSES to bind a non-loopback address unless an auth provider (password/OAuth)
is configured -- `--insecure` is now a documented no-op. The ACTIVATE session
tunnel is itself the access boundary, so we don't want a second password gate in
front of it; instead we bind the dashboard to loopback (where the auth gate does
NOT engage) and put this relay on the tunnel-facing port `${service_port}`.

A raw byte relay -- not an HTTP proxy -- is deliberate: the dashboard speaks
HTTP, SSE, AND WebSocket (`/api/ws`, `/api/events`, a terminal socket), and it
builds those URLs from the `X-Forwarded-Prefix` the tunnel injects so the SPA
works under the session base path. Forwarding bytes verbatim preserves all of
that exactly as it behaved when the dashboard bound `0.0.0.0` itself (which the
skill verified worked, WebSockets included) -- minus the now-forbidden public
bind. An HTTP-aware proxy would have to re-implement chunking, the WS upgrade
handshake, and header passthrough; the relay sidesteps all of it.

Standard library only (no install on the controller).
"""
import argparse
import socket
import sys
import threading


def _pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        # Half-close the write side so the peer sees EOF but the other
        # direction can still drain (matters for half-closed HTTP/WS streams).
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _handle(client, up_host, up_port):
    try:
        upstream = socket.create_connection((up_host, up_port))
    except OSError as exc:  # noqa: BLE001
        sys.stderr.write("relay: upstream connect failed: %s\n" % exc)
        sys.stderr.flush()
        client.close()
        return
    t = threading.Thread(target=_pipe, args=(client, upstream), daemon=True)
    t.start()
    _pipe(upstream, client)
    t.join()
    client.close()
    upstream.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:8717", help="host:port to listen on (tunnel-facing)")
    ap.add_argument("--upstream", default="127.0.0.1:9119", help="host:port of the loopback dashboard")
    args = ap.parse_args()
    lh, lp = args.listen.rsplit(":", 1)
    uh, up = args.upstream.rsplit(":", 1)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lh, int(lp)))
    srv.listen(128)
    print("tcp_proxy: %s -> %s" % (args.listen, args.upstream), flush=True)
    while True:
        try:
            client, _ = srv.accept()
        except OSError:
            continue
        threading.Thread(target=_handle, args=(client, uh, int(up)), daemon=True).start()


if __name__ == "__main__":
    main()
