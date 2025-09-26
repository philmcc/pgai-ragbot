# Episode 2 Plan — pg_vectorize + Agentic Chunking

This document captures the concrete steps to upgrade the current Postgres-only RAG chatbot to use the pgai Vectorizer (pg_vectorize) for automatic embeddings from S3/MinIO and to add an agentic chunking pipeline. Each step is independent and can be executed incrementally.

## Objectives
- Replace in-DB embedding step with pgai Vectorizer worker.
- Keep existing S3 sync and background job that detect new objects.
- Add agentic (LLM-assisted) chunking with provenance (offsets, section paths).
- Preserve current RAG API (`app.chat_rag`) and frontend UX.

## High-level architecture changes
- Continue using `app.s3_sync_documents()` to mirror MinIO objects into `app.documents`.
- Refactor `app.process_pending_documents()` to:
  - Create chunks using `app.agentic_chunk_text()`; do not embed in-DB.
  - Leave `doc_chunks.embedding` as NULL to signal vectorizer work.
- Run `timescale/pgai-vectorizer-worker` as a separate docker service configured to:
  - Connect to DB via `PGAI_VECTORIZER_WORKER_DB_URL`.
  - Use OpenAI for embeddings via `OPENAI_API_KEY`.
  - Read S3/MinIO via smart_open credentials (`AWS_*` and `AWS_ENDPOINT_URL`).
- Create a vectorizer over `app.doc_chunks` with `destination => ai.destination_column('embedding')` and `chunking => ai.chunking_none()`.

## Files to change/add
- `docker-compose.yml`
  - Add `vectorizer-worker` service:
    - image: `timescale/pgai-vectorizer-worker:latest`
    - env:
      - `PGAI_VECTORIZER_WORKER_DB_URL=postgres://postgres:postgres@db:5432/pgai`
      - `OPENAI_API_KEY=<set via .env or export>`
      - `AWS_ACCESS_KEY_ID=minioadmin`
      - `AWS_SECRET_ACCESS_KEY=minioadmin`
      - `AWS_DEFAULT_REGION=us-east-1`
      - `AWS_EC2_METADATA_DISABLED=true`
      - `AWS_ENDPOINT_URL=http://minio:9000`
    - command: `["--poll-interval","5s"]`

- `db/init/02_schema.sql`
  - (Done) Add provenance columns to `app.doc_chunks`: `char_start`, `char_end`, `section_path`.

- `db/init/03_ingest.sql`
  - Add function `app.agentic_chunk_text(p_text text)` returning `(seq int, chunk text, char_start int, char_end int, section_path text)`.
    - Heuristics for headings/sections + optional pgai-assisted merges for semantic coherence.
    - Fallback to `app.simple_chunk_text` if pgai is unavailable.
  - Refactor `app.process_pending_documents()` to use `app.agentic_chunk_text(...)` and remove in-DB embedding step.

- `db/init/08_vectorizer.sql` (new)
  - One-time creation of vectorizer for `app.doc_chunks`:
    ```sql
    SELECT ai.create_vectorizer(
      'app.doc_chunks'::regclass,
      if_not_exists => true,
      loading      => ai.loading_column('chunk_text'),
      chunking     => ai.chunking_none(),
      embedding    => ai.embedding_openai(model=>'text-embedding-3-small', dimensions=>'1536'),
      destination  => ai.destination_column('embedding'),
      scheduling   => ai.scheduling_timescaledb('1 minute')
    );
    ```

- `README.md`
  - Add section "Vectorizer setup" documenting:
    - `docker compose run --rm vectorizer-worker --entrypoint "python -m pgai install -d postgres://postgres:postgres@db:5432/pgai"`
    - Required env vars for the worker and suggested `.env` usage.
    - Ingestion flow change: "Ingest now" triggers sync+chunk only; embeddings are populated asynchronously by the worker.

## Rollout steps
1) Add vectorizer service to `docker-compose.yml` and bring it up.
2) Run `pgai install` once using the vectorizer-worker container.
3) Deploy the new `agentic_chunk_text` and refactor `process_pending_documents`.
4) Create the `app.doc_chunks` vectorizer with `destination_column('embedding')`.
5) Upload test documents to MinIO and observe that:
   - `v_ingest_status` shows chunks created.
   - After a short delay, `embedding` is populated by the worker.
6) Verify chat flow (`/rpc/chat_rag`) still works and quality improves on multi-paragraph ideas.

## Smoke tests
- Trigger ingestion via UI link "Ingest now" or `POST /rpc/run_ingest_once`.
- Check `GET /v_ingest_status` — `chunks_pending` decreases to zero as vectorizer fills embeddings.
- Ask a question in the UI and confirm relevant context is used.

## Acceptance criteria
- New docs uploaded to MinIO are automatically chunked by Postgres and embedded by the vectorizer.
- No need to set an OpenAI key for embeddings at request time; only chat needs a key.
- Agentic chunking produces fewer fragmented ideas; provenance columns are present and populated.

## Notes
- We can add a per-document flag to switch between `simple_chunk_text` and `agentic_chunk_text` for A/B testing.
- Later parts can build on this to add Hybrid Search, Re-ranking, Multi-query, and Citations without further ingestion changes.
