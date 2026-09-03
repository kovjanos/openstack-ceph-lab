# Exercise 22 — The monitoring you already have (web UI)

Guide section: [Exercise 22](../openstack-ceph-lab-exercise.md#exercise-22--the-monitoring-you-already-have)

You want graphs of cluster throughput and OSD latency and you are about to install
Prometheus. You do not need to: `cephadm` deployed Prometheus, Grafana, Alertmanager
and node-exporter when it bootstrapped the cluster.

## Step 1 — The landing page

`https://<vm-ip>:8443/` → **Overview**.

![Ceph dashboard overview](img/ex22-step01-ceph-dashboard-overview.png)

Everything a status page should have, in one screen:

- **Details** — cluster ID, orchestrator, and the exact Ceph version (20.2.2 tentacle)
- **Status** — the health check, green here
- **Capacity** — 4.2 GiB of 45 GiB raw. This is raw, before replication; Exercise 20
  explains why the usable figure is much smaller
- **Cluster Utilization** — throughput, IOPS and OSD apply/commit latency over the last
  hour. These are the Grafana panels, embedded
- **Inventory** — hosts, monitors, OSDs, pools, gateways, each linking to its page

## Step 2 — Logs

**Observability → Logs.**

![Ceph cluster logs](img/ex22-step02-ceph-cluster-logs.png)

Three tabs, and the distinction matters when you are answering "who did this?":

- **Cluster Logs** — what the cluster did to itself: pgmap updates, scrub results,
  health transitions
- **Audit Logs** — who issued which command, including everything the dashboard does
  on your behalf
- **Daemon Logs** — per-daemon output

Filters for priority, keyword, date and time range are above the tabs, and the icons on
the right export or copy the current view.

## Where to look for what

- **Cluster → OSDs** — per-OSD latency and utilisation; first stop when something is
  "slow"
- **Cluster → Hosts → Overall Performance** — throughput and IOPS per host
- **Cluster → Pools** — per-pool usage and MAX AVAIL
- **Object → Buckets** — the S3 side

Re-run the failure drill from Exercise 17 with the Overview open. Watching the degraded
count climb and drain away is much clearer than `ceph -s` in a loop.

**Alerting exists too.** Alertmanager is deployed with the default Ceph rules — full
OSDs, down daemons, slow ops. It has no receiver configured, so nothing is delivered.
Wiring one up is the natural next step beyond this lab.
