# Episode 4 — Reranking for Higher-Precision Retrieval

## TL;DR
- Reranking applies a stronger (usually cross-encoder) model to a short list of retrieved candidates to refine their final order.
- Adds precision on top of hybrid retrieval by better modeling interactions between the user query and each chunk.
- Requires an inference-friendly reranker model, an orchestration path for two-stage retrieval, and metrics to validate the gains.

---

## What is Reranking?
Reranking is a **two-stage retrieval strategy**. A first-stage retriever (sparse, dense, or hybrid) produces a coarse-grained set of candidate chunks. A second-stage model then reevaluates each candidate alongside the query to assign a more accurate relevance score.

- **Cross-encoders**: Encode the query and chunk together, attending to word-level interactions. Examples: `cross-encoder/ms-marco-MiniLM-L-6-v2`, `bge-reranker-base`. These offer the best quality but require more compute.
- **Bi-encoders with lightweight scoring**: Faster alternatives that reuse embeddings but add small interaction modules (e.g., ColBERT, late interaction). Lower latency, slightly lower precision.
- **Heuristic rerankers**: Simpler reordering based on metadata (recency, source authority) or rule-based scoring. Less effective but cheap.

For Episode 4 we will focus on neural cross-encoder rerankers because they produce the largest quality lift for question answering.

---

## Why add Reranking to `pgai-ragbot`?
First-stage retrieval (Episode 2 semantic + Episode 3 hybrid) excels at recall, but top results can still include loosely related chunks. Reranking improves:

- **Answer grounding**: Higher-quality top-3 chunks reduce hallucinations and improve citation fidelity.
- **Precision at K**: Cross-encoders explicitly compare the query to each candidate sentence/paragraph, down-weighting off-topic but semantically similar passages.
- **Query nuance handling**: Captures subtle intent (negations, constraint phrases like "after 2024", references to specific releases or components).
- **Long-tail robustness**: Helps when lexical and semantic scores disagree or when the best answer is buried mid-pack.

Empirically, many RAG systems observe 5–15 point gains in MRR@10 / NDCG@10 and noticeable qualitative improvements in chat answers after adding reranking.

---

## Implementation Requirements
To incorporate reranking we will need updates across data, services, and evaluation:

### 1. Candidate Generation (reuse Episodes 2–3)
- Continue using `app.search_chunks_hybrid` (or semantic fallback) to retrieve `k_first_stage` candidates (e.g., 40–100).
- Ensure we return per-candidate metadata (chunk ID, document reference, lexical/semantic scores) for downstream logging.

### 2. Reranker Model
- Choose an accessible cross-encoder (e.g., `bge-reranker-large` for quality or `bge-reranker-base` for balance).
- Hosting options:
  - **Local inference**: Package model weights via `pgai-vectorizer` or a new microservice; requires GPU/fast CPU.
  - **External API**: OpenAI `text-embedding-3-large` with rerank endpoint (when available) or VoyageAI / Cohere Rerank; needs API key management and cost tracking.
- Define model input format: `[query]` paired with each chunk's trimmed text (respect token limits, typically 512–1024 tokens combined).

### 3. Implementation Snapshot (branch `04-reranking`)
- Added `app.invoke_reranker()` PL/Python shim that calls the reranker microservice (default `http://reranker:8000/rerank`).
- Introduced `app.search_chunks_rerank()` orchestrating first-stage retrieval (semantic or hybrid), deduping candidates, calling the reranker, logging to `rerank_events`, and returning reranked rows.
- Extended `app.chat_rag_opts()` with new parameters (`p_stage_k`, `p_use_rerank`, `p_rerank_stage_mode`, `p_rerank_model`) and new modes (`semantic_rerank`, `hybrid_rerank`).
- Created `rerank_events` table + `app.v_rerank_events` view for observability and PostgREST access.
- Added reranker FastAPI service under `reranker/` (Dockerized, caches Hugging Face weights, defaults to `BAAI/bge-reranker-base`). Compose now runs it as `pgai-reranker` and propagates `RERANK_ENDPOINT` into Postgres.
- Introduced `app.rerank_enabled()` guard controlled by env `RERANK_ENABLED` (default `true`) so deployments without the reranker can disable two-stage scoring without code changes.
- Frontend updates (`frontend/index.html`, `frontend/main.js`) expose rerank toggles, stage-K controls, model selection, reranked debug output, and a rerank event log panel.

### 3. Orchestration Layer
- Extend the retrieval pipeline (likely in `db/init/04_rag.sql` or the application service) to:
  1. Call first-stage retriever (`k_first_stage`).
  2. Call reranker with query + candidate texts.
  3. Sort candidates by reranker score and return top `k_final` (e.g., 8–12).
- Add fallbacks when reranker call fails (return baseline ranking) to keep the chatbot responsive.

### 4. Latency & Cost Controls
- Cache query embeddings and optionally reranker scores for repeated queries.
- Limit candidate text length (e.g., first 400–600 characters) to avoid timeouts.
- Consider async prefetch or batching if multiple chats run concurrently.

### 5. Observability & Evaluation
- Log first-stage vs reranked positions to measure uplift.
- Track latency (P50/P95) and model cost per request.
- Define evaluation set (reuse Episode 3 golden queries) and compute precision/recall metrics before/after reranking.
- Optionally add an A/B flag to compare reranked vs baseline responses in-app.
- **Current status**: `app.v_rerank_events` is queryable from the UI panel to inspect recent rerank decisions. Each entry records query text, doc/seq, stage rank, distances, rerank score, and model ID.

---

## Proposed Task Breakdown for Episode 4
1. **Select reranker model and hosting strategy** (local vs API) with constraints documented in `episode-4/PLAN.md`.
2. **Implement reranker service wrapper** (new microservice or extension to existing vectorizer) exposing `/rerank`.
3. **Update retrieval flow** to perform two-stage ranking and return reranked context to `app.chat_rag`.
4. **Add configuration & toggles** (`k_first_stage`, `k_final`, model name, feature flag).
5. **Evaluate and document metrics** demonstrating gains; iterate on chunk sizing if needed.

---

## References
- [Cohere Rerank overview](https://docs.cohere.com/docs/rerank)
- [BAAI BGE Reranker models](https://huggingface.co/BAAI/bge-reranker-base)
- [MS MARCO Cross-Encoder baseline](https://huggingface.co/cross-encoder/ms-marco-MiniLM-L-6-v2)
