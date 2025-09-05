# Postgres-only RAG Chatbot (pgai + pgvector + PostgREST)

GitHub repository: https://github.com/philmcc/pgai-ragbot

This is a minimal demo of a RAG chatbot implemented almost entirely in PostgreSQL using:

- TimescaleDB (PostgreSQL)
- pgvector (`vector` extension) for embeddings search
- pgai (`ai` extension) for embeddings and chat completions via OpenAI
- PL/Python for ingestion from S3-compatible storage (MinIO)
- Timescale background jobs to schedule ingestion/processing
- PostgREST as a thin HTTP layer to call SQL functions from a static frontend
- MinIO (local S3) for document uploads

Frontend is static (Nginx). All logic and state lives in Postgres.

## Services

- DB: `localhost:5432` (database `pgai`, user `postgres`/`postgres`)
- PostgREST: `http://localhost:3000`
- Frontend: `http://localhost:8080`
- MinIO Console: `http://localhost:9001` (user/pass: `minioadmin`/`minioadmin`)
- MinIO S3 endpoint: `http://localhost:9000`

## Quick start

1. Start the stack:
   ```bash
   docker compose up -d --build
   ```

2. Open the frontend:
   - http://localhost:8080

3. Set your OpenAI API key in the UI:
   - Enter your key (sk-...) and click Save. The key is stored in localStorage and sent per-request as header `X-OpenAI-Key` to PostgREST. The DB pre-request hook copies it into `ai.openai_api_key` for pgai.

4. Upload documents to MinIO:
   - Open http://localhost:9001
   - Login `minioadmin`/`minioadmin`
   - Use bucket `documents` (auto-created). Upload `.txt`, `.md`, `.pdf`(best effort), `.csv`, `.json`.

5. Trigger ingestion:
   - In the frontend, click "Ingest now" (or wait ~1 minute for the background job).
   - Check status in the sidebar. It shows chunk/embedding progress per document.

6. Ask questions:
   - Use the chat box. The DB function `app.chat_rag()` performs similarity search and calls `ai.openai_chat_complete` to generate an answer constrained to the retrieved context.

## How it works

- SQL init in `db/init/`:
  - `00_roles.sql`: anon role, PostgREST pre-request `app.set_request_context()` to map headers -> session GUCs (OpenAI key and models).
  - `01_extensions.sql`: enable `timescaledb`, `vector`, `plpython3u`, `ai`.
  - `02_schema.sql`: `app.documents`, `app.doc_chunks` (vector(1536)), IVFFLAT index, `app.v_ingest_status`.
  - `03_ingest.sql`: `app.s3_sync_documents()` (PL/Python with boto3) + `app.process_pending_documents()` (chunk via `ai.chunk_text_recursively`, embed via `ai.openai_embed`). `app.run_ingest_once()` RPC.
  - `04_rag.sql`: `app.search_chunks()` and `app.chat_rag()` (RAG + `ai.openai_chat_complete`).
  - `05_jobs.sql`: Timescale `add_job('app.job_sync_and_process','1 minute')` to poll S3 and process.
  - `06_grants.sql`: privileges for PostgREST anon.

- PostgREST exposes schema `app` only. CORS is enabled. Pre-request hook sets:
  - `ai.openai_api_key` from `X-OpenAI-Key`
  - `ai.openai_embedding_model` from `X-Embedding-Model` (default `text-embedding-3-small`)
  - `ai.openai_chat_model` from `X-Chat-Model` (default `gpt-4o-mini`)

- MinIO bucket `documents` is created on startup by `minio-setup` service. Data persists in `./minio-data/`.

## Environment / versions

- Docker images:
  - DB: `timescale/timescaledb-ha:pg17` (with `CREATE EXTENSION ai` available)
  - PostgREST: `postgrest/postgrest:v12.2.3`
  - MinIO: `minio/minio@sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0`

- The DB container installs pip packages for ingestion:
  - `boto3`, `langchain-text-splitters`, `pymupdf`

## Useful endpoints (PostgREST)

- GET `http://localhost:3000/v_ingest_status`
- POST `http://localhost:3000/rpc/run_ingest_once` (body `{}`)
- POST `http://localhost:3000/rpc/chat_rag` (body `{ "p_query": "...", "k": 5 }`)
- POST `http://localhost:3000/rpc/health` (body `{}`) — smoke-test RPC

Include headers when calling from outside the frontend:
```
X-OpenAI-Key: sk-...
X-Embedding-Model: text-embedding-3-small
X-Chat-Model: gpt-4o-mini
```

## Notes

- This demo runs embeddings and chat directly in Postgres using pgai functions. No vectorizer worker is used.
- PDF extraction is best-effort via PyMuPDF; for robust parsing, consider docling or the pgai vectorizer pipeline.
- The IVFFLAT index becomes effective after some `ANALYZE`; Postgres autovacuum will handle it as data accumulates.

## Fresh install and reproducibility

- OpenAI key is not stored server-side. The background job can chunk documents automatically, but it cannot embed without your key. Trigger "Ingest now" in the UI (or call the RPC with `X-OpenAI-Key`) so embeddings are computed.
- All container images are pinned via `.env` (e.g. `POSTGREST_IMAGE`, `MINIO_IMAGE`, `MINIO_MC_IMAGE`, `NGINX_IMAGE`, `DB_BASE_IMAGE`). You can replace tags with digests in `.env` for maximum reproducibility.
- Python packages for ingestion are pinned in `db/Dockerfile` for reproducibility.

## Smoke test

1. Health check:
   ```bash
   curl -sS http://localhost:3000/rpc/health | jq .
   ```
2. Trigger ingestion (sync, chunk, and embed pending) using your OpenAI key:
   ```bash
   curl -sS -X POST http://localhost:3000/rpc/run_ingest_once \
     -H "Content-Type: application/json" \
     -H "X-OpenAI-Key: sk-..." \
     -H "X-Embedding-Model: text-embedding-3-small" \
     -d '{}'
   ```
3. Check status:
   ```bash
   curl -sS http://localhost:3000/v_ingest_status | jq .
   ```
4. Ask a question (or use the UI at http://localhost:8080):
   ```bash
   curl -sS -X POST http://localhost:3000/rpc/chat_rag \
     -H "Content-Type: application/json" \
     -H "X-OpenAI-Key: sk-..." \
     -H "X-Chat-Model: gpt-4o-mini" \
     -d '{"p_query":"summarize the uploaded research paper","k":8}'
   ```

## Makefile

Common commands are provided via `Makefile`:

- `make up` — build and start the stack
- `make down` — stop and remove containers and volumes
- `make status` — show `v_ingest_status`
- `make health` — call `/rpc/health`
- `make ingest KEY=sk-... [EMBED_MODEL=text-embedding-3-small]` — trigger ingest with your key
- `make reset-chunks` — delete chunks to re-run chunking/embedding
- `make logs` — tail logs for db, postgrest, frontend, minio

## Version pinning

Image versions are pinned via `.env` so that `docker compose` always uses the same image references. You can replace tags with digests for maximum reproducibility.

Defaults in `.env`:

```
POSTGREST_IMAGE=postgrest/postgrest:v12.2.3
MINIO_IMAGE=minio/minio@sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0
MINIO_MC_IMAGE=minio/mc:RELEASE.2024-05-03T11-21-07Z
NGINX_IMAGE=nginx:1.27.0-alpine
DB_BASE_IMAGE=timescale/timescaledb-ha:pg17
```

To pin by digest, set these to full references, for example:

```
POSTGREST_IMAGE=postgrest/postgrest@sha256:...
MINIO_IMAGE=minio/minio@sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0
MINIO_MC_IMAGE=minio/mc@sha256:...
NGINX_IMAGE=nginx@sha256:...
DB_BASE_IMAGE=timescale/timescaledb-ha@sha256:...
```

Note: MinIO's on-disk format may change across releases. If you already have data under `./minio-data/`, avoid downgrading the MinIO server image, as older binaries may fail to read newer metadata. Pinning by digest (as shown above) ensures reproducible starts with the existing data.

The DB image base is passed as a build arg to `db/Dockerfile` (`ARG BASE_IMAGE_REF`), so the final database image you run is deterministically built atop that base. Python packages are pinned in `db/Dockerfile` for the ingestion helpers.

## Tear down

```bash
docker compose down -v
```
This will remove containers and volumes (including the Postgres data volume). MinIO object files persist in `./minio-data/` on your host.
