-- RPC: delete a single document by id (cascades to chunks)
CREATE OR REPLACE FUNCTION app.delete_document(p_id bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v int; BEGIN
  DELETE FROM app.documents WHERE id = p_id;
  GET DIAGNOSTICS v = ROW_COUNT;
  IF v > 0 THEN RETURN 'deleted'; ELSE RETURN 'not_found'; END IF;
END;$$;

-- RPC: delete a single document by s3_key (cascades to chunks)
CREATE OR REPLACE FUNCTION app.delete_document_by_key(p_key text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v int; BEGIN
  DELETE FROM app.documents WHERE s3_key = p_key;
  GET DIAGNOSTICS v = ROW_COUNT;
  IF v > 0 THEN RETURN 'deleted'; ELSE RETURN 'not_found'; END IF;
END;$$;

-- RPC: delete all documents (use with care)
CREATE OR REPLACE FUNCTION app.delete_all_documents()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v int; BEGIN
  DELETE FROM app.documents;
  GET DIAGNOSTICS v = ROW_COUNT;
  RETURN v;
END;$$;

-- S3 (MinIO) sync using PL/Python and boto3
SET search_path = app, public;

-- Helper to choose embedding/chat models via GUCs or defaults
CREATE OR REPLACE FUNCTION app.embedding_model() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(NULLIF(current_setting('ai.openai_embedding_model', true), ''), 'text-embedding-3-small')
$$;

CREATE OR REPLACE FUNCTION app.chat_model() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(NULLIF(current_setting('ai.openai_chat_model', true), ''), 'gpt-4o-mini')
$$;

CREATE OR REPLACE FUNCTION app.rerank_model() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(NULLIF(current_setting('ai.openai_rerank_model', true), ''), 'BAAI/bge-reranker-base')
$$;

-- Create PL/Python function to sync documents from MinIO bucket
CREATE OR REPLACE FUNCTION app.s3_sync_documents(p_bucket text DEFAULT 'documents')
RETURNS int
LANGUAGE plpython3u
AS $$
import os
import mimetypes
from io import BytesIO

import boto3

# Optional PDF parsing
try:
    import fitz  # PyMuPDF
except Exception:
    fitz = None

# Optional DOCX parsing
try:
    import docx
except Exception:
    docx = None

endpoint = os.environ.get('S3_ENDPOINT_URL', 'http://minio:9000')
aws_key = os.environ.get('AWS_ACCESS_KEY_ID')
aws_secret = os.environ.get('AWS_SECRET_ACCESS_KEY')
aws_region = os.environ.get('AWS_DEFAULT_REGION', 'us-east-1')

session = boto3.session.Session()
s3 = session.client('s3', endpoint_url=endpoint, aws_access_key_id=aws_key, aws_secret_access_key=aws_secret, region_name=aws_region)

inserted = 0
continuation = None

# Prepare statements
plan_exists = plpy.prepare("SELECT 1 FROM app.documents WHERE s3_key = $1", ["text"]) 
plan_insert = plpy.prepare(
    """
    INSERT INTO app.documents (s3_bucket, s3_key, source_uri, content_type, content_text)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (s3_key) DO NOTHING
    """,
    ["text","text","text","text","text"]
)

while True:
    if continuation:
        resp = s3.list_objects_v2(Bucket=p_bucket, ContinuationToken=continuation)
    else:
        resp = s3.list_objects_v2(Bucket=p_bucket)

    for obj in resp.get('Contents', []):
        key = obj['Key']
        source_uri = f's3://{p_bucket}/{key}'

        # Skip if already ingested
        exists = plpy.execute(plan_exists, [key], 1)
        if exists:
            continue

        # Get object and parse text
        o = s3.get_object(Bucket=p_bucket, Key=key)
        content_type = o.get('ContentType') or mimetypes.guess_type(key)[0] or 'application/octet-stream'
        body = o['Body'].read()
        text = None

        # crude type-based parsing
        if key.lower().endswith('.pdf') and fitz is not None:
            try:
                doc = fitz.open(stream=body, filetype='pdf')
                pages = []
                for p in doc:
                    pages.append(p.get_text())
                text = "\n\n".join(pages)
            except Exception as e:
                text = None
        elif key.lower().endswith('.docx') and docx is not None:
            try:
                d = docx.Document(BytesIO(body))
                parts = []
                # Paragraphs
                for p in d.paragraphs:
                    pt = (p.text or '').strip()
                    if pt:
                        parts.append(pt)
                # Tables (cells)
                for tbl in d.tables:
                    for row in tbl.rows:
                        for cell in row.cells:
                            ct = (cell.text or '').strip()
                            if ct:
                                parts.append(ct)
                text = "\n\n".join(parts)
            except Exception as e:
                text = None
        elif key.lower().endswith(('.txt', '.md', '.csv', '.json')):
            try:
                text = body.decode('utf-8', errors='ignore')
            except Exception:
                text = None
        else:
            # fallback: try utf-8
            try:
                text = body.decode('utf-8', errors='ignore')
            except Exception:
                text = None

        if not text:
            text = ''

        # Insert document row
        plpy.execute(plan_insert, [p_bucket, key, source_uri, content_type, text])
        inserted += 1

    if resp.get('IsTruncated'):
        continuation = resp.get('NextContinuationToken')
    else:
        break

return inserted
$$;

-- Process documents without chunks: chunk and embed
CREATE OR REPLACE FUNCTION app.process_pending_documents()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
  v_model text := app.embedding_model();
BEGIN
  -- Insert chunks for docs lacking any
  WITH new_docs AS (
    SELECT d.id, d.content_text
    FROM app.documents d
    LEFT JOIN app.doc_chunks c ON c.doc_id = d.id
    WHERE c.doc_id IS NULL
  ), ins AS (
    INSERT INTO app.doc_chunks (doc_id, seq, chunk)
    SELECT nd.id, c.seq, c.chunk
    FROM new_docs nd
    CROSS JOIN LATERAL ai.chunk_text_recursively(nd.content_text, chunk_size=>1000, chunk_overlap=>200) c
    RETURNING 1
  )
  SELECT COALESCE(count(*),0) INTO v_count FROM ins;

  -- Embed missing chunks
  UPDATE app.doc_chunks c
  SET embedding = ai.openai_embed(v_model, c.chunk)
  WHERE c.embedding IS NULL;

  RETURN v_count;
END;
$$;

-- Chunking mode selector (heuristic | llm)
CREATE OR REPLACE FUNCTION app.chunking_mode() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(NULLIF(current_setting('app.chunking_mode', true), ''), 'heuristic')
$$;

-- LLM proposes boundary plan as JSON [{start:int, end:int, title:text|null}, ...]
CREATE OR REPLACE FUNCTION app.llm_propose_boundaries(p_text text,
                                                      max_chunk_chars int DEFAULT 1400,
                                                      min_chunk_chars int DEFAULT 400)
RETURNS jsonb
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
  -- Limit text to keep token usage reasonable; windows can be added later.
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

  -- Strip accidental code fences and cast to JSONB
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

-- Convert boundary plan to chunks with provenance; fallback to heuristic if invalid/empty
CREATE OR REPLACE FUNCTION app.agentic_chunk_llm(p_text text,
                                                 max_chunk_chars int DEFAULT 1400,
                                                 min_chunk_chars int DEFAULT 400)
RETURNS TABLE(seq int, chunk text, char_start int, char_end int, section_path text)
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
BEGIN
  IF v_plan IS NULL OR jsonb_typeof(v_plan) <> 'array' OR jsonb_array_length(v_plan) = 0 THEN
    RETURN QUERY
      SELECT seq, chunk, char_start, char_end, section_path
      FROM app.agentic_chunk_text(p_text, max_chunk_chars, min_chunk_chars)
      CROSS JOIN LATERAL (
        SELECT 1 as dummy
      ) d
      -- Map to expected column names
      ;
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

-- Recreate process_pending_documents to use simple_chunk_text
CREATE OR REPLACE FUNCTION app.process_pending_documents()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
  v_mode  text := app.chunking_mode();
BEGIN
  -- Insert chunks for docs lacking any using selected chunker
  IF v_mode = 'llm' THEN
    WITH new_docs AS (
      SELECT d.id, d.content_text
      FROM app.documents d
      LEFT JOIN app.doc_chunks c ON c.doc_id = d.id
      WHERE c.doc_id IS NULL
    ), ins AS (
      INSERT INTO app.doc_chunks (doc_id, seq, chunk, char_start, char_end, section_path)
      SELECT nd.id, c.seq, c.chunk, c.char_start, c.char_end, c.section_path
      FROM new_docs nd
      CROSS JOIN LATERAL app.agentic_chunk_llm(nd.content_text, 1400, 400) c
      RETURNING 1
    )
    SELECT COALESCE(count(*),0) INTO v_count FROM ins;
  ELSE
    WITH new_docs AS (
      SELECT d.id, d.content_text
      FROM app.documents d
      LEFT JOIN app.doc_chunks c ON c.doc_id = d.id
      WHERE c.doc_id IS NULL
    ), ins AS (
      INSERT INTO app.doc_chunks (doc_id, seq, chunk)
      SELECT nd.id, c.seq, c.chunk
      FROM new_docs nd
      CROSS JOIN LATERAL app.simple_chunk_text(nd.content_text, 1000, 200) c
      RETURNING 1
    )
    SELECT COALESCE(count(*),0) INTO v_count FROM ins;
  END IF;

  -- Embed missing chunks
  UPDATE app.doc_chunks c
  SET embedding = ai.openai_embed(app.embedding_model(), c.chunk)
  WHERE c.embedding IS NULL;

  RETURN v_count;
END;
$$;

-- Simple word-based chunker to avoid external dependencies
CREATE OR REPLACE FUNCTION app.simple_chunk_text(p_text text, chunk_size int DEFAULT 1000, chunk_overlap int DEFAULT 200)
RETURNS TABLE(seq int, chunk text)
LANGUAGE plpgsql
AS $$
DECLARE
  words text[];
  total int;
  start_idx int := 1;
  i int;
  seqno int := 0;
  t text;
  len int;
BEGIN
  IF p_text IS NULL OR length(p_text) = 0 THEN
    RETURN;
  END IF;

  -- Split on whitespace; use E-string so \\s is interpreted by the regex engine as whitespace
  words := regexp_split_to_array(p_text, E'\\s+');
  total := array_length(words, 1);
  IF total IS NULL THEN
    RETURN;
  END IF;

  -- Fallback: if the regex split produced a single massive token (e.g., PDF text with non-breaking spaces),
  -- slice by characters with overlap so we still make progress.
  IF total = 1 AND length(words[1]) > chunk_size THEN
    i := 1; -- reuse as position (1-based)
    WHILE i <= length(p_text) LOOP
      seqno := seqno + 1;
      seq := seqno;
      chunk := substr(p_text, i, chunk_size);
      RETURN NEXT;
      i := i + GREATEST(1, chunk_size - chunk_overlap);
    END LOOP;
    RETURN;
  END IF;

  WHILE start_idx <= total LOOP
    t := '';
    len := 0;
    i := start_idx;
    WHILE i <= total AND (len + length(words[i]) + CASE WHEN len > 0 THEN 1 ELSE 0 END) <= chunk_size LOOP
      IF len > 0 THEN
        t := t || ' ';
        len := len + 1;
      END IF;
      t := t || COALESCE(words[i], '');
      len := len + length(words[i]);
      i := i + 1;
    END LOOP;
    IF length(t) > 0 THEN
      seqno := seqno + 1;
      seq := seqno;
      chunk := t;
      RETURN NEXT;
    END IF;
    -- approximate overlap in words (~5 chars avg/word)
    start_idx := GREATEST(i - GREATEST(1, floor(chunk_overlap / 5)::int), start_idx + 1);
  END LOOP;
END;
$$;

-- Agentic-ish chunker: prefers semantic boundaries (headings/blank lines) and produces
-- variable-sized chunks with provenance. This is a heuristic implementation that does not
-- require an LLM to run, but aligns chunks to Markdown-style structure and paragraph breaks.
-- We can later enrich this to consult pgai for boundary hints.
CREATE OR REPLACE FUNCTION app.agentic_chunk_text(p_text text,
                                                 max_chunk_chars int DEFAULT 1400,
                                                 min_chunk_chars int DEFAULT 400)
RETURNS TABLE(seq int, chunk text, char_start int, char_end int, section_path text)
LANGUAGE plpgsql
AS $$
DECLARE
  lines text[];
  n int;
  i int := 1;
  buf text := '';
  buf_start int := 1;
  cur_start int := 1;
  cur_section text := NULL;
  seqno int := 0;
  line text;
  line_len int;
  abs_pos int := 1; -- absolute character position (1-based)
  can_flush boolean;
BEGIN
  IF p_text IS NULL OR length(p_text) = 0 THEN
    RETURN;
  END IF;

  -- Normalize newlines
  p_text := replace(p_text, '\r\n', '\n');
  p_text := replace(p_text, '\r', '\n');

  lines := regexp_split_to_array(p_text, E'\n');
  n := array_length(lines, 1);
  IF n IS NULL THEN
    -- Single line fallback
    lines := ARRAY[p_text];
    n := 1;
  END IF;

  WHILE i <= n LOOP
    line := COALESCE(lines[i], '');
    line_len := length(line);

    -- Detect headings to set section path (e.g., Markdown #, ##, ###)
    IF line ~ E'^\s*#{1,6}\s+' THEN
      -- If current buffer has enough content, flush it before changing section
      can_flush := length(buf) >= min_chunk_chars;
      IF can_flush THEN
        seqno := seqno + 1;
        seq := seqno;
        chunk := buf;
        char_start := buf_start;
        char_end := abs_pos - 1; -- end before current line
        section_path := cur_section;
        RETURN NEXT;
        buf := '';
      END IF;
      cur_section := regexp_replace(line, E'^\s*#{1,6}\s+', '');
      buf_start := abs_pos + line_len + 1; -- next line start
    ELSIF line ~ E'^\s*$' THEN
      -- Paragraph boundary: consider flushing if buffer large enough
      IF length(buf) >= min_chunk_chars THEN
        seqno := seqno + 1;
        seq := seqno;
        chunk := buf;
        char_start := buf_start;
        char_end := abs_pos - 1; -- up to before this blank line
        section_path := cur_section;
        RETURN NEXT;
        buf := '';
        buf_start := abs_pos; -- start at this boundary
      ELSIF length(buf) >= max_chunk_chars THEN
        -- Hard flush to avoid overly large chunks
        seqno := seqno + 1;
        seq := seqno;
        chunk := buf;
        char_start := buf_start;
        char_end := abs_pos - 1;
        section_path := cur_section;
        RETURN NEXT;
        buf := '';
        buf_start := abs_pos;
      ELSE
        -- Keep boundary but don't flush yet
        buf := buf || '\n';
      END IF;
    ELSE
      -- Regular content line: append
      IF length(buf) > 0 THEN
        buf := buf || '\n' || line;
      ELSE
        buf := line;
      END IF;
      IF length(buf) >= max_chunk_chars THEN
        seqno := seqno + 1;
        seq := seqno;
        chunk := buf;
        char_start := buf_start;
        char_end := abs_pos + line_len; -- include this line
        section_path := cur_section;
        RETURN NEXT;
        buf := '';
        buf_start := char_end + 1;
      END IF;
    END IF;

    -- Advance absolute position (+1 for newline except last line handled below)
    abs_pos := abs_pos + line_len + 1;
    i := i + 1;
  END LOOP;

  -- Flush remainder
  IF length(buf) > 0 THEN
    seqno := seqno + 1;
    seq := seqno;
    chunk := buf;
    char_start := buf_start;
    char_end := GREATEST(buf_start + length(buf) - 1, buf_start);
    section_path := cur_section;
    RETURN NEXT;
  END IF;
END;
$$;

-- Recreate process_pending_documents to use simple_chunk_text
CREATE OR REPLACE FUNCTION app.process_pending_documents()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
  v_mode  text := app.chunking_mode();
BEGIN
  -- Insert chunks for docs lacking any using selected chunker
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

  -- Embeddings are filled asynchronously by pgai vectorizer worker.
  RETURN COALESCE(v_count, 0);
END;
$$;

-- RPC to trigger ingest on demand
CREATE OR REPLACE FUNCTION app.run_ingest_once()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  PERFORM app.s3_sync_documents('documents');
  PERFORM app.process_pending_documents();
  RETURN 'ok';
END;
$$;

GRANT EXECUTE ON FUNCTION app.run_ingest_once() TO anon;

-- Admin helper: reset all chunks to allow re-chunking with updated logic
CREATE OR REPLACE FUNCTION app.reset_chunks()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM app.doc_chunks;
END;
$$;

GRANT EXECUTE ON FUNCTION app.reset_chunks() TO anon;
