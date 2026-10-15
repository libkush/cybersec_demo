#!/usr/bin/env python3
"""
keepalive_probe.py -- show, live, why a warm HTTP connection survives a
Slowloris attack that kills brand-new connections.

WHY THIS EXISTS
---------------
Apache prefork binds one worker process to one TCP connection. With
`KeepAlive On` and a long `KeepAliveTimeout`, that worker is *not* released
between requests -- it sits on the socket waiting for the next one.

So during a Slowloris attack the victim runs out of workers, and:

  * a connection that already owns a worker keeps getting served (warm), while
  * a brand-new connection has no worker to accept it and times out (cold).

This is the most interesting thing the lab demonstrates, and it is invisible if
you only ever look at one browser tab. This tool puts the two side by side:

    WARM   one persistent keep-alive connection, reused for every request
    COLD   a brand-new TCP connection for every request

Run it, start the attack in another terminal, and watch the cold lane die while
the warm lane stays green.

This is a benign HTTP GET probe, not an attack tool, so it needs no
authorisation flag. It only ever fetches a static file.

Requires Python 3.8+. No third-party packages.
"""

from __future__ import annotations

import argparse
import http.client
import socket
import sys
import threading
import time
from collections import deque

# --- ANSI --------------------------------------------------------------------
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"

STRIP_WIDTH = 34


def colour_enabled(no_color: bool) -> bool:
    return not no_color and sys.stdout.isatty()


class Style:
    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled

    def __call__(self, code: str, text: str) -> str:
        if not self.enabled:
            return text
        return code + text + RESET


class Lane:
    """One probe lane: a reused keep-alive connection, or a cold one."""

    def __init__(self, name: str, target: str, port: int, timeout: float, warm: bool) -> None:
        self.name = name
        self.target = target
        self.port = port
        self.timeout = timeout
        self.warm = warm

        self.lock = threading.Lock()
        self.samples: deque[tuple[str, float]] = deque(maxlen=STRIP_WIDTH)
        self.ok = 0
        self.failed = 0
        self.connections = 0
        self.last_label = "-"
        self.last_ms = 0.0

        self._conn: http.client.HTTPConnection | None = None
        self._counter = 0

    # -- one request ------------------------------------------------------
    def _request(self) -> tuple[str, float, str]:
        path = "/index.html?probe=%s-%d" % (self.name.lower(), self._counter)
        self._counter += 1

        if self.warm:
            if self._conn is None:
                self._conn = http.client.HTTPConnection(self.target, self.port, timeout=self.timeout)
                with self.lock:
                    self.connections += 1
            conn = self._conn
        else:
            conn = http.client.HTTPConnection(self.target, self.port, timeout=self.timeout)
            with self.lock:
                self.connections += 1

        started = time.perf_counter()
        try:
            conn.request(
                "GET",
                path,
                headers={
                    "Connection": "keep-alive" if self.warm else "close",
                    "Accept": "*/*",
                    "User-Agent": "keepalive-probe/1.0",
                },
            )
            response = conn.getresponse()
            response.read()
            elapsed_ms = (time.perf_counter() - started) * 1000.0

            if response.status != 200:
                return ("http", elapsed_ms, "HTTP %d" % response.status)
            if elapsed_ms > 1000.0:
                return ("slow", elapsed_ms, "200 (slow)")
            return ("ok", elapsed_ms, "200")

        except Exception as exc:  # noqa: BLE001 - we want everything here
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            timed_out = isinstance(exc, (socket.timeout, TimeoutError))

            # A broken keep-alive connection loses its privileged status; the
            # next attempt will have to open a new one, just like the cold lane.
            if self.warm and self._conn is not None:
                try:
                    self._conn.close()
                except Exception:  # noqa: BLE001
                    pass
                self._conn = None

            return ("timeout" if timed_out else "error", elapsed_ms,
                    "TIMEOUT" if timed_out else type(exc).__name__)

    def run(self, stop: threading.Event, interval: float) -> None:
        while not stop.is_set():
            state, ms, label = self._request()
            with self.lock:
                self.samples.append((state, ms))
                if state in ("ok", "slow"):
                    self.ok += 1
                else:
                    self.failed += 1
                self.last_label = label
                self.last_ms = ms
            if stop.wait(interval):
                break

    # -- reporting --------------------------------------------------------
    def snapshot(self) -> tuple:
        with self.lock:
            return (list(self.samples), self.ok, self.failed,
                    self.connections, self.last_label, self.last_ms)

    @staticmethod
    def ratio(samples: list[tuple[str, float]]) -> float:
        if not samples:
            return 0.0
        good = sum(1 for state, _ in samples if state in ("ok", "slow"))
        return good / len(samples)


def cell(state: str, ms: float, style: Style) -> str:
    if state in ("timeout", "error", "http"):
        return style(RED, "\u00d7")
    if ms < 150:
        return style(GREEN, "\u2581")
    if ms < 500:
        return style(GREEN, "\u2584")
    if ms < 1000:
        return style(GREEN, "\u2586")
    if ms < 3000:
        return style(YELLOW, "\u2588")
    return style(RED, "\u2588")


def render(lanes: list[Lane], args: argparse.Namespace, started: float, style: Style) -> None:
    elapsed = int(time.time() - started)
    target = "http://%s/" % args.target if args.port == 80 else "http://%s:%d/" % (args.target, args.port)

    lines: list[str] = []
    lines.append("")
    lines.append("  %s  %s" % (
        style(BOLD + CYAN, "Slowloris lab"),
        style(DIM, "\u00b7 warm vs cold connection probe"),
    ))
    lines.append("  %s   every %.1fs   elapsed %02d:%02d" % (
        style(DIM, "target " + target), args.interval, elapsed // 60, elapsed % 60,
    ))
    lines.append("")

    snapshots = []
    for lane in lanes:
        samples, ok, failed, conns, label, ms = lane.snapshot()
        snapshots.append((lane, samples, ok, failed, conns))

        if lane.warm:
            heading = "one persistent keep-alive connection, reused every request"
        else:
            heading = "a brand-new TCP connection for every request"

        lines.append("  %s  %s" % (style(BOLD, "%-4s" % lane.name), style(DIM, heading)))
        lines.append("      connections opened: %-5d  ok %-5d failed %-5d  last: %s" % (
            conns, ok, failed,
            style(GREEN, label) if label.startswith("200") and "slow" not in label
            else style(RED, label) if label in ("TIMEOUT",) or not label.startswith("200")
            else style(YELLOW, label),
        ))

        strip = "".join(cell(state, ms_, style) for state, ms_ in samples)
        padding = style(DIM, "\u00b7" * (STRIP_WIDTH - len(samples)))
        lines.append("      " + strip + padding)
        lines.append("")

    # -- verdict ----------------------------------------------------------
    warm_ratio = Lane.ratio(snapshots[0][1])
    cold_ratio = Lane.ratio(snapshots[1][1])

    if warm_ratio >= 0.8 and cold_ratio <= 0.4:
        verdict = style(RED, "COLD LANE STARVED") + style(
            DIM, "  \u2014 the victim cannot accept NEW connections, "
                 "but existing ones are still served")
    elif warm_ratio <= 0.4 and cold_ratio <= 0.4:
        verdict = style(RED, "VICTIM DOWN") + style(DIM, "  \u2014 neither lane can get through")
    elif warm_ratio >= 0.8 and cold_ratio >= 0.8:
        verdict = style(GREEN, "HEALTHY") + style(DIM, "  \u2014 no attack in progress?")
    else:
        verdict = style(YELLOW, "MIXED") + style(DIM, "  \u2014 partial worker starvation")

    lines.append("  " + verdict)
    lines.append("")
    lines.append("  " + style(DIM, "Ctrl-C to stop   \u00b7   in another terminal: ./scripts/attack.sh start"))
    lines.append("")

    # Redraw in place: home the cursor, then overwrite each line.
    out = ["\033[H"]
    for line in lines:
        out.append(line + "\033[K\n")
    sys.stdout.write("".join(out))
    sys.stdout.flush()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Live warm-vs-cold HTTP connection probe.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--target", required=True, help="victim host or IP")
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--interval", type=float, default=2.0, help="seconds between requests per lane")
    parser.add_argument("--timeout", type=float, default=8.0, help="per-request timeout in seconds")
    parser.add_argument("--no-color", action="store_true", help="disable ANSI colour")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    style = Style(colour_enabled(args.no_color))

    lanes = [
        Lane("WARM", args.target, args.port, args.timeout, warm=True),
        Lane("COLD", args.target, args.port, args.timeout, warm=False),
    ]

    stop = threading.Event()
    started = time.time()

    if sys.stdout.isatty():
        sys.stdout.write("\033[2J")  # clear once; frames redraw in place

    threads = [
        threading.Thread(target=lane.run, args=(stop, args.interval), daemon=True)
        for lane in lanes
    ]
    for thread in threads:
        thread.start()

    try:
        while any(thread.is_alive() for thread in threads):
            render(lanes, args, started, style)
            time.sleep(0.25)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        for thread in threads:
            thread.join(timeout=2.0)

    # -- final summary ----------------------------------------------------
    elapsed = max(0.001, time.time() - started)
    print()
    print("  %s  (%.0fs)" % (style(BOLD, "Summary"), elapsed))
    for lane in lanes:
        _samples, ok, failed, conns, _label, ms = lane.snapshot()
        total = ok + failed
        pct = (100.0 * ok / total) if total else 0.0
        print("    %-5s %3d/%-3d served (%5.1f%%)   %d TCP connection(s) opened" % (
            lane.name, ok, total, pct, conns))
    print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
