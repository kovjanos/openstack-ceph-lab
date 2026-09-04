# Exercise 28 — Decommission the disk, and get the space back (web UI)

Guide section: [Exercise 28](../openstack-ceph-lab-exercise.md#exercise-28--decommission-the-disk-and-get-the-space-back)

The disk added in Exercise 21 has done its job. Draining and removing it is
routine; what it leaves behind is the lesson.

## Step 1 — Removing

Back on **Cluster → Hosts**, the host's ⋮ menu, in order:

1. **Start Drain** — moves daemons off the host and waits
2. **Remove** — takes it out of the cluster

![Hosts list with the actions menu](img/ex19-step01-ceph-hosts-list.png)

## Step 2 — What gets left behind

This is the exercise. Removing a node the quick way leaves at least three things:

- **A stranded monitor in the monmap.** `ceph -s` reports `1/4 mons down` forever.
  Visible on **Cluster → Monitors**; fixed with `ceph mon rm <node>`.
- **Too many PGs per OSD.** Fewer OSDs, same PG count:
  `too many PGs per OSD (307 > 250)`. Either reduce PGs or raise the limit with
  `ceph config set global mon_max_pg_per_osd 400`.
- **A `CEPHADM_REFRESH_FAILED` warning**, from cephadm still trying to inventory a host
  that is gone.

None of these are errors while the cluster is otherwise healthy, and all of them are
still there weeks later when something else fails. Check **Cluster → Hosts**,
**Monitors** and the **Overview** health panel after any removal.
