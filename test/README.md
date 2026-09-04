# End-to-end verification

Tears the lab down, rebuilds it from the kernel up, runs all 29 exercises, and records
disk and memory at every step. This is what produced the figures quoted in
[`../README.md`](../README.md) and the build guide's *Disk usage on macOS* section.

```bash
./test/run-e2e.sh
```

About 70 minutes on an M4: ~3 min kernel, ~8 min image, ~30 min provision, ~30 min
exercises. Results land in `test/results/<timestamp>/`, and nothing is written outside
that directory except the lab itself.

```bash
./test/report.py test/results/20260904-104500
```

## What it checks

Each part runs the guide's own commands and asserts on their output — 93 checks in
total. A part prints `PASS`/`FAIL` per assertion and a banner at the end.

| Script | Covers |
|---|---|
| `exercises/part-A-C.sh` | 1–8: bootstrap, the lab image, first workload, volumes, snapshots, security groups, floating IPs |
| `exercises/part-D-F.sh` | 9–17: load balancing, shared filesystem, object storage, encryption, Heat, quotas, tenants |
| `exercises/part-G.sh` | 18–28: RADOS, maintenance, credentials, adding a disk, failure drills, snapshots, replication, scrub, monitoring, decommissioning |
| `exercises/part-H.sh` | 29: filling the cluster and recovering from it |

The parts are ordered and stateful — Part G expects what Part D-F left behind — so run
them through `run-e2e.sh` rather than individually.

## Options

| Variable | Default | Effect |
|---|---|---|
| `SKIP_BUILD` | `0` | `1` runs only the exercises, against a lab already up |
| `OUT` | `test/results/<timestamp>` | where results go |
| `MACHINE` | `openstack-lab` | container machine name |

Provisioning knobs (`OSD_SIZE`, `CEPH_POOL_SIZE`, `ENABLE_NETWORK_LOADBALANCER`,
`MACHINE_MEMORY`) belong to the lab scripts and are documented there; export them and
`run-e2e.sh` passes them through.

## What the metrics collect

Three samplers write epoch-keyed CSVs that `report.py` joins:

| File | Interval | Contents |
|---|---|---|
| `disk.csv` | 30s | free space, container-store size, `rootfs.ext4` allocated blocks, OSD backing files |
| `ceph.csv` | 60s | `ceph df` raw total/used/stored, guest `df`, OSD apparent vs actual size, guest memory |
| `memory.csv` | 30s | VM `phys_footprint` and its kernel peak, `ps` RSS, host free, swap |

Two distinctions the report keeps separate, because conflating them gives wrong answers:

- **Allocated vs used.** The OSD files are sparse: they report their declared size but
  occupy only what Ceph has written. `osd_apparent_mb` against `osd_actual_mb` is the
  gap, and it is large — 21 GB declared against 3 GB real is normal early in a run.
- **`phys_footprint` vs RSS.** `phys_footprint` is what Activity Monitor shows and what
  a user must actually have free. RSS counts shared and file-backed mappings and reads
  several GB high. Both are recorded; quote the footprint.

## Reading the report

```
step                     start      dur     host store   VM img alloc   ceph used/alloc   peak footprint
4/5 provision           10:18:35   26m08s   7.2->29.4    3.2->24.5      0.0->2.4  /21             26.0
Ex9 one address...      10:51:15    6m02s  32.5->39.3   26.5->33.8      8.0->8.2  /21             26.0
```

Start and end values per step, so growth is attributable rather than aggregate, plus
wall-clock duration — which is how the "provisioning is 26 of the 70 minutes" figure in
the README was arrived at.
