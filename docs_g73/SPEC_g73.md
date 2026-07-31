# SPEC — G73 fsync/durability hardening (frozen 2026-08-01, polar day)

Scope (from queen's G73 + dag's 2026-05-12 adversarial pinning, unchanged):
1. **WAL batch knob.** WAL fsyncs every record today (keep as DEFAULT).
   Add opt-in group-commit: batch by (N records | T ms), whichever first;
   crash loses at most the unsynced tail — bound EXPLICIT and tested.
   Config via daemon env/verb; per-env default: prod = per-record
   (+F_FULLFSYNC), dev/test = batchable.
2. **Snapshot SHA-256 manifest.** Snapshot save already does
   tmp → F_FULLFSYNC → rename → dir-fsync (verify, don't rewrite). Add
   side-by-side `<snapshot>.sha256`; loader verifies BEFORE buffers are
   touched; mismatch = refuse load with named error (fail loud, never
   half-load). Does not protect directory-level corruption — documented.
3. **Kill-9 stress probe.** External script: write loop at ~1k ops/s,
   `kill -9` mid-write, ≥10 iterations; reload must (a) pass manifest
   verification, (b) replay WAL to a state equal to ground-truth minus
   at most the frozen batch bound. Plus a committed in-suite acceptance
   test (deterministic, no kill: torn-tail WAL file fixture must replay
   to the pre-tail state and report the truncation).

Non-goals: no WAL format change; no compression; no multi-file WAL.
