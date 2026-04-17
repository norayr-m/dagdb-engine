# Sample Databases

## power_grid.dagdb

A ranked DAG representing a power grid monitoring system.

```
Rank 3 (Sensors):    18 nodes — voltage, current, temperature readings
Rank 2 (Zones):       3 nodes — North (AND), South (MAJORITY), East (OR)
Rank 1 (Grid):        1 node  — grid controller (AND of all zones)
Rank 0 (Decision):    1 node  — final decision (IDENTITY pass-through)
```

3 faults injected: nodes 109, 114, 116.

### Load it

```bash
./dagdb start --data sample_db/
```

Or manually:

```bash
./dagdb start
while IFS= read -r line; do ./dagdb query "$line"; done < sample_db/power_grid.dagdb
```
