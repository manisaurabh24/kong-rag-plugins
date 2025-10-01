local typedefs = require "kong.db.schema.typedefs"

return {
  name = "rag-retriever",
  fields = {
    {
      config = {
        type = "record",
        fields = {
          {
            azure_endpoint = {
              type = "string",
              required = true,
              description = "Azure OpenAI endpoint URL"
            }
          },
          {
            deployment = {
              type = "string",
              required = true,
              description = "Azure OpenAI deployment name for embeddings"
            }
          },
          {
            api_version = {
              type = "string",
              required = true,
              default = "2023-05-15",
              description = "Azure OpenAI API version"
            }
          },
          {
            azure_api_key = {
              type = "string",
              required = true,
              encrypted = true,
              referenceable = true,
              description = "Azure OpenAI API key"
            }
          },
          {
            redis_url = {
              type = "string",
              required = true,
              description = "Redis connection URL (rediss://user:pass@host:port)"
            }
          },
          {
            redis_index = {
              type = "string",
              required = true,
              default = "doc_embeddings_idx",
              description = "Redis search index name"
            }
          },
          {
            redis_prefix = {
              type = "string",
              required = true,
              default = "doc:",
              description = "Redis key prefix for documents"
            }
          },
          {
            embedding_dim = {
              type = "number",
              required = true,
              default = 1536,
              description = "Embedding vector dimensions"
            }
          },
          {
            top_k = {
              type = "number",
              required = false,
              default = 5,
              description = "Number of top results to return"
            }
          },
          {
            similarity_threshold = {
              type = "number",
              required = false,
              default = 0.7,
              description = "Minimum similarity score (0-1) to include results"
            }
          }
        }
      }
    }
  }
}