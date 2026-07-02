# Contributing

> **Humble disclaimer.** Amateur engineering project. We are not HPC
> professionals and make no competitive claims. Errors likely.

This is a private research prototype that happens to be readable in
public. There is no sponsorship, no roadmap commitment, and no SLA.
Contributions are welcome in the same spirit.

## Before you open a PR

- Open an issue first. Describe what problem you're trying to solve
  and point at the place in the code. A paragraph is enough.
- Assume the maintainer has already noticed the thing you want to fix
  and has a reason for not fixing it. Ask what the reason is; you may
  be right anyway.
- Don't rewrite code you haven't read end to end. Small, surgical
  changes are much easier to land than sweeping refactors.
- No rush. This is a slow project.

## Style

- **Swift.** `swift build` + `swift test` under `dagdb/` must stay
  green. 98 Swift tests today, ≤ 3 s total runtime. Python plugin
  tests (`plugins/biology` self-test, `plugins/loom/test_adapter.py`)
  must also stay green; 16 in the adapter suite.
- **Comments.** None unless the reason is non-obvious. Don't explain
  what the code does; well-named identifiers do that.
- **No emojis** in code or docs unless the existing file already uses
  them.
- **No famous-name comparisons** ("this is the Dijkstra of X") unless
  the parallel is genuinely there — and even then, keep it to one
  mention.
- **Humble disclaimer.** Every new top-level document gets one. Copy
  the block from `README.md`.

## Tests

Add tests with new code. The suites are organised by module:

```
swift test --filter DagDBSnapshotTests
swift test --filter DagDBJSONIOTests
swift test --filter DagDBBackupTests
swift test --filter DagDBDistanceTests
swift test --filter DagDBWALTests
swift test --filter DagDBBFSTests
swift test --filter DagDBReaderSessionTests
swift test --filter DagDBSecondaryIndexTests
```

Python plugin tests:

```
python3 plugins/biology/rank_policies.py
python3 -m pytest plugins/loom/test_adapter.py -q
```

For mathematically load-bearing features (new distance metrics,
persistence formats, WAL opcodes), a test that pins a closed-form
result is worth more than five round-trip tests. Example: the
Laplacian spectrum of `K_{1,6}` is exactly `{0, 1, 1, 1, 1, 1, 7}` —
`testSpectralL2OnStar` pins that.

## Commits

- Concise subject, 72 cols max. Present tense. No trailing period.
- Body explains the "why" more than the "what". One to three short
  paragraphs is the norm.
- Group by logical unit, not by file. A WAL commit should not also
  bring in dashboard changes.
- No force-pushes to shared branches. Amend only local commits that
  haven't been pushed.

## License

All contributions are accepted under GPL-3.0 (see `LICENSE`). By
submitting a patch you confirm you have the right to release it under
that licence.

## Not in scope

- Production deployment advice.
- Benchmarks against other databases.
- Framework ports to platforms other than Apple Silicon (not because
  we object; because we can't test them).
- Security review. This is a research prototype, not a hardened
  system.

## Humble disclaimer

This project makes no competitive claims. Numbers speak. Errors likely.
