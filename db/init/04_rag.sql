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
