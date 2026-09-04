#!/bin/bash
# Logical view, every 60s: what Ceph believes it uses, what the guest filesystem
# believes, and the OSD files' declared size against their real one. Pairs with
# disk.sh by epoch to show allocated-vs-used at every point.
#
# Usage: OUT=<dir> MACHINE=<name> ./ceph.sh
OUT="${OUT:?set OUT to the results directory}"
MACHINE="${MACHINE:-openstack-lab}"
CSV=$OUT/ceph.csv
cat > /tmp/.lab-ceph-probe <<'INNER'
#!/bin/bash
tomb() { awk -v v="$1" -v u="$2" 'BEGIN{m=(u=="TiB")?1048576:(u=="GiB")?1024:(u=="MiB")?1:(u=="KiB")?0.001:0; printf "%d", v*m}'; }
line=$(incus exec ceph-node1 -- cephadm shell -- ceph df 2>/dev/null | awk '/^ *TOTAL/{print}')
if [ -n "$line" ]; then
  set -- $line
  raw_total=$(tomb "$2" "$3"); raw_used=$(tomb "$6" "$7"); pct="${10:-0}"
  stored=$(incus exec ceph-node1 -- cephadm shell -- ceph df 2>/dev/null | awk '
     /^---|^ *$|^ *TOTAL|^POOL |^CLASS|^hdd /{next} NF>=5{v=$4;u=$5;
       m=(u=="TiB")?1048576:(u=="GiB")?1024:(u=="MiB")?1:(u=="KiB")?0.001:0; s+=v*m} END{printf "%d", s}')
else raw_total=0; raw_used=0; pct=0; stored=0; fi
gdf=$(df -m / | awk 'NR==2{print $3}')
gmem=$(free -m | awk '/Mem:/{print $3}')
gavail=$(free -m | awk '/Mem:/{print $7}')
app=$(ls -l /var/lib/ceph-disks/*.img 2>/dev/null | awk '{s+=$5} END{printf "%d", s/1048576}')
act=$(du -cm /var/lib/ceph-disks/ 2>/dev/null | tail -1 | awk '{print $1}')
echo "${raw_total:-0},${raw_used:-0},${pct:-0},${stored:-0},${gdf:-0},${app:-0},${act:-0},${gmem:-0},${gavail:-0}"
INNER
echo "epoch,ts,ceph_raw_total_mb,ceph_raw_used_mb,ceph_pct,ceph_stored_mb,guest_used_mb,osd_apparent_mb,osd_actual_mb,guest_mem_used_mb,guest_mem_avail_mb" > "$CSV"
while true; do
    [ -f "$OUT/STATUS" ] && break
    pgrep -f "run-e2e.sh" >/dev/null || { sleep 20; pgrep -f "run-e2e.sh" >/dev/null || break; }
    v=$(container machine run -n "$MACHINE" -i --root -- \
          bash -c 'cat > /tmp/probe && chmod +x /tmp/probe && /tmp/probe' < /tmp/.lab-ceph-probe 2>/dev/null | tail -1 | tr -d '\r')
    case "$v" in *,*,*,*,*,*,*,*,*) : ;; *) v="0,0,0,0,0,0,0,0,0" ;; esac
    printf '%s,%s,%s\n' "$(date +%s)" "$(date '+%H:%M:%S')" "$v" >> "$CSV"
    sleep 60
done
