# OpenStack & 3-node Ceph lab on Apple Silicon

A complete, restart-proof OpenStack cloud backed by a 3-node Ceph cluster, running
inside a single Apple `container` machine on an M-series Mac. Three scripts build it;
two guides explain it; 24 day-2 exercises give you something to do with it.

This is a lab, not a production reference. It is sized to fit on one laptop and every
shortcut it takes is stated in the build guide.

## What you get

```
macOS (Apple Silicon, macOS 26)
  └─ container machine "openstack-lab" — Ubuntu 24.04 ARM64, /dev/kvm, device-mapper
       ├─ loop0/1/2 → ceph-vg1/2/3 → LVs osd1/osd2/osd3 (15 GiB each)
       ├─ incusbr0  10.100.0.0/24
       ├─ ceph-node1  10.100.0.11   mon, mgr, osd.0, RGW, NFS-Ganesha
       ├─ ceph-node2  10.100.0.12   mon, mgr standby, osd.1
       └─ ceph-node3  10.100.0.13   mon, osd.2
```

- **Ceph 20.2.2 (tentacle)** deployed by `cephadm` into Incus system containers, on
  LVM-backed loop devices — 3 mons, 3 OSDs, 45 GiB raw, MDS, RGW
- **OpenStack 2026.1** via Kolla-Ansible `stable/2026.1`: Keystone, Glance, Nova,
  Neutron, Placement, Cinder, Barbican, Heat, Horizon
- **Everything on Ceph RBD** — Glance images, Cinder volumes, Nova root disks
- **S3** through Ceph RGW, and **NFSv4.1** through CephFS + NFS-Ganesha
- **Neutron ML2/OVS** with a flat external network on `br-ex` and VXLAN tenant
  networks, so floating IPs work from macOS
- Survives a machine restart, including device renumbering

## Requirements

| | |
|---|---|
| Hardware | Apple Silicon M3 or later |
| macOS | 26 |
| Tooling | Apple [`container`](https://github.com/apple/container) CLI 1.3.1+ |
| Memory | 24 GB to the machine minimum, 28 GB comfortable, 32 GB on a 48 GB Mac |
| Disk | ~90 GB free during the build |
| Time | A few hours, nearly all of it pulling Kolla's container images |

`MACHINE_CPUS` and `MACHINE_MEMORY` in `02-build-image.sh` set the machine's size.

## Quick start

```bash
git clone https://github.com/kovjanos/openstack-ceph-lab.git
cd openstack-ceph-lab

./01-build-kernel.sh     # macOS. Produces vmlinux-arm64, then cleans up after itself.
./02-build-image.sh      # macOS. Builds the image and creates the machine.
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh
```

The third script runs inside the VM and is baked into the image, so after logging in
(`container machine run -n openstack-lab`, then `sudo -i`) you can just run
`provision-lab`.

It is checkpointed per phase under `/var/lib/openstack-lab/state`, so a failed run
resumes where it stopped:

```bash
provision-lab --list             # phases and their state
provision-lab --from 50-ceph     # re-run from a phase onward
provision-lab --only 90-verify   # print the current URLs and passwords
```

`--only 90-verify` is also how you get back in after a restart — **the machine's IP
address changes every time it starts**, so read it fresh rather than reusing an old
one.

## Repository layout

| Path | What it is |
|---|---|
| `01-build-kernel.sh` | Builds `vmlinux-arm64` from `apple/containerization`. The stock kernel has no device-mapper, which makes LVM — and therefore Ceph — impossible. |
| `02-build-image.sh` | Builds `local/ubuntu-machine:latest` and creates the `openstack-lab` machine. Everything needed at boot is baked into the image. |
| `03-provision.sh` | Runs in the VM. Eleven checkpointed phases from loop devices to a verified cloud. |
| `sync-provision.sh` | Pushes an edited `03-provision.sh` into the machine without rebuilding the image. |
| `openstack-ceph-lab-build.md` | The build guide: every phase, why it is done that way, and what breaks otherwise. |
| `openstack-ceph-lab-exercise.md` | 24 day-2 exercises, each with a real incident behind it, CLI steps, the web-UI equivalent, and cleanup. |
| `walkthrough/` | Screenshots of the web-UI side of every exercise, one Markdown file per exercise. |

Both build scripts delete the BuildKit cache as their last step. That is not
housekeeping for its own sake — BuildKit is a persistent container with a 42 GB ext4
rootfs and no cache eviction, and it is where most of the 129 GB this lab once
occupied had accumulated.

## The exercises

`openstack-ceph-lab-exercise.md` is the reason the lab exists. Each exercise opens
with the day-2 situation it covers, so you know why you are doing it:

| Part | Exercises |
|---|---|
| A. Foundation | bootstrap the tenant · build the lab image |
| B. One workload | first workload · persistent disk · snapshot & restore · grow a volume |
| C. Two workloads | network isolation · floating-IP failover · shared NFS · object storage |
| D. Platform operations | encrypted volumes with Barbican · Heat · quotas · projects & RBAC |
| E. Ceph day-2 | maintenance mode · restricted credentials · failure drill · disk replacement · CephFS snapshots · replication cost · scrub · monitoring · node add/remove |
| F. Recovery | recovering a cluster that has filled up |

Peak cost is two 512 MB guests. The lab image is a 248 MB Alpine build, not a distro
cloud image — Exercise 2 explains why and how it is made.

[`walkthrough/`](walkthrough/README.md) has the same exercises driven through Horizon
and the Ceph dashboard, with screenshots of each step.

## Getting in

```bash
# a shell in the machine
container machine run -n openstack-lab

# run something headless (the only form that works from a background job)
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh
```

Inside the VM, the OpenStack client needs this wrapper:

```bash
OS() { sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && \
  OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin exec openstack "$@"' _ "$@"; }
```

The trailing `_ "$@"` matters. Interpolating `$*` into the quoted string loses quoting,
and any argument containing a space is silently split.

Ceph commands go through `incus exec ceph-node1 -- cephadm shell --`.

## Web UIs

| UI | URL | Login |
|---|---|---|
| Horizon | `http://<vm-ip>:8080/` | `admin`, domain `Default` |
| Ceph dashboard | `https://<vm-ip>:8443/` | `admin` |
| Grafana | `https://<vm-ip>:3000/` | none — anonymous viewing |
| Prometheus | `http://<vm-ip>:9095/` | none |
| Alertmanager | `http://<vm-ip>:9093/` | none |

Every address and both passwords are printed by `provision-lab --only 90-verify`.

The monitoring stack is what `cephadm` deployed at bootstrap — nothing extra is
installed. The Ceph dashboard embeds Grafana's panels, so open `https://<vm-ip>:3000/`
once and accept its certificate before using any "Overall Performance" tab; it is a
different self-signed certificate from the dashboard's.

## License

Two licenses, split by what the file is:

- **Documentation, guides, walkthrough text and screenshots** — [CC BY 4.0](LICENSE).
  Use, share and adapt them anywhere, including commercially, as long as you credit the
  source.
- **Scripts (`*.sh`)** — [MIT](LICENSE-CODE).

Both require attribution. See [LICENSE](LICENSE) for how to credit.
