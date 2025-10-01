local kong = kong
local cjson = require "cjson.safe"
local http = require "resty.http"
local redis = require "resty.redis"
local uuid = require "resty.jit-uuid"
local ffi = require "ffi"
local ngx = ngx

local DocEmbedder = {
  PRIORITY = 800,
  VERSION = "0.9",
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

-- Simple chunker (ultra-minimal to avoid any table issues)
local function chunk_text(text, chunk_size, overlap, max_chunks)
  local len = #text
  kong.log.info("[doc-embedder] chunk_text called: len=", len, " chunk_size=", chunk_size)
  
  -- For small documents, return as single chunk
  if len <= chunk_size then
    kong.log.info("[doc-embedder] Single chunk mode")
    return {text}
  end
  
  -- Build chunks array with explicit indices
  local result = {}
  local idx = 0
  local pos = 1
  
  while pos <= len and idx < max_chunks do
    local endpos = pos + chunk_size - 1
    if endpos > len then
      endpos = len
    end
    
    idx = idx + 1
    result[idx] = string.sub(text, pos, endpos)
    pos = endpos - overlap + 1
    
    if idx % 10 == 0 then
      kong.log.debug("[doc-embedder] Created ", idx, " chunks so far")
    end
  end
  
  kong.log.info("[doc-embedder] Total chunks created: ", idx)
  return result
end

-- Convert floats to binary using FFI (most efficient)
local function pack_floats_to_binary(embedding)
  local dim = #embedding
  local buf = ffi.new("float[?]", dim)
  for i = 1, dim do
    buf[i-1] = embedding[i]
  end
  return ffi.string(buf, dim * 4)
end

-- Ensure Redis index (skip creation, assume index exists or will be created manually)
local function ensure_redis_index(red, index_name, prefix, dim)
  kong.log.info("[doc-embedder] Skipping Redis index check (assume index exists)")
  -- Skip index creation - assume it's already created manually or not needed
  -- This avoids issues with Redis instances that don't support FT.CREATE command syntax
  return true, nil
end

function DocEmbedder:access(config)
  kong.log.info("[doc-embedder] === access start ===")

  local raw = kong.request.get_raw_body()
  kong.log.info("[doc-embedder] Raw body length: ", raw and #raw or 0)
  
  local body, err = safe_decode(raw)
  if not body then
    return kong.response.exit(400, { error = "Invalid JSON body", detail = err })
  end

  -- Redis connection setup
  kong.log.debug("[doc-embedder] Connecting to Redis...")
  local red = redis:new()
  red:set_timeout(5000)
  local parsed = parse_redis_url(config.redis_url)
  
  local ok, conn_err = red:connect(parsed.host, parsed.port)
  if not ok then
    kong.log.err("[doc-embedder] Redis connect failed: ", conn_err)
    return kong.response.exit(502, { error = "Redis connect failed", detail = conn_err })
  end
  
  kong.log.debug("[doc-embedder] Connected to Redis: ", parsed.host, ":", parsed.port)
  
  if parsed.ssl then
    kong.log.debug("[doc-embedder] Performing SSL handshake...")
    local ok, ssl_err = red:sslhandshake(false, parsed.host, true)
    if not ok then
      kong.log.err("[doc-embedder] SSL handshake failed: ", ssl_err)
      return kong.response.exit(502, { error = "Redis SSL handshake failed", detail = ssl_err })
    end
  end
  
  if parsed.pass and parsed.pass ~= "" then
    kong.log.debug("[doc-embedder] Authenticating to Redis...")
    local ok, auth_err = red:auth(parsed.user, parsed.pass)
    if not ok then
      kong.log.err("[doc-embedder] Redis auth failed: ", auth_err)
      return kong.response.exit(502, { error = "Redis AUTH failed", detail = auth_err })
    end
  end

  -- Test mode
  if body.redis_test then
    kong.log.info("[doc-embedder] Redis test mode")
    local pong, ping_err = red:ping()
    red:set_keepalive(10000, 100)
    if pong ~= "PONG" then
      return kong.response.exit(502, { error = "Redis PING failed", detail = ping_err })
    end
    return kong.response.exit(200, { status = "ok", redis = "PONG" })
  end

  local document = body.document
  local metadata = body.metadata or {}
  if not document then
    return kong.response.exit(400, { error = "Missing document" })
  end

  kong.log.info("[doc-embedder] Document length: ", #document)
  
  -- Create chunks with error handling
  local ok_chunk, chunks = pcall(chunk_text, document, config.chunk_size, config.chunk_overlap, config.max_chunks)
  if not ok_chunk then
    kong.log.err("[doc-embedder] Chunking failed: ", chunks)
    return kong.response.exit(500, { error = "Chunking failed", detail = tostring(chunks) })
  end
  
  local num_chunks = #chunks
  kong.log.info("[doc-embedder] Number of chunks: ", num_chunks)
  
  if num_chunks > config.max_chunks then
    return kong.response.exit(413, { 
      error = "Document too large", 
      chunks = num_chunks,
      max_chunks = config.max_chunks 
    })
  end

  -- Ensure index
  local ok_idx, idx_err = ensure_redis_index(red, config.redis_index, config.redis_prefix, config.embedding_dim)
  if not ok_idx then
    kong.log.err("[doc-embedder] Redis index error: ", idx_err)
    return kong.response.exit(500, { error = "Redis index error", detail = idx_err })
  end

  -- Azure embedding
  kong.log.debug("[doc-embedder] Preparing Azure OpenAI request...")
  local httpc = http.new()
  local url_azure = string.format("%s/openai/deployments/%s/embeddings?api-version=%s",
                                  config.azure_endpoint:gsub("/+$",""),
                                  config.deployment,
                                  config.api_version)
  
  kong.log.debug("[doc-embedder] Azure URL: ", url_azure)

  -- Process chunks one at a time and store IDs with explicit indexing
  local stored_ids = {}
  local stored_count = 0
  
  for i = 1, num_chunks do
    local chunk = chunks[i]
    kong.log.info("[doc-embedder] Processing chunk ", i, "/", num_chunks, " (length: ", #chunk, ")")
    
    local res, req_err = httpc:request_uri(url_azure, {
      method = "POST",
      body = cjson.encode({ input = chunk }),
      headers = {
        ["Content-Type"] = "application/json",
        ["api-key"] = config.azure_api_key,
      },
      ssl_verify = true,
    })
    
    if not res or res.status ~= 200 then
      kong.log.err("[doc-embedder] Azure API failed for chunk ", i, ": ", req_err or (res and res.body))
      return kong.response.exit(502, { 
        error = "Azure embeddings failed", 
        detail = req_err or (res and res.body) or "no response",
        chunk_number = i
      })
    end
    
    local payload = cjson.decode(res.body)
    local embedding = payload.data[1].embedding
    
    kong.log.debug("[doc-embedder] Received embedding with ", #embedding, " dimensions")
    
    if #embedding ~= config.embedding_dim then
      kong.log.warn(string.format("[doc-embedder] Dimension mismatch: expected %d, got %d", 
        config.embedding_dim, #embedding))
    end
    
    -- Pack embedding
    local ok_pack, embedding_blob = pcall(pack_floats_to_binary, embedding)
    if not ok_pack then
      kong.log.err("[doc-embedder] Failed to pack embedding: ", embedding_blob)
      return kong.response.exit(500, { 
        error = "Failed to encode embedding", 
        detail = tostring(embedding_blob),
        chunk_number = i
      })
    end
    
    kong.log.debug("[doc-embedder] Packed embedding to ", #embedding_blob, " bytes")

    local doc_id = uuid.generate_v4()
    local key = config.redis_prefix .. doc_id
    
    kong.log.debug("[doc-embedder] Storing to Redis key: ", key)
    
    local ok_hmset, hmset_err = red:hmset(key,
      "content", chunk,
      "metadata", cjson.encode(metadata),
      "embedding", embedding_blob
    )
    
    if not ok_hmset then
      kong.log.err("[doc-embedder] Redis HMSET failed: ", hmset_err)
      return kong.response.exit(500, { 
        error = "Failed to store document", 
        detail = tostring(hmset_err),
        chunk_number = i
      })
    end
    
    kong.log.debug("[doc-embedder] Successfully stored chunk ", i, " with ID: ", doc_id)
    
    stored_count = stored_count + 1
    stored_ids[stored_count] = doc_id
  end

  red:set_keepalive(10000, 100)
  
  kong.log.info("[doc-embedder] === Processing complete: ", stored_count, " chunks stored ===")
  return kong.response.exit(200, { 
    message = "Document processed", 
    chunks = num_chunks, 
    stored_ids = stored_ids 
  })
end

return DocEmbedder