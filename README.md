<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# provide response in .md file

Below is a complete README.md you can save as a .md file.

# RAG Injector \& Retriever for Kong

Two Kong plugins enabling production-ready Retrieval-Augmented Generation (RAG): an injector that chunks and embeds documents into Redis using Azure OpenAI, and a retriever that performs KNN vector search to return top‑k relevant chunks for LLM prompts.[^11][^12]

## Repo name

kong-rag-injector-retriever. Short, descriptive, kebab‑case, and discoverable within the Kong ecosystem.[^13][^14]

## Highlights

- Doc Embedder (doc-embedder): POST documents, chunk text, generate embeddings, and store content + metadata + packed float32 vectors in Redis.[^15][^11]
- RAG Retriever (rag-retriever): POST a query, generate an embedding, run RediSearch KNN, and get structured top‑k results.[^12][^16]
- Clear JSON contracts, robust error handling, TLS to Redis (rediss), and encrypted/referenceable API keys in schema.[^16][^11][^12][^15]


## Direct download links

Replace OWNER/REPO/BRANCH with actual values after pushing to GitHub.

- Download rag-retriever/schema.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/rag-retriever/schema.lua[^17][^18]
- Download rag-retriever/handler.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/rag-retriever/handler.lua[^18][^17]
- Download doc-embedder/schema.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/doc-embedder/schema.lua[^17][^18]
- Download doc-embedder/handler.lua:
    - https://raw.githubusercontent.com/OWNER/REPO/BRANCH/kong/plugins/doc-embedder/handler.lua[^18][^17]

Tip: For immutable permalinks, use a commit SHA instead of BRANCH. For packaged artifacts, prefer Release assets and link from README.[^19][^20]

## Architecture

- Execution: both plugins run in the access phase; retriever priority 900, embedder 800.[^11][^12]
- Vector store: Redis with RediSearch stores float32 binary vectors in HASHes under a configurable prefix; index management is external.[^11]
- Embeddings: Azure OpenAI for both ingestion and retrieval to ensure consistent vector space (default 1536 dims).[^15][^16]


## Repository structure

- kong/plugins/doc-embedder/handler.lua[^11]
- kong/plugins/doc-embedder/schema.lua[^15]
- kong/plugins/rag-retriever/handler.lua[^12]
- kong/plugins/rag-retriever/schema.lua[^16]
- scripts/setup.sh (example FT.CREATE and Admin API calls — suggested)[^12][^11]


## Prerequisites

- Kong Gateway (OSS/EE), Redis with RediSearch, Azure OpenAI embedding deployment and API key.[^12][^11]
- A pre‑created RediSearch index (example below).[^11]


## Installation

1) Copy plugin files into Kong:

- doc-embedder → kong/plugins/doc-embedder/{handler.lua,schema.lua}[^15][^11]
- rag-retriever → kong/plugins/rag-retriever/{handler.lua,schema.lua}[^16][^12]

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

MIT (suggested).[^11][^12]
<span style="display:none">[^1][^10][^2][^3][^4][^5][^6][^7][^8][^9]</span>

<div align="center">⁂</div>

[^1]: https://stackoverflow.com/questions/19699059/print-directory-file-structure-with-icons-for-representation-in-markdown

[^2]: https://www.markdownguide.org/basic-syntax/

[^3]: https://gist.github.com/whoisryosuke/813186b07e6c9e4d23593041827a6530

[^4]: https://markdown-it.github.io

[^5]: https://www.w3schools.io/file/markdown-folder-tree/

[^6]: https://dev.to/developerehsan/how-to-easily-create-folder-structure-in-readme-markdown-with-two-simple-steps-3i42

[^7]: https://www.markdownguide.org/hacks/

[^8]: https://quarto.org/docs/authoring/markdown-basics.html

[^9]: https://docs.github.com/github/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax

[^10]: https://www.markdownguide.org/getting-started/

[^11]: handler.lua

[^12]: handler.lua

[^13]: https://github.com/Kong/kong-plugin

[^14]: https://stackoverflow.com/questions/11947587/is-there-a-naming-convention-for-git-repositories

[^15]: schema.lua

[^16]: schema.lua

[^17]: https://stackoverflow.com/questions/8779197/how-to-link-files-directly-from-github-raw-github-com

[^18]: https://github.com/orgs/community/discussions/44370

[^19]: https://docs.github.com/en/repositories/working-with-files/using-files/getting-permanent-links-to-files

[^20]: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases

