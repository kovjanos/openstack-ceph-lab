# OpenStack & 3-Node Ceph Lab on macOS Apple Silicon M4

Ubuntu 24.04 ARM64 with nested KVM on an M4 Mac, a 3-node Ceph cluster in Incus
system containers, and OpenStack backed by Ceph RBD.

> **Companion guide:** `openstack-ceph-lab-exercise.md` — day-2 exercises to run once
> this is built (workloads, storage, networking, Ceph disk and node operations).

## Run it with the scripts

The whole lab is three scripts. The phase-by-phase text below is the reference for
what they do and why; you do not need to work through it by hand.

```bash
cd ~/openstack-ceph-lab
./01-build-kernel.sh     # macOS. Produces vmlinux-arm64, then cleans up after itself.
./02-build-image.sh      # macOS. Builds local/ubuntu-machine:latest and creates the machine.
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh
```

| Script | Runs on | Produces | Removes on exit |
|---|---|---|---|
| `01-build-kernel.sh` | macOS | `vmlinux-arm64` | the checkout, `kernel-build:0.1` and its base, the BuildKit cache |
| `02-build-image.sh` | macOS | `local/ubuntu-machine:latest`, machine `openstack-lab` | the build context, `ubuntu:24.04`, the BuildKit cache |
| `03-provision.sh` | in the VM, as root | Ceph cluster + OpenStack | nothing — it is the lab |
| `sync-provision.sh` | macOS | pushes an edited `03-provision.sh` into the machine | — |

Both build scripts delete the BuildKit cache as their last step. That is not
housekeeping for its own sake: BuildKit is a persistent container with its own 42 GB
ext4 rootfs and no cache eviction, and it is where most of the 129 GB this lab once
occupied had accumulated.

`03-provision.sh` is checkpointed per phase under `/var/lib/openstack-lab/state`, so a
failed run resumes where it stopped rather than starting over. `--list` shows the
phases, `--from <phase>` re-runs from one onward, `--reset` forgets the checkpoints
without deleting anything.

| Phase | Does | Section |
|---|---|---|
| `10-storage` | loop devices, LVM, confirms the holds | 2 |
| `20-incus` | daemon init, pins `incusbr0` to 10.100.0.0/24 | 3.1–3.2 |
| `30-nodebase` | builds and publishes `ceph-node-base` | 3.3 |
| `40-nodes` | launches the three nodes, device passthrough, symlinks, repair unit | 3.4–3.10 |
| `50-ceph` | bootstrap, hosts, OSDs, pools, cephx users | 4.1–4.5 |
| `60-hostclient` | `/etc/ceph` on the VM, keyring checks | 4.6 |
| `70-kolla` | deploy user, venv, `globals.yml`, per-service Ceph config | 5.2–5.5 |
| `80-deploy` | `bootstrap-servers`, `prechecks`, `deploy`, `post-deploy` | 5.6 |
| `85-rgw` | Ceph RGW, S3 user, proxy device, s3cmd round trip | 7 |
| `86-nfs` | CephFS, NFS-Ganesha cluster, v4 export, mount test | 8 |
| `90-verify` | cluster health, service list, hypervisor, dashboards, S3/NFS | 6 |

### Getting in and out of the machine

`container machine run` has three ways to reach inside, and they are not
interchangeable. Getting this wrong wastes real time, because two of the three fail
*silently*.

| Form | Works | Use it for |
|---|---|---|
| `run -n m --root -- /path/to/script.sh` | always, including headless | **running** things |
| `run -n m -i --root -- bash < script.sh` | only with a controlling terminal | **delivering** things |
| `run -n m -- sh -c 'cmd'` | never | nothing |

**Run by path.** This is the only form that works from a background job, a cron entry
or a script whose output is redirected. It is why `03-provision.sh` and
`verify-lab.sh` are baked into the image.

**Deliver by stdin, from an interactive shell.** `-i` needs a controlling terminal; a
backgrounded script gets `Error: The operation couldn't be completed. Inappropriate
ioctl for device`. Drop the `-i` and it does not fail — it reads no stdin at all and
exits 0 having done nothing, so a stdin-fed health check "passes" by doing nothing.

**Never pass a command as arguments.** `container machine run -n m -- sh -c 'echo
$(id -u)'` produces empty output rather than running the command; multi-word arguments
are mangled. A single executable path is fine, arguments after it are fine
(`provision-lab.sh --list` works); an inline shell command is not.

Also note the first exec right after `container machine create` can fail with
`Operation not supported by device` — the create call returns before the machine will
accept one. That is a readiness race, not a fault; retry.

**Editing the provisioning script without rebuilding the image:**

```bash
./sync-provision.sh     # pushes 03-provision.sh in over stdin
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh
```

**The macOS home directory is not mounted.** The machine is created with
`--home-mount none`. `--home-mount` is the only mount a machine supports and it takes
`ro`, `rw` or `none` — there is no way to bind-mount an arbitrary directory, so a
shared folder is not an option. Everything the VM needs is either baked into the image
or pushed in with `sync-provision.sh`.

**Status**

| Phase | State |
|---|---|
| 0–4: kernel, machine, Incus, Ceph cluster | **Verified** — reaches HEALTH_OK from a clean build |
| Restart recovery (Ceph) | **Verified** — HEALTH_OK after `container machine stop`/`run` with no manual steps |
| 5: OpenStack via Kolla-Ansible | **Verified** — 35 containers, 7 services, hypervisor registered |
| Restart recovery (OpenStack) | **Verified** — the whole cloud returns unattended |
| 6: Verification | **Verified** — services, compute, hypervisor, and both dashboards reachable from macOS |
| 7: Ceph RGW / S3 | **Verified** — phase `85-rgw`; s3cmd put/get round trip, survives a machine restart |
| 8: CephFS + NFSv4 | **Verified** — phase `86-nfs`; export mounted and read/written, survives a machine restart |
| Monitoring (Grafana / Prometheus / Alertmanager) | **Verified** — proxied by `90-verify`; embedded panels render, URLs re-point themselves after the VM address changes |
| Octavia / load balancing | **Verified** — `ACTIVE_STANDBY`, amphora image built for aarch64; on by default, `ENABLE_NETWORK_LOADBALANCER=no` to skip |
| Manila (shared filesystems API) | Deferred to v3; CephFS + NFS covers the capability without it |

Built and verified from scratch on 2026-09-02: kernel `6.18.5-cz-fc9e63846f36`, Ceph
20.2.2 tentacle, Kolla-Ansible 22.1.1 (`stable/2026.1`), OpenStack 2026.1 aarch64.

Ordering matters. Steps marked **must precede** cannot be done later without tearing
down work.

**On users.** Nothing inside the VM depends on which account you log in as. Ceph,
Incus and RGW commands all run through `sudo` (as root); OpenStack runs as a dedicated
`kolla` service account created in 5.2; shared artifacts live in `/etc/openstack-lab`
rather than a home directory. The only `~/` paths in this guide are on the **macOS
side** (`~/openstack-ceph-lab`, `~/.zshrc`), where they refer to your own Mac account.

---

## Credentials

Nothing here has a fixed default you can look up — Kolla randomises every password at
install time, and the Ceph one you chose yourself at bootstrap. `03-provision.sh`
prints all of them at the end of phase `90-verify`, so the quickest answer is:

```bash
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh --only 90-verify
```

To fetch them individually, from inside the machine:

### Horizon and the OpenStack APIs

Username **admin**, domain **Default**. The password is generated by `kolla-genpwd`
(5.2) — there is no default and it differs on every install:

```bash
sudo -u kolla grep '^keystone_admin_password:' /etc/kolla/passwords.yml
```

`passwords.yml` holds every other service password too, same format. It is owned by the
`kolla` user, hence the `sudo -u kolla`.

For the CLI, don't retype the password — Kolla writes a full clouds file at
`post-deploy`:

```bash
sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate &&
  OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin openstack service list'
```

Put those two exports in the `kolla` user's profile to avoid repeating them.

### Ceph dashboard

Username **admin**. Unlike the OpenStack one this is *not* generated — it is whatever
was passed to `--initial-dashboard-password` at `cephadm bootstrap` (4.2), which in
this lab is `ChangeMeBeforeUse` (set in `03-provision.sh` as `DASHBOARD_PASSWORD`).

Ceph normally forces a change on first login. To set it to something known, and clear
that flag at the same time:

```bash
echo -n 'YourNewPassword' | sudo incus exec ceph-node1 -- cephadm shell -- \
  ceph dashboard ac-user-set-password admin --force-password -i -
```

If you have lost it entirely, the same command resets it — there is no recovery of the
old value. (`ac-user-set-password-policy` does not exist; `ceph dashboard --help` lists
the real subcommands.)

### S3 (Ceph RGW)

The access and secret keys are minted by `radosgw-admin` when the user is created
(7.3). Phase `85-rgw` writes a ready-to-use client config to
`/etc/openstack-lab/s3cfg`, mode 600:

```bash
sudo cat /etc/openstack-lab/s3cfg
sudo s3cmd -c /etc/openstack-lab/s3cfg ls
```

To read them back from Ceph itself, or to see them for any other user:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- \
  radosgw-admin user info --uid=labuser --format=json | python3 -m json.tool | grep -A2 access_key
```

Use `--format=json`. Plain `radosgw-admin user info | grep -A3 '"keys"'` truncates
before the secret key.

### Where the secrets live

| What | Path | Owner |
|---|---|---|
| Every OpenStack service password | `/etc/kolla/passwords.yml` | `kolla` |
| OpenStack CLI clouds file | `/etc/kolla/clouds.yaml` | `kolla` |
| Ceph client keyrings | `/etc/ceph/ceph.client.{glance,cinder}.keyring` | root, group `libvirt` |
| S3 client config | `/etc/openstack-lab/s3cfg` | root, mode 600 |
| Pinned Ceph version, shared with the provisioner | `/etc/openstack-lab/lab.env` | root |

The Ceph dashboard password is **not** stored anywhere on disk — it only exists in the
`cephadm bootstrap` command in `03-provision.sh` and inside Ceph's own user database.

`/etc/openstack-lab/labkey.pem` appears only if you work through 6.5 by hand;
`03-provision.sh` does not boot an instance, so it does not create a keypair.

None of these leave the VM, and the machine has no home directory mounted, so they are
not visible from macOS.

---

## The four things that make this work

Most of the difficulty in this lab comes down to four discoveries. Read these before
starting; the rest of the guide is mechanics.

**1. Loop devices are rejected by `ceph-volume`.** It refuses anything reporting
`TYPE=loop` with *"Device type is not acceptable. It should be raw device or
partition."* The fix is to put an LVM logical volume on top of the loop device — an
LV reports `TYPE=lvm` and is accepted. That requires device-mapper in the kernel,
which the stock `apple/containerization` kernel does not have, so the kernel must be
rebuilt.

**2. Incus containers have no working device model.** Even with the LV passed
through, `ceph-volume` fails because the container lacks device nodes, LVM symlinks,
and a udev daemon. Three things fix it:

- `raw.lxc: lxc.mount.auto = sys:rw` so `systemd-udevd` can start (it refuses on a
  read-only `/sys` with *"ConditionPathIsReadWrite=/sys"*)
- `dmsetup mknodes` creates `/dev/mapper/<vg>-<lv>` block nodes
- `vgmknodes` creates the `/dev/<vg>/<lv>` symlinks — this is the one
  `ceph orch daemon add osd` actually resolves, and without it you get
  *"blkid: error: ceph-vg1/osd1: No such file or directory"*

Both `mknodes` commands must be re-run after every container restart — sections 3.8 and 3.10
make this automatic.

**3. Stopping a container deactivates its LV.** The container holds the only open
reference, so device-mapper tears the mapping down on stop and the device is gone
when it starts again. A `hold-osd` unit on the VM keeps a file descriptor open so
this can't happen (3.8). The hold must come from a unit baked into the machine image —
`/etc/systemd/system` reverts on every machine restart.

**Version constraint, not a discovery but easy to trip over:** Ceph must be pinned to
**20.2.2** throughout — cluster image and host client. 20.2.3/20.2.4 have no noble
package, and their type-2 cephx keys can't be read by any client you can install on
Ubuntu 24.04. See 0.3.

**4. The LV's own major:minor must be in the container's cgroup device whitelist.**
Passing `/dev/dm-N` through is what grants it. Without it the device node exists and
looks correctly owned, but any open returns EPERM and OSD creation fails silently
(3.6).

Note: `ceph orch device ls` and `ceph-volume inventory` stay **empty** even when
everything works. Don't use them as a health check — pass the LV path explicitly to
`ceph orch daemon add osd` instead.

---

## Architecture

```
macOS (M4, macOS 26)
  └─ container machine "openstack-lab" — Ubuntu 24.04 ARM64, /dev/kvm, device-mapper
       ├─ loop0/1/2 → ceph-vg1/2/3 → LVs osd1/osd2/osd3 (15G each)
       ├─ incusbr0  10.100.0.0/24 (static)
       ├─ ceph-node1  10.100.0.11   mon, mgr, osd.0, bootstrap host
       ├─ ceph-node2  10.100.0.12   mon, mgr standby, osd.1
       └─ ceph-node3  10.100.0.13   mon, osd.2
```

---

## Phase 0: Prerequisites

### 0.1 zsh comments

zsh doesn't treat `#` as a comment interactively; pasted comments become arguments,
producing errors like ``make: *** No rule to make target `#'``.

```bash
echo 'setopt interactive_comments' >> ~/.zshrc && exec zsh
```

### 0.2 Verify the host

```bash
container --version
container system start
```

Apple Silicon M3 or later; macOS 26.

### 0.3 Pick the Ceph version — it must match in three places

Ceph 20.2.3+ mints cephx keys with crypto type 2 and its mons only negotiate auth
method 2, so only a matching-version client can authenticate. Upstream published
noble (Ubuntu 24.04) packages for Tentacle 20.2.1 and 20.2.2 but **not** for 20.2.3
or 20.2.4 — the 20.2.4 build produced jammy, bookworm, Rocky and CentOS, and noble
was never copied to `download.ceph.com`. Squid (19.2.x) never published a noble suite
at all, and Ubuntu's own `ceph-common` (19.2.3) cannot parse a type-2 key.

A 20.2.4 cluster on Ubuntu 24.04 therefore has **no usable host client**, so
OpenStack can't talk to it. Importing an older type-1 key doesn't help either — the
mons refuse the auth method.

**This gap has since been closed.** When this lab was first built, 20.2.2 was the
newest release with both a noble client package and a matching cluster image. That is
no longer true — upstream has published noble arm64 packages for 20.2.4:

```
$ curl -fsSL https://download.ceph.com/debian-20.2.4/dists/noble/main/binary-arm64/Packages \
    | grep -A1 '^Package: ceph-common$'
Package: ceph-common
Version: 20.2.4-1noble
```

Check the **package index**, not just the `Release` file — a `200` on `Release` only
says the suite exists, not that it carries the packages you need:

```bash
curl -fsSL https://download.ceph.com/debian-<ver>/dists/noble/main/binary-arm64/Packages \
  | awk '/^Package: (ceph-common|cephadm)$/{p=$2} /^Version:/{if(p){print p, $2; p=""}}'
```

**The scripts still pin 20.2.2**, which is the version this lab has actually verified
end to end. 20.2.4 should work now that client and cluster can match, but it has not
been tested here. Changing it is a one-line edit — `CEPH_VERSION` in
`02-build-image.sh`, which bakes the value into `/etc/openstack-lab/lab.env` so
`03-provision.sh` picks up the same number for the node image and the cephadm
bootstrap. Do not edit it in one place only.

Whichever you pick, it must be identical in all three places:

| Place | What |
|---|---|
| 1.3 | VM image — `debian-<ver>` apt repo plus `ceph-common` |
| 3.3 | Node base image — same repo, plus `cephadm` and `ceph-common` |
| 4.2 | `cephadm bootstrap --image quay.io/ceph/ceph:v<ver>` |

A mismatch anywhere surfaces as an unreadable keyring in 4.6, after everything else
looks fine.

---

## Phase 1: Kernel and machine

### 1.1 Clone and patch the kernel config — must precede everything

The stock kernel lacks device-mapper, which makes LVM impossible and therefore Ceph
impossible.

```bash
mkdir -p ~/openstack-ceph-lab && cd ~/openstack-ceph-lab
git clone https://github.com/apple/containerization
cd containerization/kernel
```

Check what's already set:

```bash
grep -E 'CONFIG_(MD|BLK_DEV_DM|DM_|OPENVSWITCH|VXLAN)' config-arm64
```

On a stock checkout `CONFIG_MD` and `CONFIG_OPENVSWITCH` are unset (the DM options
are gated behind `CONFIG_MD`, so they don't appear at all) and `CONFIG_VXLAN=y`
already. Append what's missing — the config parser takes the last occurrence, so
plain `=y` lines override the earlier `# ... is not set`:

```bash
cat >> config-arm64 <<'EOF'
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_SNAPSHOT=y
CONFIG_DM_THIN_PROVISIONING=y
CONFIG_DM_MIRROR=y
CONFIG_DM_ZERO=y
CONFIG_OPENVSWITCH=y
CONFIG_NF_CONNTRACK=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_SCSI=y
CONFIG_SCSI_LOWLEVEL=y
CONFIG_SCSI_ISCSI_ATTRS=y
CONFIG_ISCSI_TCP=y

# --- Module infrastructure. Everything in this lab is still built =y, but Kolla
# --- and Ansible expect the machinery to exist: Ansible's modprobe module reads
# --- /proc/modules, which the kernel only creates with CONFIG_MODULES=y, and
# --- modprobe needs a real /lib/modules that depmod can populate.
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y

# --- AppArmor: Kolla's bootstrap-servers removes a libvirt AppArmor profile and
# --- fails outright if AppArmor is absent. CONFIG_LSM must list apparmor or the
# --- code compiles in but never activates.
CONFIG_SECURITY=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor"

# --- Docker (Kolla runs every OpenStack service as a Docker container).
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_PIDS=y
CONFIG_CPUSETS=y
CONFIG_MEMCG=y
CONFIG_KEYS=y
CONFIG_VETH=y
CONFIG_MACVLAN=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_NF_NAT=y
CONFIG_NETFILTER_XTABLES=y
# Three gates, all required. NETFILTER_XTABLES_LEGACY is the global one; the
# per-family *_IPTABLES_LEGACY options default to =m and are what actually decide
# the ten IP_NF_*/IP6_NF_* options below. Miss them and every one is demoted to =m.
CONFIG_NETFILTER_XTABLES_LEGACY=y
CONFIG_IP_NF_IPTABLES_LEGACY=y
CONFIG_IP6_NF_IPTABLES_LEGACY=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_MANGLE=y
CONFIG_IP_NF_RAW=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_IP6_NF_IPTABLES=y
CONFIG_IP6_NF_FILTER=y
CONFIG_IP6_NF_MANGLE=y
CONFIG_IP6_NF_RAW=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_IPVS=y
CONFIG_POSIX_MQUEUE=y
CONFIG_USER_NS=y
CONFIG_SECCOMP=y
EOF
```

Everything `=y`, never `=m` — there is no module loading in these VMs. OpenVSwitch
and the iSCSI stack are for Phase 5; adding them now avoids a second rebuild.

**Options with unmet dependencies are dropped silently.** The build runs
`olddefconfig`, which discards anything whose prerequisites aren't enabled — no error,
no warning. Three cases bite here, all with parents unset in the stock config, which is
why the parents appear in the block above:

| Options | Parent required |
|---|---|
| `CONFIG_DM_*` | `CONFIG_MD` |
| `CONFIG_ISCSI_TCP`, `CONFIG_SCSI_ISCSI_ATTRS` | `CONFIG_SCSI`, `CONFIG_SCSI_LOWLEVEL` |
| `CONFIG_IP_NF_*` / `CONFIG_IP6_NF_*` (ten options) | `CONFIG_IP_NF_IPTABLES`, `CONFIG_IP6_NF_IPTABLES`, `CONFIG_NETFILTER_XTABLES_LEGACY`, **and** `CONFIG_IP_NF_IPTABLES_LEGACY` / `CONFIG_IP6_NF_IPTABLES_LEGACY` |

**Watch for `=m`, not just for missing.** kconfig will not build a symbol in when a
parent is a module, so an option can be silently demoted rather than dropped — and in
this lab `=m` means absent, since nothing runs `make modules_install`. The ten
`IP_NF_*` options come back `=m` unless `CONFIG_IP_NF_IPTABLES_LEGACY=y` and
`CONFIG_IP6_NF_IPTABLES_LEGACY=y` are set, which is why they are in the block above.
Check the resolved value, not just for `=y`:

```bash
zcat /proc/config.gz | grep -E '^(# )?CONFIG_IP_NF_FILTER[= ]'
```

None of this stops the lab working — Ubuntu 24.04 ships `iptables v1.8.10 (nf_tables)`,
which uses `CONFIG_NF_TABLES` and never touches the legacy layer. The legacy options
are there for anything calling `iptables-legacy` directly.

Dependencies can be **nested**: the iptables case needed `CONFIG_IP_NF_IPTABLES`, and
then still failed until `CONFIG_NETFILTER_XTABLES_LEGACY` was added above it. Check the
built kernel rather than assuming an option took:

```bash
zcat /proc/config.gz | grep '^CONFIG_IP_NF_FILTER='
```

A line beginning `# CONFIG_X is not set` in `/proc/config.gz` where you wrote
`CONFIG_X=y` means it was dropped — look for its parent in the kernel's Kconfig.

This is exactly what `check-config.sh` in 1.5 catches — run it before Phase 5, not
during it.

**Appending repeatedly leaves duplicates.** Each edit of `config-arm64` adds another
copy of the block. The last occurrence wins so it still works, but the file becomes
impossible to reason about — the checkout this lab ran on had accumulated seven copies
of the device-mapper block and four of the iptables block.

`01-build-kernel.sh` writes the block between sentinels and strips any previous copy
first, so re-running replaces rather than appends:

```
# >>> openstack-ceph-lab >>>
...
# <<< openstack-ceph-lab <<<
```

**Do not validate by counting occurrences of an option.** The stock `config-arm64`
already sets some of these itself — `CONFIG_IP_NF_IPTABLES=y` is at line 1321 of a
fresh checkout — so a second occurrence from the block is correct, not a fault. The
checks that mean something are that the sentinel block appears exactly once, and that
the **last** occurrence of each option reads `=y`:

```bash
grep -E '^(# )?CONFIG_BLK_DEV_DM[= ]' config-arm64 | tail -1
```

A useful sanity signal: the built `vmlinux-arm64` should grow noticeably. Adding the
SCSI stack took it from ~29.6 MB to ~29.8 MB. An unchanged size means nothing landed.

### 1.2 Build

```bash
make -C kernel TARGET_ARCH=arm64
ls -l kernel/vmlinux-arm64
```

Builds inside a container. On an M4 with 8 CPUs the whole thing — build image, source
fetch, compile — takes about ten minutes. No `.config` comes back; only the artifact.

**Check the timestamp is current.** If `make` considers the target up to date it
silently does nothing, and a stale kernel is worse than a failed build because it boots
and behaves like the old one. `01-build-kernel.sh` fails the run if the artifact is
more than an hour old.

**Take `kernel/vmlinux-arm64`, not `bin/vmlinux-arm64`.** A checkout ships a prebuilt
`bin/vmlinux-arm64` which is the Kata kernel, with no KVM. After a successful build the
two are identical — the `kernel-install` target copies `kernel/` over `bin/` — so the
distinction only bites when the build failed and you didn't notice. Reading from
`kernel/` is correct either way.

The kernel this produced is `6.18.5-cz-<git-short-sha>`; the `LOCALVERSION` comes from
the checkout's HEAD, so it changes when upstream moves.

### 1.3 Machine image

```bash
cd ~/openstack-ceph-lab
cat << 'EOF' > Dockerfile
FROM ubuntu:24.04
ENV container container
RUN apt-get update && apt-get install -y \
    dbus systemd openssh-server net-tools iproute2 iputils-ping \
    qemu-system-arm qemu-utils libvirt-daemon-system \
    bridge-utils nftables iptables chrony lvm2 incus \
    python3-yaml python3-jinja2 python3-requests \
    curl wget git vim-tiny man sudo cpu-checker uuid-runtime s3cmd \
    gdisk parted kpartx dosfstools e2fsprogs debootstrap \
    python3-dev python3-venv python3-apt libffi-dev libssl-dev libdbus-glib-1-dev \
    kmod && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && yes | unminimize
RUN >/etc/machine-id
RUN >/var/lib/dbus/machine-id
RUN systemctl set-default multi-user.target
RUN systemctl mask dev-hugepages.mount sys-fs-fuse-connections.mount \
      systemd-update-utmp.service systemd-tmpfiles-setup.service console-getty.service
RUN systemctl disable networkd-dispatcher.service
# Ubuntu's OCI image ships a policy-rc.d stub that blocks every daemon you install.
RUN rm -f /usr/sbin/policy-rc.d
RUN echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-lab.conf

# --- securityfs is never mounted in this image. systemd mounts API filesystems
# --- only when it is PID 1 from the start; here the machine boots via
# --- init=/sbin/vminitd and hands off later, so the mount never happens.
# --- Without it, AppArmor is active in the kernel but /sys/kernel/security/apparmor
# --- is absent, and Kolla's bootstrap-servers fails with
# --- "apparmor_parser ... unable to find a suitable fs in /proc/mounts".
# ---
# --- It must be a .service, NOT an fstab line or a .mount unit: systemd refuses
# --- both for API filesystems with "Cannot create mount unit for API file system
# --- /sys/kernel/security. Refusing."
RUN printf '%s\n' \
  '[Unit]' \
  'Description=Mount securityfs (systemd refuses .mount units for API filesystems)' \
  'DefaultDependencies=no' \
  'Before=sysinit.target' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  "ExecStart=/bin/sh -c 'mountpoint -q /sys/kernel/security || mount -t securityfs securityfs /sys/kernel/security'" \
  'RemainAfterExit=yes' \
  '' \
  '[Install]' \
  'WantedBy=sysinit.target' \
  > /etc/systemd/system/securityfs-mount.service
RUN systemctl enable securityfs-mount.service

# --- /run must have shared mount propagation. Kolla's containers (kolla_toolbox
# --- and others) mount /run:/run:shared; a normal systemd host sets this at boot,
# --- this minimal image leaves /run private and Docker refuses to start them:
# --- "path /run is mounted on /run but it is not a shared mount".
RUN printf '%s\n' \
  '[Unit]' \
  'Description=Make /run a shared mount for Kolla containers' \
  'DefaultDependencies=no' \
  'Before=docker.service' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'ExecStart=/bin/mount --make-shared /run' \
  'RemainAfterExit=yes' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/run-shared.service
RUN systemctl enable run-shared.service

# --- modprobe needs /lib/modules/<version> to exist. CONFIG_MODULES=y (1.1) gives
# --- the kernel /proc/modules, but the directory is created by `make
# --- modules_install`, which Apple's kernel build never runs — there are no .ko
# --- files because everything is =y. Both halves are required.
COPY fake-modules-builtin.sh /usr/local/sbin/fake-modules-builtin.sh
RUN chmod 755 /usr/local/sbin/fake-modules-builtin.sh
RUN printf '%s\n' \
  '[Unit]' \
  'Description=Create /lib/modules so modprobe resolves built-in modules' \
  'DefaultDependencies=no' \
  'Before=docker.service' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'ExecStart=/usr/local/sbin/fake-modules-builtin.sh' \
  'RemainAfterExit=yes' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/fake-modules-builtin.service
RUN systemctl enable fake-modules-builtin.service

# --- Kolla's bootstrap-servers REMOVES the libvirt AppArmor profile, and fails if
# --- it was never loaded ("apparmor_parser: Unable to remove libvirtd. Profile
# --- doesn't exist"). A normal Ubuntu host loads it at boot; this image doesn't,
# --- so it must be loaded on every machine.
RUN printf '%s\n' \
  '[Unit]' \
  'Description=Load libvirt AppArmor profile so Kolla can remove it' \
  'After=apparmor.service' \
  'ConditionPathExists=/etc/apparmor.d/usr.sbin.libvirtd' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'ExecStart=/sbin/apparmor_parser -r /etc/apparmor.d/usr.sbin.libvirtd' \
  'RemainAfterExit=yes' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/libvirt-apparmor-load.service
RUN systemctl enable libvirt-apparmor-load.service

# --- Kolla's network setup: the private control-plane interface, Neutron's
# --- external interface, and the port forward that makes Horizon reachable from
# --- macOS. None of this survives a reboot if done by hand (5.1, 6.2).
COPY kolla-net-setup.sh /usr/local/sbin/kolla-net-setup.sh
RUN chmod 755 /usr/local/sbin/kolla-net-setup.sh
RUN printf '%s\n' \
  '[Unit]' \
  'Description=Kolla lab network interfaces and port forwards' \
  'After=network-online.target' \
  'Wants=network-online.target' \
  'Before=docker.service' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'ExecStart=/usr/local/sbin/kolla-net-setup.sh' \
  'RemainAfterExit=yes' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/kolla-net-setup.service
RUN systemctl enable kolla-net-setup.service

# --- Under Kolla, libvirt runs in a container and needs exclusive use of
# --- /var/run/libvirt/libvirt-sock. The host copy (installed above for the
# --- nested-KVM work in Phase 1) must not run, or prechecks fail on
# --- "Checking that host libvirt is not running". Disable the sockets too —
# --- socket activation restarts the daemon otherwise.
RUN systemctl disable libvirtd.service libvirtd.socket libvirtd-ro.socket \
      libvirtd-admin.socket virtlogd.socket virtlockd.socket \
      virtlogd-admin.socket virtlockd-admin.socket || true


# --- Ceph host client, pinned to 20.2.2. Ubuntu's ceph-common is 19.2.3 and
# --- cannot parse the type-2 cephx keys a Tentacle cluster mints. See 0.3.
RUN curl -fsSL https://download.ceph.com/keys/release.gpg \
      -o /etc/apt/trusted.gpg.d/ceph.gpg && \
    echo 'deb https://download.ceph.com/debian-20.2.2/ noble main' \
      > /etc/apt/sources.list.d/ceph.list && \
    apt-get update && apt-get install -y ceph-common && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Storage units, in three stages. A single unit deadlocks: it would have to run
# --- before Incus (so the LVs exist) and after Incus (so `incus config device set`
# --- has a daemon to talk to).
COPY ceph-lab-assemble.sh /usr/local/sbin/ceph-lab-assemble.sh
COPY ceph-lab-remap.sh    /usr/local/sbin/ceph-lab-remap.sh
RUN chmod 755 /usr/local/sbin/ceph-lab-assemble.sh /usr/local/sbin/ceph-lab-remap.sh

# Stage 1: before Incus — loop devices and volume groups.
RUN printf '%s\n' \
  '[Unit]' \
  'Description=Assemble Ceph lab storage (loop devices and volume groups)' \
  'After=systemd-udev-settle.service' \
  'Before=incus.service' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'ExecStart=/usr/local/sbin/ceph-lab-assemble.sh' \
  'RemainAfterExit=yes' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/ceph-lab-assemble.service

# Stage 2: one long-running hold per LV, as its own service so it does not die
# with the oneshot unit that spawned it.
RUN for n in 1 2 3; do printf '%s\n' \
  '[Unit]' \
  "Description=Hold ceph-vg${n}/osd${n} open" \
  'After=ceph-lab-assemble.service' \
  'Requires=ceph-lab-assemble.service' \
  'Before=incus.service' \
  '' \
  '[Service]' \
  "ExecStart=/bin/sh -c 'exec sleep infinity < /dev/ceph-vg${n}/osd${n}'" \
  'Restart=always' \
  'RestartSec=5' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/hold-osd${n}.service; done

# Stage 3: after Incus is up — fix device mappings, then start the containers.
RUN printf '%s\n' \
  '[Unit]' \
  'Description=Repair Incus device mappings and start Ceph nodes' \
  'After=incus.service hold-osd1.service hold-osd2.service hold-osd3.service' \
  'Requires=incus.service' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'ExecStart=/usr/local/sbin/ceph-lab-remap.sh' \
  'RemainAfterExit=yes' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/ceph-lab-remap.service

RUN systemctl enable ceph-lab-assemble.service ceph-lab-remap.service \
      hold-osd1.service hold-osd2.service hold-osd3.service
EOF
```

Two scripts are needed alongside the Dockerfile. The split into three stages is not
cosmetic — a single unit deadlocks, because it would have to run *before* Incus (so
the LVs exist) and *after* Incus (so `incus config device set` has a daemon to talk
to). See the notes under each.

Alongside the Dockerfile, create `kolla-net-setup.sh`:

```bash
cat << 'SCRIPT' > kolla-net-setup.sh
#!/bin/sh
# Private control-plane interface, Neutron's external interface, and the Horizon
# port forward. Idempotent — safe to re-run.
#
# Nothing here references the VM's own vmnet address, which changes on every
# machine recreate: the DNAT rule matches by interface name (enp0s1) and targets a
# fixed private address, so only the URL you type changes.
set -e

# kolla0: network_interface, holds 10.10.10.1. The VIP 10.10.10.10 stays free for
# keepalived. A dummy interface would be cleaner but CONFIG_DUMMY is not in this
# kernel, so a veth pair stands in.
if ! ip link show kolla0 >/dev/null 2>&1; then
    ip link add kolla0 type veth peer name kolla0-peer
    ip addr add 10.10.10.1/24 dev kolla0
    ip link set kolla0 up
    ip link set kolla0-peer up
fi

# veth-ext: neutron_external_interface, up with NO address.
if ! ip link show veth-ext >/dev/null 2>&1; then
    ip link add veth-ext type veth peer name veth-ext-br
    ip link set veth-ext up
    ip link set veth-ext-br up
fi

# Horizon on the VIP, reachable from macOS as <VM_IP>:8080.
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C PREROUTING -i enp0s1 -p tcp --dport 8080 \
    -j DNAT --to-destination 10.10.10.10:80 2>/dev/null || \
iptables -t nat -A PREROUTING -i enp0s1 -p tcp --dport 8080 \
    -j DNAT --to-destination 10.10.10.10:80
iptables -t nat -C POSTROUTING -o kolla0 -p tcp -d 10.10.10.10 --dport 80 \
    -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o kolla0 -p tcp -d 10.10.10.10 --dport 80 \
    -j MASQUERADE
SCRIPT
chmod +x kolla-net-setup.sh
```

And `fake-modules-builtin.sh`:

```bash
cat << 'SCRIPT' > fake-modules-builtin.sh
#!/bin/sh
# Kolla calls modprobe for ip_vs, br_netfilter and openvswitch. All three are
# compiled in (=y), but Apple's kernel build never runs `make modules_install`,
# so /lib/modules/<version> does not exist and modprobe fails even for built-ins.
set -e
K=$(uname -r)
mkdir -p "/lib/modules/$K"
cat > "/lib/modules/$K/modules.builtin" <<EOF
kernel/net/netfilter/ipvs/ip_vs.ko
kernel/net/bridge/br_netfilter.ko
kernel/net/openvswitch/openvswitch.ko
EOF
touch "/lib/modules/$K/modules.order" "/lib/modules/$K/modules.builtin.modinfo"
depmod -a
SCRIPT
chmod +x fake-modules-builtin.sh
```

```bash
cat << 'SCRIPT' > ceph-lab-assemble.sh
#!/bin/sh
# Stage 1 — runs before incus.service. Reassembles the loop devices and VGs.
# Does NOT touch incus: the daemon isn't running yet and the client would block
# forever waiting for a socket systemd hasn't created.
set -e

for f in /var/lib/ceph-disks/osd*.img; do
  [ -e "$f" ] || continue
  losetup -j "$f" | grep -q . || losetup --find "$f"
done

vgchange -ay
SCRIPT

cat << 'SCRIPT' > ceph-lab-remap.sh
#!/bin/sh
# Stage 3 — runs after incus.service. dm minor numbers are assigned in vgchange
# activation order and shuffle between boots, so the Incus device definitions
# (pinned by number, in BOTH path= and source=) must be corrected before the
# containers start. Containers have boot.autostart=false; this starts them.
set -e

for n in 1 2 3; do
  d=$(dmsetup ls | awk -v v="ceph--vg$n-osd$n" \
        '$1==v {gsub(/[()]/,"",$2); split($2,a,":"); print a[2]}')
  [ -n "$d" ] || continue
  logger -t ceph-lab-remap "ceph-vg$n/osd$n -> /dev/dm-$d"
  incus config device set "ceph-node$n" "dm$((n-1))" path   "/dev/dm-$d"
  incus config device set "ceph-node$n" "dm$((n-1))" source "/dev/dm-$d"
done

for n in 1 2 3; do
  incus start "ceph-node$n" 2>/dev/null || true
done
SCRIPT

container build -t local/ubuntu-machine:latest .
```

Three things this design gets right that the obvious one-unit version does not:

- **The holds are their own services.** Backgrounded children of a `Type=oneshot`
  live in that unit's cgroup and are killed the moment it stops — taking the LV
  activation with them, which renumbers the devices.
- **The remap runs after Incus.** `incus config device set` from a unit ordered
  `Before=incus.service` hangs forever; the unit never completes and the mapping is
  never fixed.
- **Containers are started by the remap unit**, not by Incus autostart, so they can't
  come up on stale device numbers. Set this once, after creating them in 3.4:
  `for n in 1 2 3; do sudo incus config set ceph-node$n boot.autostart false; done`

Removing `policy-rc.d` prevents `incus admin init` failing with
*"Failed to connect to local daemon"* after an install that printed
*"policy-rc.d returned 101"*. `python3-yaml` prevents cephadm's
`ModuleNotFoundError: No module named 'yaml'`. The last two lines cover Phase 5 and the optional Octavia
build: `python3-dev python3-venv python3-apt libffi-dev libssl-dev libdbus-glib-1-dev` are
Kolla-Ansible's dependencies — `python3-apt` in particular, without which
`bootstrap-servers` fails with *"Could not detect a supported package manager"*, and the partitioning tools
(`gdisk parted kpartx dosfstools e2fsprogs debootstrap`) are only needed if you build
the Octavia amphora image — `diskimage-builder` shells out to them and the minimal
image has none of them. Missing `sgdisk` in particular fails with
`BlockDeviceSetupException: exec_sudo failed: sudo: sgdisk: command not found`, about
two minutes into an otherwise-working build. `incus` is included here rather than
installed at runtime — the `ceph-lab-remap` unit above is ordered against
`incus.service`, which must exist in the image for that ordering to resolve.

### 1.4 Create the machine

```bash
container machine create \
  --virtualization \
  --kernel ~/openstack-ceph-lab/vmlinux-arm64 \
  --name openstack-lab \
  --cpus 8 \
  --memory 26G \
  --home-mount none \
  local/ubuntu-machine:latest
container machine set-default openstack-lab
container machine run
```

`--home-mount none` keeps the macOS home directory out of the VM. The default is `rw`,
which exposes the whole of `~` — the provisioning script does not need it, and nothing
in the lab reads from the Mac at runtime. `ro`, `rw` and `none` are the only choices;
there is no option to bind-mount a single directory, so if you want a file inside, bake
it into the image or pipe it in over stdin.

`--cpus` and `--memory` are accepted at create time; the separate
`container machine set -n openstack-lab cpus=8 memory=26G` is only needed to change
them later, and takes effect on the next restart.

Verify both kernel features landed:

```bash
ls -l /dev/mapper/control && ls -l /dev/kvm
```

Both must exist. `/dev/mapper/control` is the device-mapper control node — if it's
missing, the kernel rebuild didn't take and nothing downstream will work.

Then verify every option you asked for actually survived the build. This is the
cheapest possible check and it catches silently-dropped options before they cost you
an hour-long OpenStack deployment:

```bash
zcat /proc/config.gz | grep -E 'CONFIG_KVM=|CONFIG_BLK_DEV_DM=|CONFIG_SCSI=|CONFIG_ISCSI_TCP=|CONFIG_SCSI_ISCSI_ATTRS=|CONFIG_OPENVSWITCH=|CONFIG_BRIDGE=|CONFIG_NF_TABLES=|CONFIG_OVERLAY_FS=|CONFIG_SECURITY_APPARMOR=|CONFIG_SECURITYFS='
ls /sys/kernel/security/apparmor
```

Expect **eleven** lines, all `=y`, and the AppArmor directory to exist. A missing
option means an unmet dependency — find its parent, add it in 1.1, and rebuild before
going further.

**If the options are all `=y` but `/sys/kernel/security/apparmor` is missing**, the
kernel is fine and securityfs simply isn't mounted. The `securityfs-mount.service` from
1.3 handles this:

```bash
systemctl is-enabled securityfs-mount.service
mount | grep securityfs
cat /sys/kernel/security/lsm
ls /sys/kernel/security/apparmor
```

`lsm` must include `apparmor`, and the directory must list `profiles`, `policy` and so
on.

Two things that do **not** work, both tried:

- **An fstab line.** systemd's generator won't produce a unit for an API filesystem.
- **A `sys-kernel-security.mount` unit.** systemd rejects it outright —
  `systemd-analyze verify` reports *"Cannot create mount unit for API file system
  /sys/kernel/security. Refusing."* and the unit loads as `bad-setting`.

A plain `oneshot` service running `mount` is accepted, which is what 1.3 installs.

`container machine` already passes `lsm=lockdown,capability,landlock,yama,apparmor` on
the kernel command line (`cat /proc/cmdline`), so the LSM list is rarely the problem —
the missing mount is.

**Then run Docker's own checker**, which is authoritative in a way a hand-written list
is not:

```bash
curl -fsSL https://raw.githubusercontent.com/moby/moby/master/contrib/check-config.sh -o /tmp/check-config.sh
chmod +x /tmp/check-config.sh
/tmp/check-config.sh | grep -iE 'missing|enabled|apparmor' | head -40
```

Everything under **Generally Necessary** must say `enabled`. Kolla runs every
OpenStack service as a Docker container, so anything missing here fails during
`bootstrap-servers` or later, usually with an error that doesn't mention the kernel.
Doing this before Phase 5 costs a minute; discovering it during a deploy costs a
rebuild and a full redeploy.

---

## Phase 2: LVM-backed OSD devices

Loop devices alone are rejected. The LV on top is what makes them acceptable.

```bash
sudo mkdir -p /var/lib/ceph-disks
for i in 1 2 3; do
  sudo truncate -s 15G /var/lib/ceph-disks/osd$i.img
  L=$(sudo losetup --find --show /var/lib/ceph-disks/osd$i.img)
  echo "osd$i -> $L"
  sudo pvcreate $L
  sudo vgcreate ceph-vg$i $L
  sudo lvcreate -l 100%FREE -n osd$i ceph-vg$i
done
lsblk -o NAME,TYPE | grep lvm
```

Expect three entries reporting `lvm`, not `loop`. **Record which loop device backs
which VG** — you need both the loop and the dm device numbers in Phase 3:

```bash
losetup -a
ls -l /dev/dm-*
```

Typically loop0/dm-0 → ceph-vg1, loop1/dm-1 → ceph-vg2, loop2/dm-2 → ceph-vg3, but
verify rather than assume.

---

## Phase 3: Incus and the Ceph nodes

### 3.1 Initialize Incus

Incus itself is installed by the image from 1.3. Only initialization happens at
runtime — it creates the database, storage pool, and bridge, and needs a running
daemon, which isn't possible during an image build.

```bash
sudo incus admin init --auto
sudo incus info | head -3
```

If it reports *"Failed to connect to local daemon"*, the daemon didn't start:
`sudo systemctl enable --now incus.socket incus.service` and retry.

**All Incus and Ceph commands in this guide run through `sudo`, i.e. as root.** Don't
add your interactive login account to `incus-admin` — the guide never depends on which
user you logged in as, and `$USER` is empty in a `container machine run` shell anyway.

### 3.2 Pin the network — must precede launching containers

Incus picks a random subnet and it changes across restarts. This lab saw three
different subnets in one session. Ceph writes mon addresses into its config, so a
subnet change after bootstrap destroys the cluster.

```bash
sudo incus network set incusbr0 ipv4.address 10.100.0.1/24
sudo incus network set incusbr0 ipv4.nat true
sudo incus network show incusbr0
```

### 3.3 Build the node base image

The Ceph nodes can't use the machine image from 1.3 — that's an OCI image in Apple's
store on macOS, and Incus needs its own format with a working init system. Build the
equivalent inside the VM instead: configure one container, publish it as a local
image, launch the nodes from that.

```bash
sudo incus launch images:ubuntu/24.04 ceph-base -c security.privileged=true
sleep 20

sudo incus exec ceph-base -- apt-get update
sudo incus exec ceph-base -- apt-get install -y \
     lvm2 openssh-server podman python3 chrony curl gnupg

# Pinned Ceph repo — same version as the VM image (1.3) and the cluster (4.2).
sudo incus exec ceph-base -- bash -c \
  'curl -fsSL https://download.ceph.com/keys/release.gpg -o /etc/apt/trusted.gpg.d/ceph.gpg && \
   echo "deb https://download.ceph.com/debian-20.2.2/ noble main" > /etc/apt/sources.list.d/ceph.list && \
   apt-get update && apt-get install -y cephadm ceph-common'

sudo incus exec ceph-base -- systemctl enable ssh
sudo incus exec ceph-base -- apt-get clean
sudo incus exec ceph-base -- cephadm version

sudo incus stop ceph-base
sudo incus publish ceph-base --alias ceph-node-base
sudo incus delete ceph-base
sudo incus image list
```

`chrony` is required — cephadm's host check fails without time sync. `podman` runs
every Ceph daemon. `openssh-server` is how the orchestrator reaches nodes 2 and 3.
`lvm2` provides `dmsetup` and `vgmknodes`, needed in 3.7. `cephadm version` must
report the version chosen in 0.3 — installing it from the pinned repo rather than
`curl`-ing a standalone binary keeps it consistent with the VM client and puts it on
all three nodes, not just the bootstrap host.

Keep the base container free of anything node-specific — no hostnames, no SSH keys,
no static IPs. Those are set per node after launch.

The image lives in `/var/lib/incus`, which survives machine restarts, so you build it
once and reuse it. `sudo incus image delete ceph-node-base` if you need to rebuild.

### 3.4 Launch with static addresses

```bash
for n in 1 2 3; do
  sudo incus launch ceph-node-base ceph-node$n -c security.privileged=true
done

sudo incus stop ceph-node1 ceph-node2 ceph-node3
for n in 1 2 3; do
  sudo incus config device override ceph-node$n eth0 ipv4.address=10.100.0.1$n
done
sudo incus start ceph-node1 ceph-node2 ceph-node3
sleep 15
sudo incus list

# The remap unit starts the containers after fixing device numbers, so Incus
# must not autostart them onto stale mappings.
for n in 1 2 3; do sudo incus config set ceph-node$n boot.autostart false; done
```

Launching from `ceph-node-base` means the packages are already in place. (If you
skipped 3.3, use `images:ubuntu/24.04` — note the remote is `images:`, since Incus
has no `ubuntu:` remote — and install the packages afterwards.) Privileged from the
start; retrofitting means recreating.

`incusbr0` showing DOWN before the first container starts is normal.

### 3.5 Verify networking — ping does not work

ICMP is filtered through the macOS NAT path even when networking is fine.

```bash
sudo incus exec ceph-node1 -- curl -sSI --max-time 5 http://archive.ubuntu.com/ | head -1
```

### 3.6 Pass through the device stack

Each node needs three devices plus the `sys:rw` mount option. Check the current
mapping first — `sudo dmsetup ls` and `losetup -a` — and match each node to *its own*
loop and dm number.

```bash
for n in 1 2 3; do
  d=$((n-1))
  sudo incus config device add ceph-node$n dm-control unix-char \
       path=/dev/mapper/control source=/dev/mapper/control
  sudo incus config device add ceph-node$n pv-disk unix-block \
       path=/dev/loop$d source=/dev/loop$d
  sudo incus config device add ceph-node$n dm$d unix-block \
       path=/dev/dm-$d source=/dev/dm-$d
  sudo incus config set ceph-node$n raw.lxc "lxc.mount.auto = sys:rw
lxc.apparmor.profile = unconfined"
  sudo incus restart ceph-node$n
done
```

Why each one:

- `dm-control` — without it LVM reports *"Failure to communicate with kernel
  device-mapper driver"*
- `pv-disk` — the backing loop device; without it `lvs` runs but lists nothing
- `dm<N>` — **required for the cgroup device whitelist.** Without this entry the
  container can create the device node but cannot open it: `ceph-volume` fails with
  `PermissionError: [Errno 1] Operation not permitted: '/dev/ceph-vgN/osdN'` and
  `ceph orch daemon add osd` returns silently. Note this is EPERM from the cgroup
  policy, not a file-permission problem — `chown` on the node succeeds and the
  ownership looks correct.
- `sys:rw` — lets `systemd-udevd` start
- `lxc.apparmor.profile = unconfined` — **required because 1.1 enables AppArmor for
  Kolla's benefit.** With AppArmor active, Incus confines each container with a
  generated profile that blocks the mounts `systemd-udevd` and `podman` need. The
  symptoms are `systemd-udevd` failing with `status=226/NAMESPACE` and dmesg lines
  like:

  ```
  apparmor="DENIED" operation="mount" ... comm="(md-udevd)" name="/run/systemd/mount-rootfs/"
  apparmor="DENIED" operation="mount" ... comm="podman" name="/var/lib/containers/storage/overlay/"
  ```

  Both break Ceph — udevd is needed in 3.7, podman runs every Ceph daemon. These
  containers are already `security.privileged=true`, so AppArmor was the remaining
  confinement and you are dropping it. Acceptable in a lab; it is the price of having
  AppArmor enabled at all, which Kolla requires.

Passing `dm<N>` through used to cause a startup deadlock (*"Failed to start device
'dm0': The required device path doesn't exist"*) because stopping the container
deactivated the LV and removed `/dev/dm-N` from the VM. The `hold-osd` units in 3.8
prevent that, so the passthrough is safe — but **3.8 must be in place**, and if you
ever stop those units you will hit the deadlock again.

**Wait for systemd before checking anything.** The containers need time after restart
or you get *"Failed to connect to bus: No such file or directory"*:

```bash
sleep 20
for n in 1 2 3; do sudo incus exec ceph-node$n -- systemctl is-active systemd-udevd; done
```

All three must report `active`. The device-read test comes in 3.7, after the symlinks
exist — testing here just reports *"No such file or directory"*, which tells you
nothing.

### 3.7 Create device nodes and LVM symlinks

`dmsetup` and `vgmknodes` come from `lvm2`, which the base image from 3.3 already
provides. If these commands fail with `Error: Command not found`, the containers were
launched from a plain `images:ubuntu/24.04` instead — install the packages listed in
3.3 before continuing.

Clear any stale nodes and recreate them:

```bash
for n in 1 2 3; do
  sudo incus exec ceph-node$n -- bash -c 'rm -rf /dev/ceph-vg*/ /dev/mapper/ceph--*'
  sudo incus exec ceph-node$n -- dmsetup mknodes
  sudo incus exec ceph-node$n -- vgmknodes
done
```

**The `rm -rf` is not optional.** `/dev/dm-N` numbering is assigned in activation
order and changes whenever LVs are deactivated and reactivated, so symlinks left from
a previous boot can point at a *different node's volume*. Clearing first forces them
to be rebuilt from current DM state.

The warning *"The link should have been created by udev but it was not found.
Falling back to direct link creation"* is expected and harmless.

Without `vgmknodes`, `ceph orch daemon add osd` fails with
*"blkid: error: ceph-vg1/osd1: No such file or directory"*.

Now verify each container can actually **open** its device — this is what catches a
missing or wrong `dm<N>` entry from 3.6:

```bash
for n in 1 2 3; do
  sudo incus exec ceph-node$n -- dd if=/dev/ceph-vg$n/osd$n of=/dev/null bs=1M count=1 2>&1 | tail -1
done
```

All three must report bytes copied. *"Operation not permitted"* means the `dm<N>`
cgroup whitelist entry is missing or points at the wrong number — fix 3.6 before
continuing, or OSD creation will fail silently later.

### 3.8 Confirm the LV holds are running

**Stopping a container deactivates its LV.** The container is the last thing holding
the device open, so when it stops, device-mapper tears down the mapping and
`/dev/dm-N` disappears on the VM. On the next start the container's repair unit runs,
finds nothing to link, and the OSD has no device. Worse, the LVs get reactivated in a
different order later, which renumbers every dm device.

The `hold-osd{1,2,3}` services from 1.3 prevent this by keeping a file descriptor
open from the VM side. They start automatically; just confirm:

```bash
systemctl is-active hold-osd1 hold-osd2 hold-osd3
sudo lvs -o lv_name,vg_name,lv_attr
```

All three must be `active`, and each LV must show `-wi-ao----`. The `o` is the open
flag — that's what survives a container restart. `-wi-a-----` without it means a hold
isn't running, and the LV will deactivate on the next container stop.

### 3.9 Verify the mapping — do this before every OSD operation

Each container must resolve its LV to the *correct* device. A mismatch here means one
node's OSD writes to another node's volume: silent, cluster-wide data corruption.

```bash
echo "=== VM ==="; sudo dmsetup ls
echo "=== containers ==="
for n in 1 2 3; do echo "--- node$n"; sudo incus exec ceph-node$n -- ls -lL /dev/ceph-vg$n/; done
```

The major:minor shown for `osd<n>` inside ceph-node`<n>` must match the VM's
`ceph--vg<n>-osd<n>` entry. Example of a correct result — note the dm numbers need
not line up with the VG numbers:

```
ceph--vg1-osd1  (251:2)      node1: osd1  251, 2   ✓
ceph--vg2-osd2  (251:1)      node2: osd2  251, 1   ✓
ceph--vg3-osd3  (251:0)      node3: osd3  251, 0   ✓
```

If any row mismatches, or `ls -lL` shows `l?????????` (dangling link), re-run 3.7 and
check again. Do not proceed until all three match.

### 3.10 Make it survive restarts

Three pieces: a repair unit inside each container, the LV holds made permanent, and
storage reassembly on the VM.

**Inside each container** — recreates device nodes and symlinks at boot, before any
OSD tries to open its device:

```bash
for n in 1 2 3; do
  sudo incus exec ceph-node$n -- bash -c 'cat > /etc/systemd/system/ceph-dm-nodes.service <<EOF
[Unit]
Description=Recreate device-mapper nodes and LVM symlinks for Ceph
DefaultDependencies=no
After=systemd-udevd.service
Before=ceph.target

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c "rm -rf /dev/ceph-vg*/ /dev/mapper/ceph--*"
ExecStart=/sbin/dmsetup mknodes
ExecStart=/sbin/vgmknodes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ceph-dm-nodes.service'
done
```

`Before=ceph.target` matters — cephadm's OSD units are pulled in by that target.

**On the VM** — nothing to do. The image from 1.3 bakes in
`ceph-lab-assemble.service`, `hold-osd{1,2,3}.service`, and
`ceph-lab-remap.service`. Confirm all five are enabled and the first two stages ran:

```bash
systemctl is-enabled ceph-lab-assemble ceph-lab-remap hold-osd1 hold-osd2 hold-osd3
systemctl is-active ceph-lab-assemble hold-osd1 hold-osd2 hold-osd3
```

`ceph-lab-remap` will show `inactive` on a first install — it runs at boot, and on
this boot the containers didn't exist yet. That's expected; it takes effect from the
next machine restart onward.

**Verify** — this is the test that previously failed:

```bash
sudo incus restart ceph-node1 && sleep 20
sudo lvs -o lv_name,vg_name,lv_attr
sudo incus exec ceph-node1 -- ls -lL /dev/ceph-vg1/
```

`ceph-vg1` must still read `-wi-ao----` and the container must show a block device,
not a dangling link — with no manual intervention.

Note that loop device *numbers* can differ after a VM reboot. The VG-to-PV binding
lives in on-disk LVM metadata so `vgchange -ay` finds them regardless, but the Incus
`pv-disk` mapping from 3.6 is hardcoded by number. Check `losetup -a` against
`incus config device get ceph-node$n pv-disk source` after a machine restart.

### 3.11 Verify node prerequisites

Packages went in at 3.3. Confirm the two that cephadm's host check depends on:

```bash
for n in 1 2 3; do
  sudo incus exec ceph-node$n -- podman run --rm hello-world >/dev/null && echo "node$n podman ok"
  sudo incus exec ceph-node$n -- systemctl is-active chrony
done
```

All three must print `node$n podman ok` and `active`. Podman failing here means
cephadm cannot deploy anything — stop and fix it before Phase 4.

---

## Phase 4: Ceph

### 4.1 cephadm — runs inside ceph-node1, not on the VM

`cephadm bootstrap` must run on the host that will be the first mon. Running it on
the VM with `--mon-ip` pointing at a container fails with
*"OSError: [Errno 99] Cannot assign requested address"* — the VM can't bind a port on
an IP it doesn't own.

`cephadm` is already on every node from the pinned repo in 3.3. Confirm the version
matches what you chose in 0.3:

```bash
sudo incus exec ceph-node1 -- cephadm version
```

### 4.2 Bootstrap

Letting cephadm generate its own keypair is simpler than supplying one.

```bash
sudo incus exec ceph-node1 -- cephadm --image quay.io/ceph/ceph:v20.2.2 bootstrap \
  --mon-ip 10.100.0.11 \
  --initial-dashboard-password 'ChangeMeBeforeUse' \
  --skip-firewalld
```

`--image` is a **global** cephadm option and must come before the `bootstrap`
subcommand — placing it after gives `error: unrecognized arguments`. It pins the
cluster to the version chosen in 0.3. Without it
cephadm pulls `quay.io/ceph/ceph:v20`, which resolves to the newest Tentacle and
gives you a cluster no host client can authenticate against.

Confirm the version before going further:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph versions 2>/dev/null | head -5
```

Then fix `public_network` — bootstrap sets it to `10.100.0.1/32,10.100.0.0/24`, with
the `/32` being the bridge gateway leaking in from the container's routing view:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph config set global public_network 10.100.0.0/24
```

Bootstrap also leaves telemetry prompting in the dashboard. It ships **disabled**
(`enabled: false`, `last_upload: null`), so nothing is sent — but silencing it avoids
the nag on every dashboard visit:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph telemetry off
sudo incus exec ceph-node1 -- cephadm shell -- ceph telemetry status 2>/dev/null | grep -E '"enabled"|"last_upload"'
```

On failure: `sudo incus exec ceph-node1 -- cephadm rm-cluster --force --fsid <fsid>`.

### 4.3 Add nodes 2 and 3

cephadm manages its own keypair, separate from anything you created. `ceph orch host
add` uses that key, so distribute it:

```bash
CEPH_KEY=$(sudo incus exec ceph-node1 -- cephadm shell -- ceph cephadm get-pub-key | grep '^ssh-')
for n in 2 3; do
  sudo incus exec ceph-node$n -- mkdir -p /root/.ssh
  sudo incus exec ceph-node$n -- bash -c "echo '$CEPH_KEY' >> /root/.ssh/authorized_keys"
  sudo incus exec ceph-node$n -- chmod 700 /root/.ssh
done

sudo incus exec ceph-node1 -- cephadm shell -- ceph orch host add ceph-node2 10.100.0.12
sudo incus exec ceph-node1 -- cephadm shell -- ceph orch host add ceph-node3 10.100.0.13
sudo incus exec ceph-node1 -- cephadm shell -- ceph orch host ls
```

Append with `>>`. If you push a public key with `incus file push`, use
`--uid 0 --gid 0 --mode 600` — otherwise it lands owned by your macOS UID (501) and
sshd silently ignores it and falls back to a password prompt.

### 4.4 OSDs

**Re-run the 3.9 mapping verification first.** If a container's `osd<n>` resolves to
another node's device, the OSD you create will write to the wrong volume.

Pass the LV path explicitly. Do **not** rely on `ceph orch device ls` — it returns
empty even when this works.

```bash
for n in 1 2 3; do
  sudo incus exec ceph-node1 -- cephadm shell -- \
    ceph orch daemon add osd ceph-node$n:ceph-vg$n/osd$n
done
```

Run them **one at a time**, waiting for each `Created osd(s) N` before the next. A
tight loop can leave all three tagged `ceph.osd_id=0`, colliding on the same ID with
none registered.

If a command returns silently, it failed — get the reason from the log:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph log last 20 cephadm | grep -i "stderr\|error" | tail -15
```

#### "Created no osd(s) on host X; already created?"

A failed attempt leaves LVM tags on the volume. `ceph-volume` sees its own tags and
skips, even though no OSD was registered. Clear the tags and wipe the BlueStore
label, then retry:

```bash
n=1   # the node that failed
for t in $(sudo lvs --noheadings -o lv_tags ceph-vg$n/osd$n | tr ',' ' '); do
  sudo lvchange --deltag "$t" ceph-vg$n/osd$n
done
sudo dd if=/dev/zero of=/dev/ceph-vg$n/osd$n bs=1M count=100 conv=fsync
sudo lvs -o lv_name,lv_tags ceph-vg$n/osd$n
```

The tags column must be empty. Note that every failed attempt re-tags the LV, so
clear them again before each retry.

Check `ceph osd tree` for orphaned CRUSH entries too:
`ceph osd purge <id> --yes-i-really-mean-it`.

If it reports an error, the log has the real reason:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph log last 50 cephadm
```

Verify:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph osd tree
sudo incus exec ceph-node1 -- cephadm shell -- ceph status
```

Target state: 3 mons in quorum, 3 OSDs up and in, ~45 GiB avail, `HEALTH_OK`.

#### Recovering from a failed OSD attempt

A partial attempt leaves a CRUSH entry and a BlueStore label that block retries:

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph osd purge <id> --yes-i-really-mean-it
```

For the device, `ceph-volume raw zap` does not exist. Recreate the backing file — the
BlueStore label survives `dd` of the first 200 MB:

```bash
sudo losetup -d /dev/loop0
sudo rm -f /var/lib/ceph-disks/osd1.img
sudo truncate -s 15G /var/lib/ceph-disks/osd1.img
sudo losetup --find --show /var/lib/ceph-disks/osd1.img
```

Then redo the LVM setup for that VG.

### 4.5 Pools and OpenStack key

```bash
for p in glance-images cinder-volumes nova-vms; do
  sudo incus exec ceph-node1 -- cephadm shell -- ceph osd pool create $p 32
  sudo incus exec ceph-node1 -- cephadm shell -- rbd pool init $p
done

sudo incus exec ceph-node1 -- cephadm shell -- ceph auth get-or-create client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=glance-images' \
  mgr 'profile rbd pool=glance-images'

sudo incus exec ceph-node1 -- cephadm shell -- ceph auth get-or-create client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=cinder-volumes, profile rbd pool=nova-vms, profile rbd-read-only pool=glance-images' \
  mgr 'profile rbd pool=cinder-volumes, profile rbd pool=nova-vms'
```

**The user names matter.** Kolla-Ansible defaults to `ceph_glance_user: glance` and
`ceph_cinder_user: cinder`, and expects those entities to already exist on the
external cluster. A single combined user will not be found, and the failure surfaces
late as a missing keyring rather than as a clear error.

`client.cinder` needs read access to `glance-images` (Nova clones images from there
when booting) and write access to `nova-vms` — Nova's `rbd_user` is set to `cinder`,
not to a separate nova user.

Failure domains are nominal with all OSDs on one physical host. Set
`osd_crush_chooseleaf_type 0` if pools won't reach active+clean.

### 4.6 Configure and test the host Ceph client — do this before Phase 5

OpenStack reads Ceph credentials from `/etc/ceph` on the VM. Nova and Cinder link
librbd in-process, so the host client has to work — a container-based `rbd` is not a
substitute. Test it now: a failure here surfaces much later and far less clearly
during deployment.

```bash
ceph --version
```

Must report the version chosen in 0.3 (**20.2.2 tentacle** by default), installed by
the image build in 1.3. If it reports 19.2.x,
the pinned repo didn't take and nothing below will work.

Copy the config and both keyrings out of ceph-node1:

```bash
sudo mkdir -p /etc/ceph
sudo incus exec ceph-node1 -- cat /etc/ceph/ceph.conf | sudo tee /etc/ceph/ceph.conf > /dev/null

for u in glance cinder; do
  K=$(sudo incus exec ceph-node1 -- cephadm shell -- ceph auth get-key client.$u 2>/dev/null | tr -d '[:space:]')
  printf '[client.%s]\n\tkey = %s\n' "$u" "$K" | sudo tee /etc/ceph/ceph.client.$u.keyring > /dev/null
  sudo chmod 640 /etc/ceph/ceph.client.$u.keyring
  sudo chgrp libvirt /etc/ceph/ceph.client.$u.keyring
done
ls -l /etc/ceph/
```

**Watch the group ownership.** nova-compute must be able to read the keyring, and it
does not necessarily run as the user that owns `/etc/ceph`. If it can't, the symptom
is `ceph df ... Exit code: 13`, `RADOS permission denied`, and
`nova.exception.StorageError: Could not determine disk usage` — after which the
hypervisor never registers and `openstack hypervisor list` stays empty. Check which
user and group the compute service actually runs as and set the keyring group to
match. (Containerised deployments mount these in, so the in-container ownership is
what counts.)

Building each keyring from `get-key` avoids the stray "Inferring fsid" lines that
`ceph auth get` writes to stderr.

Verify both parse and can reach the cluster:

```bash
for u in glance cinder; do
  sudo ceph-authtool /etc/ceph/ceph.client.$u.keyring --print-key -n client.$u
done
sudo rbd -n client.glance --keyring /etc/ceph/ceph.client.glance.keyring ls glance-images && echo "glance RBD OK"
sudo rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring ls nova-vms && echo "cinder RBD OK"
```

`--print-key` must echo each key back. Empty output from `rbd` before the OK lines is
correct — the pools have no images yet.

Some deployment tools rewrite `/etc/ceph/ceph.conf` during their run. That's normally
harmless, but re-check the file afterwards if Ceph access stops working.

Two failures to recognise, both meaning the version pin didn't hold:

| Error | Cause |
|---|---|
| `error setting modifier for [client.X] type=key ... Malformed input` | client is older than the cluster and can't parse a type-2 key |
| `server allowed_methods [2] but i only support [2,1]` | the key is type 1 (starts `AQ`); the cluster requires method 2 |

Key prefixes tell you the crypto type: `AQ` is type 1 (AES-128), `Ag` is type 2.
A 20.2.2 cluster mints **`AQ`** keys, which is why a 20.2.2 client can read them —
type 2 arrived in 20.2.3. So on a correctly pinned build you should see `AQ`. Seeing
`Ag` means the cluster is 20.2.3+ and the `--image` pin in 4.2 didn't take.

---
## Phase 5: OpenStack via Kolla-Ansible

Kolla-Ansible deploys OpenStack as **prebuilt containers** pulled from Quay, so there
is no per-run build cost, and it is designed for deployments that persist and upgrade
rather than being torn down.

> **Verified.** A full `bootstrap-servers` → `prechecks` → `deploy` → `post-deploy`
> run completed in this lab, with Glance, Cinder and Nova all on Ceph RBD. The two
> host-requirement mismatches in 5.1 are real and must be solved first.

### 5.1 Network prerequisites — do these before anything else

Kolla's defaults assume a multi-node HA deployment on a normal network. Neither
assumption holds here, and getting this wrong costs hours. Two interfaces are needed,
and **neither should be `enp0s1`**.

#### Why not the VM's own interface

`enp0s1` sits on macOS's vmnet-shared network (`192.168.64.0/24`). Two problems:

- **The address changes on every machine recreate.** This lab saw `.13`, `.14`, `.21`,
  `.28`, `.30` across a day.
- **vmnet does anti-spoofing.** It hands each VM one DHCP address and won't carry
  traffic from an address it didn't assign — so a keepalived-managed floating VIP on
  that subnet **cannot work**, no matter how carefully you pick a free address.

#### A private interface for the control plane

Kolla wants a VIP: an address keepalived claims and haproxy binds, separate from the
host's own address. On `enp0s1` that is **impossible** — vmnet won't carry traffic
from an address it didn't assign by DHCP — which is why keepalived can never take a
VIP there, regardless of how carefully you pick a free one.

Give Kolla its own private subnet instead. Nothing outside the VM has any say over it,
so keepalived and VRRP work normally:

**The image creates this for you** (`kolla-net-setup.service`, 1.3). Verify:

```bash
systemctl is-active kolla-net-setup
ip -br addr show kolla0
```

Create it in the image, not interactively: interfaces and iptables rules do not
survive a reboot, and Kolla stays configured to use them.

- `kolla0` holds **10.10.10.1** — this is `network_interface`
- **10.10.10.10** stays free on that subnet — this is `kolla_internal_vip_address`

A `dummy` interface would be the natural choice, but `CONFIG_DUMMY` is not in this
kernel (`ip link add ... type dummy` → `Error: Unknown device type`). A veth pair does
the same job; the peer end just sits there unused.

#### The hostname must resolve to the kolla0 address — and only that

RabbitMQ clusters on hostnames, not IP addresses, so Kolla enforces that the host's
name resolves **uniquely** to the `api_interface` address (which defaults to
`network_interface`, i.e. `kolla0`). The machine image sets its own name to the vmnet
address, and `bootstrap-servers` adds the `kolla0` one, leaving two entries — which
fails the precheck:

```
Hostname has to resolve uniquely to the IP address of api_interface
```

The `getent` output must show **only** `10.10.10.1`. If both addresses appear, the
precheck will reject it regardless of which comes first.

**`/etc/hosts` is regenerated on every boot**, carrying the vmnet address instead of
`10.10.10.1`. The name still resolves, so it does not look like a name problem — but
not to the address RabbitMQ was deployed against, and rabbitmq then crash-loops with
`{epmd_error,"<hostname>",address}`, taking every nova and neutron agent down with it.
`docker logs rabbitmq` is the only place this is visible.

Fixing it once at deploy time is not enough. It belongs in `kolla-net-setup.service`
(1.3), so it is reapplied on every boot:

```sh
H=$(hostname)
sed -i -E "/^[0-9.]+[[:space:]]+${H}([[:space:]]|$)/d" /etc/hosts
echo "10.10.10.1 ${H}" >> /etc/hosts
```

Delete every entry for the name, not just the vmnet one — two entries fail the
precheck whatever the order.

#### A veth pair for Neutron's external interface

Kolla wants `neutron_external_interface` **up without an IP address**:

Also created by `kolla-net-setup.service`. Verify:

```bash
ip -br link show type veth
```

`veth-ext` must be **UP with no IP address**.

Upstream documents this: *in the case of a single interface on a machine, a veth pair
may be used where one end of the veth pair is listed here and the other end is in a
bridge on the system.*

#### Keep HAProxy and Keepalived enabled

It is tempting to turn both off on a single node. **Don't** — upstream explicitly
warns against it:

> If a development environment doesn't have a free IP address available for VIP
> configuration, the host's IP address may be used here by disabling HAProxy … Note
> this method is not recommended and generally not tested by the Kolla community, but
> included since sometimes a free IP is not available in a testing environment.

That fallback exists for when you *can't* get a free IP. With `kolla0` you can, so use
the supported path: defaults for `enable_haproxy`, `enable_keepalived` and
`enable_proxysql`, and a real VIP on the private subnet.

**If keepalived still won't take the VIP**, check for this in
`docker logs keepalived`:

```
Script user 'keepalived_script' does not exist
```

The image's default config references a user it doesn't ship, so the tracked health
script is treated as failed and the instance never leaves BACKUP. Workaround:

```bash
sudo docker exec keepalived useradd -r -s /sbin/nologin keepalived_script
sudo docker restart keepalived
sleep 45
ip -br addr show kolla0     # 10.10.10.10 should now be present
```

Confirm the VIP is actually claimed before assuming a later failure is unrelated — the
symptom otherwise is a five-minute
`Timeout when waiting for 10.10.10.10:61313` during deploy.

#### Host minimums

8 GB RAM and 40 GB disk, comfortably met by the 26 GB / 500 GB machine from 1.4.

> `network_interface` on a private subnet is non-routable from macOS, so Horizon needs
> the explicit port-forward in 6.2, and that forward must come from
> `kolla-net-setup.service` rather than your shell. Kolla's
> `kolla_external_vip_address` / `kolla_external_vip_interface` pair is designed for
> this split and would be tidier, but is untested here.

### 5.2 Create the deploy user and install

Kolla-Ansible needs a user that owns `/etc/kolla` and can write it without `sudo`
(the playbooks and `kolla-genpwd` write there), while still having passwordless sudo
for the host-level tasks. **Create a dedicated service account** — never use your
interactive login account, which differs per host and whose primary group may not
match its name.

```bash
sudo useradd -r -m -d /opt/kolla -s /bin/bash kolla
echo "kolla ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/kolla
sudo chmod 0440 /etc/sudoers.d/kolla
sudo chmod 755 /opt/kolla
sudo mkdir -p /etc/kolla
sudo chown -R kolla:kolla /etc/kolla
```

`chmod 755 /opt/kolla` matters: `useradd -m` creates the home mode 750, which blocks
other services (notably a web server) from traversing into it later.

Pick a release branch — same rule as 0.3 for Ceph: **the Kolla-Ansible branch and the
container image tag must match**, or you get Ansible from one release driving
containers from another.

```bash
git ls-remote --heads https://opendev.org/openstack/kolla-ansible.git 'refs/heads/stable/*' | tail -5
```

Use the newest `stable/YYYY.N`; `stable/2026.1` is current as of writing. Avoid
`master` — it's trunk, and nothing else in this guide runs unpinned.

Everything below runs **as the `kolla` user**:

```bash
sudo -u kolla -i
```

Then, inside that shell:

```bash
KOLLA_BRANCH=stable/2026.1

python3 -m venv --system-site-packages /opt/kolla/venv
source /opt/kolla/venv/bin/activate
pip install -U pip
pip install "git+https://opendev.org/openstack/kolla-ansible@$KOLLA_BRANCH"

# prechecks runs these imports with the venv's python, not the system one
pip install docker dbus-python

cp -r /opt/kolla/venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp /opt/kolla/venv/share/kolla-ansible/ansible/inventory/all-in-one /opt/kolla/

kolla-ansible install-deps
kolla-genpwd
```

Build dependencies (`python3-dev python3-venv libffi-dev libssl-dev
libdbus-glib-1-dev`) come from the image in 1.3.

#### If `install-deps` fails

`kolla-ansible install-deps` shells out to `ansible-galaxy`. Two failures are
environmental, not configuration:

- **`Ansible requires blocking IO on stdin/stdout/stderr`** — running unattended
  leaves `O_NONBLOCK` set on inherited handles. Route ansible's stdio through a
  regular file; `03-provision.sh` does this in `run_logged`.
- **`KeyError: 'results'`, exit 250** — a transient galaxy.ansible.com fault. Kolla
  retries five times in quick succession, so a short outage exhausts them all and
  looks permanent. Re-run it.

### 5.3 globals.yml

`/etc/kolla/globals.yml` ships as a ~900-line commented template. **Append** your
settings rather than editing in place — the file is entirely comments by default, so
anything you add at the end takes effect and is easy to find later.

Still as the `kolla` user, which owns the file. Substitute the VIP you chose in 5.1:

```bash
cat >> /etc/kolla/globals.yml <<'EOF'

# ---- lab settings ----
kolla_base_distro: "ubuntu"

# Must match the branch installed in 5.2.
openstack_release: "2026.1"

# Kolla images are NOT multiarch. Without this suffix you get x86-64 images.
openstack_tag_suffix: "-aarch64"

# Private control-plane interface from 5.1 — never enp0s1, whose address changes on
# every machine recreate and whose subnet (vmnet) forbids a floating VIP.
network_interface: "kolla0"
neutron_external_interface: "veth-ext"

# Free address on kolla0's subnet. kolla0 itself holds 10.10.10.1.
kolla_internal_vip_address: "10.10.10.10"

# External Ceph — the cluster from Phase 4.
glance_backend_ceph: "yes"
cinder_backend_ceph: "yes"
nova_backend_ceph: "yes"

ceph_glance_user: "glance"
ceph_glance_pool_name: "glance-images"
ceph_cinder_user: "cinder"
ceph_cinder_pool_name: "cinder-volumes"
ceph_nova_pool_name: "nova-vms"

EOF
```

**Do not set `enable_ceph_rgw` until RGW actually exists.** The lab ran with
`enable_ceph_rgw: true` and `ceph_rgw_hosts` pointing at `ceph-node1:8000` while
`ceph orch ls` showed no `rgw` service at all — Kolla had registered a Swift-compatible
endpoint in Keystone for a gateway that was never deployed. Any Swift client would
have got a connection refused from a service Keystone advertised as present.

RGW is v2 work, so `03-provision.sh` omits both keys. Add them, and re-run
`kolla-ansible deploy`, only after Phase 7 reports `1/1` running:

```yaml
enable_ceph_rgw: true
ceph_rgw_hosts:
  - host: ceph-node1
    ip: 10.100.0.11
    port: 8000
```

Verify each key appears **exactly once** uncommented — a duplicate earlier in the
template would be shadowed by yours, which works but is confusing to debug later:

```bash
grep -nE '^(kolla_base_distro|openstack_release|openstack_tag_suffix|network_interface|neutron_external_interface|kolla_internal_vip_address):' /etc/kolla/globals.yml
```

Six lines, near the end of the file. HAProxy, Keepalived and ProxySQL keep their
defaults (all enabled) — see 5.1 for why disabling them is the wrong instinct.

**Pool names must be overridden.** Kolla defaults to `images`, `volumes` and `vms`;
your Phase 4 pools are `glance-images`, `cinder-volumes` and `nova-vms`.

`ceph_nova_user` defaults to whatever `ceph_cinder_user` is — which matches Phase 4,
where `client.cinder` owns both `cinder-volumes` and `nova-vms`. Upstream notes that
if your Ceph tool generated separate Nova and Cinder keys you must override
`ceph_nova_user` to match.

### 5.4 Ceph config and keyrings — watch the tabs

Kolla reads per-service config from `/etc/kolla/config/<service>/`:

| Service | Files |
|---|---|
| Glance | `glance/ceph.conf`, `glance/ceph.client.glance.keyring` |
| Cinder | `cinder/ceph.conf`, `cinder/cinder-volume/ceph.client.cinder.keyring` |
| Nova | `nova/ceph.conf`, `nova/ceph.client.cinder.keyring` |

**Strip leading tabs from `ceph.conf`.** Upstream is explicit: files produced by
`ceph config generate-minimal-conf` have leading tabs, and *these tabs break Kolla
Ansible's ini parser*. The config you copied in 4.6 came from cephadm and has exactly
this problem.

Still as the `kolla` user. The keyrings in `/etc/ceph` are root-owned, so reading them
needs `sudo`:

```bash
for svc in glance cinder nova; do
  mkdir -p /etc/kolla/config/$svc
  sudo sed 's/^[[:space:]]*//' /etc/ceph/ceph.conf > /etc/kolla/config/$svc/ceph.conf
done
mkdir -p /etc/kolla/config/cinder/cinder-volume

sudo cat /etc/ceph/ceph.client.glance.keyring > /etc/kolla/config/glance/ceph.client.glance.keyring
sudo cat /etc/ceph/ceph.client.cinder.keyring > /etc/kolla/config/cinder/cinder-volume/ceph.client.cinder.keyring
sudo cat /etc/ceph/ceph.client.cinder.keyring > /etc/kolla/config/nova/ceph.client.cinder.keyring
chmod 600 /etc/kolla/config/*/*.keyring /etc/kolla/config/cinder/cinder-volume/*.keyring

grep -P '^\t' /etc/kolla/config/glance/ceph.conf && echo "TABS REMAIN — fix before deploying"
```

`sudo cat > file` rather than `sudo cp` keeps the destination owned by `kolla`.

**cephadm's minimal config is not enough.** What you copied has only `fsid` and
`mon_host`; upstream's example also carries the keyring path and the three cephx
lines, without which the clients fall back to defaults and may not find the right
keyring. Add them per service — the `keyring` path differs, and Glance uses its own
user while Nova shares Cinder's:

```bash
cat >> /etc/kolla/config/glance/ceph.conf <<'EOF'
keyring = /etc/ceph/ceph.client.glance.keyring
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx
EOF

for d in cinder nova; do
cat >> /etc/kolla/config/$d/ceph.conf <<'EOF'
keyring = /etc/ceph/ceph.client.cinder.keyring
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx
EOF
done

tail -n 6 /etc/kolla/config/glance/ceph.conf /etc/kolla/config/nova/ceph.conf
```

Those `keyring` paths are the **in-container** locations Kolla mounts each service's
keyring to, not the host paths under `/etc/kolla/config/`.

The final layout:

```
/etc/kolla/config/
├── cinder/ceph.conf
├── cinder/cinder-volume/ceph.client.cinder.keyring
├── glance/ceph.conf
├── glance/ceph.client.glance.keyring
└── nova/ceph.conf
    nova/ceph.client.cinder.keyring
```

All owned by `kolla`, keyrings mode 600.

### 5.5 Inventory

With external Ceph there may be no nodes in the `[storage]` group, and upstream warns
this *will cause Cinder and related services relying on this group to fail*. Add the
host running `cinder-volume`:

```bash
grep -A3 '^\[storage\]' /opt/kolla/all-in-one
```

For `all-in-one` this should already be `localhost`; verify rather than assume.

### 5.6 Deploy

Run these **inside the `kolla` shell from 5.2**, with the venv already active — your
prompt should read `(venv) kolla@...`. `sudo -u kolla -i` opens an interactive shell,
so anything pasted after it in the same block runs in your *original* shell as the
wrong user; and `source` only affects the shell it runs in. If you're in a fresh
terminal, switch and activate first, as two separate steps:

```bash
sudo -u kolla -i
```

```bash
source /opt/kolla/venv/bin/activate
```

Then, one command at a time — `prechecks` before `deploy`, never combined:

```bash
kolla-ansible bootstrap-servers -i /opt/kolla/all-in-one
kolla-ansible prechecks         -i /opt/kolla/all-in-one --use-test-images
kolla-ansible deploy            -i /opt/kolla/all-in-one
kolla-ansible post-deploy        -i /opt/kolla/all-in-one
```

**`--use-test-images` is a `prechecks`-only flag** — `deploy` doesn't run the registry
check and rejects it with `error: unrecognized arguments`. It, and it is less
alarming than it sounds. Kolla publishes to `quay.io/openstack.kolla` for every tagged
release *and* daily from CI — one namespace for both, so the gate fires on the
namespace rather than on what you're actually pulling. With `openstack_release`
pinned (5.3) you get the release tag, not trunk. Upstream's recommendation for
anything beyond a lab is to mirror the images into your own registry and point
`docker_registry` at it.

The gate message:

```
Kolla images from quay.io/openstack.kolla namespace are meant only for testing
purposes, if you want to continue using them please use --use-test-images CLI argument
```

Those are the prebuilt aarch64 images this whole approach depends on, so for a lab the
flag is simply the acknowledgement. **Host libvirt and the AppArmor profile are handled by the image** (1.3):
`libvirt-apparmor-load.service` loads the profile Kolla expects to remove, and the
host `libvirtd` units are disabled so the containerised libvirt can own
`/var/run/libvirt/libvirt-sock`. Verify before deploying:

```bash
sudo aa-status | grep -i libvirtd
systemctl is-active libvirtd libvirtd.socket
ls -l /var/run/libvirt/libvirt-sock 2>&1
```

`libvirtd` should be listed by `aa-status`, both units `inactive`, and the socket
absent.

`prechecks` is the valuable one — it catches the interface and VIP problems from 5.1
before any deployment happens. Don't skip it.

#### The first `deploy` fails on MariaDB. Run it again.

On a clean build, `deploy` fails with `Timeout when waiting for search string MariaDB`
and `mariadb containers are missing or not running`. Note the `"elapsed": 10` in the
error: on first start MariaDB has to create its data directory, which takes longer on
a VM disk than the ten seconds Kolla's liveness check allows. The container is not
broken — check a few seconds later and it is healthy.

`deploy` is idempotent. Do not reconfigure anything and do not `destroy` — just run it
again. With `03-provision.sh` that means running it again; the checkpoint resumes at
`80-deploy`, and `bootstrap-servers` is checkpointed separately so it is not repeated.

Credentials land in `/etc/kolla/clouds.yaml`; point clients at it with
`OS_CLIENT_CONFIG_FILE`.

```bash
pip install python-openstackclient

export OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml
export OS_CLOUD=kolla-admin

openstack service list
```

Those two exports are needed for every `openstack` command; put them in the `kolla`
user's shell profile if you don't want to repeat them.

### 5.7 What this does and doesn't solve

**Solves:** the rebuild cost. Redeploys pull cached images instead of recompiling, so
reconfiguring the cloud is cheap rather than a multi-hour cycle.

**Doesn't solve:** Octavia's management network. `lb-mgmt-net` plus a host interface
into it is Octavia's own architecture, not a deployment-tool quirk — it applies here
too. Kolla has an Octavia role with its own setup procedure, and it is a separate
piece of work either way.

**Risks:** the aarch64 image set is less travelled than x86-64 — there is an open
Launchpad bug about per-host `kolla_base_distro` being ignored in mixed-architecture
deployments. Single-architecture avoids that specific case, but it indicates the path
is not heavily worn.

---

## Phase 6: Verification

Credentials come from `/etc/kolla/clouds.yaml` (see 5.6). Inspect services with
`docker ps` and `docker logs <container>`.

### 6.1 Services and hypervisor

```bash
export OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml
export OS_CLOUD=kolla-admin
openstack compute service list
openstack hypervisor list
```

All four Nova services must be `up`. `hypervisor list` must show one entry — this is
what proves libvirt reached `/dev/kvm` through the nested virtualization.

**If `hypervisor list` is empty** but the services are up, compute failed to register.
Check why, fix it, then map the host into the cell:

```bash
docker logs nova_compute 2>&1 | grep -B5 ERROR | tail -20
docker exec -it nova_conductor nova-manage cell_v2 discover_hosts --verbose
openstack hypervisor list
```

The most likely cause is nova-compute not being able to read its Ceph keyring — see
4.6. `discover_hosts` finds nothing until compute has registered successfully at least
once.

The hypervisor type displays as **QEMU** even with KVM active; check
`grep '^virt_type' /etc/nova/nova.conf` for the truth (it should say `kvm`).

### 6.2 Reaching the web UIs from macOS

Both dashboards now live on addresses macOS cannot route to:

| UI | Address | Why unreachable from macOS |
|---|---|---|
| Horizon | the `kolla0` VIP, `10.10.10.10` | private control-plane subnet inside the VM (5.1) |
| Ceph | `10.100.0.11:8443` on ceph-node1 | Incus bridge, inside the VM (3.2) |

The VM's own vmnet address is the only thing macOS can reach. Find it:

```bash
ip -br addr show enp0s1
```

Something like `192.168.64.35/24` — **it changes on every machine recreate**, so check
it each time rather than writing it down.

#### Horizon

Horizon binds the VIP on `kolla0`. **The forward is set up by
`kolla-net-setup.service` from 1.3** — verify rather than re-adding:

```bash
sudo iptables -t nat -L PREROUTING -n | grep 8080
```

One rule in each of PREROUTING and POSTROUTING. If `grep` finds nothing,
`kolla-net-setup.service` did not run — fix the unit rather than adding the rules by
hand, which will not survive the next reboot.

**Test from macOS, not from the VM.** The PREROUTING rule matches `-i enp0s1`, so
loopback traffic never hits it and a local `curl 127.0.0.1:8080` always fails —
that proves nothing:

```bash
# on macOS
curl -sS -o /dev/null -w '%{http_code}\n' http://<VM_IP>:8080/
```

A 200 or 302 means the forward works. Then open `http://<VM_IP>:8080/` in a browser —
the trailing slash matters.

If it fails, check where Horizon actually bound:

```bash
sudo ss -tlnp | grep -E ':80 |:8080 '
```

The DNAT target must match what's listening.

**The admin password is generated, not chosen.** `kolla-genpwd` (5.2) randomises every
password; there is no default to guess:

```bash
grep keystone_admin_password /etc/kolla/passwords.yml
```

Log in as **admin** with that value, domain `Default`. (`ChangeMeBeforeUse` in this
guide only ever refers to the Ceph dashboard, which you set explicitly at
`cephadm bootstrap` in 4.2.)

> **Untested.** The DNAT rules above are the standard approach but have not been run
> in this lab. If they don't work, an SSH tunnel from macOS is the simpler fallback:
> `ssh -L 8080:10.10.10.10:80 <user>@<VM_IP>` — though `container machine` may not
> expose SSH, in which case the iptables route is the only option.

#### Ceph dashboard

Two hops: the dashboard is inside a container on the Incus bridge. An Incus proxy
device brings it to the VM, then the same DNAT brings it to macOS:

```bash
sudo incus config device add ceph-node1 dashboard proxy \
  listen=tcp:0.0.0.0:8443 \
  connect=tcp:10.100.0.11:8443

curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443
```

The proxy device listens on all VM interfaces, including `enp0s1`, so this one needs
no iptables — from macOS: `https://<VM_IP>:8443`

User **admin**, password from `--initial-dashboard-password` in 4.2. Self-signed
certificate, so accept the browser warning.

Ceph forces a password change on first login. Clear it with `--force-password`, which
also resets the must-change flag:

```bash
echo -n 'ChangeMeBeforeUse' | sudo incus exec ceph-node1 -- cephadm shell -- \
  ceph dashboard ac-user-set-password admin --force-password -i -
```

(`ac-user-set-password-policy` does not exist — `ceph dashboard --help` lists the real
subcommands.)

Remove the proxy later with
`sudo incus config device remove ceph-node1 dashboard`.

#### Grafana, Prometheus and Alertmanager

`cephadm` deploys the whole monitoring stack at bootstrap — Grafana on 3000,
Prometheus on 9095, Alertmanager on 9093/9094, node-exporter and ceph-exporter on every
host. Nothing extra has to be installed.

They need the same two hops as the dashboard, and one thing more. The dashboard shows
Grafana's graphs in an **iframe**, which the *browser* loads — so the URL has to be one
macOS can resolve. Out of the box it is `https://ceph-node1:3000`, a name that exists
only inside the Incus network, and every "Overall Performance" tab renders as an empty
grey frame with a broken-image icon:

```bash
for p in 3000:grafana 9095:prometheus 9093:alertmanager; do
  sudo incus config device add ceph-node1 "${p#*:}" proxy \
    listen=tcp:0.0.0.0:"${p%%:*}" connect=tcp:10.100.0.11:"${p%%:*}"
done

VM_IP=$(ip -br addr show enp0s1 | awk '{print $3}' | cut -d/ -f1)
sudo incus exec ceph-node1 -- cephadm shell -- ceph dashboard set-grafana-api-url "https://$VM_IP:3000"
sudo incus exec ceph-node1 -- cephadm shell -- ceph dashboard set-grafana-api-ssl-verify false
sudo incus exec ceph-node1 -- cephadm shell -- ceph dashboard set-prometheus-api-host "http://$VM_IP:9095"
sudo incus exec ceph-node1 -- cephadm shell -- ceph dashboard set-alertmanager-api-host "http://$VM_IP:9093"
```

**The URL must carry the VM address, not `127.0.0.1`.** This is the opposite of the
`s3cfg` rule in 7.3: `s3cfg` is read by a client inside the VM, so loopback is right
there; these URLs are resolved by a browser on macOS, so loopback is wrong. And since
the VM address changes on every start, `03-provision.sh` re-sets all four on every
`90-verify` run rather than once at bootstrap.

Grafana has its own self-signed certificate on 3000, separate from the dashboard's on
8443. Visit `https://<VM_IP>:3000/` once and accept it, or the iframe stays blank with
no visible error — the dashboard cannot tell you that the browser refused a certificate
it never saw.

`set-grafana-api-ssl-verify false` covers the other direction: the dashboard backend
also calls Grafana's API to check it is alive.

Prometheus and Alertmanager are plain HTTP and need no exception. Prometheus at
`http://<VM_IP>:9095/targets` is the quickest proof the whole chain works.

### 6.3 What survives a restart

| Thing | Survives? |
|---|---|
| `kolla0`, `veth-ext`, Horizon DNAT | yes — `kolla-net-setup.service` (1.3) |
| Incus proxy devices (dashboard, RGW, NFS, monitoring) | yes — stored in `/var/lib/incus` |
| `o-hm0`, Octavia's health-manager port | **not without help** — see below |
| The dashboard's Grafana/Prometheus/Alertmanager URLs | **no** — they embed the VM address, so `90-verify` re-sets them |
| The VM's vmnet address | **no** — changes on every machine recreate |

Only the address you type into the browser changes. Re-check it with
`ip -br addr show enp0s1` after any `container machine stop` / `run`.

### 6.4 Upload an image

**CirrOS works on aarch64** — tested with 0.6.3, which boots, leases, fetches
metadata and accepts SSH:

```
Starting network: dhcpcd-9.4.1 starting
eth0: waiting for carrier
eth0: carrier acquired
checking http://169.254.169.254/2009-04-04/instance-id
c512 login:
```

At 25 MB and a 512 MB flavor it is roughly a quarter the footprint of an Ubuntu cloud
image, which matters when the whole VM has ~13 GB spare. Use it for anything that just
needs to be a running, reachable workload; use Ubuntu when you need cloud-init to
install packages or run a real service.

> An earlier version of this guide claimed CirrOS runs `dhcpcd` before carrier and
> never gets a lease. That is wrong — it waits for carrier, as the log above shows.
> The failure that produced that claim was almost certainly the flavor-size one
> below: under 512 MB GRUB dies with `error: out of memory` before Linux ever starts,
> and the instance is unreachable for that reason instead.

```bash
wget -q https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img
openstack image create ubuntu-arm64 \
  --file noble-server-cloudimg-arm64.img \
  --disk-format qcow2 --container-format bare --public
```

Confirm it went to Ceph rather than local disk — the `locations` property should read
`rbd://<fsid>/glance-images/<image-id>/snap`:

```bash
openstack image show ubuntu-arm64 -f value -c properties | tr ',' '\n' | grep rbd
```

All images must be **aarch64**. x86_64 either fails to boot or falls back to slow
emulation.

### 6.5 Network access: security group, key, floating IP

The default security group blocks all ingress, so open SSH and HTTP:

```bash
openstack security group rule create --proto tcp --dst-port 22 default
openstack security group rule create --proto tcp --dst-port 80 default
openstack security group rule create --proto icmp default

sudo mkdir -p /etc/openstack-lab
sudo chmod 755 /etc/openstack-lab
openstack keypair create labkey | sudo tee /etc/openstack-lab/labkey.pem > /dev/null
sudo chmod 644 /etc/openstack-lab/labkey.pem
```

### 6.6 Boot a real workload

Booting to a login prompt proves very little. This boots an instance that serves HTTP,
which exercises compute, RBD storage, DHCP, the metadata service, cloud-init,
security groups and floating-IP NAT in one test.

```bash
cat << 'EOF' > /tmp/web.yaml
#cloud-config
package_update: true
runcmd:
  - |
    cat > /var/www/index.html <<'HTML'
    <h1>OpenStack on Ceph, on an M4 Mac</h1>
    <p>Served from an instance whose disk lives in Ceph RBD.</p>
    HTML
  - [ sh, -c, "cd /var/www && nohup python3 -m http.server 80 >/var/log/webdemo.log 2>&1 &" ]
EOF

openstack server create web-demo \
  --image ubuntu-arm64 \
  --flavor m1.small \
  --network private \
  --key-name labkey \
  --user-data /tmp/web.yaml
```

`/var/www` may not exist on a bare cloud image; if the page 404s, `mkdir -p /var/www`
belongs in `runcmd` before the write.

Wait for it — Ubuntu's first boot takes a few minutes:

```bash
sleep 180
openstack server list
openstack console log show web-demo 2>&1 | tail -5
```

You want `ACTIVE`, an address on `private`, and a `login:` prompt in the console log.

**Flavor note: 512 MB is the floor, whatever the image.** Below it, aarch64 UEFI GRUB
fails before Linux starts, and the console shows the cause followed by its consequence:

```
error: out of memory.
error: you need to load the kernel first.
Failed to boot both default and fallback entries.
```

The second line is the misleading one — it reads like a missing kernel or a broken
image, and it is neither. Verified: a 128 MB flavor fails this way, 512 MB boots
CirrOS cleanly, and 2 GB is needed for Ubuntu cloud images. If a flavor of the name you want already exists,
`flavor create` fails while leaving you on the existing (possibly tiny) one.

### 6.7 Floating IP and the actual test

```bash
FIP=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip web-demo "$FIP"
echo "http://$FIP/"

curl -sS -m 10 "http://$FIP/"
ssh -i /etc/openstack-lab/labkey.pem ubuntu@"$FIP"
```

The `curl` returning the page is the end-to-end proof. The floating range is
`172.24.4.0/24` on `br-ex`, which lives inside the VM — reachable from the VM, and
from macOS only if you add a route or another Incus-style proxy.

### 6.8 Confirm the data is in Ceph

```bash
sudo rbd ls -p glance-images -n client.glance --keyring /etc/ceph/ceph.client.glance.keyring
sudo rbd ls -p nova-vms      -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring
sudo incus exec ceph-node1 -- cephadm shell -- ceph df
```

`nova-vms` should contain `<instance-uuid>_disk` for each running instance. That, plus
the image in `glance-images`, is the whole point of the lab.

---
## Phase 7: Object storage (S3) via Ceph RGW

The best value-per-effort addition: one orchestrator command, no image builds, no
re-stack, and it can't disturb the working OpenStack deployment. Gives you an S3
endpoint backed by the same cluster.

Automated as phase **`85-rgw`** in `03-provision.sh`. The text below is the reference
for what it does.

**Poll the endpoint, don't trust `ceph orch ls`.** It reports `1/1` as soon as the
daemon is placed, several seconds before `radosgw` binds its port — and it keeps
reporting `running` for a daemon that has exited. Readiness means a TCP connect or a
real request, here and in Phase 8.

**The VM-side proxy port must not clash with Kolla.** RGW serves 8000 inside
`ceph-node1`, which is its own namespace, but on the VM 8000 is Kolla's heat-api-cfn
behind haproxy — so a proxy device listening on `0.0.0.0:8000` cannot bind. This guide
uses **8100** on the VM side:

```bash
sudo incus config device add ceph-node1 rgw proxy \
  listen=tcp:0.0.0.0:8100 connect=tcp:10.100.0.11:8000
```

Check before choosing another, and do not discard the exit code of
`incus config device add` — a failed bind leaves no device and the only symptom is a
connection error against a healthy gateway:

```bash
ss -tln | awk 'NR>1{print $4}' | sed 's/.*://' | sort -n -u
```

8443 (Ceph dashboard) and 2049 (NFS) are clear of Kolla; 8000 is not.

### 7.2 Verify the endpoint

```bash
sudo incus exec ceph-node1 -- curl -sS -m 5 http://localhost:8000
```

A working gateway returns `ListAllMyBucketsResult` XML with an `anonymous` owner.

### 7.3 Create a user

```bash
sudo incus exec ceph-node1 -- cephadm shell -- radosgw-admin user create \
  --uid=labuser --display-name="Lab User" 2>/dev/null

sudo incus exec ceph-node1 -- cephadm shell -- radosgw-admin user info --uid=labuser 2>/dev/null \
  | grep -E 'access_key|secret_key'
```

Don't `grep -A3 '"keys"'` — that truncates before the secret. Record both keys.

### 7.4 Reach it from the VM and from macOS

RGW listens inside the container, so add a proxy device the same way as the Ceph
dashboard in 6.3:

```bash
sudo incus config device add ceph-node1 rgw proxy \
  listen=tcp:0.0.0.0:8000 \
  connect=tcp:10.100.0.11:8000

curl -sS -m 5 http://<VM_IP>:8000
```

Then test with a real S3 client. `s3cmd` is in the image from 1.3. Skip
`s3cmd --configure` — it's interactive and fiddly; write the config directly:

```bash
sudo mkdir -p /etc/openstack-lab
sudo tee /etc/openstack-lab/s3cfg > /dev/null <<'EOF'
[default]
access_key = <ACCESS_KEY from 7.3>
secret_key = <SECRET_KEY from 7.3>
host_base = <VM_IP>:8000
host_bucket = <VM_IP>:8000/%(bucket)s
use_https = False
signature_v2 = True
EOF
sudo chmod 600 /etc/openstack-lab/s3cfg
```

Pass it explicitly with `s3cmd -c /etc/openstack-lab/s3cfg` (shown below) rather than
relying on a `~/.s3cfg` in whichever account you happen to be using.

**Point `host_base` at `127.0.0.1`, not the VM's address.** `enp0s1` gets a new vmnet
address on every machine restart, and this file is written once. Embedding the VM IP
works right up until the first reboot, after which every `s3cmd` call fails against a
gateway that is running perfectly well:

```
host_base = 127.0.0.1:8100
host_bucket = 127.0.0.1:8100/%(bucket)s
```

The proxy device listens on `0.0.0.0:8100`, so loopback always reaches it. From macOS
use the current VM address instead — phase `90-verify` prints it on every run.

Three settings that matter:

- **`signature_v2 = True`** is required. With v4 every request fails
  `ERROR: S3 error: 403 (SignatureDoesNotMatch)`, because the v4 signature covers the
  Host header and RGW's configured hostname doesn't match what the client sends
  through the proxy device.
- **`host_bucket` in path style** (`<VM_IP>:8000/%(bucket)s`) avoids needing wildcard
  DNS for virtual-hosted buckets.

`s3cmd` on Ubuntu 24.04 prints `SyntaxWarning: invalid escape sequence` lines under
Python 3.12. Cosmetic — ignore them.

Full round-trip:

```bash
S3=(sudo s3cmd -c /etc/openstack-lab/s3cfg)

"${S3[@]}" mb s3://testbucket
echo "hello from ceph" > /tmp/hello.txt
"${S3[@]}" put /tmp/hello.txt s3://testbucket/
"${S3[@]}" ls s3://testbucket/
"${S3[@]}" get s3://testbucket/hello.txt /tmp/hello-back.txt --force
cat /tmp/hello-back.txt
```

### 7.5 Confirm it landed in Ceph

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph df
sudo incus exec ceph-node1 -- cephadm shell -- radosgw-admin bucket list
```

New `.rgw.*` pools appear alongside the RBD ones, holding the object data.

---

## Phase 8: Shared filesystem (CephFS) and an NFS export

Pure Ceph — a filesystem plus a cephadm-managed NFS-Ganesha cluster. No Manila, so
shares are created here rather than self-serviced through the OpenStack API. That is
the deliberate v2 scope: it delivers a real NFS export that guests and macOS can mount,
without adding three more Kolla containers and another re-deploy.

Automated as phase **`86-nfs`** in `03-provision.sh`.

### 8.1 Create the filesystem and the NFS cluster

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph fs volume create labfs --placement="1 ceph-node1"
sudo incus exec ceph-node1 -- cephadm shell -- ceph nfs cluster create labnfs "1 ceph-node1"
```

`fs volume create` creates the data and metadata pools and deploys an MDS. Wait for an
active MDS before exporting — `ceph fs status labfs` must show `active`.

### 8.2 Export it, and install rpcbind

Two non-obvious requirements, both mandatory.

**rpcbind must be installed in the node, even though the lab only uses v4.** cephadm
hardcodes `Protocols = 3, 4;` into the `ganesha.conf` it generates; neither a v4-only
export nor `ceph nfs cluster config set` overrides it. So ganesha attempts NFSv3
registration on every start, that goes through rpcbind, and without it the daemon exits
`2/INVALIDARGUMENT` before serving anything — while `ceph orch ps` still reports it
running. `rpcbind` is therefore in the node base image (3.3). Do not remove it.

```bash
sudo incus exec ceph-node1 -- systemctl is-active rpcbind    # must be 'active'
```

**Pin the export to v4 by applying JSON.** `ceph nfs export create` defaults to
`protocols: [3, 4]`; v4 also carries mount and lock over 2049 alone, so one proxy
device suffices.

```bash
sudo incus exec ceph-node1 -- bash -c "cat <<'JSON' | cephadm shell -- ceph nfs export apply labnfs -i -
{
  \"export_id\": 1, \"path\": \"/\", \"cluster_id\": \"labnfs\",
  \"pseudo\": \"/labshare\", \"access_type\": \"RW\", \"squash\": \"none\",
  \"protocols\": [4], \"transports\": [\"TCP\"],
  \"fsal\": {\"name\": \"CEPH\", \"fs_name\": \"labfs\"}
}
JSON"
```

**After any crash-loop, `reset-failed` before redeploying.** systemd trips its restart
limit and refuses to start the unit even once the cause is fixed:

```bash
sudo incus exec ceph-node1 -- systemctl reset-failed 'ceph-*@nfs.labnfs.*.service'
sudo incus exec ceph-node1 -- cephadm shell -- ceph orch redeploy nfs.labnfs
```

### 8.3 The kernel needs NFSv4.1, not just NFSv4

cephadm's config sets `Minor_Versions = 1, 2`, so the server speaks **only** 4.1 and
4.2. A kernel with `CONFIG_NFS_V4=y` but `CONFIG_NFS_V4_1` unset has nothing to
negotiate and every mount fails with `mount.nfs4: Protocol not supported` — while
`nfs4` is in `/proc/filesystems` and the client looks capable. Check the minor version
specifically:

```bash
zcat /proc/config.gz | grep -E '^(# )?CONFIG_NFS_V4_1'
```

`CONFIG_NFS_V4_1=y` and `CONFIG_NFS_V4_2=y` are in the kernel config block in 1.1.

**A kernel swap does not need the machine rebuilt.** `container machine set` takes a
kernel path and applies it on the next restart; the filesystem persists, so a running
lab picks up a new kernel with no re-provisioning:

```bash
./01-build-kernel.sh
container machine set -n openstack-lab kernel=~/openstack-ceph-lab/vmlinux-arm64
container machine stop openstack-lab && container machine run
```

`uname -r` will not change — `LOCALVERSION` comes from the upstream git SHA. Verify
with `/proc/config.gz`.

### 8.4 Reach it from the VM and from macOS

Ganesha listens inside the container, so it needs a proxy device like RGW and the
dashboard. **NFSv4 only**, which is what Ceph's Ganesha serves by default — v4 carries
mount and lock protocols over port 2049 alone, so one proxy device is enough. NFSv3
would additionally need rpcbind, mountd and statd on their own ports.

```bash
sudo incus config device add ceph-node1 nfs proxy \
  listen=tcp:0.0.0.0:2049 connect=tcp:10.100.0.11:2049
```

`nfs-common` is in the image package list (1.3) — without it there is no `mount.nfs4`
and nothing can mount the export.

```bash
sudo mkdir -p /mnt/labshare
sudo mount -t nfs4 -o proto=tcp,port=2049 127.0.0.1:/labshare /mnt/labshare
echo hello | sudo tee /mnt/labshare/hello.txt
```

From macOS the same export is at `<VM_IP>:/labshare`, through the proxy device.

### 8.5 Confirm it landed in Ceph

```bash
sudo incus exec ceph-node1 -- cephadm shell -- ceph fs ls
sudo incus exec ceph-node1 -- cephadm shell -- ceph df
```

New `cephfs.labfs.data` and `cephfs.labfs.meta` pools appear alongside the RBD and
`.rgw.*` ones.

---

## Further work

Not attempted. Listed so the options are on record, in rough order of how much work
each is.

- **Ceph 20.2.4.** The 20.2.2 pin exists only because 20.2.3+ mints type-2 cephx keys
  and upstream had published no noble client. It has since published noble arm64 for
  20.2.4, so the constraint may be gone. One-line change — `CEPH_VERSION` in
  `02-build-image.sh` (see 0.3).
- **Load balancing (Octavia).** Two providers, and the choice is not free: the default
  amphora driver runs one Nova VM per load balancer and needs an aarch64 amphora
  image, certificates and `lb-mgmt-net`; `ovn-octavia-provider` needs none of that but
  requires Neutron on OVN, which this deployment is not, and Kolla has no supported
  in-place OVS→OVN migration.
- **Manila.** Self-service shared filesystems through the OpenStack API, on top of the
  CephFS that Phase 8 already creates. Adds three containers and a re-deploy.
- **Barbican.** Secret storage. Comes along automatically with Octavia if TLS
  termination is wanted.
- **Kubernetes.** Cluster API provider OpenStack (CAPO) needs Nova, Neutron, Cinder
  and Octavia. Magnum is the OpenStack-native alternative but also wants Heat. Cinder
  CSI works against the existing Cinder; Manila CSI would cover RWX volumes.
- **Swift-compatible S3 in Keystone.** Register the existing RGW as a Swift endpoint
  with `enable_ceph_rgw` and `ceph_rgw_hosts` (5.3) and re-run `deploy`. Only after
  the gateway is confirmed running — see the warning in 5.3.

## After a restart

### Container restart

Handled automatically by `ceph-dm-nodes.service` inside the container plus the LV
holds on the VM. Verify:

```bash
sudo lvs -o lv_name,vg_name,lv_attr        # all -wi-ao----
sudo incus exec ceph-node1 -- cephadm shell -- ceph status
```

### Machine restart (`container machine stop` / `run`)

**What survives: the whole filesystem.** Incus containers and their config, Ceph
cluster data, the OSD disk images, and anything else written at runtime. The cluster
recovers with no data loss.

**Bake units into the image.** Not for persistence -- the filesystem survives a
restart -- but because the image is the reproducible artifact, and a unit written by
hand is gone the moment you `container machine delete` and recreate.

**What does not survive:** interfaces, addresses, iptables rules — and `/etc/hosts`,
which is regenerated from scratch carrying the new vmnet address. Anything created
with `ip link`, `ip addr` or `iptables` at runtime is gone on the next boot unless a
unit recreates it. This is what `kolla-net-setup.service` is for, and why it fixes
`/etc/hosts` as well as the interfaces — see 5.1.

**Verified.** `container machine stop` followed by `container machine run` returns the
lab to service unattended, including boots where the dm minor numbers shuffled and
`ceph-lab-remap.service` repointed each node to its own volume.

**Octavia's `o-hm0` does not come back on its own.** Kolla writes
`octavia-interface.service` ordered `After=docker.service`, but docker being up is not
the same as the openvswitch container having recreated `br-int`'s ports. On every
restart the unit runs first, its `ExecStartPre` dies with `Cannot find device "o-hm0"`,
and systemd burns all five default retries inside one second:

```
octavia-interface.service: Start request repeated too quickly.
```

The unit stays failed, `o-hm0` stays DOWN, and the health manager has no path to the
amphorae — so load balancers are silently unmonitored. Nothing reports it: all four
octavia containers are healthy, and `openstack loadbalancer list` looks fine.

`03-provision.sh` drops in a patient retry, which is all it needs:

```ini
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=60
[Service]
RestartSec=5
```

Verified: with the drop-in, `o-hm0` came up unattended **50 seconds** after a restart,
with no manual step. `90-verify` also checks it and starts it if something else went
wrong, because a failed unit is invisible from the container status.

**Stop can fail with instances running, and it fails badly.** With three Nova instances
up, `container machine stop` gave up after 12s:

```
Error: failed to stop container machine (cause: ... failed to delete process
(cause: "deleteProcess: failed with errno 95: failed to write to
/sys/fs/cgroup/container/openstack-lab-.../machine.slice/
machine-qemu\x2d22\x2dinstance\x2d00000018.scope/libvirt/iothread1/cgroup.kill"
```

The scope it could not kill is a *guest* — `instance-00000018` is one of Nova's QEMU
processes, nested inside the machine's own VM. The state it left behind is the
dangerous part: `container machine ls` still reported `running`, but the guest was
gone. No ping, every port closed, `container machine run` refused with "container is
not running".

Running `container machine stop` a second time succeeded immediately, and
`container machine run` brought everything back to `HEALTH_OK`. So the recovery is
trivial once you know it — but if you take the first `ls` at face value you will spend
the next ten minutes debugging a machine that is not running.

Shut the instances down first (`openstack server stop <name>`) if you want a clean stop.

There is no `container machine start`; the subcommand is `container machine run`.

**What shifts:** dm minor numbers. They're assigned in `vgchange` activation order,
which varies per boot — `ceph-vg1` is *not* reliably `/dev/dm-0`. Verified: a machine
that installed with vg1→251:0 came back with vg1→251:2. Loop numbers have been stable
in testing but aren't guaranteed.

With the three-stage units from 1.3, this should be automatic:

```bash
container machine stop openstack-lab
container machine run
```

Then verify, in order — each check gates the next:

```bash
systemctl status ceph-lab-assemble --no-pager
systemctl status ceph-lab-remap --no-pager
sudo lvs -o lv_name,vg_name,lv_attr
sudo dmsetup ls
for n in 1 2 3; do echo -n "node$n: "; sudo incus config device get ceph-node$n dm$((n-1)) source; done
sudo incus exec ceph-node1 -- cephadm shell -- ceph status
```

What each should show:

- both units `active (exited)`, neither `activating` — a unit stuck in `activating`
  means a hung `incus` call
- all three LVs `-wi-ao----`
- each node's `dm<N>` source matching **its own** VG's minor from `dmsetup ls`
- `HEALTH_OK` with 3 OSDs up and in

`journalctl -t ceph-lab-remap` shows the mapping the remap script computed.

**Give it about 90 seconds before judging anything.** Different layers come back at
different speeds, and checking too early reports a broken lab that is merely starting.
Measured on this build:

| Comes back | After |
|---|---|
| Kolla containers (docker restart policy) | ~10 s |
| keepalived claims the VIP | ~20 s |
| Ceph mons/OSDs, `HEALTH_OK` | ~60-85 s |
| RGW and ganesha listening | ~40-50 s |
| nova-api answering behind haproxy | ~60-90 s |

Querying before those gives `No route to host` on the VIP, `503 Service Unavailable`
from the APIs, `mount.nfs4: Broken pipe`, and s3cmd connection errors — none of which
mean anything is wrong. Phase `90-verify` waits for each of these rather than racing
them.

Expect `HEALTH_WARN: N failed cephadm daemon(s)` for the first few minutes after the
machine comes up, while OSDs show `unknown` in `ceph orch ps`. This is the
orchestrator's cache catching up, not a failure — `ceph status` returns to
`HEALTH_OK` on its own within about five minutes. `ceph cephadm check-host
ceph-node1` prompts a re-inventory if you're impatient. Don't redeploy.

If OSDs come up down after a remap, they usually recover within a minute or two as
the daemons re-open their devices — check `ceph status` again before intervening.

### Manual recovery

If the units didn't run:

```bash
# 1. reattach and activate
for f in /var/lib/ceph-disks/osd*.img; do losetup -j "$f" | grep -q . || sudo losetup --find "$f"; done
sudo vgchange -ay

# 2. make sure the holds are running
sudo systemctl restart hold-osd1 hold-osd2 hold-osd3

# 3. fix Incus device mappings from the real numbering — BOTH path and source
for n in 1 2 3; do
  d=$(sudo dmsetup ls | awk -v v="ceph--vg$n-osd$n" '$1==v {gsub(/[()]/,"",$2); split($2,a,":"); print a[2]}')
  echo "node$n -> /dev/dm-$d"
  sudo incus config device set ceph-node$n dm$((n-1)) path /dev/dm-$d
  sudo incus config device set ceph-node$n dm$((n-1)) source /dev/dm-$d
done

# 4. start and verify
sudo incus start ceph-node1 ceph-node2 ceph-node3
sleep 25
for n in 1 2 3; do sudo incus exec ceph-node$n -- dd if=/dev/ceph-vg$n/osd$n of=/dev/null bs=1M count=1 2>&1 | tail -1; done
```

Then run the 3.9 mapping verification before trusting the cluster.

### Three traps worth knowing

**Don't use `/dev/mapper/...` as an Incus source** to dodge the numbering problem.
Incus passes it through as a *symlink*, not a block node, so it lands in the container
as a dangling link to a `/dev/dm-N` that doesn't exist there.

**Set `path` and `source` together.** Updating only `source` leaves the node at the
old name with the new content; `vgmknodes` then builds a symlink to a name that isn't
there, and `dd` reports *"No such file or directory"*.

**`systemctl stop` on a unit that spawned background holds kills the holds**, which
deactivates the LVs and renumbers the dm devices — turning a diagnostic step into the
cause of the next problem. Stop `hold-osd*` individually if you must, and re-verify
the mapping afterward.

## Reset

Inside the VM, to rebuild the cluster without recreating the machine:

```bash
sudo incus delete -f ceph-node1 ceph-node2 ceph-node3
sudo vgremove -f ceph-vg1 ceph-vg2 ceph-vg3
sudo losetup -D
sudo rm -f /var/lib/ceph-disks/*.img
sudo rm -f /var/lib/openstack-lab/state/*.done
```

From macOS: `container machine stop openstack-lab && container machine delete openstack-lab`.

---

## Disk usage on macOS

`container` accumulates far more than the lab needs and nothing prunes it on its own.
This lab reached **129 GB** in `~/Library/Application Support/com.apple.container`
with a single machine running, on a 460 GB disk that was 98% full:

| Path | Size | What it was |
|---|---|---|
| `containers/buildkit/rootfs.ext4` | 42 GB | BuildKit cache, grown over repeated `container build` runs |
| `snapshots/` | 57 GB | 24 orphaned image layers, ~3 GB each, from superseded builds |
| `plugin-state/.../openstack-lab/rootfs.ext4` | 25 GB | the machine itself — real data |
| `content/` | 5 GB | image content store |

Only the machine's own rootfs was worth keeping. Reclaiming the rest:

```bash
container builder stop
container builder delete --force     # drops the BuildKit cache
container image prune -a             # drops unused images and their snapshots
container system df                  # confirm
```

That took the directory from **129 GB to 1.4 GB** and free space from 11 GB to 142 GB.
Neither command touches a running machine; `image prune -a` will not remove the image a
machine was created from.

**BuildKit is the one that grows without bound.** It is a persistent container with its
own 42 GB ext4 rootfs and no cache eviction, so every rebuild adds to it. Deleting it
is free — the next `container build` starts a new one. `01-build-kernel.sh` and
`02-build-image.sh` both delete it as their last step, which is why the leak does not
come back.

**Read the sizes with `du`, not `ls`.** A machine's `rootfs.ext4` is sparse:
`openstack-lab` showed 513 GB apparent and 25 GB actual. `ls -lh` reports the apparent
size and makes it look like the disk is already gone.

A fully deployed lab costs roughly:

| | |
|---|---|
| `/var/lib/docker` in the VM (Kolla images) | 47 GB |
| `/var/lib/incus` (node containers and base image) | 9.7 GB |
| `/var/lib/ceph-disks` (3 × 15 GB sparse, grows with use) | 1.3 GB initially |

Budget about 90 GB of free space on the Mac for a full build, and keep an eye on
`df -h /System/Volumes/Data` during the Kolla deploy — that is where most of it lands.

---

## Failure lookup

| Symptom | Cause |
|---|---|
| ``No rule to make target `#'`` | zsh comments — `setopt interactive_comments` |
| `Failure to communicate with kernel device-mapper driver` (on VM) | kernel lacks `CONFIG_BLK_DEV_DM` — rebuild |
| `Failure to communicate with kernel device-mapper driver` (in container) | `/dev/mapper/control` not passed through |
| `lvs` runs but lists nothing | backing loop device not passed through |
| `ConditionPathIsReadWrite=/sys` unmet | need `raw.lxc: lxc.mount.auto = sys:rw` |
| `systemd-udevd` fails `status=226/NAMESPACE` in a container | Incus AppArmor confinement — set `lxc.apparmor.profile = unconfined`, see 3.6 |
| `apparmor="DENIED" ... comm="podman"` in dmesg | same cause; podman can't mount its overlay store |
| `Failed to connect to bus` after restart | systemd still starting — sleep 20 |
| `Device type is not acceptable` | passing a loop device; use an LV |
| `blkid: error: <vg>/<lv>: No such file or directory` | run `vgmknodes` |
| `orch device ls` / `ceph-volume inventory` empty | expected; pass the LV path explicitly |
| `Insufficient space (<5GB)` on a large device | `sys_api` empty — device metadata unreadable, not a real size check |
| `Cannot assign requested address` at bootstrap | bootstrapping on a host that doesn't own `--mon-ip` |
| `Device IP not within network subnet` | pin `incusbr0` subnet before static IPs |
| `policy-rc.d returned 101` | daemon blocked; `systemctl enable --now` it |
| ssh prompts for password despite key | `authorized_keys` owned by UID 501 |
| `orch host add` auth failure | needs `ceph cephadm get-pub-key` |
| `ModuleNotFoundError: yaml` | install `python3-yaml` or use upstream cephadm |
| `ping` fails but network works | ICMP filtered by macOS NAT; use `curl` |
| `Error: Command not found` on dmsetup/vgmknodes | `lvm2` not installed in the container |
| `Failed to start device "dm0": The required device path doesn't exist` | LV deactivated; `hold-osd` units (3.8) not running |
| `PermissionError: [Errno 1] Operation not permitted` on the LV | missing `dm<N>` cgroup whitelist entry — see 3.6 |
| `Created no osd(s); already created?` with empty `osd tree` | stale LVM tags — clear with `lvchange --deltag`, see 4.4 |
| All three LVs tagged `ceph.osd_id=0` | OSDs created in a tight loop; do them one at a time |
| `kolla0` / `veth-ext` / DNAT gone after machine restart | runtime network state never persists; needs `kolla-net-setup.service` in the image (1.3) |
| `ceph-lab-remap` stuck in `activating` | it ran before `incus.service`; must be ordered `After=incus.service` |
| dm numbers changed mid-session | a unit holding the LVs was stopped, killing the holds |
| Container symlink points at a `/dev/dm-N` that isn't there | Incus `source` set to a `/dev/mapper/` path, or `path` not updated with `source` |
| After machine restart, node reads another node's data | dm numbers shuffled; fix `path` AND `source` from `dmsetup ls` |
| OSDs `unknown` in `orch ps` after restart | stale orchestrator cache; clears in a few minutes, no redeploy needed |
| Container symlink resolves to another node's device | stale nodes; `rm -rf` then re-run 3.7, verify with 3.9 |
| `l?????????` on `ls -lL` | dangling symlink; LV inactive on the VM — `vgchange -ay` |
| LV shows `-wi-------` after container restart | missing `hold-osd` unit — see 3.8 |
| `Could not detect a supported package manager` | `python3-apt` missing — it's in the 1.3 package list |
| `ModuleNotFoundError: No module named 'docker'` / `'dbus'` in prechecks | venv sealed from system packages — create it with `--system-site-packages`, see 5.2 |
| `Ansible requires blocking IO on stdin/stdout/stderr. Non-blocking file handles detected: <stderr>` | you are driving the script from a background job; `O_NONBLOCK` is inherited by every child. Redirect ansible's stdio to a regular file — redirecting stdout alone is not enough |
| `ansible-galaxy ... exit status 250`, `KeyError: 'results'` | transient galaxy.ansible.com fault, not a config error. See below |
| `Timeout when waiting for search string MariaDB in <vip>:3306` + `mariadb containers are missing or not running` on the FIRST deploy | MariaDB was still initialising its data directory; Kolla's check gives up after 10s. Re-run `deploy` — see below |
| `apparmor_parser: Unable to remove "libvirtd". Profile doesn't exist` | load the profile first — see 5.6 |
| `Kolla images from quay.io/openstack.kolla ... use --use-test-images` | add the flag to `prechecks` and `deploy` — see 5.6 |
| `Can't start server: Bind on TCP/IP port ... 3306` | ProxySQL and MariaDB collide — happens only if HAProxy was disabled; keep the defaults, see 5.1 |
| `Timeout when waiting for <vip>:61313` | keepalived hasn't claimed the VIP — check `docker logs keepalived`, see 5.1 |
| `Script user 'keepalived_script' does not exist` | image ships a config referencing a missing user; `useradd` it in the container — see 5.1 |
| `Hostname has to resolve uniquely to the IP address of api_interface` | two `/etc/hosts` entries for the host — remove the vmnet one, see 5.1 |
| RabbitMQ crash-loops after a machine restart with `{epmd_error,"<host>",address}` | `/etc/hosts` was regenerated with the vmnet address; the name must resolve to `10.10.10.1`. Fix it from `kolla-net-setup.service`, see 5.1 |
| Every nova/neutron agent `down` and APIs `503` after a restart | almost always the RabbitMQ hostname problem above — check `docker logs rabbitmq` first |
| `No route to host` on the VIP right after a restart | keepalived needs 20-30s to claim it; not a fault. Wait for `10.10.10.10/32` on `kolla0` |
| `Checking that host libvirt is not running` fails | host libvirt holds `/var/run/libvirt/libvirt-sock` — disable it and its sockets, see 5.6 |
| `path /run is mounted on /run but it is not a shared mount` | `/run` is private; needs `mount --make-shared /run` — see the `run-shared.service` in 1.3 |
| `Failed to find required executable "modprobe"` | install `kmod` — it's in the 1.3 package list |
| `modprobe: FATAL: Module X not found in directory /lib/modules/...` | `/lib/modules/<version>` doesn't exist — `CONFIG_MODULES=y` does **not** create it; see `fake-modules-builtin.service` in 1.3 |
| `[Errno 2] No such file or directory: '/proc/modules'` | same; `/proc/modules` is kernel-generated and cannot be faked. `CONFIG_MODULES=y` is the only fix |
| `container ... is not running` after `Restart kolla-toolbox` | same cause; the container was created but never started |
| `permission denied ... /var/run/docker.sock` | group membership from `bootstrap-servers` needs a fresh login, or use `sudo docker` |
| `apparmor_parser ... unable to find a suitable fs in /proc/mounts` | AppArmor missing from the kernel (1.1) **or** securityfs not mounted (1.3 service) — verify with 1.5 |
| `Cannot create mount unit for API file system` | don't use a `.mount` unit or fstab for securityfs — use a oneshot service, see 1.3 |
| `Method http has died unexpectedly` during `bootstrap-servers` | an apt fetch stalled; re-run, cached packages are kept |
| `chown: invalid group` | don't assume a group matching the username exists — this guide uses root or a dedicated service account |
| Kolla API endpoints stop answering after a restart | VIP may have been handed out by DHCP — re-check with `ping`, see 5.1 |
| Neutron external bridge missing after a machine restart | the `veth-ext` pair is runtime-only — see 5.1 |
| `iscsid.service ... can not create NETLINK_ISCSI socket` | kernel lacks `CONFIG_ISCSI_TCP` — see 1.1 |
| A `CONFIG_` option you added isn't in `/proc/config.gz` | unmet dependency; `olddefconfig` dropped it silently — enable its parent |
| `RADOS permission denied` in nova-compute, empty `hypervisor list` | keyring not readable by the compute service — see 4.6 |
| `error: out of memory` at GRUB in a guest | flavor RAM too small for aarch64 UEFI; use 2 GB |
| Guest boots but `no interfaces have a carrier` | CirrOS on aarch64 — use the Ubuntu cloud image |
| `Error: Unsupported architecture arm64 specified` | Octavia branch predates `arm64` support — use `master` |
| `E: Invalid Release file, no entry for main/binary-aarch64/Packages` | `aarch64` passed to `debootstrap`, which wants `arm64` |
| `exec_sudo failed: sudo: sgdisk: command not found` | install `gdisk` and the other dib tools — see 1.3 |
| `S3 error: 403 (SignatureDoesNotMatch)` | s3cmd using v4 signatures — set `signature_v2 = True` |
| `Cannot register NFS V3 on TCP` and ganesha exits 2 | the export lists protocol 3; rpcbind is not running in the node containers. Apply the export as NFSv4-only, see 8.2 |
| `ceph orch ps` shows an nfs daemon `running` but nothing answers on 2049 | the daemon exited; the orchestrator view is not evidence. Check the systemd unit and `podman ps` inside the node |
| `mount.nfs4: Connection refused` from the VM | ganesha is not listening; see the two rows above |
| `mount.nfs4: Protocol not supported` | server offers only NFSv4.1/4.2 (`Minor_Versions = 1, 2`); the kernel needs `CONFIG_NFS_V4_1=y` — `CONFIG_NFS_V4=y` alone is not enough |
| ganesha will not start even after fixing the cause | systemd hit its restart limit; `systemctl reset-failed` before redeploying |
| An NFS mount hangs for minutes instead of failing | default mount retries; use `-o soft,retry=0,timeo=50` and wrap in `timeout` when scripting |
| `s3cmd: Connection refused` against a healthy-looking RGW | the Incus proxy device was never created — its VM-side port clashed with Kolla (8000 is heat-api-cfn). Use 8100, and never discard the exit code of `incus config device add` |
| s3cmd worked, then failed after a machine restart | `host_base` in `s3cfg` embeds the old vmnet address. Use `127.0.0.1:8100` |
| `RGW is running but did not return ListAllMyBucketsResult` | `ceph orch ls` reports `1/1` before radosgw binds its port — poll the endpoint, don't check once |
| `Malformed input [buffer:3]` reading a keyring | client older than cluster; can't parse a type-2 cephx key |
| `server allowed_methods [2] but i only support [2,1]` | type-1 key against a cluster requiring method 2 |
| `apt update` 404s on `debian-20.2.4/noble` | upstream never published noble for 20.2.3/20.2.4 — use 20.2.2 |
| OSD down after container restart | LV deactivated on stop — see 3.8 (`hold-osd` units) |
| OSD down after machine restart | loop devices gone; check `ceph-lab-assemble.service` or recover manually |
| OSD down and loop numbers changed | Incus `pv-disk` mapping now points at the wrong device |
| `Not using device /dev/loopN for PV` | image attached twice; `losetup -d` the duplicates, add the `-j` guard |
