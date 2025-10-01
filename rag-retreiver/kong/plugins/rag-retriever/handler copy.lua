local kong = kong
local cjson = require "cjson.safe"
local http = require "resty.http"
local redis = require "resty.redis"
local ffi = require "ffi"
local ngx = ngx

local RagRetriever = {
  PRIORITY = 799,
  VERSION = "1.0",
}

-- Parse redis_url into components
local function parse_redis_url(url)
  local scheme, user, pass, host, port =
    url:match("^(redis[s]?)://([^:]+):([^@]+)@([^:]+):?(%d*)$")
  port = tonumber(port) or 6379
  return {
    ssl = (scheme == "rediss"),
    user = user,
    pass = pass,
    host = host,
    port = port
  }
end

-- safe JSON decode
local function safe_decode(raw)
  if not raw or raw == "" then
    return {}
  end
  local ok, obj = pcall(cjson.decode, raw)
  if not ok then
    return nil, "invalid json body"
  end
  return obj
end

-- Convert floats to binary using FFI
local function pack_floats_to_binary(embedding)
  local dim = #embedding
  local buf = ffi.new("float[?]", dim)
  for i = 1, dim do
    buf[i-1] = embedding[i]
  end
  return ffi.string(buf, dim * 4)
end

-- Get embedding from Azure OpenAI
local function get_embedding(query, config)
  local httpc = http.new()
  local url_azure = string.format("%s/openai/deployments/%s/embeddings?api-version=%s",
                                  config.azure_endpoint:gsub("/+$",""),
                                  config.deployment,
                                  config.api_version)

  local res, req_err = httpc:request_uri(url_azure, {
    method = "POST",
    body = cjson.encode({ input = query }),
    headers = {
      ["Content-Type"] = "application/json",
      ["api-key"] = config.azure_api_key,
    },
    ssl_verify = true,
  })

  if not res or res.status ~= 200 then
    return nil, "Azure embedding failed: " .. (req_err or (res and res.body) or "no response")
  end

  local payload = cjson.decode(res.body)
  return payload.data[1].embedding, nil
end

-- Connect to Redis
local function connect_redis(config)
  local red = redis:new()
  red:set_timeout(5000)
  local parsed = parse_redis_url(config.redis_url)
  
  local ok, conn_err = red:connect(parsed.host, parsed.port)
  if not ok then
    return nil, "Redis connect failed: " .. conn_err
  end
  
  if parsed.ssl then
    local ok, ssl_err = red:sslhandshake(false, parsed.host, true)
    if not ok then
      return nil, "Redis SSL handshake failed: " .. ssl_err
    end
  end
  
  if parsed.pass and parsed.pass ~= "" then
    local ok, auth_err = red:auth(parsed.user, parsed.pass)
    if not ok then
      return nil, "Redis AUTH failed: " .. auth_err
    end
  end
  
  return red, nil
end

-- Search similar documents using Redis vector search
local function search_similar_docs(red, config, query_embedding_blob, top_k)
  kong.log.info("[rag-retriever] Searching for similar documents, top_k=", top_k)
  
  -- Use FT.SEARCH with vector similarity
  local search_res, search_err = red:command(
    "FT.SEARCH",
    config.redis_index,
    "*=>[KNN " .. tostring(top_k) .. " @embedding $query_vec AS score]",
    "PARAMS", "2", "query_vec", query_embedding_blob,
    "SORTBY", "score",
    "RETURN", "3", "content", "metadata", "score",
    "DIALECT", "2"
  )
  
  if not search_res then
    return nil, "Redis search failed: " .. tostring(search_err)
  end
  
  -- Parse results
  local results = {}
  local num_results = search_res[1] or 0
  
  kong.log.info("[rag-retriever] Found ", num_results, " results")
  
  -- Results are returned as: [count, key1, fields1, key2, fields2, ...]
  for i = 2, #search_res, 2 do
    local key = search_res[i]
    local fields = search_res[i + 1]
    
    local result = {
      key = key,
      content = nil,
      metadata = nil,
      score = nil
    }
    
    -- Parse fields array
    for j = 1, #fields, 2 do
      local field_name = fields[j]
      local field_value = fields[j + 1]
      
      if field_name == "content" then
        result.content = field_value
      elseif field_name == "metadata" then
        result.metadata = cjson.decode(field_value)
      elseif field_name == "score" then
        result.score = tonumber(field_value)
      end
    end
    
    results[#results + 1] = result
  end
  
  return results, nil
end

function RagRetriever:access(config)
  kong.log.info("[rag-retriever] === access start ===")

  local raw = kong.request.get_raw_body()
  local body, err = safe_decode(raw)
  if not body then
    return kong.response.exit(400, { error = "Invalid JSON body", detail = err })
  end

  local query = body.query or body.question
  if not query then
    return kong.response.exit(400, { error = "Missing query or question" })
  end

  kong.log.info("[rag-retriever] Query: ", query)

  -- Get embedding for query
  kong.log.debug("[rag-retriever] Getting query embedding...")
  local query_embedding, emb_err = get_embedding(query, config)
  if not query_embedding then
    kong.log.err("[rag-retriever] Failed to get embedding: ", emb_err)
    return kong.response.exit(502, { error = "Failed to get query embedding", detail = emb_err })
  end

  kong.log.debug("[rag-retriever] Query embedding dimensions: ", #query_embedding)

  -- Pack embedding to binary
  local ok_pack, query_blob = pcall(pack_floats_to_binary, query_embedding)
  if not ok_pack then
    return kong.response.exit(500, { error = "Failed to pack embedding", detail = tostring(query_blob) })
  end

  -- Connect to Redis
  local red, redis_err = connect_redis(config)
  if not red then
    return kong.response.exit(502, { error = "Redis connection failed", detail = redis_err })
  end

  -- Search for similar documents
  local top_k = body.top_k or config.top_k or 5
  local results, search_err = search_similar_docs(red, config, query_blob, top_k)
  
  red:set_keepalive(10000, 100)
  
  if not results then
    kong.log.err("[rag-retriever] Search failed: ", search_err)
    return kong.response.exit(500, { error = "Search failed", detail = search_err })
  end

  -- Filter by similarity threshold if configured
  local filtered_results = {}
  local threshold = config.similarity_threshold or 0
  
  for _, result in ipairs(results) do
    -- Note: Redis returns distance, lower is better for COSINE
    -- Convert to similarity score (1 - distance) for intuitive threshold
    local similarity = 1 - (result.score or 0)
    
    if similarity >= threshold then
      filtered_results[#filtered_results + 1] = {
        content = result.content,
        metadata = result.metadata,
        similarity = similarity,
        distance = result.score
      }
    end
  end

  kong.log.info("[rag-retriever] === Returning ", #filtered_results, " results ===")
  
  return kong.response.exit(200, {
    query = query,
    results = filtered_results,
    total_found = #results,
    returned = #filtered_results
  })
end

return RagRetriever