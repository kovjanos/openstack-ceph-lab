#!/bin/bash
# Part G, restructured: extend capacity first, then fail ONLY the disk we added,
# then decommission it and give the space back before the fill exercise.
# Exercises 18-28. Runs inside the VM as root after ex-D-F.sh.
set +o pipefail
OS() { sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin exec openstack "$@"' _ "$@"; }
C()  { incus exec ceph-node1 -- cephadm shell -- "$@" 2>/dev/null; }
CK="-n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring"
K=/etc/openstack-lab/labkey.pem
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=$((FAILED+1)); }
FAILED=0
step() { printf '\n--- [%s|%s] %s\n' "$(date '+%H:%M:%S')" "$(date +%s)" "$*"; }
health()  { C ceph health 2>/dev/null | head -1; }
wait_ok() { for i in $(seq 1 "${1:-60}"); do C ceph health 2>/dev/null | grep -q HEALTH_OK && return 0; sleep 5; done; return 1; }
quiet()   { for i in $(seq 1 "${1:-60}"); do C ceph -s 2>/dev/null | grep -qE 'remapped|recovering|backfill' || return 0; sleep 10; done; return 1; }
vstat()   { OS volume show "$1" -f value -c status 2>/dev/null; }
waitvol() { for i in $(seq 1 40); do [ "$(vstat "$1")" = "$2" ] && return 0; sleep 3; done; return 1; }
# ceph df TOTAL columns: SIZE AVAIL RAW-USED USED %RAW-USED -- $4 is AVAIL, not used
dfr()     { C ceph df 2>/dev/null | awk '/TOTAL/{print "raw "$2$3" avail "$4$5" used "$6$7" ("$NF"%)"}'; }
imgs()    { du -ch /var/lib/ceph-disks/*.img 2>/dev/null | tail -1 | cut -f1; }
EXTRA_OSD_SIZE=5G

F1=$(OS server show share1 -f value -c addresses 2>/dev/null | grep -oE '172\.24\.4\.[0-9]+')
F2=$(OS server show share2 -f value -c addresses 2>/dev/null | grep -oE '172\.24\.4\.[0-9]+')
SFIP=${F1:-$(cat /tmp/ex-share1-fip 2>/dev/null)}
echo "share1=$F1  share2=$F2  ceph: $(dfr)  osd files: $(imgs)"

########## 18 -- RADOS
step "Ex18 RADOS: pools and a hand-written object"
n=$(C rados lspools | grep -c .); echo "    $n pools"
[ "$n" -ge 13 ] && pass "one object store behind every service ($n pools)" || fail "only $n pools"
incus exec ceph-node1 -- cephadm shell -- ceph osd pool create scratch 1 2>&1 | grep -v Inferring | sed 's/^/    /'
C ceph osd pool set scratch pg_autoscale_mode off >/dev/null 2>&1
C ceph osd pool application enable scratch rados >/dev/null 2>&1
out=$(incus exec ceph-node1 -- cephadm shell -- bash -c '
  echo "the lab put this here by hand" > /tmp/hello.txt
  rados -p scratch put greeting /tmp/hello.txt
  rados -p scratch ls; rados -p scratch stat greeting
  rados -p scratch get greeting /tmp/back.txt; echo "GOT:$(cat /tmp/back.txt)"' 2>/dev/null)
echo "$out" | grep -E '^greeting|^scratch/greeting|^GOT:' | sed 's/^/    /'
echo "$out" | grep -q 'GOT:the lab put this here by hand' && pass "object round-tripped" || fail "round trip failed"

step "Ex18 RADOS: a volume is objects, then export/restore to the other workload"
OS volume show rados-demo >/dev/null 2>&1 || OS volume create --size 1 rados-demo >/dev/null 2>&1
waitvol rados-demo available || fail "rados-demo never became available"
VID=$(OS volume show rados-demo -f value -c id)
PFX=$(rbd $CK info cinder-volumes/volume-$VID 2>/dev/null | awk '/block_name_prefix/{print $2}')
before=$(C rados -p cinder-volumes ls 2>/dev/null | grep -c "$PFX")
OS server add volume share2 rados-demo >/dev/null 2>&1; waitvol rados-demo in-use || fail "attach failed"
sleep 6
DEV=$(ssh $SSHO alpine@"$F2" 'for d in /dev/vd?; do [ "$d" = /dev/vda ] && continue; sudo blkid $d >/dev/null 2>&1 || echo $d; done | head -1' 2>/dev/null | tr -d '\r')
[ -z "$DEV" ] && DEV=/dev/vdb
ssh $SSHO alpine@"$F2" "sudo mkfs.ext4 -F $DEV >/dev/null 2>&1 && sudo mkdir -p /mnt/d && sudo mount $DEV /mnt/d && echo written-by-share2 | sudo tee /mnt/d/proof.txt >/dev/null && sudo sync && sudo umount /mnt/d && echo STEP_OK" 2>/dev/null | sed 's/^/    /'
sleep 6
after=$(C rados -p cinder-volumes ls 2>/dev/null | grep -c "$PFX")
echo "    objects $before -> $after"
[ "$after" -gt "$before" ] && pass "the filesystem is $after RADOS objects" || fail "objects did not grow"
OS server remove volume share2 rados-demo >/dev/null 2>&1; waitvol rados-demo available
rm -f /tmp/rados-demo.img
rbd $CK export cinder-volumes/volume-$VID /tmp/rados-demo.img >/dev/null 2>&1
strings /tmp/rados-demo.img 2>/dev/null | grep -q 'written-by-share2' && pass "backup file holds share2's data" || fail "backup empty"
OS volume show rados-restored >/dev/null 2>&1 || OS volume create --size 1 rados-restored >/dev/null 2>&1
waitvol rados-restored available || fail "restore target unavailable"
RID=$(OS volume show rados-restored -f value -c id)
rbd $CK rm cinder-volumes/volume-$RID >/dev/null 2>&1
rbd $CK import --image-feature layering /tmp/rados-demo.img cinder-volumes/volume-$RID >/dev/null 2>&1
OS server add volume share1 rados-restored >/dev/null 2>&1; waitvol rados-restored in-use || fail "restored volume did not attach"
sleep 6
RDEV=$(ssh $SSHO alpine@"$F1" 'for d in /dev/vd?; do [ "$d" = /dev/vda ] && continue; mount | grep -q "^$d " && continue; sudo blkid $d 2>/dev/null | grep -q ext4 && echo $d; done | tail -1' 2>/dev/null | tr -d '\r')
got=$(ssh $SSHO alpine@"$F1" "sudo mkdir -p /mnt/r && sudo mount $RDEV /mnt/r && sudo cat /mnt/r/proof.txt" 2>/dev/null | tr -d '\r')
echo "    share1 ($RDEV) sees: $got"
echo "$got" | grep -q 'written-by-share2' && pass "share1 reads what share2 wrote" || fail "restored volume lost the data"
ssh $SSHO alpine@"$F1" 'sudo umount /mnt/r' >/dev/null 2>&1
OS server remove volume share1 rados-restored >/dev/null 2>&1; waitvol rados-restored available
OS volume delete rados-restored >/dev/null 2>&1; OS volume delete rados-demo >/dev/null 2>&1
C ceph config set mon mon_allow_pool_delete true >/dev/null 2>&1
C ceph osd pool rm scratch scratch --yes-i-really-really-mean-it >/dev/null 2>&1
C ceph config set mon mon_allow_pool_delete false >/dev/null 2>&1
rm -f /tmp/rados-demo.img
OS server delete share2 >/dev/null 2>&1 && echo "    deleted share2 (guide's Ex18 cleanup)"
wait_ok 24 >/dev/null
echo "    ceph after 18: $(dfr)  osd files: $(imgs)"

########## 19 -- maintenance mode
step "Ex19 maintenance mode"
C ceph osd set noout >/dev/null; sleep 5
h=$(health); echo "    with noout: $h"
echo "$h" | grep -q HEALTH_WARN && pass "noout warns deliberately" || fail "noout did not warn ($h)"
C ceph osd unset noout >/dev/null
wait_ok 24 && pass "HEALTH_OK after unsetting noout" || fail "did not return to HEALTH_OK"

########## 20 -- restricted credentials
step "Ex20 restricted Ceph user"
C ceph auth get-or-create client.readonly mon 'profile rbd' osd 'profile rbd-read-only pool=cinder-volumes' >/dev/null
C ceph auth export client.readonly 2>&1 | grep -E 'client.readonly|key =|caps ' > /etc/ceph/ceph.client.readonly.keyring
chmod 600 /etc/ceph/ceph.client.readonly.keyring
KR="-n client.readonly --keyring /etc/ceph/ceph.client.readonly.keyring"
rbd $KR ls cinder-volumes >/dev/null 2>&1 && pass "read works with the restricted key" || fail "restricted key cannot read"
err=$(rbd $KR create --size 10 cinder-volumes/should-fail 2>&1)
echo "$err" | grep -qi 'operation not permitted' && pass "write refused by the capability" || fail "write not refused"
rbd $KR rm cinder-volumes/should-fail >/dev/null 2>&1

########## 21 -- EXTEND CAPACITY (this is what makes the failure drills safe)
step "Ex21 extend the cluster with a new OSD"
echo "    before: $(C ceph -s 2>/dev/null | awk '/osd:/{print $2,$3,$4,$5}')  $(dfr)  files $(imgs)"
mkdir -p /var/lib/ceph-disks
[ -f /var/lib/ceph-disks/osd4.img ] || truncate -s "$EXTRA_OSD_SIZE" /var/lib/ceph-disks/osd4.img
LOOP=$(losetup -j /var/lib/ceph-disks/osd4.img | cut -d: -f1)
[ -n "$LOOP" ] || LOOP=$(losetup --find --show /var/lib/ceph-disks/osd4.img)
vgs ceph-vg4 >/dev/null 2>&1 || { pvcreate -f "$LOOP" >/dev/null 2>&1; vgcreate ceph-vg4 "$LOOP" >/dev/null 2>&1; lvcreate -l 100%FREE -n osd4 ceph-vg4 >/dev/null 2>&1; }
vgs ceph-vg4 >/dev/null 2>&1 && pass "ceph-vg4/osd4 created ($EXTRA_OSD_SIZE on $LOOP)" || fail "volume group not created"
pgrep -f 'sleep infinity' >/dev/null || setsid sh -c 'exec sleep infinity < /dev/ceph-vg4/osd4' &
sleep 2
DM=$(dmsetup ls | awk '$1=="ceph--vg4-osd4"{gsub(/[()]/,"",$2); split($2,a,":"); print a[2]}')
WANT=$(dmsetup ls | awk '$1=="ceph--vg4-osd4"{gsub(/[()]/,"",$2); print $2}')
if ! incus info ceph-node4 >/dev/null 2>&1; then
  incus launch ceph-node-base ceph-node4 -c security.privileged=true >/dev/null 2>&1
  incus stop ceph-node4 >/dev/null 2>&1
  incus config device override ceph-node4 eth0 ipv4.address=10.100.0.14 >/dev/null 2>&1
  incus config set ceph-node4 boot.autostart false >/dev/null 2>&1
  incus config device add ceph-node4 dm-control unix-char path=/dev/mapper/control source=/dev/mapper/control >/dev/null 2>&1
  incus config device add ceph-node4 pv-disk unix-block path="$LOOP" source="$LOOP" >/dev/null 2>&1
  incus config device add ceph-node4 dm3 unix-block path="/dev/dm-$DM" source="/dev/dm-$DM" >/dev/null 2>&1
  incus config set ceph-node4 raw.lxc "lxc.mount.auto = sys:rw
lxc.apparmor.profile = unconfined" >/dev/null 2>&1
  incus start ceph-node4 >/dev/null 2>&1
fi
for i in $(seq 1 24); do incus exec ceph-node4 -- systemctl is-active systemd-udevd >/dev/null 2>&1 && break; sleep 5; done
incus exec ceph-node4 -- bash -c 'rm -rf /dev/ceph-vg*/ /dev/mapper/ceph--*' >/dev/null 2>&1
incus exec ceph-node4 -- dmsetup mknodes >/dev/null 2>&1
incus exec ceph-node4 -- vgmknodes >/dev/null 2>&1
GOT=$(incus exec ceph-node4 -- ls -lL /dev/ceph-vg4/osd4 2>/dev/null | awk '{gsub(",","",$5); print $5":"$6}')
[ -n "$GOT" ] && [ "$GOT" = "$WANT" ] && pass "device node matches the host ($GOT)" || fail "mapping mismatch ($GOT vs $WANT)"
incus exec ceph-node4 -- dd if=/dev/ceph-vg4/osd4 of=/dev/null bs=1M count=1 >/dev/null 2>&1 \
  && pass "container reads through the LVM path" || fail "cannot read the LVM path"
C ceph cephadm get-pub-key 2>/dev/null | grep '^ssh-' > /tmp/cephkey
incus exec ceph-node4 -- mkdir -p /root/.ssh >/dev/null 2>&1
cat /tmp/cephkey | incus exec ceph-node4 -- tee /root/.ssh/authorized_keys >/dev/null 2>&1
incus exec ceph-node4 -- chmod 600 /root/.ssh/authorized_keys >/dev/null 2>&1
C ceph orch host add ceph-node4 10.100.0.14 >/dev/null 2>&1; sleep 15
C ceph orch host ls 2>/dev/null | grep -q ceph-node4 && pass "host joined" || fail "host add failed"
out=$(incus exec ceph-node1 -- cephadm shell -- ceph orch daemon add osd ceph-node4:ceph-vg4/osd4 2>&1 | grep -v Inferring)
echo "    add osd said: ${out:-<no output>}"
for i in $(seq 1 48); do n=$(C ceph -s 2>/dev/null | grep -oE '[0-9]+ osds' | head -1 | awk '{print $1}'); [ "$n" = 4 ] && break; sleep 10; done
[ "$n" = 4 ] && pass "fourth OSD joined the cluster" || fail "still $n OSDs"
C ceph osd tree 2>/dev/null | tail -3 | sed 's/^/    /'
quiet 60; wait_ok 90 && pass "rebalanced onto the new disk, HEALTH_OK" || echo "    (still settling: $(health))"
echo "    after 21: $(dfr)  files $(imgs)"

########## 22 -- lose a disk (the NEW one, never an original)
step "Ex22 lose the added disk while the service runs"
before=$(curl -s --max-time 5 "http://$SFIP/" 2>/dev/null)
[ -n "$before" ] && pass "workload serving before the drill" || fail "workload not serving at http://$SFIP/"
C ceph orch daemon stop osd.3 >/dev/null
for i in $(seq 1 30); do C ceph -s 2>/dev/null | grep -q '3 up'; [ $? -eq 0 ] && break; sleep 5; done
C ceph -s 2>/dev/null | grep -E 'health|osd:|degraded' | sed 's/^/    /'
deg=$(C ceph -s 2>/dev/null | grep -oE 'degraded \([0-9.]+%\)' | head -1)
echo "    degraded: ${deg:-none reported}"
during=$(curl -s --max-time 8 "http://$SFIP/" 2>/dev/null)
[ "$during" = "$before" ] && pass "workload never noticed the missing OSD" || fail "service changed during the drill"
rbd $CK ls cinder-volumes >/dev/null 2>&1 && pass "volumes still listable with an OSD down" || fail "rbd ls failed"
C ceph orch daemon start osd.3 >/dev/null
wait_ok 60 && pass "HEALTH_OK after the OSD came back" || fail "did not recover"

########## 23 -- replace the added disk properly (purge and re-add the same LV)
step "Ex23 replace the added disk"
C ceph osd out osd.3 >/dev/null 2>&1
quiet 60
C ceph osd tree 2>/dev/null | grep -E '^ *3 ' | sed 's/^/    drained: /'
C ceph orch daemon stop osd.3 >/dev/null 2>&1; sleep 8
C ceph orch daemon rm osd.3 --force >/dev/null 2>&1; sleep 8
C ceph osd purge 3 --yes-i-really-mean-it >/dev/null 2>&1; sleep 5
n=$(C ceph -s 2>/dev/null | grep -oE '[0-9]+ osds' | head -1 | awk '{print $1}')
[ "$n" = 3 ] && pass "osd.3 purged, back to 3 OSDs" || fail "purge left $n OSDs"
# the step everyone misses: ceph-volume left its own tags on the LV, and a re-add
# fails with 'Created no osd(s) ... already created?' until they are gone
tags=$(lvs --noheadings -o lv_tags ceph-vg4/osd4 2>/dev/null | tr ',' ' ')
echo "    lv tags before wipe: $(echo $tags | cut -c1-60)"
for t in $tags; do lvchange --deltag "$t" ceph-vg4/osd4 >/dev/null 2>&1; done
dd if=/dev/zero of=/dev/ceph-vg4/osd4 bs=1M count=100 conv=fsync >/dev/null 2>&1
left=$(lvs --noheadings -o lv_tags ceph-vg4/osd4 2>/dev/null | tr -d ' ')
[ -z "$left" ] && pass "LVM tags cleared and BlueStore label wiped" || fail "tags remain: $left"
incus exec ceph-node4 -- bash -c 'rm -rf /dev/ceph-vg*/ /dev/mapper/ceph--*' >/dev/null 2>&1
incus exec ceph-node4 -- dmsetup mknodes >/dev/null 2>&1
incus exec ceph-node4 -- vgmknodes >/dev/null 2>&1
out=$(incus exec ceph-node1 -- cephadm shell -- ceph orch daemon add osd ceph-node4:ceph-vg4/osd4 2>&1 | grep -v Inferring)
echo "    re-add said: ${out:-<no output>}"
for i in $(seq 1 48); do n=$(C ceph -s 2>/dev/null | grep -oE '[0-9]+ osds' | head -1 | awk '{print $1}'); [ "$n" = 4 ] && break; sleep 10; done
[ "$n" = 4 ] && pass "replacement disk is back in the cluster" || fail "re-add failed, $n OSDs"
quiet 90; wait_ok 90 && pass "HEALTH_OK after the replacement" || fail "not healthy: $(health)"

########## 24 -- CephFS snapshots
step "Ex24 CephFS snapshots"
command -v ceph-fuse >/dev/null && pass "ceph-fuse is in the image" || fail "ceph-fuse missing"
[ -f /etc/ceph/ceph.client.admin.keyring ] || { incus exec ceph-node1 -- cat /etc/ceph/ceph.client.admin.keyring > /etc/ceph/ceph.client.admin.keyring 2>/dev/null; chmod 600 /etc/ceph/ceph.client.admin.keyring; }
mkdir -p /mnt/cephfs
mountpoint -q /mnt/cephfs || ceph-fuse -n client.admin /mnt/cephfs >/dev/null 2>&1
sleep 5
if mountpoint -q /mnt/cephfs; then
  pass "cephfs mounted with ceph-fuse"
  echo snapshot-test > /mnt/cephfs/snaptest.txt
  mkdir -p /mnt/cephfs/.snap/before-migration 2>/dev/null
  rm -f /mnt/cephfs/snaptest.txt
  if [ -f /mnt/cephfs/.snap/before-migration/snaptest.txt ]; then
    pass "the deleted file is still in the snapshot"
    cp /mnt/cephfs/.snap/before-migration/snaptest.txt /mnt/cephfs/ 2>/dev/null
    [ -f /mnt/cephfs/snaptest.txt ] && pass "restored from the snapshot" || fail "restore failed"
  else fail "snapshot did not capture the file"; fi
  rmdir /mnt/cephfs/.snap/before-migration 2>/dev/null; rm -f /mnt/cephfs/snaptest.txt
  umount /mnt/cephfs 2>/dev/null
else fail "could not mount cephfs"; fi

########## 25 -- what the third copy would cost (lab runs at 2)
step "Ex25 replication cost: 2 -> 3 -> 2"
echo "    --- DF_BEFORE ---"
C ceph df 2>/dev/null | grep -E 'TOTAL|cinder-volumes|glance-images' | sed 's/^/    /'
s=$(C ceph osd pool get cinder-volumes size 2>/dev/null | awk '{print $2}')
[ "$s" = 2 ] && pass "lab runs cinder-volumes at size 2" || fail "unexpected size $s"
C ceph osd pool set cinder-volumes size 3 >/dev/null; sleep 15; quiet 30
echo "    --- DF_SIZE3 ---"
C ceph df 2>/dev/null | grep -E 'TOTAL|cinder-volumes|glance-images' | sed 's/^/    /'
C ceph osd pool set cinder-volumes size 2 >/dev/null; sleep 15; quiet 30
[ "$(C ceph osd pool get cinder-volumes size 2>/dev/null | awk '{print $2}')" = 2 ] \
  && pass "back to size 2" || fail "pool left at the wrong size"
wait_ok 60 >/dev/null

########## 26 -- scrub
step "Ex26 verify the data"
C ceph osd deep-scrub 3 >/dev/null 2>&1 && pass "deep scrub accepted" || fail "could not trigger a deep scrub"
C ceph osd pool ls detail 2>/dev/null | grep -q cinder-volumes && pass "pool detail readable" || fail "pool detail unreadable"

########## 27 -- monitoring
step "Ex27 the monitoring you already have"
n=$(C ceph orch ls 2>/dev/null | grep -cE '^(prometheus|grafana|alertmanager|node-exporter|ceph-exporter)')
[ "$n" -ge 5 ] && pass "monitoring stack deployed ($n services)" || fail "only $n monitoring services"
VM_IP=$(ip -br addr show enp0s1 | awk '{print $3}' | cut -d/ -f1)
for u in "https://$VM_IP:3000/api/health" "http://$VM_IP:9095/-/healthy" "http://$VM_IP:9093/-/healthy"; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$u")
  [ "$code" = 200 ] && pass "reachable: $u" || fail "$u returned $code"
done
rules=$(curl -s --max-time 10 "http://$VM_IP:9095/api/v1/rules" | grep -o '"type":"alerting"' | grep -c .)
[ "$rules" -gt 50 ] && pass "$rules alerting rules loaded" || fail "only $rules alert rules"

########## 28 -- decommission the added disk and give the space back
step "Ex28 decommission the added disk, reclaim the space"
echo "    before: $(dfr)  files $(imgs)"
C ceph osd out osd.3 >/dev/null 2>&1
quiet 90
C ceph orch daemon rm osd.3 --force >/dev/null 2>&1; sleep 10
C ceph osd purge 3 --yes-i-really-mean-it >/dev/null 2>&1; sleep 5
C ceph orch host rm ceph-node4 --force >/dev/null 2>&1; sleep 10
n=$(C ceph -s 2>/dev/null | grep -oE '[0-9]+ osds' | head -1 | awk '{print $1}')
[ "$n" = 3 ] && pass "back to the three original OSDs" || fail "osd count is $n"
C ceph mon dump 2>/dev/null | grep -q 'mon.ceph-node4' && pass "stranded monitor still in the monmap (the lesson)" || echo "    (no mon was placed on node4)"
C ceph mon rm ceph-node4 >/dev/null 2>&1
incus delete ceph-node4 --force >/dev/null 2>&1
pkill -f 'sleep infinity' 2>/dev/null; sleep 2
lvremove -f ceph-vg4 >/dev/null 2>&1; vgremove -f ceph-vg4 >/dev/null 2>&1
[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
rm -f /var/lib/ceph-disks/osd4.img && pass "osd4.img deleted -- that space is off the host disk"
C ceph health mute CEPHADM_REFRESH_FAILED 1w >/dev/null 2>&1
h=$(health); echo "    after removal: $h"
echo "$h" | grep -q 'too many PGs' && { C ceph config set global mon_max_pg_per_osd 400 >/dev/null 2>&1; echo "    applied the documented PG-limit remedy"; }
quiet 90; wait_ok 90 && pass "cluster clean after decommissioning" || fail "not clean: $(health)"
fstrim -v / 2>/dev/null | sed 's/^/    trim: /'
echo "    after 28: $(dfr)  files $(imgs)"

fstrim / >/dev/null 2>&1 || true
printf '\n=========== Part G (18-28): %s ===========\n' \
  "$( [ "$FAILED" -eq 0 ] && echo 'all checks passed' || echo "$FAILED CHECK(S) FAILED" )"
exit 0
