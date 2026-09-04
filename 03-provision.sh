#!/usr/bin/env bash
#
# 03-provision.sh -- provision Ceph and OpenStack. Runs INSIDE the machine, as root.
#
# Baked into the image at /usr/local/sbin/provision-lab.sh, so after logging in:
#     sudo provision-lab
#
# From macOS, run it by path -- this is the form that works headless, including
# from a background job:
#     container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh
#
# After editing this file, push it into the machine without rebuilding the image:
#     ./sync-provision.sh
#
# Progress goes to /var/log/openstack-lab-provision.log inside the VM, written
# continuously, so a long deploy can be followed from another shell.
#
# Builds a 3-node Ceph cluster in Incus system containers on LVM-backed loop
# devices, then deploys OpenStack over it with Kolla-Ansible, backed by Ceph RBD.
#
# Every phase is idempotent and checkpointed under /var/lib/openstack-lab/state,
# so a failed run resumes instead of starting over. A full run takes a few hours,
# nearly all of it pulling Kolla's container images.
#
# Usage:
#   provision-lab                 run every unfinished phase
#   provision-lab --list          show phases and their state
#   provision-lab --from 50-ceph  re-run from this phase onward
#   provision-lab --only 80-deploy
#   provision-lab --reset         forget all checkpoints (does not delete anything)

set -uo pipefail

STATE_DIR=/var/lib/openstack-lab/state
SHARED_DIR=/etc/openstack-lab
LOG=/var/log/openstack-lab-provision.log

# Pinned by 02-build-image.sh so the host client, the node image and the cluster
# all agree. A mismatch surfaces late, as an unreadable keyring.
CEPH_VERSION=20.2.2
[ -f "$SHARED_DIR/lab.env" ] && . "$SHARED_DIR/lab.env"

KOLLA_BRANCH=stable/2026.1
OPENSTACK_RELEASE=2026.1

CEPH_SUBNET=10.100.0
KOLLA_NET=10.10.10.1
KOLLA_VIP=10.10.10.10
DASHBOARD_PASSWORD=ChangeMeBeforeUse

# RGW listens on 8000 inside ceph-node1, but the VM side of the proxy device shares
# a port space with Kolla, where 8000 is heat-api-cfn behind haproxy. 8100 is free.
RGW_CONTAINER_PORT=8000
RGW_VM_PORT=8100

# Network load balancing is ON by default. Measured on a 24 GB machine, what it
# actually costs is smaller than it looks:
#
#   always      1.4 GB across four containers -- ordinary for this lab, where
#               neutron_server alone is 0.9 GB
#   part D only 2 GB, the two amphorae behind one load balancer; briefly 3 GB
#               while a destroyed one is rebuilt
#   one-off     ~3 minutes to build the amphora image, and 7.5 GiB of Ceph once
#               it is in Glance (2.5 GiB raw at size 3)
#
# Peak observed with a load balancer, two backends and three amphorae alive at
# once was 19.9 GB of 24 GB. It fits.
#
# If it does not fit on your machine -- other things running, a smaller VM -- there
# are two ways out, in this order:
#
#   ENABLE_NETWORK_LOADBALANCER=no provision-lab    rebuild without it; the lab is
#                                                   complete apart from exercises 9-11
#   MACHINE_MEMORY=28G in 02-build-image.sh         26G is enough, 28G is comfortable;
#                                                   needs the machine recreating
#
# The OpenStack service behind it is Octavia, which is what every setting below and
# every error message says. The flag is named for the capability rather than the
# project, because you should not need to know the latter to decide.
#
#   ENABLE_NETWORK_LOADBALANCER=no  provision-lab                 build without it
#   ENABLE_NETWORK_LOADBALANCER=yes provision-lab --from 70-kolla add it to a lab
#                                                                 built without it
#
# It cannot be a bolt-on phase alone: enable_octavia has to be in globals.yml
# before 80-deploy, because Kolla deploys the containers there. 87-octavia only
# does what has to happen after Glance is up.
ENABLE_NETWORK_LOADBALANCER="${ENABLE_NETWORK_LOADBALANCER:-yes}"

# Each OSD is a sparse file on the Mac's disk, so its size is a ceiling on how much
# host disk the lab can ever consume -- the file grows to the high-water mark of what
# Ceph writes and never shrinks.
#
# With thin provisioning at size 2 the exercises peak at about 9.7 GB across the
# cluster, which three 5G disks hold comfortably at 54%.
#
# Exercise 29 fills the cluster on purpose, and that is where small disks bite: a 5G OSD
# taken to 93% has roughly 340 MB left, too little for RocksDB to compact. Measured here,
# BlueFS aborted with "bluefs enospc" and the OSD could not restart, because recovery
# needs to write as well. The default full_ratio of 0.95 does not prevent it -- BlueFS
# starves before the data area is full.
#
# The fix is not bigger disks, it is stopping writes earlier: Exercise 29 lowers the
# ratios to 0.70/0.75/0.80 before filling, which leaves about 1 GB per OSD -- three
# times the headroom that failed -- and still demonstrates a genuinely full cluster. The rest of the size exists only so Exercise 29 has
# something to fill, and filling it is what costs host disk: at 3x15G/size 3 the files
# ended at 45 GB, at 3x10G/size 2 at 24 GB.
OSD_SIZE="${OSD_SIZE:-5G}"

# size 2, not 3. On a three-OSD lab this is the difference between ~10 GiB and ~15 GiB
# usable, and the amphora image alone is 2.5 GiB stored -- 7.5 GiB at size 3 against
# 5 GiB at size 2. Exercise 25 raises a pool to 3 to show what the third copy costs.
CEPH_POOL_SIZE="${CEPH_POOL_SIZE:-2}"

PHASES=(10-storage 20-incus 30-nodebase 40-nodes 50-ceph 60-hostclient 70-kolla 80-deploy 85-rgw 86-nfs 87-octavia 90-verify)

# --- Plumbing ----------------------------------------------------------------

log()  { printf '\n=== [%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
info() { printf '    %s\n' "$*" | tee -a "$LOG"; }
die()  { printf 'ERROR: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

# Run a ceph command through the bootstrap node's cephadm shell.
ceph_do() { incus exec ceph-node1 -- cephadm shell -- "$@" 2>/dev/null; }

# Poll until a command succeeds. wait_for <seconds> <description> <cmd...>
#
# Says what it is waiting for before it starts waiting, and repeats every 30s. A
# silent 50-second pause reads like a hang; "still waiting" reads like patience.
#
# The three outcomes are worded so they cannot be confused with each other, which
# matters more than it sounds: "not ready yet" during a wait is normal, and only
# the line after the timeout means something is actually wrong.
wait_for() {
    local timeout="$1" what="$2"; shift 2
    local waited=0

    # Already true: one quiet line, no drama.
    if "$@" >/dev/null 2>&1; then
        info "$what -- ok"
        return 0
    fi

    info "waiting for $what (up to ${timeout}s -- this is normal after a restart)"
    until "$@" >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout" ]; then
            info "GAVE UP: $what did not happen within ${timeout}s -- this one needs looking at"
            return 1
        fi
        sleep 5; waited=$((waited + 5))
        [ $((waited % 30)) -eq 0 ] && info "  ... still waiting for $what (${waited}s)"
    done
    info "$what -- ok after ${waited}s"
    return 0
}

# Add an Incus proxy device, failing loudly rather than silently.
#
# Daemons inside the Ceph containers have their own port space, but the VM side of
# a proxy device competes with everything Kolla runs. Binding 0.0.0.0:<port> fails
# if any Kolla service already holds that port on any address -- which is how the
# RGW device silently failed to be created on 8000 (heat-api-cfn), leaving s3cmd
# with "Connection refused" and no indication why.
add_proxy() {
    local inst="$1" name="$2" listen_port="$3" connect_addr="$4"
    incus config device get "$inst" "$name" listen >/dev/null 2>&1 && return 0
    if ss -tln | awk '{print $4}' | grep -q ":${listen_port}$"; then
        die "cannot add proxy device '$name': port $listen_port is already in use on the VM (ss -tlnp | grep $listen_port)"
    fi
    incus config device add "$inst" "$name" proxy \
        "listen=tcp:0.0.0.0:$listen_port" "connect=tcp:$connect_addr" >/dev/null \
        || die "could not add proxy device '$name' on port $listen_port"
    info "proxy device $name: VM :$listen_port -> $connect_addr"
}

# Run a command with stdio on regular files, and mirror the output.
#
# Ansible refuses to start when any of stdin/stdout/stderr is non-blocking:
#   "Ansible requires blocking IO on stdin/stdout/stderr.
#    Non-blocking file handles detected: <stderr>"
# That is exactly what it inherits when this script is driven from a background job
# -- 'container machine run ... > provision.log 2>&1 &' leaves O_NONBLOCK set, and
# every child gets it. kolla-ansible's install-deps step shells out to
# ansible-galaxy, so it fails there long before any playbook runs, retrying five
# times first. Regular files are always blocking, so route ansible's stdio through
# one and copy the result into the main log afterwards.
#
# Redirecting only stdout is not enough; the message names <stderr> for a reason.
run_logged() {
    local tag="$1"; shift
    local out="/var/log/openstack-lab-$tag.out"
    "$@" </dev/null >"$out" 2>&1
    local rc=$?
    cat "$out" >> "$LOG"
    tail -25 "$out"
    return "$rc"
}

# $0 is "bash" when this is piped in over stdin, so print the usage rather than
# trying to read it back out of the file.
usage() {
    cat <<'USAGE'
provision-lab                 run every unfinished phase
provision-lab --list          show phases and their state
provision-lab --from 50-ceph  re-run from this phase onward
provision-lab --only 80-deploy
provision-lab --reset         forget all checkpoints (does not delete anything)
USAGE
    exit 0
}

FROM=""; ONLY=""; RESET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)  LIST=1; shift ;;
        --from)  FROM="$2"; shift 2 ;;
        --only)  ONLY="$2"; shift 2 ;;
        --reset) RESET=1; shift ;;
        -h|--help) usage ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"
mkdir -p "$STATE_DIR" "$SHARED_DIR"
chmod 755 "$SHARED_DIR"
touch "$LOG"

if [ "${LIST:-0}" = 1 ]; then
    printf '%-14s %s\n' PHASE STATE
    for p in "${PHASES[@]}"; do
        [ -f "$STATE_DIR/$p.done" ] && printf '%-14s done\n' "$p" || printf '%-14s pending\n' "$p"
    done
    exit 0
fi

if [ "$RESET" = 1 ]; then
    rm -f "$STATE_DIR"/*.done
    echo "checkpoints cleared; nothing was deleted"
    exit 0
fi

# =============================================================================
# 10-storage -- LVM-backed OSD devices
#
# ceph-volume refuses anything reporting TYPE=loop ("Device type is not
# acceptable. It should be raw device or partition."). An LV on top reports
# TYPE=lvm and is accepted, which is the whole reason the kernel needs
# device-mapper.
# =============================================================================
phase_10_storage() {
    [ -e /dev/mapper/control ] || die "no /dev/mapper/control -- kernel lacks device-mapper"

    mkdir -p /var/lib/ceph-disks
    for i in 1 2 3; do
        img=/var/lib/ceph-disks/osd$i.img
        [ -f "$img" ] || { info "creating $img (${OSD_SIZE} sparse)"; truncate -s "$OSD_SIZE" "$img"; }

        # -j guards against a second attachment of the same image, which shows up
        # later as "Not using device /dev/loopN for PV".
        loop=$(losetup -j "$img" | cut -d: -f1)
        [ -n "$loop" ] || loop=$(losetup --find --show "$img")
        info "osd$i -> $loop"

        if ! vgs "ceph-vg$i" >/dev/null 2>&1; then
            pvcreate -f "$loop"        >/dev/null
            vgcreate "ceph-vg$i" "$loop" >/dev/null
            lvcreate -l 100%FREE -n "osd$i" "ceph-vg$i" >/dev/null
            info "created ceph-vg$i/osd$i"
        fi
    done

    vgchange -ay >/dev/null
    systemctl start hold-osd1 hold-osd2 hold-osd3 2>/dev/null || true

    # An LV must report -wi-ao----. The 'o' is the open flag held by hold-osdN;
    # without it the LV deactivates the moment a container stops, and every dm
    # minor number shuffles on the next activation.
    local bad=0
    for i in 1 2 3; do
        attr=$(lvs --noheadings -o lv_attr "ceph-vg$i/osd$i" 2>/dev/null | tr -d ' ')
        case "$attr" in
            -wi-ao*) info "ceph-vg$i/osd$i $attr" ;;
            *) info "ceph-vg$i/osd$i is $attr, expected -wi-ao----"; bad=1 ;;
        esac
    done
    [ "$bad" -eq 0 ] || die "LV holds are not running -- check hold-osd{1,2,3}.service"

    lsblk -o NAME,TYPE | grep -q lvm || die "no LVM devices visible"
}

# =============================================================================
# 20-incus -- daemon init and a fixed bridge subnet
#
# Incus picks a random subnet and changes it across restarts. Ceph writes mon
# addresses into its config, so a subnet change after bootstrap destroys the
# cluster. Pin it before anything launches.
# =============================================================================
phase_20_incus() {
    systemctl enable --now incus.socket incus.service >/dev/null 2>&1 || true
    wait_for 60 "incus daemon" incus info || die "incus daemon did not start"

    incus admin init --auto >/dev/null 2>&1 || info "incus already initialised"

    incus network set incusbr0 ipv4.address "$CEPH_SUBNET.1/24"
    incus network set incusbr0 ipv4.nat true
    info "incusbr0 pinned to $CEPH_SUBNET.0/24"
}

# =============================================================================
# 30-nodebase -- the Incus image the Ceph nodes are launched from
#
# The machine image cannot be reused: that is an OCI image in Apple's store on
# macOS, and Incus needs its own format with a working init system. Build the
# equivalent here once, publish it, and launch all three nodes from it.
# =============================================================================
phase_30_nodebase() {
    if incus image alias list 2>/dev/null | grep -q 'ceph-node-base'; then
        info "ceph-node-base already published"
        return 0
    fi

    incus delete -f ceph-base 2>/dev/null || true
    incus launch images:ubuntu/24.04 ceph-base -c security.privileged=true
    # 'is-system-running' exits non-zero on "degraded", which is normal in a
    # container, so poll for a state that means booted rather than for success.
    wait_for 180 "ceph-base booted" bash -c \
        "incus exec ceph-base -- systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'" \
        || die "ceph-base never finished booting"

    # chrony: cephadm's host check fails without time sync.
    # podman:  runs every Ceph daemon.
    # lvm2:    provides dmsetup and vgmknodes, needed for the device nodes.
    # openssh: how the orchestrator reaches nodes 2 and 3.
    incus exec ceph-base -- apt-get update
    # rpcbind: ganesha registers NFSv3 at startup whatever the export says, and
    # exits 2 if it cannot. See phase_86_nfs.
    incus exec ceph-base -- apt-get install -y \
        lvm2 openssh-server podman python3 chrony curl gnupg rpcbind \
        || die "package install failed in ceph-base"

    # Same pinned repo as the host client, so cephadm and ceph-common match the
    # cluster image used at bootstrap.
    incus exec ceph-base -- bash -c \
      "curl -fsSL https://download.ceph.com/keys/release.gpg -o /etc/apt/trusted.gpg.d/ceph.gpg && \
       echo 'deb https://download.ceph.com/debian-$CEPH_VERSION/ noble main' > /etc/apt/sources.list.d/ceph.list && \
       apt-get update && apt-get install -y cephadm ceph-common" \
      || die "cephadm install failed in ceph-base"

    incus exec ceph-base -- systemctl enable ssh
    incus exec ceph-base -- apt-get clean

    got=$(incus exec ceph-base -- cephadm version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    info "cephadm in base image: $got"
    [ "$got" = "$CEPH_VERSION" ] || die "cephadm is $got, expected $CEPH_VERSION"

    incus stop ceph-base
    incus publish ceph-base --alias ceph-node-base
    incus delete ceph-base
    info "published ceph-node-base"
}

# =============================================================================
# 40-nodes -- launch the three nodes and give them a working device model
#
# Even with the LV passed through, ceph-volume fails without device nodes, LVM
# symlinks and a udev daemon. Four things fix it, all applied here.
# =============================================================================
phase_40_nodes() {
    for n in 1 2 3; do
        if ! incus info "ceph-node$n" >/dev/null 2>&1; then
            incus launch ceph-node-base "ceph-node$n" -c security.privileged=true
        fi
    done

    incus stop ceph-node1 ceph-node2 ceph-node3 2>/dev/null || true
    for n in 1 2 3; do
        incus config device override "ceph-node$n" eth0 "ipv4.address=$CEPH_SUBNET.1$n" 2>/dev/null \
            || incus config device set "ceph-node$n" eth0 ipv4.address "$CEPH_SUBNET.1$n"
        # The remap unit starts these after fixing device numbers, so Incus must
        # not autostart them onto a stale mapping.
        incus config set "ceph-node$n" boot.autostart false
    done

    for n in 1 2 3; do
        img=/var/lib/ceph-disks/osd$n.img
        loop=$(losetup -j "$img" | cut -d: -f1)
        [ -n "$loop" ] || die "no loop device for $img"

        # dm minor numbers are assigned in vgchange activation order and shuffle
        # between boots, so read the current one rather than assuming dm-(n-1).
        dm=$(dmsetup ls | awk -v v="ceph--vg$n-osd$n" \
                '$1==v {gsub(/[()]/,"",$2); split($2,a,":"); print a[2]}')
        [ -n "$dm" ] || die "no dm device for ceph-vg$n/osd$n"
        info "ceph-node$n: $loop, /dev/dm-$dm"

        # dm-control: without it LVM reports "Failure to communicate with kernel
        #   device-mapper driver".
        # pv-disk:    the backing loop device; without it lvs runs but lists nothing.
        # dm<N>:      required for the cgroup device WHITELIST. Without it the node
        #   can create the device node but not open it -- ceph-volume fails with
        #   EPERM and 'orch daemon add osd' returns silently. This is a cgroup
        #   policy denial, not a file permission problem, so the ownership looks
        #   correct, which makes it easy to misdiagnose.
        incus config device remove "ceph-node$n" dm-control 2>/dev/null || true
        incus config device remove "ceph-node$n" pv-disk    2>/dev/null || true
        incus config device remove "ceph-node$n" "dm$((n-1))" 2>/dev/null || true
        incus config device add "ceph-node$n" dm-control unix-char \
             path=/dev/mapper/control source=/dev/mapper/control
        incus config device add "ceph-node$n" pv-disk unix-block \
             path="$loop" source="$loop"
        incus config device add "ceph-node$n" "dm$((n-1))" unix-block \
             path="/dev/dm-$dm" source="/dev/dm-$dm"

        # sys:rw lets systemd-udevd start; it refuses on a read-only /sys with
        #   "ConditionPathIsReadWrite=/sys".
        # unconfined is required because the kernel has AppArmor on for Kolla's
        #   benefit. With it active, Incus confines each container with a generated
        #   profile that blocks the mounts udevd and podman need -- udevd dies with
        #   status=226/NAMESPACE. These containers are already privileged, so
        #   AppArmor was the only remaining confinement.
        incus config set "ceph-node$n" raw.lxc "lxc.mount.auto = sys:rw
lxc.apparmor.profile = unconfined"
    done

    # The nodes were stopped above to attach devices, so start them -- 'incus
    # restart' errors on a stopped instance.
    for n in 1 2 3; do
        incus start "ceph-node$n" 2>/dev/null || incus restart "ceph-node$n"
    done
    for n in 1 2 3; do
        wait_for 120 "ceph-node$n systemd-udevd" \
            incus exec "ceph-node$n" -- systemctl is-active systemd-udevd \
            || die "systemd-udevd not running in ceph-node$n"
    done

    _make_device_nodes
    _verify_mapping

    # Recreate nodes and symlinks at boot, before any OSD opens its device.
    # Before=ceph.target matters: cephadm's OSD units are pulled in by that target.
    for n in 1 2 3; do
        incus exec "ceph-node$n" -- bash -c 'cat > /etc/systemd/system/ceph-dm-nodes.service <<EOF
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
systemctl daemon-reload && systemctl enable ceph-dm-nodes.service' >/dev/null 2>&1
    done
    info "ceph-dm-nodes.service enabled in all three nodes"
}

# dmsetup mknodes creates /dev/mapper/<vg>-<lv>; vgmknodes creates the
# /dev/<vg>/<lv> symlink, which is the one 'orch daemon add osd' resolves.
# Without vgmknodes: "blkid: error: ceph-vg1/osd1: No such file or directory".
#
# The rm -rf is not optional. dm numbering changes whenever LVs are deactivated
# and reactivated, so symlinks left from a previous boot can point at another
# node's volume.
_make_device_nodes() {
    for n in 1 2 3; do
        incus exec "ceph-node$n" -- bash -c 'rm -rf /dev/ceph-vg*/ /dev/mapper/ceph--*'
        incus exec "ceph-node$n" -- dmsetup mknodes >/dev/null 2>&1
        incus exec "ceph-node$n" -- vgmknodes       >/dev/null 2>&1
    done
}

# Each node must resolve its LV to its OWN device. A mismatch means one node's OSD
# writes to another node's volume: silent, cluster-wide corruption.
_verify_mapping() {
    local bad=0
    for n in 1 2 3; do
        want=$(dmsetup ls | awk -v v="ceph--vg$n-osd$n" \
                 '$1==v {gsub(/[()]/,"",$2); print $2}')
        # ls -lL reports major,minor in decimal, matching dmsetup. stat's %t:%T is
        # hex and awk will not reliably parse a 0x prefix.
        got=$(incus exec "ceph-node$n" -- ls -lL "/dev/ceph-vg$n/osd$n" 2>/dev/null \
                | awk '{gsub(",","",$5); print $5":"$6}')
        if [ "$want" = "$got" ] && [ -n "$got" ]; then
            info "ceph-node$n osd$n -> $got  ok"
        else
            info "ceph-node$n osd$n -> '$got', VM says '$want'  MISMATCH"; bad=1
        fi

        # Proves the cgroup whitelist entry is right. "Operation not permitted"
        # here means the dm<N> device is missing or points at the wrong number.
        if ! incus exec "ceph-node$n" -- dd if="/dev/ceph-vg$n/osd$n" of=/dev/null bs=1M count=1 >/dev/null 2>&1; then
            info "ceph-node$n cannot read its device -- check the dm$((n-1)) entry"; bad=1
        fi
    done
    [ "$bad" -eq 0 ] || die "device mapping is wrong -- do not create OSDs"
}

# =============================================================================
# 50-ceph -- bootstrap the cluster, add nodes, create OSDs, pools and users
# =============================================================================
phase_50_ceph() {
    _make_device_nodes
    _verify_mapping

    if ! incus exec ceph-node1 -- test -f /etc/ceph/ceph.conf; then
        # cephadm bootstrap must run on the host that will be the first mon.
        # Running it on the VM with --mon-ip pointing at a container fails with
        # "Cannot assign requested address" -- the VM cannot bind an IP it does
        # not own.
        #
        # --image is a GLOBAL option and must precede the subcommand; after it you
        # get "unrecognized arguments". Without it cephadm pulls quay.io/ceph/ceph:v20,
        # which resolves to the newest Tentacle and gives a cluster no host client
        # can authenticate against.
        log "bootstrapping ceph on ceph-node1"
        incus exec ceph-node1 -- cephadm --image "quay.io/ceph/ceph:v$CEPH_VERSION" bootstrap \
            --mon-ip "$CEPH_SUBNET.11" \
            --initial-dashboard-password "$DASHBOARD_PASSWORD" \
            --skip-firewalld || die "cephadm bootstrap failed"
    else
        info "cluster already bootstrapped"
    fi

    ver=$(ceph_do ceph versions | grep -oE 'ceph version [0-9.]+' | head -1 | awk '{print $3}')
    info "cluster version: $ver"

    # Bootstrap sets public_network to "10.100.0.1/32,10.100.0.0/24" -- the /32 is
    # the bridge gateway leaking in from the container's routing view.
    ceph_do ceph config set global public_network "$CEPH_SUBNET.0/24" >/dev/null
    ceph_do ceph telemetry off >/dev/null 2>&1 || true

    # cephadm manages its own keypair, separate from anything created by hand.
    # 'orch host add' uses that key, so it has to be distributed first.
    CEPH_KEY=$(ceph_do ceph cephadm get-pub-key | grep '^ssh-')
    [ -n "$CEPH_KEY" ] || die "could not read the cephadm public key"
    for n in 2 3; do
        incus exec "ceph-node$n" -- mkdir -p /root/.ssh
        incus exec "ceph-node$n" -- chmod 700 /root/.ssh
        incus exec "ceph-node$n" -- bash -c \
            "grep -qF '$CEPH_KEY' /root/.ssh/authorized_keys 2>/dev/null || echo '$CEPH_KEY' >> /root/.ssh/authorized_keys"
        if ! ceph_do ceph orch host ls | grep -q "ceph-node$n"; then
            ceph_do ceph orch host add "ceph-node$n" "$CEPH_SUBNET.1$n" || die "could not add ceph-node$n"
        fi
    done
    wait_for 180 "3 hosts registered" bash -c \
        "[ \$(incus exec ceph-node1 -- cephadm shell -- ceph orch host ls 2>/dev/null | grep -c ceph-node) -ge 3 ]"

    # Set discard BEFORE the OSDs exist, so every one of them starts with it on.
    # BlueStore only discards blocks as it frees them -- turning this on afterwards
    # does nothing for space already released, which is why it has to be here.
    #
    # It matters because each OSD is an LV on a loop device on a sparse file. Without
    # discard those files only ever grow: Exercise 29 fills the cluster on purpose and
    # they stay at 15G each afterwards, holding ~27 GB the cluster is no longer using.
    # The whole chain carries discard (loop and dm both report
    # discard_max_bytes=4294966784), so BlueStore's frees reach the file as hole
    # punches and the image shrinks back.
    # Set the default before any pool is created, so Kolla's glance/cinder/nova pools
    # and the RGW/CephFS pools all come up at this size rather than needing a rebalance
    # afterwards. min_size 1 keeps writes flowing while one OSD is down, which is the
    # point of the failure drills.
    ceph_do ceph config set global osd_pool_default_size     "$CEPH_POOL_SIZE" >/dev/null 2>&1 || true
    ceph_do ceph config set global osd_pool_default_min_size 1 >/dev/null 2>&1 || true
    info "default pool size set to $CEPH_POOL_SIZE before any pool exists"

    ceph_do ceph config set osd bdev_enable_discard true >/dev/null 2>&1 || true
    ceph_do ceph config set osd bdev_async_discard  true >/dev/null 2>&1 || true
    info "BlueStore discard enabled before OSD creation"

    # One at a time, waiting for each. A tight loop can leave all three tagged
    # ceph.osd_id=0, colliding on the same ID with none registered.
    #
    # Do not use 'ceph orch device ls' or 'ceph-volume inventory' as a health
    # check -- both stay empty even when this works. Pass the LV path explicitly.
    for n in 1 2 3; do
        # Match on the host, not on an osd id -- ids are assigned by the cluster
        # and do not necessarily line up with the node numbers.
        if ceph_do ceph osd tree | grep -q "host ceph-node$n"; then
            info "osd for ceph-node$n already present"; continue
        fi
        log "creating OSD on ceph-node$n"
        _clear_lvm_tags "$n"
        # "Created no osd(s) on host X; already created?" is not necessarily a
        # failure -- ceph-volume prints it when the device is already prepared, and
        # the OSD can still come up. Judge by the tree, not by the message.
        ceph_do ceph orch daemon add osd "ceph-node$n:ceph-vg$n/osd$n" \
            || info "add osd returned non-zero for ceph-node$n"

        # Wait for the OSD to be UP, not merely for a CRUSH host bucket to exist --
        # the bucket appears immediately and makes the wait return in 0s, which
        # defeats the point. Doing these one at a time is what stops all three
        # being tagged ceph.osd_id=0 and colliding.
        wait_for 300 "$n OSD(s) up" bash -c \
            "[ \$(incus exec ceph-node1 -- cephadm shell -- ceph osd tree 2>/dev/null | grep -cE '^ *[0-9]+ +hdd .* up ') -ge $n ]" \
            || die "OSD on ceph-node$n never came up -- see: ceph log last 50 cephadm"
    done

    wait_for 600 "3 OSDs up and in" bash -c \
        "incus exec ceph-node1 -- cephadm shell -- ceph -s 2>/dev/null | grep -qE 'osd: 3 osds: 3 up.*3 in'"

    for pool in glance-images cinder-volumes nova-vms; do
        ceph_do ceph osd pool ls | grep -qx "$pool" || {
            ceph_do ceph osd pool create "$pool" 32 >/dev/null
            ceph_do rbd pool init "$pool" >/dev/null
            info "created pool $pool"
        }
    done

    # .mgr was created by bootstrap, before the default above was set, so it is still
    # at the built-in size 3. Pull every existing pool to the configured size so
    # 'ceph df' is consistent and nothing silently costs an extra copy.
    for pool in $(ceph_do ceph osd pool ls 2>/dev/null); do
        cur=$(ceph_do ceph osd pool get "$pool" size 2>/dev/null | awk '{print $2}')
        [ "$cur" = "$CEPH_POOL_SIZE" ] && continue
        ceph_do ceph osd pool set "$pool" size "$CEPH_POOL_SIZE" >/dev/null 2>&1 \
            && info "pool $pool: size $cur -> $CEPH_POOL_SIZE"
    done

    # The user names matter. Kolla defaults to ceph_glance_user: glance and
    # ceph_cinder_user: cinder and expects those entities to already exist. A
    # single combined user is not found, and the failure surfaces late as a
    # missing keyring rather than a clear error.
    #
    # client.cinder needs read on glance-images (Nova clones images from there)
    # and write on nova-vms -- Nova's rbd_user is cinder, not a separate user.
    ceph_do ceph auth get-or-create client.glance \
        mon 'profile rbd' \
        osd 'profile rbd pool=glance-images' \
        mgr 'profile rbd pool=glance-images' >/dev/null
    ceph_do ceph auth get-or-create client.cinder \
        mon 'profile rbd' \
        osd 'profile rbd pool=cinder-volumes, profile rbd pool=nova-vms, profile rbd-read-only pool=glance-images' \
        mgr 'profile rbd pool=cinder-volumes, profile rbd pool=nova-vms' >/dev/null
    info "client.glance and client.cinder created"

    ceph_do ceph -s | sed 's/^/    /' | tee -a "$LOG"
}

# A failed OSD attempt leaves LVM tags on the volume. ceph-volume sees its own
# tags and skips with "Created no osd(s) on host X; already created?", even though
# nothing was registered. Every failed attempt re-tags, so clear before each retry.
_clear_lvm_tags() {
    local n="$1"
    local tags
    tags=$(lvs --noheadings -o lv_tags "ceph-vg$n/osd$n" 2>/dev/null | tr ',' ' ')
    [ -z "$(echo "$tags" | tr -d ' ')" ] && return 0
    info "clearing stale LVM tags on ceph-vg$n/osd$n"
    for t in $tags; do lvchange --deltag "$t" "ceph-vg$n/osd$n" >/dev/null 2>&1 || true; done
    dd if=/dev/zero of="/dev/ceph-vg$n/osd$n" bs=1M count=100 conv=fsync >/dev/null 2>&1 || true
}

# =============================================================================
# 60-hostclient -- /etc/ceph on the VM
#
# OpenStack reads Ceph credentials from /etc/ceph. Nova and Cinder link librbd
# in-process, so the host client has to work; a container-based rbd is not a
# substitute. A failure here surfaces much later and far less clearly.
# =============================================================================
phase_60_hostclient() {
    have=$(ceph --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ "$have" = "$CEPH_VERSION" ] || die "host ceph client is $have, expected $CEPH_VERSION"

    mkdir -p /etc/ceph
    incus exec ceph-node1 -- cat /etc/ceph/ceph.conf > /etc/ceph/ceph.conf
    [ -s /etc/ceph/ceph.conf ] || die "could not copy ceph.conf from ceph-node1"

    # Build each keyring from get-key rather than 'ceph auth get', which writes
    # stray "Inferring fsid" lines to stderr.
    #
    # Group ownership matters: nova-compute must be able to read the keyring and
    # does not necessarily run as the owner of /etc/ceph. If it cannot, the
    # symptom is "RADOS permission denied" and an empty 'hypervisor list'.
    for u in glance cinder; do
        K=$(ceph_do ceph auth get-key "client.$u" | tr -d '[:space:]')
        [ -n "$K" ] || die "could not read the key for client.$u"
        printf '[client.%s]\n\tkey = %s\n' "$u" "$K" > "/etc/ceph/ceph.client.$u.keyring"
        chmod 640 "/etc/ceph/ceph.client.$u.keyring"
        chgrp libvirt "/etc/ceph/ceph.client.$u.keyring"
        ceph-authtool "/etc/ceph/ceph.client.$u.keyring" --print-key -n "client.$u" >/dev/null \
            || die "keyring for client.$u does not parse"
    done

    # A 20.2.2 cluster mints AQ (type 1) keys, which a 20.2.2 client can read.
    # An Ag prefix means the cluster is 20.2.3+ and the --image pin did not take.
    for u in glance cinder; do
        case "$(ceph-authtool "/etc/ceph/ceph.client.$u.keyring" --print-key -n "client.$u")" in
            Ag*) die "client.$u key is type 2 -- the cluster is newer than $CEPH_VERSION" ;;
        esac
    done

    rbd -n client.glance --keyring /etc/ceph/ceph.client.glance.keyring ls glance-images >/dev/null \
        || die "glance client cannot reach the cluster"
    rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring ls nova-vms >/dev/null \
        || die "cinder client cannot reach the cluster"
    info "both RBD clients reach the cluster"
    ls -l /etc/ceph/ | sed 's/^/    /' | tee -a "$LOG"
}

# =============================================================================
# 70-kolla -- deploy user, Kolla-Ansible, and configuration
# =============================================================================
phase_70_kolla() {
    systemctl start kolla-net-setup 2>/dev/null || true
    ip -br addr show kolla0 2>/dev/null | grep -q "$KOLLA_NET" \
        || die "kolla0 has no address -- check kolla-net-setup.service"
    ip -br link show veth-ext >/dev/null 2>&1 \
        || die "veth-ext is missing -- check kolla-net-setup.service"

    # RabbitMQ clusters on hostnames, so Kolla requires the host name to resolve
    # UNIQUELY to the api_interface address. The image sets its own name to the
    # vmnet address and bootstrap-servers adds the kolla0 one, leaving two entries
    # and failing the precheck with "Hostname has to resolve uniquely...".
    sed -i -E "/^192\.168\.64\.[0-9]+[[:space:]]+$(hostname)([[:space:]]|\$)/d" /etc/hosts
    grep -q "^$KOLLA_NET $(hostname)$" /etc/hosts || echo "$KOLLA_NET $(hostname)" >> /etc/hosts
    n=$(getent ahostsv4 "$(hostname)" | awk '{print $1}' | sort -u | wc -l)
    [ "$n" -eq 1 ] || die "$(hostname) resolves to $n addresses, must be exactly 1"
    info "$(hostname) resolves uniquely to $KOLLA_NET"

    # A dedicated service account: it owns /etc/kolla and writes there without
    # sudo (the playbooks and kolla-genpwd do), while still having passwordless
    # sudo for host-level tasks. Never an interactive login account.
    if ! getent passwd kolla >/dev/null; then
        useradd -r -m -d /opt/kolla -s /bin/bash kolla
        echo "kolla ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/kolla
        chmod 0440 /etc/sudoers.d/kolla
    fi
    # useradd -m creates the home 750, which blocks other services traversing in.
    chmod 755 /opt/kolla
    mkdir -p /etc/kolla
    chown -R kolla:kolla /etc/kolla

    if [ ! -x /opt/kolla/venv/bin/kolla-ansible ]; then
        log "installing kolla-ansible $KOLLA_BRANCH (several minutes)"
        # --system-site-packages: prechecks runs its docker and dbus imports with
        # the venv's python. A sealed venv fails with ModuleNotFoundError.
        sudo -u kolla bash -lc "
            set -e
            python3 -m venv --system-site-packages /opt/kolla/venv
            . /opt/kolla/venv/bin/activate
            pip install -q -U pip
            pip install -q 'git+https://opendev.org/openstack/kolla-ansible@$KOLLA_BRANCH'
            pip install -q docker dbus-python python-openstackclient
            # Kolla's venv ships no Heat or Barbican client, so 'openstack stack ...'
            # and 'openstack secret ...' are not openstack commands at all. Install
            # them here rather than telling the reader to -- these go into kolla's own
            # venv and touch nothing the system package manager owns.
            pip install -q python-heatclient python-barbicanclient
        " || die "kolla-ansible install failed"
    fi

    sudo -u kolla bash -lc "
        set -e
        [ -f /etc/kolla/globals.yml ] || cp -r /opt/kolla/venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
        [ -f /opt/kolla/all-in-one ]  || cp /opt/kolla/venv/share/kolla-ansible/ansible/inventory/all-in-one /opt/kolla/
    " || die "could not lay down the kolla config templates"

    # install-deps runs ansible-galaxy, which needs blocking stdio -- see run_logged.
    run_logged install-deps sudo -u kolla bash -lc \
        ". /opt/kolla/venv/bin/activate && kolla-ansible install-deps" \
        || die "kolla-ansible install-deps failed"

    sudo -u kolla bash -lc "
        set -e
        . /opt/kolla/venv/bin/activate
        grep -q '^[a-z_]*_password: .\+' /etc/kolla/passwords.yml || kolla-genpwd
    " || die "kolla-genpwd failed"

    blank=$(sudo -u kolla grep -c ': ""' /etc/kolla/passwords.yml || true)
    [ "$blank" -eq 0 ] || die "passwords.yml still has $blank blank entries -- kolla-genpwd did not run"

    # Append rather than edit: the shipped globals.yml is ~900 lines of comments,
    # so anything at the end takes effect and is easy to find later.
    if ! grep -q '^# ---- lab settings ----' /etc/kolla/globals.yml; then
        sudo -u kolla tee -a /etc/kolla/globals.yml > /dev/null <<EOF

# ---- lab settings ----
kolla_base_distro: "ubuntu"

# Must match the branch installed above.
openstack_release: "$OPENSTACK_RELEASE"

# Kolla images are NOT multiarch. Without this suffix you get x86-64 images.
openstack_tag_suffix: "-aarch64"

# Private control-plane interface -- never enp0s1, whose address changes on every
# machine recreate and whose vmnet subnet forbids a floating VIP.
network_interface: "kolla0"
neutron_external_interface: "veth-ext"

# Free address on kolla0's subnet. kolla0 itself holds $KOLLA_NET.
kolla_internal_vip_address: "$KOLLA_VIP"

# Cinder is NOT enabled by default in Kolla. Setting cinder_backend_ceph alone
# gets you the Ceph pool and keyring but no block-storage service at all, and any
# volume command fails with "public endpoint for block-storage service in
# RegionOne region not found".
enable_cinder: "yes"

# Barbican stores secrets, and Cinder uses it for encrypted volume types -- the
# key for a LUKS volume lives here, not on the compute node.
enable_barbican: "yes"

# cinder-backup is on by default once cinder is enabled, and wants its own cephx
# user, its own 'backups' pool and a keyring at
# /etc/kolla/config/cinder/cinder-backup/. Without them deploy fails with
# "Could not find or access '/etc/kolla/config/cinder/cinder-backup/...'".
# Volume snapshots cover backup/restore for this lab, so leave it off.
enable_cinder_backup: "no"

# External Ceph -- the cluster built above.
glance_backend_ceph: "yes"
cinder_backend_ceph: "yes"
nova_backend_ceph: "yes"

# Pool names must be overridden; Kolla defaults to images/volumes/vms.
ceph_glance_user: "glance"
ceph_glance_pool_name: "glance-images"
ceph_cinder_user: "cinder"
ceph_cinder_pool_name: "cinder-volumes"
ceph_nova_pool_name: "nova-vms"
EOF
    fi

    # Its own sentinel, so Octavia can be added to an already-deployed lab with
    # 'ENABLE_NETWORK_LOADBALANCER=yes provision-lab --from 70-kolla' -- the block above is
    # already present and is skipped, this one gets appended.
    if [ "$ENABLE_NETWORK_LOADBALANCER" = yes ] && ! grep -q '^# ---- octavia ----' /etc/kolla/globals.yml; then
        sudo -u kolla tee -a /etc/kolla/globals.yml > /dev/null <<'EOF'

# ---- octavia ----
enable_octavia: "yes"
enable_horizon_octavia: "yes"

# Two amphorae per load balancer with VRRP between them, so losing one is a
# survivable event rather than an outage -- which is the point of the exercise.
# SINGLE halves the memory and removes it.
octavia_loadbalancer_topology: "ACTIVE_STANDBY"

# The jobboard auto-enables with the amphora driver, and its template fills
# jobboard_backend_hosts by iterating groups['valkey'] -- but enable_valkey is
# false and nothing turns it on, so the worker would start with an empty backend
# list. Either deploy valkey plus its sentinel, or turn the jobboard off. It only
# buys resumable task flows after a worker crash, so: off.
enable_octavia_jobboard: "no"

# 'provider' expects lb-mgmt-net on a physnet, and kolla0 has no physnet mapping.
# 'tenant' creates an o-hm0 OVS port on br-int instead: self-contained, no second
# physnet, but a runtime interface -- so it needs recreating at boot the same way
# kolla0 and veth-ext do.
octavia_network_type: "tenant"
EOF
    fi

    # octavia_network_type=tenant makes Kolla write octavia-interface.service, whose
    # ExecStart is a hard-coded /sbin/dhclient against the o-hm0 OVS port. Ubuntu
    # 24.04 does not ship dhclient any more -- netplan drives systemd-networkd --
    # so the unit dies with status=203/EXEC and the deploy fails on its very last
    # task, after everything else has succeeded. The OVS port is created and the MAC
    # is set; only the DHCP client is absent. isc-dhcp-client is still packaged.
    # Every package this lab needs is in the machine image. Nothing installs packages
    # in the VM at runtime, deliberately: an 'apt-get update' here would refresh a
    # machine whose whole premise is a pinned Ceph 20.2.2, and the most likely thing
    # it drags in is a mismatched client. So this checks rather than installs.
    if [ "$ENABLE_NETWORK_LOADBALANCER" = yes ] && [ ! -x /sbin/dhclient ]; then
        die "no /sbin/dhclient -- octavia-interface.service needs it, and it should have
    come from the image. Rebuild with ./02-build-image.sh, which installs
    isc-dhcp-client, or build without load balancing using
    ENABLE_NETWORK_LOADBALANCER=no."
    fi

    # The amphora CA has to exist before deploy: the octavia role copies the certs
    # into the containers, and a missing one fails the play rather than degrading.
    #
    # -i is required. Without it kolla-ansible looks for its packaged default,
    # /etc/kolla/ansible/inventory/all-in-one, which this lab does not use, and
    # stops with "Kolla inventory ... is invalid: Path does not exist".
    if [ "$ENABLE_NETWORK_LOADBALANCER" = yes ] && [ ! -f /etc/kolla/config/octavia/client_ca.cert.pem ]; then
        run_logged octavia-certificates sudo -u kolla bash -lc \
            '. /opt/kolla/venv/bin/activate && kolla-ansible octavia-certificates -i /opt/kolla/all-in-one' \
            || die "kolla-ansible octavia-certificates failed"
        info "octavia certificates generated"
    fi

    # Octavia waits amp_active_retries x amp_active_wait_sec for an amphora to answer,
    # then marks the load balancer ERROR. Kolla ships 100 x 2 = 200 seconds -- it raises
    # the retry count from the upstream 30 but cuts the interval from 10, so the budget
    # is shorter than the default, not longer.
    #
    # 200 seconds is not enough here. Two amphorae boot at once for ACTIVE_STANDBY on a
    # machine already running Ceph and the whole control plane, and the second one is
    # slow whenever the host is busy. Measured across runs on identical configuration:
    # ACTIVE at 235s and 293s, and one run that gave up at 340s. Whether the lab builds
    # was decided by how loaded the Mac happened to be.
    #
    # 300 retries at the same 2-second interval is ten minutes. The interval stays short
    # so a healthy amphora is still picked up within two seconds; only the patience for
    # a slow one changes.
    #
    # The path matters. Kolla merges, in order:
    #     <custom>/octavia.conf                  -- every octavia service
    #     <custom>/octavia/<service_name>.conf   -- one service, e.g. octavia_worker.conf
    # There is no <custom>/octavia/octavia.conf in that list, and a file written there is
    # ignored in silence.
    if [ "$ENABLE_NETWORK_LOADBALANCER" = yes ]; then
        mkdir -p /etc/kolla/config
        cat > /etc/kolla/config/octavia.conf <<'EOF'
[controller_worker]
amp_active_retries = 300
EOF
        info "octavia amphora wait raised to 10 minutes (was 200s)"
    fi

    # Ceph config and keyrings, per service. Leading tabs from cephadm's
    # generate-minimal-conf break Kolla's ini parser, so strip them.
    #
    # cephadm's minimal config carries only fsid and mon_host; without the keyring
    # path and the three cephx lines the clients fall back to defaults and may not
    # find the right keyring. The keyring paths are the IN-CONTAINER locations
    # Kolla mounts to, not the host paths under /etc/kolla/config.
    for svc in glance cinder nova; do
        mkdir -p "/etc/kolla/config/$svc"
        sed 's/^[[:space:]]*//' /etc/ceph/ceph.conf > "/etc/kolla/config/$svc/ceph.conf"
        case "$svc" in
            glance) key=glance ;;
            *)      key=cinder ;;
        esac
        cat >> "/etc/kolla/config/$svc/ceph.conf" <<EOF
keyring = /etc/ceph/ceph.client.$key.keyring
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx
EOF
    done
    # Glance writes an image to RBD chunk by chunk and, by default, writes the zero
    # chunks too. That matters here because the amphora image is a 2.6 GB raw disk
    # image holding about 1 GB of files -- a 549 MB EFI partition with 192 KB in it,
    # and a 2 GB root partition 60% used. Measured without this: glance-images at
    # 2.8 GiB stored, 5.5 GiB used. Skipping the all-zero chunks stores what the
    # image actually contains instead of its declared size.
    cat > /etc/kolla/config/glance/glance-api.conf <<'EOF'
[rbd]
rbd_thin_provisioning = True
EOF

    mkdir -p /etc/kolla/config/cinder/cinder-volume
    cat /etc/ceph/ceph.client.glance.keyring > /etc/kolla/config/glance/ceph.client.glance.keyring
    cat /etc/ceph/ceph.client.cinder.keyring > /etc/kolla/config/cinder/cinder-volume/ceph.client.cinder.keyring
    cat /etc/ceph/ceph.client.cinder.keyring > /etc/kolla/config/nova/ceph.client.cinder.keyring
    chmod 600 /etc/kolla/config/glance/*.keyring \
              /etc/kolla/config/nova/*.keyring \
              /etc/kolla/config/cinder/cinder-volume/*.keyring
    chown -R kolla:kolla /etc/kolla/config
    grep -qP '^\t' /etc/kolla/config/glance/ceph.conf && die "tabs remain in ceph.conf"

    # With external Ceph the [storage] group can end up empty, which upstream
    # warns will fail Cinder. all-in-one should already have localhost.
    grep -A2 '^\[storage\]' /opt/kolla/all-in-one | grep -q localhost \
        || die "[storage] group in the inventory has no host"

    find /etc/kolla/config -type f | sort | sed 's/^/    /' | tee -a "$LOG"
}

# =============================================================================
# 80-deploy -- bootstrap-servers, prechecks, deploy, post-deploy
#
# The long one: nearly all of it is pulling aarch64 container images.
# =============================================================================
phase_80_deploy() {
    # Kolla's containerised libvirt needs exclusive use of libvirt-sock, so the
    # host copy must not be running or prechecks fails on "Checking that host
    # libvirt is not running".
    systemctl stop libvirtd.service libvirtd.socket libvirtd-ro.socket \
        libvirtd-admin.socket virtlogd.socket virtlockd.socket 2>/dev/null || true
    systemctl start libvirt-apparmor-load 2>/dev/null || true

    # Full output goes to $LOG continuously via tee, so progress can be followed
    # from outside with 'tail -f'. Only the tail is echoed here to keep a
    # multi-hour ansible run readable.
    # Via run_logged so ansible gets blocking stdio. Full output lands in
    # /var/log/openstack-lab-<step>.out and is copied into $LOG.
    kolla_run() {
        run_logged "$1" sudo -u kolla bash -lc \
            ". /opt/kolla/venv/bin/activate && kolla-ansible $* -i /opt/kolla/all-in-one"
    }

    # Ansible's failure detail is usually well above the PLAY RECAP.
    kolla_fail() {
        info "--- last 60 log lines ---"
        tail -60 "$LOG" | sed 's/^/    /'
        info "--- failed tasks ---"
        grep -E '^(fatal|failed):' "$LOG" | tail -10 | sed 's/^/    /'
        die "$1"
    }

    if [ ! -f "$STATE_DIR/80-deploy.bootstrap" ]; then
        log "kolla-ansible bootstrap-servers"
        kolla_run bootstrap-servers || kolla_fail "bootstrap-servers failed"
        touch "$STATE_DIR/80-deploy.bootstrap"
    fi

    # /etc/hosts regenerates on some boots; re-check before the precheck that
    # cares about it.
    sed -i -E "/^192\.168\.64\.[0-9]+[[:space:]]+$(hostname)([[:space:]]|\$)/d" /etc/hosts

    # --use-test-images is a prechecks-only flag; deploy rejects it. Kolla
    # publishes tagged releases and daily CI builds to the same namespace, so the
    # gate fires on the namespace rather than on what is actually pulled. With
    # openstack_release pinned this is the release tag.
    log "kolla-ansible prechecks"
    kolla_run prechecks --use-test-images || kolla_fail "prechecks failed -- fix before deploying"

    log "kolla-ansible deploy (this is the long one)"
    kolla_run deploy || kolla_fail "deploy failed"

    log "kolla-ansible post-deploy"
    kolla_run post-deploy || kolla_fail "post-deploy failed"

    [ -f /etc/kolla/clouds.yaml ] || die "no /etc/kolla/clouds.yaml after post-deploy"
}

# =============================================================================
# 85-rgw -- object storage (S3) via Ceph RGW
#
# The best value-per-effort addition: one orchestrator command, no image build,
# no re-stack, and it cannot disturb the OpenStack deployment.
#
# NOT registered in Keystone as a Swift endpoint. Doing that means setting
# enable_ceph_rgw plus ceph_rgw_hosts in globals.yml and re-running
# 'kolla-ansible deploy'. Never set those before the gateway is actually running,
# or Keystone advertises a Swift endpoint that refuses connections.
# =============================================================================
phase_85_rgw() {
    if ! ceph_do ceph orch ls --service-name rgw.lab 2>/dev/null | grep -q rgw.lab; then
        # Port 8000 rather than the default 80, to stay clear of anything else in
        # the container.
        ceph_do ceph orch apply rgw lab --placement="1 ceph-node1" --port=8000 >/dev/null \
            || die "could not apply the rgw service"
    fi
    wait_for 420 "rgw.lab running" bash -c \
        "incus exec ceph-node1 -- cephadm shell -- ceph orch ls --service-name rgw.lab 2>/dev/null | grep -qE '1/1'" \
        || die "rgw.lab never reached 1/1 -- see 'ceph orch ps --daemon-type rgw'"

    # A working gateway answers anonymously with ListAllMyBucketsResult XML.
    #
    # Poll for it rather than checking once. 'ceph orch ls' reports 1/1 as soon as
    # the orchestrator has placed the daemon, which is several seconds before
    # radosgw has actually bound port 8000 -- a single-shot check right after 1/1
    # fails against a gateway that is simply not listening yet.
    wait_for 300 "RGW serving on ceph-node1:8000" bash -c \
        "incus exec ceph-node1 -- curl -sS -m 5 http://localhost:8000 2>/dev/null | grep -q ListAllMyBucketsResult" \
        || die "RGW is 1/1 but never served ListAllMyBucketsResult"

    incus exec ceph-node1 -- cephadm shell -- radosgw-admin user info --uid=labuser >/dev/null 2>&1 || \
        incus exec ceph-node1 -- cephadm shell -- radosgw-admin user create \
            --uid=labuser --display-name="Lab User" >/dev/null 2>&1

    # Parse the JSON. Do NOT grep -A3 '"keys"' -- that truncates before the secret.
    creds=$(incus exec ceph-node1 -- cephadm shell -- \
              radosgw-admin user info --uid=labuser --format=json 2>/dev/null \
            | python3 -c 'import json,sys
d=json.load(sys.stdin); k=d["keys"][0]
print(k["access_key"]); print(k["secret_key"])' 2>/dev/null)
    AK=$(printf '%s\n' "$creds" | sed -n 1p)
    SK=$(printf '%s\n' "$creds" | sed -n 2p)
    [ -n "$AK" ] && [ -n "$SK" ] || die "could not read labuser's S3 keys"
    info "S3 access key: $AK"

    # RGW listens inside the container; a proxy device brings it to the VM and,
    # because it listens on all interfaces including enp0s1, to macOS as well.
    add_proxy ceph-node1 rgw "$RGW_VM_PORT" "$CEPH_SUBNET.11:$RGW_CONTAINER_PORT"

    # Point at 127.0.0.1, NOT the VM's vmnet address.
    #
    # enp0s1's address changes on every machine restart, and this file is written
    # once by a checkpointed phase -- so an embedded VM IP is correct exactly until
    # the first reboot, after which every s3cmd call fails with a connection error
    # against a gateway that is running fine. The proxy device listens on
    # 0.0.0.0:$RGW_VM_PORT, so loopback always reaches it.
    #
    # From macOS, use the current VM address instead; 90-verify prints it.
    #
    # signature_v2 is required: with v4 every request fails 403
    # SignatureDoesNotMatch, because the v4 signature covers the Host header and
    # RGW's configured hostname is not what the client sends through the proxy.
    # host_bucket in path style avoids needing wildcard DNS for virtual-hosted
    # buckets.
    cat > "$SHARED_DIR/s3cfg" <<EOF
[default]
access_key = $AK
secret_key = $SK
host_base = 127.0.0.1:$RGW_VM_PORT
host_bucket = 127.0.0.1:$RGW_VM_PORT/%(bucket)s
use_https = False
signature_v2 = True
EOF
    chmod 600 "$SHARED_DIR/s3cfg"

    # Full round trip. s3cmd prints SyntaxWarning lines under Python 3.12 --
    # cosmetic, ignore them.
    s3cmd -c "$SHARED_DIR/s3cfg" ls "s3://testbucket" >/dev/null 2>&1 || \
        s3cmd -c "$SHARED_DIR/s3cfg" mb s3://testbucket >/dev/null 2>&1 || \
        die "s3cmd could not create a bucket"
    echo "hello from ceph rgw" > /tmp/s3-hello.txt
    s3cmd -c "$SHARED_DIR/s3cfg" put /tmp/s3-hello.txt s3://testbucket/ >/dev/null 2>&1 \
        || die "s3cmd put failed"
    s3cmd -c "$SHARED_DIR/s3cfg" get s3://testbucket/s3-hello.txt /tmp/s3-back.txt --force >/dev/null 2>&1 \
        || die "s3cmd get failed"
    grep -q 'hello from ceph rgw' /tmp/s3-back.txt \
        || die "S3 round trip returned the wrong content"
    info "S3 round trip OK (put/get verified)"
    s3cmd -c "$SHARED_DIR/s3cfg" ls s3://testbucket/ | sed 's/^/    /' | tee -a "$LOG"
}

# =============================================================================
# 86-nfs -- CephFS plus an NFS export
#
# Pure Ceph: a filesystem and a cephadm-managed NFS-Ganesha cluster. No Manila,
# so shares are created here rather than self-serviced through the OpenStack API.
# NFSv4 only, which needs just port 2049 and therefore one proxy device.
# =============================================================================
phase_86_nfs() {
    if ! ceph_do ceph fs ls 2>/dev/null | grep -q 'name: labfs'; then
        ceph_do ceph fs volume create labfs --placement="1 ceph-node1" >/dev/null \
            || die "could not create the CephFS volume"
    fi
    wait_for 420 "labfs MDS active" bash -c \
        "incus exec ceph-node1 -- cephadm shell -- ceph fs status labfs 2>/dev/null | grep -q active" \
        || die "labfs has no active MDS"

    if ! ceph_do ceph nfs cluster ls 2>/dev/null | grep -q labnfs; then
        ceph_do ceph nfs cluster create labnfs "1 ceph-node1" >/dev/null \
            || die "could not create the NFS cluster"
    fi

    # Ganesha ALWAYS registers NFSv3 at startup, and needs rpcbind to do it.
    #
    # cephadm hardcodes "Protocols = 3, 4;" into the ganesha.conf it generates.
    # Neither a v4-only export nor 'ceph nfs cluster config set' changes it -- the
    # generated NFS_CORE_PARAM block wins, so the daemon always attempts v3
    # registration. Without rpcbind that fails and ganesha exits:
    #     nfs_Init_svc :DISP :CRIT :Cannot acquire credentials for principal nfs
    #     __Register_program :DISP :MAJ :Cannot register NFS V3 on TCP
    #     status=2/INVALIDARGUMENT ... Start request repeated too quickly
    # all while 'ceph orch ps' reports the daemon as running.
    #
    # rpcbind comes from the node base image built in 30-nodebase, which is rebuilt
    # on every run -- so this is a check, not an install. Nothing uses v3; the export
    # below is v4 only. rpcbind just has to exist or ganesha exits 2 at startup.
    # bash -c is required: 'command' is a shell builtin and 'incus exec' runs a
    # binary directly, so the unwrapped form always fails with "Command not found"
    # regardless of whether rpcbind is installed.
    incus exec ceph-node1 -- bash -c 'command -v rpcbind' >/dev/null 2>&1 \
        || die "rpcbind missing in ceph-node1 -- it should come from ceph-base (30-nodebase)"
    incus exec ceph-node1 -- systemctl enable --now rpcbind rpcbind.socket >/dev/null 2>&1 || true
    [ "$(incus exec ceph-node1 -- systemctl is-active rpcbind 2>&1)" = active ] \
        || die "rpcbind is not running in ceph-node1 -- ganesha will exit on startup"

    # Pin the EXPORT to NFSv4 only. This does not stop ganesha registering v3 (see
    # above), but it is what clients are offered, and it matches the kernel: the
    # generated config says "Minor_Versions = 1, 2", so the server speaks 4.1/4.2
    # and the client needs CONFIG_NFS_V4_1 (01-build-kernel.sh) or every mount
    # fails with "mount.nfs4: Protocol not supported".
    incus exec ceph-node1 -- bash -c "cat <<'JSON' | cephadm shell -- ceph nfs export apply labnfs -i -
{
  \"export_id\": 1,
  \"path\": \"/\",
  \"cluster_id\": \"labnfs\",
  \"pseudo\": \"/labshare\",
  \"access_type\": \"RW\",
  \"squash\": \"none\",
  \"protocols\": [4],
  \"transports\": [\"TCP\"],
  \"fsal\": {\"name\": \"CEPH\", \"fs_name\": \"labfs\"}
}
JSON" >/dev/null 2>&1 || die "could not apply the NFSv4-only export"

    # If a previous attempt crash-looped, systemd has tripped its restart limit and
    # will refuse to start the unit again ("Start request repeated too quickly")
    # even once the cause is fixed. reset-failed clears that; redeploy then
    # regenerates the config and starts it.
    incus exec ceph-node1 -- bash -c \
        'systemctl reset-failed "ceph-*@nfs.labnfs.*.service" 2>/dev/null || true' >/dev/null 2>&1
    ceph_do ceph orch redeploy nfs.labnfs >/dev/null 2>&1 || true

    # Judge readiness by an actual TCP connect to the container, NOT by
    # 'ceph orch ls' -- it reported 1/1 for a daemon that had already exited.
    wait_for 420 "ganesha accepting connections on $CEPH_SUBNET.11:2049" bash -c \
        "timeout 5 bash -c '</dev/tcp/$CEPH_SUBNET.11/2049' 2>/dev/null" \
        || die "ganesha never listened on 2049 -- check 'journalctl -u ceph-*@nfs.*' in ceph-node1"

    ceph_do ceph nfs export ls labnfs | sed 's/^/    /' | tee -a "$LOG"
    add_proxy ceph-node1 nfs 2049 "$CEPH_SUBNET.11:2049"

    # nfs-common is in the image package list; check rather than install, for the
    # same reason as dhclient above.
    command -v mount.nfs4 >/dev/null 2>&1 \
        || die "no mount.nfs4 -- nfs-common should have come from the image; rebuild with ./02-build-image.sh"

    # soft,retry=0 and a timeout wrapper: a default NFS mount retries for minutes
    # rather than failing, so wait_for would never get to iterate.
    mkdir -p /mnt/labshare
    mountpoint -q /mnt/labshare && umount -f /mnt/labshare
    wait_for 300 "NFS export mountable" bash -c \
        "timeout 30 mount -t nfs4 -o proto=tcp,port=2049,vers=4.1,soft,retry=0,timeo=50 127.0.0.1:/labshare /mnt/labshare" \
        || die "could not mount the NFS export"

    echo "hello from cephfs over nfs" > /mnt/labshare/hello.txt
    grep -q 'hello from cephfs over nfs' /mnt/labshare/hello.txt \
        || die "NFS write/read back failed"
    info "NFS round trip OK (wrote and read /mnt/labshare/hello.txt)"
    df -h /mnt/labshare | tail -1 | sed 's/^/    /' | tee -a "$LOG"
    umount /mnt/labshare
}

# =============================================================================
# 90-verify -- prove the cloud works and the data is in Ceph
# =============================================================================
# Properly quoted openstack wrapper. The one inside phase_90_verify interpolates
# $*, which is fine for 'os service list' but splits any argument containing a
# space -- and this phase passes image properties and file paths.
oscli() {
    sudo -u kolla bash -lc \
        '. /opt/kolla/venv/bin/activate && \
         OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin exec openstack "$@"' \
        _ "$@"
}

phase_87_octavia() {
    if [ "$ENABLE_NETWORK_LOADBALANCER" != yes ]; then
        info "load balancing disabled -- ENABLE_NETWORK_LOADBALANCER=yes provision-lab --from 70-kolla adds it"
        return 0
    fi

    local src=/opt/octavia-src dib=/opt/dib work=/opt/amphora-build
    local img="$work/amphora-arm64-haproxy.raw"
    local build_log=/var/log/amphora-build.log

    # There is no prebuilt amphora for this architecture. Every image published at
    # tarballs.opendev.org/openstack/octavia/test-images/ is x64 -- nine of them,
    # not one arm64. So it gets built here, from the Octavia source at the same
    # branch as the control plane: an amphora-agent newer than the API it reports
    # to is a version skew you discover at the first failover, not at boot.
    # Glance is the source of truth, not the local file. The build tree is deleted
    # once the upload succeeds, so keying the rebuild on the raw file alone would make
    # every re-run of this phase rebuild an image the cluster already has.
    if oscli image show amphora >/dev/null 2>&1; then
        info "amphora already in glance -- skipping the build"
    elif [ ! -f "$img" ]; then
        info "building the amphora image (a few minutes; 3 min and 11 min measured on\
 two runs, it depends on how fast the Ubuntu mirror is)"

        # qemu-utils, debootstrap, kpartx, python3-venv, uuid-runtime, dosfstools and
        # git all come from the image. Check, do not install.
        for t in qemu-img debootstrap kpartx python3 uuidgen mkfs.vfat git; do
            command -v "$t" >/dev/null 2>&1 \
                || die "$t is missing -- it should have come from the image; rebuild with ./02-build-image.sh"
        done

        if [ ! -x "$dib/bin/disk-image-create" ]; then
            python3 -m venv "$dib" >>"$build_log" 2>&1
            "$dib/bin/pip" -q install --upgrade pip >>"$build_log" 2>&1
            "$dib/bin/pip" -q install diskimage-builder >>"$build_log" 2>&1 \
                || die "diskimage-builder install failed -- see $build_log"
        fi

        [ -d "$src/.git" ] || git clone --depth 1 -b "$KOLLA_BRANCH" \
            https://opendev.org/openstack/octavia "$src" >>"$build_log" 2>&1 \
            || die "could not clone octavia at $KOLLA_BRANCH"

        # stable/2026.1 accepts -a aarch64, then hands the value straight to
        # disk-image-create and on to debootstrap -- which only knows the Debian
        # name arm64 and dies with "Invalid Release file, no entry for
        # main/binary-aarch64/Packages". Passing -a arm64 instead is rejected by
        # the script's own validation. Master accepts both; backport that line.
        local dic="$src/diskimage-create/diskimage-create.sh"
        grep -q '"\$AMP_ARCH" != "arm64"' "$dic" || sed -i \
            's/\[ "\$AMP_ARCH" != "aarch64" \] && \\/&\n                [ "$AMP_ARCH" != "arm64" ] \&\& \\/' "$dic"
        bash -n "$dic" || die "the arm64 backport broke $dic"

        mkdir -p "$work"
        # -g pins the amphora-agent branch. Without it the checkout above is
        # ignored and the agent is pulled from master, which the script announces
        # as "using amphora-agent from the master branch" and nothing else warns
        # about. A master agent against a 2026.1 control plane is a skew you meet
        # at the first failover. It also pins upper-constraints to the same branch.
        #
        # -f turns off dib's tmpfs build: it wants several GB of RAM and this VM is
        # already running Ceph, Kolla and their guests. -t raw because Glance sits
        # on RBD, where Nova copy-on-write clones a raw image and converts a qcow2
        # one on every single boot.
        ( cd "$src/diskimage-create" && PATH="$dib/bin:$PATH" \
            ./diskimage-create.sh -a arm64 -i ubuntu-minimal -t raw -s 2 -f \
                -g "$KOLLA_BRANCH" \
                -w "$work" -o "$work/amphora-arm64-haproxy" ) >>"$build_log" 2>&1 \
            || die "amphora image build failed -- see $build_log"
    fi
    [ -f "$img" ] || die "amphora build finished but $img is missing -- see $build_log"
    info "amphora image: $(du -h "$img" | cut -f1)"

    # amp_image_owner_id defaults to the service project, and amp_image_tag to
    # 'amphora'. An image uploaded into admin instead is invisible to Octavia, and
    # the only symptom is a load balancer that sits in PENDING_CREATE until it
    # times out. hw_firmware_type=uefi for the same reason lab-workload needs it:
    # aarch64 has no BIOS, so without it the amphora never reaches a bootloader.
    if ! oscli image show amphora >/dev/null 2>&1; then
        oscli image create amphora \
            --disk-format raw --container-format bare \
            --project service --tag amphora \
            --property hw_firmware_type=uefi \
            --file "$img" >/dev/null || die "amphora image upload failed"
        info "amphora image uploaded to glance, owned by the service project"
    fi

    # Glance has the image now, so the local copy is dead weight -- and it is not
    # small: 2.6 GB apparent, 1.1 GB of real blocks on the Mac's disk, which nothing
    # else ever reclaims because the VM's filesystem is never trimmed automatically.
    # The diskimage-builder work tree beside it is the same story.
    if oscli image show amphora >/dev/null 2>&1; then
        # everything the build needed and nothing after it: the raw image, the
        # diskimage-builder work tree, the octavia checkout and the dib venv itself.
        # All of it is recreated on demand if this phase is ever re-run.
        rm -rf "$work"/*.raw "$work"/*.qcow2 "$work"/*.d "$src" "$dib" 2>/dev/null || true
        rm -rf /var/lib/apt/lists/* /root/.cache/pip /tmp/dib_* 2>/dev/null || true
        # Deleting inside the VM frees guest blocks but hands nothing back to macOS:
        # the disk image is sparse and grows only. Trim right here, at the cleanup,
        # rather than leaving it to fstrim.timer, which fires weekly and will never
        # run inside the life of a lab that is built and torn down the same day.
        fstrim / >/dev/null 2>&1 || true
        info "removed the local amphora build tree and trimmed -- glance has the image"
    fi

    # Kolla's octavia-interface.service is ordered After=docker.service, but docker
    # being up is not the same as the openvswitch container having recreated br-int's
    # ports. On every machine restart the unit runs first, its ExecStartPre dies with
    #     Cannot find device "o-hm0"
    # and systemd burns all five default retries inside one second:
    #     octavia-interface.service: Start request repeated too quickly
    #
    # The unit then stays failed, o-hm0 stays DOWN, and the health manager has no path
    # to the amphorae -- so load balancers are silently unmonitored after any restart.
    # Nothing else reports this; the octavia containers are all healthy.
    #
    # A drop-in that retries patiently fixes it without touching Kolla's unit. Five
    # seconds apart for five minutes is far longer than OVS takes.
    mkdir -p /etc/systemd/system/octavia-interface.service.d
    cat > /etc/systemd/system/octavia-interface.service.d/10-wait-for-ovs.conf <<'EOF'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=60

[Service]
RestartSec=5
EOF
    systemctl daemon-reload
    systemctl reset-failed octavia-interface 2>/dev/null || true
    systemctl enable --now octavia-interface >/dev/null 2>&1 || true
    wait_for 180 "o-hm0 up (health manager path to the amphorae)" \
        bash -c "ip -br addr show o-hm0 2>/dev/null | grep -q '10\.'" \
        || die "o-hm0 has no address -- systemctl status octavia-interface"

    wait_for 180 "octavia api answering" bash -c \
        "timeout 5 bash -c '</dev/tcp/$KOLLA_VIP/9876'" \
        || die "NOT listening: octavia-api -- check 'docker logs octavia_api'"

    # Third missing CLI plugin, after heat and barbican: Kolla's venv has no
    # octaviaclient, so 'openstack loadbalancer ...' is not an openstack command at
    # all and the CLI answers with a list of 'container ...' suggestions, which
    # reads like the load balancer is broken rather than the client being absent.
    sudo -u kolla bash -lc \
        '. /opt/kolla/venv/bin/activate && python -c "import octaviaclient" 2>/dev/null' || \
    sudo -u kolla bash -lc \
        '. /opt/kolla/venv/bin/activate && python -c "import octaviaclient" 2>/dev/null' || \
    sudo -u kolla bash -lc \
        '. /opt/kolla/venv/bin/activate && pip -q install python-octaviaclient' \
        || die "could not install python-octaviaclient"

    oscli loadbalancer provider list | sed 's/^/    /' | tee -a "$LOG"

    # is_public is false on the amphora flavor, so it only shows with --all -- worth
    # printing, because "the flavor is missing" is the first wrong guess when a load
    # balancer will not build.
    oscli flavor list --all -f value -c Name -c RAM -c VCPUs | grep -i amphora \
        | sed 's/^/    amphora flavor: /' | tee -a "$LOG"
}

# Write /usr/local/sbin/lab-expose, which publishes a workload on the VM's address.
#
# Instances live on 172.24.4.0/24 behind br-ex, and macOS has no route there: a
# floating IP works from inside the VM and from other guests, and from nowhere else.
# 'route -n get' on the Mac shows those addresses going to the LAN gateway, so the
# packets leave the machine entirely.
#
# A static route on macOS would fix it, but needs sudo, does not survive a reboot,
# and points at a VM address that changes on every machine start. Forwarding a port
# on the VM needs none of that -- macOS already reaches the VM, and the URL uses the
# address 90-verify prints anyway. It is the same DNAT the lab already uses to bring
# Horizon out to the host.
write_lab_expose() {
    cat > /usr/local/sbin/lab-expose <<'EXPOSE'
#!/bin/bash
# Publish a lab workload on the VM's address, so a browser on macOS can reach it.
#
#   lab-expose 18080 172.24.4.20        http://<vm-ip>:18080/  ->  172.24.4.20:80
#   lab-expose 18081 172.24.4.21:8080   a port other than 80
#   lab-expose --list                   what is published now
#   lab-expose --clear                  remove all of them
#
# Not persistent: a machine restart clears these. Floating IPs change from exercise
# to exercise anyway, so re-run it rather than expecting it to stick.
set -uo pipefail
IFACE=enp0s1

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

list() {
    local n
    n=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c 'lab-expose')
    if [ "$n" -eq 0 ]; then echo "nothing published"; return 0; fi
    local vmip; vmip=$(ip -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)
    iptables -t nat -S PREROUTING 2>/dev/null | grep 'lab-expose' | while read -r r; do
        local port to
        port=$(sed -n 's/.*--dport \([0-9]*\).*/\1/p' <<<"$r")
        to=$(sed -n 's/.*--to-destination \([0-9.:]*\).*/\1/p' <<<"$r")
        printf '  http://%s:%s/  ->  %s\n' "$vmip" "$port" "$to"
    done
}

case "${1:-}" in
    --list|-l|"") list; exit 0 ;;
    --clear|-c)
        while iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'lab-expose'; do
            iptables -t nat -D PREROUTING $(iptables -t nat -S PREROUTING \
                | grep -m1 'lab-expose' | sed 's/^-A PREROUTING //') 2>/dev/null || break
        done
        echo "cleared"; exit 0 ;;
    --help|-h) usage ;;
esac

PORT="$1"; TARGET="${2:-}"
[ -n "$TARGET" ] || usage
case "$TARGET" in *:*) DEST="$TARGET" ;; *) DEST="$TARGET:80" ;; esac

[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "port must be a number: $PORT" >&2; exit 1; }
if ss -tln | awk '{print $4}' | grep -q ":${PORT}$"; then
    echo "port $PORT is already in use on the VM (ss -tlnp | grep $PORT)" >&2; exit 1
fi

iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport "$PORT" \
    -m comment --comment lab-expose -j DNAT --to-destination "$DEST" \
    || { echo "could not add the rule" >&2; exit 1; }

VMIP=$(ip -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)
echo "http://$VMIP:$PORT/  ->  $DEST"
EXPOSE
    chmod 755 /usr/local/sbin/lab-expose
}

phase_90_verify() {
    os() {
        sudo -u kolla bash -lc \
            ". /opt/kolla/venv/bin/activate && \
             OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin openstack $*" 2>&1
    }

    info "this phase waits for services that may still be starting -- pauses are expected,"
    info "and nothing here is a problem unless a line says GAVE UP or NOT."

    log "ceph"
    # After a machine restart the mons re-form quorum and the OSDs re-peer, and
    # HEALTH_OK comes back 60-90s in. Checking once and announcing "cluster is not
    # HEALTH_OK" turns ordinary startup into an alarm -- which is exactly how it read
    # to someone running this a minute after boot. Wait first, judge afterwards.
    if wait_for 300 "Ceph to reach HEALTH_OK" bash -c \
        "incus exec ceph-node1 -- cephadm shell -- ceph health 2>/dev/null | grep -q HEALTH_OK"
    then
        ceph_do ceph -s | sed 's/^/    /' | tee -a "$LOG"
    else
        ceph_do ceph -s | sed 's/^/    /' | tee -a "$LOG"
        info "NOT healthy after 5 minutes. 'ceph health detail' says:"
        ceph_do ceph health detail 2>/dev/null | head -20 | sed 's/^/      /' | tee -a "$LOG"
    fi

    # After a machine restart the Kolla containers come back on Docker's restart
    # policy, but keepalived takes another 20-30s to claim the VIP. Querying before
    # that gives "No route to host" on the VIP and a 503 from the APIs behind
    # haproxy -- which looks like a broken deployment and is only impatience.
    wait_for 300 "keepalived to claim the VIP" \
        bash -c "ip -br addr show kolla0 | grep -q '$KOLLA_VIP/'" \
        || info "NOT up: the VIP $KOLLA_VIP never appeared -- check 'docker logs keepalived'"
    wait_for 300 "keystone on the VIP" \
        bash -c "curl -sS -m 5 -o /dev/null http://$KOLLA_VIP:5000/" \
        || info "NOT answering: keystone on $KOLLA_VIP:5000 -- check 'docker logs keystone'"

    log "openstack services"
    os service list | sed 's/^/    /' | tee -a "$LOG"

    # nova-api comes up behind haproxy later than keystone; querying first gives
    # "503 Service Unavailable: No server is available to handle this request",
    # which looks like a dead cloud rather than one still starting.
    wait_for 300 "nova API on the VIP" bash -c \
        "curl -sS -m 5 -o /dev/null http://$KOLLA_VIP:8774/" \
        || info "NOT answering: nova API on $KOLLA_VIP:8774 -- check 'docker logs nova_api'"

    log "compute"
    os compute service list | sed 's/^/    /' | tee -a "$LOG"

    # This is what proves libvirt reached /dev/kvm through nested virtualization.
    # An empty list with services up means compute failed to register -- almost
    # always the Ceph keyring not being readable by nova-compute. But nova-compute
    # also takes a little while to report in after a restart, so wait before
    # concluding anything: an empty list at 20 seconds means nothing at all.
    if wait_for 180 "the hypervisor to register with nova" bash -c \
        "sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && \
         OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin \
         openstack hypervisor list -f value -c ID' 2>/dev/null \
         | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-'"
    then
        hv=$(os hypervisor list -f value -c ID 2>/dev/null \
               | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-' || true)
        info "hypervisor registered ($hv)"
    else
        info "still no hypervisor -- trying cell discovery, which is the usual fix"
        docker exec nova_conductor nova-manage cell_v2 discover_hosts --verbose 2>&1 | tail -5 | tee -a "$LOG"
        os hypervisor list | sed 's/^/    /' | tee -a "$LOG"
        info "if that list is still empty: NOT registered -- check the cinder/nova"
        info "keyrings in /etc/ceph and 'docker logs nova_compute'"
    fi

    # The Ceph dashboard lives on the Incus bridge; a proxy device brings it to
    # the VM, where it is reachable from macOS with no iptables because the
    # device listens on all interfaces including enp0s1.
    add_proxy ceph-node1 dashboard 8443 "$CEPH_SUBNET.11:8443"
    echo -n "$DASHBOARD_PASSWORD" | incus exec ceph-node1 -- cephadm shell -- \
        ceph dashboard ac-user-set-password admin --force-password -i - >/dev/null 2>&1 || true

    # After a machine restart the Ceph daemons come back later than the Kolla
    # containers -- RGW and ganesha took about 50s in testing. Checking before that
    # reports a broken S3/NFS setup that is merely still starting, which is how the
    # restart test was misread twice. Only wait if they are meant to exist.
    if ceph_do ceph orch ls 2>/dev/null | grep -q '^rgw.lab'; then
        wait_for 300 "RGW serving after restart" bash -c \
            "timeout 5 bash -c '</dev/tcp/$CEPH_SUBNET.11/$RGW_CONTAINER_PORT'" \
            || info "NOT serving: RGW -- check 'ceph orch ps --daemon-type rgw'"
    fi
    # o-hm0 is a runtime OVS port, so it is the octavia thing most likely to be
    # missing after a restart. The drop-in in 87-octavia should have handled it;
    # check anyway, because a failed one is invisible from the container status.
    if [ "$ENABLE_NETWORK_LOADBALANCER" = yes ] && systemctl list-unit-files octavia-interface.service >/dev/null 2>&1; then
        if ip -br addr show o-hm0 2>/dev/null | grep -q '10\.'; then
            info "o-hm0 up ($(ip -br addr show o-hm0 | awk '{print $3}'))"
        else
            systemctl reset-failed octavia-interface 2>/dev/null || true
            systemctl start octavia-interface 2>/dev/null || true
            wait_for 120 "o-hm0 up after restart" \
                bash -c "ip -br addr show o-hm0 2>/dev/null | grep -q '10\.'" \
                || info "NOT up: o-hm0 -- load balancers will not be health-checked"
        fi
    fi

    if ceph_do ceph nfs cluster ls 2>/dev/null | grep -q labnfs; then
        wait_for 300 "ganesha serving after restart" bash -c \
            "timeout 5 bash -c '</dev/tcp/$CEPH_SUBNET.11/2049'" \
            || info "NOT serving: ganesha -- check the unit inside ceph-node1"
    fi

    log "object storage and shared filesystem"
    ceph_do ceph orch ls 2>/dev/null | grep -E 'rgw|nfs|mds' | sed 's/^/    /' | tee -a "$LOG"
    ceph_do ceph fs ls 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"

    VM_IP=$(ip -br addr show enp0s1 | awk '{print $3}' | cut -d/ -f1)

    # cephadm deploys Grafana, Prometheus and Alertmanager at bootstrap, and the
    # dashboard shows their graphs as iframes -- which the BROWSER loads, not the
    # dashboard backend. Out of the box those iframes point at https://ceph-node1:3000,
    # a name that resolves only inside the Incus network, so every "Overall
    # Performance" tab renders as an empty grey frame.
    #
    # Proxy devices publish the three ports on the VM, and the URLs must then carry
    # the VM address -- 127.0.0.1 works for s3cfg because that is read inside the VM,
    # but these are resolved on macOS. The address changes on every machine start,
    # which is why this is re-set on every verify run rather than once at bootstrap.
    add_proxy ceph-node1 grafana      3000 "$CEPH_SUBNET.11:3000"
    add_proxy ceph-node1 prometheus   9095 "$CEPH_SUBNET.11:9095"
    add_proxy ceph-node1 alertmanager 9093 "$CEPH_SUBNET.11:9093"
    ceph_do ceph dashboard set-grafana-api-url "https://$VM_IP:3000" >/dev/null || true
    ceph_do ceph dashboard set-grafana-api-ssl-verify false >/dev/null || true
    ceph_do ceph dashboard set-alertmanager-api-host "http://$VM_IP:9093" >/dev/null || true
    ceph_do ceph dashboard set-prometheus-api-host "http://$VM_IP:9095" >/dev/null || true
    info "monitoring URLs point at $VM_IP (grafana 3000, prometheus 9095, alertmanager 9093)"

    # br-ex only exists once Kolla's openvswitch container has created it, which on a
    # first provision is ~15 minutes after boot. lab-brex.service waits 5 minutes and
    # then exits 0 -- silently, reporting success -- so on a fresh build the bridge
    # never gets its address and every floating IP is unreachable: ping and ssh time
    # out against instances that are running perfectly. It only ever appeared to work
    # because a restarted machine already has br-ex in the OVS config.
    #
    # The boot unit is right for restarts. This is what makes a first build correct.
    if ! ip addr show dev br-ex 2>/dev/null | grep -q '172\.24\.4\.1/24'; then
        info "br-ex has no gateway address -- running lab-brex now (expected on a first build)"
        /usr/local/sbin/lab-brex.sh >/dev/null 2>&1 || true
    fi
    ip addr show dev br-ex 2>/dev/null | grep -q '172\.24\.4\.1/24' \
        && info "br-ex 172.24.4.1/24 -- floating IPs routable" \
        || info "NOT routable: br-ex has no 172.24.4.1/24 -- floating IPs will time out"

    write_lab_expose
    exposed=$(/usr/local/sbin/lab-expose --list 2>/dev/null | grep -c 'http://' || true)
    [ "$exposed" -gt 0 ] && {
        info "workloads currently published to the host:"
        /usr/local/sbin/lab-expose --list | sed 's/^/  /' | tee -a "$LOG"
    }

    horizon_pw=$(sudo -u kolla grep '^keystone_admin_password:' /etc/kolla/passwords.yml | awk '{print $2}')
    s3_ak=$(awk -F' = ' '/^access_key/{print $2}' "$SHARED_DIR/s3cfg" 2>/dev/null)

    cat <<EOF | tee -a "$LOG"

=== Reachable from macOS
    Horizon        http://$VM_IP:8080/     admin / $horizon_pw  (domain Default)
    Ceph dashboard https://$VM_IP:8443/    admin / $DASHBOARD_PASSWORD
    S3 (Ceph RGW)  http://$VM_IP:$RGW_VM_PORT/     access key $s3_ak, config in $SHARED_DIR/s3cfg
    NFS export     $VM_IP:/labshare        mount -t nfs4 -o proto=tcp,port=2049
    Grafana        https://$VM_IP:3000/    embedded in the Ceph dashboard; self-signed
    Prometheus     http://$VM_IP:9095/
    Alertmanager   http://$VM_IP:9093/

    The VM address changes on every machine recreate. Re-read it with
    'ip -br addr show enp0s1'. Test the Horizon forward FROM macOS -- the DNAT
    rule matches -i enp0s1, so a local curl to 127.0.0.1:8080 always fails and
    proves nothing.

=== Reaching a workload from a browser on macOS
    Instance floating IPs (172.24.4.x) are NOT reachable from the Mac: they live
    behind br-ex and macOS routes that range to its own LAN gateway instead. This
    publishes one on the VM's address, which macOS already reaches:

        lab-expose 18080 <floating-ip>     then open http://$VM_IP:18080/
        lab-expose --list                  what is published now
        lab-expose --clear                 remove them

    Not persistent -- a machine restart clears it, and floating IPs change between
    exercises anyway, so re-run it rather than expecting it to stick.
EOF
}

# --- Driver ------------------------------------------------------------------

start=0
if [ -n "$FROM" ]; then
    # "from this phase onward" means everything after it is stale too, so clear
    # those checkpoints as well -- otherwise the later phases silently skip.
    found=0
    for i in "${!PHASES[@]}"; do
        [ "${PHASES[$i]}" = "$FROM" ] && { start=$i; found=1; }
        [ "$found" = 1 ] && rm -f "$STATE_DIR/${PHASES[$i]}.done"
    done
    [ "$found" = 1 ] || die "unknown phase: $FROM (see --list)"
fi

if [ -n "$ONLY" ]; then
    printf '%s\n' "${PHASES[@]}" | grep -qx "$ONLY" || die "unknown phase: $ONLY (see --list)"
fi

log "provisioning started (ceph $CEPH_VERSION, kolla $KOLLA_BRANCH), log: $LOG"

# __phase, not p: phase functions run in this same shell and share its globals, so
# a loop variable inside one silently overwrites the driver's. That happened -- a
# `for p in <pools>` in phase_50_ceph left the checkpoint written as nova-vms.done
# and 50-ceph.done never created, so the phase re-ran on every resume.
for __i in "${!PHASES[@]}"; do
    __phase="${PHASES[$__i]}"
    [ -n "$ONLY" ] && [ "$__phase" != "$ONLY" ] && continue
    [ -z "$ONLY" ] && [ "$__i" -lt "$start" ] && continue
    if [ -f "$STATE_DIR/$__phase.done" ] && [ "$__phase" != "$ONLY" ]; then
        info "skip $__phase (done)"; continue
    fi

    log "PHASE $__phase"
    if "phase_${__phase//-/_}"; then
        touch "$STATE_DIR/$__phase.done"
        log "PHASE $__phase complete"
    else
        die "PHASE $__phase failed -- fix, then re-run (it resumes here)"
    fi
done

log "provisioning complete"
