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

{ echo "MACHINE_MEMORY=${MACHINE_MEMORY:-26G}"
  echo "MACHINE_CPUS=${MACHINE_CPUS:-8}"
  echo "OSD_SIZE=${OSD_SIZE:-5G}"
  echo "CEPH_POOL_SIZE=${CEPH_POOL_SIZE:-2}"
  echo "ENABLE_NETWORK_LOADBALANCER=${ENABLE_NETWORK_LOADBALANCER:-yes}"
} > "$OUT/CONFIG"
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
    stage "STAGE 1/6 teardown"
    # Release the guests and the Incus containers first. A running Nova instance is
    # a nested QEMU scope the host cannot kill, and it is what makes the stop stall.
    # Bounded, and tolerant of a machine built before lab-down existed.
    if container machine ls 2>/dev/null | grep "^$MACHINE " | grep -qw running; then
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
    stage "STAGE 2/6 kernel"
    ( cd "$LAB" && ./01-build-kernel.sh ) >>"$LOG" 2>&1
    [ -s "$LAB/vmlinux-arm64" ] || { note "KERNEL FAILED"; echo "FAILED kernel" > "$OUT/STATUS"; exit 1; }
    note "kernel ok [$(el)]"
  else
    [ -s "$LAB/vmlinux-arm64" ] || { note "SKIP_KERNEL but no vmlinux-arm64"; echo "FAILED no kernel" > "$OUT/STATUS"; exit 1; }
    note "SKIP_KERNEL: reusing $(ls -lh "$LAB/vmlinux-arm64" | awk '{print $5}') kernel"
  fi

  if [ "${SKIP_IMAGE:-0}" != 1 ]; then
    stage "STAGE 3/6 image"
    ( cd "$LAB" && ./02-build-image.sh ) >>"$LOG" 2>&1
    rc=$?; [ $rc -eq 0 ] || { note "IMAGE FAILED rc=$rc"; echo "FAILED image rc=$rc" > "$OUT/STATUS"; exit 1; }
    note "image ok [$(el)]"
  else
    note "SKIP_IMAGE: reusing the existing image and machine"
  fi

    stage "STAGE 4/6 provision"
    container machine run -n "$MACHINE" --root -- /usr/local/sbin/provision-lab.sh >>"$LOG" 2>&1
    rc=$?; note "provision rc=$rc [$(el)]"
    [ $rc -eq 0 ] || { echo "FAILED provision rc=$rc" > "$OUT/STATUS"; exit 1; }
fi

stage "STAGE 5/6 exercises 1-29"
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

stage "STAGE 6/6 graceful stop and restart"
# Does the machine stop on its own once the lab is down, and does everything come
# back? Both have failed before: a stop with a guest running either errors on
# cgroup.kill or prints progress until the VM process is killed.
rpass() { printf '  PASS  %s\n' "$*" | tee -a "$LOG"; }
rfail() { printf '  FAIL  %s\n' "$*" | tee -a "$LOG"; }
mline() { container machine ls 2>/dev/null | grep "^$MACHINE "; }

t0=$(date +%s)
container machine run -n "$MACHINE" --root -- /usr/local/sbin/lab-down.sh >>"$LOG" 2>&1
ldrc=$?
note "lab-down rc=$ldrc in $(( $(date +%s) - t0 ))s"
[ $ldrc -eq 0 ] && rpass "lab-down completed" || rfail "lab-down rc=$ldrc"

t0=$(date +%s)
container machine stop "$MACHINE" >>"$LOG" 2>&1 &
sp=$!
for i in $(seq 1 60); do kill -0 $sp 2>/dev/null || break; sleep 5; done
if kill -0 $sp 2>/dev/null; then
    kill -9 $sp 2>/dev/null
    vm=$(ps -Ao pid,comm | grep Virtualization.VirtualMachine | grep -v grep | awk '{print $1}' | head -1)
    [ -n "$vm" ] && kill -9 "$vm" 2>/dev/null
    sleep 8
    rfail "stop did not return within 5 min -- killed the VM process"
    # The runtime still reports the machine as running and the restart below would
    # fail in 0s with "container is not running". A second stop reconciles it.
    container machine stop "$MACHINE" >>"$LOG" 2>&1 || true
    note "issued a second stop to reconcile the runtime state"
else
    wait $sp; src=$?
    secs=$(( $(date +%s) - t0 ))
    note "stop returned rc=$src in ${secs}s"
    [ $src -eq 0 ] && rpass "graceful stop returned on its own in ${secs}s" \
                   || rfail "stop exited rc=$src after ${secs}s"
fi

st=$(mline); vmleft=$(ps -Ao pid,comm | grep Virtualization.VirtualMachine | grep -v grep | wc -l | tr -d ' ')
note "after stop: ${st:-<no line>}   VM processes: $vmleft"
echo "$st" | grep -qw stopped && rpass "machine reports stopped" || rfail "machine is not 'stopped' after the stop"
[ "$vmleft" = 0 ] && rpass "no VM process left behind" || rfail "$vmleft VM process(es) still running"

# Restart, and let 90-verify prove the services came back. It waits on Ceph, the
# keepalived VIP, keystone, nova-api and hypervisor registration.
t0=$(date +%s)
container machine run -n "$MACHINE" --root -- \
    /usr/local/sbin/provision-lab.sh --only 90-verify > "$OUT/restart-verify.out" 2>&1
vrc=$?
cat "$OUT/restart-verify.out" >> "$LOG"
note "restart + 90-verify rc=$vrc in $(( $(date +%s) - t0 ))s"
[ $vrc -eq 0 ] && rpass "machine restarted and 90-verify exited 0" || rfail "restart/verify rc=$vrc"

# 90-verify does not exit non-zero for a sick service; it prints these instead.
patt='GAVE UP|NOT healthy|NOT up|NOT answering|still no hypervisor'
bad=$(grep -cE "$patt" "$OUT/restart-verify.out" 2>/dev/null)
if ! grep -q '90-verify complete' "$OUT/restart-verify.out" 2>/dev/null; then
    # An empty or truncated file has no failure text in it either. Demand the
    # phase's own completion line before reading silence as success.
    rfail "90-verify did not run to completion -- $(wc -l < "$OUT/restart-verify.out" 2>/dev/null || echo 0) lines of output"
elif [ "${bad:-0}" = 0 ]; then
    rpass "no service reported a problem after restart"
else
    rfail "$bad service problem(s) after restart"
    grep -E "$patt" "$OUT/restart-verify.out" | sed 's/^/      /' | tee -a "$LOG"
fi

h=$(printf '%s\n' 'incus exec ceph-node1 -- cephadm shell -- ceph health 2>/dev/null' \
      | container machine run -n "$MACHINE" -i --root -- bash -s 2>/dev/null \
      | tr -d '\r' | grep -E 'HEALTH_' | head -1)
note "ceph after restart: ${h:-<no answer>}"
case "$h" in HEALTH_OK*) rpass "Ceph HEALTH_OK after restart";;
             *)          rfail "Ceph after restart: ${h:-no answer}";; esac

stage "COMPLETE"
{ echo "finished in $(el)"; echo; cat "$OUT/SUMMARY"; echo
  echo "PASS: $(grep -c '^  PASS' "$LOG")   FAIL: $(grep -c '^  FAIL' "$LOG")"
} | tee "$OUT/STATUS" | tee -a "$LOG"
note "report: $HERE/report.py $OUT"
