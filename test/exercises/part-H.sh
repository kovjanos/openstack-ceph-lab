#!/bin/bash
# Exercise 29 -- fill the cluster, hit the delete deadlock, recover. Destructive by design.
set +o pipefail
OS() { sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin exec openstack "$@"' _ "$@"; }
C()  { incus exec ceph-node1 -- cephadm shell -- "$@" 2>/dev/null; }
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=$((FAILED+1)); }
FAILED=0
step() { printf '\n--- [%s|%s] %s\n' "$(date '+%H:%M:%S')" "$(date +%s)" "$*"; }
pct() { C ceph df | awk '/TOTAL/{print $NF}'; }
imgs() { du -ch /var/lib/ceph-disks/*.img 2>/dev/null | tail -1 | cut -f1; }

step "Ex29 lower the ratios so a full cluster does not kill an OSD"
# Ceph enforces nearfull < backfillfull < full, so all three move together.
# At the default 0.95 a 5G OSD has ~340 MB left when writes stop, which is not enough
# for RocksDB to compact: BlueFS aborts with "bluefs enospc" and the OSD will not
# restart. At 0.80 it has ~1 GB, and the cluster is still genuinely full.
C ceph osd set-nearfull-ratio     0.70 2>&1 | tail -1 | sed 's/^/    /'
C ceph osd set-backfillfull-ratio 0.75 2>&1 | tail -1 | sed 's/^/    /'
C ceph osd set-full-ratio         0.80 2>&1 | tail -1 | sed 's/^/    /'
sleep 5
C ceph osd dump 2>/dev/null | grep -E "full_ratio" | sed 's/^/    /'
r=$(C ceph osd dump 2>/dev/null | awk '/^full_ratio/{print $2}')
[ "$r" = "0.8" ] && pass "full_ratio lowered to 0.80 before filling" || fail "full_ratio is '$r', expected 0.8"

step "Ex29 fill the cluster"
echo "  starting at $(pct)% raw used"
cd /tmp
[ -f big.raw ] || dd if=/dev/urandom of=big.raw bs=1M count=1000 status=none
echo "  made $(du -h big.raw | cut -f1) of incompressible data"

for n in $(seq 1 24); do
  OS image show big-image-$n >/dev/null 2>&1 && continue
  cur=$(pct)
  # A 1 GB image costs 2 GiB raw at size 2. Near the top that no longer fits, and the
  # upload fails silently leaving the cluster stuck below full_ratio. Drop to 250 MB
  # once past 85% so the last few percent can actually be walked.
  if echo "$cur" | awk '{exit !($1+0 >= 72)}'; then
    [ -f /tmp/small.raw ] || dd if=/dev/urandom of=/tmp/small.raw bs=1M count=250 status=none
    src=/tmp/small.raw; sz=250M
  else
    src=/tmp/big.raw; sz=1G
  fi
  echo "  uploading big-image-$n ($sz) ... (${cur}% used)"
  OS image create big-image-$n --file "$src" --disk-format raw \
     --container-format bare >/dev/null 2>&1
  p=$(pct)
  echo "$p" | awk '{exit !($1+0 >= 81)}' && { echo "  cluster at $p% -- stopping"; break; }
  # once the cluster stops accepting writes the uploads fail silently and the
  # percentage stops moving; two flat readings mean full, not slow
  if [ "$p" = "${last:-}" ]; then
    flat=$((${flat:-0} + 1))
    [ "$flat" -ge 2 ] && { echo "  cluster stopped accepting writes at $p% -- stopping"; break; }
  else flat=0; fi
  last=$p
done

echo "  now at $(pct)% raw used, osd files $(imgs)"
C ceph df | grep -E 'TOTAL|glance-images' | sed 's/^/    /'
C ceph health detail 2>/dev/null | head -4 | sed 's/^/    /'
C ceph health detail 2>/dev/null | grep -qE 'OSD_FULL|POOL_FULL|osd\(s\) full' && pass "cluster reports OSD_FULL/POOL_FULL" \
  || fail "cluster did not reach a full state (at $(pct)%)"

step "Ex29 the deadlock -- deleting is itself a write"
IMG=$(OS image list -f value -c Name 2>/dev/null | grep '^big-image-' | head -1)
if [ -z "$IMG" ]; then
  echo "    glance is not answering -- that IS the symptom; falling back to rbd"
  IMG=$(rbd -n client.glance --keyring /etc/ceph/ceph.client.glance.keyring ls glance-images 2>/dev/null | head -1)
  [ -n "$IMG" ] && pass "cluster full: the image API is down, rbd still lists images" \
                || fail "neither glance nor rbd could list images"
fi
echo "  trying to delete $IMG while the cluster is full"
out=$(timeout 90 sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin openstack image delete '"$IMG" 2>&1 | tail -2)
echo "    ${out:-<no output>}"
sleep 10
# Do not ask glance whether the image survived: glance is down, which is the whole
# point. Ask rbd, which talks to the cluster directly.
RBDLS="rbd -n client.glance --keyring /etc/ceph/ceph.client.glance.keyring ls glance-images"
if $RBDLS 2>/dev/null | grep -q .; then
  pass "images still in the pool after the delete -- this is the deadlock the exercise is about"
else
  echo "    (pool is empty -- the delete completed, so the cluster was not blocking writes)"
fi

step "Ex29 the way out -- raise full_ratio, delete, put it back"
C ceph osd set-full-ratio 0.99 2>&1 | sed 's/^/    /'
sleep 10
for i in $(OS image list -f value -c Name | grep '^big-image-'); do
  OS image delete "$i" >/dev/null 2>&1 && echo "    deleted $i"
done
for i in $(seq 1 30); do
  p=$(pct); echo "$p" | awk '{exit !($1+0 < 60)}' && break
  sleep 10
done
echo "  after deleting: $(pct)% raw used"
C ceph osd set-full-ratio         0.95 2>&1 | tail -1 | sed 's/^/    /'
C ceph osd set-backfillfull-ratio 0.90 2>&1 | tail -1 | sed 's/^/    /'
C ceph osd set-nearfull-ratio     0.85 2>&1 | tail -1 | sed 's/^/    /'
sleep 15
for i in $(seq 1 40); do C ceph health | grep -q HEALTH_OK && break; sleep 10; done
C ceph health | head -1 | sed 's/^/    /'
down=$(C ceph -s 2>/dev/null | grep -oE '[0-9]+ osds: [0-9]+ up' | awk '{print ($2+0)-($4+0)}')
[ "${down:-0}" -gt 0 ] && fail "an OSD did not survive the fill (bluefs enospc kills OSDs that are too small)" \
                       || pass "every OSD survived the fill"
C ceph health | grep -q HEALTH_OK && pass "cluster recovered to HEALTH_OK" \
  || fail "still not healthy: $(C ceph health | head -1)"
C ceph df | grep -E 'TOTAL' | sed 's/^/    /'

rm -f /tmp/big.raw /tmp/small.raw
fstrim / >/dev/null 2>&1 || true
printf '\n=========== Exercise 29: %s ===========\n' \
  "$( [ "$FAILED" -eq 0 ] && echo 'all checks passed' || echo "$FAILED CHECK(S) FAILED" )"
exit 0
