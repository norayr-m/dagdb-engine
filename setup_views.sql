-- DagDB Views — Make graph data visible in DBeaver/pgAdmin
-- Run this after CREATE EXTENSION pg_dagdb;
-- Daemon must be running: .build/debug/dagdb-daemon --grid 256

-- View: all nodes with their properties
CREATE OR REPLACE VIEW dagdb_nodes AS
SELECT node_id, rank, truth, node_type
FROM dagdb_exec('NODES AT RANK 0')
WHERE node_id IS NOT NULL;

-- View: graph status as a row
CREATE OR REPLACE VIEW dagdb_status_view AS
SELECT message AS status
FROM dagdb_exec('STATUS')
WHERE message IS NOT NULL;

-- View: graph statistics
CREATE OR REPLACE VIEW dagdb_info AS
SELECT message AS info
FROM dagdb_exec('GRAPH INFO')
WHERE message IS NOT NULL;

-- Convenience function: tick and return results
CREATE OR REPLACE FUNCTION dagdb_run(n integer DEFAULT 1)
RETURNS TABLE(node_id integer, rank smallint, truth smallint, node_type smallint, message text) AS $$
    SELECT * FROM dagdb_exec('TICK ' || n);
$$ LANGUAGE sql;

-- Convenience function: get nodes at specific rank
CREATE OR REPLACE FUNCTION dagdb_rank(r integer)
RETURNS TABLE(node_id integer, rank smallint, truth smallint, node_type smallint, message text) AS $$
    SELECT * FROM dagdb_exec('NODES AT RANK ' || r);
$$ LANGUAGE sql;

-- Convenience function: traverse from a node
CREATE OR REPLACE FUNCTION dagdb_traverse(from_node integer, depth integer DEFAULT 2)
RETURNS TABLE(node_id integer, rank smallint, truth smallint, node_type smallint, message text) AS $$
    SELECT * FROM dagdb_exec('TRAVERSE FROM ' || from_node || ' DEPTH ' || depth);
$$ LANGUAGE sql;

-- Example queries to try in DBeaver:
--
--   SELECT * FROM dagdb_nodes;
--   SELECT * FROM dagdb_status_view;
--   SELECT * FROM dagdb_info;
--   SELECT * FROM dagdb_run(10);
--   SELECT * FROM dagdb_rank(2);
--   SELECT * FROM dagdb_traverse(42, 3);
--
--   -- Count nodes by rank:
--   SELECT rank, COUNT(*) FROM dagdb_nodes GROUP BY rank ORDER BY rank;
--
--   -- Find all true nodes:
--   SELECT * FROM dagdb_nodes WHERE truth = 1;
