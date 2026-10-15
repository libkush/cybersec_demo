# Slowloris / DDoS teaching lab

A disposable AWS lab that demonstrates **Slowloris**, a denial-of-service attack
that takes a web server down without using any meaningful bandwidth, and then
shows exactly why the fix works.

One victim, three attackers, and (optionally) a monitoring node with Prometheus
and Grafana showing the attack happening live: connection counts climbing,
worker slots draining, and a blackbox probe flipping from "200 OK" to "timeout".

> **Scope.** This repository builds an isolated lab inside *your own* AWS
> account and attacks *only* the victim instance it creates. The attack tooling
> refuses to run without `--i-have-permission`. Pointing anything in here at
> systems you do not own is a criminal offence in most jurisdictions. Keep the
> lab in its own AWS account if you can, and tear it down when the class ends.

---

## What you get

```
        your laptop / classroom
        |                    |
        | browser            | browser
        v                    v
  :80 victim site      :3000 Grafana,  :9090 Prometheus
                                 |
            +--------------------+---------------------+
            |                                          |
   +--------+---------+                      +---------+--------+
   |     OBSERVER     |                      |       VICTIM        |
   | Prometheus       |   scrapes :9100      | Apache httpd        |
   | Grafana          |   scrapes :9117      |  - prefork, 40 slots|
   | blackbox_exporter|   probes  :80        |  - no req-timeout   |
   +------------------+                      | node_exporter :9100 |
                                             | apache_exporter :9117|
   +------------------+   Slowloris          +---------------------+
   |  attacker-1      |   half-open HTTP             ^
   |  attacker-2      |   on port 80                 |
   |  attacker-3      |------------------------------+
   | node_exporter    |
   +------------------+
```

| Node | Count | What it does |
| --- | --- | --- |
| victim | 1 | Apache prefork, deliberately misconfigured. Serves a static demo site. |
| attacker | 3 (`attacker_count`) | Hold ~150 half-open HTTP requests each. That is what makes it *distributed*. |
| observer | 1 (`deploy_observer`) | Prometheus + Grafana + blackbox_exporter. Optional. |

Everything is one `t3.micro` per node, each with a 2 GiB swap file so a
mis-tuned demo cannot OOM-kill itself halfway through your lesson. All nodes
live in a dedicated VPC (`10.42.0.0/16`) that `tofu destroy` removes in one go.

---

## Why this is a DDoS and not just a DoS

Slowloris opens a TCP connection, sends a request line and *most* of the
headers, and then stops — never sending the blank line that ends the header
block:

```
GET /?abc123 HTTP/1.1\r\n
Host: demo.acme.test\r\n
User-Agent: ...\r\n
Accept: text/html,*/*\r\n
                          <-- and nothing more, ever
```

The server now has a worker slot allocated to a request that will never
complete. Every few seconds the attacker pushes one more junk header so the
connection never looks idle. About 25 bytes every 10 seconds per socket.

Apache **prefork** dedicates one process per connection, so `MaxRequestWorkers`
(40 on the victim) is a hard ceiling on concurrency. Three attackers × 150
sockets is 450 connections chasing 40 slots: real visitors get queued and then
time out, while the attack itself uses well under 1 KB/s.

That is the whole point of the lesson. A bigger pipe, a fatter CPU, or a load
balancer that only counts bandwidth will not help. What helps is either reaping
slow clients or refusing to give a worker to a request that has not finished
arriving.

---

## Cost

This is the part that surprises people, so read it before you leave it running.

* 5 × `t3.micro` on-demand is roughly **$0.05–0.12 per hour** for the whole lab
  in `us-east-1`, plus a public IPv4 charge for each node.
* A three-hour class lands somewhere around **$1–2**, not counting data transfer.
* Nothing here is free-tier-safe: the observer's NAT-free public subnet and the
  five public IPv4 addresses are billed regardless of free-tier status.

Check the current [EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
for your region. Then run `./scripts/down.sh` when you are finished — the
[teardown](#teardown) section has the "did I actually delete it?" checklist.

---

## Prerequisites

| Tool | Why | Check |
| --- | --- | --- |
| OpenTofu ≥ 1.6 (or Terraform ≥ 1.6) | builds the infrastructure | `tofu version` |
| AWS CLI v2, authenticated | credentials for the provider | `aws sts get-caller-identity` |
| `jq` | the helper scripts parse `tofu output` | `jq --version` |
| `ssh` / `curl` | orchestration and smoke tests | `ssh -V` |

Your AWS identity needs permission to create a VPC, EC2 instances, security
groups, an S3 bucket and an IAM role. `PowerUserAccess` plus `iam:CreateRole`
is a reasonable stand-in for a lab account.

Python is **not** a prerequisite on your laptop — the attack scripts only ever
run on the EC2 nodes, and they use nothing but the standard library.

---

## Quick start

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
$EDITOR infra/terraform.tfvars          # optional; defaults work

make init                               # tofu init
make plan                               # see what will be built
make up                                 # apply + wait for cloud-init on every node
```

`make up` ends by printing the summary:

```
  Lab 'slowloris' is up in us-east-1  (5 nodes, t3.micro)

  Victim site      : http://54.1.2.3/
  Victim (internal): http://10.42.1.10/
  Attackers        : 54.1.2.4, 54.1.2.5, 54.1.2.6
  Grafana          : http://54.1.2.7:3000/  (admin / ...)
  Prometheus       : http://54.1.2.7:9090/
```

Get the Grafana password with `cd infra && tofu output -raw grafana_admin_password`.

`admin_cidr` defaults to **your current public IP, detected automatically**, and
every inbound rule is scoped to it. If you change networks, re-apply with
`-var admin_cidr=...` or the console will stop working.

---

## Running the demo

Open two browser tabs first: the **victim site** and **Grafana → DDoS Lab →
"Slowloris / DDoS Lab"**.

1. **Baseline.** Let the victim site's own probe settle for ~30 seconds. It
   shows availability, last response time and a live latency chart. In Grafana,
   point at *Apache worker slots*: 40 workers, nearly all `idle`, `busy` near 0.
2. **Start it.**
   ```bash
   ./scripts/attack.sh start
   ```
   That SSHes into all three attackers and starts `lab-slowloris.service`. Pass
   `--duration 60` if you want it to stop by itself.
3. **Watch, and narrate what you see:**
   * *Apache worker slots* — `idle` collapses to 0, `busy` pins at 40. The
     server is structurally full; it is not slow, it is **out of slots**.
   * *Apache connections by state* — the `read` bucket explodes. `read` means
     "connected, waiting for request headers": that is literally the Slowloris
     socket parked on the scoreboard. The `keepalive` band is separate and
     unrelated.
   * *Website reachable* / *Availability* — the blackbox probe is a completely
     independent host asking "can I still fetch the homepage?" It goes red.
   * *Website response time* — jumps from tens of milliseconds to the full
     5-second probe timeout.
   * *Victim network throughput* — **stays tiny.** This is the punchline. Pan
     to it deliberately.
   * *Victim CPU and memory headroom* — CPU barely moves (it is not a CPU
     attack) while available memory falls, because each of those 40 prefork
     workers costs real RAM.
4. **Stop it.**
   ```bash
   ./scripts/attack.sh stop
   ```
   Recovery is not instant: 450 half-open sockets have to be reaped, and the
   `TIME_WAIT` panel stays elevated for a while afterwards. That asymmetry —
   instant to break, slow to recover — is worth pointing out.
5. **Optional contrast.** `./scripts/attack.sh flood --duration 30` runs the
   volumetric `http_flood.py` from all attackers instead. Now the network panel
   moves, and you can discuss why noisy attacks are easier to detect.

`./scripts/status.sh` gives a one-glance health check of every node, and
`./scripts/ssh.sh victim` (or `attacker-2`, `observer`) drops you into a shell.

---

## Why a warm browser tab keeps working

The most interesting behaviour in the lab is easy to miss, because it is
invisible if you only ever watch one tab.

Apache prefork binds one worker process to one TCP connection, and
`KeepAlive On` + `MaxKeepAliveRequests 0` + `KeepAliveTimeout 300` mean that
worker is *not* released between requests — it sits on the socket waiting for the
next one. So once all 40 workers are taken:

* a connection that **already owns a worker** keeps being served, and
* a **brand-new** connection has no worker to accept it, and times out.

That is exactly what you observe mid-attack: `curl` times out and Grafana's
blackbox probe (a fresh connection every 2 s) turns red, while a browser tab
opened beforehand carries on returning 200s from its own warm connection. The
tab's probe fires every 2 s, so the connection never idles long enough to trip
`KeepAliveTimeout` — it can outlast the entire attack.

Show it directly, side by side:

```bash
./tools/keepalive_probe.py --target <victim-public-ip>
# or: make probe
```

Two lanes run in parallel — one reused keep-alive connection, one new TCP
connection per request — and the cold lane dies while the warm lane stays green.
The connection counters make it concrete: the warm lane serves dozens of
requests over **one** TCP connection.

Run it on the projector while the students watch. This is arguably the better
lesson than "the site went down", because it names the resource being drained:
*the ability to accept new connections*, not the ability to serve requests.

It also means the victim's **own in-page probe is not a trustworthy indicator**.
Open the page before the attack and it will keep reporting healthy. Stage the
demo deliberately instead:

1. Open the victim site in **Window A** *before* starting the attack.
2. Start the attack (`./scripts/attack.sh start`).
3. Open the site in a **fresh private window** — Window B times out.
4. Run `make probe` and explain worker affinity.

Same server, same second, two different answers — because one of them already
had a worker.

---

## The interesting bit: why a naive attempt fails

If you build this by hand and just delete the timeouts, **it still will not
work**, and the reason is the single best teaching moment in the lab.

Apache 2.4 ships `mod_reqtimeout`, loaded by default on every RHEL-family
distro, and it has a built-in default even when you never write a directive:

```
RequestReadTimeout handshake=0 header=20-40,MinRate=500 body=20,MinRate=500
```

That means "allow 20 seconds for headers, extended by up to 40 seconds, but
require at least 500 bytes/second". A classic slowloris dribbling 25 bytes every
10 seconds is well under that rate, so the server 408s the connection after ~40
seconds and the attack quietly fails while you stare at a graph that will not
move.

The victim's config therefore contains this, and it is commented as the
vulnerability it is:

```apache
<IfModule mod_reqtimeout.c>
    RequestReadTimeout header=0 body=0      # 0 == no limit
</IfModule>
```

`header=0 body=0` disables the module's protection entirely (as documented in
the `mod_reqtimeout` manual). **The hardening fix is to put that line back to
`sensible values`** — which is a one-line diff you can show on the projector.

---

## Hardening: the fix

Three independent fixes live in `infra/templates/victim_apache.conf`, each
annotated in place:

| Weakness | Vulnerable setting | Fix |
| --- | --- | --- |
| No request-read timeout | `RequestReadTimeout header=0 body=0` | `RequestReadTimeout header=20-40,MinRate=500 body=20,MinRate=500` |
| Long keep-alive window | `KeepAliveTimeout 300`, `MaxKeepAliveRequests 0` | `KeepAliveTimeout 5`, `MaxKeepAliveRequests 100` |
| Tiny worker pool | `MaxRequestWorkers 40` | Raise it — but this alone only buys time |

The real-world answers sit outside Apache and are worth naming in class:

* A reverse proxy (nginx, HAProxy, a cloud LB) that buffers the **complete**
  header block before handing the connection to a backend. A half-open request
  then occupies a cheap proxy slot, not an application worker.
* Layer 7 rate limiting / WAF rules keyed on "connection open but no complete
  request within N seconds".
* `iptables`/`nftables` `conntrack` limits, or the cloud equivalent, to cap
  per-source connection counts.
* Autoscaling — which, as students usually spot immediately, converts a
  availability problem into a billing problem unless the source is throttled
  first.

---

## Running without the observer node (4-node mode)

If you want to stay at exactly four EC2 machines, turn the observer off and run
the identical monitoring stack on your own laptop:

```bash
# infra/terraform.tfvars
deploy_observer = false
```

```bash
make up

cd monitoring
cp prometheus.local.yml.example prometheus.local.yml
$EDITOR prometheus.local.yml        # paste in the IPs from `tofu output`
docker compose up -d                # Grafana on :3000, admin/admin
```

The dashboard and datasource definitions are the same files the EC2 observer
uses, so the board looks identical. Your laptop must be able to reach the nodes'
`9100`, `9117` and `80` ports — which it can, because `admin_cidr` already
allows your public IP. Note that this mode polls over the public internet, so
one extra hop of latency shows up in the probe numbers.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Grafana shows "No data" for everything | Prometheus has not discovered targets yet. Check `http://<observer>:9090/targets`. EC2 service discovery needs ~30s after boot, and the instance role must have `ec2:DescribeInstances` (it does by default). |
| `apache_scoreboard` panels are empty | `mod_status` or `ExtendedStatus` is off, or `apache_exporter` cannot reach `/server-status`. On the victim: `curl -s localhost/server-status?auto`. |
| A `blackbox` target is `down` with `lookup blackbox ... no such host` | The blackbox container is crash-looping, so it never joins the docker network. blackbox_exporter parses its config **strictly** — one unknown key is fatal, not a warning. `sudo docker logs blackbox` names the offending line. Validate any edit before shipping it: `docker run --rm -v "$PWD/blackbox.yml:/etc/blackbox_exporter/config.yml:ro" prom/blackbox-exporter:v0.29.0 --config.check --config.file=/etc/blackbox_exporter/config.yml`. |
| The attack starts but nothing happens | The single most common cause is `mod_reqtimeout` still reaping connections. Confirm the victim's `zz-slowloris-lab.conf` is present and that `httpd -t` is clean. |
| `attack.sh` says "no attacker nodes found" | Run it from the repo root after a successful `make up`; the scripts read `tofu output`. |
| SSH times out | Your public IP changed. Re-apply with `-var admin_cidr=<new-ip>/32`. |
| A node never finishes bootstrapping | `./scripts/ssh.sh victim` then `sudo tail -f /var/log/lab-init.log`. The most common failures are a GitHub rate limit while downloading an exporter, or an S3 permission problem. |
| Grafana dies on first boot | Volume ownership. The observer's cloud-init `chown`s them, but if you re-run containers by hand: `sudo chown -R 472:472 /opt/lab/grafana-data` and `sudo chown -R 65534:65534 /opt/lab/prometheus-data`. |

Handy one-liners on the victim:

```bash
sudo systemctl status httpd
curl -s localhost/server-status?auto
ss -tan state established '( sport = :80 )' | wc -l
sudo tail -f /var/log/lab-init.log
```

---

## Teardown

```bash
./scripts/down.sh            # or: make down
```

`tofu destroy` removes the VPC, all instances, the security groups, the IAM
role and the S3 asset bucket (it has `force_destroy = true`, so the objects go
with it). Afterwards, `make status` should fail to resolve anything, and this
should print nothing:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:LabName,Values=slowloris" \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

Worth checking out-of-band too, because a failed destroy is an expensive
silent failure:

* **EC2 → Instances**, filtered on tag `LabName = slowloris`
* **VPC**, for a `slowloris-vpc`
* **S3**, for `ddos-lab-assets-<account-id>-<region>`

---

## Repository layout

```
.
├── site/                     the demo website (static HTML/CSS/JS, no deps)
│   ├── index.html            the page, with a built-in availability probe
│   ├── app.js                client-side latency probe + canvas chart
│   └── style.css
├── attack/
│   ├── slowloris.py          half-open HTTP connection holder  <- the attack
│   ├── http_flood.py         volumetric contrast
│   └── README.md
├── monitoring/
│   ├── blackbox/blackbox.yml
│   ├── grafana/
│   │   ├── provisioning/     datasource + dashboard auto-provisioning
│   │   └── dashboards/slowloris-demo.json
│   ├── systemd/              node_exporter, apache_exporter, lab-slowloris
│   ├── docker-compose.yml    local fallback monitoring stack
│   └── prometheus.local.yml.example
├── infra/                    OpenTofu
│   ├── versions.tf providers.tf variables.tf locals.tf
│   ├── network.tf security.tf storage.tf compute.tf outputs.tf
│   └── templates/
│       ├── victim_apache.conf        the deliberately vulnerable config
│       ├── prometheus.yml.tftpl      EC2 service discovery, no hard-coded IPs
│       └── userdata_*.sh.tftpl       cloud-init per role
├── tools/
│   └── keepalive_probe.py    live warm-vs-cold connection probe (TUI)
└── scripts/                  up / down / status / attack / ssh
```

**How content gets onto the nodes:** `site/`, `attack/` and `monitoring/` are
mirrored into S3 and pulled down by cloud-init. EC2 `user_data` has a hard
16 KiB limit, and keeping the real files in S3 means you can edit the website or
tweak the attack scripts and just re-apply — no HCL changes. Prometheus finds its
targets with **EC2 service discovery** on the `LabName` tag rather than
hard-coded IPs, which also means the monitoring self-heals if you stop and start
an instance mid-class and it picks up a new address.

---

## Further reading

* [`mod_reqtimeout`](https://httpd.apache.org/docs/2.4/mod/mod_reqtimeout.html) —
  the module that decides whether your demo works at all
* [`mod_status`](https://httpd.apache.org/docs/2.4/mod/mod_status.html) — where
  the live connection counts come from
* [CWE-400: Uncontrolled Resource Consumption](https://cwe.mitre.org/data/definitions/400.html)
* [OWASP: Denial of Service](https://owasp.org/www-community/attacks/Denial_of_Service)
