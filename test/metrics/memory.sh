#!/bin/bash
# Memory as macOS reports it. phys_footprint is what Activity Monitor shows and what a
# user must actually have free; ps RSS counts shared and file-backed mappings and reads
# high. Both are recorded, plus the kernel's own running peak.
#
# Usage: OUT=<dir> ./memory.sh
OUT="${OUT:?set OUT to the results directory}"
CSV=$OUT/memory.csv
echo "epoch,ts,stage,vm_footprint_mb,vm_footprint_peak_mb,vm_rss_mb,host_free_mb,swap_used_mb" > "$CSV"
while true; do
    [ -f "$OUT/STATUS" ] && break
    pgrep -f "run-e2e.sh" >/dev/null || { sleep 20; pgrep -f "run-e2e.sh" >/dev/null || break; }
    pid=$(pgrep -f "Virtualization.VirtualMachine" | head -1)
    fp=0; pk=0; rss=0
    if [ -n "$pid" ]; then
        out=$(footprint -p "$pid" 2>/dev/null)
        fp=$(echo "$out" | awk '/phys_footprint:/      {v=$2;u=$3; print (u=="GB")?v*1024:(u=="MB")?v:0; exit}')
        pk=$(echo "$out" | awk '/phys_footprint_peak:/ {v=$2;u=$3; print (u=="GB")?v*1024:(u=="MB")?v:0; exit}')
        rss=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%d",$1/1024}')
    fi
    free=$(vm_stat | awk '/Pages free/{f=$3}/Pages inactive/{i=$3} END{gsub(/\./,"",f);gsub(/\./,"",i); printf "%d",(f+i)*16384/1048576}')
    sw=$(sysctl -n vm.swapusage 2>/dev/null | awk '{gsub(/M/,"",$6); printf "%d",$6}')
    printf '%s,%s,%s,%.0f,%.0f,%s,%s,%s\n' "$(date +%s)" "$(date '+%H:%M:%S')" \
        "$(tr -d ',\n' < "$OUT/STAGE" 2>/dev/null)" "${fp:-0}" "${pk:-0}" "${rss:-0}" "${free:-0}" "${sw:-0}" >> "$CSV"
    sleep 30
done
