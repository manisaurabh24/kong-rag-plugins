local typedefs = require "kong.db.schema.typedefs"

return {
  name = "doc-embedder",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- Redis
          { redis_url     = { type = "string", required = true } },   -- full URL: redis:// or rediss://
          { redis_index   = { type = "string", required = true } },
          { redis_prefix  = { type = "string", default = "doc:" } },

          -- Azure OpenAI
          { azure_endpoint = { type = "string", required = true } },
          { azure_api_key  = { type = "string", required = true, encrypted = true } },
          { deployment     = { type = "string", required = true } },
          { api_version    = { type = "string", default = "2025-01-01-preview" } },

          -- Chunking + Embeddings
          { chunk_size     = { type = "number", default = 1000 } },
          { chunk_overlap  = { type = "number", default = 50 } },
          { embedding_dim  = { type = "number", default = 1536 } },
          { max_chunks     = { type = "number", default = 200 } },
        },
      },
    },
  },
}
