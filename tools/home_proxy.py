#!/usr/bin/env python3
"""home_proxy.py — tiny authenticated HTTP proxy (the home end of the relay).

Run it on a home computer that has Tailscale installed and running:

    python3 home_proxy.py

It listens on port 8899. It is reachable only from your own devices:
your home LAN, and your Tailscale network (nothing is forwarded from the
public internet unless you open the port on your router — don't).
Every request must present the token below as the proxy password
(any username works). Change the token if you like; just tell Jarvis
the new one through the secure card, not plain chat.

Pure Python 3 standard library — no pip installs. Leave it running
while the relay is in use; Ctrl+C stops it.
"""

import argparse
import base64
import socket
import socketserver
import sys
import threading
from urllib.parse import urlsplit

TOKEN = "PUT_TOKEN_HERE"


def _authed(headers):
    auth = headers.get("proxy-authorization", "")
    if not auth.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(auth[6:]).decode("utf-8", "replace")
    except Exception:
        return False
    return decoded.split(":", 1)[-1] == TOKEN


def _pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(60)
        rfile = self.request.makefile("rb")
        line = rfile.readline(65536).decode("iso-8859-1").strip()
        if not line:
            return
        headers = {}
        while True:
            h = rfile.readline(65536).decode("iso-8859-1")
            if h in ("\r\n", "\n", ""):
                break
            if ":" in h:
                k, v = h.split(":", 1)
                headers[k.strip().lower()] = v.strip()

        if not _authed(headers):
            self.request.sendall(
                b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                b'Proxy-Authenticate: Basic realm="home-relay"\r\n'
                b"Content-Length: 0\r\n\r\n"
            )
            return

        parts = line.split(" ")
        if len(parts) < 2:
            return
        method, target = parts[0].upper(), parts[1]

        try:
            if method == "CONNECT":
                host, _, port = target.rpartition(":")
                upstream = socket.create_connection(
                    (host.strip("[]"), int(port or 443)), timeout=20
                )
                self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                self._relay(upstream, rfile)
            else:
                # Plain HTTP proxying: target is an absolute URL.
                u = urlsplit(target)
                host = u.hostname
                port = u.port or 80
                path = u.path or "/"
                if u.query:
                    path += "?" + u.query
                upstream = socket.create_connection((host, port), timeout=20)
                send_headers = [
                    f"{method} {path} HTTP/1.1",
                    f"Host: {host}" if "host" not in headers else None,
                ]
                for k, v in headers.items():
                    if k in ("proxy-authorization", "proxy-connection"):
                        continue
                    send_headers.append(f"{k}: {v}")
                head = "\r\n".join(h for h in send_headers if h) + "\r\n\r\n"
                upstream.sendall(head.encode("iso-8859-1"))
                # Forward a request body if one was announced.
                length = int(headers.get("content-length", "0") or "0")
                remaining = length
                while remaining > 0:
                    chunk = rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    upstream.sendall(chunk)
                    remaining -= len(chunk)
                self._relay(upstream, rfile)
        except OSError:
            try:
                self.request.sendall(
                    b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                )
            except OSError:
                pass

    def _relay(self, upstream, rfile):
        t = threading.Thread(target=_pump, args=(upstream, self.request), daemon=True)
        t.start()
        try:
            while True:
                # Raw recv, not rfile.read(n): a buffered read(n) blocks until
                # the full n bytes arrive, which stalls interactive tunnels.
                data = self.request.recv(65536)
                if not data:
                    break
                upstream.sendall(data)
        except OSError:
            pass
        finally:
            try:
                upstream.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            t.join(timeout=5)
            upstream.close()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    args = ap.parse_args()
    with Server(("0.0.0.0", args.port), Handler) as srv:
        print(f"home-relay proxy listening on port {args.port} (token required)")
        print("Leave this running. Ctrl+C to stop.")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")


if __name__ == "__main__":
    sys.exit(main())
