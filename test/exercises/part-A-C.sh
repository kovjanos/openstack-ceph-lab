#!/bin/bash
# Exercises 1-8 (Parts A, B, C) exactly as the guide writes them.
# Runs inside the VM as root. Each step prints PASS/FAIL so a run can be read at a glance.
set +o pipefail

OS() { sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin exec openstack "$@"' _ "$@"; }
K=/etc/openstack-lab/labkey.pem
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=$((FAILED+1)); }
FAILED=0
step() { printf '\n--- [%s|%s] %s\n' "$(date '+%H:%M:%S')" "$(date +%s)" "$*"; }

########## Exercise 1 -- bootstrap the tenant
step "Ex1 bootstrap the tenant"
OS network show public >/dev/null 2>&1 || \
  OS network create --external --provider-physical-network physnet1 --provider-network-type flat public >/dev/null
OS subnet show public-subnet >/dev/null 2>&1 || \
  OS subnet create public-subnet --network public --subnet-range 172.24.4.0/24 \
    --gateway 172.24.4.1 --allocation-pool start=172.24.4.10,end=172.24.4.200 --no-dhcp >/dev/null
OS network show private >/dev/null 2>&1 || OS network create private >/dev/null
OS subnet show private-subnet >/dev/null 2>&1 || \
  OS subnet create private-subnet --network private --subnet-range 10.0.0.0/24 --dns-nameserver 8.8.8.8 >/dev/null
OS router show r1 >/dev/null 2>&1 || {
  OS router create r1 >/dev/null
  OS router set r1 --external-gateway public
  OS router add subnet r1 private-subnet
}
OS flavor show m1.lab >/dev/null 2>&1 || OS flavor create m1.lab --ram 512 --vcpus 1 --disk 2 >/dev/null
if [ ! -f "$K" ]; then OS keypair create labkey > "$K"; chmod 600 "$K"; fi
ADMIN=$(OS project show admin -f value -c id)
DEFSG=$(OS security group list --project "$ADMIN" -f value -c ID -c Name | awk '$2=="default"{print $1}')
OS security group rule list "$DEFSG" -f value -c "IP Protocol" | grep -q '^tcp$' || \
  OS security group rule create --proto tcp --dst-port 22 "$DEFSG" >/dev/null
OS security group rule list "$DEFSG" -f value -c "IP Protocol" | grep -q '^icmp$' || \
  OS security group rule create --proto icmp "$DEFSG" >/dev/null
OS security group rule list "$DEFSG" -f value -c "IP Protocol" | grep -q '^tcp$' \
  && pass "default group now allows ssh" || fail "default group has no ssh ingress"

OS network list -f value -c Name | grep -q '^public$'  && pass "public network"  || fail "public network"
OS network list -f value -c Name | grep -q '^private$' && pass "private network" || fail "private network"
OS router list  -f value -c Name | grep -q '^r1$'      && pass "router r1"       || fail "router r1"
OS flavor list  -f value -c Name | grep -q '^m1.lab$'  && pass "flavor m1.lab"   || fail "flavor m1.lab"
[ -s "$K" ] && pass "keypair labkey" || fail "keypair labkey"

########## Exercise 2 -- build the lab image, exactly as the guide does it
step "Ex2 build the lab image"
if ! OS image show lab-workload >/dev/null 2>&1; then
  cd /tmp
  [ -f nocloud_alpine-3.21.2-aarch64-uefi-cloudinit-r0.qcow2 ] || \
    curl -sSLO https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/nocloud_alpine-3.21.2-aarch64-uefi-cloudinit-r0.qcow2
  [ -s nocloud_alpine-3.21.2-aarch64-uefi-cloudinit-r0.qcow2 ] \
    && pass "downloaded the Alpine cloud image" || fail "download failed"
  rm -f lab-workload.raw
  qemu-img convert -f qcow2 -O raw nocloud_alpine-*.qcow2 lab-workload.raw

  LO=$(losetup --find --show -P lab-workload.raw)
  mkdir -p /mnt/alp && mount "${LO}p2" /mnt/alp

  # Fix 1 -- the datasource. Match the line rather than trusting line 105 to be
  # stable across Alpine releases; the guide's sed is release-specific.
  if grep -q '^datasource_list' /mnt/alp/etc/cloud/cloud.cfg; then
    sed -i 's/^datasource_list:.*/datasource_list: ["ConfigDrive", "OpenStack", "NoCloud", "None"]/' \
      /mnt/alp/etc/cloud/cloud.cfg
    grep -q 'ConfigDrive' /mnt/alp/etc/cloud/cloud.cfg \
      && pass "datasource_list now tries ConfigDrive and OpenStack" || fail "datasource fix did not apply"
  else
    fail "no datasource_list line found -- image layout changed"
  fi

  # Fix 2 -- the packages
  cp /etc/resolv.conf /mnt/alp/etc/resolv.conf
  for d in proc sys dev; do mount --bind /$d /mnt/alp/$d; done
  grep -q '/community' /mnt/alp/etc/apk/repositories || \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.21/community" >> /mnt/alp/etc/apk/repositories
  chroot /mnt/alp /sbin/apk update >/dev/null 2>&1
  chroot /mnt/alp /sbin/apk add nfs-utils e2fsprogs dosfstools curl darkhttpd sudo >/dev/null 2>&1
  chroot /mnt/alp /bin/sh -c 'command -v darkhttpd && command -v sudo' >/dev/null 2>&1 \
    && pass "darkhttpd and sudo installed into the image" || fail "apk add failed inside the chroot"
  echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /mnt/alp/etc/sudoers.d/wheel
  for d in proc sys dev; do umount /mnt/alp/$d; done
  rm -f /mnt/alp/etc/resolv.conf
  umount /mnt/alp && losetup -d "$LO"

  OS image create lab-workload --file /tmp/lab-workload.raw --disk-format raw \
    --container-format bare --public --property hw_firmware_type=uefi >/dev/null 2>&1
fi
if OS image show lab-workload >/dev/null 2>&1; then
  sz=$(OS image show lab-workload -f value -c size)
  fmt=$(OS image show lab-workload -f value -c disk_format)
  pass "lab-workload in glance: $sz bytes, $fmt"
  [ "$fmt" = raw ] && pass "raw, so nova COW-clones it" || fail "not raw"
else
  fail "lab-workload was not created"
fi

########## Exercise 3 -- a first workload
step "Ex3 a first workload"
OS server show web1 >/dev/null 2>&1 || \
  OS server create web1 --image lab-workload --flavor m1.lab --network private \
    --key-name labkey --config-drive true >/dev/null
for i in $(seq 1 40); do [ "$(OS server show web1 -f value -c status 2>/dev/null)" = ACTIVE ] && break; sleep 3; done
FIP=$(OS floating ip list -f value -c "Floating IP Address" -c Port | awk '$2=="None"{print $1}' | head -1)
[ -z "$FIP" ] && FIP=$(OS floating ip create public -f value -c floating_ip_address)
OS server add floating ip web1 "$FIP" >/dev/null 2>&1
echo "$FIP" > /tmp/ex-web1-fip
for i in $(seq 1 30); do ssh $SSHO alpine@"$FIP" true 2>/dev/null && break; sleep 5; done
h=$(ssh $SSHO alpine@"$FIP" hostname 2>/dev/null)
[ "$h" = web1 ] && pass "ssh to web1 via $FIP" || fail "ssh to web1 (got '$h')"
OS console log show web1 2>/dev/null | grep -q 'Authorized keys from' \
  && pass "cloud-init injected the key" || fail "no key-injection line in the console log"
OS console log show web1 2>/dev/null | grep -q 'DataSourceOpenStack' \
  && pass "metadata datasource found" || fail "datasource line missing"

########## Exercise 4 -- persistent storage
step "Ex4 persistent storage"
OS volume show data1 >/dev/null 2>&1 || OS volume create --size 1 data1 >/dev/null
for i in $(seq 1 20); do [ "$(OS volume show data1 -f value -c status)" = available ] && break; sleep 3; done
OS server add volume web1 data1 >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show data1 -f value -c status)" = in-use ] && break; sleep 3; done
ssh $SSHO alpine@"$FIP" 'sudo mkfs.ext4 -F /dev/vdb >/dev/null 2>&1 && sudo mkdir -p /mnt/d && sudo mount /dev/vdb /mnt/d && echo persistent-data | sudo tee /mnt/d/proof.txt >/dev/null && sudo umount /mnt/d && echo ok' 2>/dev/null | grep -q ok \
  && pass "wrote proof.txt on the volume" || fail "could not write to the volume"
VID=$(OS volume show data1 -f value -c id)
rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring ls cinder-volumes 2>/dev/null | grep -q "volume-$VID" \
  && pass "volume is an RBD image in cinder-volumes" || fail "volume not visible in Ceph"

########## Exercise 5 -- snapshot and restore
step "Ex5 snapshot and restore"
OS server remove volume web1 data1 >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show data1 -f value -c status)" = available ] && break; sleep 3; done
OS volume snapshot show data1-snap >/dev/null 2>&1 || OS volume snapshot create --volume data1 data1-snap >/dev/null
for i in $(seq 1 20); do [ "$(OS volume snapshot show data1-snap -f value -c status)" = available ] && break; sleep 3; done
# cause the incident
OS server add volume web1 data1 >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show data1 -f value -c status)" = in-use ] && break; sleep 3; done
ssh $SSHO alpine@"$FIP" 'sudo mount /dev/vdb /mnt/d && sudo rm -f /mnt/d/proof.txt && sudo umount /mnt/d' 2>/dev/null
OS server remove volume web1 data1 >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show data1 -f value -c status)" = available ] && break; sleep 3; done
OS volume show data1-restored >/dev/null 2>&1 || OS volume create --snapshot data1-snap --size 1 data1-restored >/dev/null
for i in $(seq 1 20); do [ "$(OS volume show data1-restored -f value -c status)" = available ] && break; sleep 3; done
OS server add volume web1 data1-restored >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show data1-restored -f value -c status)" = in-use ] && break; sleep 3; done
r=$(ssh $SSHO alpine@"$FIP" 'sudo mount /dev/vdb /mnt/d && sudo cat /mnt/d/proof.txt && sudo umount /mnt/d' 2>/dev/null)
[ "$r" = persistent-data ] && pass "restored volume still has proof.txt" || fail "restore did not bring the file back (got '$r')"
OS server remove volume web1 data1-restored >/dev/null 2>&1

########## Exercise 6 -- grow a volume in use
step "Ex6 grow a volume"
OS volume set --size 2 data1 >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show data1 -f value -c size)" = 2 ] && break; sleep 3; done
OS server add volume web1 data1 >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show data1 -f value -c status)" = in-use ] && break; sleep 3; done
before=$(ssh $SSHO alpine@"$FIP" 'sudo mount /dev/vdb /mnt/d && df -h /mnt/d | tail -1 | awk "{print \$2}"' 2>/dev/null)
after=$(ssh $SSHO alpine@"$FIP" 'sudo resize2fs /dev/vdb >/dev/null 2>&1; df -h /mnt/d | tail -1 | awk "{print \$2}"; sudo umount /mnt/d' 2>/dev/null | head -1)
echo "    filesystem: $before -> $after"
[ "$before" != "$after" ] && pass "resize2fs grew the filesystem" || fail "filesystem did not grow ($before -> $after)"

# cleanup for Ex7
OS server remove volume web1 data1 >/dev/null 2>&1
sleep 5
OS volume snapshot delete data1-snap >/dev/null 2>&1; sleep 8
OS volume delete data1 data1-restored >/dev/null 2>&1
OS server delete web1 >/dev/null 2>&1; sleep 15

########## Exercise 7 -- network isolation
step "Ex7 network isolation"
OS security group show sg-web >/dev/null 2>&1 || {
  OS security group create sg-web --description frontend >/dev/null
  OS security group rule create --proto tcp --dst-port 80 sg-web >/dev/null
  OS security group rule create --proto tcp --dst-port 22 sg-web >/dev/null
}
OS security group show sg-backend >/dev/null 2>&1 || {
  OS security group create sg-backend --description backend >/dev/null
  OS security group rule create --proto tcp --dst-port 8080 --remote-group sg-web sg-backend >/dev/null
  OS security group rule create --proto tcp --dst-port 22 sg-backend >/dev/null
}
cat > /tmp/ud-web.yaml <<'UD'
#cloud-config
runcmd:
  - [ sh, -c, "mkdir -p /srv/www && echo '<h1>web frontend</h1>' > /srv/www/index.html" ]
  - [ sh, -c, "darkhttpd /srv/www --port 80 --daemon" ]
UD
cat > /tmp/ud-backend.yaml <<'UD'
#cloud-config
runcmd:
  - [ sh, -c, "mkdir -p /srv/www && echo 'backend-api-v1' > /srv/www/index.html" ]
  - [ sh, -c, "darkhttpd /srv/www --port 8080 --daemon" ]
UD
OS server show web >/dev/null 2>&1 || OS server create web --image lab-workload --flavor m1.lab \
  --network private --security-group sg-web --key-name labkey --user-data /tmp/ud-web.yaml >/dev/null
OS server show backend >/dev/null 2>&1 || OS server create backend --image lab-workload --flavor m1.lab \
  --network private --security-group sg-backend --key-name labkey --user-data /tmp/ud-backend.yaml >/dev/null
for n in web backend; do
  for i in $(seq 1 40); do [ "$(OS server show $n -f value -c status 2>/dev/null)" = ACTIVE ] && break; sleep 3; done
done
WIP=$(OS server show web -f value -c addresses | grep -oE '10\.0\.0\.[0-9]+' | head -1)
BIP=$(OS server show backend -f value -c addresses | grep -oE '10\.0\.0\.[0-9]+' | head -1)
WFIP=$(OS floating ip list -f value -c "Floating IP Address" -c Port | awk '$2=="None"{print $1}' | head -1)
[ -z "$WFIP" ] && WFIP=$(OS floating ip create public -f value -c floating_ip_address)
OS server add floating ip web "$WFIP" >/dev/null 2>&1
echo "$WFIP" > /tmp/ex-web-fip; echo "$WIP" > /tmp/ex-web-ip; echo "$BIP" > /tmp/ex-backend-ip
for i in $(seq 1 40); do ssh $SSHO alpine@"$WFIP" true 2>/dev/null && break; sleep 5; done
for i in $(seq 1 20); do
  r=$(ssh $SSHO alpine@"$WFIP" "wget -qO- --timeout 5 http://$BIP:8080/" 2>/dev/null)
  [ -n "$r" ] && break; sleep 6
done
[ "$r" = backend-api-v1 ] && pass "web -> backend:8080 allowed by the group rule" || fail "web could not reach backend:8080 (got '$r')"
# remove egress from sg-backend
for id in $(OS security group rule list sg-backend --egress -f value -c ID 2>/dev/null); do
  OS security group rule delete "$id" >/dev/null 2>&1
done
sleep 10
scp $SSHO "$K" alpine@"$WFIP":/home/alpine/k.pem >/dev/null 2>&1
out=$(ssh $SSHO alpine@"$WFIP" "chmod 600 ~/k.pem; ssh -i ~/k.pem -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 alpine@$BIP 'wget -qO- --timeout 8 http://$WIP:80/ 2>&1 || echo BLOCKED'" 2>/dev/null | tail -1)
[ "$out" = BLOCKED ] && pass "backend -> web:80 blocked with no egress" || fail "egress removal did not block (got '$out')"
r2=$(ssh $SSHO alpine@"$WFIP" "wget -qO- --timeout 8 http://$BIP:8080/" 2>/dev/null)
[ "$r2" = backend-api-v1 ] && pass "backend still serves web -- security groups are stateful" || fail "stateful reply broke (got '$r2')"

########## Exercise 8 -- floating IP failover
step "Ex8 floating IP failover"
h1=$(ssh $SSHO alpine@"$WFIP" hostname 2>/dev/null)
OS server remove floating ip web "$WFIP" >/dev/null 2>&1; sleep 5
OS server add floating ip backend "$WFIP" >/dev/null 2>&1; sleep 10
for i in $(seq 1 12); do h2=$(ssh $SSHO alpine@"$WFIP" hostname 2>/dev/null); [ -n "$h2" ] && break; sleep 5; done
echo "    $WFIP answered as '$h1', now '$h2'"
[ "$h1" = web ] && [ "$h2" = backend ] && pass "same address, different host" || fail "failover did not move the address"
# put it back on web for later exercises
OS server remove floating ip backend "$WFIP" >/dev/null 2>&1; sleep 5
OS server add floating ip web "$WFIP" >/dev/null 2>&1

fstrim / >/dev/null 2>&1 || true
printf '\n=========== Parts A-C: %s ===========\n' \
  "$( [ "$FAILED" -eq 0 ] && echo 'all checks passed' || echo "$FAILED CHECK(S) FAILED" )"
exit 0
