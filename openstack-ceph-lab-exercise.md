# OpenStack & Ceph Lab Exercises

Day-2 operations on the lab built by `openstack-ceph-lab-build.md`. Each exercise has a
reason to exist, a command-line walkthrough, the equivalent in the web UIs, and a
cleanup step saying what to remove and what to leave for the next one.

Everything here has been run on the lab as built. Where an exercise depends on
something the previous one created, it says so.

Screenshots of the web-UI side of each exercise are in
[`walkthrough/`](walkthrough/README.md), one file per exercise.

## Before you start

The lab must be up. From macOS:

```bash
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh --only 90-verify
```

That prints the current URLs and passwords — the VM's address changes on every start,
so take it from there rather than reusing an old one. Give it about 90 seconds after a
restart before judging anything.

Then get a shell in the VM and become the OpenStack client:

```bash
container machine run -n openstack-lab
sudo -i
```

Every `openstack` command below assumes this wrapper, which the lab's own scripts use:

```bash
OS() { sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && \
  OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=kolla-admin exec openstack "$@"' _ "$@"; }
```

Note the `"$@"` and the trailing `_ "$@"`. The obvious version — interpolating `$*`
into the quoted string — loses quoting, so any argument containing a space is split
and you get errors like `unrecognized arguments: heat webstack` from a perfectly valid
`--parameter 'message=built by heat'`.

Put it in your shell profile, or prefix commands with the long form. Ceph commands run
through `incus exec ceph-node1 -- cephadm shell --`.

**Three CLI plugins are missing by default.** Kolla's venv has no Heat, Barbican or
Octavia client, so `openstack stack ...`, `openstack secret ...` and
`openstack loadbalancer ...` are not openstack commands at all. The last one is the
most confusing, because the CLI answers with a list of `container ...` suggestions,
which reads like a broken load balancer rather than an absent client. Install them
once:

```bash
sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && \
  pip install python-heatclient python-barbicanclient python-octaviaclient'
```

(`provision-lab` installs the Octavia one for you when the load-balancer build is
enabled; the other two are always needed.)

## Reaching a workload from your own browser

Every `curl` in this guide runs **inside the VM**, where floating IPs work. From macOS
they do not: `172.24.4.x` lives behind `br-ex`, and the Mac has no route to it —
`route -n get 172.24.4.20` shows it heading for your LAN gateway instead, so the packets
leave the machine entirely.

That catches people out, because the management UIs *are* reachable from the Mac
(Horizon, the Ceph dashboard, Grafana, Prometheus, S3, NFS — all forwarded already). The
workloads you create are not.

To open one in your own browser, publish it on the VM's address:

```bash
lab-expose 18080 172.24.4.20     # then open http://<vm-ip>:18080/ on the Mac
lab-expose --list                # what is published now
lab-expose --clear               # remove them
```

`provision-lab --only 90-verify` prints the VM's address and repeats these three lines,
so you do not have to remember them.

**Adding a route on the Mac would also work** — `sudo route -n add -net 172.24.4.0/24
<vm-ip>` — and then floating IPs work directly, exactly as written in the exercises. It
needs sudo, does not survive a reboot, and points at a VM address that changes on every
machine start, so `lab-expose` is usually less trouble.

Neither is persistent. Floating IPs change from one exercise to the next anyway, so
re-run `lab-expose` rather than expecting it to stick.

---

## Resource budget — read this first

The exercises are sized for a **26 GB machine**, which is the default in
`02-build-image.sh`. That leaves roughly 13 GB for guests once Ceph, the OpenStack
control plane and Octavia have taken their share, and Ceph gives **14 GiB usable** after
3× replication.

| | |
|---|---|
| Lab guest | 512 MB RAM, 248 MB image — every workload exercise uses the same one |
| Concurrent guests | 3-4 on a 26 GB machine, more on 28-32 GB |
| 24 GB machine | Works, but build with `ENABLE_NETWORK_LOADBALANCER=no` and skip exercises 9–11 |

**512 MB is a hard floor for any guest.** Below it, aarch64 UEFI GRUB fails with
`error: out of memory` before Linux starts, and the console's next line —
`you need to load the kernel first` — makes it look like a broken image instead.

If your Mac has 48 GB, give the machine more and run the exercises with room to spare:

```bash
MACHINE_MEMORY=32G ./02-build-image.sh
```

Cleanup steps matter here. Several exercises say to keep what they built because a
later one uses it; the rest should be torn down or you will run out of memory.

## Running order

The exercises are ordered so that state built once is reused, rather than rebooting
instances for each. Peak cost is two guests (1 GB), or three guests plus two amphorae
(3 GB) across the load-balancing part — both fit the default 26 GB machine, and in fact
fit 24 GB with less room to spare.

| Part | Exercises | Running | Needs |
|---|---|---|---|
| **A. Foundation** | 1 bootstrap · 2 build the lab image | nothing | |
| **B. One workload** | 3 first workload · 4 persistent disk · 5 snapshot & restore · 6 grow a volume | 1 guest | |
| **C. Two workloads** | 7 network isolation · 8 floating-IP failover | 2 guests | |
| **D. Load balancing** | 9 one address two servers · 10 sticky sessions · 11 the load balancer died | 2 guests + 2 amphorae | LB build |
| **E. Shared storage** | 12 shared NFS · 13 object storage | 2 guests | |
| **F. Platform operations** | 14 encrypted volume · 15 Heat · 16 quotas · 17 projects & RBAC | 2 guests | |
| **G. Ceph day-2** | 18 maintenance mode · 19 restricted user · 20 failure drill · 21 disk replacement · 22 CephFS snapshots · 23 replication cost · 24 scrub · 25 monitoring · 26 node add/remove | 1 guest, kept deliberately | |
| **H. Recovery** | 27 full-cluster recovery · teardown | 1 guest | |

**Part D needs the load-balancer build, which is on by default.** The four Octavia
containers cost 1.4 GB all the time — ordinary here, where `neutron_server` alone is
0.9 GB — and the two amphorae cost 2 GB more, but only while Part D is running. Peak
observed, with a load balancer, two backends and three amphorae briefly alive during a
rebuild, was 19.9 GB.

That is why `02-build-image.sh` defaults to **26 GB**. The same run fits in 24 GB with
4.2 GB spare, which works but leaves little for anything else.

**To run on 24 GB**, build with `ENABLE_NETWORK_LOADBALANCER=no`. Everything except
exercises 9–11 works unchanged, and the end of Exercise 9 still teaches round-robin and
sticky sessions using HAProxy in a guest, for one extra instance. What it cannot teach
is Exercise 11.

Changing `MACHINE_MEMORY` recreates the machine, so decide before you build the lab
rather than after.

Exercise 9 retires the two guests from Part C before booting its own, and Exercise 11
tears the load balancer down before Part G. Following the order keeps the peak at the
figures above; skipping cleanups does not.

Part G keeps a workload running on purpose. Watching a web page keep serving while an
OSD is destroyed is the entire point of replication, and it costs nothing to leave one
512 MB instance up.

Do Part H last: filling the cluster disrupts everything else, and its cleanup is the
teardown anyway.

---

## Exercise 1 — Bootstrap the tenant

**The situation.** You have just been handed a freshly deployed cloud and told to
"get the first tenant onto it". The control plane is green, every service answers —
and a developer's first `openstack server create` fails, because there is no network,
no flavor, no image and no key to boot with. This is day one of every new region. Kolla ships an
`init-runonce` script that does this, but the image and defaults it installs do not
fit here, so the lab builds its own.

Everything later depends on this, so run it once and keep it.

```bash
# external (flat, on physnet1 -> br-ex) and the floating range
OS network create --external --provider-physical-network physnet1 \
  --provider-network-type flat public
OS subnet create public-subnet --network public --subnet-range 172.24.4.0/24 \
  --gateway 172.24.4.1 --allocation-pool start=172.24.4.10,end=172.24.4.200 --no-dhcp

# tenant network and a router joining the two
OS network create private
OS subnet create private-subnet --network private --subnet-range 10.0.0.0/24 \
  --dns-nameserver 8.8.8.8
OS router create r1
OS router set r1 --external-gateway public
OS router add subnet r1 private-subnet

# flavors -- 512 MB is the floor, see the budget section
OS flavor create m1.lab --ram 512 --vcpus 1 --disk 2

OS keypair create labkey > /etc/openstack-lab/labkey.pem
chmod 600 /etc/openstack-lab/labkey.pem
```

The image comes from Exercise 2. Everything else the lab needs is above.

**In the web UI.** Horizon → Project → Network → Networks / Routers, and
Compute → Images / Key Pairs. The external network needs admin rights, so create it
under Admin → Network → Networks with "External Network" ticked.

**Cleanup.** None — everything here is the foundation for what follows.

---

## Exercise 2 — Build the lab's own image

**The situation.** Your users keep booting a 3.5 GB distro image to run a 2 MB
service, and your Ceph cluster is filling up. Someone asks for an NFS client that the
tiny image doesn't have. The answer in every real cloud is the same: publish a small,
opinionated image with the tooling baked in, and point everyone at it.

Building your own is a normal operator task, and here it is also a capacity decision —
see the warning at the end. Alpine hits the balance this lab needs: 248 MB, boots in a
512 MB flavor, and has real packages, so one image covers every workload exercise. But
the stock image needs two fixes before OpenStack can use it.

```bash
cd /tmp
curl -sSLO https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/nocloud_alpine-3.21.2-aarch64-uefi-cloudinit-r0.qcow2
qemu-img convert -f qcow2 -O raw nocloud_alpine-*.qcow2 lab-workload.raw

LO=$(losetup --find --show -P lab-workload.raw)
mkdir -p /mnt/alp && mount ${LO}p2 /mnt/alp
```

**Fix 1 — the datasource.** The `nocloud_` variant pins cloud-init to NoCloud only, so
ConfigDrive is never tried, no SSH key is injected and you cannot log in:

```bash
grep -n 'datasource_list' /mnt/alp/etc/cloud/cloud.cfg      # line 105 overrides it
sed -i '105s/.*/datasource_list: ["ConfigDrive", "OpenStack", "NoCloud", "None"]/' \
  /mnt/alp/etc/cloud/cloud.cfg
```

**Fix 2 — the packages.** Alpine ships `doas` not `sudo`, and its busybox has no
`httpd` applet, so `busybox httpd` fails with `applet not found`:

```bash
cp /etc/resolv.conf /mnt/alp/etc/resolv.conf
for d in proc sys dev; do mount --bind /$d /mnt/alp/$d; done
echo "https://dl-cdn.alpinelinux.org/alpine/v3.21/community" >> /mnt/alp/etc/apk/repositories
chroot /mnt/alp /sbin/apk update
chroot /mnt/alp /sbin/apk add nfs-utils e2fsprogs dosfstools curl darkhttpd sudo
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /mnt/alp/etc/sudoers.d/wheel

for d in proc sys dev; do umount /mnt/alp/$d; done
rm -f /mnt/alp/etc/resolv.conf
umount /mnt/alp && losetup -d $LO
```

The chroot works because the VM and the image are both aarch64 — no emulation needed.

```bash
OS image create lab-workload --file /tmp/lab-workload.raw --disk-format raw \
  --container-format bare --public --property hw_firmware_type=uefi
```

**Mind the capacity.** Glance stores raw images **unsparsed**, and Ceph replicates
three times, so an image costs `size × 3` of raw cluster space. This 248 MB image costs
744 MB, while a 3.5 GB distro image would cost 10.5 GB — a quarter of a 45 GiB cluster
for one image. That is the whole reason to build a small one. Check before uploading
anything large:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph df
```

**In the web UI.** Horizon → Project → Compute → Images → Create Image, then upload the
raw file. The customisation has to happen before upload; Horizon cannot edit an image.

**Cleanup.** Keep `lab-workload` — every workload exercise from here uses it. You can
delete `/tmp/*.raw` and `/tmp/*.qcow2` once the upload is confirmed `active`.

---

## Exercise 3 — A first workload

**The situation.** A developer opens a ticket: "I launched an instance, it says
ACTIVE, but I can't reach it." Before you can debug anyone else's workload you need a
known-good one of your own — booted, addressed, and logged into — so you can tell the
difference between a broken cloud and a broken application.

```bash
OS server create web1 --image lab-workload --flavor m1.lab \
  --network private --key-name labkey --config-drive true
OS server list

FIP=$(OS floating ip create public -f value -c floating_ip_address)
OS server add floating ip web1 "$FIP"
ssh -i /etc/openstack-lab/labkey.pem alpine@"$FIP"
```

Boot takes about 15 seconds, and SSH is answering within about 80. If the instance is `ACTIVE` but unreachable, read the
console before anything else — it is almost always visible there:

```bash
OS console log show web1 | tail -20
```

A healthy boot shows the network coming up properly:

```
eth0: waiting for carrier
eth0: carrier acquired
checking http://169.254.169.254/2009-04-04/instance-id
```

### Where does configuration actually come from?

OpenStack has no ConfigMap, but it has the same idea in two places, and both are
visible from inside the guest. This is worth doing once so the mechanism stops being
magic:

```bash
# on web1
curl -s http://169.254.169.254/openstack/latest/meta_data.json | head -20
curl -s http://169.254.169.254/openstack/latest/user_data
curl -s http://169.254.169.254/latest/meta-data/hostname
```

`meta_data.json` carries the hostname, the SSH keys and any `--property` you set on the
server; `user_data` is exactly the cloud-config you passed at boot. Anything you would
put in a ConfigMap goes in one of those two.

There are two ways cloud-init can obtain this, and which one you get matters:

- **the metadata service** at `169.254.169.254`, reached over the network — what this
  lab actually uses
- **a config drive**, a small read-only disk attached to the instance, requested with
  `--config-drive true` — useful when the network is not up early enough

Both are listed in the image's `datasource_list`, which is precisely what Exercise 2
had to fix: the stock Alpine image pinned it to `NoCloud`, so neither was tried and no
SSH key was ever injected.

Add your own metadata to a running instance and read it back:

```bash
OS server set --property role=frontend --property tier=web web1
curl -s http://169.254.169.254/openstack/latest/meta_data.json | grep -A3 '"meta"'
```

**In the web UI.** Horizon → Project → Compute → Instances → Launch Instance. The
floating IP is under the instance's dropdown → Associate Floating IP. Metadata is under
the instance → Update Metadata.

**Cleanup.** Keep `web1` — Exercise 4 attaches a volume to it.

---

## Exercise 4 — Persistent storage that outlives the instance

**The situation.** An instance is deleted — by an autoscaler, by mistake, by someone
cleaning up — and the database that lived on its root disk goes with it. The fix is
not "be more careful": it is to keep state on a volume that outlives any instance, and
can be re-attached elsewhere. This exercise proves the data survives the instance.

```bash
OS volume create --size 1 data1
OS volume list
```

It is a real RBD image in Ceph, which you can see from the storage side:

```bash
rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring ls cinder-volumes
# volume-703ed2f5-7e2f-4abd-8688-82f05eba374b
```

Attach it and put a filesystem on it:

```bash
OS server add volume web1 data1
ssh -i /etc/openstack-lab/labkey.pem alpine@"$FIP"
  sudo mkfs.ext4 -F /dev/vdb
  sudo mkdir -p /mnt/d && sudo mount /dev/vdb /mnt/d
  echo persistent-data | sudo tee /mnt/d/proof.txt
  sudo umount /mnt/d
```

Now the point of the exercise — move the data to a different host:

```bash
OS server remove volume web1 data1
OS server add volume backend data1
# on backend:
sudo mount /dev/vdb /mnt/d && sudo cat /mnt/d/proof.txt
# persistent-data
```

The file is there, on an instance that never wrote it — the volume, not the instance,
is where the data lives. Timings on this lab: detach 9s, reattach 6s.

**In the web UI.** Horizon → Project → Volumes → Volumes → Create Volume, then Manage
Attachments. Extend and Snapshot are on the same dropdown.

**Cleanup.** Keep `data1` — Exercise 5 snapshots it. Detach it first:
`OS server remove volume backend data1`.

---

## Exercise 5 — Snapshot and restore

**The situation.** Someone runs the wrong command and deletes production data at
16:40 on a Friday. There is no backup job, but there is a snapshot from this morning.
How fast can you get the file back, and what does it cost you to have taken it?

Snapshots on RBD are copy-on-write: taking one is near-instant and costs no space
until the data diverges. That is why "snapshot before you touch it" is a reasonable
habit here in a way it is not on a traditional array.

```bash
OS server remove volume web1 data1          # a volume must be detached to snapshot
OS volume snapshot create --volume data1 data1-snap
OS volume snapshot list
```

Now cause the incident, then recover from the snapshot into a **new** volume — the
original is left untouched, which is what you want while you work out what happened:

```bash
# delete the file on the original volume, then:
OS volume create --snapshot data1-snap --size 1 data1-restored
OS server add volume web1 data1-restored
sudo mount /dev/vdb /mnt/d && sudo cat /mnt/d/proof.txt
# persistent-data
```

Measured here: snapshot 3s, restore-to-new-volume 3s, attach 6s.

**In the web UI.** Horizon → Project → Volumes → Snapshots. "Create Volume" from a
snapshot is on the snapshot's dropdown.

**Cleanup.** Delete `data1-restored`; keep `data1` and `data1-snap` — Exercise 6
grows `data1`.

---

## Exercise 6 — Grow a volume that is already in use

**The situation.** Monitoring pages you: a volume is at 95%. The application cannot be
stopped. You need more space now, and a maintenance window is not on offer.

```bash
OS server remove volume web1 data1
OS volume set --size 2 data1
OS server add volume web1 data1
```

The RBD image is bigger immediately, but the guest's filesystem is not — it still
believes it is 1 GiB. That second step is the one people forget:

```bash
sudo mount /dev/vdb /mnt/d
df -h /mnt/d                 # still the old size
sudo resize2fs /dev/vdb      # ext4; use resize.f2fs, xfs_growfs etc. to match
df -h /mnt/d                 # now 2 GiB
```

"I extended the volume and nothing changed" is one of the most common storage tickets
in any cloud, and it is always this.

**In the web UI.** Horizon → Project → Volumes → the volume's dropdown → Extend Volume.
The filesystem resize still has to happen inside the guest.

**Cleanup.** Detach and delete `data1`, `data1-snap` and `data1-restored`; Exercise 7
needs the memory, not the disk.

---

## Exercise 7 — Network isolation between a frontend and a backend

**The situation.** A security review asks a simple question: "if the web tier is
compromised, what can it reach?" You need to show that the backend accepts traffic
only from the frontend, and — the part people forget — that a compromised backend
cannot call back out to arbitrary hosts.

Two security groups, and the rule that matters is scoped to a **group**, not an IP
range, so it keeps working as instances come and go:

```bash
OS security group create sg-web
OS security group create sg-backend

OS security group rule create --proto tcp --dst-port 80 sg-web
OS security group rule create --proto tcp --dst-port 22 sg-web

# 8080 open ONLY to members of sg-web
OS security group rule create --proto tcp --dst-port 8080 --remote-group sg-web sg-backend
OS security group rule create --proto tcp --dst-port 22 sg-backend
```

Boot one of each, serving something identifiable:

```bash
cat > /tmp/ud-web.yaml <<'EOF'
#cloud-config
runcmd:
  - [ sh, -c, "mkdir -p /srv/www && echo '<h1>web frontend</h1>' > /srv/www/index.html" ]
  - [ sh, -c, "darkhttpd /srv/www --port 80 --daemon" ]
EOF
cat > /tmp/ud-backend.yaml <<'EOF'
#cloud-config
runcmd:
  - [ sh, -c, "mkdir -p /srv/www && echo 'backend-api-v1' > /srv/www/index.html" ]
  - [ sh, -c, "darkhttpd /srv/www --port 8080 --daemon" ]
EOF

OS server create web --image lab-workload --flavor m1.lab --network private \
  --security-group sg-web --key-name labkey --user-data /tmp/ud-web.yaml
OS server create backend --image lab-workload --flavor m1.lab --network private \
  --security-group sg-backend --key-name labkey --user-data /tmp/ud-backend.yaml
```

### Test it in both directions

From `web`, reaching the backend works — the rule matches because `web` is in `sg-web`:

```bash
# on web
wget -qO- http://<backend-internal-ip>:8080/
# backend-api-v1
```

Now the reverse. Note what is **not** the control here: `web` serves port 80 to the
world, so an ingress rule will not stop the backend reaching it. What stops it is
**egress**:

```bash
# remove the default allow-all egress from sg-backend
OS security group rule list sg-backend --egress -f value -c ID
OS security group rule delete <each-id>
```

```bash
# on backend
wget -qO- --timeout 6 http://<web-internal-ip>:80/
# wget: download timed out
```

**The lesson worth keeping.** `backend` now has *zero* egress rules, yet it still
serves `web` perfectly. Security groups are **stateful**: replies to an allowed
inbound connection are always permitted. So you can stop a service initiating
connections without stopping it doing its job — which is exactly what you want from a
compromised-backend scenario.

### Watch a rule take effect live

Rules apply to running instances immediately; no reboot, no re-attach:

```bash
OS security group rule create --proto tcp --dst-port 8080 --remote-ip 0.0.0.0/0 sg-backend
# backend:8080 is now reachable from anywhere -- verify, then remove it again
OS security group rule delete <id>
```

**In the web UI.** Horizon → Project → Network → Security Groups → Manage Rules. The
"Remote Security Group" field is the group-scoped rule used above.

**Cleanup.** Keep both instances and both groups — Exercises 8, 9 and 10 use them.

---

## Exercise 8 — Move a service between hosts with a floating IP

**The situation.** A host needs urgent maintenance, or an instance has gone bad, and
the service it fronts has to keep answering on the address your users and DNS already
know. You do not have a load balancer yet. What you do have is a floating IP, which is
just NAT you control.

With `web` and `backend` from Exercise 7 still running:

```bash
VIP=$(OS floating ip list -f value | awk '$3!="None"{print $2}' | head -1)
ssh -i /etc/openstack-lab/labkey.pem alpine@$VIP hostname     # web
```

Move it. Two commands, no reboot, no reconfiguration of either instance:

```bash
OS server remove floating ip web "$VIP"
OS server add    floating ip backend "$VIP"
```

```bash
ssh -i /etc/openstack-lab/labkey.pem alpine@$VIP hostname     # backend
```

The same address, a different machine, in about ten seconds. This is the crude version
of what Octavia would do for you — and it is genuinely how small clouds handle
failover before they have LBaaS.

**Watch out for orphans.** A floating IP released from a deleted instance stays
allocated to your project and keeps consuming quota. They accumulate invisibly:

```bash
OS floating ip list -f value | awk '$3=="None"{print $1}'     # unattached
OS floating ip list -f value | awk '$3=="None"{print $1}' | xargs -r -n1 \
  sudo -u kolla ... openstack floating ip delete
```

**In the web UI.** Horizon → Project → Compute → Instances → the instance's dropdown →
Associate / Disassociate Floating IP.

**Cleanup.** Leave the floating IP wherever you like. Exercise 9 retires `web` and
`backend` and boots a matched pair in their place, so nothing here needs keeping.

---

## Exercise 9 — One address, two servers

> **Needs the load-balancer build**, which is on by default. If you built with
> `ENABLE_NETWORK_LOADBALANCER=no`, either add it with
> `ENABLE_NETWORK_LOADBALANCER=yes provision-lab --from 70-kolla`, or read the
> **Without a load balancer** section at the end, which teaches the same thing with
> HAProxy in a guest.

**The situation.** One web server is a single point of failure and a capacity ceiling.
You add a second, and immediately have two new problems: which address do users type,
and what happens when one of the two dies at 3am? A floating IP moved by hand
(Exercise 8) solves the first and not the second. This is the version that solves both.

Exercise 8 left `web` and `backend` running. They serve different things on different
ports, which is not what a load balancer pool wants — two interchangeable servers are.
Retire them and boot a matched pair:

```bash
OS server delete web backend

for n in 1 2; do
  cat > /tmp/ud-lb$n.yaml <<EOF
#cloud-config
runcmd:
  - [ sh, -c, "mkdir -p /srv/www && echo 'server-web$n' > /srv/www/index.html" ]
  - [ sh, -c, "darkhttpd /srv/www --port 80 --daemon" ]
EOF
  OS server create lb-web$n --image lab-workload --flavor m1.lab --network private \
    --security-group sg-web --key-name labkey --user-data /tmp/ud-lb$n.yaml
done
```

Each serves its own name, which is the whole trick — you can see which one answered.

### The load balancer

```bash
OS loadbalancer create --name lb1 --vip-subnet-id private-subnet
OS loadbalancer show lb1 -f value -c provisioning_status
```

It sits in `PENDING_CREATE` for a while: Octavia is booting **two** amphorae, each a
real instance running HAProxy. Measured here: **4 minutes 30 seconds** to `ACTIVE`. Two,
not one, because the lab sets `octavia_loadbalancer_topology: ACTIVE_STANDBY` — which
Exercise 11 exists to justify.

```bash
OS loadbalancer amphora list
```

```
| id        | status    | role   | lb_network_ip | ha_ip      |
| 6371c403… | ALLOCATED | MASTER | 10.1.0.130    | 10.0.0.162 |
| d822204b… | ALLOCATED | BACKUP | 10.1.0.35     | 10.0.0.162 |
```

Two amphorae, one `ha_ip`. That shared address is the VIP, and VRRP decides which of
them currently holds it.

Now the parts that carry traffic. Each has to reach `ACTIVE` before the next is
accepted, so this is a sequence, not a batch — `openstack loadbalancer show lb1` in
between if a command is refused:

```bash
OS loadbalancer listener create --name web-listener --protocol HTTP --protocol-port 80 lb1
OS loadbalancer pool create --name web-pool --lb-algorithm ROUND_ROBIN \
  --listener web-listener --protocol HTTP

for ip in <lb-web1-ip> <lb-web2-ip>; do
  OS loadbalancer member create --address "$ip" --protocol-port 80 \
    --subnet-id private-subnet web-pool
done

OS loadbalancer healthmonitor create --name web-hm --delay 5 --timeout 3 \
  --max-retries 3 --type HTTP web-pool
```

Then an address users can actually reach:

```bash
VIP_PORT=$(OS loadbalancer show lb1 -f value -c vip_port_id)
FIP=$(OS floating ip create public -f value -c floating_ip_address)
OS floating ip set --port "$VIP_PORT" "$FIP"
```

### Watch it balance

```bash
for i in $(seq 1 10); do curl -s http://$FIP/; done | sort | uniq -c
```

```
   5 server-web1
   5 server-web2
```

Five each. `ROUND_ROBIN` is doing exactly what it says, and neither backend has any
idea the other exists.

### Now kill one

This is the half that a hand-moved floating IP cannot do. `lb-web1` needs its own
address first, because the floating IP now belongs to the VIP and is no longer a way
into any backend:

```bash
BFIP=$(OS floating ip create public -f value -c floating_ip_address)
OS server add floating ip lb-web1 "$BFIP"
ssh -i /etc/openstack-lab/labkey.pem alpine@"$BFIP" 'sudo pkill darkhttpd'
```

Wait about 25 seconds — `--delay 5 --max-retries 3` means three consecutive failures
before ejection — then:

```bash
OS loadbalancer member list web-pool -f value -c address -c operating_status
for i in $(seq 1 10); do curl -s http://$FIP/; done | sort | uniq -c
```

```
10.0.0.76   ERROR
   10 server-web2
```

The dead backend is marked `ERROR` and every request goes to the survivor. **Nobody
was paged and no address changed.** Put it back and watch the reverse:

```bash
ssh -i /etc/openstack-lab/labkey.pem alpine@"$BFIP" 'sudo darkhttpd /srv/www --port 80 --daemon'
sleep 30
for i in $(seq 1 6); do curl -s http://$FIP/; done | sort | uniq -c    # 3 and 3
```

The health monitor re-admits it on its own. That is the difference between a load
balancer and a floating IP: one is a control loop, the other is a command you have to
remember to run.

**In the web UI.** Horizon → Project → Network → Load Balancers, with a create wizard
that walks listener → pool → members → monitor in one pass.

**Cleanup.** Keep everything — Exercises 10 and 11 use it.

### Without a load balancer

If you are running the smaller lab, the same two lessons are available for the price of
one extra guest. Boot a third instance and put HAProxy in front of the same two
backends:

```bash
cat > /tmp/ud-haproxy.yaml <<'EOF'
#cloud-config
packages: [ haproxy ]
write_files:
  - path: /etc/haproxy/haproxy.cfg
    content: |
      defaults
        mode http
        timeout connect 5s
        timeout client 30s
        timeout server 30s
      frontend fe
        bind *:80
        default_backend be
      backend be
        balance roundrobin
        cookie SRV insert indirect nocache
        server web1 <lb-web1-ip>:80 check cookie web1
        server web2 <lb-web2-ip>:80 check cookie web2
runcmd:
  - [ rc-service, haproxy, start ]
EOF
OS server create lb-manual --image lab-workload --flavor m1.lab --network private \
  --security-group sg-web --key-name labkey --user-data /tmp/ud-haproxy.yaml
```

`balance roundrobin` and `check` give you Exercise 9; the `cookie` line gives you
Exercise 10. What it does *not* give you is Exercise 11 — this HAProxy is a single
instance, and when it dies the service dies with it. That gap is the argument for
Octavia, and it is worth feeling rather than being told.

---

## Exercise 10 — The session that keeps logging out

> **Needs the load-balancer build** (on by default). The HAProxy variant at the end of
> Exercise 9 demonstrates the same thing with a `cookie` line.

**The situation.** A ticket arrives: "users get logged out at random". Nothing in the
application logs looks wrong, and it only started when you added the second server. The
application keeps session state in memory, round-robin sends alternate requests to the
other machine, and half of them arrive with a session the server has never heard of.

The real fix is to move session state out of the application. The fix you can ship this
afternoon is to make each client stick to one backend.

Octavia offers three kinds, and choosing wrongly is why this exercise exists.

### SOURCE_IP — and why your browser test will lie to you

```bash
OS loadbalancer pool set --session-persistence type=SOURCE_IP web-pool
sleep 15
for i in $(seq 1 8); do curl -s http://$FIP/; done | sort | uniq -c
```

```
   8 server-web2
```

Every request pinned to one backend. Now try to demonstrate it the obvious way — open a
second browser, or a private window, and reload. **It stays on the same backend**,
because the key is your source address and both windows share it.

That is not a broken demo, it is the property itself: `SOURCE_IP` treats everyone behind
one NAT, one office firewall or one corporate proxy as a single client. It pins them all
to one backend, and your careful round-robin becomes a single server with a spare.

### HTTP_COOKIE — the one that follows the browser

```bash
OS loadbalancer pool unset --session-persistence web-pool
OS loadbalancer pool set --session-persistence type=HTTP_COOKIE web-pool
sleep 15
```

One cookie jar, six requests — one browser session:

```bash
rm -f /tmp/jar
for i in $(seq 1 6); do curl -s -b /tmp/jar -c /tmp/jar http://$FIP/; done | sort | uniq -c
```

```
   6 server-web2
```

A fresh jar each time — six private windows:

```bash
for i in $(seq 1 6); do rm -f /tmp/j$i; curl -s -c /tmp/j$i http://$FIP/; done | sort | uniq -c
```

```
   3 server-web1
   3 server-web2
```

**This is the demo that works in a browser.** Load the page, reload as much as you like,
you stay put. Open a private window and you may well land on the other server.

To do it in your own browser rather than with `curl`, publish the VIP first —
`lab-expose 18080 $FIP` — and open `http://<vm-ip>:18080/`. See
[Reaching a workload from your own browser](#reaching-a-workload-from-your-own-browser).

### Look at the cookie

```bash
grep -v '^#' /tmp/jar
```

```
172.24.4.199  FALSE  /  FALSE  0  SRV  84075c31-93ae-4a79-9ff9-f3dc54596354
```

The value is the **member UUID**. Check it against the pool:

```bash
OS loadbalancer member list web-pool
```

So the cookie in your browser's devtools names the exact backend you are pinned to,
which turns "sticky sessions" from a diagram into something you can point at during an
incident. `APP_COOKIE` is the third option: the same idea, but keyed on a cookie the
application already sets, so the load balancer inserts nothing of its own.

**In the web UI.** Horizon → Load Balancers → the pool → Edit, where session persistence
is a dropdown with the same three values.

**Cleanup.** Leave persistence off for Exercise 11, so you can see requests alternate:
`OS loadbalancer pool unset --session-persistence web-pool`.

---

## Exercise 11 — The load balancer died

> **Needs the load-balancer build** (on by default), and specifically `ACTIVE_STANDBY`.
> With `SINGLE` topology there is one amphora, and this exercise is a plain outage.

**The situation.** You put a load balancer in front of two servers so that losing one
would not matter. Then someone asks the obvious question: what happens when the load
balancer itself dies? If the answer is "everything stops", you have moved the single
point of failure rather than removed it — which is exactly what the HAProxy-in-a-guest
version at the end of Exercise 9 does.

This lab runs `ACTIVE_STANDBY`, so there are two amphorae and a VRRP election between
them. Here is what that buys, measured.

```bash
OS loadbalancer amphora list -f value -c id -c role -c status -c lb_network_ip
```

```
6371c403…  MASTER  ALLOCATED  10.1.0.130
d822204b…  BACKUP  ALLOCATED  10.1.0.35
```

Find the Nova instance behind the MASTER. **`compute_id` is not a column of
`amphora list`** — it only appears in `amphora show`, and looking for it in the list is
the first thing that goes wrong here:

```bash
AID=$(OS loadbalancer amphora list -f value -c id -c role | awk '$2=="MASTER"{print $1}')
CID=$(OS loadbalancer amphora show "$AID" -f value -c compute_id)
```

Start polling in one shell:

```bash
while true; do curl -s --max-time 2 http://$FIP/ || echo '--- NO ANSWER ---'; sleep 2; done
```

Destroy the master in another — not a graceful shutdown, a hard delete, the way a
hypervisor failure would look:

```bash
OS server delete "$CID"
```

```
  2s server-web1
  4s --- NO ANSWER ---
  6s server-web2
```

**One failed request out of ninety.** The backup held the VIP within a single two-second
poll, and traffic carried on round-robining across both backends as though nothing had
happened.

Run it twice and you will probably get a different number. The second run here dropped
**nothing at all** — twelve consecutive polls, no gap — because VRRP completed the
switch inside the two seconds between requests. So the honest figure is "at most one
request, sometimes none", not a reliable constant. If you want to see the gap, poll
faster than you think you need to.

### The dashboard is behind the failure

Immediately after the kill, `openstack loadbalancer amphora list` still reports the
destroyed amphora as `ALLOCATED MASTER`, and the load balancer as `ACTIVE`, even though
its instance is already gone from `openstack server list`. Detection took about **45
seconds** here.

That gap is worth internalising: **the data plane had already failed over before the
control plane knew anything was wrong.** Traffic never depended on Octavia noticing —
VRRP between the two amphorae handled it, and Octavia's job was only to rebuild the
pair afterwards. A monitoring system watching `provisioning_status` would have reported
a healthy load balancer throughout a genuine hardware failure.

### It heals without being asked

```bash
OS loadbalancer amphora list -f value -c id -c role -c status
```

```
6371c403…  MASTER  PENDING_DELETE     <- the one you destroyed
d822204b…  BACKUP  ALLOCATED          <- now serving
de47ef65…  None    BOOTING            <- a replacement, unprompted
```

The health manager noticed the master stop reporting, promoted the backup, and started
building a new amphora to restore the pair. Nobody ran a command. `provisioning_status`
sits at `PENDING_UPDATE` while that happens, and `operating_status` stays `ONLINE`
throughout — worth reading carefully, because they answer different questions: one is
"is Octavia currently changing this", the other is "is it serving traffic".

### What it costs

Two amphorae at 1 GB each, and briefly three during a rebuild. Measured on this lab at
the peak: **19.6 GB used, 4.5 GB still available on a 24 GB machine**, with two 512 MB
backends and three amphorae alive at once. On the default 26 GB there is correspondingly
more room. That is the price of the answer to "what happens when the
load balancer dies", and it is why `octavia_loadbalancer_topology` is a setting rather
than a default.

**In the web UI.** Horizon shows the load balancer's status but not the amphorae behind
it — they live in Octavia's own service project. `openstack loadbalancer amphora list`
is the only view.

**Cleanup.** Delete the load balancer and its backends before Part E; Ceph day-2 wants
the memory:

```bash
OS loadbalancer delete lb1 --cascade
OS server delete lb-web1 lb-web2
```

`--cascade` removes the listener, pool, members and monitor with it. Without it the
delete is refused while children exist, which is the same lesson as Exercise 15's stack
delete: things that were created as a unit should be deleted as one.

---

## Exercise 12 — Two workloads sharing one filesystem

**The situation.** Two web servers must serve the same content. Copying files to both
is how content drifts and one server starts serving yesterday's page. You want one
filesystem, mounted by both, where a write on either is immediately visible to the
other — the classic shared-document-root problem.

The lab already has a CephFS export served over NFSv4 (Phase 8 of the build guide).
Both instances mount it at boot:

```bash
cat > /tmp/ud-share.yaml <<'EOF'
#cloud-config
runcmd:
  - [ mkdir, -p, /srv/shared ]
  - [ sh, -c, "mount -t nfs4 -o proto=tcp,port=2049,vers=4.1 172.24.4.1:/labshare /srv/shared" ]
  - [ sh, -c, "darkhttpd /srv/shared --port 80 --daemon" ]
EOF

OS server create share1 --image lab-workload --flavor m1.lab --network private \
  --security-group sg-web --key-name labkey --user-data /tmp/ud-share.yaml
OS server create share2 --image lab-workload --flavor m1.lab --network private \
  --security-group sg-web --key-name labkey --user-data /tmp/ud-share.yaml
```

**Why `172.24.4.1`?** That is the VM's own address on `br-ex`. Ganesha runs inside the
Ceph container on the Incus bridge, and an Incus proxy device republishes it on every
VM interface — so instances reach it through their default gateway with no extra
routing.

Confirm both mounted, then do the demonstration:

```bash
# on share1 -- write content share2 has never seen
echo "<h1>created by share1</h1>" > /srv/shared/index.html
```

```bash
# from anywhere -- ask share2 for it
wget -qO- http://<share2-floating-ip>/
# <h1>created by share1</h1>
```

`share2` is serving a file it never wrote. Write from `share2` and `share1` sees it
just as fast — the filesystem is the shared state, not either instance.

**Permissions.** NFSv4 maps unknown users to `nobody` (uid 4294967294), so a guest
writing into a freshly created export gets "Permission denied" while the operator's
own writes succeed. For a lab, open it up once from the VM:

```bash
mount -t nfs4 -o proto=tcp,port=2049,vers=4.1 127.0.0.1:/labshare /mnt/labshare
chmod 777 /mnt/labshare
umount /mnt/labshare
```

In production you would align UIDs or configure idmapping instead.

**In the web UI.** Nothing — this is Ceph and guest configuration, below the OpenStack
API. The share is visible in the Ceph dashboard under Filesystems.

**Cleanup.** Keep `share1` and `share2` for Exercise 13, then delete `share2`; a single
guest is enough from Exercise 14 onward.

---

## Exercise 13 — Object storage for a workload

**The situation.** An application needs somewhere to put user uploads, build
artefacts or static assets. Putting them on a volume means they are tied to one
instance and one availability zone. The answer is object storage — and the same Ceph
cluster already provides an S3 endpoint.

As the operator, publish an asset:

```bash
s3cmd -c /etc/openstack-lab/s3cfg mb s3://assets
echo "served-from-ceph-object-storage" > /tmp/asset.txt
s3cmd -c /etc/openstack-lab/s3cfg put --acl-public /tmp/asset.txt s3://assets/asset.txt
s3cmd -c /etc/openstack-lab/s3cfg ls s3://assets/
```

Then, from a workload, with no credentials and no S3 client at all:

```bash
# on share1
wget -qO- http://172.24.4.1:8100/assets/asset.txt
# served-from-ceph-object-storage
```

**Use path-style URLs.** s3cmd prints a "Public URL" in virtual-host form
(`http://assets.127.0.0.1:8100/asset.txt`) which needs wildcard DNS and will not
resolve here. `http://<host>:8100/<bucket>/<key>` always works.

For authenticated access from a workload, copy `/etc/openstack-lab/s3cfg` into the
instance — the credentials come from `radosgw-admin`, not from Keystone, because this
RGW is not registered as a Swift endpoint in this lab.

**In the web UI.** Ceph dashboard → Object Gateway → Buckets. Horizon has no view of
it, since the gateway is not registered in Keystone.

**Cleanup.** Keep the `assets` bucket — it costs almost nothing and Exercise 25 uses
the cluster's usage figures. Delete `share2` now:
`OS server delete share2`.

---

## Exercise 14 — Encryption at rest, with the key in Barbican

**The situation.** An auditor asks where the encryption keys for your tenant volumes
live, and whether an operator with access to the storage cluster could read customer
data. "The disks are encrypted" is not an answer until you can show *what* is
encrypted, *where* the key is, and that the ciphertext is what actually lands on disk.

Barbican stores the key; Cinder asks for it; the compute node does the LUKS encryption,
so Ceph only ever sees ciphertext.

First, prove the secret store works on its own:

```bash
OS secret store --name lab-demo --payload "s3cr3t-value"
OS secret list
OS secret get <secret-href> --payload
# s3cr3t-value
```

Now an encrypted volume type, and a volume using it:

```bash
OS volume type create LUKS \
  --encryption-provider luks --encryption-cipher aes-xts-plain64 \
  --encryption-key-size 256 --encryption-control-location front-end

OS volume create --size 1 --type LUKS secret-vol
OS volume show secret-vol -f value -c encrypted        # True
OS server add volume share1 secret-vol
```

Inside the guest it is an ordinary block device — that is the point:

```bash
sudo mkfs.ext4 -F /dev/vdb && sudo mkdir -p /mnt/s && sudo mount /dev/vdb /mnt/s
echo "TOPSECRET-CANARY-STRING" | sudo tee /mnt/s/secret.txt
sudo cat /mnt/s/secret.txt        # reads back fine
sudo sync
```

### The proof

Now look at the same volume from the storage side, as an operator with full Ceph
credentials would:

```bash
VID=$(OS volume show secret-vol -f value -c id)
rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring \
  export cinder-volumes/volume-$VID - | strings | grep -c 'TOPSECRET-CANARY-STRING'
# 0
```

Zero. The canary the guest just wrote and read is not in the raw object. What *is*
there is the LUKS header:

```bash
rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring \
  export cinder-volumes/volume-$VID - | head -c 2000 | strings | head -3
# LUKS
# xts-plain64
# sha256
```

Run the same `grep` against an unencrypted volume and you will find the string
immediately — that contrast is the exercise.

**`front-end` is the setting that matters.** It puts the encryption on the compute
node, so plaintext never crosses the network to Ceph. `back-end` would rely on the
storage layer instead.

**In the web UI.** Horizon → Admin → Volume → Volume Types → Create Encrypted Volume
Type. Barbican has no Horizon panel in this deployment.

**Cleanup.** Detach and delete `secret-vol`; keep the `LUKS` volume type and the
`lab-demo` secret, both of which cost nothing.

---

## Exercise 15 — Build the same thing declaratively with Heat

**The situation.** You built the web tier by hand in Exercise 7 and it worked. Now you
need it in three environments, reproducibly, and someone must be able to review the
change before it happens. Clicking through Horizon does not survive that. This is
where a template replaces a runbook.

```bash
cat > webstack.yaml <<'EOF'
heat_template_version: 2021-04-16
description: A web server with a floating IP, built declaratively.

parameters:
  message:
    type: string
    default: hello from heat
  flavor:
    type: string
    default: m1.lab

resources:
  web_port:
    type: OS::Neutron::Port
    properties:
      network: private
      security_groups: [ sg-web ]

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
          params:
            $MSG: { get_param: message }

  web_fip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network: public
      port_id: { get_resource: web_port }

outputs:
  url:
    value:
      str_replace:
        template: http://IP/
        params:
          IP: { get_attr: [ web_fip, floating_ip_address ] }
EOF

OS stack create -t webstack.yaml --parameter 'message=built by heat' webstack
OS stack show webstack -f value -c stack_status      # CREATE_COMPLETE in ~15s
OS stack output show webstack url -f value -c output_value
wget -qO- http://<that-ip>/
# <h1>built by heat</h1>
```

Three resources — port, server, floating IP — created in dependency order and tracked
as one unit:

```bash
OS stack resource list webstack
```

**This is the answer to "where do I put configuration?".** The `message` parameter
flows into cloud-init's user-data via `str_replace`, so the same template produces a
different deployment per environment without editing it. Parameters are your values
file; outputs are what other systems consume.

Change it and let Heat work out the difference:

```bash
OS stack update -t webstack.yaml --parameter 'message=updated in place' webstack
```

Then delete everything the stack owns in one command — no orphaned ports or floating
IPs, which is the other half of why templates beat runbooks:

```bash
OS stack delete --yes webstack
```

**In the web UI.** Horizon → Project → Orchestration → Stacks, with a template editor
and a resource topology view that is genuinely useful for seeing dependencies.

**Cleanup.** The `stack delete` above is the cleanup. Verify with
`OS server list` that the stack's instance is gone.

---

## Exercise 16 — Quotas, and the ticket that starts "I can't launch anything"

**The situation.** A team files a ticket: their pipeline has stopped, every
`server create` fails, and nothing in the logs looks broken. Nine times out of ten
they have hit a quota. Knowing how to read and raise one — and how to see what they
have actually consumed — is the most routine task in this list.

```bash
OS quota show admin | grep -E '\| (instances|cores|ram) '
```

Reproduce the failure deliberately. Set the limit to exactly what is running, then try
one more:

```bash
N=$(OS server list -f value -c Name | wc -l)
OS quota set --instances "$N" admin
OS server create over-quota --image lab-workload --flavor m1.lab --network private
```

```
ForbiddenException: 403: Quota exceeded for instances:
Requested 1, but already used 6 of 6 instances
```

That message names the resource, the request and the current usage — everything you
need to answer the ticket. Then raise it:

```bash
OS quota set --instances 10 admin
```

Quotas cover far more than instances — `cores`, `ram`, `volumes`, `gigabytes`,
`floating-ips`, `security-groups`. Floating IPs are the sneaky one, because they stay
allocated after the instance that used them is deleted (see Exercise 8).

**In the web UI.** Horizon → Admin → Compute → Overview shows usage; quotas are edited
under Identity → Projects → the project's dropdown → Modify Quotas.

**Cleanup.** Restore the quota to something sane. Nothing else to remove.

---

## Exercise 17 — A second tenant, and proving they cannot see each other

**The situation.** A new team wants onto your cloud. Before you say yes you need to be
able to demonstrate — not assert — that they cannot see or touch the existing team's
instances, and that they cannot consume the whole cluster.

```bash
OS project create --domain default demo-project
OS user create --domain default --password DemoPass123 --project demo-project demo-user
OS role add --project demo-project --user demo-user member
OS quota set --instances 2 --cores 2 --ram 1024 demo-project
```

Now log in as that user and look:

```bash
sudo -u kolla bash -lc '. /opt/kolla/venv/bin/activate && \
  OS_AUTH_URL=http://10.10.10.10:5000/v3 \
  OS_USERNAME=demo-user OS_PASSWORD=DemoPass123 \
  OS_PROJECT_NAME=demo-project \
  OS_USER_DOMAIN_NAME=Default OS_PROJECT_DOMAIN_NAME=Default \
  openstack server list'
```

The list is **empty**, even though the admin project has several instances running.
That is tenant isolation: same cloud, same hypervisor, same Ceph cluster, and no
visibility across the boundary.

The `member` role is deliberate — it can create and manage its own resources but
cannot see other projects or change quotas. Give it `admin` instead and the isolation
above disappears, which is worth trying once to see the difference.

**Images cross the boundary only if you let them.** `lab-workload` was created
`--public`, so the new project can boot it. A private image would need
`OS image add project` to be shared explicitly.

**In the web UI.** Horizon → Identity → Projects / Users. Log out and back in as
`demo-user` to see the same empty instance list.

**Cleanup.** Keep the project — Exercise 18 uses it, and an idle project costs nothing.

---

## Exercise 18 — Ceph maintenance mode

**The situation.** You need to reboot a storage node — a kernel update, a firmware
patch, moving a machine. The moment the OSD goes down Ceph will start re-replicating
several gigabytes to restore redundancy, and when the node comes back five minutes
later it will move it all again. That rebalance is pure waste, and on a busy cluster
it hurts.

`noout` tells Ceph "this OSD is coming back, don't reshuffle":

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd set noout
incus exec ceph-node1 -- cephadm shell -- ceph -s
```

```
health: HEALTH_WARN
        flags noout
```

The `HEALTH_WARN` is deliberate and useful — it is Ceph reminding you the cluster is
in a non-default state, so a forgotten `noout` shows up on every status check.

Do the maintenance — stop an OSD, restart it — and notice that no backfill starts.
Then always, always put it back:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd unset noout
incus exec ceph-node1 -- cephadm shell -- ceph -s | grep health    # HEALTH_OK
```

**Leaving `noout` set is a real outage waiting to happen**: a genuinely dead disk will
never be replaced automatically, and you will find out weeks later when a second one
fails. Related flags worth knowing: `norebalance`, `nobackfill`, `norecover` — same
idea, finer grained.

**In the web UI.** Ceph dashboard → Cluster → OSDs → Cluster-wide configuration.

**Cleanup.** Confirm `HEALTH_OK` and no flags before moving on.

---

## Exercise 19 — Scoping credentials with a restricted Ceph user

**The situation.** A monitoring tool, or a backup script, wants Ceph credentials. It
needs to read volumes; it has no business writing to them. Handing it `client.admin`
is the path of least resistance and exactly how a compromised monitoring box turns
into a destroyed cluster.

```bash
incus exec ceph-node1 -- cephadm shell -- ceph auth get-or-create client.readonly \
  mon 'profile rbd' \
  osd 'profile rbd-read-only pool=cinder-volumes'
```

Export the key to a keyring on the VM and use it:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph auth export client.readonly 2>&1 \
  | grep -E 'client.readonly|key =|caps ' > /tmp/ro.keyring
cp /tmp/ro.keyring /etc/ceph/ceph.client.readonly.keyring
chmod 600 /etc/ceph/ceph.client.readonly.keyring
```

```bash
KR="-n client.readonly --keyring /etc/ceph/ceph.client.readonly.keyring"
rbd $KR ls cinder-volumes           # works
rbd $KR create --size 10 cinder-volumes/should-fail
# rbd: create error: (1) Operation not permitted
```

Reading works, writing is refused by the cluster — not by the client, not by file
permissions, but by the capability attached to the credential. Compare it with the
credentials the lab already uses:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph auth ls | grep -A3 'client.glance'
```

`client.glance` can write to `glance-images` and nothing else; `client.cinder` has
read-only access to `glance-images` so Nova can clone images but cannot modify them.
That is the same principle applied to the services themselves.

**In the web UI.** Ceph dashboard → Cluster → Users shows the capabilities per entity.

**Cleanup.** `ceph auth del client.readonly` and remove the keyring, or keep it — it
can do no harm, which is the point.

---

## Exercise 20 — Lose a disk while the service is running

**The situation.** 03:00, a disk fails. The page says `HEALTH_WARN` and a third of your
objects are degraded. The question your manager will ask at 09:00 is not "what broke"
but "was anything down?" — and you want to have already watched the answer.

Keep a workload running for this. `share1` from Exercise 12 will do, serving a page you
can poll throughout.

```bash
incus exec ceph-node1 -- cephadm shell -- ceph -s | grep -E 'health|osd:'
# health: HEALTH_OK
# osd: 3 osds: 3 up, 3 in
```

Kill one:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph orch daemon stop osd.1
```

Within about 35 seconds:

```
health: HEALTH_WARN
osd: 3 osds: 2 up (since 35s), 3 in
pgs: 646/1938 objects degraded (33.333%)
```

**Read that number.** With `size = 3`, losing one OSD degrades exactly one third of
the replicas — 33.333% — and loses precisely nothing. Two copies of every object are
still online.

Now the part that matters:

```bash
wget -qO- http://<share1-floating-ip>/
# <h1>created by share1</h1>
rbd -n client.cinder --keyring /etc/ceph/ceph.client.cinder.keyring ls cinder-volumes
# still lists
```

The workload never noticed. Bring the disk back:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph orch daemon start osd.1
```

`HEALTH_OK` returned in **30 seconds** here, because the OSD was only briefly absent
and Ceph replayed the difference rather than recopying everything.

**In the web UI.** Ceph dashboard → Cluster → OSDs, and the health panel on the
landing page. Watching the degraded percentage fall in the dashboard is the clearest
version of this exercise.

**Cleanup.** Confirm `HEALTH_OK` and 3 OSDs up before continuing.

---

## Exercise 21 — Replace a failed disk properly

**The situation.** The disk from Exercise 20 is not coming back — it is genuinely
dead. You need to remove it from the cluster, put a new one in, and get back to full
redundancy. Doing this in the wrong order leaves half-states that block the
replacement, which is why it is worth rehearsing before it is urgent.

**Drain it first.** `out` moves data off while the OSD is still running, so redundancy
is restored *before* you remove anything:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd out osd.1
incus exec ceph-node1 -- cephadm shell -- ceph osd tree
#  1  hdd  0.01459  osd.1  up  0  1.00000     <- up, but weight 0
```

Then remove the daemon and the CRUSH entry:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph orch daemon stop osd.1
incus exec ceph-node1 -- cephadm shell -- ceph orch daemon rm  osd.1 --force
incus exec ceph-node1 -- cephadm shell -- ceph osd purge 1 --yes-i-really-mean-it
incus exec ceph-node1 -- cephadm shell -- ceph osd tree
# host ceph-node2 now has weight 0 and no OSDs
```

### The step everyone misses

The "new disk" here is the same LV, and it is **not** blank — `ceph-volume` left its
own LVM tags on it. Skip this and the re-add fails with the deeply unhelpful
`Created no osd(s) on host X; already created?`, because ceph-volume sees its own
tags and declines:

```bash
lvs --noheadings -o lv_name,lv_tags ceph-vg2/osd2      # ceph.block_device=..., ceph.osd_id=...

for t in $(lvs --noheadings -o lv_tags ceph-vg2/osd2 | tr ',' ' '); do
  lvchange --deltag "$t" ceph-vg2/osd2
done
dd if=/dev/zero of=/dev/ceph-vg2/osd2 bs=1M count=100 conv=fsync   # wipe the BlueStore label
lvs --noheadings -o lv_name,lv_tags ceph-vg2/osd2      # tags column now empty
```

Recreate the device nodes in the container, then add the disk back:

```bash
incus exec ceph-node2 -- bash -c 'rm -rf /dev/ceph-vg*/ /dev/mapper/ceph--*; dmsetup mknodes; vgmknodes'
incus exec ceph-node1 -- cephadm shell -- ceph orch daemon add osd ceph-node2:ceph-vg2/osd2
# Created osd(s) 1 on host 'ceph-node2'
```

`HEALTH_OK` returned in **15 seconds** here — the cluster is small and most data was
already on the surviving OSDs.

**Every failed attempt re-tags the LV**, so clear the tags again before each retry. If
an OSD id is left orphaned in the CRUSH map, `ceph osd purge <id> --yes-i-really-mean-it`
clears that too.

**In the web UI.** Ceph dashboard → Cluster → OSDs has Out / Down / Purge in the OSD's
menu. Creating an OSD from the dashboard needs a device the inventory can see, which
in this lab it cannot — see the note about `ceph orch device ls` in the build guide.

**Cleanup.** Confirm `HEALTH_OK` and 3 OSDs up and in.

---

## Exercise 22 — Filesystem snapshots that cost nothing

**The situation.** Someone is about to run a migration script against the shared
document root. You want a restore point, you want it in one command, and you do not
want to detach anything or stop the web servers.

Cinder snapshots (Exercise 5) need the volume detached. CephFS snapshots do not — they
are a directory you create.

The VM's kernel has no CephFS driver, so mount it with the userspace client:

```bash
apt-get update && apt-get install -y ceph-fuse
incus exec ceph-node1 -- cat /etc/ceph/ceph.client.admin.keyring > /etc/ceph/ceph.client.admin.keyring
chmod 600 /etc/ceph/ceph.client.admin.keyring
mkdir -p /mnt/cephfs && ceph-fuse -n client.admin /mnt/cephfs
```

**`apt-get update` first, always, in this VM.** The machine image ends with
`rm -rf /var/lib/apt/lists/*`, so a freshly built machine has no package lists and apt
answers `E: Unable to locate package` for anything you ask for — including packages
that certainly exist. It is not a broken mirror or a missing repository.

Now the whole feature:

```bash
mkdir /mnt/cephfs/.snap/before-migration       # this IS the snapshot
```

Cause the incident and recover:

```bash
rm -f /mnt/cephfs/index.html
ls /mnt/cephfs/                                # gone
ls /mnt/cephfs/.snap/before-migration/         # still there
cp /mnt/cephfs/.snap/before-migration/index.html /mnt/cephfs/
```

List and remove snapshots the same way:

```bash
ls /mnt/cephfs/.snap/
rmdir /mnt/cephfs/.snap/before-migration
```

`mkdir` to snapshot, `rmdir` to release. They are copy-on-write, so an idle snapshot
costs nothing and only diverging data consumes space — which makes "snapshot before
you touch it" a habit you can actually afford.

**The `.snap` directory is not visible over NFS.** Ganesha does not export it, so this
has to be done on a native CephFS mount, not from the guests using the share.

**In the web UI.** Ceph dashboard → File Systems → the filesystem → Snapshots, for
snapshots taken on subvolumes.

**Cleanup.** `umount /mnt/cephfs`. Leave the export and its contents — the guests are
still using it.

---

## Exercise 23 — What replication actually costs you

**The situation.** Someone asks for a 10 TB volume and you have 20 TB of disk. You have
to explain why the answer is no. Replication is the single biggest factor in what a
Ceph cluster can actually hold, and the arithmetic is worth doing once with real
numbers rather than in your head.

```bash
incus exec ceph-node1 -- cephadm shell -- ceph df
```

```
TOTAL           45 GiB   40 GiB avail
cinder-volumes  55 MiB stored   160 MiB used   MAX AVAIL 13 GiB
```

Three numbers matter: **stored** is your data, **used** is what it occupies after
replication (roughly 3×), and **MAX AVAIL** is what you can still write. On a 45 GiB
cluster at `size = 3` you have about 13 GiB of usable space, not 45.

**The clearest example is sitting in your own cluster.** Look at the images pool:

```
glance-images   2.8 GiB stored   8.3 GiB used   MAX AVAIL 11 GiB
```

Almost all of that is the amphora image from the load-balancer build — 2.5 GiB of
image, charged at 7.5 GiB of cluster. One file took the cluster from 6% to 22% full and
cost every other pool 2 GiB of MAX AVAIL, without anyone writing a byte of data. That
is the entire lesson, and it is why `lab-workload` is a 248 MB Alpine build rather than
a 3.5 GB distro image: that swap alone would cost 10.5 GiB here.

(Built with `ENABLE_NETWORK_LOADBALANCER=no`? Then `glance-images` holds only
`lab-workload`, your figures are smaller, and MAX AVAIL is correspondingly larger.)

Change it and watch:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd pool set cinder-volumes size 2
incus exec ceph-node1 -- cephadm shell -- ceph df
```

```
cinder-volumes  55 MiB stored   106 MiB used   MAX AVAIL 19 GiB
```

Usable space went from 13 GiB to 19 GiB, and the same data now occupies 106 MiB
instead of 160 MiB — purely by keeping two copies instead of three.

**Put it back.** `size = 2` means one disk failure leaves you with a single copy and
no redundancy at all while it recovers:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd pool set cinder-volumes size 3
```

This is also the answer to the capacity incident in Exercise 27: an image is charged
at `size × replication`, so a 3.5 GB image costs 10.5 GB of cluster.

**In the web UI.** Ceph dashboard → Pools shows size, usage and the same MAX AVAIL.

**Cleanup.** Verify every pool is back at `size 3`:
`ceph osd pool ls detail | grep -o 'size [0-9]'`.

---

## Exercise 24 — Verify the data is really intact

**The situation.** Ceph tells you `HEALTH_OK`, which means every object is *present*
and the right number of copies exist. It does not, by itself, mean the bytes are still
correct. Scrubbing is what checks that, and it is worth knowing how to trigger on
demand — after a power loss, or a disk that has been throwing errors.

```bash
PG=$(incus exec ceph-node1 -- cephadm shell -- ceph pg ls | awk 'NR==2{print $1}')
incus exec ceph-node1 -- cephadm shell -- ceph pg deep-scrub "$PG"
# instructing pg 1.0 on osd.1 to deep-scrub
```

A normal **scrub** compares object metadata and is cheap. A **deep-scrub** reads every
byte and compares checksums — it is the real integrity check, and it costs I/O, which
is why Ceph schedules them slowly in the background.

Watch the result:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph pg ls | head -3
incus exec ceph-node1 -- cephadm shell -- ceph -s
```

If a deep-scrub finds a mismatch the cluster goes `HEALTH_ERR` with
`X scrub errors` and `Possible data damage: N pg inconsistent`. The repair is:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph pg repair <pgid>
```

**Do not reach for `pg repair` reflexively.** It resolves the inconsistency by
trusting the primary copy, which is the right answer for a bit-flip on a replica and
the wrong one if the primary is the damaged copy. On a real cluster, find out which
disk is failing first.

**In the web UI.** Ceph dashboard → Pools → Placement Groups shows scrub state and
timestamps.

**Cleanup.** Nothing to remove.

---

## Exercise 25 — The monitoring you already have

**The situation.** You want graphs of cluster throughput and OSD latency, and you are
about to go and install Prometheus. You do not need to: `cephadm` deployed the whole
stack when it bootstrapped the cluster, and it has been scraping ever since.

```bash
incus exec ceph-node1 -- cephadm shell -- ceph orch ls | grep -E 'prometheus|grafana|alertmanager|exporter'
```

```
alertmanager   ?:9093,9094      1/1
ceph-exporter  ?:9926           3/3
grafana        ?:3000           1/1
node-exporter  ?:9100           3/3
prometheus     ?:9095           1/1
```

Five services, none of which you installed. `node-exporter` and `ceph-exporter` run on
every host; the other three run once.

### Reaching them from macOS

They listen on the Incus bridge, so each needs a proxy device the same way the
dashboard does. `90-verify` adds all three and prints the URLs:

```bash
provision-lab --only 90-verify
```

```
Ceph dashboard https://<VM_IP>:8443/    admin / ChangeMeBeforeUse
Grafana        https://<VM_IP>:3000/    embedded in the Ceph dashboard; self-signed
Prometheus     http://<VM_IP>:9095/
Alertmanager   http://<VM_IP>:9093/
```

**Visit `https://<VM_IP>:3000/` once and accept the certificate.** Grafana has its own
self-signed cert, separate from the dashboard's. The dashboard shows Grafana's graphs
in an iframe that your *browser* loads, so until the browser trusts that certificate
every "Overall Performance" tab is an empty grey box — with no error message, because
the dashboard never learns the browser refused it. This is the single most confusing
failure in the whole monitoring setup, and it takes one click to avoid.

### The graphs

With that done, the embedded panels work:

- **Cluster → Hosts → Overall Performance** — CPU, RAM and network per host
- **Cluster → OSDs → Overall Performance** — read/write latency percentiles, PG
  distribution, device class breakdown. The usual first stop when something is "slow"
- **Cluster → Pools → Overall Performance** — per-pool throughput, next to the MAX
  AVAIL from Exercise 23

Grafana on its own at `https://<VM_IP>:3000/dashboards` has about twenty pre-built Ceph
dashboards the embedded views only sample — *Ceph Cluster - Advanced*, *Ceph Pool
Details*, *OSD device details*, *RBD Details*, *MDS Performance*, *RGW Overview*. No
login needed: cephadm enables anonymous viewing so the iframes work, which means you
get them too.

### Where the numbers come from

`http://<VM_IP>:9095/targets` lists every scrape target and its state:

```
ceph            1 / 1 up     http://ceph-node1:9283/metrics
ceph-exporter   3 / 3 up     http://10.100.0.1{1,2,3}:9926/metrics
nfs             1 / 1 up     http://10.100.0.11:9587/metrics
node            3 / 3 up     http://10.100.0.1{1,2,3}:9100/metrics
```

If a Grafana panel is empty, check here before anything else — a panel with no data and
a target that is `DOWN` are the same fault, and this page names it.

The query browser at `http://<VM_IP>:9095/graph` takes PromQL directly. Two worth
trying, because they are the ones you end up writing during an incident:

```promql
ceph_osd_op_r_latency_sum / ceph_osd_op_r_latency_count
ceph_cluster_total_used_bytes / ceph_cluster_total_bytes
```

The first returns one series per OSD — average read latency in seconds, around 1 ms
here. The second returns a single number that should match the capacity donut on the
dashboard Overview exactly; if it does not, one of the two is reading stale data.

### Alerting

**Observability → Alerts** has three tabs. **Active Alerts** is empty on a healthy
cluster — that page working at all is the proof Alertmanager is wired up. **Alert
Rules** is the interesting one: 89 rules that Prometheus already evaluates, each with a
severity and a firing delay.

```
CephDaemonCrash             critical  generic        60s
CephDaemonSlowOps           warning   healthchecks   30s
CephDeviceFailurePredicted  warning   osd            60s
CephMonDown                 warning   mon            30s
CephOSDNearFull             warning   osd           300s
CephOSDFull                 critical  osd            60s
CephPGsDamaged              critical  pgs           300s
```

`CephOSDNearFull` fires at 85% after five minutes. That is the alert that would have
caught Exercise 27 while it was still recoverable, rather than at 95% when writes had
already stopped.

**Nothing is delivered, though.** Alertmanager has no receiver configured, so rules
fire into the dashboard and stop there. Wiring one up — email, a webhook, Slack — is a
`ceph orch` config change and the natural next step beyond this lab.

### Do it with something happening

Re-run the failure drill from Exercise 20 with **Cluster → OSDs** open. Watching the
degraded-object count climb and drain away, and the latency panel spike, is far more
legible than reading `ceph -s` in a loop — and it is how you will actually experience
the real thing.

**In the web UI.** All of it. This exercise is the web UI.

**Cleanup.** Nothing.

---

## Exercise 26 — Add a node, then take it away again

**The situation.** The cluster is filling up and you have budget for another storage
node. Later, that node is being decommissioned. Both directions are routine, and both
leave things behind if you stop at the obvious step — which is the real lesson here.

### Adding

A "new node" in this lab is a fourth disk plus a fourth Incus container:

```bash
truncate -s 8G /var/lib/ceph-disks/osd4.img
LOOP=$(losetup --find --show /var/lib/ceph-disks/osd4.img)
pvcreate -f "$LOOP" && vgcreate ceph-vg4 "$LOOP" && lvcreate -l 100%FREE -n osd4 ceph-vg4
setsid sh -c 'exec sleep infinity < /dev/ceph-vg4/osd4' &      # hold the LV open
```

The hold matters for the same reason as the `hold-osd` units in the build guide: stop
the container without it and device-mapper tears the mapping down.

```bash
incus launch ceph-node-base ceph-node4 -c security.privileged=true
incus stop ceph-node4
incus config device override ceph-node4 eth0 ipv4.address=10.100.0.14
incus config set ceph-node4 boot.autostart false

DM=$(dmsetup ls | awk '$1=="ceph--vg4-osd4"{gsub(/[()]/,"",$2); split($2,a,":"); print a[2]}')
incus config device add ceph-node4 dm-control unix-char path=/dev/mapper/control source=/dev/mapper/control
incus config device add ceph-node4 pv-disk    unix-block path=$LOOP source=$LOOP
incus config device add ceph-node4 dm3        unix-block path=/dev/dm-$DM source=/dev/dm-$DM
incus config set ceph-node4 raw.lxc "lxc.mount.auto = sys:rw
lxc.apparmor.profile = unconfined"
incus start ceph-node4
```

Give cephadm its key, then add the host and the disk:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph cephadm get-pub-key | grep '^ssh-' > /tmp/cephkey
incus exec ceph-node4 -- mkdir -p /root/.ssh
cat /tmp/cephkey | incus exec ceph-node4 -- tee /root/.ssh/authorized_keys
incus exec ceph-node4 -- chmod 600 /root/.ssh/authorized_keys

incus exec ceph-node1 -- cephadm shell -- ceph orch host add ceph-node4 10.100.0.14
incus exec ceph-node1 -- cephadm shell -- ceph orch daemon add osd ceph-node4:ceph-vg4/osd4
# Created osd(s) 3 on host 'ceph-node4'
```

Watch it take load — `11 remapped pgs` while Ceph rebalances onto the new disk:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd tree
# -9  0.00780  host ceph-node4
#  3  hdd  0.00780  osd.3  up  1.00000
```

The weight (0.00780 for 8 GB vs 0.01459 for 15 GB) is how Ceph knows to give the
smaller disk proportionally less data.

### Removing

Drain, remove the daemon, purge, then remove the host:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd out osd.3
incus exec ceph-node1 -- cephadm shell -- ceph orch daemon rm osd.3 --force
incus exec ceph-node1 -- cephadm shell -- ceph osd purge 3 --yes-i-really-mean-it
incus exec ceph-node1 -- cephadm shell -- ceph orch host rm ceph-node4 --force
```

### The two things left behind

Removing the host is not the end, and this is the part worth remembering:

**A stranded monitor.** cephadm may have placed a mon on the new node, and removing
the host does not remove it from the monmap:

```
health: HEALTH_WARN  1/4 mons down, quorum ceph-node1,ceph-node3,ceph-node2
```

```bash
incus exec ceph-node1 -- cephadm shell -- ceph mon dump | grep mon.
incus exec ceph-node1 -- cephadm shell -- ceph mon rm ceph-node4
```

A cluster running with a permanently-down mon has lost failure tolerance it thinks it
has — on a 4-mon map you now need 3 of the remaining 3 for quorum.

**PGs per OSD.** Fewer OSDs, same number of PGs:

```
too many PGs per OSD (307 > max 250)
```

Either reduce PG counts or, on a small cluster, raise the limit:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph config set global mon_max_pg_per_osd 400
```

Finally clean up the disk itself:

```bash
incus delete -f ceph-node4
vgremove -f ceph-vg4
losetup -d $LOOP
rm -f /var/lib/ceph-disks/osd4.img
```

**Expect `CEPHADM_REFRESH_FAILED` afterwards.** Adding or removing a host triggers a
device probe, and `ceph-volume inventory` cannot run in these nested containers — the
same limitation that keeps `ceph orch device ls` empty. It is cosmetic here:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph health mute CEPHADM_REFRESH_FAILED 1w
```

Muting a known-benign alert is the right call; muting one you have not diagnosed is
not.

**In the web UI.** Ceph dashboard → Cluster → Hosts shows the new host and its daemons.

**Cleanup.** The removal above is the cleanup. Confirm `HEALTH_OK`, 3 mons in quorum
and 3 OSDs up and in before moving on.

---

## Exercise 27 — Recover a cluster that has filled up

**The situation.** Someone uploads a large image, or a runaway job writes until there
is no space left. Ceph stops accepting writes, Glance starts returning `502`, and
instances cannot be created. Then you discover the trap: **you cannot delete your way
out of it either**, because deleting an RBD image is itself a write.

This is the most useful failure in this guide, because the instinctive response —
"just delete something" — does not work, and knowing the way out beforehand turns a
long outage into a five-minute one.

> Do this exercise last. It disrupts everything else, and its cleanup is the teardown.

### Fill it up

The lab cluster is 45 GiB raw, so roughly 14 GiB usable at `size = 3`. A large raw
image will do it — Glance stores raw images **unsparsed**, so each one costs its full
size times the replication factor:

```bash
cd /tmp
dd if=/dev/urandom of=big.raw bs=1M count=3500      # 3.5 GB of incompressible data
OS image create big-image --file /tmp/big.raw --disk-format raw --container-format bare
```

Use random data, not zeros — a file of zeros may not consume the space you expect once
it reaches the cluster, and the point of this exercise is to actually run out.

One 3.5 GB image is 10.5 GB of cluster. Upload it two or three times under different
names, and the cluster is full:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph df
```

```
TOTAL           45 GiB   1.9 GiB avail   43 GiB used   95.74%
glance-images   13 GiB stored   39 GiB used   100.00%   MAX AVAIL 0 B
```

### What it looks like

```bash
incus exec ceph-node1 -- cephadm shell -- ceph health detail
```

```
HEALTH_ERR 3 full osd(s); 13 pool(s) full
[ERR] OSD_FULL: 3 full osd(s)
    osd.0 is full
```

Every pool shows `MAX AVAIL 0 B`. Glance returns
`HttpException: 502` on upload. And the deadlock:

```bash
rbd -n client.glance --keyring /etc/ceph/ceph.client.glance.keyring rm glance-images/<id>
# hangs, or fails -- deleting requires a metadata write, and writes are blocked
```

### Getting out

Raise the full ratio just enough to let deletes through. This is a temporary,
deliberate loosening of a safety limit:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd set-full-ratio 0.99
```

Now find what is actually consuming space and remove it. Work at the RBD level, since
the OpenStack APIs may still be failing:

```bash
KG="-n client.glance --keyring /etc/ceph/ceph.client.glance.keyring"
for img in $(rbd $KG ls glance-images); do
  printf '%-40s %s\n' "$img" "$(rbd $KG info glance-images/$img | awk '/size/{print $2, $3}')"
done
```

```
0d6a6089-8ebd-44b2-a0cd-f51c975d0375     16 GiB      <- the culprit
9bdaefd0-61c2-4b60-8299-dc9d3922ee8f     3.5 GiB
a4c71411-a210-4d5f-9a68-768077feddb0     112 MiB
```

Delete the large ones. Glance images carry a protected snapshot for copy-on-write
cloning, so purge that first or `rm` refuses:

```bash
rbd $KG snap purge glance-images/<id>
rbd $KG rm         glance-images/<id>
```

Deletion is asynchronous — give it a minute before judging progress. Then **put the
safety limits back**:

```bash
incus exec ceph-node1 -- cephadm shell -- ceph osd set-full-ratio 0.95
incus exec ceph-node1 -- cephadm shell -- ceph osd set-nearfull-ratio 0.85
incus exec ceph-node1 -- cephadm shell -- ceph osd set-backfillfull-ratio 0.90
incus exec ceph-node1 -- cephadm shell -- ceph df
```

```
TOTAL  45 GiB  43 GiB avail  1.7 GiB used  3.82%
```

Glance recovers on its own once space is available; no restart needed.

### What to take away

- **Capacity is `size × replication`.** A 3.5 GB image is 10.5 GB of cluster. Check
  `ceph df` *before* uploading anything large, not after.
- **`nearfull` at 85% is your warning**, and it is there so you never reach 95%. Treat
  it as an incident, not a notice.
- **A full cluster blocks its own cleanup.** Raising `full-ratio` is the escape hatch;
  lowering it again is not optional.
- **`MAX AVAIL` is the number that matters**, not `TOTAL`.

**In the web UI.** Ceph dashboard → Pools shows usage and MAX AVAIL per pool; the
health panel shows the OSD_FULL error. The dashboard keeps working while the cluster
is full, which makes it a better vantage point than the OpenStack APIs during this
incident.

**Cleanup.** Delete `big-image` and `/tmp/*.raw`. Confirm `HEALTH_OK` and sensible
`MAX AVAIL` on every pool.

---

## Teardown

Remove the workloads but keep the lab, so the next run starts from Exercise 1 without
rebuilding the cloud:

```bash
OS server list -f value -c ID | xargs -r -n1 openstack server delete
OS floating ip list -f value | awk '$3=="None"{print $1}' | xargs -r -n1 openstack floating ip delete
OS volume list -f value -c ID | xargs -r -n1 openstack volume delete
OS stack list -f value -c ID | xargs -r -n1 openstack stack delete --yes
```

Keep `lab-workload`, the networks, the router, the flavors, the keypair and the
security groups — they are Exercises 1 and 2, and rebuilding them wastes ten minutes
every time.

Then stop the machine cleanly:

```bash
container machine stop openstack-lab
```

To start again later:

```bash
container machine run -n openstack-lab --root -- /usr/local/sbin/provision-lab.sh --only 90-verify
```

That waits for each layer and prints the current URLs and passwords — the VM address
changes on every start.

**To reset the storage side completely** without rebuilding the machine, see *Reset* in
`openstack-ceph-lab-build.md`.
