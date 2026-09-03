#!/usr/bin/env bash
#
# sync-provision.sh -- push the local 03-provision.sh into the machine. Runs on macOS.
#
# The macOS home directory is not mounted (--home-mount none) and a machine cannot
# bind-mount an arbitrary directory, so this is how an edited provisioning script gets
# in without rebuilding the image or recreating the machine:
#
#     ./sync-provision.sh
#     container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh
#
# Two ways to reach into a machine, and they are not interchangeable:
#
#   by path    container machine run -n m --root -- /usr/local/sbin/x.sh
#              Reliable everywhere, including a backgrounded script with no terminal.
#              This is how you RUN things.
#
#   by stdin   container machine run -n m -i --root -- bash < x.sh
#              Needs -i, and -i needs a controlling terminal -- from a background job
#              it fails with "Inappropriate ioctl for device". Without -i, stdin is
#              ignored and the command silently does nothing. This is how you DELIVER
#              things, from an interactive shell.
#
# Passing a command as arguments does not work at all: `container machine run -n m --
# sh -c 'echo $(id -u)'` produces empty output rather than running the command.

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINE="${MACHINE:-openstack-lab}"
SRC="$LAB_DIR/03-provision.sh"
DEST=/usr/local/sbin/provision-lab.sh

[ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }
bash -n "$SRC" || { echo "ERROR: $SRC has syntax errors, not pushing" >&2; exit 1; }
grep -q '^PROVISION_EOF$' "$SRC" && { echo "ERROR: $SRC contains the heredoc sentinel" >&2; exit 1; }

payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
{
    printf "cat > %s <<'PROVISION_EOF'\n" "$DEST"
    cat "$SRC"
    printf 'PROVISION_EOF\n'
    printf 'chmod 755 %s\n' "$DEST"
    printf 'ln -sf %s /usr/local/bin/provision-lab\n' "$DEST"
    printf 'printf "pushed %%s lines to %s\\n" "$(wc -l < %s)"\n' "$DEST" "$DEST"
} > "$payload"

container machine run -n "$MACHINE" -i --root -- bash < "$payload"
