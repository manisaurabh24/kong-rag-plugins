
# RAG Injector \& Retriever for Kong

Two Kong plugins enabling production-ready Retrieval-Augmented Generation (RAG): an injector that chunks and embeds documents into Redis using Azure OpenAI, and a retriever that performs KNN vector search to return top‑k relevant chunks for LLM prompts.

## Custom Plugins

- doc-embedder: Accepts raw documents, chunks the text, generates embeddings with Azure OpenAI, and writes HASH records into Redis that include content, metadata, and packed Float32 vectors for fast vector search.
- rag-retriever: Takes a user query, creates its embedding, executes a RediSearch KNN over the stored vectors, and returns structured top‑k relevant chunks ready to prepend to the LLM prompt

## Highlights

- Doc Embedder (doc-embedder): POST documents, chunk text, generate embeddings, and store content + metadata + packed float32 vectors in Redis.
- RAG Retriever (rag-retriever): POST a query, generate an embedding, run RediSearch KNN, and get structured top‑k results.
- Clear JSON contracts, robust error handling, TLS to Redis (rediss), and encrypted/referenceable API keys in schema.


## Architecture

- Execution: both plugins run in the access phase; retriever priority 900, embedder 800.
- Vector store: Redis with RediSearch stores float32 binary vectors in HASHes under a configurable prefix; index management is external.
- Embeddings: Azure OpenAI for both ingestion and retrieval to ensure consistent vector space (default 1536 dims).
 
 
Installation

# Prerequisites

- Kong Gateway EE with AI Licence
- Redis with RediSearch
- Azure OpenAI embedding deployment and API key.  You can also use your own LLM
- A pre‑created RediSearch index (example below).


## Installing the plugin

There are two things necessary to make a custom plugin work in Kong:

1. Install it locally (based on the .rockspec in the current directory):
```

sudo luarocks make

```

2. Pack the installed rock:
```

luarocks pack YOUR-PLUGIN-NAME PLUGIN-VERSION

```

3. Load the plugin files.

The easiest way to install the plugin is using `luarocks`.

```

luarocks install [https://github.com/manisaurabh24/kong-rag-plugins/blob/main/kong-rag-plugins/kongversation-…](https://github.com/manisaurabh24/kong-rag-plugins/blob/main/kong-rag-plugins/kong-rag-plugins-1.0-1.all.rock)

```

You can substitute `0.1.0-1` in the command above with any other version you want to install.
 
 
5. Specify that you want to use the plugin by modifying the plugins property in the Kong configuration.
 
Add the custom plugin’s name to the list of plugins in your Kong configuration:

```conf

plugins = bundled, kong-rag-plugins

```

If you are using the Kong helm chart, create a configMap with the plugin files and add it to your `values.yaml` file:

```yaml

# values.yaml

plugins:

  configMaps:

  - name: kong-rag-plugins

    pluginName: kong-rag-plugins

```

## Configuring Kong Gateway -

```

_format_version: "3.0"

_transform: true
 
_info:

  select_tags:

  - rag_ret

_konnect:

  control_plane_name: tcsai
 
 
services:

  # Document Embedding Service

  - name: doc-embedder-service

    url: [http://localhost:8080](http://localhost:8080)

    routes:

      - name: embed-route

        paths:

          - /v1/embedd

        methods:

          - POST

    plugins:

      - name: doc-embedder

        config:

          azure_endpoint: ${azure_endpoint}

          deployment: "BTG_text-embedding-ada-002"

          api_version: "2025-01-01-preview"

          azure_api_key: "${azure_api_key}"

          redis_url: "redis://default:${redis_pwd}@redis-15934.crce206.ap-south-1-1.ec2.redns.redis-cloud.com:15934"

          redis_index: "hr_mitr_index"

          redis_prefix: "doc:"

          chunk_size: 500

          chunk_overlap: 50

          max_chunks: 50

          embedding_dim: 1536
 
  # RAG Retrieval Service

  - name: rag-retrieval-service

    url: [http://localhost:8080](http://localhost:8080)

    routes:

      - name: rag-route

        paths:

          - /v1/rag

        methods:

          - POST

    plugins:

      - name: rag-retriever

        config:

          azure_endpoint: ${azure_endpoint}

          deployment: "BTG_text-embedding-ada-002"

          api_version: "2025-01-01-preview"

          azure_api_key: "${azure_api_key}"

          redis_url: "redis://default:${redis_pwd}@redis-15934.crce206.ap-south-1-1.ec2.redns.redis-cloud.com:15934"

          redis_index: "hr_mitr_index"

          redis_prefix: "doc:"

          embedding_dim: 1536

          top_k: 5

          similarity_threshold: 0.7
 
```

Test
 
a. Do document embedding
 
curl -X POST [http://localhost:8000/v1/embed](http://localhost:8000/v1/embed)   -H "Content-Type: application/json"   -d '{

"document": "This document covers distributed backpressure.",

"metadata": {"source":"doc.pdf","author":"Alice"},

"messages": [

{"role":"user","content":"Explain backpressure"}

]

}'
 
 
b. Retrieve

curl -X POST [http://localhost:8000/v1/rag](http://localhost:8000/v1/rag)   -H "Content-Type: application/json"   -d '{

"query": "What is backpressure?",

"top_k": 3

}'

{"total":3,"docs":[{"metadata":"{\"source\":\"docs.pdf\"}","content":"Distributed backpressure is a mechanism to prevent system overload.","id":"doc:677c7872-57d5-4935-bd08-95cf6ae7b5b7"},{"metadata":"{\"source\":\"architecture.pdf\",\"topic\":\"backpressure\"}","content":"Distributed backpressure is a mechanism to prevent system overload by controlling data flow rates across multiple services.","id":"doc:36d7cefa-2a17-48e7-8695-a85e73df3778"},{"metadata":"{\"author\":\"Alice\",\"source\":\"doc.pdf\"}","content":"This document covers distributed backpressure.","id":"doc:5654cc49-4ba5-4167-9c3e-dc7ffeab1cca"}]}(base)
kong-rag-plugins/kong-rag-plugins/kong-rag-plugins-1.0-1.all.rock at main · manisaurabh24/kong-rag-plugins
Stateless LLMs with Smart Contextual Memory using Kong Gateway - manisaurabh24/kong-rag-plugins
also add section in table format for future enhancement and inducty use cases  (cover govnance aspect , rbac etc

Here’s a polished, GitHub‑ready README in Markdown for “RAG Injector \& Retriever for Kong,” with clear setup, config, testing, and a comparison-style roadmap and industry use cases table.

"RAG Injector \& Retriever for Kong"

### Overview

Production‑ready RAG for Kong via two custom plugins: an injector that chunks, embeds, and stores documents in Redis, and a retriever that runs KNN vector search to return top‑k context for LLM prompts using consistent Azure OpenAI embeddings.

### Custom plugins

- Doc Embedder (doc‑embedder): Accepts documents, chunks text, generates embeddings, and stores content + metadata + packed Float32 vectors in Redis HASHes.
- RAG Retriever (rag‑retriever): Accepts a query, generates an embedding, runs RediSearch KNN, and returns structured top‑k results.
- Operational guardrails: JSON contracts, robust error handling, TLS to Redis (rediss) support, and encrypted/referenceable API keys in plugin schema.


### Highlights

- End‑to‑end RAG path: ingestion → chunking → embeddings → Redis → KNN → ranked chunks for prompts.
- Consistent vector space: Azure OpenAI embeddings for both ingestion and retrieval (default 1536 dims for text‑embedding‑ada‑002).
- Deployable in VM, Docker, or Helm; install via LuaRocks and enable with KONG_PLUGINS.


### Architecture

- Execution phase: both plugins run in access; suggested priorities: retriever 900, embedder 800 for predictable order.
- Vector store: Redis with RediSearch stores Float32 binary vectors in HASH fields under a configurable prefix; index management stays external to plugins.[^8]
- Embeddings: Azure OpenAI deployments for parity between write/read; typical dim 1536 for text‑embedding‑ada‑002.


### Prerequisites

- Kong Gateway (EE) with AI license enabled and permission to load custom plugins.
- Redis with RediSearch capability available; KNN queries enabled via FT.SEARCH with DIALECT 2.
- Azure OpenAI embedding deployment and API key (or compatible LLM for embeddings with matching dimensions).
- A pre‑created RediSearch index matching TYPE, DIM, and DISTANCE_METRIC for stored vectors.[^8]


### RediSearch index example

- HASH schema with Float32 vectors; DIM must match the embedding model used (e.g., 1536).
- Ensure returned embedding byte length equals DIM × 4 bytes for Float32, or indexing fails silently.

Example command outline (adapted to HASH):

- Create index with VECTOR HNSW or FLAT; specify TYPE FLOAT32, DIM 1536, DISTANCE_METRIC COSINE/L2.[^9]


### Installation

There are two required steps for custom Kong plugins: install the rock and enable the plugin in Kong.

1) Local build from rockspec:
```
sudo luarocks make
```

2) Pack the installed rock:
```
luarocks pack YOUR-PLUGIN-NAME PLUGIN-VERSION
```

3) Install via LuaRocks (remote rock or local file):

- Remote:

```
luarocks install <rock URL or name>
```

- Local (inside a Kong container or host):

```
luarocks install ./your-plugin-1.0-1.all.rock
```

4) Enable the plugin in Kong:

- kong.conf:

```
plugins = bundled, kong-rag-plugins
```

- Or via env:

```
export KONG_PLUGINS="bundled,kong-rag-plugins"
```

Kubernetes (Helm):

- Provide plugin files via ConfigMap and reference in values.yaml to load and enable the plugin on the data plane.

Notes:

- After enabling, restart or reload Kong; verify availability via Admin API or logs.
- For local iteration, “luarocks make” during development and “luarocks install <rock>” for distribution is typical.


### Kong configuration (deck example)

- Ensure service, route, and plugin attachments reflect desired paths and methods; inject secrets via environment references.
- Keep Azure endpoint, deployment, API version, and redis_url consistent across both plugins.

```yaml
_format_version: "3.0"
_transform: true

_info:
  select_tags:
    - rag_ret

_konnect:
  control_plane_name: tcsai

services:
  - name: doc-embedder-service
    url: http://localhost:8080
    routes:
      - name: embed-route
        paths:
          - /v1/embedd
        methods:
          - POST
    plugins:
      - name: doc-embedder
        config:
          azure_endpoint: ${azure_endpoint}
          deployment: "BTG_text-embedding-ada-002"
          api_version: "2025-01-01-preview"
          azure_api_key: "${azure_api_key}"
          redis_url: "redis://default:${redis_pwd}@host:port"
          redis_index: "hr_mitr_index"
          redis_prefix: "doc:"
          chunk_size: 500
          chunk_overlap: 50
          max_chunks: 50
          embedding_dim: 1536

  - name: rag-retrieval-service
    url: http://localhost:8080
    routes:
      - name: rag-route
        paths:
          - /v1/rag
        methods:
          - POST
    plugins:
      - name: rag-retriever
        config:
          azure_endpoint: ${azure_endpoint}
          deployment: "BTG_text-embedding-ada-002"
          api_version: "2025-01-01-preview"
          azure_api_key: "${azure_api_key}"
          redis_url: "redis://default:${redis_pwd}@host:port"
          redis_index: "hr_mitr_index"
          redis_prefix: "doc:"
          embedding_dim: 1536
          top_k: 5
          similarity_threshold: 0.7
```

Tips:

- If using TLS to Redis, use rediss:// and validate CA where supported by the client library used in the plugin.
- For text-embedding-3-* families, adjust DIM accordingly; 1536 for -small, up to 3072 for -large (or downsampled).


### Request/response examples

a) Embed a document:

```
curl -X POST http://localhost:8000/v1/embed \
  -H "Content-Type: application/json" \
  -d '{
    "document": "This document covers distributed backpressure.",
    "metadata": {"source":"doc.pdf","author":"Alice"},
    "messages": [{"role":"user","content":"Explain backpressure"}]
  }'
```
<p align="center" width="100%">
    <img src="assets/1-Embedd.png">
</p>

b) Retrieve top‑k:

```
curl -X POST http://localhost:8000/v1/rag \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What is backpressure?",
    "top_k": 3
  }'
```
<p align="center" width="100%">
    <img src="assets/2-retrieve.png">
</p>

Notes:

- The retriever uses FT.SEARCH KNN with DIALECT 2 and sorts by the vector score field; lower scores for cosine/L2 indicate closer matches depending on metric.
- Ensure the HASH field that stores the vector is a Float32 blob and dimension‑matched; mismatches cause empty results.


### Operations and troubleshooting

- Plugin not visible: verify KONG_PLUGINS includes the custom plugin and reload Kong; check Admin API plugin list.
- Redis search returns zero results: confirm index schema, DIM/type, and that HASH vs JSON schema matches storage format and field names.
- Packaging issues: consider using pongo pack or luarocks pack for consistent rock creation across environments.[^12]


### Security and governance

- Secrets: Use environment or vault references for Azure/OpenAI keys; avoid plaintext in deck files.
- TLS: Prefer rediss and validated certificates for in‑transit encryption between Kong and Redis.
- Access control: Use Kong RBAC in Admin plane and scoped plugin enablement per service/route to limit blast radius.


### Roadmap and use cases

 # Vector Service Governance & Architecture 

## Governance
- **Central policy pack**: rate limits, PII redaction, schema validation, audit logs  
- Enforce with global plugins and schema validation on POST bodies before embedding  
- Add structured audit of doc IDs and metadata fields  

## Security
- **Transport & storage**: mTLS to Redis, at-rest encryption for vectors, KMS-backed key rotation  
- Use `rediss://` and client certs  
- Consider encrypting metadata fields  
- Rotate Azure keys via CI/CD secrets  

## RBAC
- **Scopes & roles**: per-route scopes for embed vs retrieve, service-level JWT/OAuth  
- Gate `/v1/embed` to ingestion roles  
- Restrict `/v1/rag` to app clients  
- Align with Kong identity providers  

## Observability
- **Metrics & dashboards**: vector op metrics, KNN latency histograms, chunking/error dashboards  
- Emit custom metrics on chunk counts, bytes stored, `FT.SEARCH` latency  
- Correlate with route/service  

## Index Management
- **Helpers & jobs**: on-write upsert helpers, index warmers, auto-reindex hooks  
- External job to manage `FT.CREATE/ALTER`, cardinality checks, DIM/type consistency  

## Models
- **Pluggable backends**: dim auto-detect, mixed-model migration  
- Support `text-embedding-3-small/large`  
- Ensure DIM adheres to model  
- Enable downsampling for cost  

## Relevance
- **Search quality**: hybrid search (BM25+KNN), semantic rerankers, MMR/diversity  
- Combine RediSearch text fields with KNN  
- Post-rank via LLM/reranker for improved context quality  

## Chunking
- **Splitting strategy**: adaptive splitters, overlap tuning, media/doc types  
- Tune `chunk_size/overlap` by doc type  
- Add PDF/HTML extraction pipelines before embed  

## Caching
- **Performance**: query embedding cache and retrieval cache  
- Cache frequent query vectors and top-k results with TTL  
- Reduce compute and Redis load  

### Industry Use Cases & Governance Angles

| Industry       | Use Case                                    | Governance Angle                                                                 |
|----------------|---------------------------------------------|----------------------------------------------------------------------------------|
| **Retail**     | Product Q&A, policy-aware support copilots  | Enforce SKU/region visibility; redact PII; audit who ingested catalogs.           |
| **Banking**    | Knowledge copilots for policies/procedures  | Strict RBAC by business unit; mTLS to Redis; encrypt sensitive metadata.          |
| **Telco**      | Troubleshooting assistants with device manuals | Rate limit ingestion; validate document MIME/types; observability for spike detection. |
| **Manufacturing** | Field service copilots with SOPs          | Versioned embeddings per SOP release; index lifecycle and rollbacks.              |
| **Healthcare** | Care pathway retrieval (de-identified)      | PHI scrubbing pre-embed; access logging; DIM consistency validation jobs.         |


### Notes on embedding dimensions

- text‑embedding‑ada‑002: fixed 1536 dimensions; set embedding_dim accordingly across plugins and index.
- text‑embedding‑3‑small: up to 1536; text‑embedding‑3‑large: up to 3072, often effective at reduced dims for cost.
