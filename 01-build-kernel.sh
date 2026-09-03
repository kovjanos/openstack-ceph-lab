#!/usr/bin/env bash
#
# 01-build-kernel.sh -- build the lab kernel. Runs on macOS.
#
# Produces ./vmlinux-arm64: arm64, with device-mapper, KVM, AppArmor, OpenVSwitch,
# iSCSI and the Docker/iptables stack compiled in. Everything is =y, never =m --
# these VMs have no module loading, so a =m option is the same as absent.
#
# The stock apple/containerization kernel has no device-mapper, which makes LVM
# impossible and therefore Ceph impossible: ceph-volume rejects a loop device with
# "Device type is not acceptable", and an LV on top is the only thing it accepts.
#
# On the way out this removes the checkout, the kernel-build image and the BuildKit
# cache, keeping only vmlinux-arm64 and the cached kernel tarball.
#
# Usage:
#   ./01-build-kernel.sh              build, then clean up
#   ./01-build-kernel.sh --keep-build leave the checkout in place for debugging
#   ./01-build-kernel.sh --no-cache   also drop the cached kernel source tarball

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$LAB_DIR/.build/kernel"
CACHE_DIR="$LAB_DIR/.cache"
KERNEL_OUT="$LAB_DIR/vmlinux-arm64"
KERNEL_IMAGE="kernel-build:0.1"
REPO="https://github.com/apple/containerization"
MIN_FREE_GB=20

KEEP_BUILD=0
DROP_CACHE=0
for arg in "$@"; do
    case "$arg" in
        --keep-build) KEEP_BUILD=1 ;;
        --no-cache)   DROP_CACHE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\n=== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

# --- The config block. -------------------------------------------------------
#
# Written between sentinels so re-running replaces it instead of appending a
# seventh copy. The kernel's config parser takes the last occurrence, so a plain
# =y line overrides an earlier "# ... is not set" -- but duplicates accumulate and
# make the file impossible to reason about.
#
# Options with unmet dependencies are dropped SILENTLY by olddefconfig, with no
# error. Every parent needed by something below is therefore listed explicitly:
#   CONFIG_MD                    gates all CONFIG_DM_*
#   CONFIG_SCSI/SCSI_LOWLEVEL    gate the iSCSI stack
#   CONFIG_NETFILTER_XTABLES_LEGACY  gates all ten IP_NF_*/IP6_NF_* options,
#                                even when the IPTABLES parents are set
read -r -d '' LAB_CONFIG <<'CONFIG_EOF' || true
# --- Device-mapper. Without this LVM cannot work and ceph-volume rejects the
# --- loop devices outright. CONFIG_MD is the parent that gates every DM_ option.
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_SNAPSHOT=y
CONFIG_DM_THIN_PROVISIONING=y
CONFIG_DM_MIRROR=y
CONFIG_DM_ZERO=y

# --- Neutron's OVS agent, plus the conntrack/netfilter base it needs.
CONFIG_OPENVSWITCH=y
CONFIG_NF_CONNTRACK=y
CONFIG_NETFILTER_ADVANCED=y

# --- iSCSI. Cinder's LVM/iSCSI paths and iscsid both need this; without it
# --- iscsid.service fails with "can not create NETLINK_ISCSI socket".
CONFIG_SCSI=y
CONFIG_SCSI_LOWLEVEL=y
CONFIG_SCSI_ISCSI_ATTRS=y
CONFIG_ISCSI_TCP=y

# --- NFS client, for mounting the CephFS export from Phase 8.
# --- CONFIG_NFS_V4 alone is not enough: cephadm's ganesha.conf sets
# --- "Minor_Versions = 1, 2", so the server offers ONLY 4.1 and 4.2. A 4.0-only
# --- client gets "mount.nfs4: Protocol not supported" against a gateway that is
# --- running perfectly well.
CONFIG_NFS_FS=y
CONFIG_NFS_V3=y
CONFIG_NFS_V4=y
CONFIG_NFS_V4_1=y
CONFIG_NFS_V4_2=y

# --- ipset. Neutron's security groups create 'hash:net' sets for every group and
# --- the OVS agent matches on them with iptables '-m set'. Without these the agent
# --- dies with "ipset v7.19: Kernel error received: set type not supported", every
# --- port fails to bind, and instances end in
# --- "VirtualInterfaceCreateException: Virtual Interface creation failed" -- which
# --- reads like a Neutron problem and is not.
CONFIG_IP_SET=y
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NETFILTER_XT_SET=y

# --- Module infrastructure. Everything here is still built =y, but Kolla and
# --- Ansible expect the machinery to exist: Ansible's modprobe module reads
# --- /proc/modules, which the kernel only creates with CONFIG_MODULES=y.
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y

# --- AppArmor. Kolla's bootstrap-servers removes a libvirt AppArmor profile and
# --- fails outright if AppArmor is absent. CONFIG_LSM must list apparmor or the
# --- code compiles in but never activates.
CONFIG_SECURITY=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor"

# --- Docker. Kolla runs every OpenStack service as a Docker container.
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
# Three separate gates gate the legacy ip_tables layer, and all three are needed.
# NETFILTER_XTABLES_LEGACY is the global one. The per-family
# IP_NF_IPTABLES_LEGACY / IP6_NF_IPTABLES_LEGACY are the ones that actually decide
# the ten IP_NF_*/IP6_NF_* options below, and they default to =m -- which silently
# demotes every option under them from =y to =m, because kconfig will not build a
# symbol in when its parent is a module. Since this kernel never runs
# 'make modules_install', an =m option is the same as absent.
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
CONFIG_EOF

BEGIN_MARK='# >>> openstack-ceph-lab >>>'
END_MARK='# <<< openstack-ceph-lab <<<'

# --- Preflight ---------------------------------------------------------------
log "Preflight"
command -v container >/dev/null || die "the 'container' CLI is not on PATH"
container system start >/dev/null 2>&1 || true

have=$(free_gb)
echo "free space: ${have} GB"
[ "$have" -ge "$MIN_FREE_GB" ] || die "need at least ${MIN_FREE_GB} GB free, have ${have} GB"

# --- Fetch -------------------------------------------------------------------
log "Fetching containerization"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$CACHE_DIR"
git clone --depth 1 "$REPO" "$BUILD_DIR/containerization"

KDIR="$BUILD_DIR/containerization/kernel"
cfg="$KDIR/config-arm64"
[ -f "$cfg" ] || die "config-arm64 not found -- upstream layout changed"

# Reuse the cached kernel tarball rather than re-downloading ~147 MB each run.
if [ -f "$CACHE_DIR/source.tar.xz" ]; then
    echo "reusing cached kernel source"
    cp "$CACHE_DIR/source.tar.xz" "$KDIR/source.tar.xz"
fi

# --- Patch the config --------------------------------------------------------
log "Patching config-arm64"

# Drop any previous block first, so this is idempotent against an existing tree.
if grep -qF "$BEGIN_MARK" "$cfg"; then
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
fi

{
    printf '%s\n' "$BEGIN_MARK"
    printf '%s\n' "$LAB_CONFIG"
    printf '%s\n' "$END_MARK"
} >> "$cfg"

# The lab block must appear exactly once -- that is what stops the accumulation
# the old by-hand process produced (seven copies of the DM block in one file).
#
# Individual options may legitimately appear twice: the stock config already sets
# CONFIG_IP_NF_IPTABLES=y, and the block sets it again. That is harmless, because
# the parser takes the LAST occurrence. So check the last occurrence, not the count.
n=$(grep -cF "$BEGIN_MARK" "$cfg")
[ "$n" -eq 1 ] || die "lab config block appears $n times, expected exactly 1"

# This only proves the request is in the source config. Whether it SURVIVED
# olddefconfig can only be read from /proc/config.gz in the booted kernel, which is
# what verify-lab.sh checks after 02-build-image.sh creates the machine.
for opt in CONFIG_MD CONFIG_BLK_DEV_DM CONFIG_IP_NF_IPTABLES CONFIG_NETFILTER_XTABLES_LEGACY \
           CONFIG_IP_NF_IPTABLES_LEGACY CONFIG_IP6_NF_IPTABLES_LEGACY \
           CONFIG_SECURITY_APPARMOR CONFIG_SECURITYFS CONFIG_ISCSI_TCP CONFIG_OPENVSWITCH \
           CONFIG_MODULES CONFIG_NFS_V4_1 CONFIG_NFS_V4_2 \
           CONFIG_IP_SET CONFIG_IP_SET_HASH_NET CONFIG_NETFILTER_XT_SET; do
    last=$(grep -E "^(# )?${opt}[= ]" "$cfg" | tail -1)
    [ "$last" = "${opt}=y" ] || die "$opt resolves to '${last:-<absent>}', expected ${opt}=y"
done
echo "config patched: block present once, all options resolve to =y"

# --- Build -------------------------------------------------------------------
log "Building (a few minutes)"
make -C "$KDIR" TARGET_ARCH=arm64

built="$KDIR/vmlinux-arm64"
[ -f "$built" ] || die "build produced no vmlinux-arm64"

# make does nothing silently if it considers the target up to date. A stale
# artifact is worse than a failure, because it boots and behaves like the old one.
if [ -n "$(find "$built" -mmin +60 2>/dev/null)" ]; then
    die "vmlinux-arm64 is older than an hour -- make treated it as up to date"
fi

size=$(stat -f %z "$built")
[ "$size" -gt 20000000 ] || die "vmlinux-arm64 is only $size bytes, expected >20 MB"

cp -L "$built" "$KERNEL_OUT"
[ -f "$KDIR/source.tar.xz" ] && cp "$KDIR/source.tar.xz" "$CACHE_DIR/source.tar.xz"

log "Built $(basename "$KERNEL_OUT") -- $(du -h "$KERNEL_OUT" | cut -f1)"

# --- Clean up ----------------------------------------------------------------
# Keep the kernel and the cached tarball. Everything else is build residue: the
# checkout, the build image, and the BuildKit cache, which is what grew to 42 GB
# over repeated builds.
if [ "$KEEP_BUILD" -eq 1 ]; then
    log "Skipping cleanup (--keep-build); checkout at $BUILD_DIR"
else
    log "Cleaning up"
    rm -rf "$BUILD_DIR"
    [ "$DROP_CACHE" -eq 1 ] && rm -rf "$CACHE_DIR"
    container image rm "$KERNEL_IMAGE" >/dev/null 2>&1 || true
    container builder stop  >/dev/null 2>&1 || true
    container builder delete --force >/dev/null 2>&1 || true
    # -a rather than dangling-only: this also drops ubuntu:focal, the base the
    # kernel-build image was built from. Safe here because the artifact is a file,
    # not an image -- 02-build-image.sh must NOT use -a, or it deletes its own.
    container image prune -a >/dev/null 2>&1 || true
    echo "removed checkout, $KERNEL_IMAGE, its base image and the BuildKit cache"
fi

log "Done. free space: $(free_gb) GB"
echo "kernel: $KERNEL_OUT"
echo "next:   ./02-build-image.sh"
