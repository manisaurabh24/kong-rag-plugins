# RAG Injector \& Retriever for Kong

Two Kong plugins enabling production-ready Retrieval-Augmented Generation (RAG): an injector that chunks and embeds documents into Redis using Azure OpenAI, and a retriever that performs KNN vector search to return top‑k relevant chunks for LLM prompts.

## Repo name

kong-rag-plugin

## Highlights

- Doc Embedder (doc-embedder): POST documents, chunk text, generate embeddings, and store content + metadata + packed float32 vectors in Redis.
- RAG Retriever (rag-retriever): POST a query, generate an embedding, run RediSearch KNN, and get structured top‑k results.
- Clear JSON contracts, robust error handling, TLS to Redis (rediss), and encrypted/referenceable API keys in schema.

## Direct download links

Replace OWNER/REPO/BRANCH with actual values after pushing to GitHub.

- Download rag-retriever/schema.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/rag-retriever/schema.lua
- Download rag-retriever/handler.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/rag-retriever/handler.lua
- Download doc-embedder/schema.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/doc-embedder/schema.lua
- Download doc-embedder/handler.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/doc-embedder/handler.lua
Tip: For immutable permalinks, use a commit SHA instead of BRANCH. For packaged artifacts, prefer Release assets and link from README

## Architecture

- Execution: both plugins run in the access phase; retriever priority 900, embedder 800.
- Vector store: Redis with RediSearch stores float32 binary vectors in HASHes under a configurable prefix; index management is external.
- Embeddings: Azure OpenAI for both ingestion and retrieval to ensure consistent vector space (default 1536 dims).


## Repository structure

- kong/plugins/doc-embedder/handler.lua
- kong/plugins/doc-embedder/schema.lua
- - kong/plugins/rag-retriever/handler.lua
- kong/plugins/rag-retriever/schema.lua
- scripts/setup.sh (example FT.CREATE and Admin API calls — suggested)


## Prerequisites

- Kong Gateway (OSS/EE), Redis with RediSearch, Azure OpenAI embedding deployment and API key.
- A pre‑created RediSearch index (example below).


## Installation

1) Copy plugin files into Kong:

- doc-embedder → kong/plugins/doc-embedder/{handler.lua,schema.lua}
- rag-retriever → kong/plugins/rag-retriever/{handler.lua,schema.lua}

2) Enable plugins in kong.conf:

- plugins = bundled,doc-embedder,rag-retriever[^12][^11]

3) Restart or reload Kong.[^11][^12]

## RediSearch index (example)

Ensure DIM matches the embedding model (default 1536).[^16][^15]

- FT.CREATE doc_embeddings_idx ON HASH PREFIX 1 "doc:" SCHEMA content TEXT metadata TEXT embedding VECTOR FLAT 6 TYPE FLOAT32 DIM 1536 DISTANCE_METRIC COSINE INITIAL_CAP 10000[^11]


## Configuration

Doc Embedder (ingestion route)[^15]

- redis_url: rediss://user:pass@host:6380[^15]
- redis_index: doc_embeddings_idx[^15]
- redis_prefix: doc:[^15]
- azure_endpoint: https://<resource>.openai.azure.com[^15]
- azure_api_key: secret or reference (encrypted/referenceable)[^15]
- deployment: text-embedding-3-large (example)[^15]
- api_version: 2025-01-01-preview (default)[^15]
- chunk_size: 1000, chunk_overlap: 50, max_chunks: 200, embedding_dim: 1536[^15]

RAG Retriever (search route)[^16]

- Same redis_* and azure_* values as ingestion[^16]
- embedding_dim: 1536[^16]
- top_k: 5 (overridable per request)[^16]
- similarity_threshold: 0.7 (exposed for future filtering)[^16]


## Usage

Health check (Redis ping)[^11]

- POST /ingest
- Body: { "redis_test": true }
- 200 → { "status": "ok", "redis": "PONG" }

Ingest document[^11]

- POST /ingest
- Body: { "document": "long text...", "metadata": { "source": "kb", "lang": "en" } }
- 200 → { "message", "chunks", "stored_ids": ["..."] }

Retrieve top‑k[^12]

- POST /search
- Body: { "query": "How to rotate API keys?", "top_k": 5 }
- 200 → { "total", "docs": [ { "id", "content", "metadata" } ] }


## Security

- Secrets: azure_api_key encrypted/referenceable; integrate with secret managers or env references.[^16][^15]
- Transport: use TLS to Redis (rediss) and SSL verification for Azure API requests.[^12][^11]
- Gateway policy: protect routes with authn/z and rate limits; sanitize or minimize PII in metadata.[^12][^11]


## Performance

- Cost and latency bounded via chunk_size, chunk_overlap, max_chunks; large docs return 413 early.[^11][^15]
- Binary packing of embeddings reduces memory and network overhead.[^12][^11]
- Keepalive and 5s timeouts on Redis; compact embedding requests to Azure.[^12][^11]


## Limitations

- Index creation is not performed by the plugin; manage via ops tooling.[^11]
- Ensure ingestion and retrieval use the same embedding model and dimension.[^12][^11]


## Roadmap

- Threshold-based server-side filtering and re-ranking.[^16]
- Batch/stream ingestion mode and larger chunk orchestration.[^11]
- Metrics and tracing for observability.[^12][^11]


## License


