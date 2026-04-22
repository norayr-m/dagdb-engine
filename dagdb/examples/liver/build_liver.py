#!/usr/bin/env python3
"""Build a bio-digital liver on DagDB with properties-as-nodes.

Physiological model (simplified but anatomically grounded):

  Rank 5: systemic condition nodes (SHARED across many cells)
    - toxin_APAP     : is acetaminophen present in portal blood?
    - hypoxia        : is blood oxygen low?
    - inflammation   : is there an inflammatory signal (Kupffer cells)?
    - zone3_marker   : cell-type marker for centrilobular hepatocytes (CYP2E1+)

  Rank 4: 600 hepatocytes (parenchymal cells)
    - Distributed evenly across 3 zones (200 each)
    - Zone 1 cells subscribe to { hypoxia, inflammation } — 2 systemic inputs
    - Zone 3 cells subscribe to { toxin_APAP, hypoxia, zone3_marker } — 3 systemic inputs
    - LUT6 semantics: cell_healthy = NOT(any damage signal firing)

  Rank 3: 100 lobules (each aggregates 6 hepatocytes via MAJORITY)
  Rank 2: 3 zones (periportal AND, midzonal MAJ, centrilobular OR)
  Rank 1: 3 liver functions (detox AND, bile MAJ, glucose AND)
  Rank 0: liver health (AND across functions)

The 6-bound matters: every cell has at most 6 incoming edges, and the DAG
naturally respects it — lobule fan-in is 6, zone fan-in is 6, function fan-in
is 3, root fan-in is 3. Signals flow leaves-up (high rank → low rank) exactly
once per TICK, in parallel per rank. That's the GPU kernel schedule.

The properties-as-nodes pattern means flipping `toxin_APAP` from 0 to 1
propagates to every zone-3 hepatocyte in a single tick — no per-cell update
loop, no broadcast. One node, one truth byte, many subscribers.

Node ID layout (keeps everything in one sparse range for easy inspection):
  20000-20003 : systemic condition nodes (4 shared)
  20100-20699 : 600 hepatocytes
  20700-20799 : 100 lobules
  20800-20802 : 3 zones
  20803-20805 : 3 functions
  20806       : liver health root
"""

import socket
import sys
import time

SOCK = "/tmp/dagdb.sock"


def cmd(c: str) -> str:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((c + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    buf = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    return buf.decode().strip()


def batch(cmds):
    for c in cmds:
        r = cmd(c)
        if r.startswith("ERROR") or r.startswith("FAIL"):
            print(f"  {c} -> {r}")


# ── Node IDs ──
SYS_START    = 20000  # systemic shared nodes (rank 5)
TOXIN_APAP   = 20000
HYPOXIA      = 20001
INFLAMMATION = 20002

HEP_START    = 20100  # hepatocytes, rank 4 (600 cells)
N_HEP        = 600

LOB_START    = 20700  # lobules, rank 3
N_LOB        = 100
HEPS_PER_LOB = 6

ZONE_START   = 20800  # 3 zones, rank 2
ZONE_PERIPORTAL, ZONE_MIDZONAL, ZONE_CENTRI = 20800, 20801, 20802

FN_START     = 20803  # 3 functions, rank 1
FN_DETOX, FN_BILE, FN_GLUCOSE = 20803, 20804, 20805

LIVER_ROOT   = 20806  # root, rank 0


def build():
    print("══════════════════════════════════════════════════════════")
    print("  Bio-Digital Liver  (DagDB — properties as nodes)")
    print("══════════════════════════════════════════════════════════")

    s = cmd("STATUS")
    print(f"  {s}\n")

    t0 = time.time()

    # ── Rank 5: systemic condition nodes ──
    # Start "off" — a healthy liver in clean blood.
    # LUT = IDENTITY so their truth state flows through when set.
    print("  [1/6] Systemic condition nodes (shared across many cells)...")
    sys_nodes = [
        (TOXIN_APAP,   "toxin_APAP    (acetaminophen in portal blood)"),
        (HYPOXIA,      "hypoxia       (low blood oxygen)"),
        (INFLAMMATION, "inflammation  (Kupffer cell signal)"),
    ]
    for nid, label in sys_nodes:
        batch([f"SET {nid} RANK 5",
               f"SET {nid} LUT CONST0",
               f"CLEAR {nid} EDGES",
               f"SET {nid} TRUTH 0"])
        print(f"        {nid}: {label}")

    # ── Rank 4: 600 hepatocytes ──
    # Distributed: cells 20100..20299 = zone 1 (periportal)
    #              cells 20300..20499 = zone 2 (midzonal)
    #              cells 20500..20699 = zone 3 (centrilobular)
    print("\n  [2/6] 600 hepatocytes (parenchymal cells, rank 4)...")
    for i in range(N_HEP):
        nid = HEP_START + i
        batch([f"SET {nid} RANK 4",
               f"CLEAR {nid} EDGES",
               f"SET {nid} TRUTH 1"])

        # NOR6: cell is HEALTHY (truth=1) iff every subscribed damage signal
        # is 0. Any firing damage-signal flips the cell to 0 (damaged).
        batch([f"SET {nid} LUT NOR"])

        # Subscribe to relevant systemic damage-signals.
        # Zone specificity comes from WHICH nodes a cell subscribes to,
        # not from a marker-node in the inputs. Zones 1 & 2 don't know
        # about APAP because they don't subscribe to it.
        if i < 200:
            # Zone 1 (periportal) — O2-rich, robust to toxin
            batch([f"CONNECT FROM {HYPOXIA} TO {nid}",
                   f"CONNECT FROM {INFLAMMATION} TO {nid}"])
        elif i < 400:
            # Zone 2 (midzonal) — intermediate
            batch([f"CONNECT FROM {HYPOXIA} TO {nid}",
                   f"CONNECT FROM {INFLAMMATION} TO {nid}"])
        else:
            # Zone 3 (centrilobular) — CYP2E1+, APAP-vulnerable
            batch([f"CONNECT FROM {TOXIN_APAP}   TO {nid}",
                   f"CONNECT FROM {HYPOXIA}      TO {nid}",
                   f"CONNECT FROM {INFLAMMATION} TO {nid}"])

    print(f"        wrote {N_HEP} hepatocytes")
    print(f"        Zone 1 (periportal):    {HEP_START}..{HEP_START+199}")
    print(f"        Zone 2 (midzonal):      {HEP_START+200}..{HEP_START+399}")
    print(f"        Zone 3 (centrilobular): {HEP_START+400}..{HEP_START+599}")

    # ── Rank 3: 100 lobules ──
    print("\n  [3/6] 100 lobules (MAJORITY gate over 6 hepatocytes)...")
    for i in range(N_LOB):
        lob_id = LOB_START + i
        batch([f"SET {lob_id} RANK 3",
               f"SET {lob_id} LUT MAJ",
               f"CLEAR {lob_id} EDGES"])
        for j in range(HEPS_PER_LOB):
            hep_id = HEP_START + i * HEPS_PER_LOB + j
            cmd(f"CONNECT FROM {hep_id} TO {lob_id}")
    print(f"        wired {N_LOB * HEPS_PER_LOB} edges")

    # ── Rank 2: 3 zones ──
    print("\n  [4/6] 3 zones (periportal/midzonal/centrilobular)...")
    zones = [
        (ZONE_PERIPORTAL, "AND", "periportal   (strict, O2-rich)"),
        (ZONE_MIDZONAL,   "MAJ", "midzonal     (resilient)"),
        (ZONE_CENTRI,     "OR",  "centrilobular (APAP-vulnerable)"),
    ]
    lobs_per_zone = N_LOB // 3
    for z_idx, (zid, lut, label) in enumerate(zones):
        batch([f"SET {zid} RANK 2",
               f"SET {zid} LUT {lut}",
               f"CLEAR {zid} EDGES"])
        # Sample 6 representative lobules per zone (the 6-bound at the zone level)
        start = z_idx * lobs_per_zone
        step  = max(1, lobs_per_zone // 6)
        for j in range(6):
            lob_id = LOB_START + start + j * step
            cmd(f"CONNECT FROM {lob_id} TO {zid}")
        print(f"        {zid}: {label}")

    # ── Rank 1: 3 functions ──
    print("\n  [5/6] 3 liver functions...")
    # Functions aggregate 3 zones, not 6 — use AND3 / MAJ3 presets so the
    # unused 4th-6th LUT inputs don't skew the gate semantics.
    functions = [
        (FN_DETOX,   "AND3", "detoxification   (needs all zones)"),
        (FN_BILE,    "MAJ3", "bile production  (resilient)"),
        (FN_GLUCOSE, "AND3", "glucose regulation"),
    ]
    for fid, lut, label in functions:
        batch([f"SET {fid} RANK 1",
               f"SET {fid} LUT {lut}",
               f"CLEAR {fid} EDGES"])
        for zid, _, _ in zones:
            cmd(f"CONNECT FROM {zid} TO {fid}")
        print(f"        {fid}: {label}")

    # ── Rank 0: liver health root ──
    print("\n  [6/6] Liver health root (AND3 across 3 functions)...")
    batch([f"SET {LIVER_ROOT} RANK 0",
           f"SET {LIVER_ROOT} LUT AND3",
           f"CLEAR {LIVER_ROOT} EDGES"])
    for fid, _, _ in functions:
        cmd(f"CONNECT FROM {fid} TO {LIVER_ROOT}")

    build_ms = (time.time() - t0) * 1000
    print(f"\n  Graph built in {build_ms:.1f} ms")

    # ── Evaluate baseline ──
    print("\n  Baseline evaluation (healthy liver, systemic signals all off)...")
    cmd("TICK 1")
    cmd("TICK 1")
    cmd("TICK 1")
    cmd("TICK 1")
    cmd("TICK 1")

    print("  ── Baseline state ──")
    r = cmd(f"TRAVERSE FROM {LIVER_ROOT} DEPTH 1")
    print(f"    liver root: {r}")
    for fid, _, label in functions:
        r = cmd(f"TRAVERSE FROM {fid} DEPTH 0")
        print(f"    {label}: {r}")

    r = cmd("GRAPH INFO")
    print(f"\n  {r}")

    # Validate
    v = cmd("VALIDATE")
    print(f"  {v}")

    return {
        "root": LIVER_ROOT,
        "functions": [FN_DETOX, FN_BILE, FN_GLUCOSE],
        "zones": [ZONE_PERIPORTAL, ZONE_MIDZONAL, ZONE_CENTRI],
        "systemic": {
            "toxin_APAP":   TOXIN_APAP,
            "hypoxia":      HYPOXIA,
            "inflammation": INFLAMMATION,
        },
        "hep_range": (HEP_START, HEP_START + N_HEP),
        "build_ms":  build_ms,
    }


if __name__ == "__main__":
    info = build()
    print("\n  Ready. Next: run scenario_apap.py")
