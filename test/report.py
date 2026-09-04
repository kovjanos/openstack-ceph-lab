#!/usr/bin/env python3
"""Per-step metrics from an end-to-end run: host disk, VM disk, Ceph allocated vs used,
and peak memory, for every build phase and every exercise.

    ./report.py test/results/<timestamp>

Joins disk.csv (host, 30s), ceph.csv (guest and cluster, 60s) and memory.csv (30s) by
nearest epoch, and takes step boundaries from the markers each exercise script emits."""
import csv, re, sys, pathlib, bisect
if len(sys.argv) < 2:
    sys.exit("usage: report.py <results-dir>")
E = pathlib.Path(sys.argv[1])

host = [r for r in csv.DictReader(open(E/"disk.csv")) if r.get("epoch","").isdigit()]
try:
    logi = [r for r in csv.DictReader(open(E/"ceph.csv")) if r.get("epoch","").isdigit()]
except FileNotFoundError:
    logi = []
if not host: sys.exit("no host samples")
try:
    mem = [r for r in csv.DictReader(open(E/"memory.csv")) if r.get("epoch","").isdigit()]
except FileNotFoundError:
    mem = []
mep = [int(r["epoch"]) for r in mem]
def M(ep, key):
    if not mem: return 0.0
    i = bisect.bisect_left(mep, ep)
    for j in (i, i-1, i+1):
        if 0 <= j < len(mem):
            try: return float(mem[j].get(key) or 0)
            except ValueError: return 0.0
    return 0.0

lep = [int(r["epoch"]) for r in logi]
def L(ep, key):
    if not logi: return 0.0
    i = bisect.bisect_left(lep, ep)
    for j in (i, i-1, i+1):
        if 0 <= j < len(logi):
            try: return float(logi[j].get(key) or 0)
            except ValueError: return 0.0
    return 0.0

log = (E/"run.log").read_text(errors="ignore")
marks = sorted((int(m.group(1)), m.group(2).strip()) for m in
               re.finditer(r'^--- \[[0-9:]+\|(\d+)\] (Ex\d+[^\n]*)', log, re.M))

# steps: build stages from the sampler's own stage column, then exercises from markers
steps, cur, start = [], None, None
for r in host:
    st = r["stage"]
    if st != cur:
        if cur is not None: steps.append((cur, start, int(r["epoch"])))
        cur, start = st, int(r["epoch"])
steps.append((cur, start, int(host[-1]["epoch"])+1))
steps = [s for s in steps if "5/5" not in s[0]]        # stage 5 is split by exercise
for i, (ep, lab) in enumerate(marks):
    end = marks[i+1][0] if i+1 < len(marks) else int(host[-1]["epoch"])+1
    steps.append((lab, ep, end))

def rows_in(a, b): return [r for r in host if a <= int(r["epoch"]) < b]
def gb(v):
    try: return float(v)/1024
    except (TypeError, ValueError): return 0.0

print(f"{'step':<26}{'start':>9}{'dur':>8}{'host store':>14}{'VM img alloc':>15}{'VM fs used':>14}"
      f"{'ceph used/alloc':>19}{'peak footprint':>16}{'peak rss':>10}{'peak guest/26G':>16}")
print("-"*133)
for lab, a, b in steps:
    rs = rows_in(a, b)
    if not rs: continue
    s, e = rs[0], rs[-1]
    ceph_s, ceph_e = L(int(s["epoch"]), "ceph_raw_used_mb"), L(int(e["epoch"]), "ceph_raw_used_mb")
    alloc = L(int(e["epoch"]), "ceph_raw_total_mb")
    vmfs_s, vmfs_e = L(int(s["epoch"]), "guest_used_mb"), L(int(e["epoch"]), "guest_used_mb")
    pk_fp  = max(M(int(r["epoch"]), "vm_footprint_mb") for r in rs)/1024
    pk_rss = max(M(int(r["epoch"]), "vm_rss_mb") or gb(r["vm_rss_mb"]) for r in rs)/1 if mem else max(gb(r["vm_rss_mb"]) for r in rs)
    pk_rss = pk_rss/1024 if mem else pk_rss
    pk_gm  = max(L(int(r["epoch"]), "guest_mem_used_mb") for r in rs)/1024
    name = lab.replace("STAGE ","")
    name = re.sub(r' \(3x\d+G OSDs, pool size \d\)', '', name)[:25]
    dur = int(rs[-1]["epoch"]) - int(rs[0]["epoch"])
    print(f"{name:<26}{rs[0]['ts']:>9}{dur//60:>5}m{dur%60:02d}s"
          f"{gb(s['store_mb']):6.1f}->{gb(e['store_mb']):<6.1f}"
          f"{gb(s['rootfs_mb']):7.1f}->{gb(e['rootfs_mb']):<6.1f}"
          f"{vmfs_s/1024:6.1f}->{vmfs_e/1024:<6.1f}"
          f"{ceph_s/1024:8.1f}->{ceph_e/1024:<5.1f}/{alloc/1024:<4.0f}"
          f"{pk_fp:15.1f}{pk_rss:10.1f}{pk_gm:15.1f}")
print("-"*133)
total = int(host[-1]["epoch"]) - int(host[0]["epoch"])
print(f"{'PEAK / TOTAL':<26}{host[0]['ts']:>9}{total//60:>5}m{total%60:02d}s{max(gb(r['store_mb']) for r in host):13.1f}"
      f"{max(gb(r['rootfs_mb']) for r in host):14.1f}"
      f"{max(L(int(r['epoch']),'guest_used_mb') for r in host)/1024:13.1f}"
      f"{max(L(int(r['epoch']),'ceph_raw_used_mb') for r in host)/1024:16.1f}"
      f"{max(M(int(r['epoch']),'vm_footprint_mb') for r in host)/1024:15.1f}"
      f"{max(M(int(r['epoch']),'vm_rss_mb') for r in host)/1024:10.1f}"
      f"{max(L(int(r['epoch']),'guest_mem_used_mb') for r in host)/1024:15.1f}")
print("\n  all figures GB.  host store = what macOS allocated.  VM img alloc = rootfs.ext4 real blocks.")
print("  VM fs used = df inside the guest.  ceph used/alloc = raw used vs raw capacity.")
print("  peak footprint = macOS phys_footprint (Activity Monitor).  peak rss = ps RSS.")
print("  peak guest/26G = memory in use inside the VM, against its 26 GB allocation.")
