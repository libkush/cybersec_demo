# Attack tooling

Two clients live here. Both are Python 3.8+ with **no third-party dependencies**,
so they run straight off the Amazon Linux 2023 image.

| Script | What it is | Detectability |
| --- | --- | --- |
| `slowloris.py` | Holds many half-open HTTP requests open, one junk header at a time | Very low: uses less bandwidth than a single browser tab |
| `http_flood.py` | Blunt volumetric request flood | High: obvious request-rate and bandwidth signature |

Both refuse to run without `--i-have-permission`. That flag is the
acknowledgement that you own the target or hold written authorisation to test
it. Only ever point these at the lab's own victim node.

## slowloris.py

```bash
python3 slowloris.py \
    --target 10.42.1.10 \
    --port 80 \
    --sockets 150 \
    --interval 10 \
    --i-have-permission
```

| Flag | Meaning |
| --- | --- |
| `--target` | Victim address (inside the lab this is the victim's **private** IP) |
| `--port` | Default 80 |
| `--sockets` | How many half-open connections to hold (default 150) |
| `--interval` | Seconds between keep-alive headers per socket (default 10) |
| `--timeout` | Connect/write timeout in seconds (default 4) |
| `--duration` | Stop after N seconds; `0` means run until stopped |
| `--report-every` | Seconds between progress lines (default 5) |
| `--verbose` | Log every keep-alive sweep |

**`--interval` must stay comfortably below the server's `Timeout` directive.**
On the lab victim that is 300s, so the default of 10s is safe. If you make the
interval larger than the server timeout, the server reaps your connections
faster than you can hold them and the attack simply will not take hold.

Rough budget per socket: ~200 bytes of headers initially, then ~25 bytes every
`--interval` seconds. 150 sockets at a 10s interval is well under 1 KB/s.

In the deployed lab you normally do **not** run this by hand — `lab-slowloris.service`
wraps it and `./scripts/attack.sh start` triggers it on all three attackers at once.

## http_flood.py

```bash
# 50 threads hammering / for 30 seconds
python3 http_flood.py --target 10.42.1.10 --workers 50 --duration 30 --i-have-permission
```

Watch the *Victim network throughput* panel in Grafana while this runs — unlike
Slowloris, the graph actually moves. It is a useful contrast: the same victim
that is trivial to knock over with 150 idle sockets is much harder to take down
by brute force.

In the lab: `./scripts/attack.sh flood --duration 30`.
