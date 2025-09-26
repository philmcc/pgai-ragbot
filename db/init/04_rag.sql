-- RAG search + chat functions
SET search_path = app, public;

-- Ensure no ambiguous overload remains
DROP FUNCTION IF EXISTS app.search_chunks(text, int);

-- Search function to retrieve top-k chunks with distances
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

GRANT EXECUTE ON FUNCTION app.search_chunks(text, int, float4) TO anon;

-- Hybrid search: lexical (FTS) + semantic (pgvector) with simple weighted fusion
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
  v_w_lex float4 := COALESCE(p_w_lex, 0.5);
  v_w_sem float4 := COALESCE(p_w_sem, 0.5);
BEGIN
  -- Guard against degenerate zeroed weights
  IF (v_w_lex IS NULL OR v_w_lex = 0) AND (v_w_sem IS NULL OR v_w_sem = 0) THEN
    v_w_lex := 0.5; v_w_sem := 0.5;
  END IF;
  v_embed := ai.openai_embed(v_model, p_query, api_key=>v_api_key);
  RETURN QUERY
  WITH params AS (
    SELECT websearch_to_tsquery('english', p_query) AS q,
           COALESCE(array_agg(m) FILTER (WHERE m IS NOT NULL), ARRAY[]::text[]) AS nums
    FROM regexp_matches(p_query, '\\d+', 'g') AS t(m)
  ),
  lex AS (
    SELECT c.doc_id, c.seq, c.chunk_text AS chunk,
           ts_rank_cd(c.lexeme, (SELECT q FROM params))
           + 0.2 * ts_rank_cd(to_tsvector('simple', d.s3_key), (SELECT q FROM params)) AS lex_score
    FROM app.doc_chunks c
    JOIN app.documents d ON d.id = c.doc_id
    WHERE c.lexeme IS NOT NULL
      AND (
        c.lexeme @@ (SELECT q FROM params)
        OR to_tsvector('simple', d.s3_key) @@ (SELECT q FROM params)
      )
    ORDER BY lex_score DESC
    LIMIT GREATEST(k*5, 50)
  ),
  sem AS (
    SELECT c.doc_id, c.seq, c.chunk_text AS chunk,
           (1.0 - (c.embedding <=> v_embed)) AS sem_score
    FROM app.doc_chunks c
    WHERE c.embedding IS NOT NULL
    ORDER BY c.embedding <=> v_embed
    LIMIT GREATEST(k*5, 50)
  ),
  name_matches AS (
    -- If query contains numbers (e.g., version), include chunks from docs whose filename contains that number
    SELECT c.doc_id, c.seq, c.chunk_text AS chunk,
           1.0::float8 AS lex_score -- strong lexical hint based on filename match
    FROM app.doc_chunks c
    JOIN app.documents d ON d.id = c.doc_id
    WHERE (SELECT COALESCE(array_length((SELECT nums FROM params), 1), 0)) > 0
      AND EXISTS (
        SELECT 1 FROM unnest((SELECT nums FROM params)) n
        WHERE d.s3_key ILIKE '%' || n || '%'
      )
    ORDER BY c.seq
    LIMIT GREATEST(k*2, 20)
  ),
  unioned AS (
    SELECT lex.doc_id AS doc_id,
           lex.seq    AS seq,
           lex.chunk  AS chunk,
           lex.lex_score AS lex_score,
           NULL::float8 AS sem_score
    FROM lex
    UNION ALL
    SELECT sem.doc_id AS doc_id,
           sem.seq    AS seq,
           sem.chunk  AS chunk,
           NULL::float8 AS lex_score,
           sem.sem_score AS sem_score
    FROM sem
    UNION ALL
    SELECT nm.doc_id AS doc_id,
           nm.seq    AS seq,
           nm.chunk  AS chunk,
           nm.lex_score AS lex_score,
           NULL::float8 AS sem_score
    FROM name_matches nm
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
           CASE WHEN s.max_lex IS NOT NULL AND s.min_lex IS NOT NULL AND s.max_lex > s.min_lex
                THEN (a.lex_score - s.min_lex) / NULLIF(s.max_lex - s.min_lex, 0)
                ELSE CASE WHEN a.lex_score IS NOT NULL THEN 1 ELSE 0 END
           END AS lex_norm,
           CASE WHEN s.max_sem IS NOT NULL AND s.min_sem IS NOT NULL AND s.max_sem > s.min_sem
                THEN (a.sem_score - s.min_sem) / NULLIF(s.max_sem - s.min_sem, 0)
                ELSE CASE WHEN a.sem_score IS NOT NULL THEN 1 ELSE 0 END
           END AS sem_norm
    FROM aggr a
    CROSS JOIN stats s
  ),
  with_bonus AS (
    SELECT f.doc_id, f.seq, f.chunk,
           GREATEST(0.0,
             LEAST(1.0,
               (v_w_lex * f.lex_norm + v_w_sem * f.sem_norm)
               + CASE
                   WHEN (SELECT count(*) FROM unnest((SELECT nums FROM params)) n
                         WHERE (SELECT s3_key FROM app.documents d WHERE d.id = f.doc_id) ILIKE '%' || n || '%') > 0
                   THEN 0.05 ELSE 0.0
                 END
             )
           ) AS fused
    FROM final f
  )
  SELECT b.doc_id, b.seq, b.chunk,
         (1.0 - b.fused)::float4 AS distance
  FROM with_bonus b
  ORDER BY b.fused DESC
  LIMIT k;
END;
$$;

GRANT EXECUTE ON FUNCTION app.search_chunks_hybrid(text, int, float4, float4) TO anon;

-- Chat completion that performs RAG internally and returns assistant text
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
  -- Intent: If the user is asking to list documents/files, return a complete deterministic list.
  -- Use broad, case-insensitive regex to catch common phrasings.
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
  FROM app.search_chunks(p_query, k, NULL) s
  JOIN app.documents d ON d.id = s.doc_id;

  IF v_ctx IS NULL OR v_ctx = '' THEN
    -- Fallback: provide a list of available documents to help answer queries like
    -- "what documents do you have"
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

-- Simple document list RPC (helps both UI and chat fallback)
CREATE OR REPLACE FUNCTION app.list_documents()
RETURNS TABLE(id bigint, s3_key text, created_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT d.id, d.s3_key, d.created_at
  FROM app.documents d
  ORDER BY d.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION app.list_documents() TO anon;
