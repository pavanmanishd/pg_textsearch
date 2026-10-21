-- A backend reuses a cached segment page map only while the segment's
-- root page is unchanged.  Reclaim a segment, reuse its pages for a new
-- segment of the same size in the same session, and check that queries
-- read the new segment.
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
SET pg_textsearch.memtable_pages_threshold = 0;
SET pg_textsearch.bulk_load_threshold = 0;
SET enable_seqscan = off;

CREATE TABLE page_map_docs (id int, body text)
    WITH (autovacuum_enabled = false);
CREATE INDEX page_map_idx ON page_map_docs
    USING bm25 (body) WITH (text_config = 'english', compaction = 'manual');

INSERT INTO page_map_docs
SELECT g, 'alpha filler ' || g FROM generate_series(1, 3000) g;
SELECT bm25_spill_index('page_map_idx') > 0 AS spilled;

SELECT count(*) AS alpha FROM (
    SELECT 1 FROM page_map_docs
    ORDER BY body <@> to_bm25query('alpha', 'page_map_idx')
    LIMIT 10000
) s;

INSERT INTO page_map_docs
SELECT g, 'beta filler ' || g FROM generate_series(3001, 6000) g;
SELECT bm25_spill_index('page_map_idx') > 0 AS spilled;
SELECT bm25_force_merge('page_map_idx');
VACUUM page_map_docs;

INSERT INTO page_map_docs
SELECT g, 'gamma filler ' || g FROM generate_series(6001, 9000) g;
SELECT bm25_spill_index('page_map_idx') > 0 AS spilled;

SELECT count(*) AS alpha FROM (
    SELECT 1 FROM page_map_docs
    ORDER BY body <@> to_bm25query('alpha', 'page_map_idx')
    LIMIT 10000
) s;
SELECT count(*) AS gamma FROM (
    SELECT 1 FROM page_map_docs
    ORDER BY body <@> to_bm25query('gamma', 'page_map_idx')
    LIMIT 10000
) s;
SELECT count(*) AS filler FROM (
    SELECT 1 FROM page_map_docs
    ORDER BY body <@> to_bm25query('filler', 'page_map_idx')
    LIMIT 10000
) s;

DROP TABLE page_map_docs;
DROP EXTENSION pg_textsearch CASCADE;
