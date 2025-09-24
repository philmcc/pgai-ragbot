# Series Roadmap

This roadmap outlines the planned episodes for evolving the Postgres-only RAG chatbot. Details will be expanded per episode as we implement them.

- Episode 0 — Baseline Postgres RAG
  - pgvector + pgai in-DB embeddings and chat
  - PostgREST API and static frontend
  - S3/MinIO-backed ingestion
  - Status: implemented (branch: `01-basic-rag-chatbot`)

- Part 1 — pg_vectorize + Agentic Chunking (current)
  - Add Timescale pgai Vectorizer worker for automatic embeddings
  - Agentic chunking with variable-size chunks and provenance (offsets/sections)
  - Status: in progress (branch: `02-agentic-chunking`)

- Episode 2 — Hybrid Search (FTS + Vector)
  - Add `TSVECTOR` + GIN; weighted score combining `ts_rank_cd` with vector similarity
  - Toggle retrieval to compare hybrid vs vector-only

- Episode 3 — Re-ranking (LLM or Cross-encoder)
  - Re-rank top-N candidates before the LLM
  - Store rerank scores in retrieval logs for evaluation

- Episode 4 — Multi-query Retrieval (Expansion + Diversity)
  - LLM-based query expansions; union + MMR-like selection
  - Dedupe and improve recall/coverage for complex questions

- Episode 5 — Contextual Embeddings (Domain-aware)
  - Maintain multiple embedding columns (general + domain-specific)
  - Weighted query scoring across embeddings or pre-normalized text

- Episode 6 — Agentic RAG Orchestration
  - Retrieval planner (tool selection, iterative retrieval, self-refine)
  - Trace logging for observability and A/B testing

- Episode 7 — SQL/Table Querying (Text-to-SQL)
  - Read-only role sandbox with guardrails and timeouts
  - Natural language to SQL with schema introspection

- Episode 8 — Citations & Source Tracking
  - Return precise provenance (document, seq, char offsets, section path)
  - UI annotations for trust and auditability

- Episode 9 — Knowledge Graph Augmentation (Optional)
  - Relational nodes/edges with recursive CTEs, or Apache AGE
  - Graph-driven narrowing followed by vector retrieval
