-- Unit coverage for the in-memory memtable cache TpDataSource
-- (cache_source.c; see ARCHITECTURE.md, "Memtable Cache").
--
-- Drives bm25_test_cache_source directly so we can observe the
-- TpDataSource interface (open / total_docs / get_postings /
-- get_doc_freq / get_doc_length / close) backed by the cache
-- rather than the chain, without going through the query
-- planner.

CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE TABLE cache_source_t (id int, body text);
CREATE INDEX cache_source_idx ON cache_source_t
    USING bm25 (body) WITH (text_config = 'english');

-- ---------- empty memtable ----------
-- An empty memtable yields a NULL cache source, just like the
-- chain source does.
SELECT bm25_test_cache_source('cache_source_idx', 'empty');

-- ---------- populate and serve ----------
INSERT INTO cache_source_t
SELECT g, 'shared term ' || g
  FROM generate_series(1, 5) g;

-- Opening a cache source over a 5-doc memtable reports
-- total_docs = 5 and a non-zero total_len.  We assert
-- structurally to avoid pinning the tokenizer's exact length
-- output.
SELECT split_part(bm25_test_cache_source('cache_source_idx', 'open'),
                  ',',
                  1) AS total_docs_clause;

SELECT (split_part(
            split_part(bm25_test_cache_source('cache_source_idx', 'open'),
                       ',',
                       2),
            '=',
            2)::bigint > 0) AS total_len_positive;

-- get_postings via the cache: 'shared' appears in every
-- document.  We snapshot doc_freq = 5 (all five docs) and
-- count = 5 (one CTID per occurrence).  Tokenizer stemming may
-- shape the lexeme, so we look up the stemmed form 'share'.
SELECT bm25_test_cache_source('cache_source_idx', 'lookup:share');

-- A term that doesn't exist returns 'miss:df=0'.
SELECT bm25_test_cache_source('cache_source_idx', 'lookup:nonexistentterm');

-- get_doc_length via the cache: doc 1 is at heap block 0,
-- offset 1.  We don't pin the exact length (depends on tokens
-- after stemming), only that the lookup succeeds.
SELECT (split_part(
            split_part(bm25_test_cache_source(
                           'cache_source_idx',
                           'doclen:0'),
                       ':',
                       2),
            '=',
            2)::int >= 0) AS doc_length_lookup_ok;

-- ---------- end-to-end equivalence (chain vs cache) ----------
-- With the cache GUC off the read path uses chain_source; with
-- it on the read path uses cache_source.  Either way the BM25
-- ranking must be identical because the cache is derived state
-- over the same chain.

SET pg_textsearch.memtable_cache_enabled = off;
SELECT id, body
  FROM cache_source_t
 ORDER BY body <@> to_bm25query('shared', 'cache_source_idx')
 LIMIT 3;

SET pg_textsearch.memtable_cache_enabled = on;
SELECT id, body
  FROM cache_source_t
 ORDER BY body <@> to_bm25query('shared', 'cache_source_idx')
 LIMIT 3;

RESET pg_textsearch.memtable_cache_enabled;

-- ---------- retained endpoint after the cache moves on ----------
-- A cursor keeps the memtable endpoint its scan started at.  An
-- INSERT and a ranked query in the same transaction advance the
-- cache past that endpoint, so the cursor's later scoring passes
-- cannot use the cache and read the bounded chain instead.  The
-- cursor must still return exactly the rows of its endpoint.
CREATE TABLE cache_source_snap (id int, body text);
CREATE INDEX cache_source_snap_idx ON cache_source_snap
    USING bm25 (body) WITH (text_config = 'english');
SET pg_textsearch.memtable_pages_threshold = 0;
SET pg_textsearch.bulk_load_threshold = 0;
INSERT INTO cache_source_snap
SELECT g, 'apple filler ' || g
  FROM generate_series(1, 2000) g;
SET pg_textsearch.default_limit = 10;

CREATE FUNCTION cache_source_snap_ids() RETURNS int[]
LANGUAGE plpgsql AS $$
DECLARE
    c CURSOR FOR
        SELECT id FROM cache_source_snap
         WHERE id % 100 = 0
         ORDER BY body <@> to_bm25query('apple', 'cache_source_snap_idx');
    r record;
    ids int[] := '{}';
BEGIN
    OPEN c;
    FETCH c INTO r;
    ids := ids || r.id;
    INSERT INTO cache_source_snap VALUES (2100, 'apple late');
    PERFORM count(*) FROM (
        SELECT id FROM cache_source_snap
         ORDER BY body <@> to_bm25query('apple', 'cache_source_snap_idx')
         LIMIT 5) s;
    LOOP
        FETCH c INTO r;
        EXIT WHEN NOT FOUND;
        ids := ids || r.id;
    END LOOP;
    CLOSE c;
    RETURN ids;
END
$$;

SELECT array_length(ids, 1) AS fetched,
       ARRAY(SELECT unnest(ids) ORDER BY 1)
           = ARRAY(SELECT g * 100 FROM generate_series(1, 20) g)
           AS endpoint_rows
  FROM cache_source_snap_ids() ids;

DROP FUNCTION cache_source_snap_ids();
DROP TABLE cache_source_snap;
RESET pg_textsearch.default_limit;
RESET pg_textsearch.bulk_load_threshold;
RESET pg_textsearch.memtable_pages_threshold;

DROP INDEX cache_source_idx;
DROP TABLE cache_source_t;
DROP EXTENSION pg_textsearch CASCADE;
