-- S3 (MinIO) sync using PL/Python and boto3
SET search_path = app, public;

-- Helper to choose embedding/chat models via GUCs or defaults
CREATE OR REPLACE FUNCTION app.embedding_model() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(NULLIF(current_setting('ai.openai_embedding_model', true), ''), 'text-embedding-3-small')
$$;

CREATE OR REPLACE FUNCTION app.chat_model() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(NULLIF(current_setting('ai.openai_chat_model', true), ''), 'gpt-4o-mini')
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

-- Recreate process_pending_documents to use simple_chunk_text
CREATE OR REPLACE FUNCTION app.process_pending_documents()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
  v_model text := app.embedding_model();
  v_api_key text := NULLIF(current_setting('ai.openai_api_key', true), '');
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
    CROSS JOIN LATERAL app.simple_chunk_text(nd.content_text, 1000, 200) c
    RETURNING 1
  )
  SELECT COALESCE(count(*),0) INTO v_count FROM ins;

  -- Embed missing chunks
  IF v_api_key IS NOT NULL AND v_api_key <> '' THEN
    BEGIN
      UPDATE app.doc_chunks c
      SET embedding = ai.openai_embed(v_model, c.chunk, api_key=>v_api_key)
      WHERE c.embedding IS NULL;
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'Embedding failed: %', SQLERRM;
    END;
  ELSE
    RAISE NOTICE 'Skipping embedding (no OpenAI API key set)';
  END IF;

  RETURN v_count;
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
