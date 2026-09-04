#!/bin/bash
# Host-side disk sampler. Every 30s: what macOS has actually allocated, what the VM's
# disk image holds, and what the OSD backing files occupy. Epoch is recorded directly so
# nothing downstream has to reconstruct it from a clock that may cross midnight.
#
# Usage: OUT=<dir> MACHINE=<name> ./disk.sh
OUT="${OUT:?set OUT to the results directory}"
MACHINE="${MACHINE:-openstack-lab}"
APP="${CONTAINER_APPROOT:-$HOME/Library/Application Support/com.apple.container}"
ROOTFS="$APP/plugin-state/machine-apiserver/machines/$MACHINE/rootfs.ext4"
CSV=$OUT/disk.csv
echo "epoch,ts,stage,disk_avail_mb,store_mb,rootfs_mb,osd_img_mb" > "$CSV"
i=0; store=0; osd=0
while true; do
    [ -f "$OUT/STATUS" ] && break
    pgrep -f "run-e2e.sh" >/dev/null || { sleep 20; pgrep -f "run-e2e.sh" >/dev/null || break; }
    stage=$(tr -d ',\n' < "$OUT/STAGE" 2>/dev/null)
    avail=$(df -m /System/Volumes/Data | awk 'NR==2{print $4}')
    rootfs=$(du -m "$ROOTFS" 2>/dev/null | awk '{print $1}'); : "${rootfs:=0}"
    # du over the whole store is slow; every 5th tick is enough resolution
    if [ $((i % 5)) -eq 0 ]; then
        store=$(du -sm "$APP" 2>/dev/null | awk '{print $1}'); : "${store:=0}"
        osd=$(container machine run -n "$MACHINE" --root -- \
              du -cm /var/lib/ceph-disks/ 2>/dev/null | tail -1 | awk '{print $1}'); : "${osd:=0}"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$(date '+%H:%M:%S')" \
        "${stage:-?}" "$avail" "$store" "$rootfs" "$osd" >> "$CSV"
    i=$((i+1)); sleep 30
done
