local kong = kong
local cjson = require "cjson.safe"
local http = require "resty.http"
local redis = require "resty.redis"
local ffi = require "ffi"

local RagRetriever = {
  PRIORITY = 900,
  VERSION = "0.5",
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

-- Helper to build raw Redis protocol
local function build_redis_command(cmd, ...)
  local args = {...}
  local lines = {}
  
  -- Array length
  lines[#lines + 1] = "*" .. tostring(#args + 1) .. "\r\n"
  
  -- Command
  lines[#lines + 1] = "$" .. #cmd .. "\r\n"
  lines[#lines + 1] = cmd .. "\r\n"
  
  -- Arguments
  for i = 1, #args do
    local arg = args[i]
    lines[#lines + 1] = "$" .. #arg .. "\r\n"
    lines[#lines + 1] = arg .. "\r\n"
  end
  
  return table.concat(lines)
end
local function pack_floats_to_binary(embedding)
  local dim = #embedding
  local buf = ffi.new("float[?]", dim)
  for i = 1, dim do
    buf[i-1] = embedding[i]
  end
  return ffi.string(buf, dim * 4)
end

-- Call Azure OpenAI to get embeddings
local function get_embedding(config, text)
  local httpc = http.new()
  local url_azure = string.format("%s/openai/deployments/%s/embeddings?api-version=%s",
                                  config.azure_endpoint:gsub("/+$",""),
                                  config.deployment,
                                  config.api_version)

  kong.log.debug("[rag-retriever] Azure URL: ", url_azure)

  local res, err = httpc:request_uri(url_azure, {
    method = "POST",
    body = cjson.encode({ input = text }),
    headers = {
      ["Content-Type"] = "application/json",
      ["api-key"] = config.azure_api_key,
    },
    ssl_verify = true,
  })

  if not res or res.status ~= 200 then
    kong.log.err("[rag-retriever] Azure embedding request failed: ", err or (res and res.body))
    return nil, "Azure embedding request failed"
  end

  local payload = cjson.decode(res.body)
  if not payload or not payload.data or not payload.data[1] then
    return nil, "Azure embedding response malformed"
  end

  local embedding = payload.data[1].embedding
  return pack_floats_to_binary(embedding), #embedding
end

-- Transform Redis FT.SEARCH response into structured objects
local function parse_redis_results(res)
  local results = {}
  local total = tonumber(res[1]) or 0

  for i = 2, #res, 2 do
    local doc_id = res[i]
    local fields = res[i+1]

    local entry = { id = doc_id }
    for j = 1, #fields, 2 do
      entry[fields[j]] = fields[j+1]
    end

    table.insert(results, entry)
  end

  return { total = total, docs = results }
end

function RagRetriever:access(config)
  kong.log.info("[rag-retriever] === access start ===")

  -- Parse request
  local raw = kong.request.get_raw_body()
  local body, err = cjson.decode(raw or "")
  if not body then
    return kong.response.exit(400, { error = "Invalid JSON body" })
  end

  local query = body.query
  local top_k = body.top_k or 3
  if not query then
    return kong.response.exit(400, { error = "Missing query text" })
  end

  kong.log.info("[rag-retriever] Query: ", query)

  -- Redis connect
  local red = redis:new()
  red:set_timeout(5000)
  local parsed = parse_redis_url(config.redis_url)

  local ok, conn_err = red:connect(parsed.host, parsed.port)
  if not ok then
    kong.log.err("[rag-retriever] Redis connect failed: ", conn_err)
    return kong.response.exit(502, { error = "Redis connect failed", detail = conn_err })
  end

  if parsed.ssl then
    local ok, ssl_err = red:sslhandshake(false, parsed.host, true)
    if not ok then
      kong.log.err("[rag-retriever] Redis SSL handshake failed: ", ssl_err)
      return kong.response.exit(502, { error = "Redis SSL handshake failed", detail = ssl_err })
    end
  end

  if parsed.pass and parsed.pass ~= "" then
    local ok, auth_err = red:auth(parsed.user, parsed.pass)
    if not ok then
      kong.log.err("[rag-retriever] Redis AUTH failed: ", auth_err)
      return kong.response.exit(502, { error = "Redis AUTH failed", detail = auth_err })
    end
  end

  kong.log.info("[rag-retriever] Connected to Redis")

  -- Generate embedding for query
  local query_vec, dim_or_err = get_embedding(config, query)
  if not query_vec then
    return kong.response.exit(500, { error = "Embedding generation failed", detail = dim_or_err })
  end
  kong.log.info("[rag-retriever] Embedding generated, dim=", dim_or_err)

  -- Build KNN query
  local knn_query = string.format("*=>[KNN %d @embedding $query_vec AS vector_distance]", top_k)

  -- Directly add the method to the redis instance
  function red:ft_search(...)
    local args = {...}
    local req = {"*" .. tostring(#args + 1) .. "\r\n"}
    req[#req + 1] = "$9\r\nFT.SEARCH\r\n"
    
    for i = 1, #args do
      local arg = args[i]
      req[#req + 1] = "$" .. #arg .. "\r\n"
      req[#req + 1] = arg .. "\r\n"
    end
    
    local sock = self._sock
    local bytes, err = sock:send(table.concat(req))
    if not bytes then
      return nil, err
    end
    
    return self:read_reply()
  end

  -- Call our custom FT.SEARCH method
  local res, rerr = red:ft_search(
    config.redis_index,
    knn_query,
    "PARAMS", "2", "query_vec", query_vec,
    "SORTBY", "vector_distance",
    "RETURN", "2", "content", "metadata",
    "DIALECT", "2"
  )
  
  kong.log.info("[rag-retriever] FT.SEARCH result type: ", type(res))

    
  if not res then
    kong.log.err("[rag-retriever] Redis search failed: ", rerr)
    red:set_keepalive(10000, 100)
    return kong.response.exit(500, { 
      error = "Redis search failed", 
      detail = tostring(rerr)
    })
  end
  
  if type(res) == "table" and #res > 0 then
    kong.log.info("[rag-retriever] Found ", res[1], " results")
  end

  red:set_keepalive(10000, 100)

  local parsed_res = parse_redis_results(res)
  return kong.response.exit(200, parsed_res)
end

return RagRetriever