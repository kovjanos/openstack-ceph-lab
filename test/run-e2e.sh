#!/bin/bash
# End-to-end verification: tear the lab down, rebuild it from the kernel up, then run
# all 29 exercises, recording disk and memory at every step.
#
#   ./test/run-e2e.sh                 full run
#   OSD_SIZE=7G ./test/run-e2e.sh     override a provisioning knob
#   SKIP_BUILD=1 ./test/run-e2e.sh    exercises only, against the lab already running
#
# Resuming after a failure, so an expensive stage is not repeated:
#   SKIP_TEARDOWN=1 SKIP_KERNEL=1 ./test/run-e2e.sh    keep vmlinux-arm64, rebuild image
#   SKIP_TEARDOWN=1 SKIP_KERNEL=1 SKIP_IMAGE=1 ./test/run-e2e.sh   provision onwards
#
# Results land in test/results/<timestamp>/. Nothing is written outside that directory
# except the lab itself.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
MACHINE="${MACHINE:-openstack-lab}"
OUT="${OUT:-$HERE/results/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
LOG=$OUT/run.log
export OUT MACHINE
: > "$LOG"
note()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
stage() { echo "$*" > "$OUT/STAGE"; note "=== $*"; }
START=$(date +%s)
el() { local s=$(( $(date +%s) - START )); printf '%dh%02dm' $((s/3600)) $(((s%3600)/60)); }

note "results: $OUT"
note "lab: $LAB   machine: $MACHINE"
[ -d "$LAB/.git" ] && note "git: $(cd "$LAB" && git rev-parse --short HEAD 2>/dev/null)"

# metrics collectors run for the life of the orchestrator
for m in disk ceph memory; do
    nohup "$HERE/metrics/$m.sh" >"$OUT/$m.err" 2>&1 &
done
note "metrics collectors started"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  if [ "${SKIP_TEARDOWN:-0}" != 1 ]; then
    stage "STAGE 1/5 teardown"
    # Release the guests and the Incus containers first. A running Nova instance is
    # a nested QEMU scope the host cannot kill, and it is what makes the stop stall.
    # Bounded, and tolerant of a machine built before lab-down existed.
    if container machine ls 2>/dev/null | awk -v m="$MACHINE" '$1==m{print $7}' | grep -q running; then
        ld=$(mktemp); ( container machine run -n "$MACHINE" --root -- \
                /usr/local/sbin/lab-down.sh >"$ld" 2>&1 ) &
        lp=$!
        for i in $(seq 1 48); do kill -0 $lp 2>/dev/null || break; sleep 5; done
        kill -0 $lp 2>/dev/null && { note "lab-down exceeded 4 min -- going ahead"; kill -9 $lp 2>/dev/null; }
        cat "$ld" >>"$LOG" 2>/dev/null; rm -f "$ld"
        note "lab-down: $(grep -c '^lab-down:' "$LOG" 2>/dev/null || echo 0) steps logged"
    fi
    # bounded: an unbounded stop once hung for over seven hours while still printing
    container machine stop "$MACHINE" >>"$LOG" 2>&1 &
    sp=$!
    for i in $(seq 1 60); do kill -0 $sp 2>/dev/null || break; sleep 5; done
    if kill -0 $sp 2>/dev/null; then
        note "stop exceeded 5 min -- killing the VM process"
        kill -9 $sp 2>/dev/null
        vm=$(ps -Ao pid,comm | grep Virtualization.VirtualMachine | grep -v grep | awk '{print $1}' | head -1)
        [ -n "$vm" ] && kill -9 "$vm" 2>/dev/null
        sleep 8
    fi
    container machine delete "$MACHINE" >>"$LOG" 2>&1
    for img in $(container image ls 2>/dev/null | awk 'NR>1{print $1":"$2}'); do
        container image rm "$img" >>"$LOG" 2>&1
    done
    container builder delete >>"$LOG" 2>&1
    rm -rf "$LAB/.build" "$LAB/vmlinux-arm64"
    note "free after teardown: $(df -g / | awk 'NR==2{print $4}')GB"
  else
    note "SKIP_TEARDOWN: keeping the existing machine and images"
  fi

  if [ "${SKIP_KERNEL:-0}" != 1 ]; then
    stage "STAGE 2/5 kernel"
    ( cd "$LAB" && ./01-build-kernel.sh ) >>"$LOG" 2>&1
    [ -s "$LAB/vmlinux-arm64" ] || { note "KERNEL FAILED"; echo "FAILED kernel" > "$OUT/STATUS"; exit 1; }
    note "kernel ok [$(el)]"
  else
    [ -s "$LAB/vmlinux-arm64" ] || { note "SKIP_KERNEL but no vmlinux-arm64"; echo "FAILED no kernel" > "$OUT/STATUS"; exit 1; }
    note "SKIP_KERNEL: reusing $(ls -lh "$LAB/vmlinux-arm64" | awk '{print $5}') kernel"
  fi

  if [ "${SKIP_IMAGE:-0}" != 1 ]; then
    stage "STAGE 3/5 image"
    ( cd "$LAB" && ./02-build-image.sh ) >>"$LOG" 2>&1
    rc=$?; [ $rc -eq 0 ] || { note "IMAGE FAILED rc=$rc"; echo "FAILED image rc=$rc" > "$OUT/STATUS"; exit 1; }
    note "image ok [$(el)]"
  else
    note "SKIP_IMAGE: reusing the existing image and machine"
  fi

    stage "STAGE 4/5 provision"
    container machine run -n "$MACHINE" --root -- /usr/local/sbin/provision-lab.sh >>"$LOG" 2>&1
    rc=$?; note "provision rc=$rc [$(el)]"
    [ $rc -eq 0 ] || { echo "FAILED provision rc=$rc" > "$OUT/STATUS"; exit 1; }
fi

stage "STAGE 5/5 exercises 1-29"
: > "$OUT/SUMMARY"
run_part() {
    local src="$1" label="$2"
    local name; name=$(basename "$src")
    local out="$OUT/$name.out"
    note "--- $label starting"
    container machine run -n "$MACHINE" -i --root -- \
        bash -c "cat > /usr/local/sbin/$name && chmod 755 /usr/local/sbin/$name" < "$src" >>"$LOG" 2>&1
    container machine run -n "$MACHINE" --root -- "/usr/local/sbin/$name" > "$out" 2>&1
    local r=$? f
    cat "$out" >> "$LOG"
    f=$(grep -c '^  FAIL' "$out" 2>/dev/null)
    note "--- $label done rc=$r fails=${f:-?} [$(el)]"
    echo "$label: $( [ "${f:-1}" = 0 ] && echo PASS || echo "$f FAILED" )" >> "$OUT/SUMMARY"
}
run_part "$HERE/exercises/part-A-C.sh" "Parts A-C (1-8)"
run_part "$HERE/exercises/part-D-F.sh" "Parts D-F (9-17)"
run_part "$HERE/exercises/part-G.sh"   "Part G (18-28)"
run_part "$HERE/exercises/part-H.sh"   "Part H (29)"

stage "COMPLETE"
{ echo "finished in $(el)"; echo; cat "$OUT/SUMMARY"; echo
  echo "PASS: $(grep -c '^  PASS' "$LOG")   FAIL: $(grep -c '^  FAIL' "$LOG")"
} | tee "$OUT/STATUS" | tee -a "$LOG"
note "report: $HERE/report.py $OUT"
