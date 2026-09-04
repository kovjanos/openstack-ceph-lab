#!/bin/bash
# Exercises 9-17 (Parts D, E, F): load balancing, shared storage, platform operations.
# Runs inside the VM as root, after ex-A-C.sh.
set +o pipefail

OS() { sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin exec openstack "$@"' _ "$@"; }
K=/etc/openstack-lab/labkey.pem
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILED=$((FAILED+1)); }
FAILED=0
step() { printf '\n--- [%s|%s] %s\n' "$(date '+%H:%M:%S')" "$(date +%s)" "$*"; }
lbwait() { # the guide says each part must reach ACTIVE before the next; poll, do not guess
  local i ps
  for i in $(seq 1 60); do
    ps=$(OS loadbalancer show lb1 -f value -c provisioning_status 2>/dev/null)
    [ "$ps" = ACTIVE ] && return 0
    [ "$ps" = ERROR ]  && return 1
    sleep 5
  done
  return 1
}
freefip() { local f; f=$(OS floating ip list -f value -c "Floating IP Address" -c Port | awk '$2=="None"{print $1}' | head -1)
            [ -z "$f" ] && f=$(OS floating ip create public -f value -c floating_ip_address); echo "$f"; }

########## Exercise 9 -- one address, two servers
step "Ex9 one address, two servers"
OS server delete web backend >/dev/null 2>&1; sleep 20
for n in 1 2; do
  cat > /tmp/ud-lb$n.yaml <<UD
#cloud-config
runcmd:
  - [ sh, -c, "mkdir -p /srv/www && echo 'server-web$n' > /srv/www/index.html" ]
  - [ sh, -c, "darkhttpd /srv/www --port 80 --daemon" ]
UD
  OS server show lb-web$n >/dev/null 2>&1 || OS server create lb-web$n --image lab-workload \
     --flavor m1.lab --network private --security-group sg-web --key-name labkey \
     --user-data /tmp/ud-lb$n.yaml >/dev/null
done
for n in 1 2; do for i in $(seq 1 40); do [ "$(OS server show lb-web$n -f value -c status 2>/dev/null)" = ACTIVE ] && break; sleep 3; done; done
IP1=$(OS server show lb-web1 -f value -c addresses | grep -oE '10\.0\.0\.[0-9]+' | head -1)
IP2=$(OS server show lb-web2 -f value -c addresses | grep -oE '10\.0\.0\.[0-9]+' | head -1)

OS loadbalancer show lb1 >/dev/null 2>&1 || OS loadbalancer create --name lb1 --vip-subnet-id private-subnet >/dev/null
t0=$(date +%s)
for i in $(seq 1 120); do
  ps=$(OS loadbalancer show lb1 -f value -c provisioning_status 2>/dev/null)
  [ "$ps" = ACTIVE ] && break; [ "$ps" = ERROR ] && break; sleep 6
done
echo "    load balancer reached $ps after $(( $(date +%s)-t0 ))s"
[ "$ps" = ACTIVE ] && pass "load balancer ACTIVE" || fail "load balancer is $ps"
amph=$(OS loadbalancer amphora list -f value -c role 2>/dev/null | sort | tr '\n' ' ')
echo "    amphora roles: $amph"
[ "$(OS loadbalancer amphora list -f value -c role 2>/dev/null | grep -c .)" -eq 2 ] \
  && pass "ACTIVE_STANDBY built two amphorae" || fail "expected two amphorae"

OS loadbalancer listener show web-listener >/dev/null 2>&1 || \
  OS loadbalancer listener create --name web-listener --protocol HTTP --protocol-port 80 lb1 >/dev/null
lbwait || fail "lb1 not ACTIVE after the listener"
OS loadbalancer pool show web-pool >/dev/null 2>&1 || \
  OS loadbalancer pool create --name web-pool --lb-algorithm ROUND_ROBIN --listener web-listener --protocol HTTP >/dev/null
lbwait || fail "lb1 not ACTIVE after the pool"
for ip in $IP1 $IP2; do
  OS loadbalancer member list web-pool -f value -c address 2>/dev/null | grep -q "$ip" || \
    OS loadbalancer member create --address "$ip" --protocol-port 80 --subnet-id private-subnet web-pool >/dev/null 2>&1
  lbwait || fail "lb1 not ACTIVE after adding a member"
done
OS loadbalancer healthmonitor show web-hm >/dev/null 2>&1 || \
  OS loadbalancer healthmonitor create --name web-hm --delay 5 --timeout 3 --max-retries 3 --type HTTP web-pool >/dev/null
lbwait || fail "lb1 not ACTIVE after the health monitor"

VIP_PORT=$(OS loadbalancer show lb1 -f value -c vip_port_id)
FIP=$(freefip); OS floating ip set --port "$VIP_PORT" "$FIP" >/dev/null 2>&1
echo "$FIP" > /tmp/ex-lb-fip
BFIP=$(freefip); OS server add floating ip lb-web1 "$BFIP" >/dev/null 2>&1
echo "$BFIP" > /tmp/ex-lbweb1-fip
echo "    VIP floating IP $FIP, lb-web1 at $BFIP"

for i in $(seq 1 30); do out=$(curl -s --max-time 5 "http://$FIP/"); [ -n "$out" ] && break; sleep 6; done
rr=$(for i in $(seq 1 10); do curl -s --max-time 5 "http://$FIP/"; done | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
echo "    round robin: $rr"
[ "$(for i in $(seq 1 10); do curl -s --max-time 5 "http://$FIP/"; done | sort -u | grep -c .)" -eq 2 ] \
  && pass "round robin hits both backends" || fail "round robin did not hit both"

for i in $(seq 1 30); do ssh $SSHO alpine@"$BFIP" true 2>/dev/null && break; sleep 5; done
ssh $SSHO alpine@"$BFIP" 'sudo pkill darkhttpd' 2>/dev/null
sleep 35
st=$(OS loadbalancer member list web-pool -f value -c address -c operating_status 2>/dev/null | grep "$IP1" | awk '{print $2}')
[ "$st" = ERROR ] && pass "health monitor ejected the dead backend" || fail "member status is '$st', expected ERROR"
only=$(for i in $(seq 1 8); do curl -s --max-time 5 "http://$FIP/"; done | sort -u | tr '\n' ' ')
echo "    serving now: $only"
ssh $SSHO alpine@"$BFIP" 'sudo darkhttpd /srv/www --port 80 --daemon' 2>/dev/null
sleep 35
both=$(for i in $(seq 1 8); do curl -s --max-time 5 "http://$FIP/"; done | sort -u | grep -c .)
[ "$both" -eq 2 ] && pass "health monitor re-admitted it" || fail "backend did not come back into the pool"

########## Exercise 10 -- sticky sessions
step "Ex10 sticky sessions"
OS loadbalancer pool set --session-persistence type=SOURCE_IP web-pool >/dev/null 2>&1; lbwait; sleep 6
n=$(for i in $(seq 1 8); do curl -s --max-time 5 "http://$FIP/"; done | sort -u | grep -c .)
[ "$n" -eq 1 ] && pass "SOURCE_IP pins one client to one backend" || fail "SOURCE_IP did not pin (saw $n backends)"
OS loadbalancer pool unset --session-persistence web-pool >/dev/null 2>&1; lbwait
OS loadbalancer pool set --session-persistence type=HTTP_COOKIE web-pool >/dev/null 2>&1; lbwait; sleep 6
rm -f /tmp/jar
one=$(for i in $(seq 1 6); do curl -s -b /tmp/jar -c /tmp/jar --max-time 5 "http://$FIP/"; done | sort -u | grep -c .)
[ "$one" -eq 1 ] && pass "HTTP_COOKIE keeps one jar on one backend" || fail "cookie did not stick (saw $one)"
many=$(for i in $(seq 1 6); do rm -f /tmp/j$i; curl -s -c /tmp/j$i --max-time 5 "http://$FIP/"; done | sort -u | grep -c .)
[ "$many" -ge 2 ] && pass "fresh jars get rebalanced" || fail "fresh jars all landed on one backend"
grep -q SRV /tmp/jar 2>/dev/null && pass "the LB inserted an SRV cookie ($(awk '/SRV/{print $NF}' /tmp/jar))" || fail "no SRV cookie"
OS loadbalancer pool unset --session-persistence web-pool >/dev/null 2>&1; lbwait

########## Exercise 11 -- the load balancer died
step "Ex11 the load balancer died"
AID=$(OS loadbalancer amphora list -f value -c id -c role | awk '$2=="MASTER"{print $1}')
CID=$(OS loadbalancer amphora show "$AID" -f value -c compute_id 2>/dev/null)
[ -n "$CID" ] && pass "found the MASTER's nova instance via amphora show" || fail "could not resolve compute_id"
OS server delete "$CID" >/dev/null 2>&1
gap=0; total=0
for i in $(seq 1 45); do
  r=$(curl -s --max-time 2 "http://$FIP/" 2>/dev/null); total=$((total+1))
  [ -z "$r" ] && gap=$((gap+1))
  sleep 2
done
echo "    $total requests through the VIP, $gap failed"
[ "$gap" -le 3 ] && pass "failover cost $gap of $total requests" || fail "$gap failed requests -- more than a failover should cost"
for i in $(seq 1 30); do
  OS loadbalancer amphora list -f value -c status 2>/dev/null | grep -qE 'BOOTING|PENDING' && break; sleep 10
done
OS loadbalancer amphora list -f value -c id -c role -c status 2>/dev/null | sed 's/^/    /'
OS loadbalancer amphora list -f value -c status 2>/dev/null | grep -qE 'BOOTING|PENDING|ALLOCATED' \
  && pass "octavia is rebuilding the pair on its own" || fail "no rebuild started"

# Exercise 11's cleanup, which the guide is explicit about: the load balancer and its
# backends go before Part E. Skipping it leaves six instances running into Exercise 12
# -- two amphorae, two lb-web and the two it is about to create -- and on a small
# cluster nova then refuses with "No valid host was found" for want of schedulable disk.
#
# Wait for ACTIVE first. Exercise 11 kills an amphora, so Octavia is still rebuilding
# the pair when this runs, and a delete against a PENDING_UPDATE load balancer is
# refused with a 409 that is easy to miss if stderr is thrown away.
lbwait || echo "    lb1 did not settle before delete; trying anyway"
for attempt in 1 2 3; do
  out=$(OS loadbalancer delete lb1 --cascade 2>&1)
  [ -n "$out" ] && echo "    delete attempt $attempt: $(echo "$out" | head -1 | cut -c1-90)"
  for i in $(seq 1 40); do OS loadbalancer show lb1 >/dev/null 2>&1 || break; sleep 6; done
  OS loadbalancer show lb1 >/dev/null 2>&1 || break
  lbwait || true
done
OS server delete lb-web1 lb-web2 >/dev/null 2>&1
for i in $(seq 1 30); do
  n=$(OS server list -f value -c Name 2>/dev/null | grep -c '^lb-web')
  [ "$n" = 0 ] && break; sleep 5
done
OS loadbalancer list -f value -c name 2>/dev/null | grep -q lb1 \
  && fail "lb1 still present going into Part E" || pass "load balancer and backends removed before Part E"
fstrim / >/dev/null 2>&1 || true
echo "    instances now: $(OS server list --all-projects -f value -c Name 2>/dev/null | tr '\n' ' ')"

########## Exercise 12 -- two workloads sharing one filesystem
step "Ex12 shared filesystem over NFS"
mkdir -p /mnt/labshare
mount -t nfs4 -o proto=tcp,port=2049,vers=4.1 127.0.0.1:/labshare /mnt/labshare 2>/dev/null \
  && { chmod 777 /mnt/labshare; pass "VM can mount the export"; } || fail "VM could not mount /labshare"
cat > /tmp/ud-share.yaml <<'UD'
#cloud-config
runcmd:
  - [ mkdir, -p, /srv/shared ]
  - [ sh, -c, "mount -t nfs4 -o proto=tcp,port=2049,vers=4.1 172.24.4.1:/labshare /srv/shared" ]
  - [ sh, -c, "darkhttpd /srv/shared --port 80 --daemon" ]
UD
for n in 1 2; do
  OS server show share$n >/dev/null 2>&1 || OS server create share$n --image lab-workload --flavor m1.lab \
    --network private --security-group sg-web --key-name labkey --user-data /tmp/ud-share.yaml >/dev/null
done
for n in 1 2; do for i in $(seq 1 40); do [ "$(OS server show share$n -f value -c status 2>/dev/null)" = ACTIVE ] && break; sleep 3; done; done
S2FIP=$(freefip); OS server add floating ip share2 "$S2FIP" >/dev/null 2>&1
echo "$S2FIP" > /tmp/ex-share2-fip
S1IP=$(OS server show share1 -f value -c addresses | grep -oE '10\.0\.0\.[0-9]+' | head -1)
sleep 60
echo "<h1>created by share1</h1>" > /mnt/labshare/index.html
for i in $(seq 1 20); do out=$(curl -s --max-time 5 "http://$S2FIP/"); [ -n "$out" ] && break; sleep 6; done
echo "    share2 served: $out"
[ "$out" = "<h1>created by share1</h1>" ] && pass "share2 serves a file it never wrote" || fail "shared filesystem not visible from share2"

########## Exercise 13 -- object storage
step "Ex13 object storage"
s3cmd -c /etc/openstack-lab/s3cfg mb s3://assets >/dev/null 2>&1
echo "served-from-ceph-object-storage" > /tmp/asset.txt
s3cmd -c /etc/openstack-lab/s3cfg put --acl-public /tmp/asset.txt s3://assets/asset.txt >/dev/null 2>&1
s3cmd -c /etc/openstack-lab/s3cfg ls s3://assets/ 2>/dev/null | grep -q asset.txt \
  && pass "object uploaded to the assets bucket" || fail "upload failed"
got=$(curl -s --max-time 8 "http://172.24.4.1:8100/assets/asset.txt")
[ "$got" = served-from-ceph-object-storage ] && pass "workload can read it with no credentials" || fail "path-style read failed (got '$got')"

########## Exercise 14 -- encryption at rest
step "Ex14 encryption at rest"
OS secret list >/dev/null 2>&1 && pass "barbican answers" || fail "barbican CLI not working"
OS volume type show LUKS >/dev/null 2>&1 || OS volume type create LUKS \
  --encryption-provider luks --encryption-cipher aes-xts-plain64 \
  --encryption-key-size 256 --encryption-control-location front-end >/dev/null
OS volume show secret-vol >/dev/null 2>&1 || OS volume create --size 1 --type LUKS secret-vol >/dev/null
for i in $(seq 1 20); do [ "$(OS volume show secret-vol -f value -c status)" = available ] && break; sleep 3; done
[ "$(OS volume show secret-vol -f value -c encrypted)" = True ] && pass "volume reports encrypted" || fail "volume not encrypted"
OS server add volume share1 secret-vol >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show secret-vol -f value -c status)" = in-use ] && break; sleep 3; done
S1FIP=$(freefip); OS server add floating ip share1 "$S1FIP" >/dev/null 2>&1
echo "$S1FIP" > /tmp/ex-share1-fip
for i in $(seq 1 30); do ssh $SSHO alpine@"$S1FIP" true 2>/dev/null && break; sleep 5; done
ssh $SSHO alpine@"$S1FIP" 'sudo mkfs.ext4 -F /dev/vdb >/dev/null 2>&1 && sudo mkdir -p /mnt/s && sudo mount /dev/vdb /mnt/s && echo TOPSECRET-CANARY-STRING | sudo tee /mnt/s/secret.txt >/dev/null && sudo sync && sudo cat /mnt/s/secret.txt' 2>/dev/null | grep -q TOPSECRET \
  && pass "guest reads its own canary back" || fail "could not write the canary"
VID=$(OS volume show secret-vol -f value -c id)
c=$(rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring export cinder-volumes/volume-$VID - 2>/dev/null | strings | grep -c 'TOPSECRET-CANARY-STRING')
[ "$c" = 0 ] && pass "canary is NOT in the raw RBD object" || fail "canary leaked into Ceph ($c hits)"
rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring export cinder-volumes/volume-$VID - 2>/dev/null | head -c 2000 | strings | grep -q LUKS \
  && pass "LUKS header is what is on disk" || fail "no LUKS header found"
# the guide's Ex14 cleanup: detach and delete secret-vol. Doing it here keeps the
# harness on the documented path, so Ex18's restored volume lands on vdb as written.
ssh $SSHO alpine@"$S1FIP" 'sudo umount /mnt/s' >/dev/null 2>&1
OS server remove volume share1 secret-vol >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(OS volume show secret-vol -f value -c status 2>/dev/null)" = available ] && break; sleep 3; done
OS volume delete secret-vol >/dev/null 2>&1
OS volume show secret-vol >/dev/null 2>&1 && fail "secret-vol not deleted" || pass "secret-vol detached and deleted (Ex14 cleanup)"

########## Exercise 15 -- Heat
step "Ex15 Heat"
cat > /tmp/webstack.yaml <<'YAML'
heat_template_version: 2021-04-16
parameters:
  message: { type: string, default: hello from heat }
  flavor:  { type: string, default: m1.lab }
resources:
  web_port:
    type: OS::Neutron::Port
    properties: { network: private, security_groups: [ sg-web ] }
  web_server:
    type: OS::Nova::Server
    properties:
      image: lab-workload
      flavor: { get_param: flavor }
      key_name: labkey
      networks: [ { port: { get_resource: web_port } } ]
      user_data_format: RAW
      user_data:
        str_replace:
          template: |
            #cloud-config
            runcmd:
              - [ sh, -c, "mkdir -p /srv/www && echo '<h1>$MSG</h1>' > /srv/www/index.html" ]
              - [ sh, -c, "darkhttpd /srv/www --port 80 --daemon" ]
          params: { $MSG: { get_param: message } }
  web_fip:
    type: OS::Neutron::FloatingIP
    properties: { floating_network: public, port_id: { get_resource: web_port } }
outputs:
  url:
    value:
      str_replace:
        template: http://IP/
        params: { IP: { get_attr: [ web_fip, floating_ip_address ] } }
YAML
OS stack show webstack >/dev/null 2>&1 || \
  OS stack create -t /tmp/webstack.yaml --parameter 'message=built by heat' webstack >/dev/null 2>&1
for i in $(seq 1 60); do
  ss=$(OS stack show webstack -f value -c stack_status 2>/dev/null)
  [ "$ss" = CREATE_COMPLETE ] && break; [ "$ss" = CREATE_FAILED ] && break; sleep 5
done
[ "$ss" = CREATE_COMPLETE ] && pass "stack $ss" || fail "stack $ss"
URL=$(OS stack output show webstack url -f value -c output_value 2>/dev/null)
echo "$URL" > /tmp/ex-heat-url
for i in $(seq 1 25); do got=$(curl -s --max-time 5 "$URL"); [ -n "$got" ] && break; sleep 6; done
echo "    $URL -> $got"
[ "$got" = "<h1>built by heat</h1>" ] && pass "the parameter reached cloud-init" || fail "stack output did not serve the message"
[ "$(OS stack resource list webstack -f value -c resource_name 2>/dev/null | grep -c .)" -eq 3 ] \
  && pass "three resources tracked as one unit" || fail "unexpected resource count"

# Exercise 15's cleanup: the stack owns an instance, and the guide deletes it here.
# Leaving it running carries an extra guest through every later exercise.
OS stack delete webstack --yes >/dev/null 2>&1
for i in $(seq 1 30); do OS stack show webstack >/dev/null 2>&1 || break; sleep 5; done
OS stack list -f value -c "Stack Name" 2>/dev/null | grep -q webstack \
  && fail "webstack still present" || pass "heat stack and its instance deleted"
fstrim / >/dev/null 2>&1 || true
echo "    instances now: $(OS server list -f value -c Name 2>/dev/null | tr '\n' ' ')"

########## Exercise 16 -- quotas
step "Ex16 quotas"
N=$(OS server list -f value -c Name | grep -c .)
OS quota set --instances "$N" admin >/dev/null 2>&1; sleep 3
err=$(OS server create over-quota --image lab-workload --flavor m1.lab --network private 2>&1 | tail -3)
echo "$err" | grep -qi 'quota' && pass "quota refuses the extra instance" || fail "no quota error (got: $(echo "$err" | head -1))"
OS quota set --instances 10 admin >/dev/null 2>&1
[ "$(OS quota show admin 2>/dev/null | awk '/\| instances /{print $4}')" = 10 ] && pass "quota restored to 10" || fail "quota not restored"

########## Exercise 17 -- a second tenant
step "Ex17 a second tenant"
OS project show demo-project >/dev/null 2>&1 || OS project create --domain default demo-project >/dev/null
OS user show demo-user >/dev/null 2>&1 || OS user create --domain default --password DemoPass123 --project demo-project demo-user >/dev/null
OS role add --project demo-project --user demo-user member >/dev/null 2>&1
OS quota set --instances 2 --cores 2 --ram 1024 demo-project >/dev/null 2>&1
cnt=$(sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && \
  OS_AUTH_URL=http://10.10.10.10:5000/v3 OS_USERNAME=demo-user OS_PASSWORD=DemoPass123 \
  OS_PROJECT_NAME=demo-project OS_USER_DOMAIN_NAME=Default OS_PROJECT_DOMAIN_NAME=Default \
  OS_IDENTITY_API_VERSION=3 openstack server list -f value' 2>/dev/null | grep -c .)
adm=$(OS server list -f value -c Name | grep -c .)
echo "    admin sees $adm instances, demo-user sees $cnt"
[ "$cnt" = 0 ] && [ "$adm" -gt 0 ] && pass "tenant isolation holds" || fail "demo-user saw $cnt instances"

fstrim / >/dev/null 2>&1 || true
printf '\n=========== Parts D-F: %s ===========\n' \
  "$( [ "$FAILED" -eq 0 ] && echo 'all checks passed' || echo "$FAILED CHECK(S) FAILED" )"
exit 0
