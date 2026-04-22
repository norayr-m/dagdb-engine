#!/usr/bin/env python3
"""DagDB Liver — Bio-Digital Twin Proof of Concept

Builds a simplified liver as a ranked DAG and runs physiological scenarios.

Structure:
  Rank 4: 600 hepatocytes organized into 100 functional groups of 6
  Rank 3: 100 lobules (MAJORITY gate — lobule healthy if 4+ cells work)
  Rank 2: 3 zones — periportal, midzonal, centrilobular (different LUT per zone)
  Rank 1: 3 liver functions — detox, bile, glucose (AND of zones)
  Rank 0: liver health status

Node ID ranges:
  1000-1599: hepatocytes (600 cells)
  1600-1699: lobules (100)
  1700-1702: zones (3)
  1703-1705: functions (3)
  1706: liver health
"""

import socket
import sys
import random

SOCK = "/tmp/dagdb.sock"

def cmd(c):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((c + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    r = b""
    while True:
        chunk = s.recv(4096)
        if not chunk: break
        r += chunk
    s.close()
    return r.decode().strip()

def batch(commands):
    for c in commands:
        cmd(c)

N_CELLS = 600
N_LOBULES = 100
CELLS_PER_LOBULE = 6

CELL_START = 1000
LOBULE_START = 1600
ZONE_START = 1700
FUNCTION_START = 1703
LIVER_ROOT = 1706

def build_liver(fault_rate=0.02):
    """Build the liver graph with a given rate of hepatocyte faults."""
    print(f"══════════════════════════════════════════════════════════")
    print(f"  DagDB Liver — Building {N_CELLS} hepatocytes...")
    print(f"══════════════════════════════════════════════════════════")

    # Rank 4: hepatocytes
    print(f"\n  [1/5] Hepatocytes (fault rate: {fault_rate*100:.1f}%)...")
    faults = []
    for i in range(N_CELLS):
        nid = CELL_START + i
        is_fault = random.random() < fault_rate
        truth = 0 if is_fault else 1
        lut = "CONST0" if is_fault else "CONST1"
        cmd(f"SET {nid} RANK 4")
        cmd(f"SET {nid} LUT {lut}")
        cmd(f"SET {nid} TRUTH {truth}")
        if is_fault:
            faults.append(nid)
    print(f"      wrote {N_CELLS} hepatocytes, {len(faults)} faults: {faults[:10]}{'...' if len(faults)>10 else ''}")

    # Rank 3: lobules (MAJORITY of 6 hepatocytes)
    print(f"\n  [2/5] {N_LOBULES} lobules (MAJORITY gate, need 4+/6 healthy)...")
    for i in range(N_LOBULES):
        nid = LOBULE_START + i
        cmd(f"SET {nid} RANK 3")
        cmd(f"SET {nid} LUT MAJ")
        cmd(f"CLEAR {nid} EDGES")
        for j in range(CELLS_PER_LOBULE):
            cell_id = CELL_START + i * CELLS_PER_LOBULE + j
            cmd(f"CONNECT FROM {cell_id} TO {nid}")
    print(f"      wired {N_LOBULES * CELLS_PER_LOBULE} edges")

    # Rank 2: 3 zones with different aggregation strategies
    # Periportal (strict AND — all lobules must work for detox)
    # Midzonal (MAJORITY — resilient)
    # Centrilobular (OR — most sensitive to damage)
    print(f"\n  [3/5] 3 zones (periportal/midzonal/centrilobular)...")
    zones = [
        (ZONE_START + 0, "AND",  "Periportal (strict, oxygen-rich)"),
        (ZONE_START + 1, "MAJ",  "Midzonal (resilient)"),
        (ZONE_START + 2, "OR",   "Centrilobular (sensitive)"),
    ]
    lobules_per_zone = N_LOBULES // 3
    for z_idx, (zid, lut, label) in enumerate(zones):
        cmd(f"SET {zid} RANK 2")
        cmd(f"SET {zid} LUT {lut}")
        cmd(f"CLEAR {zid} EDGES")
        # Connect up to 6 representative lobules per zone (Rule of 6)
        start = z_idx * lobules_per_zone
        for j in range(6):
            lobule_id = LOBULE_START + start + j * (lobules_per_zone // 6)
            cmd(f"CONNECT FROM {lobule_id} TO {zid}")
        print(f"      Zone {zid}: {label} = {lut}")

    # Rank 1: liver functions
    print(f"\n  [4/5] 3 liver functions (detox/bile/glucose)...")
    functions = [
        (FUNCTION_START + 0, "AND", "Detoxification"),
        (FUNCTION_START + 1, "MAJ", "Bile production"),
        (FUNCTION_START + 2, "AND", "Glucose regulation"),
    ]
    for fid, lut, label in functions:
        cmd(f"SET {fid} RANK 1")
        cmd(f"SET {fid} LUT {lut}")
        cmd(f"CLEAR {fid} EDGES")
        for zid, _, _ in zones:
            cmd(f"CONNECT FROM {zid} TO {fid}")
        print(f"      Function {fid}: {label} = {lut}")

    # Rank 0: liver health root
    print(f"\n  [5/5] Liver health root (ID gate over 3 functions = AND)...")
    cmd(f"SET {LIVER_ROOT} RANK 0")
    cmd(f"SET {LIVER_ROOT} LUT AND")
    cmd(f"CLEAR {LIVER_ROOT} EDGES")
    for fid, _, _ in functions:
        cmd(f"CONNECT FROM {fid} TO {LIVER_ROOT}")
    print(f"      Liver root: node {LIVER_ROOT}")

    # Evaluate
    print(f"\n  Evaluating (leaves-up propagation)...")
    for _ in range(5):
        cmd("TICK 1")

    # Read results
    print(f"\n  ── Liver State ──")
    liver = cmd(f"TRAVERSE FROM {LIVER_ROOT} DEPTH 1")
    print(f"  Root:      {liver}")
    for fid, _, label in functions:
        r = cmd(f"TRAVERSE FROM {fid} DEPTH 1")
        print(f"  {label}: {r}")
    for zid, _, label in zones:
        r = cmd(f"TRAVERSE FROM {zid} DEPTH 1")
        print(f"  {label}: {r}")

    return faults


def scenario_cirrhosis():
    """Simulate progressive liver damage (cirrhosis)."""
    print(f"\n\n══════════════════════════════════════════════════════════")
    print(f"  SCENARIO: Progressive Cirrhosis")
    print(f"══════════════════════════════════════════════════════════\n")

    for stage, fault_rate in [("Healthy", 0.00), ("Stage 1", 0.10),
                                ("Stage 2", 0.25), ("Stage 3", 0.40), ("Cirrhosis", 0.60)]:
        random.seed(42)  # deterministic for comparison
        print(f"\n  ▸ {stage} — {fault_rate*100:.0f}% hepatocyte damage")
        build_liver(fault_rate=fault_rate)


if __name__ == "__main__":
    # Verify daemon
    s = cmd("STATUS")
    if not s.startswith("OK"):
        print(f"ERROR: daemon not running. Start with: ./dagdb start")
        sys.exit(1)
    print(f"Daemon: {s}\n")

    if len(sys.argv) > 1 and sys.argv[1] == "cirrhosis":
        scenario_cirrhosis()
    else:
        build_liver(fault_rate=0.02)
