# A DDoS doesn’t have to be loud

When people picture a denial-of-service attack, they often imagine a huge wall of traffic overwhelming a network. That can happen—but it isn’t the only way to make a service unavailable. Sometimes the more interesting question is: *what limited resource is the server waiting on?*

For our cybersecurity class, we built an isolated AWS lab to explore that question. One machine hosted a deliberately vulnerable Apache website, three machines acted as clients, and a separate observer ran Prometheus and Grafana. We used the lab to demonstrate **Slowloris**, an application-layer denial-of-service technique that keeps server connections occupied with very little traffic.

## From one client to many

A denial of service (DoS) aims to make a service unavailable. A distributed denial of service (DDoS) has the same goal, but traffic comes from multiple systems. Distribution can make it harder to distinguish attack traffic from ordinary clients and can increase the number of simultaneous requests or connections.

Not every DDoS is a bandwidth flood. Some attacks exhaust a resource the application needs: CPU, memory, database connections, or—as in this demo—the server’s capacity to handle open connections. Slowloris is a useful example because the traffic rate can stay low while the impact grows.

## What Slowloris asks the server to do

An HTTP client normally sends a request line and headers, followed by a blank line that tells the server the headers are complete. Slowloris opens a connection, sends part of that request, and then deliberately leaves it unfinished. It occasionally adds another small header so the connection stays open.

Our victim used Apache’s **prefork** model, where each active connection is handled by a worker process. We configured a small limit of 40 workers and disabled the request-read timeout that would otherwise close slow, incomplete requests. Each Slowloris connection could therefore keep a worker waiting. When the workers were occupied, new connections struggled to get service—even though the network graph showed little traffic.

> **[Hand-drawn image: A normal request arriving complete. Show an Apache worker accepting it, returning the page, and becoming available again.]**

> **[Hand-drawn image: Slowloris connections arriving from three clients. Show each incomplete request holding a worker while Apache waits for the missing end-of-headers blank line.]**

> **[Hand-drawn image: All 40 workers occupied. Show new visitors waiting or timing out, while network traffic remains low.]**

## How we ran the demonstration

- **Provision the lab.** OpenTofu creates a private network, the Apache victim, three client machines, and an observer with Prometheus and Grafana. The three clients make the demonstration distributed; the separate observer can keep monitoring while the victim is under pressure.
- **Establish a baseline.** We open the demo site and Grafana before starting the clients. Apache’s exporter reports busy and idle workers, node_exporter reports host metrics, and a blackbox probe independently requests the site. These give us several views of normal behavior.
- **Start Slowloris.** We run `./scripts/attack.sh start`. The clients open incomplete HTTP requests to the victim and keep them alive. We watch Apache’s busy-worker count rise and its idle-worker count fall.
- **Read the impact.** The Apache scoreboard’s `read` state shows workers waiting for request data. The blackbox probe shows whether a new visitor can fetch the page. Network throughput remains low: the attack is exhausting connection-handling capacity, not trying to fill the network pipe.
- **Stop and recover.** We run `./scripts/attack.sh stop`, then watch connections close, workers become available, and the site probe recover. Finally, we destroy the AWS resources.

> **[Embed YouTube demo here]**

One brief surprise: a browser tab opened before the attack sometimes kept working while new `curl` requests timed out. Its keep-alive connection was already established, while fresh requests needed new worker capacity. It’s a useful reminder that one successful request from an existing connection does not prove a service is available to everyone.

## What the demo teaches—and what it doesn’t

Slowloris makes resource exhaustion visible: the server can be short of workers without being short of bandwidth. A sensible request-read timeout helps by refusing to wait indefinitely for incomplete headers. A reverse proxy that buffers complete requests can also prevent slow clients from tying up application workers. Increasing the worker limit may delay the failure, but it does not address why those workers are being held.

This small lab is not a model of every DDoS attack. Real incidents may involve massive traffic volumes, many compromised devices, or multiple techniques at once. But Slowloris is a good starting point for asking a broader security question: **what resource does this service depend on, and how cheaply can an attacker make it wait?**

*We ran the demonstration only against our own isolated lab.*

## References

- [Apache `mod_reqtimeout`](https://httpd.apache.org/docs/2.4/mod/mod_reqtimeout.html) — request-read timeouts and protection against slow clients.
- [Apache `mod_status`](https://httpd.apache.org/docs/2.4/mod/mod_status.html) — worker and scoreboard status used to observe the victim.
- [Apache prefork MPM](https://httpd.apache.org/docs/2.4/mod/prefork.html) — the process-per-connection model used in the lab.
- [CWE-400: Uncontrolled Resource Consumption](https://cwe.mitre.org/data/definitions/400.html) — the broader weakness illustrated by resource exhaustion.
- [Prometheus documentation](https://prometheus.io/docs/introduction/overview/) and [blackbox exporter](https://github.com/prometheus/blackbox_exporter) — metrics collection and external HTTP probes.
- [OpenTofu documentation](https://opentofu.org/docs/) — infrastructure provisioning.

## Acknowledgements

I would like to thank the **School of Computer Science and Engineering (SCOPE), Vellore Institute of Technology, Chennai**, for offering the Cyber Security course during Fall Semester 2026–2027 with an industry-standard syllabus. I also gratefully acknowledge the course faculty, **Dr. T. Subbulakshmi, Professor, SCOPE, VIT Chennai**, for her guidance.
