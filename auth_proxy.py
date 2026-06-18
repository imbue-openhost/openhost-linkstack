#!/usr/bin/env python3
"""OpenHost auth-proxy sidecar for LinkStack.

Listens on the OpenHost-routed port (default 8080) and reverse-proxies to the
in-container Apache that serves LinkStack on 127.0.0.1:UPSTREAM_PORT.

Responsibilities:
  * Rewrite the Host header from X-Forwarded-Host so LinkStack's APP_URL /
    Host validation is satisfied.
  * Force X-Forwarded-Proto: https (OpenHost terminates TLS upstream).
  * Sanitise the owner-trust header: strip any client-supplied
    X-OpenHost-Is-Owner and only re-add it when the OpenHost router set it.
    LinkStack's OpenHostSso middleware trusts this header for auto-login.
  * Serve a static 200 on /_healthz for the OpenHost health check.
  * Serve a 200 placeholder while Apache is still cold-starting, so OpenHost
    does not mark the app as "started but not responding".

No credentials are read or written. The owner header alone drives SSO.
"""

import http.client
import os
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("OPENHOST_PROXY_PORT", "8080"))
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "80"))

OWNER_HEADER = "X-OpenHost-Is-Owner"

# Hop-by-hop headers must not be forwarded.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

HEALTH_PATH = "/_healthz"


def upstream_ready() -> bool:
    try:
        with socket.create_connection((UPSTREAM_HOST, UPSTREAM_PORT), timeout=1):
            return True
    except OSError:
        return False


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "openhost-linkstack-proxy"

    # Silence default request logging (keep logs clean / cheap).
    def log_message(self, fmt, *args):
        pass

    def _is_owner(self) -> bool:
        return (self.headers.get(OWNER_HEADER) or "").strip().lower() == "true"

    def _send_simple(self, code: int, body: bytes, ctype: str = "text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _handle(self):
        if self.path == HEALTH_PATH:
            self._send_simple(200, b"ok")
            return

        if not upstream_ready():
            # Cold-start placeholder: a 200 keeps OpenHost's health probe happy
            # until Apache is up.
            self._send_simple(
                200,
                b"<!doctype html><title>Starting</title>"
                b"<meta http-equiv=refresh content=3>"
                b"<body style='font-family:sans-serif'>Starting LinkStack...</body>",
                "text/html; charset=utf-8",
            )
            return

        # Read request body if present.
        body = b""
        length = self.headers.get("Content-Length")
        if length:
            try:
                body = self.rfile.read(int(length))
            except (ValueError, OSError):
                body = b""

        # Build the upstream header set.
        out_headers = {}
        for key in self.headers.keys():
            lk = key.lower()
            if lk in HOP_BY_HOP:
                continue
            if lk == "host":
                continue
            # Strip any client-supplied owner header; we re-add it below only
            # if the OpenHost router set it on the inbound request.
            if lk == OWNER_HEADER.lower():
                continue
            out_headers[key] = self.headers.get(key)

        # Host: prefer X-Forwarded-Host (set by the OpenHost router).
        xfh = self.headers.get("X-Forwarded-Host") or self.headers.get("Host")
        if xfh:
            out_headers["Host"] = xfh
            out_headers["X-Forwarded-Host"] = xfh

        out_headers["X-Forwarded-Proto"] = "https"
        client_ip = self.client_address[0] if self.client_address else ""
        prior_xff = self.headers.get("X-Forwarded-For")
        out_headers["X-Forwarded-For"] = (
            f"{prior_xff}, {client_ip}" if prior_xff else client_ip
        )

        # Re-add the trusted owner header only when the router set it.
        if self._is_owner():
            out_headers[OWNER_HEADER] = "true"

        conn = http.client.HTTPConnection(
            UPSTREAM_HOST, UPSTREAM_PORT, timeout=120
        )
        try:
            conn.request(self.command, self.path, body=body, headers=out_headers)
            resp = conn.getresponse()
            resp_body = resp.read()
            status = resp.status
            reason = resp.reason
            resp_headers = resp.getheaders()
        except (OSError, http.client.HTTPException) as exc:
            self._send_simple(502, f"upstream error: {exc}".encode())
            return
        finally:
            conn.close()

        self.send_response(status, reason)
        for key, value in resp_headers:
            if key.lower() in HOP_BY_HOP:
                continue
            if key.lower() == "content-length":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(resp_body)))
        self.send_header("Connection", "close")
        self.end_headers()
        # HEAD responses must not carry a body.
        if self.command != "HEAD":
            try:
                self.wfile.write(resp_body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    # Map all common verbs to the single handler.
    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_PATCH = _handle
    do_HEAD = _handle
    do_OPTIONS = _handle


def main():
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), ProxyHandler)
    print(
        f"[auth_proxy] listening on :{LISTEN_PORT} -> "
        f"{UPSTREAM_HOST}:{UPSTREAM_PORT}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
