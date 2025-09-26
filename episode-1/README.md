# Episode 1 — pg_vectorize + Agentic Chunking (Deep Dive)

This document details what existed before Episode 1, the limitations we hit, the goals we set, and exactly what we implemented for Part 1/Episode 1. It also includes rollout steps, commands, and references to the specific files and functions that were added or changed.

## TL;DR
- Migrated from in-DB, synchronous embeddings to an asynchronous pgai Vectorizer worker.
- Introduced agentic chunking (heuristic and optional LLM-assisted) with provenance (`char_start`, `char_end`, `section_path`).
- Kept the same PostgREST API and static frontend, but enhanced the UI with vectorizer status and mode indicators.
- Centralized the OpenAI key with server-side storage (`app.app_secrets`) and convenient sync to `.env` for container services.

---

## Before Episode 1 (Baseline: Episode 0)
Baseline was a Postgres-only RAG stack with:
- `pgvector` for vector search and `pgai` for embeddings and chat.
- Ingestion from MinIO via PL/Python (`boto3`), chunking and embedding performed in-DB.
- PostgREST exposing RPCs and static Nginx frontend.

Key references (baseline):
- `README.md` — Baseline description and quick start.
- `db/init/03_ingest.sql` — Original path used `ai.chunk_text_recursively` + `ai.openai_embed` inside `app.process_pending_documents()`.
- `db/init/04_rag.sql` — `app.search_chunks()` and `app.chat_rag()`.
- `docker-compose.yml` — DB, PostgREST, MinIO, Frontend; no vectorizer worker.

### Baseline Limitations
- Embedding was synchronous in the DB:
  - Background job could not embed unless an OpenAI key was provided per request (via headers), leading to awkward operational flow.
- Chunking was naive and lacked provenance:
  - No `char_start`, `char_end`, or `section_path` for precise citations or UI annotations.
- Tight coupling of embedding to ingestion increased latency and compute in the DB.

---

## Objectives (Episode 1)
From `PLAN.md`:
- Replace in-DB embedding with pgai Vectorizer worker (async embeddings).
- Keep S3 sync and background job, but make chunking agentic and embeddings async.
- Add provenance to chunks (character offsets and section paths).
- Preserve the RAG API and frontend experience.

---

## Architecture Changes
- Vectorizer worker service added to `docker-compose.yml` as `vectorizer-worker`:
  - Image: `timescale/pgai-vectorizer-worker:latest`
  - Connects via `PGAI_VECTORIZER_WORKER_DB_URL`
  - Reads `OPENAI_API_KEY` from env (optionally bootstrapped from DB secret) and can access MinIO via standard AWS envs.
  - Entrypoint script: `scripts/vectorizer-start.sh` which fetches DB-stored OpenAI key as a fallback.
- Chunking moved to an agentic approach in SQL:
  - Heuristic agentic chunker: `app.agentic_chunk_text(...)`
  - Optional LLM-assisted planner: `app.llm_propose_boundaries(...)` + `app.agentic_chunk_llm(...)`
  - `app.process_pending_documents()` now inserts chunks with provenance and leaves embeddings NULL for the vectorizer to fill.
- Provenance columns added to `app.doc_chunks`:
  - `char_start`, `char_end`, `section_path`.
- Vectorizer configuration:
  - `db/init/08_vectorizer.sql` creates a vectorizer over `app.doc_chunks` with `loading => ai.loading_column('chunk_text')` and `destination => ai.destination_column('embedding')` and `chunking_none()`.
- Secrets:
  - `app.app_secrets` table to store `openai_api_key`.
  - RPCs: `app.set_openai_key(text)`, `app.get_openai_key()`, `app.openai_key_status()`.
  - Utility script `scripts/sync-openai-key.sh` to copy DB key to `.env`.
  - PostgREST pre-request `app.set_request_context()` enhanced to read from secrets and headers into GUCs.
- UI enhancements in `frontend/main.js`:
  - Shows vectorizer status/views, worker progress, and chunking mode badge.
  - Adds document listing and deletion helpers.

---

## Implementation Details and File References

### Docker Compose
- `docker-compose.yml`
  - New service `vectorizer-worker` with:
    - `PGAI_VECTORIZER_WORKER_DB_URL=postgres://postgres:postgres@db:5432/pgai`
    - `OPENAI_API_KEY` (from env or synced `.env`)
    - AWS/MinIO env vars
    - Entrypoint `scripts/vectorizer-start.sh`
  - Existing services: `db`, `postgrest`, `minio`, `minio-setup`, `frontend`, plus `ingest-cron` (curl-based polling of `/rpc/run_ingest_once`).

### Database Schema and Functions
- `db/init/02_schema.sql`
  - `app.doc_chunks` includes `chunk_text`, `char_start`, `char_end`, `section_path`, `embedding vector(1536)`.
  - IVFFLAT index for embeddings.
  - Views for ingestion/vectorizer status.
- `db/init/03_ingest.sql`
  - `app.s3_sync_documents(p_bucket text)` — PL/Python MinIO sync and crude parsing (txt/md/pdf/docx/json/csv).
  - `app.simple_chunk_text(...)` — a fallback word-based chunker.
  - `app.agentic_chunk_text(...)` — heuristic agentic chunker that aligns to headings and paragraph breaks and emits provenance.
  - `app.llm_propose_boundaries(...)` + `app.agentic_chunk_llm(...)` — LLM-assisted planner with safeguards and fallbacks.
  - `app.process_pending_documents()` — inserts chunks with provenance (into `chunk_text`), does not embed; embeddings are populated asynchronously by the vectorizer.
  - `app.run_ingest_once()` — triggers sync and chunking.
  - `app.reset_chunks()` — helper to clear chunks for re-chunking.
  - `app.chunking_mode()` — returns `heuristic` or `llm` (see migration making it STABLE for PostgREST).
- `db/init/04_rag.sql`
  - `app.search_chunks(p_query,k,p_threshold)` and `app.chat_rag(p_query,k)` updated to select `chunk_text` and use embeddings from vectorizer.
- `db/init/05_jobs.sql`
  - `app.job_sync_and_process` registered via Timescale jobs to run periodically.
- `db/init/06_grants.sql`
  - Grants to PostgREST anon role for relevant functions and views.
- `db/init/08_vectorizer.sql`
  - Idempotent creation of vectorizer over `app.doc_chunks` with `loading => 'chunk_text'` and `destination => 'embedding'`.

### Migrations (Part 1)
- `db/migrations/2025-09-16_part1_agentic_chunking.sql`
  - Adds provenance columns if missing.
  - Creates `app.app_secrets` table, trigger for `updated_at`.
  - `app.set_request_context()` to map secrets/headers to GUCs.
  - Introduces `app.agentic_chunk_text(...)` and refactors `app.process_pending_documents()` to write chunks and not embed.
  - RPCs for managing the OpenAI key: `openai_key_status`, `set_openai_key`, `get_openai_key`.
  - Creates vectorizer if `ai.vectorizers` is present.
  - Optional bootstrap of `OPENAI_API_KEY` from DB container env.
- `db/migrations/2025-09-17_chunk_column_rename.sql`
  - Renames `doc_chunks.chunk` -> `doc_chunks.chunk_text` and updates functions/vectorizer to use `chunk_text` consistently.
- `db/migrations/2025-09-21_llm_agentic_chunking.sql`
  - Adds LLM plan functions and a mode-aware `process_pending_documents()` variant.
  - Exposes `app.v_vectorizer_worker_progress` view and grants.
  - Optionally sets DB-level defaults for `app.chunking_mode` and `ai.openai_api_key` based on stored secret.
- `db/migrations/2025-09-22_chunking_mode_stable.sql`
  - Marks `app.chunking_mode()` as STABLE and grants execute to `anon` so PostgREST can expose it via GET/POST.

### Secrets and Worker Entrypoint
- `scripts/vectorizer-start.sh`
  - Fetches `OPENAI_API_KEY` from `app.get_openai_key()` if not present in env, then starts the vectorizer worker.
- `scripts/sync-openai-key.sh`
  - Pulls key from DB and writes it to `.env` as `OPENAI_API_KEY=...` for container consumption.

### Frontend
- `frontend/main.js`
  - Fetches and displays `v_ingest_status`, `v_vectorizer_status`, and `v_vectorizer_worker_progress`.
  - Displays chunking mode badge via `rpc/chunking_mode`.
  - Adds document listing and deletion helpers.
  - Shows embedding progress computed from `v_ingest_status`.
- `frontend/nginx.conf`
  - Serves static frontend and proxies `/api/*` to PostgREST.

---

## Rollout Steps (Episode 1)
- Bring up the stack with the new `vectorizer-worker` service:
  ```bash
  docker compose up -d --build
  ```
- Install pgai objects via the worker container (one-time):
  ```bash
  docker compose run --rm vectorizer-worker \
    --entrypoint "python -m pgai install -d postgres://postgres:postgres@db:5432/pgai"
  ```
- Set your OpenAI key (either via UI calling `app.set_openai_key`, or directly):
  ```bash
  make set-key KEY=sk-...
  # then optionally sync into .env for containers
  make sync-key
  ```
- Ensure the vectorizer exists (created idempotently by `db/init/08_vectorizer.sql` or the migration).
- Upload documents to MinIO and trigger ingest:
  ```bash
  make ingest
  # or use the UI "Ingest now"
  ```
- Verify:
  - `GET /v_ingest_status` shows chunks created and `chunks_pending` decreases as embeddings are filled.
  - `GET /v_vectorizer_status` and `GET /v_vectorizer_worker_progress` show active processing.
  - `POST /rpc/chat_rag` still answers with retrieved context.

---

## Operational Notes
- Chunking mode control:
  - `app.chunking_mode()` reads GUC `app.chunking_mode`. It’s set to `heuristic` by default; can be set to `llm` for LLM-assisted planning.
  - Exposed to PostgREST; the frontend calls it to render a badge.
- LLM planner safeguards:
  - Limits planning to first ~12k characters and enforces strict JSON-only output with fallbacks to heuristic chunking.
- Vectorizer prerequisites:
  - `python -m pgai install` must be run once so the `ai.*` catalog tables exist.
- Backwards compatibility:
  - Migration renames `doc_chunks.chunk` to `chunk_text` and updates dependent functions to avoid confusion.

---

## Results and Acceptance Criteria
- New docs uploaded to MinIO are chunked by Postgres and embedded asynchronously by the vectorizer worker.
- No need to pass an OpenAI key on every ingestion call; the key can be stored in DB and synced to `.env`.
- Agentic chunking produces fewer fragmented ideas, and provenance fields are populated for future citations/UI.

Smoke tests (from `PLAN.md`):
- Trigger ingestion via UI or `POST /rpc/run_ingest_once`.
- `GET /v_ingest_status` shows `chunks_pending` progressing to zero.
- Ask questions via UI; relevant context is used.

---

## Files Changed/Added (Highlights)
- Docker/Services:
  - `docker-compose.yml` (added `vectorizer-worker`, `ingest-cron`).
  - `scripts/vectorizer-start.sh` (new).
- DB Init/Migrations:
  - `db/init/02_schema.sql` (provenance columns, views).
  - `db/init/03_ingest.sql` (agentic chunking functions and refactored processing).
  - `db/init/04_rag.sql` (search/chat use `chunk_text`).
  - `db/init/05_jobs.sql`, `db/init/06_grants.sql`.
  - `db/init/08_vectorizer.sql` (vectorizer for `app.doc_chunks`).
  - `db/migrations/2025-09-16_part1_agentic_chunking.sql`.
  - `db/migrations/2025-09-17_chunk_column_rename.sql`.
  - `db/migrations/2025-09-21_llm_agentic_chunking.sql`.
  - `db/migrations/2025-09-22_chunking_mode_stable.sql`.
- Frontend:
  - `frontend/main.js` (status panels, chunking mode badge, doc management, progress bar).
  - `frontend/nginx.conf` (proxy and static serving).
- Utilities:
  - `scripts/sync-openai-key.sh` (DB -> .env convenience).
  - `Makefile` (helper targets for ingest, health, reset, set-key, sync-key).

---

## End-to-End Diagram
```mermaid
flowchart LR
  subgraph Client
    UI[Static Frontend (Nginx)]
  end
  subgraph API
    PGRST[PostgREST]
  end
  subgraph DB[PostgreSQL (TimescaleDB + pgvector + pgai)]
    DOCS[(app.documents)]
    CHUNKS[(app.doc_chunks)]
    VSTAT[[app.v_vectorizer_status]]
    VWSTAT[[app.v_vectorizer_worker_progress]]
    FUNCS[[agentic_chunk_text / agentic_chunk_llm / process_pending_documents / chat_rag]]
  end
  subgraph S3[MinIO]
    BUCKET[(documents)]
  end
  subgraph Worker
    VEC[timescale/pgai-vectorizer-worker]
  end

  UI -->|/api/rpc/run_ingest_once| PGRST -->|s3_sync + process| DB
  DB <--> S3
  DB -->|chunks (no embed)| CHUNKS
  VEC -->|polls ai.vectorizers| DB
  VEC -->|writes embeddings| CHUNKS
  UI -->|/api/v_ingest_status| PGRST --> DB
  UI -->|/api/v_vectorizer_status| PGRST --> DB
  UI -->|/api/v_vectorizer_worker_progress| PGRST --> DB
  UI -->|/api/rpc/chat_rag| PGRST -->|RAG| DB
```

---

## Next Steps (Future Episodes)
- Hybrid search (FTS + vector), re-ranking, multi-query expansion, citations — per `ROADMAP.md`.
- A/B toggles between `simple_chunk_text`, `agentic_chunk_text`, and `agentic_chunk_llm` for evaluation.

---

## Appendix: Useful Commands
- Start stack:
  ```bash
  make up
  ```
- Install pgai objects once (via worker):
  ```bash
  docker compose run --rm vectorizer-worker \
    --entrypoint "python -m pgai install -d postgres://postgres:postgres@db:5432/pgai"
  ```
- Set OpenAI key in DB and sync to .env:
  ```bash
  make set-key KEY=sk-...
  make sync-key
  ```
- Trigger ingest and check status:
  ```bash
  make ingest
  make status
  ```
- Health check:
  ```bash
  make health
  ```
