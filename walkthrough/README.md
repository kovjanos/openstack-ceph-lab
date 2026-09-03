# Web UI walkthrough

Screenshots of the exercises in [`../openstack-ceph-lab-exercise.md`](../openstack-ceph-lab-exercise.md)
driven through the two web UIs. Every screen here was captured against the running
lab while actually performing the step — nothing is mocked.

Use this beside the exercise guide, not instead of it. The guide has the commands, the
reasoning and the cleanup; this shows where the same thing lives in the UI and what the
result looks like.

## Getting to the UIs

The VM's address changes on every start, so read it fresh:

```bash
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh --only 90-verify
```

That prints both URLs and both passwords:

| UI | URL | Login |
|---|---|---|
| Horizon (OpenStack) | `http://<vm-ip>:8080/` | `admin`, domain `Default` |
| Ceph dashboard | `https://<vm-ip>:8443/` | `admin` |
| Grafana | `https://<vm-ip>:3000/` | none — anonymous viewing |
| Prometheus | `http://<vm-ip>:9095/` | none |
| Alertmanager | `http://<vm-ip>:9093/` | none |

**The exercises' own workloads are not reachable from the Mac.** Floating IPs
(`172.24.4.x`) sit behind `br-ex` with no route from macOS, so a web server you launch
cannot be opened in your browser until you publish it: `lab-expose 18080 <floating-ip>`
inside the VM, then `http://<vm-ip>:18080/`. Every UI in the table above is already
forwarded and needs nothing.

Load balancing adds no URL of its own — it is a panel inside Horizon, under
Project → Network → Load Balancers. Octavia's API is on 9876, bound to the internal VIP
and not reachable from macOS.

**Two separate certificates.** The Ceph dashboard (8443) and Grafana (3000) each have
their own self-signed certificate. Accept both — and accept 3000 *before* opening any
"Overall Performance" tab, or the embedded Grafana panels render as empty grey frames
with no error. Because the VM address changes on every start, both exceptions have to
be accepted again after a restart.

The screenshots below were taken at `192.168.64.62`. Yours will differ — the addresses
inside instances (`10.0.0.x`) and floating IPs (`172.24.4.x`) will differ too.

## Which UI covers what

- **Horizon** covers exercises 1–11 and 14–17: networks, instances, volumes, security
  groups, load balancers, Heat, quotas, projects.
- **The Ceph dashboard** covers exercises 12, 13 and 18–27: file systems, object
  gateway, hosts, OSDs, pools, logs, and the embedded Grafana panels.
- Some steps have no UI at all. Where that is true the file says so rather than
  inventing a substitute.

## Index

| Exercise | Walkthrough | UI |
|---|---|---|
| 1 — Bootstrap the tenant | [ex01-bootstrap.md](ex01-bootstrap.md) | Horizon |
| 2 — Build the lab's own image | [ex02-lab-image.md](ex02-lab-image.md) | Horizon |
| 3 — A first workload | [ex03-first-workload.md](ex03-first-workload.md) | Horizon |
| 4 — Persistent storage | [ex04-persistent-storage.md](ex04-persistent-storage.md) | Horizon + Ceph |
| 5 — Snapshot and restore | [ex05-snapshot-restore.md](ex05-snapshot-restore.md) | Horizon |
| 6 — Grow a volume in use | [ex06-grow-volume.md](ex06-grow-volume.md) | Horizon |
| 7 — Network isolation | [ex07-network-isolation.md](ex07-network-isolation.md) | Horizon |
| 8 — Floating IP failover | [ex08-floating-ip-failover.md](ex08-floating-ip-failover.md) | Horizon |
| 9 — One address, two servers † | [ex09-loadbalancer.md](ex09-loadbalancer.md) | Horizon |
| 10 — Sticky sessions † | [ex10-sticky-sessions.md](ex10-sticky-sessions.md) | Horizon |
| 11 — The load balancer died † | [ex11-lb-failover.md](ex11-lb-failover.md) | Horizon + CLI |
| 12 — Shared filesystem | [ex12-shared-filesystem.md](ex12-shared-filesystem.md) | Ceph |
| 13 — Object storage | [ex13-object-storage.md](ex13-object-storage.md) | Ceph |
| 14 — Encryption at rest | [ex14-encrypted-volume.md](ex14-encrypted-volume.md) | Horizon |
| 15 — Heat | [ex15-heat.md](ex15-heat.md) | Horizon |
| 16 — Quotas | [ex16-quotas.md](ex16-quotas.md) | Horizon |
| 17 — A second tenant | [ex17-second-tenant.md](ex17-second-tenant.md) | Horizon |
| 18 — RADOS underneath it all | [ex18-rados.md](ex18-rados.md) | Ceph |
| 19 — Ceph maintenance mode | [ex19-maintenance-mode.md](ex19-maintenance-mode.md) | Ceph |
| 20 — Restricted Ceph user | [ex20-restricted-ceph-user.md](ex20-restricted-ceph-user.md) | Ceph |
| 21 — Lose a disk | [ex21-lose-a-disk.md](ex21-lose-a-disk.md) | Ceph |
| 22 — Replace a disk | [ex22-replace-a-disk.md](ex22-replace-a-disk.md) | Ceph |
| 23 — CephFS snapshots | [ex23-cephfs-snapshots.md](ex23-cephfs-snapshots.md) | Ceph |
| 24 — What replication costs | [ex24-replication-cost.md](ex24-replication-cost.md) | Ceph |
| 25 — Verify the data | [ex25-scrub.md](ex25-scrub.md) | Ceph |
| 26 — The monitoring you have | [ex26-monitoring.md](ex26-monitoring.md) | Ceph + Grafana + Prometheus |
| 27 — Add and remove a node | [ex27-add-remove-node.md](ex27-add-remove-node.md) | Ceph |
| 28 — Recover a full cluster | [ex28-full-cluster.md](ex28-full-cluster.md) | Ceph |

† needs the load-balancer build, which is on by default. Built with
`ENABLE_NETWORK_LOADBALANCER=no`? Add it with
`ENABLE_NETWORK_LOADBALANCER=yes provision-lab --from 70-kolla`, or skip these three —
the end of Exercise 9 covers the same ground with HAProxy in a guest.

## Where the UI stops

Three things in the exercises have no web UI at all, and the files say so where it
matters:

- **Barbican** has no Horizon panel in this deployment. Encrypted *volumes* are
  visible; the secrets behind them are CLI only.
- **The object gateway is not registered in Keystone**, so Horizon has no object store
  panel. Buckets are managed from the Ceph dashboard or `s3cmd`.
- **The OSD full ratios** (`ceph osd set-full-ratio`) live in the OSD map, not the
  config database, so they do not appear on the dashboard's Configuration page.
