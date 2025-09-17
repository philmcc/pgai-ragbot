-- Migration: Rename doc_chunks.chunk -> doc_chunks.chunk_text and update functions & vectorizer
BEGIN;
SET search_path = app, public;

-- 1) Rename column if it exists
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='app' AND table_name='doc_chunks' AND column_name='chunk'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='app' AND table_name='doc_chunks' AND column_name='chunk_text'
  ) THEN
    ALTER TABLE app.doc_chunks RENAME COLUMN chunk TO chunk_text;
  END IF;
END$$;

-- 2) Recreate process_pending_documents to insert into chunk_text
CREATE OR REPLACE FUNCTION app.process_pending_documents()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
BEGIN
  WITH new_docs AS (
    SELECT d.id, d.content_text
    FROM app.documents d
    LEFT JOIN app.doc_chunks c ON c.doc_id = d.id
    WHERE c.doc_id IS NULL
  ), ins AS (
    INSERT INTO app.doc_chunks (doc_id, seq, chunk_text, char_start, char_end, section_path)
    SELECT nd.id, c.seq, c.chunk, c.char_start, c.char_end, c.section_path
    FROM new_docs nd
    CROSS JOIN LATERAL app.agentic_chunk_text(nd.content_text, 1400, 400) c
    RETURNING 1
  )
  SELECT COALESCE(count(*),0) INTO v_count FROM ins;
  RETURN v_count;
END;
$$;

-- 3) Recreate search_chunks to select chunk_text
CREATE OR REPLACE FUNCTION app.search_chunks(p_query text, k int DEFAULT 5, p_threshold float4 DEFAULT 0.8)
RETURNS TABLE(doc_id bigint, seq int, chunk text, distance float4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_embed vector(1536);
  v_model text := app.embedding_model();
  v_api_key text := NULLIF(current_setting('ai.openai_api_key', true), '');
BEGIN
  v_embed := ai.openai_embed(v_model, p_query, api_key=>v_api_key);
  RETURN QUERY
  WITH scored AS (
    SELECT c.doc_id, c.seq, c.chunk_text AS chunk, (c.embedding <=> v_embed)::float4 AS distance
    FROM app.doc_chunks c
    WHERE c.embedding IS NOT NULL
    ORDER BY c.embedding <=> v_embed
    LIMIT GREATEST(k, 20)
  )
  SELECT s.doc_id, s.seq, s.chunk, s.distance
  FROM scored s
  WHERE p_threshold IS NULL OR s.distance < p_threshold
  ORDER BY s.distance
  LIMIT k;
END;
$$;

-- 4) Create or update vectorizer to use chunk_text as loading column
DO $$
DECLARE
  v_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables WHERE table_schema='ai' AND table_name='vectorizers'
  ) INTO v_exists;
  IF v_exists THEN
    -- Try to create vectorizer (idempotent)
    PERFORM ai.create_vectorizer(
      'app.doc_chunks'::regclass,
      if_not_exists => true,
      loading      => ai.loading_column('chunk_text'),
      chunking     => ai.chunking_none(),
      embedding    => ai.embedding_openai('text-embedding-3-small', 1536, api_key_name => 'OPENAI_API_KEY'),
      destination  => ai.destination_column('embedding'),
      scheduling   => ai.scheduling_timescaledb('1 minute')
    );
  ELSE
    RAISE NOTICE 'ai.vectorizer catalog not found; skipping vectorizer creation';
  END IF;
END$$;

COMMIT;
