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

The Ceph dashboard uses a self-signed certificate. Your browser will warn; accept it
once per address. Because the address changes, you will accept it again after a
restart.

The screenshots below were taken at `192.168.64.62`. Yours will differ — the addresses
inside instances (`10.0.0.x`) and floating IPs (`172.24.4.x`) will differ too.

## Which UI covers what

- **Horizon** covers exercises 1–8 and 11–14: networks, instances, volumes, security
  groups, Heat, quotas, projects.
- **The Ceph dashboard** covers exercises 9, 10 and 15–24: file systems, object
  gateway, hosts, OSDs, pools, logs.
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
| 9 — Shared filesystem | [ex09-shared-filesystem.md](ex09-shared-filesystem.md) | Ceph |
| 10 — Object storage | [ex10-object-storage.md](ex10-object-storage.md) | Ceph |
| 11 — Encryption at rest | [ex11-encrypted-volume.md](ex11-encrypted-volume.md) | Horizon |
| 12 — Heat | [ex12-heat.md](ex12-heat.md) | Horizon |
| 13 — Quotas | [ex13-quotas.md](ex13-quotas.md) | Horizon |
| 14 — A second tenant | [ex14-second-tenant.md](ex14-second-tenant.md) | Horizon |
| 15 — Ceph maintenance mode | [ex15-maintenance-mode.md](ex15-maintenance-mode.md) | Ceph |
| 16 — Restricted Ceph user | [ex16-restricted-ceph-user.md](ex16-restricted-ceph-user.md) | Ceph |
| 17 — Lose a disk | [ex17-lose-a-disk.md](ex17-lose-a-disk.md) | Ceph |
| 18 — Replace a disk | [ex18-replace-a-disk.md](ex18-replace-a-disk.md) | Ceph |
| 19 — CephFS snapshots | [ex19-cephfs-snapshots.md](ex19-cephfs-snapshots.md) | Ceph |
| 20 — What replication costs | [ex20-replication-cost.md](ex20-replication-cost.md) | Ceph |
| 21 — Verify the data | [ex21-scrub.md](ex21-scrub.md) | Ceph |
| 22 — The monitoring you have | [ex22-monitoring.md](ex22-monitoring.md) | Ceph |
| 23 — Add and remove a node | [ex23-add-remove-node.md](ex23-add-remove-node.md) | Ceph |
| 24 — Recover a full cluster | [ex24-full-cluster.md](ex24-full-cluster.md) | Ceph |

## Screenshot naming

`ex<NN>-step<NN>-<panel>-<what>.png`, all in [`img/`](img). The exercise number matches
the guide, the step number is the order within this walkthrough, and the rest names the
panel and the action.

## Where the UI stops

Three things in the exercises have no web UI at all, and the files say so where it
matters:

- **Barbican** has no Horizon panel in this deployment. Encrypted *volumes* are
  visible; the secrets behind them are CLI only.
- **The object gateway is not registered in Keystone**, so Horizon has no object store
  panel. Buckets are managed from the Ceph dashboard or `s3cmd`.
- **The OSD full ratios** (`ceph osd set-full-ratio`) live in the OSD map, not the
  config database, so they do not appear on the dashboard's Configuration page.
