-- Episode 3: Hybrid Search migration
SET search_path = app, public;

-- 1) Add tsvector column for lexical search and index
ALTER TABLE app.doc_chunks
  ADD COLUMN IF NOT EXISTS lexeme tsvector;

-- Backfill existing rows
UPDATE app.doc_chunks
SET lexeme = to_tsvector('english', COALESCE(chunk_text, ''))
WHERE lexeme IS NULL;

-- Trigger to maintain lexeme on insert/update
CREATE OR REPLACE FUNCTION app.trg_update_doc_chunks_lexeme()
RETURNS trigger LANGUAGE plpgsql AS $FN$
BEGIN
  NEW.lexeme := to_tsvector('english', COALESCE(NEW.chunk_text, ''));
  RETURN NEW;
END;
$FN$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = 'trg_update_doc_chunks_lexeme'
      AND n.nspname = 'app'
      AND c.relname = 'doc_chunks'
  ) THEN
    CREATE TRIGGER trg_update_doc_chunks_lexeme
      BEFORE INSERT OR UPDATE OF chunk_text ON app.doc_chunks
      FOR EACH ROW EXECUTE FUNCTION app.trg_update_doc_chunks_lexeme();
  END IF;
END $$ LANGUAGE plpgsql;

-- GIN index for FTS
CREATE INDEX IF NOT EXISTS doc_chunks_lexeme_gin ON app.doc_chunks USING GIN (lexeme);

-- 2) Hybrid search function (lexical + semantic with weighted fusion)
CREATE OR REPLACE FUNCTION app.search_chunks_hybrid(p_query text,
                                                   k int DEFAULT 5,
                                                   p_w_lex float4 DEFAULT 0.5,
                                                   p_w_sem float4 DEFAULT 0.5)
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
  WITH lex AS (
    SELECT c.doc_id, c.seq, c.chunk_text AS chunk,
           ts_rank_cd(c.lexeme, plainto_tsquery('english', p_query)) AS lex_score
    FROM app.doc_chunks c
    WHERE c.lexeme IS NOT NULL
      AND c.lexeme @@ plainto_tsquery('english', p_query)
    ORDER BY lex_score DESC
    LIMIT GREATEST(k, 20)
  ),
  sem AS (
    SELECT c.doc_id, c.seq, c.chunk_text AS chunk,
           (1.0 - (c.embedding <=> v_embed)) AS sem_score
    FROM app.doc_chunks c
    WHERE c.embedding IS NOT NULL
    ORDER BY c.embedding <=> v_embed
    LIMIT GREATEST(k, 20)
  ),
  unioned AS (
    SELECT doc_id, seq, chunk, lex_score, NULL::float8 AS sem_score FROM lex
    UNION ALL
    SELECT doc_id, seq, chunk, NULL::float8 AS lex_score, sem_score FROM sem
  ),
  aggr AS (
    SELECT u.doc_id, u.seq,
           max(u.chunk) AS chunk,
           max(lex_score) AS lex_score,
           max(sem_score) AS sem_score
    FROM unioned u
    GROUP BY u.doc_id, u.seq
  ),
  stats AS (
    SELECT
      min(lex_score) FILTER (WHERE lex_score IS NOT NULL) AS min_lex,
      max(lex_score) FILTER (WHERE lex_score IS NOT NULL) AS max_lex,
      min(sem_score) FILTER (WHERE sem_score IS NOT NULL) AS min_sem,
      max(sem_score) FILTER (WHERE sem_score IS NOT NULL) AS max_sem
    FROM aggr
  ),
  final AS (
    SELECT a.doc_id, a.seq, a.chunk,
           COALESCE((a.lex_score - s.min_lex) / NULLIF(s.max_lex - s.min_lex, 0), 0) AS lex_norm,
           COALESCE((a.sem_score - s.min_sem) / NULLIF(s.max_sem - s.min_sem, 0), 0) AS sem_norm
    FROM aggr a
    CROSS JOIN stats s
  )
  SELECT f.doc_id, f.seq, f.chunk,
         (1.0 - (p_w_lex * f.lex_norm + p_w_sem * f.sem_norm))::float4 AS distance
  FROM final f
  ORDER BY (p_w_lex * f.lex_norm + p_w_sem * f.sem_norm) DESC
  LIMIT k;
END;
$$;

GRANT EXECUTE ON FUNCTION app.search_chunks_hybrid(text, int, float4, float4) TO anon;

-- 3) Update chat to use hybrid search
CREATE OR REPLACE FUNCTION app.chat_rag(p_query text, k int DEFAULT 5)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ctx text;
  v_resp text;
  v_model text := app.chat_model();
  v_api_key text := NULLIF(current_setting('ai.openai_api_key', true), '');
BEGIN
  IF p_query ~* '(list|show|which|what).*(document|documents|doc|docs|file|files)'
     OR p_query ~* '(document|documents|doc|docs|file|files).*(do you have|are stored|do you store)'
  THEN
    SELECT COALESCE(
             'The documents I have are:\n\n' || string_agg(
               format('%s. %s', rn, s3_key),
               E'\n'
             ),
             'I have no documents yet.'
           )
    INTO v_resp
    FROM (
      SELECT row_number() OVER (ORDER BY created_at DESC) AS rn, s3_key
      FROM app.documents
    ) t;
    RETURN v_resp;
  END IF;

  SELECT string_agg(
           format('Doc %s (%s) #%s: %s', s.doc_id, d.s3_key, s.seq, s.chunk),
           E'\n\n'
         )
  INTO v_ctx
  FROM app.search_chunks_hybrid(p_query, k) s
  JOIN app.documents d ON d.id = s.doc_id;

  IF v_ctx IS NULL OR v_ctx = '' THEN
    SELECT string_agg(format('Doc %s: %s', d.id, d.s3_key), E'\n')
    INTO v_ctx
    FROM app.documents d;
    v_ctx := COALESCE(v_ctx, '');
  END IF;

  SELECT ai.openai_chat_complete(
    v_model,
    jsonb_build_array(
      jsonb_build_object('role','system','content','You are a helpful assistant. Answer using only the provided context. If the answer is not in the context, say you do not know.'),
      jsonb_build_object('role','user','content', p_query || E'\n\nContext:\n' || v_ctx)
    ),
    api_key => v_api_key
  )->'choices'->0->'message'->>'content'
  INTO v_resp;

  RETURN v_resp;
END;
$$;

GRANT EXECUTE ON FUNCTION app.chat_rag(text, int) TO anon;
