# Dashboard

Live status page for DagDB — feature ledger, ACID row, recent git
activity. Dark gold, auto-refreshes every 30 seconds.

## Files

- `features.yaml` — single source of truth: sections + features + ACID
  status. Edit here; dashboard rebuilds from it.
- `gen_dashboard.py` — reads YAML + `git log`, writes `index.html`.
- `index.html` — generated. Open in Chrome.

## Commands

One-shot render:

    python3 dashboard/gen_dashboard.py

Watch mode (regenerates every 10 s while source code changes):

    python3 dashboard/gen_dashboard.py --watch

Open in Chrome (macOS):

    open -a "Google Chrome" dashboard/index.html

## Status glyphs

- `●` done / pass
- `◐` wip / partial
- `○` planned
- `✗` blocked / fail

## ACID row

The `acid:` block in `features.yaml` mirrors A/C/I/D properties. Each
property carries a short note describing the test evidence or current
gap. Keep it honest — amateur project, errors likely.

## Why not a server

Static HTML is the point. No daemon to keep alive, no port to bind,
nothing to break. Rebuild on demand or in `--watch`. The browser's
meta-refresh does the rest.
