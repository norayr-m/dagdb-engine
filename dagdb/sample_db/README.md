# Sample DB

One tracked sample lives here, by policy (single-sample allow-list;
every other `*.dags` / `*.dagdb` in the repo is gitignored).

## `demo_graph.dagdb`

Tiny ranked DAG used by the quick-start tutorial and the smoke
tests. Text-format DSL, a few hundred bytes. Structure:

```
Rank 0:  Root          (OR)
Rank 1:  mid            (OR)
Rank 2:  Leaf0 .. Leaf5 (IDENTITY, truth = 1)
```

Load it:

```
cd ..
.build/release/dagdb-daemon --grid 16 &
while IFS= read -r line; do
  echo "$line" | nc -U /tmp/dagdb.sock
done < sample_db/demo_graph.dagdb
```

Or through the MCP server's `dagdb_load` tool.

## Anything else belongs in `~/dag_databases/`

Per the standing rule: all user DB content lives under
`~/dag_databases/`. The daemon's `DAGDB_DATA_ROOT` guard will
refuse `SAVE`/`LOAD`/`BACKUP` paths outside that directory. Do
not copy `.dagdb` or `.dags` files into this directory — the
repo gitignore will still block them, but the intent is: one
named demo here, everything else in the private root.
