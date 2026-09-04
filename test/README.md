# End-to-end verification

Tears the lab down, rebuilds it from the kernel up, runs all 29 exercises, and records
disk and memory at every step. This is what produced the figures quoted in
[`../README.md`](../README.md) and the build guide's *Disk usage on macOS* section.

```bash
./test/run-e2e.sh
```

1h39m on an M4 for the run recorded below: 11 min kernel, 21 min image, 33 min
provision, 34 min exercises. Results land in `test/results/<timestamp>/`, and nothing is
written outside that directory except the lab itself. The CSVs are not committed —
`report.py` turns them into the table in [The measured run](#the-measured-run), which is.

```bash
./test/report.py test/results/20260904-190141
```

## What it checks

Each part runs the guide's own commands and asserts on their output — 97 checks in
total. A part prints `PASS`/`FAIL` per assertion and a banner at the end.

| Script | Covers |
|---|---|
| `exercises/part-A-C.sh` | 1–8: bootstrap, the lab image, first workload, volumes, snapshots, security groups, floating IPs |
| `exercises/part-D-F.sh` | 9–17: load balancing, shared filesystem, object storage, encryption, Heat, quotas, tenants |
| `exercises/part-G.sh` | 18–28: RADOS, maintenance, credentials, adding a disk, failure drills, snapshots, replication, scrub, monitoring, decommissioning |
| `exercises/part-H.sh` | 29: filling the cluster and recovering from it |

Then **stage 6** stops the machine and starts it again: `lab-down` inside the VM, a
`container machine stop` that has to return on its own within five minutes, a check that
nothing is left running, and a restart verified by `provision-lab.sh --only 90-verify` —
which waits on Ceph, the keepalived VIP, keystone, nova-api and hypervisor registration.
It is the only stage that asserts the lab survives being switched off.

The parts are ordered and stateful — Part G expects what Part D-F left behind — so run
them through `run-e2e.sh` rather than individually.

## Options

| Variable | Default | Effect |
|---|---|---|
| `SKIP_BUILD` | `0` | `1` runs only the exercises, against a lab already up |
| `OUT` | `test/results/<timestamp>` | where results go |
| `MACHINE` | `openstack-lab` | container machine name |
| `MACHINE_MEMORY` | `26G` | passed to `02-build-image.sh`; recorded in `CONFIG` and used to label the report's memory column |

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

## The measured run

`20260904-190141`, at commit `053f6cf`, with the defaults: `OSD_SIZE=5G`,
`CEPH_POOL_SIZE=2`, load balancer on, 8 CPUs and 26 GB to the machine. **97 checks, none
failing, 1h39m.** Every disk and memory figure quoted in [`../README.md`](../README.md),
the build guide and the exercise guide comes from this table.

```
step                          start     dur    host store   VM img alloc    VM fs used    ceph used/alloc  peak footprint  peak rss  peak guest/26G
-------------------------------------------------------------------------------------------------------------------------------------
1/5 teardown               19:01:42    0m00s   5.4->5.4       0.0->0.0      0.0->0.0        0.0->0.0  /0               0.0       0.0            0.0
2/5 kernel                 19:02:12   11m02s   5.4->9.2       0.0->0.0      0.0->0.0        0.0->0.0  /0               4.5       7.1            0.0
3/5 image                  19:13:44   20m34s   9.2->8.9       0.0->0.0      0.0->1.9        0.0->0.0  /0               2.2       4.1            0.5
4/5 provision              19:34:48   32m38s   8.9->34.9      3.2->26.0     3.0->27.9       0.0->2.7  /15             26.0      37.7           13.9
Ex2 build the lab image    20:07:56    0m00s  34.9->34.9     26.1->26.1    27.9->27.9       2.7->2.7  /15             26.0      25.5           13.9
Ex3 a first workload       20:08:26    1m00s  34.9->33.3     27.6->27.7    28.6->28.6       3.3->3.3  /15             26.0      26.5           14.8
Ex5 snapshot and restore   20:09:56    0m30s  33.3->33.3     27.7->27.7    28.6->28.2       3.3->2.9  /15             26.0      26.7           14.8
Ex6 grow a volume          20:10:56    0m00s  33.3->33.3     27.7->27.7    28.2->28.2       2.9->2.9  /15             26.0      17.3           14.4
Ex7 network isolation      20:11:27    1m31s  33.3->34.0     27.7->28.4    29.1->29.1       3.7->3.8  /15             26.0      19.9           15.4
Ex8 floating IP failover   20:13:28    0m00s  34.0->34.0     28.4->28.4    28.3->28.3       3.0->3.0  /15             26.0      19.2           14.8
Ex9 one address, two serv  20:13:58    5m01s  34.0->40.9     28.1->35.4    28.3->36.0       3.0->8.2  /15             26.0      26.3           18.4
Ex10 sticky sessions       20:19:29    0m30s  41.0->41.0     35.4->35.4    34.3->34.3       8.2->8.2  /15             26.0      23.8           17.7
Ex11 the load balancer di  20:20:29    5m02s  41.0->43.0     35.4->37.5    35.2->31.3       6.2->5.6  /15             26.0      24.6           18.7
Ex12 shared filesystem ov  20:26:01    0m30s  43.0->43.0     31.1->31.1    32.2->32.2       4.5->4.5  /15             26.0      25.6           17.4
Ex14 encryption at rest    20:27:01    0m30s  36.7->36.7     31.1->31.2    32.3->32.3       4.5->4.5  /15             26.0      26.5           17.6
Ex15 Heat                  20:28:01    1m00s  36.7->36.7     31.7->31.7    32.6->32.2       4.9->4.6  /15             26.0      26.3           17.8
Ex16 quotas                20:29:32    0m00s  36.7->36.7     31.2->31.2    32.2->32.2       4.6->4.6  /15             26.0      26.3           17.7
Ex18 RADOS: a volume is o  20:30:02    0m30s  36.7->36.7     31.2->31.2    32.2->32.2       4.5->4.5  /15             26.0      26.5           17.5
Ex21 extend the cluster w  20:31:02    1m30s  36.7->40.0     31.2->35.2    33.3->34.4       4.2->4.2  /20             26.0      26.3           17.8
Ex22 lose the added disk   20:33:02    0m00s  40.0->40.0     35.6->35.6    34.5->34.5       4.2->4.2  /15             26.0      24.6           17.8
Ex23 replace the added di  20:33:32    0m00s  40.0->40.0     36.1->36.1    34.5->34.5       4.2->4.2  /15             26.0      24.6           17.8
Ex25 replication cost: 2   20:34:02    0m00s  40.0->40.0     36.6->36.6    35.2->35.2       4.2->4.2  /15             26.0      24.4           17.5
Ex28 decommission the add  20:34:33    0m30s  42.2->42.2     36.6->37.0    35.2->34.9       4.2->5.9  /15             26.0      24.5           17.6
Ex29 lower the ratios so   20:35:33    0m00s  42.2->42.2     31.0->31.0    34.9->34.9       5.9->5.9  /15             26.0      24.2           17.6
Ex29 fill the cluster      20:36:03    3m00s  42.2->44.4     36.6->39.1    39.8->40.1      11.0->11.0 /15             26.0      24.9           17.6
Ex29 the deadlock -- dele  20:39:34    1m00s  44.7->44.7     39.1->39.1    40.1->33.3      11.0->4.3  /15             26.0      25.0           17.6
Ex29 the way out -- raise  20:41:04    0m00s  44.7->44.7     39.2->39.2    33.3->33.3       4.3->4.3  /15             26.0      25.0           17.6
-------------------------------------------------------------------------------------------------------------------------------------
PEAK / TOTAL               19:01:42   99m22s         44.7          39.2         40.1            11.0           26.0      37.7           18.7

  all figures GB.  host store = what macOS allocated.  VM img alloc = rootfs.ext4 real blocks.
  VM fs used = df inside the guest.  ceph used/alloc = raw used vs raw capacity.
  peak footprint = macOS phys_footprint (Activity Monitor).  peak rss = ps RSS.
  peak guest/26G = memory in use inside the VM, against its 26 GB allocation.
```

Reading it:

- **Host store peaks at 44.7 GB**, during Exercise 29, and it is a high-water mark — the
  sparse image never shrinks, so this is the free space a user needs, not what is in use
  at the end.
- **Provision is the expensive step**, 8.9 to 34.9 GB. Kolla's container images are most
  of it, and they are on disk before any exercise runs.
- **Guest memory peaks at 18.7 GB of 26**, in Exercise 11, with two 512 MB backends and
  three amphorae briefly alive during the failover rebuild. Nothing later comes near it.
- **`peak footprint` sits at 26.0 GB from provision onward.** That is the whole
  allocation: macOS shows the VM at its full size regardless of what the guest is using,
  which is why the two memory columns answer different questions. The footprint is what
  a user must have free; `peak guest/26G` is what tells you whether 26 GB is the right
  number to ask for.
- **Steps showing `0m00s`** were shorter than the 30s sampling interval. They still
  bracket correctly, but their growth is attributed to the neighbouring step.
