#!/usr/bin/env python3
"""DagDB status dashboard generator.

Reads dashboard/features.yaml + git log + task list, writes dashboard/index.html.
Static output — open in Chrome. Re-run to refresh. No server needed.

Usage:
    python3 dashboard/gen_dashboard.py           # renders index.html
    python3 dashboard/gen_dashboard.py --watch   # regenerates every 10s
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import pathlib
import subprocess
import sys
import time

try:
    import yaml
except ImportError:
    sys.stderr.write("Need PyYAML: pip3 install pyyaml\n")
    sys.exit(1)

ROOT = pathlib.Path(__file__).resolve().parent.parent
FEATURES = ROOT / "dashboard" / "features.yaml"
OUT = ROOT / "dashboard" / "index.html"

STATUS_GLYPH = {
    "done":    ("●", "#d4af37"),   # gold
    "wip":     ("◐", "#e0a040"),   # half-gold
    "planned": ("○", "#7a6020"),   # dim
    "blocked": ("✗", "#c04040"),   # red
    "partial": ("◐", "#e0a040"),
    "pass":    ("●", "#d4af37"),
    "fail":    ("✗", "#c04040"),
}


def git_log(n: int = 10) -> list[tuple[str, str, str]]:
    out = subprocess.run(
        ["git", "log", f"-{n}", "--pretty=format:%h|%ar|%s"],
        cwd=ROOT, capture_output=True, text=True, check=False,
    ).stdout
    return [tuple(line.split("|", 2)) for line in out.splitlines() if "|" in line]


def feature_counts(data: dict) -> dict[str, int]:
    counts = {"done": 0, "wip": 0, "planned": 0, "blocked": 0}
    for sec in data.get("sections", []):
        for f in sec.get("features", []):
            counts[f.get("status", "planned")] = counts.get(f.get("status", "planned"), 0) + 1
    return counts


def render(data: dict) -> str:
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    counts = feature_counts(data)
    total = sum(counts.values())
    pct = (100 * counts["done"] // total) if total else 0

    rows = []
    for sec in data["sections"]:
        rows.append(f'<tr class="sec"><td colspan="3">{html.escape(sec["name"])}</td></tr>')
        for f in sec["features"]:
            glyph, color = STATUS_GLYPH.get(f["status"], ("·", "#888"))
            rows.append(
                f'<tr>'
                f'<td class="status" style="color:{color}">{glyph} {f["status"]}</td>'
                f'<td class="title">{html.escape(f["title"])}</td>'
                f'<td class="ev">{html.escape(f["evidence"])}</td>'
                f'</tr>'
            )

    acid_rows = []
    for key, a in data.get("acid", {}).items():
        glyph, color = STATUS_GLYPH.get(a["status"], ("·", "#888"))
        acid_rows.append(
            f'<tr>'
            f'<td class="acid-letter">{key}</td>'
            f'<td>{html.escape(a["property"])}</td>'
            f'<td class="status" style="color:{color}">{glyph} {a["status"]}</td>'
            f'<td class="ev">{html.escape(a["note"])}</td>'
            f'</tr>'
        )

    log_rows = []
    for sha, when, msg in git_log(12):
        log_rows.append(
            f'<tr><td class="sha">{html.escape(sha)}</td>'
            f'<td class="when">{html.escape(when)}</td>'
            f'<td>{html.escape(msg)}</td></tr>'
        )

    return TEMPLATE.format(
        now=now,
        pct=pct,
        done=counts["done"],
        wip=counts["wip"],
        planned=counts["planned"],
        blocked=counts["blocked"],
        total=total,
        feature_rows="\n".join(rows),
        acid_rows="\n".join(acid_rows),
        log_rows="\n".join(log_rows),
    )


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>DagDB · Status</title>
<meta http-equiv="refresh" content="30">
<style>
  :root {{
    --bg:        #0d0a04;
    --panel:     #1a1408;
    --gold:      #d4af37;
    --gold-dim:  #7a6020;
    --ink:       #e8dcb2;
    --ink-dim:   #8a7a48;
    --rule:      #3a2c10;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    background: var(--bg); color: var(--ink); margin: 0;
    font: 14px/1.45 -apple-system, "SF Mono", ui-monospace, monospace;
    padding: 24px 32px;
  }}
  h1 {{ color: var(--gold); font-weight: 500; letter-spacing: .04em; margin: 0 0 4px; font-size: 22px; }}
  .sub {{ color: var(--ink-dim); margin-bottom: 24px; font-size: 12px; }}
  .grid {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }}
  .card {{ background: var(--panel); border: 1px solid var(--rule); padding: 14px 16px; border-radius: 2px; }}
  .card .k {{ color: var(--ink-dim); font-size: 11px; text-transform: uppercase; letter-spacing: .1em; }}
  .card .v {{ color: var(--gold); font-size: 24px; font-weight: 500; margin-top: 4px; }}
  .bar {{ height: 4px; background: var(--rule); border-radius: 2px; overflow: hidden; margin-top: 8px; }}
  .bar > i {{ display: block; height: 100%; background: var(--gold); width: {pct}%; }}
  h2 {{ color: var(--gold); font-weight: 500; letter-spacing: .04em; margin: 24px 0 8px; font-size: 15px; border-bottom: 1px solid var(--rule); padding-bottom: 4px; }}
  table {{ width: 100%; border-collapse: collapse; margin-bottom: 8px; }}
  td {{ padding: 5px 10px; border-bottom: 1px solid var(--rule); vertical-align: top; }}
  tr.sec td {{ color: var(--gold-dim); font-size: 11px; text-transform: uppercase; letter-spacing: .12em; border-bottom: 1px solid var(--gold-dim); padding-top: 10px; }}
  td.status {{ width: 150px; font-weight: 500; }}
  td.title {{ width: 40%; }}
  td.ev {{ color: var(--ink-dim); font-family: "SF Mono", monospace; font-size: 12px; }}
  td.acid-letter {{ color: var(--gold); width: 24px; font-weight: 600; font-size: 18px; }}
  td.sha {{ color: var(--gold-dim); font-family: "SF Mono", monospace; width: 80px; }}
  td.when {{ color: var(--ink-dim); width: 140px; }}
  footer {{ color: var(--ink-dim); font-size: 11px; margin-top: 32px; padding-top: 16px; border-top: 1px solid var(--rule); }}
</style>
</head>
<body>

<h1>DagDB · Status Dashboard</h1>
<div class="sub">generated {now} · auto-refresh 30s · feature ledger: dashboard/features.yaml</div>

<div class="grid">
  <div class="card"><div class="k">Done</div><div class="v">{done}</div><div class="bar"><i></i></div></div>
  <div class="card"><div class="k">WIP</div><div class="v">{wip}</div></div>
  <div class="card"><div class="k">Planned</div><div class="v">{planned}</div></div>
  <div class="card"><div class="k">Blocked</div><div class="v">{blocked}</div></div>
</div>

<h2>ACID</h2>
<table>
{acid_rows}
</table>

<h2>Features</h2>
<table>
{feature_rows}
</table>

<h2>Recent activity</h2>
<table>
{log_rows}
</table>

<footer>DagDB · amateur engineering project · numbers speak · errors likely</footer>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", action="store_true", help="Regenerate every 10s")
    args = ap.parse_args()

    def build_once():
        data = yaml.safe_load(FEATURES.read_text())
        OUT.write_text(render(data))
        print(f"[{dt.datetime.now():%H:%M:%S}] wrote {OUT.relative_to(ROOT)}")

    build_once()
    if args.watch:
        while True:
            time.sleep(10)
            build_once()


if __name__ == "__main__":
    main()
