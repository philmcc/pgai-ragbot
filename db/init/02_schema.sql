-- Core RAG schema
SET search_path = app, public;

-- Documents sourced from S3 (MinIO)
CREATE TABLE IF NOT EXISTS documents (
  id           BIGSERIAL PRIMARY KEY,
  s3_bucket    text NOT NULL,
  s3_key       text NOT NULL UNIQUE,
  source_uri   text NOT NULL,
  content_type text,
  content_bytes bytea,
  content_text text,
  metadata     jsonb DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Chunked representation and embeddings
-- Using OpenAI embedding with 1536 dims by default
CREATE TABLE IF NOT EXISTS doc_chunks (
  doc_id    bigint NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  seq       int    NOT NULL,
  chunk     text   NOT NULL,
  embedding vector(1536),
  PRIMARY KEY (doc_id, seq)
);

-- Vector index for similarity search (IVFFLAT)
-- Note: Requires analyze and some data to be effective
CREATE INDEX IF NOT EXISTS doc_chunks_embedding_ivfflat
  ON doc_chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

-- Helper view to show ingestion and embedding status
CREATE OR REPLACE VIEW v_ingest_status AS
SELECT d.id, d.s3_bucket, d.s3_key,
       count(c.*) FILTER (WHERE c.embedding IS NULL) AS chunks_pending,
       count(c.*)                                   AS chunks_total,
       d.created_at
FROM documents d
LEFT JOIN doc_chunks c ON c.doc_id = d.id
GROUP BY d.id;
