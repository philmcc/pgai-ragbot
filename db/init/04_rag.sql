-- Remove legacy overload before redefining with expanded parameters
DROP FUNCTION IF EXISTS app.chat_rag_opts(text, int);
DROP FUNCTION IF EXISTS app.chat_rag_opts(text, int, text, float4, float4, int);

-- Chat completion with retrieval options
CREATE OR REPLACE FUNCTION app.chat_rag_opts(
  p_query             text,
  k                   int    DEFAULT 5,
  p_mode              text   DEFAULT 'semantic',  -- semantic | hybrid | semantic_rerank | hybrid_rerank | rerank
  p_w_lex             float4 DEFAULT 0.5,
  p_w_sem             float4 DEFAULT 0.5,
  p_pin_sem           int    DEFAULT 3,           -- pin top-N semantic hits to "do no harm"
  p_stage_k           int    DEFAULT NULL,
  p_use_rerank        boolean DEFAULT false,
  p_rerank_stage_mode text   DEFAULT NULL,
  p_rerank_model      text   DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ctx   text;
  v_resp  text;
  v_model text := app.chat_model();
  v_api_key text := NULLIF(current_setting('ai.openai_api_key', true), '');
  v_mode text := lower(coalesce(p_mode, 'semantic'));
  v_pin_sem int := GREATEST(COALESCE(p_pin_sem, 0), 0);
  v_stage_k int := COALESCE(p_stage_k, LEAST(200, GREATEST(k * 4, 40)));
  v_rerank boolean := COALESCE(p_use_rerank, false);
  v_stage_mode text;
  v_rerank_stage_mode text;
  v_rerank_model text := COALESCE(NULLIF(p_rerank_model, ''), app.rerank_model());
BEGIN
  -- Intent: answer deterministic document list questions
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

  IF v_mode IN ('rerank', 'hybrid_rerank', 'semantic_rerank') THEN
    v_rerank := true;
  END IF;

  v_stage_mode := CASE
                    WHEN v_mode IN ('semantic', 'semantic_rerank') THEN 'semantic'
                    WHEN v_mode = 'hybrid' THEN 'hybrid'
                    ELSE 'hybrid'
                  END;
  v_rerank_stage_mode := lower(coalesce(p_rerank_stage_mode, v_stage_mode));

  IF v_rerank THEN
    WITH reranked AS (
      SELECT 1 AS pri,
             r.doc_id,
             r.seq,
             r.chunk,
             r.distance,
             r.rerank_score,
             row_number() OVER (ORDER BY COALESCE(r.rerank_score, -1e9) DESC, r.distance ASC) AS ord
      FROM app.search_chunks_rerank(
        p_query,
        GREATEST(k, 1),
        v_stage_k,
        v_rerank_stage_mode,
        COALESCE(p_w_lex, 0.5),
        COALESCE(p_w_sem, 0.5),
        v_rerank_model,
        NULL::text
      ) r
    ), sem_pin AS (
      SELECT 0 AS pri,
             s.doc_id,
             s.seq,
             s.chunk,
             s.distance,
             NULL::float4 AS rerank_score,
             row_number() OVER (ORDER BY s.distance ASC) AS ord
      FROM app.search_chunks(p_query, v_pin_sem, NULL) s
      WHERE v_pin_sem > 0
    ), combined AS (
      SELECT * FROM sem_pin
      UNION ALL
      SELECT * FROM reranked
    ), dedup AS (
      SELECT DISTINCT ON (doc_id, seq)
             doc_id,
             seq,
             chunk,
             distance,
             rerank_score,
             pri,
             ord
      FROM combined
      ORDER BY doc_id, seq, pri, ord
    ), final AS (
      SELECT *,
             CASE
               WHEN pri = 0 THEN distance::float8
               ELSE -COALESCE(rerank_score::float8, (1.0 - distance)::float8)
             END AS sort_key
      FROM dedup
      ORDER BY pri, sort_key
      LIMIT k
    )
    SELECT string_agg(
             'Doc ' || f.doc_id ||
             ' (' || d.s3_key || ') #' || f.seq ||
             ' [score=' || to_char(COALESCE(f.rerank_score, 1.0 - f.distance), 'FM999990.000') || ']: ' ||
             f.chunk,
             E'\n\n'
           )
    INTO v_ctx
    FROM final f
    JOIN app.documents d ON d.id = f.doc_id;

  ELSIF v_mode = 'hybrid' THEN
    WITH sem_top AS (
      SELECT * FROM app.search_chunks(p_query, GREATEST(COALESCE(p_pin_sem, 0), 0), NULL)
    ),
    hyb_top AS (
      SELECT * FROM app.search_chunks_hybrid(p_query, k, COALESCE(p_w_lex,0.5), COALESCE(p_w_sem,0.5))
    ),
    combined AS (
      SELECT 0 AS pri, s.doc_id, s.seq, s.chunk, s.distance FROM sem_top s
      UNION ALL
      SELECT 1 AS pri, h.doc_id, h.seq, h.chunk, h.distance FROM hyb_top h
    ),
    dedup AS (
      SELECT DISTINCT ON (doc_id, seq) doc_id, seq, chunk, distance, pri
      FROM combined
      ORDER BY doc_id, seq, pri ASC, distance ASC
    ),
    final AS (
      SELECT *
      FROM dedup
      ORDER BY pri ASC, distance ASC
      LIMIT k
    )
    SELECT string_agg(
             format('Doc %s (%s) #%s: %s', f.doc_id, d.s3_key, f.seq, f.chunk),
             E'\n\n'
           )
    INTO v_ctx
    FROM final f
    JOIN app.documents d ON d.id = f.doc_id;
  ELSE
    -- semantic-only (original)
    SELECT string_agg(
             format('Doc %s (%s) #%s: %s', s.doc_id, d.s3_key, s.seq, s.chunk),
             E'\n\n'
           )
    INTO v_ctx
    FROM app.search_chunks(p_query, k, NULL) s
    JOIN app.documents d ON d.id = s.doc_id;
  END IF;

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
-- RAG search + chat functions
SET search_path = app, public;

-- Ensure no ambiguous overload remains
DROP FUNCTION IF EXISTS app.search_chunks(text, int);

-- Flag to indicate whether reranker calls are permitted (controlled via env RERANK_ENABLED)
CREATE OR REPLACE FUNCTION app.rerank_enabled()
RETURNS boolean
LANGUAGE plpython3u
AS $$
import os
return os.environ.get('RERANK_ENABLED', 'true').strip().lower() in ('1', 'true', 'yes', 'on')
$$;

GRANT EXECUTE ON FUNCTION app.rerank_enabled() TO anon;

-- Invoke external reranker service (PL/Python)
CREATE OR REPLACE FUNCTION app.invoke_reranker(
  p_model text,
  p_query text,
  p_chunks text[],
  p_endpoint text DEFAULT NULL,
  p_timeout_seconds int DEFAULT 15
)
RETURNS float8[]
LANGUAGE plpython3u
AS $$
import json
import os
import urllib.request
from urllib.error import URLError, HTTPError

enabled_res = plpy.execute("SELECT app.rerank_enabled() AS enabled", 1)
if not enabled_res or not enabled_res[0]['enabled']:
    return None

endpoint = p_endpoint or os.environ.get('RERANK_ENDPOINT', 'http://reranker:8000/rerank')
if not endpoint:
    plpy.warning('invoke_reranker: endpoint missing')
    return None

payload = {
    'model': p_model or '',
    'query': p_query or '',
    'documents': list(p_chunks or [])
}

req = urllib.request.Request(
    endpoint,
    data=json.dumps(payload).encode('utf-8'),
    headers={'Content-Type': 'application/json'}
)

timeout = p_timeout_seconds or 15

try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode('utf-8')
        data = json.loads(body)
        scores = data.get('scores')
        if not isinstance(scores, list):
            raise ValueError('missing scores array')
        return [float(s) for s in scores]
except (HTTPError, URLError, ValueError, TimeoutError, Exception) as exc:  # pylint: disable=broad-except
    plpy.warning(f'invoke_reranker failed: {exc}')
    return None
$$;

GRANT EXECUTE ON FUNCTION app.invoke_reranker(text, text, text[], text, int) TO anon;

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

-- Two-stage retrieval with reranking
CREATE OR REPLACE FUNCTION app.search_chunks_rerank(
  p_query text,
  k int DEFAULT 5,
  p_stage_k int DEFAULT 40,
  p_stage_mode text DEFAULT 'hybrid',
  p_w_lex float4 DEFAULT 0.3,
  p_w_sem float4 DEFAULT 0.7,
  p_rerank_model text DEFAULT NULL,
  p_endpoint text DEFAULT NULL
)
RETURNS TABLE(doc_id bigint, seq int, chunk text, distance float4, rerank_score float4)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_stage_mode text := lower(coalesce(p_stage_mode, 'hybrid'));
  v_stage_k int := GREATEST(COALESCE(p_stage_k, 0), k, 5);
  v_model text := COALESCE(NULLIF(p_rerank_model, ''), app.rerank_model());
  v_chunks text[];
  v_doc_ids bigint[];
  v_seqs int[];
  v_distances float4[];
  v_scores float8[];
  v_has_scores boolean := false;
BEGIN
  WITH stage_raw AS (
    SELECT
      s.doc_id,
      s.seq,
      s.chunk,
      s.distance
    FROM app.search_chunks(p_query, v_stage_k, NULL) s
    WHERE v_stage_mode = 'semantic'
    UNION ALL
    SELECT
      h.doc_id,
      h.seq,
      h.chunk,
      h.distance
    FROM app.search_chunks_hybrid(p_query, v_stage_k, p_w_lex, p_w_sem) h
    WHERE v_stage_mode <> 'semantic'
  ), dedup AS (
    SELECT DISTINCT ON (sr.doc_id, sr.seq)
      sr.doc_id,
      sr.seq,
      sr.chunk,
      sr.distance
    FROM stage_raw sr
    ORDER BY sr.doc_id, sr.seq, sr.distance
  ), stage_ranked AS (
    SELECT
      row_number() OVER (ORDER BY d.distance ASC, d.doc_id, d.seq) AS stage_rank,
      d.doc_id,
      d.seq,
      d.chunk,
      d.distance
    FROM dedup d
  )
  SELECT
    array_agg(srk.chunk ORDER BY srk.stage_rank)      AS chunks,
    array_agg(srk.doc_id ORDER BY srk.stage_rank)     AS doc_ids,
    array_agg(srk.seq ORDER BY srk.stage_rank)        AS seqs,
    array_agg(srk.distance ORDER BY srk.stage_rank)   AS distances
  INTO v_chunks, v_doc_ids, v_seqs, v_distances
  FROM stage_ranked srk;

  IF v_chunks IS NULL OR array_length(v_chunks, 1) IS NULL THEN
    RETURN;
  END IF;

  SELECT app.invoke_reranker(v_model, p_query, v_chunks, p_endpoint, 20)
  INTO v_scores;

  v_has_scores := v_scores IS NOT NULL AND array_length(v_scores, 1) IS NOT NULL;

  INSERT INTO rerank_events(query, doc_id, seq, stage_rank, stage_distance, rerank_score, rerank_model)
  SELECT
    p_query,
    v_doc_ids[g.idx],
    v_seqs[g.idx],
    g.idx,
    v_distances[g.idx],
    CASE
      WHEN v_has_scores AND array_length(v_scores, 1) >= g.idx THEN v_scores[g.idx]::float4
      ELSE NULL
    END,
    v_model
  FROM generate_subscripts(v_doc_ids, 1) AS g(idx)
  WHERE g.idx <= LEAST(array_length(v_doc_ids, 1), 200);

  RETURN QUERY
  WITH ranked AS (
    SELECT
      g.idx,
      v_doc_ids[g.idx] AS doc_id,
      v_seqs[g.idx]    AS seq,
      v_chunks[g.idx]  AS chunk,
      v_distances[g.idx] AS distance,
      CASE
        WHEN v_has_scores AND array_length(v_scores, 1) >= g.idx THEN v_scores[g.idx]::float4
        ELSE NULL
      END AS rerank_score
    FROM generate_subscripts(v_doc_ids, 1) AS g(idx)
  )
  SELECT
    r.doc_id,
    r.seq,
    r.chunk,
    r.distance,
    r.rerank_score
  FROM ranked r
  ORDER BY
    CASE WHEN v_has_scores THEN r.rerank_score END DESC,
    CASE WHEN v_has_scores THEN r.idx END,
    r.distance,
    r.idx
  LIMIT k;
END;
$$;

GRANT EXECUTE ON FUNCTION app.search_chunks_rerank(text, int, int, text, float4, float4, text, text) TO anon;

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
