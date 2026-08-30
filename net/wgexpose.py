#!/usr/bin/env python3
"""Expose a loopback service on the WireGuard address, for allowlisted peers only.

Why this exists: on these SELinux-confined hosts `ssh -L` fails at the last hop
(`channel N: open failed: connect failed`) because sshd's own domain may not
connect to a staff user's ports -- the forward is set up, then the server-side
connect is refused. User-context processes have no such restriction: they bind
the wg address and connect to loopback freely. So the relay runs as the user.

Only peers on the allowlist are served; everything else is dropped before a
byte is read, which keeps a service that has no auth of its own (llama.cpp,
ComfyUI) off-limits to the rest of the tunnel subnet.

usage:
  wgexpose.py <bind_ip:port> <target_ip:port> --allow 10.72.0.12[,10.72.0.13]

example:
  wgexpose.py 10.72.0.1:18088 127.0.0.1:8088 --allow 10.72.0.12
"""

from __future__ import annotations

import argparse
import socket
import socketserver
import sys
import threading
import time

BUFSIZE = 65536


def hostport(value: str) -> tuple[str, int]:
    host, _, port = value.rpartition(":")
    if not host or not port.isdigit():
        raise argparse.ArgumentTypeError(f"expected IP:PORT, got {value!r}")
    return host, int(port)


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def pump(src: socket.socket, dst: socket.socket) -> None:
    """Copy src -> dst until either end closes, then half-close dst."""
    try:
        while True:
            data = src.recv(BUFSIZE)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        # Half-close so the peer sees EOF instead of hanging on a live socket.
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class Relay(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    target: tuple[str, int]
    allowed: frozenset[str]

    def verify_request(self, request, client_address) -> bool:
        if client_address[0] in self.allowed:
            return True
        log(f"REFUSED {client_address[0]} (not in allowlist)")
        return False


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        server: Relay = self.server  # type: ignore[assignment]
        peer = self.client_address[0]
        try:
            upstream = socket.create_connection(server.target, timeout=10)
        except OSError as exc:
            log(f"{peer} -> {server.target[0]}:{server.target[1]} failed: {exc}")
            return
        # Interactive traffic (SSE token streams, ComfyUI websockets): send small
        # writes immediately rather than waiting for Nagle to fill a segment.
        for sock in (self.request, upstream):
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass
            sock.settimeout(None)
        up = threading.Thread(target=pump, args=(self.request, upstream), daemon=True)
        up.start()
        pump(upstream, self.request)
        up.join()
        try:
            upstream.close()
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bind", type=hostport, help="address to listen on, e.g. 10.72.0.1:18088")
    ap.add_argument("target", type=hostport, help="loopback service to forward to, e.g. 127.0.0.1:8088")
    ap.add_argument("--allow", required=True, help="comma-separated peer IPs permitted to connect")
    args = ap.parse_args()

    allowed = frozenset(ip.strip() for ip in args.allow.split(",") if ip.strip())
    if not allowed:
        ap.error("--allow needs at least one IP")

    Relay.target = args.target
    Relay.allowed = allowed
    try:
        server = Relay(args.bind, Handler)
    except OSError as exc:
        log(f"cannot bind {args.bind[0]}:{args.bind[1]}: {exc}")
        return 1
    log(f"relay {args.bind[0]}:{args.bind[1]} -> {args.target[0]}:{args.target[1]} allow={','.join(sorted(allowed))}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
