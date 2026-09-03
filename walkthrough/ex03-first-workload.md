# Exercise 3 — A first workload (web UI)

Guide section: [Exercise 3](../openstack-ceph-lab-exercise.md#exercise-3--a-first-workload)

"It says ACTIVE but I can't reach it" is the most common ticket in any cloud. You
cannot debug someone else's instance until you have booted a known-good one yourself.
The Launch Instance wizard is where every field of `openstack server create` lives.

## Step 1 — Details

**Project → Compute → Instances → Launch Instance.**

![Launch Instance details tab](img/ex03-step01-launch-instance-details-tab.png)

The quota donut on the right updates as you go. It is the same number Exercise 16
deliberately exhausts.

## Step 2 — Source

![Launch Instance source tab](img/ex03-step02-launch-instance-source-tab.png)

**Set "Create New Volume" to No.** The default is Yes, which boots the instance from a
new Cinder volume instead of an ephemeral disk. That works, but it consumes volume
quota and leaves a volume behind on delete — not what the guide's `server create` does.

Then click the ↑ on `lab-workload` to move it into **Allocated**. Nothing is selected
until it is in that top table.

## Step 3 — Flavor

![Launch Instance flavor tab](img/ex03-step03-launch-instance-flavor-tab.png)

## Step 4 — Networks

![Launch Instance networks tab](img/ex03-step04-launch-instance-networks-tab.png)

`private` only. Attaching directly to `public` skips the router and gives you an
instance that cannot be reached the way the rest of the lab expects.

## Step 5 — Key Pair

![Launch Instance key pair tab](img/ex03-step05-launch-instance-keypair-tab.png)

Check the arrow flipped from ↑ to ↓ before moving on. A key pair that was clicked but
not allocated produces an instance with `key_name: None`, and the only symptom is that
SSH asks for a password that does not exist.

## Step 6 — Configuration

![Launch Instance configuration tab](img/ex03-step06-launch-instance-configuration-tab.png)

**Configuration Drive** is the checkbox equivalent of `--config-drive true`. This lab
reaches the metadata service over the network so it is not required, but it costs
nothing and removes one failure mode.

## Step 7 — Running

![Instances list](img/ex03-step07-instances-list-active.png)

## Step 8 — Give it an address

The instance dropdown carries everything you would otherwise do with `openstack server
...` — floating IPs, volumes, metadata, security groups, console, resize, rebuild.

![Instance actions dropdown](img/ex03-step08-instance-actions-dropdown.png)

**Associate Floating IP** offers addresses already allocated to the project. If the
list is empty, allocate one first under **Project → Network → Floating IPs**.

![Associate floating IP](img/ex03-step09-associate-floating-ip-dialog.png)

![Floating IPs list](img/ex03-step10-floating-ips-list-mapped.png)

## Step 9 — Read the console before anything else

Instance → **Log** tab. This is `openstack console log show`, and it answers the
"ACTIVE but unreachable" ticket faster than anything else.

![Instance console log](img/ex03-step11-instance-console-log.png)

Three lines prove the boot was healthy:

- `Authorized keys from /home/alpine/.ssh/authorized_keys for user alpine` — cloud-init
  injected the key, so SSH will work.
- `Datasource DataSourceOpenStackLocal [net,ver=2]` — it found the metadata service.
  This is exactly what Exercise 2's `datasource_list` fix bought.
- `web1 login:` — userspace is up.

If the key line is missing, the image's datasource list is wrong. If the login prompt
never appears, look at the flavor's memory before anything else.
