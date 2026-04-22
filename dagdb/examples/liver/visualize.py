#!/usr/bin/env python3
"""Render the bio-digital liver graph structure as DOT → PNG.

Three outputs:
  1. liver_architecture.png — full rank layering, every role labelled.
  2. liver_lobule_zoom.png  — one representative zone-3 lobule with its
                              6 hepatocytes and their 3 systemic subscriptions.
  3. liver_apap_damage.png  — after-injection state: zone 3 cells shown
                              in red, zones 1-2 in green.

Uses the diagram MCP's graphviz bridge (dot must be installed).
"""

import subprocess
import os
import shutil

OUT = os.path.expanduser("~/diagram_output")
os.makedirs(OUT, exist_ok=True)


def render(name: str, dot: str):
    src = os.path.join(OUT, f"{name}.dot")
    out = os.path.join(OUT, f"{name}.png")
    with open(src, "w") as f:
        f.write(dot)
    dot_bin = shutil.which("dot") or "/opt/homebrew/bin/dot"
    subprocess.run([dot_bin, "-Tpng", src, "-o", out], check=True)
    print(f"  wrote {out}")
    return out


# ── 1. Architecture diagram ──

ARCHITECTURE = r"""
digraph Liver {
    rankdir=BT;
    node [shape=box, style="filled,rounded", fontname="Helvetica", fontsize=10];
    bgcolor="#FFFFFF";
    label="DagDB Bio-Digital Liver — ranked DAG\n707 nodes, 6 ranks, edges flow leaves→root";
    labelloc=t; fontsize=14;

    // Rank 5: systemic condition nodes (shared subscribers)
    subgraph cluster_sys {
        label="Rank 5 — systemic conditions (shared)";
        color="#D0D0D0"; style=filled; fillcolor="#F0F0F0";
        toxin [label="toxin_APAP\n(one node,\n~200 subscribers)", fillcolor="#FFD6D6"];
        hypoxia [label="hypoxia\n(blood O2 low)", fillcolor="#FFE6B3"];
        inflammation [label="inflammation\n(Kupffer)", fillcolor="#FFE6B3"];
    }

    // Rank 4: hepatocytes — 600 cells, shown aggregated by zone
    subgraph cluster_hep {
        label="Rank 4 — 600 hepatocytes (NOR6 gate: healthy iff no damage signal)";
        color="#D0D0D0"; style=filled; fillcolor="#F5F5F5";
        z1 [label="Zone 1\n200 hepatocytes\n(periportal)", fillcolor="#D6F0D6"];
        z2 [label="Zone 2\n200 hepatocytes\n(midzonal)", fillcolor="#D6F0D6"];
        z3 [label="Zone 3\n200 hepatocytes\n(centrilobular,\nCYP2E1+, APAP-vuln)", fillcolor="#FFE0E0"];
    }

    toxin -> z3;
    hypoxia -> z1;
    hypoxia -> z2;
    hypoxia -> z3;
    inflammation -> z1;
    inflammation -> z2;
    inflammation -> z3;

    // Rank 3: lobules
    lobules [label="Rank 3 — 100 lobules\n(MAJ gate, 6 hepatocytes each)", fillcolor="#E6E6FF"];
    z1 -> lobules;
    z2 -> lobules;
    z3 -> lobules;

    // Rank 2: zones
    zones [label="Rank 2 — 3 zone aggregators\nperiportal AND / midzonal MAJ / centrilobular OR", fillcolor="#D0D0FF"];
    lobules -> zones;

    // Rank 1: functions
    subgraph cluster_fn {
        label="Rank 1 — 3 liver functions";
        color="#D0D0D0"; style=filled; fillcolor="#F5F5F5";
        detox [label="detoxification\n(AND3)", fillcolor="#D6D6F0"];
        bile [label="bile production\n(MAJ3)", fillcolor="#D6D6F0"];
        glucose [label="glucose reg\n(AND3)", fillcolor="#D6D6F0"];
    }
    zones -> detox; zones -> bile; zones -> glucose;

    // Rank 0: root
    root [label="Rank 0 — liver health\n(AND3 across functions)", fillcolor="#80D080"];
    detox -> root;
    bile -> root;
    glucose -> root;
}
"""


# ── 2. Lobule zoom (one zone-3 lobule, with subscriptions) ──

LOBULE = r"""
digraph Lobule {
    rankdir=BT;
    node [shape=circle, style="filled", fontname="Helvetica", fontsize=9];
    label="Zoom: one zone-3 lobule with shared-subscription pattern\n6 hepatocytes → MAJ gate → lobule";
    labelloc=t; fontsize=12;

    // The three shared systemic nodes (drawn once, all cells point at them)
    toxin [label="toxin\nAPAP", fillcolor="#FF9999", shape=box];
    hypoxia [label="hypoxia", fillcolor="#FFCC99", shape=box];
    inflammation [label="inflamm", fillcolor="#FFCC99", shape=box];

    // 6 hepatocytes
    h1 [label="hep1\nNOR6", fillcolor="#D6F0D6"];
    h2 [label="hep2\nNOR6", fillcolor="#D6F0D6"];
    h3 [label="hep3\nNOR6", fillcolor="#D6F0D6"];
    h4 [label="hep4\nNOR6", fillcolor="#D6F0D6"];
    h5 [label="hep5\nNOR6", fillcolor="#D6F0D6"];
    h6 [label="hep6\nNOR6", fillcolor="#D6F0D6"];

    // Each of the 6 cells subscribes to the 3 shared systemic nodes.
    // That's 3 edges per cell (one of 6 slots each), leaving 3 free.
    toxin -> h1; toxin -> h2; toxin -> h3; toxin -> h4; toxin -> h5; toxin -> h6;
    hypoxia -> h1; hypoxia -> h2; hypoxia -> h3; hypoxia -> h4; hypoxia -> h5; hypoxia -> h6;
    inflammation -> h1; inflammation -> h2; inflammation -> h3; inflammation -> h4; inflammation -> h5; inflammation -> h6;

    // Lobule aggregator
    lobule [label="lobule\nMAJ6\n(healthy iff 4+/6\ncells alive)", fillcolor="#D0D0FF", shape=box];
    h1 -> lobule; h2 -> lobule; h3 -> lobule;
    h4 -> lobule; h5 -> lobule; h6 -> lobule;
}
"""


# ── 3. APAP damage pattern ──

DAMAGE = r"""
digraph APAP {
    rankdir=BT;
    node [shape=box, style="filled,rounded", fontname="Helvetica", fontsize=10];
    label="After APAP injection: zone 3 dead, zones 1-2 spared\n(zone-specificity encoded in subscription pattern, not cell code)";
    labelloc=t; fontsize=12;

    toxin [label="toxin_APAP\n→ TRUTH=1", fillcolor="#FF3333", fontcolor=white];

    z1 [label="Zone 1 — 200 cells\nNOT subscribed to APAP\nfiring: 200/200", fillcolor="#66CC66"];
    z2 [label="Zone 2 — 200 cells\nNOT subscribed to APAP\nfiring: 200/200", fillcolor="#66CC66"];
    z3 [label="Zone 3 — 200 cells\nSUBSCRIBED to APAP\nfiring: 0/200", fillcolor="#CC3333", fontcolor=white];

    toxin -> z3;
    z3_result [label="1 node write\n→ 200 cell state changes\n→ 33 lobules fail\n→ detox & glucose fail\n→ liver root = 0", fillcolor="#FFAAAA", shape=ellipse];
    z3 -> z3_result;
}
"""


if __name__ == "__main__":
    print("Rendering bio-digital liver diagrams...")
    render("liver_architecture", ARCHITECTURE)
    render("liver_lobule_zoom", LOBULE)
    render("liver_apap_damage", DAMAGE)
    print(f"\n  Done. See: {OUT}/liver_*.png")
    print(f"  Open one: open {OUT}/liver_architecture.png")
