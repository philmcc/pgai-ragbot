import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List
from sentence_transformers import CrossEncoder


class RerankRequest(BaseModel):
    model: str
    query: str
    documents: List[str]


class RerankResponse(BaseModel):
    scores: List[float]


app = FastAPI()


_MODEL_CACHE: dict[str, CrossEncoder] = {}


def load_model(name: str) -> CrossEncoder:
    if name not in _MODEL_CACHE:
        try:
            _MODEL_CACHE[name] = CrossEncoder(name)
        except Exception as exc:  # pragma: no cover - surface errors via HTTP
            raise HTTPException(status_code=500, detail=f"Failed to load reranker model {name}: {exc}")
    return _MODEL_CACHE[name]


@app.post("/rerank", response_model=RerankResponse)
def rerank(req: RerankRequest) -> RerankResponse:
    model_name = req.model or os.environ.get("RERANKER_DEFAULT_MODEL", "BAAI/bge-reranker-base")
    model = load_model(model_name)
    pairs = [(req.query, doc) for doc in req.documents]
    try:
        scores = model.predict(pairs)
    except Exception as exc:  # pragma: no cover
        raise HTTPException(status_code=500, detail=f"Reranker inference failed: {exc}")
    return RerankResponse(scores=list(map(float, scores)))
