# Semantic (AI) search — how to turn it on

## What this is
`GET /api/v1/search/semantic?q=...` — free-text search that ranks services by
meaning (embedding similarity) instead of exact keywords, so a query like
`بدي حدا يصلح التكييف` can still find a listing titled "AC Repair". Works for
Arabic and English since the model (`paraphrase-multilingual-mpnet-base-v2`)
is multilingual.

It's **off by default** — the model dependency is heavy and shouldn't be a
surprise 1.1GB download the first time someone runs the backend.

## One-time setup
1. Install the dependencies **including** the optional one. It is deliberately
   not in `requirements.txt`, so a plain `pip install -r requirements.txt`
   does **not** pick it up:
   ```
   pip install -r requirements-semantic.txt
   ```
   (That file includes `requirements.txt`, so it is a complete install, not an
   extra step on top. Installing just the package — `pip install
   sentence-transformers` — works too if the rest is already in place.)
   This pulls in `torch` — expect a large download (several hundred MB) and
   a minute or two the very first time the model itself downloads
   (`paraphrase-multilingual-mpnet-base-v2`, ~1.1GB, cached under
   `~/.cache/huggingface` afterward). Plan on roughly 1–1.5GB of RAM for the
   server process with the model loaded.

2. In `backend/.env`, set:
   ```
   SEMANTIC_SEARCH_ENABLED=true
   ```

3. Restart the backend. The model loads lazily on the **first** semantic
   search request (not at startup), so the first call will be noticeably
   slower than the rest.

## How it works (and its current limits)
- Each active service's title + description + category text gets embedded
  and cached in memory, keyed to a hash of that text — so a search only
  pays the embedding cost for services whose text actually changed since
  the last search, not the whole catalog every time.
- That cache is **in-process and resets on restart** — fine for a single
  `uvicorn` worker in dev/demo use, but if you ever run multiple workers or
  want this to survive restarts, the embeddings should move to a DB column
  (pgvector) or a small vector store instead. Out of scope for now.
- `threshold` (query param, default `0.35`) is the minimum cosine similarity
  to count as a match — lower it if relevant results are getting filtered
  out, raise it if results feel too loose.

## Testing it worked
```
GET /api/v1/search/semantic?q=someone to fix my AC&limit=5
```
- If you get a `503` with a message about `sentence-transformers` — the pip
  install didn't happen (or happened in a different venv than the one
  running uvicorn).
- If you get a `503` with a message about being disabled — `.env` still has
  `SEMANTIC_SEARCH_ENABLED=false` (or the line is missing — it defaults to
  false) or the backend wasn't restarted after editing `.env`.
- Otherwise you should get back a list of services sorted by
  `similarity_score`, best match first.
