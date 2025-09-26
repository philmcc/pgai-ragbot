# Episode 3 — Hybrid Search for RAG

## TL;DR
- Combine lexical (sparse) search, e.g., BM25/Postgres full‑text search, with dense semantic search (pgvector embeddings).
- Hybrid search significantly improves recall, robustness to phrasing, and ranking quality over either method alone.
- Minimal infra changes if you already run Postgres + pgvector: add a `tsvector` column + GIN index, compute both scores, then fuse them.

---

## What is Hybrid Search?
Hybrid search fuses two complementary retrieval signals:

- Lexical (Sparse): Matches exact or near‑exact query terms using an inverted index. In Postgres this is typically full‑text search (FTS) with `tsvector`, `tsquery`, BM25‑style ranking via `ts_rank`/`ts_rank_cd`.
- Semantic (Dense): Finds meaningfully similar chunks using vector embeddings stored in `pgvector` and compared with cosine/inner‑product/L2 distance.

Each method has different strengths:
- Lexical excels at precise tokens, IDs, code symbols, rare jargon, and negations.
- Semantic excels at paraphrases, synonyms, and capturing latent meaning.

Hybrid search blends them to get the best of both.

---

## Why add Hybrid Search to our RAG chatbot?
In a RAG pipeline, retrieval quality is the main driver of grounded answers. Hybrid search notably helps with:

- Improved Recall: If semantic misses rare terms or lexical misses paraphrases, the other compensates.
- Robustness to User Phrasing: Users ask the same thing in many ways; semantic helps match paraphrases.
- Handling Rare or OOV Tokens: Lexical ensures IDs, acronyms, and exact terms are not lost.
- Better Ranking: Combining signals reduces tail‑failures and surfaces the actually relevant chunks higher.
- Reduced Hallucinations: Better context -> more grounded generations.

Empirically, many production RAG systems observe meaningful gains in MRR/NDCG and task success after switching from single‑mode to hybrid retrieval.

---

## How we’ll implement it in `pgai-ragbot`
We already have pgvector and chunk embeddings (Episode 2). For Episode 3 we will:

1. Data model additions
   - Add a `tsvector` column for lexical search, e.g., `lexeme tsvector` built from chunk text.
   - Create a GIN index on that `tsvector`.

2. Query path
   - For each user query:
     - Compute an embedding (as today) and run a semantic `ORDER BY embedding <-> query_embedding LIMIT k_sem`.
     - Build a `tsquery` with `plainto_tsquery('english', :query)` (or `to_tsquery` for advanced use) and run lexical search `ORDER BY ts_rank_cd(lexeme, tsquery) DESC LIMIT k_lex`.
     - Fuse the scores (see Fusion Strategies) and return top‑K.

3. Serving changes
   - Minimal: augment existing retrieval function/SQL to compute both scores and a combined score.
   - Optional: add a two‑stage reranker (cross‑encoder) later for Episode 4+.

---

## Fusion Strategies
Several well‑known strategies can fuse lexical and semantic signals. We’ll start simple and allow tuning:

- Weighted Sum (score‑level fusion)
  - Normalize both scores to [0, 1] and compute `final = w_lex * s_lex + w_sem * s_sem`.
  - Easy to implement; weights can be tuned with a small validation set.

- Reciprocal Rank Fusion (RRF)
  - Compute rank positions from each retriever and use `1 / (k + rank)` summed across signals. Robust and parameter‑light.

- Two‑Stage (Cascade)
  - Take the union of top candidates from each retriever and rerank with a stronger model (e.g., cross‑encoder). Higher quality but higher latency/cost.

We’ll begin with Weighted Sum and optionally add RRF.

---

## Example SQL sketch (Postgres + pgvector)
Below is an illustrative approach using CTEs. Exact table/column names may differ in our schema; we’ll adapt during implementation.

```sql
WITH params AS (
  SELECT
    :query::text            AS q,
    :query_embedding::vector AS q_vec,
    0.5::float              AS w_lex,  -- tune
    0.5::float              AS w_sem,  -- tune
    50::int                 AS k_sem,
    50::int                 AS k_lex
),
lex AS (
  SELECT
    c.id,
    ts_rank_cd(c.lexeme, plainto_tsquery('english', (SELECT q FROM params))) AS lex_score
  FROM chunks c
  WHERE c.lexeme @@ plainto_tsquery('english', (SELECT q FROM params))
  ORDER BY lex_score DESC
  LIMIT (SELECT k_lex FROM params)
),
sem AS (
  SELECT
    c.id,
    1.0 - (c.embedding <-> (SELECT q_vec FROM params)) AS sem_score  -- convert distance to similarity
  FROM chunks c
  ORDER BY c.embedding <-> (SELECT q_vec FROM params)
  LIMIT (SELECT k_sem FROM params)
),
unioned AS (
  SELECT id, lex_score, NULL::float AS sem_score FROM lex
  UNION
  SELECT id, NULL::float AS lex_score, sem_score FROM sem
),
aggr AS (
  SELECT
    u.id,
    max(lex_score) AS lex_score,
    max(sem_score) AS sem_score
  FROM unioned u
  GROUP BY u.id
),
-- Simple min-max normalization per query (bounded by observed tops). More robust: precompute global stats or use RRF.
stats AS (
  SELECT
    min(lex_score) FILTER (WHERE lex_score IS NOT NULL) AS min_lex,
    max(lex_score) FILTER (WHERE lex_score IS NOT NULL) AS max_lex,
    min(sem_score) FILTER (WHERE sem_score IS NOT NULL) AS min_sem,
    max(sem_score) FILTER (WHERE sem_score IS NOT NULL) AS max_sem
  FROM aggr
)
SELECT
  a.id,
  -- normalize to [0,1]; fallback to 0 when null
  coalesce((a.lex_score - s.min_lex) / NULLIF(s.max_lex - s.min_lex, 0), 0) AS lex_norm,
  coalesce((a.sem_score - s.min_sem) / NULLIF(s.max_sem - s.min_sem, 0), 0) AS sem_norm,
  (SELECT w_lex FROM params) * coalesce((a.lex_score - s.min_lex) / NULLIF(s.max_lex - s.min_lex, 0), 0)
+ (SELECT w_sem FROM params) * coalesce((a.sem_score - s.min_sem) / NULLIF(s.max_sem - s.min_sem, 0), 0)
    AS final_score
FROM aggr a
CROSS JOIN stats s
ORDER BY final_score DESC
LIMIT 20;
```

Notes:
- `ts_rank_cd` is a BM25‑style ranking function in Postgres; `plainto_tsquery` is safe and simple; `to_tsquery` allows boolean/phrase queries.
- We convert vector distance to similarity via `1 - distance` for cosine if vectors are normalized; adjust if using L2/IP.
- For production, consider RRF or z‑score normalization over a larger pool to stabilize scores.

---

## Tuning and Evaluation
- Weight Tuning: Grid‑search `w_lex`/`w_sem` on a small labeled set of queries/answers; maximize NDCG@k or MRR.
- Diagnostics: Log per‑query which retriever contributed each top result and the combined score.
- Metrics: Track Recall@k, MRR/NDCG@k, and downstream answer quality/hallucination rate.
- Offline + Online: Validate offline with a golden set, then A/B in the app.

---

## Considerations
- Language: Choose the right FTS configuration (e.g., `'english'`); support multi‑lingual if needed.
- Negation/Operators: FTS handles operators precisely; be careful with overly aggressive stemming.
- Query Preprocessing: Keep it minimal; avoid losing rare tokens that users may rely on.
- Cost/Latency: Two parallel lookups in the same DB are cheap; fusion adds little overhead. Reranking adds latency if enabled.

---

## Proposed Next Steps
1. Add migration to create `lexeme tsvector` column on chunks and a GIN index.
2. Backfill `lexeme` via `to_tsvector('english', content)` for all rows; set up trigger to keep it fresh on insert/update.
3. Update retrieval SQL/function to run both searches and fuse scores (weighted sum or RRF).
4. Expose a feature flag to toggle hybrid and adjust weights without redeploy.
5. Add logging and a small labeled eval set to tune weights and validate gains.

Once this is in place, we can iterate on reranking and advanced fusion as needed.

---

## Implementation in branch `03-hybrid-search` (current state)

- Schema
  - Added `app.doc_chunks.lexeme tsvector` with a `GIN` index and a trigger `app.trg_update_doc_chunks_lexeme()` to keep it current. See `db/init/02_schema.sql` and migration `db/migrations/2025-09-26_hybrid_search.sql`.

- Retrieval functions (in `db/init/04_rag.sql`)
  - Created `app.search_chunks_hybrid(p_query text, k int, p_w_lex float4, p_w_sem float4)` implementing weighted fusion of:
    - Lexical FTS via `websearch_to_tsquery('english', p_query)` over `doc_chunks.lexeme` and a light filename signal from `documents.s3_key`.
    - Semantic similarity via `pgvector` query embedding.
    - Min–max normalization with guards for small candidate pools; weights coalesced with sane defaults.
  - Temporarily wired `app.chat_rag` to use the hybrid function, then reverted to semantic‑only (`app.search_chunks`) due to inconsistent results on your corpus.

- Frontend (in `frontend/`)
  - Added a Debug Retrieval panel with sliders and tooltips for lexical/semantic weights. Currently, the panel calls the semantic endpoint (`/rpc/search_chunks`) after the rollback; sliders are left in place for future experiments.
  - Collapsible sidebar cards now start minimized; added accessible tooltips.

---

## How to re‑enable Hybrid later

1) Switch chat to hybrid in `db/init/04_rag.sql` by changing the `FROM` in `app.chat_rag`:

```sql
FROM app.search_chunks_hybrid(p_query, k, 0.2, 0.8) s  -- example weights
```

Then reload the SQL and refresh PostgREST:

```bash
docker compose exec -T db psql -U postgres -d pgai -v ON_ERROR_STOP=1 -f - < db/init/04_rag.sql
docker compose restart postgrest
```

2) Switch the Debug Retrieval panel back to hybrid by changing `frontend/main.js` `debugSearch()` to call `/rpc/search_chunks_hybrid` and include `p_w_lex`/`p_w_sem` from the sliders.

Hard refresh the browser afterwards (Cmd+Shift+R).

---

## Testing & evaluation checklist

- Use curl to compare semantic vs hybrid:

```bash
curl -sS -X POST http://localhost:3000/rpc/search_chunks \
  -H 'Content-Type: application/json' -d '{"p_query":"<q>","k":10}' | jq .

curl -sS -X POST http://localhost:3000/rpc/search_chunks_hybrid \
  -H 'Content-Type: application/json' -d '{"p_query":"<q>","k":10,"p_w_lex":0.5,"p_w_sem":0.5}' | jq .
```

- Lightweight metrics in SQL: Recall@10 and MRR@10 over a tiny gold set (see examples earlier in this doc).

---

## Known issues (reason for rollback)

- Some queries underperformed due to phrasing mismatch (e.g., asking for “features” while docs say “release notes” or “changes”). Query expansion would help.
- Min–max normalization can be unstable for tiny candidate pools; we added guards but tuning is still required per corpus.
- The filename/version heuristics improved some queries but were not universally reliable.

Given the above, chat is currently reverted to semantic‑only to ensure stable answers. Hybrid infra remains in place for future tuning.

---

## Next steps when we revisit Hybrid

- Add simple query expansion for common synonyms (features/new/changes/release).
- Add a UI toggle to choose Semantic vs Hybrid per request.
- Try Reciprocal Rank Fusion (RRF) to reduce dependence on score normalization.
- Optionally add a reranking stage (cross‑encoder) for top‑N.
