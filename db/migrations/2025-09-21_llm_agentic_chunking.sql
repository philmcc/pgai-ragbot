-- LLM-assisted agentic chunking migration (idempotent)
-- Applies new functions and settings for in-DB LLM chunking using pgai
SET search_path = app, public;

-- 1) Mode selector (heuristic | llm)
CREATE OR REPLACE FUNCTION app.chunking_mode() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(NULLIF(current_setting('app.chunking_mode', true), ''), 'heuristic')
$$;

-- 2) LLM boundary planner (returns JSON array of {start,end,title|null})
CREATE OR REPLACE FUNCTION app.llm_propose_boundaries(
  p_text text,
  max_chunk_chars int DEFAULT 1400,
  min_chunk_chars int DEFAULT 400
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_model   text := app.chat_model();
  v_api_key text := NULLIF(current_setting('ai.openai_api_key', true), '');
  v_prompt  text;
  v_raw     text;
  v_json    jsonb := '[]'::jsonb;
  v_text    text;
BEGIN
  -- Fallback: pull key from app.get_openai_key() if GUC not set
  IF v_api_key IS NULL OR v_api_key = '' THEN
    BEGIN
      SELECT app.get_openai_key() INTO v_api_key;
    EXCEPTION WHEN others THEN
      v_api_key := NULL;
    END;
  END IF;

  v_text := COALESCE(p_text, '');
  IF length(v_text) > 12000 THEN
    v_text := substr(v_text, 1, 12000);
  END IF;

  v_prompt :=
    'You are a chunking planner. Output ONLY JSON array with objects {"start":int,"end":int,"title":string|null}.' || E'\n' ||
    'Rules:' || E'\n' ||
    '- Use 1-based inclusive char offsets within the provided TEXT.' || E'\n' ||
    '- Aim for chunk sizes between ' || min_chunk_chars || ' and ' || max_chunk_chars || ' characters.' || E'\n' ||
    '- Prefer boundaries at headings or paragraph breaks; avoid splitting code blocks/tables.' || E'\n' ||
    '- Do NOT include any explanations or code fences.' || E'\n\n' ||
    'TEXT:\n' || v_text;

  SELECT ai.openai_chat_complete(
           v_model,
           jsonb_build_array(
             jsonb_build_object('role','system','content','Return only JSON. No prose. Plan chunk boundaries for best Q&A.'),
             jsonb_build_object('role','user','content', v_prompt)
           ),
           api_key => v_api_key
         )->'choices'->0->'message'->>'content'
  INTO v_raw;

  IF v_raw IS NULL OR v_raw = '' THEN
    RETURN '[]'::jsonb;
  END IF;

  -- Trim code fences if present and cast to JSONB, else fallback
  v_raw := regexp_replace(v_raw, '^```[a-zA-Z]*\n?', '', 'g');
  v_raw := regexp_replace(v_raw, '\n?```$', '', 'g');
  BEGIN
    v_json := v_raw::jsonb;
  EXCEPTION WHEN others THEN
    RETURN '[]'::jsonb;
  END;
  IF jsonb_typeof(v_json) <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN v_json;
END;
$$;

-- 3) LLM agentic chunker: converts boundary plan to chunks with provenance
CREATE OR REPLACE FUNCTION app.agentic_chunk_llm(
  p_text text,
  max_chunk_chars int DEFAULT 1400,
  min_chunk_chars int DEFAULT 400
) RETURNS TABLE(seq int, chunk text, char_start int, char_end int, section_path text)
LANGUAGE plpgsql
AS $$
DECLARE
  v_plan jsonb := app.llm_propose_boundaries(p_text, max_chunk_chars, min_chunk_chars);
  v_idx int := 0;
  v_start int;
  v_end int;
  v_title text;
  v_len int := length(COALESCE(p_text,''));
  v_any boolean := false;
  v_rec record;
BEGIN
  IF v_plan IS NULL OR jsonb_typeof(v_plan) <> 'array' OR jsonb_array_length(v_plan) = 0 THEN
    RETURN QUERY
      SELECT seq, chunk, char_start, char_end, section_path
      FROM app.agentic_chunk_text(p_text, max_chunk_chars, min_chunk_chars);
    RETURN;
  END IF;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_plan) AS e(elem)
  LOOP
    v_start := GREATEST(1, COALESCE((v_rec.elem->>'start')::int, 0));
    v_end   := LEAST(v_len, COALESCE((v_rec.elem->>'end')::int, 0));
    v_title := NULLIF(v_rec.elem->>'title','');
    IF v_start < v_end AND v_start <= v_len AND v_end >= 1 THEN
      v_idx := v_idx + 1;
      seq := v_idx;
      char_start := v_start;
      char_end := v_end;
      section_path := v_title;
      chunk := substr(p_text, char_start, char_end - char_start + 1);
      v_any := true;
      RETURN NEXT;
    END IF;
  END LOOP;

  IF NOT v_any THEN
    RETURN QUERY
      SELECT seq, chunk, char_start, char_end, section_path
      FROM app.agentic_chunk_text(p_text, max_chunk_chars, min_chunk_chars);
  END IF;
END;
$$;

-- 4) Process pending docs: route based on mode (no in-DB embedding here)
CREATE OR REPLACE FUNCTION app.process_pending_documents()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
  v_mode  text := app.chunking_mode();
BEGIN
  IF v_mode = 'llm' THEN
    WITH new_docs AS (
      SELECT d.id, d.content_text
      FROM app.documents d
      LEFT JOIN app.doc_chunks c ON c.doc_id = d.id
      WHERE c.doc_id IS NULL
    )
    INSERT INTO app.doc_chunks (doc_id, seq, chunk_text, char_start, char_end, section_path)
    SELECT nd.id, c.seq, c.chunk, c.char_start, c.char_end, c.section_path
    FROM new_docs nd
    CROSS JOIN LATERAL app.agentic_chunk_llm(nd.content_text, 1400, 400) c;
    GET DIAGNOSTICS v_count = ROW_COUNT;
  ELSE
    WITH new_docs AS (
      SELECT d.id, d.content_text
      FROM app.documents d
      LEFT JOIN app.doc_chunks c ON c.doc_id = d.id
      WHERE c.doc_id IS NULL
    )
    INSERT INTO app.doc_chunks (doc_id, seq, chunk_text, char_start, char_end, section_path)
    SELECT nd.id, c.seq, c.chunk, c.char_start, c.char_end, c.section_path
    FROM new_docs nd
    CROSS JOIN LATERAL app.agentic_chunk_text(nd.content_text, 1400, 400) c;
    GET DIAGNOSTICS v_count = ROW_COUNT;
  END IF;
  RETURN COALESCE(v_count, 0);
END;
$$;

-- 5) Worker progress view + grant (for UI)
CREATE OR REPLACE VIEW app.v_vectorizer_worker_progress AS
SELECT vectorizer_id,
       success_count,
       error_count,
       last_success_at,
       last_success_process_id,
       last_error_at,
       last_error_message,
       last_error_process_id
FROM ai.vectorizer_worker_progress;
GRANT SELECT ON app.v_vectorizer_worker_progress TO anon;

-- 6) Persist settings (default to LLM mode)
ALTER DATABASE pgai SET app.chunking_mode = 'llm';

-- 7) Optional: set ai.openai_api_key GUC from secret if present
DO $$
DECLARE v text;
BEGIN
  BEGIN
    SELECT app.get_openai_key() INTO v;
  EXCEPTION WHEN others THEN
    v := NULL;
  END;
  IF v IS NOT NULL AND v <> '' THEN
    PERFORM set_config('ai.openai_api_key', v, true);
    EXECUTE format('ALTER DATABASE %I SET ai.openai_api_key = %L', current_database(), v);
  END IF;
END
$$;
