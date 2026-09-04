#!/usr/bin/env bash
#
# 02-build-image.sh -- build the machine image and create the VM. Runs on macOS.
#
# Produces the image local/ubuntu-machine:latest and a running machine named
# openstack-lab, ready for 03-provision.sh.
#
# Everything the lab needs at boot is baked into the image, because a unit written
# by hand at runtime is not reproducible and the previous machine lost its whole
# network setup (kolla0, veth-ext, the Horizon DNAT) on its first restart -- the
# running image simply had no unit for it.
#
# The machine is created with no home directory mounted (--home-mount none), so
# 03-provision.sh and verify-lab.sh are baked into the image. To iterate on the
# provisioning script without rebuilding, push it in with ./sync-provision.sh and
# run it by path.
#
# On the way out this removes the build context, the ubuntu base image and the
# BuildKit cache, keeping only local/ubuntu-machine:latest.
#
# Usage:
#   ./02-build-image.sh                 build image, create machine, clean up
#   ./02-build-image.sh --no-machine    build the image only
#   ./02-build-image.sh --keep-build    leave the build context for debugging

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$LAB_DIR/.build/image"
KERNEL="$LAB_DIR/vmlinux-arm64"
PROVISION="$LAB_DIR/03-provision.sh"
IMAGE="local/ubuntu-machine:latest"
MACHINE="openstack-lab"

# Ceph must be identical here, in the node base image, and in the cephadm
# bootstrap. 20.2.3+ mints type-2 cephx keys and upstream published no noble
# packages for them, so a 20.2.4 cluster has no usable client on Ubuntu 24.04.
# Baked into /etc/openstack-lab/lab.env so 03-provision.sh reads the same value.
CEPH_VERSION="20.2.2"

# Machine size. Override from the environment, e.g.
#     MACHINE_MEMORY=32G ./02-build-image.sh
#
#   24G  works, but tight -- measured peak with the load balancer running was
#        19.9 GB, leaving 4.2 GB. Fine on its own, thin if anything else is going on
#   26G  default          -- the same lab with headroom that is not marginal
#   28G  comfortable      -- room for 4-6 small guests alongside the control plane
#   32G+ on a 48 GB Mac, if you want to run several workloads at once
#
# 24G is still a supported size: build with ENABLE_NETWORK_LOADBALANCER=no and the
# four Octavia containers (1.4 GB) and two amphorae (2 GB) are never created.
#
# Below 24G the Kolla control plane and the three Ceph nodes leave too little for
# any guest to boot. Leave the Mac at least 12 GB for itself.
MACHINE_CPUS="${MACHINE_CPUS:-8}"
MACHINE_MEMORY="${MACHINE_MEMORY:-26G}"
MIN_FREE_GB=60

MAKE_MACHINE=1
KEEP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --no-machine) MAKE_MACHINE=0 ;;
        --keep-build) KEEP_BUILD=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\n=== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

# --- Preflight ---------------------------------------------------------------
log "Preflight"
command -v container >/dev/null || die "the 'container' CLI is not on PATH"
container system start >/dev/null 2>&1 || true

[ -f "$KERNEL" ]    || die "$KERNEL not found -- run ./01-build-kernel.sh first"
[ -f "$PROVISION" ] || die "$PROVISION not found"

have=$(free_gb)
echo "free space: ${have} GB"
[ "$have" -ge "$MIN_FREE_GB" ] || die "need at least ${MIN_FREE_GB} GB free, have ${have} GB"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Helper scripts baked into the image -------------------------------------

cat > "$BUILD_DIR/fake-modules-builtin.sh" <<'SCRIPT'
#!/bin/sh
# Kolla calls modprobe for ip_vs, br_netfilter and openvswitch. All three are
# compiled in (=y), but Apple's kernel build never runs `make modules_install`,
# so /lib/modules/<version> does not exist and modprobe fails even for built-ins.
# CONFIG_MODULES=y gives the kernel /proc/modules; this gives modprobe a directory.
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

cat > "$BUILD_DIR/kolla-net-setup.sh" <<'SCRIPT'
#!/bin/sh
# Private control-plane interface, Neutron's external interface, and the Horizon
# port forward. Idempotent -- safe to re-run.
#
# Nothing here references the VM's own vmnet address, which changes on every
# machine recreate: the DNAT rule matches by interface name (enp0s1) and targets a
# fixed private address, so only the URL you type changes.
#
# enp0s1 cannot be used for the control plane. It sits on macOS's vmnet-shared
# network, which does anti-spoofing: it carries traffic only from the one address
# it handed out by DHCP, so keepalived can never claim a VIP there.
set -e

# kolla0 holds 10.10.10.1 (network_interface). The VIP 10.10.10.10 stays free for
# keepalived. A dummy interface would be cleaner but CONFIG_DUMMY is not in this
# kernel, so a veth pair stands in.
if ! ip link show kolla0 >/dev/null 2>&1; then
    ip link add kolla0 type veth peer name kolla0-peer
    ip addr add 10.10.10.1/24 dev kolla0
    ip link set kolla0 up
    ip link set kolla0-peer up
fi

# veth-ext is neutron_external_interface: up, with NO address.
if ! ip link show veth-ext >/dev/null 2>&1; then
    ip link add veth-ext type veth peer name veth-ext-br
    ip link set veth-ext up
    ip link set veth-ext-br up
fi

# The hostname must resolve UNIQUELY to the kolla0 address.
#
# RabbitMQ clusters on hostnames, not addresses, and Kolla deployed it as
# rabbit@<hostname> expecting that to be 10.10.10.1. /etc/hosts is regenerated on
# every boot carrying the vmnet address instead, which changes on every machine
# recreate -- so after a restart rabbitmq crash-loops with
#   {epmd_error,"<hostname>",address}
# taking every nova and neutron agent down with it, and 'kolla-ansible prechecks'
# fails with "Hostname has to resolve uniquely to the IP address of api_interface".
#
# Delete every existing entry for the name rather than just the vmnet one: two
# entries fail the precheck regardless of order.
H=$(hostname)
sed -i -E "/^[0-9.]+[[:space:]]+${H}([[:space:]]|\$)/d" /etc/hosts
echo "10.10.10.1 ${H}" >> /etc/hosts

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

cat > "$BUILD_DIR/lab-brex.sh" <<'SCRIPT'
#!/bin/sh
# Give br-ex the floating-IP gateway address.
#
# Neutron's external interface (veth-ext) deliberately carries no address, so the
# VM has no route to the floating range and every floating IP is unreachable --
# ping and ssh just time out against an instance that is running perfectly well.
# Putting the subnet's gateway address on br-ex makes the VM the router for it.
#
# br-ex is created by Kolla's openvswitch container, so this runs after docker and
# waits for the bridge rather than assuming it exists.
set -e
for i in $(seq 60); do
    ip link show br-ex >/dev/null 2>&1 && break
    sleep 5
done
ip link show br-ex >/dev/null 2>&1 || exit 0
ip addr show dev br-ex | grep -q '172\.24\.4\.1/24' || ip addr add 172.24.4.1/24 dev br-ex
ip link set br-ex up

# NAT the floating range out through the VM's own uplink, so instances can reach
# the internet. Without this a guest cannot even resolve DNS -- wget reports
# "bad address" -- and anything that installs packages fails.
#
# ICMP still will not work: the macOS vmnet path filters it. Test guest
# connectivity with wget or curl, never with ping.
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s 172.24.4.0/24 -o enp0s1 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 172.24.4.0/24 -o enp0s1 -j MASQUERADE
SCRIPT

cat > "$BUILD_DIR/ceph-lab-assemble.sh" <<'SCRIPT'
#!/bin/sh
# Stage 1 -- runs before incus.service. Reattaches the loop devices and activates
# the volume groups. Does NOT touch incus: the daemon isn't running yet and the
# client would block forever waiting for a socket systemd hasn't created.
set -e

for f in /var/lib/ceph-disks/osd*.img; do
  [ -e "$f" ] || continue
  # -j guards against attaching the same image twice, which shows up later as
  # "Not using device /dev/loopN for PV".
  losetup -j "$f" | grep -q . || losetup --find "$f"
done

vgchange -ay
SCRIPT

cat > "$BUILD_DIR/ceph-lab-remap.sh" <<'SCRIPT'
#!/bin/sh
# Stage 3 -- runs after incus.service.
#
# dm minor numbers are assigned in vgchange activation order and shuffle between
# boots, so the Incus device definitions -- pinned by number in BOTH path= and
# source= -- must be corrected before the containers start. Setting only source=
# leaves the node at the old name with the new content, which surfaces as a
# dangling symlink after vgmknodes.
#
# Containers have boot.autostart=false so Incus cannot bring them up on stale
# numbers; this script starts them once the mapping is right.
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

cp "$PROVISION" "$BUILD_DIR/provision-lab.sh"

cat > "$BUILD_DIR/verify-lab.sh" <<'VERIFY'
#!/bin/bash
# Health check for the machine image: kernel options, baked-in units, lab network.
fail=0
# kolla-net-setup is ordered After=network-online.target, so give the boot a
# moment to settle before asserting on the interfaces it creates.
for _ in $(seq 30); do
    systemctl is-active kolla-net-setup >/dev/null 2>&1 && break
    sleep 2
done
echo "kernel:  $(uname -r)"
for d in /dev/mapper/control /dev/kvm; do
    [ -e "$d" ] && echo "ok    $d" || { echo "MISSING $d"; fail=1; }
done
# Every option asked for in 01-build-kernel.sh must have survived olddefconfig.
for o in CONFIG_KVM CONFIG_BLK_DEV_DM CONFIG_SCSI CONFIG_ISCSI_TCP \
         CONFIG_SCSI_ISCSI_ATTRS CONFIG_OPENVSWITCH CONFIG_BRIDGE \
         CONFIG_NF_TABLES CONFIG_OVERLAY_FS CONFIG_SECURITY_APPARMOR \
         CONFIG_SECURITYFS CONFIG_MODULES \
         CONFIG_IP_NF_IPTABLES_LEGACY CONFIG_IP_NF_FILTER CONFIG_IP_NF_NAT \
         CONFIG_NFS_V4_1 CONFIG_NFS_V4_2; do
    got=$(zcat /proc/config.gz | grep -E "^(# )?${o}[= ]" | tail -1)
    case "$got" in
        "${o}=y") echo "ok    ${o}=y" ;;
        # =m is not a partial success: this kernel never runs modules_install, so
        # there is nothing to load and the option is effectively absent.
        "${o}=m") echo "MODULE  ${o}=m -- unloadable here, a parent is =m"; fail=1 ;;
        *)        echo "DROPPED ${o} -- unmet dependency, check its parent"; fail=1 ;;
    esac
done
# What actually has to work, regardless of which backend provides it.
iptables -t nat -L -n  >/dev/null 2>&1 && echo "ok    iptables nat usable" \
    || { echo "BAD   iptables nat"; fail=1; }
[ -d /sys/kernel/security/apparmor ] && echo "ok    securityfs mounted" \
    || { echo "MISSING /sys/kernel/security/apparmor"; fail=1; }
for u in securityfs-mount run-shared fake-modules-builtin kolla-net-setup \
         ceph-lab-assemble ceph-lab-remap hold-osd1 hold-osd2 hold-osd3; do
    s=$(systemctl is-enabled "$u" 2>&1 || true)
    [ "$s" = enabled ] && echo "ok    $u enabled" || { echo "BAD   $u: $s"; fail=1; }
done
ip -br addr show kolla0 2>/dev/null | grep -q 10.10.10.1 \
    && echo "ok    kolla0 has 10.10.10.1" || { echo "BAD   kolla0"; fail=1; }
ip -br link show veth-ext >/dev/null 2>&1 \
    && echo "ok    veth-ext present" || { echo "BAD   veth-ext"; fail=1; }
ceph --version 2>/dev/null | head -1
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit "$fail"
VERIFY


# --- Dockerfile --------------------------------------------------------------

cat > "$BUILD_DIR/Dockerfile" <<DOCKERFILE
FROM ubuntu:24.04
ENV container container

# iptables is explicit: kolla-net-setup.sh needs it for the Horizon DNAT and it is
# otherwise only pulled in as somebody else's dependency.
# isc-dhcp-client is here for Octavia: Kolla's octavia-interface.service runs a
# hard-coded /sbin/dhclient against the o-hm0 port, and Ubuntu 24.04 stopped
# shipping it. The image clears /var/lib/apt/lists at the end, so a runtime
# 'apt-get install' cannot find it without an update first -- baking it in is
# both faster and one less thing to fail during provisioning.
RUN apt-get update && apt-get install -y \\
    dbus systemd openssh-server net-tools iproute2 iputils-ping \\
    qemu-system-arm qemu-utils libvirt-daemon-system \\
    bridge-utils nftables iptables chrony lvm2 incus \\
    python3-yaml python3-jinja2 python3-requests \\
    curl wget git vim-tiny man sudo cpu-checker uuid-runtime s3cmd \\
    gdisk parted kpartx dosfstools e2fsprogs debootstrap nfs-common \\
    isc-dhcp-client \\
    python3-dev python3-venv python3-apt libffi-dev libssl-dev libdbus-glib-1-dev \\
    kmod && \\
    apt-get clean && rm -rf /var/lib/apt/lists/*
# --- wget has no read timeout by default, so a mirror that accepts a connection and
# --- then goes silent hangs forever. That is not hypothetical: an amphora build here
# --- sat on one stalled fetch from ports.ubuntu.com for 13 minutes with a live,
# --- ESTABLISHED, empty-queue socket while the same URL fetched fine in 0.3s beside
# --- it. debootstrap drives wget, so the setting has to be global.
RUN printf 'timeout = 30\ntries = 3\nwaitretry = 5\n' >> /etc/wgetrc

RUN yes | unminimize || true
RUN >/etc/machine-id
RUN >/var/lib/dbus/machine-id
RUN systemctl set-default multi-user.target
RUN systemctl mask dev-hugepages.mount sys-fs-fuse-connections.mount \\
      systemd-update-utmp.service systemd-tmpfiles-setup.service console-getty.service
RUN systemctl disable networkd-dispatcher.service
# Ubuntu's OCI image ships a policy-rc.d stub that blocks every daemon you install.
# Leaving it in place makes 'incus admin init' fail with "Failed to connect to
# local daemon" after an install that printed "policy-rc.d returned 101".
RUN rm -f /usr/sbin/policy-rc.d
RUN echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-lab.conf

# Shared settings, so 03-provision.sh uses the same Ceph version this image pinned.
RUN mkdir -p /etc/openstack-lab && \\
    printf 'CEPH_VERSION=%s\\n' '$CEPH_VERSION' > /etc/openstack-lab/lab.env

# --- securityfs is never mounted in this image. systemd mounts API filesystems
# --- only when it is PID 1 from the start; here the machine boots via
# --- init=/sbin/vminitd and hands off later, so the mount never happens. Without
# --- it AppArmor is active in the kernel but /sys/kernel/security/apparmor is
# --- absent, and Kolla's bootstrap-servers fails with "apparmor_parser ... unable
# --- to find a suitable fs in /proc/mounts".
# ---
# --- It must be a .service, NOT an fstab line or a .mount unit: systemd refuses
# --- both for API filesystems with "Cannot create mount unit for API file system
# --- /sys/kernel/security. Refusing."
RUN printf '%s\\n' \\
  '[Unit]' \\
  'Description=Mount securityfs (systemd refuses .mount units for API filesystems)' \\
  'DefaultDependencies=no' \\
  'Before=sysinit.target' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  "ExecStart=/bin/sh -c 'mountpoint -q /sys/kernel/security || mount -t securityfs securityfs /sys/kernel/security'" \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=sysinit.target' \\
  > /etc/systemd/system/securityfs-mount.service

# --- /run must have shared mount propagation. Kolla's containers mount
# --- /run:/run:shared; a normal systemd host sets this at boot, this minimal image
# --- leaves /run private and Docker refuses to start them with "path /run is
# --- mounted on /run but it is not a shared mount".
RUN printf '%s\\n' \\
  '[Unit]' \\
  'Description=Make /run a shared mount for Kolla containers' \\
  'DefaultDependencies=no' \\
  'Before=docker.service' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  'ExecStart=/bin/mount --make-shared /run' \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/run-shared.service

COPY fake-modules-builtin.sh /usr/local/sbin/fake-modules-builtin.sh
RUN chmod 755 /usr/local/sbin/fake-modules-builtin.sh
RUN printf '%s\\n' \\
  '[Unit]' \\
  'Description=Create /lib/modules so modprobe resolves built-in modules' \\
  'DefaultDependencies=no' \\
  'Before=docker.service' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  'ExecStart=/usr/local/sbin/fake-modules-builtin.sh' \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/fake-modules-builtin.service

# --- Kolla's bootstrap-servers REMOVES the libvirt AppArmor profile and fails if
# --- it was never loaded ("apparmor_parser: Unable to remove libvirtd. Profile
# --- doesn't exist"). A normal Ubuntu host loads it at boot; this image doesn't.
RUN printf '%s\\n' \\
  '[Unit]' \\
  'Description=Load libvirt AppArmor profile so Kolla can remove it' \\
  'After=apparmor.service' \\
  'ConditionPathExists=/etc/apparmor.d/usr.sbin.libvirtd' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  'ExecStart=/sbin/apparmor_parser -r /etc/apparmor.d/usr.sbin.libvirtd' \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/libvirt-apparmor-load.service

COPY kolla-net-setup.sh /usr/local/sbin/kolla-net-setup.sh
RUN chmod 755 /usr/local/sbin/kolla-net-setup.sh
RUN printf '%s\\n' \\
  '[Unit]' \\
  'Description=Kolla lab network interfaces and port forwards' \\
  'After=network-online.target' \\
  'Wants=network-online.target' \\
  'Before=docker.service' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  'ExecStart=/usr/local/sbin/kolla-net-setup.sh' \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/kolla-net-setup.service

# --- Under Kolla, libvirt runs in a container and needs exclusive use of
# --- /var/run/libvirt/libvirt-sock. The host copy (installed above for the
# --- nested-KVM work) must not run, or prechecks fail on "Checking that host
# --- libvirt is not running". Disable the sockets too -- socket activation
# --- restarts the daemon otherwise.
RUN systemctl disable libvirtd.service libvirtd.socket libvirtd-ro.socket \\
      libvirtd-admin.socket virtlogd-admin.socket virtlockd-admin.socket || true
# --- virtlogd and virtlockd must be MASKED, not merely disabled. libvirtd inside
# --- nova_libvirt has stdio_handler = "logd", so it asks virtlogd to create each
# --- instance's console.log. /run is a shared mount (run-shared.service), so both
# --- the host and container daemons see the same /run/libvirt/virtlogd-sock -- and
# --- if the host one holds it, libvirtd talks to a process whose mount namespace
# --- has no /var/lib/nova. Every instance then fails to build with
# --- "Unable to open file: /var/lib/nova/instances/<uuid>/console.log". Disabling
# --- alone does not stop them being socket-activated or already running.
RUN systemctl mask virtlogd.service virtlogd.socket \\
      virtlockd.service virtlockd.socket || true

# --- Ceph host client. Nova and Cinder link librbd in-process, so the host client
# --- has to work; a container-based rbd is not a substitute. Ubuntu's own
# --- ceph-common is 19.2.3 and cannot parse the cephx keys a Tentacle cluster
# --- mints, so it comes from the pinned upstream repo instead.
# ---
# --- ceph-fuse is here for the same reason, not for convenience. Exercise 22 needs
# --- it because the VM kernel has no CephFS driver, and installing it later would
# --- mean an 'apt-get update' inside a machine whose whole point is a pinned
# --- $CEPH_VERSION -- the one thing most likely to drag in a mismatched client.
# --- Both come from the same pinned repo in the same layer, so they cannot diverge.
RUN curl -fsSL https://download.ceph.com/keys/release.gpg \\
      -o /etc/apt/trusted.gpg.d/ceph.gpg && \\
    echo 'deb https://download.ceph.com/debian-$CEPH_VERSION/ noble main' \\
      > /etc/apt/sources.list.d/ceph.list && \\
    apt-get update && apt-get install -y ceph-common ceph-fuse && \\
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- The machine's root is a sparse file on the Mac. It grows as the lab writes and
# --- never shrinks on its own: Apple's runtime mounts / before systemd so there is no
# --- fstab entry to add 'discard' to, and Ubuntu's fstrim.timer only fires weekly --
# --- far too late for a lab built and torn down the same day. A finished lab leaves
# --- ~9 GB of freed blocks still charged to the host image; 'lab-trim' hands them back.
# ---
# --- Deliberately a batch trim, not a 'discard' mount option. Mounting / with discard
# --- was tried and makes every free a synchronous discard; a machine stop afterwards
# --- hung for over seven hours instead of the usual five minutes.
RUN printf '%s\n' \
    '#!/bin/sh' \
    '# Return blocks freed inside the VM to the disk image on the Mac.' \
    'echo "guest usage before:"' \
    'df -h /' \
    'fstrim -v /' \
    'echo "guest usage after:"' \
    'df -h /' \
    > /usr/local/sbin/lab-trim && chmod 755 /usr/local/sbin/lab-trim && \
    ln -sf /usr/local/sbin/lab-trim /usr/local/bin/lab-trim

# --- Storage units, in three stages. A single unit deadlocks: it would have to run
# --- before Incus (so the LVs exist) and after Incus (so 'incus config device set'
# --- has a daemon to talk to).
COPY lab-brex.sh /usr/local/sbin/lab-brex.sh
RUN chmod 755 /usr/local/sbin/lab-brex.sh
RUN printf '%s\n' \\
  '[Unit]' \\
  'Description=Floating-IP gateway address on br-ex' \\
  'After=docker.service' \\
  'Wants=docker.service' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  'ExecStart=/usr/local/sbin/lab-brex.sh' \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/lab-brex.service

COPY ceph-lab-assemble.sh /usr/local/sbin/ceph-lab-assemble.sh
COPY ceph-lab-remap.sh    /usr/local/sbin/ceph-lab-remap.sh
RUN chmod 755 /usr/local/sbin/ceph-lab-assemble.sh /usr/local/sbin/ceph-lab-remap.sh

# Stage 1: before Incus -- loop devices and volume groups.
RUN printf '%s\\n' \\
  '[Unit]' \\
  'Description=Assemble Ceph lab storage (loop devices and volume groups)' \\
  'After=systemd-udev-settle.service' \\
  'Before=incus.service' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  'ExecStart=/usr/local/sbin/ceph-lab-assemble.sh' \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/ceph-lab-assemble.service

# Stage 2: one long-running hold per LV, each its own service so it does not die
# with the oneshot that spawned it. Stopping a container otherwise releases the
# last reference, device-mapper tears the mapping down, and the LV is gone when
# the container restarts.
RUN for n in 1 2 3; do printf '%s\\n' \\
  '[Unit]' \\
  "Description=Hold ceph-vg\${n}/osd\${n} open" \\
  'After=ceph-lab-assemble.service' \\
  'Requires=ceph-lab-assemble.service' \\
  'Before=incus.service' \\
  '' \\
  '[Service]' \\
  "ExecStart=/bin/sh -c 'exec sleep infinity < /dev/ceph-vg\${n}/osd\${n}'" \\
  'Restart=always' \\
  'RestartSec=5' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/hold-osd\${n}.service; done

# Stage 3: after Incus -- fix device mappings, then start the containers.
RUN printf '%s\\n' \\
  '[Unit]' \\
  'Description=Repair Incus device mappings and start Ceph nodes' \\
  'After=incus.service hold-osd1.service hold-osd2.service hold-osd3.service' \\
  'Requires=incus.service' \\
  '' \\
  '[Service]' \\
  'Type=oneshot' \\
  'ExecStart=/usr/local/sbin/ceph-lab-remap.sh' \\
  'RemainAfterExit=yes' \\
  '' \\
  '[Install]' \\
  'WantedBy=multi-user.target' \\
  > /etc/systemd/system/ceph-lab-remap.service

RUN systemctl enable lab-brex.service securityfs-mount.service run-shared.service \\
      fake-modules-builtin.service libvirt-apparmor-load.service \\
      kolla-net-setup.service ceph-lab-assemble.service ceph-lab-remap.service \\
      hold-osd1.service hold-osd2.service hold-osd3.service

# --- The provisioning script, so it is present after login with no mount.
COPY provision-lab.sh /usr/local/sbin/provision-lab.sh
COPY verify-lab.sh    /usr/local/sbin/verify-lab.sh
RUN chmod 755 /usr/local/sbin/provision-lab.sh /usr/local/sbin/verify-lab.sh && \\
    ln -sf /usr/local/sbin/provision-lab.sh /usr/local/bin/provision-lab && \\
    ln -sf /usr/local/sbin/verify-lab.sh /usr/local/bin/verify-lab
DOCKERFILE

# --- Build -------------------------------------------------------------------
log "Building $IMAGE"
container build -t "$IMAGE" "$BUILD_DIR"

container image inspect "$IMAGE" >/dev/null 2>&1 || die "build produced no $IMAGE"
log "Built $IMAGE"

# --- Clean up the build residue ----------------------------------------------
# Keep the image. Drop the context, the ubuntu base layer and the BuildKit cache.
if [ "$KEEP_BUILD" -eq 1 ]; then
    log "Skipping cleanup (--keep-build); context at $BUILD_DIR"
else
    log "Cleaning up build residue"
    rm -rf "$BUILD_DIR"
    container image rm ubuntu:24.04 >/dev/null 2>&1 || true
    container builder stop  >/dev/null 2>&1 || true
    container builder delete --force >/dev/null 2>&1 || true
    container image prune >/dev/null 2>&1 || true
    echo "removed build context, ubuntu:24.04 and the BuildKit cache"
fi

# --- Create the machine ------------------------------------------------------
if [ "$MAKE_MACHINE" -eq 0 ]; then
    log "Done (--no-machine). free space: $(free_gb) GB"
    exit 0
fi

log "Creating machine $MACHINE"
if container machine inspect "$MACHINE" >/dev/null 2>&1; then
    echo "$MACHINE exists -- stopping and deleting it"
    container machine stop "$MACHINE" >/dev/null 2>&1 || true
    sleep 5
    container machine delete "$MACHINE" >/dev/null 2>&1 || true
fi

# --home-mount none: the macOS home directory is NOT exposed to the VM. The
# provisioning script is baked into the image, and iteration goes over stdin.
container machine create \
    --virtualization \
    --kernel "$KERNEL" \
    --name "$MACHINE" \
    --cpus "$MACHINE_CPUS" \
    --memory "$MACHINE_MEMORY" \
    --home-mount none \
    --set-default \
    "$IMAGE"

log "Verifying the machine"
# Invoke by path, not over stdin. 'container machine run -i' needs a controlling
# terminal and fails with "Inappropriate ioctl for device" from a background job,
# and without -i stdin is ignored entirely -- so a stdin-fed check silently passes
# by doing nothing. verify-lab.sh is baked into the image for exactly this reason.
# 'container machine create' returns before the machine can accept an exec, and the
# first attempt fails with "Operation not supported by device" rather than anything
# that reads like "not ready yet". Retry rather than treating it as a real failure.
verified=0
for attempt in 1 2 3 4 5 6; do
    if container machine run -n "$MACHINE" --root -- /usr/local/sbin/verify-lab.sh; then
        verified=1; break
    fi
    echo "machine not ready yet (attempt $attempt), retrying in 10s"
    sleep 10
done
[ "$verified" -eq 1 ] || die "machine verification failed"

log "Done. free space: $(free_gb) GB"
container machine ls
cat <<EOF

next: provision the lab (several hours, mostly Kolla image pulls)

  run it:
      container machine run -n $MACHINE --root -- /usr/local/sbin/provision-lab.sh

  or from inside the machine:
      container machine run -n $MACHINE
      sudo provision-lab

  after editing 03-provision.sh, push it in without rebuilding the image:
      ./sync-provision.sh
EOF
exit 0
