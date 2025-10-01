local kong = kong
local cjson = require "cjson.safe"
local http = require "resty.http"

local RagRetriever = {
  PRIORITY = 900,
  VERSION = "0.6",
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

-- Pack floats to binary (little-endian IEEE 754)
local function pack_floats_to_binary(embedding)
  local bytes = {}
  for i = 1, #embedding do
    local num = embedding[i]
    local sign = 0
    if num < 0 then
      sign = 1
      num = -num
    end
    
    local mantissa, exponent = math.frexp(num)
    if mantissa ~= mantissa then
      exponent = 0xFF
      mantissa = 1
    elseif mantissa == math.huge then
      exponent = 0xFF
      mantissa = 0
    elseif mantissa == 0 then
      exponent = 0
      mantissa = 0
    else
      mantissa = (mantissa * 2 - 1) * math.ldexp(0.5, 24)
      exponent = exponent + 126
    end
    
    local b1 = mantissa % 256
    mantissa = math.floor(mantissa / 256)
    local b2 = mantissa % 256
    mantissa = math.floor(mantissa / 256)
    local b3 = mantissa % 128 + (exponent % 2) * 128
    exponent = math.floor(exponent / 2)
    local b4 = exponent % 128 + sign * 128
    
    bytes[#bytes+1] = string.char(b1, b2, b3, b4)
  end
  return table.concat(bytes)
end

-- Build Redis RESP array command
local function build_redis_array(...)
  local args = {...}
  local parts = {"*" .. #args .. "\r\n"}
  
  for i = 1, #args do
    local arg = tostring(args[i])
    parts[#parts+1] = "$" .. #arg .. "\r\n"
    parts[#parts+1] = arg .. "\r\n"
  end
  
  return table.concat(parts)
end

-- Parse Redis RESP response
local function read_redis_response(sock)
  local line, err, partial = sock:receive("*l")
  if not line then
    if partial and #partial > 0 then
      kong.log.err("[rag-retriever] Partial read: ", partial)
    end
    return nil, "read error: " .. tostring(err)
  end
  
  kong.log.debug("[rag-retriever] Redis response line: ", line)
  
  local prefix = line:sub(1, 1)
  local data = line:sub(2)
  
  if prefix == "+" then
    return data
  elseif prefix == "-" then
    return nil, data
  elseif prefix == ":" then
    return tonumber(data)
  elseif prefix == "$" then
    local len = tonumber(data)
    if len == -1 then
      return ngx.null
    end
    local str, str_err = sock:receive(len)
    if not str then
      return nil, "bulk string read error: " .. tostring(str_err)
    end
    sock:receive(2) -- \r\n
    return str
  elseif prefix == "*" then
    local count = tonumber(data)
    if count == -1 then
      return ngx.null
    end
    local arr = {}
    for i = 1, count do
      local val, val_err = read_redis_response(sock)
      if val_err then
        return nil, val_err
      end
      arr[i] = val
    end
    return arr
  else
    return nil, "unknown prefix: " .. prefix
  end
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
    if type(fields) == "table" then
      for j = 1, #fields, 2 do
        entry[fields[j]] = fields[j+1]
      end
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

  -- Redis connect using ngx.socket.tcp (do this first)
  local parsed = parse_redis_url(config.redis_url)
  local sock = ngx.socket.tcp()
  sock:settimeout(5000)

  local ok, conn_err = sock:connect(parsed.host, parsed.port)
  if not ok then
    kong.log.err("[rag-retriever] Redis connect failed: ", conn_err)
    return kong.response.exit(502, { error = "Redis connect failed", detail = conn_err })
  end

  -- SSL handshake if needed
  if parsed.ssl then
    local session, ssl_err = sock:sslhandshake(nil, parsed.host, true)
    if not session then
      kong.log.err("[rag-retriever] Redis SSL handshake failed: ", ssl_err)
      sock:close()
      return kong.response.exit(502, { error = "Redis SSL handshake failed", detail = ssl_err })
    end
  end

  -- Auth if needed
  if parsed.pass and parsed.pass ~= "" then
    sock:send(build_redis_array("AUTH", parsed.user, parsed.pass))
    local auth_res, auth_err = read_redis_response(sock)
    if auth_err then
      kong.log.err("[rag-retriever] Redis AUTH failed: ", auth_err)
      sock:close()
      return kong.response.exit(502, { error = "Redis AUTH failed", detail = auth_err })
    end
  end

  kong.log.info("[rag-retriever] Connected to Redis")

  -- Generate embedding for query (do this after Redis connection)
  local query_vec, dim_or_err = get_embedding(config, query)
  if not query_vec then
    sock:close()
    return kong.response.exit(500, { error = "Embedding generation failed", detail = dim_or_err })
  end
  kong.log.info("[rag-retriever] Embedding generated, dim=", dim_or_err)

  -- Build KNN query
  local knn_query = string.format("*=>[KNN %d @embedding $query_vec AS vector_distance]", top_k)

  -- Build and send FT.SEARCH command
  local search_cmd = build_redis_array(
    "FT.SEARCH",
    config.redis_index,
    knn_query,
    "PARAMS", "2", "query_vec", query_vec,
    "SORTBY", "vector_distance",
    "RETURN", "2", "content", "metadata",
    "DIALECT", "2",
    "LIMIT", "0", tostring(top_k)
  )

  kong.log.debug("[rag-retriever] Sending FT.SEARCH command, length: ", #search_cmd)
  local bytes, send_err = sock:send(search_cmd)
  if not bytes then
    kong.log.err("[rag-retriever] Redis send failed: ", send_err)
    sock:close()
    return kong.response.exit(500, { error = "Redis send failed", detail = send_err })
  end
  
  kong.log.debug("[rag-retriever] Sent ", bytes, " bytes, waiting for response...")

  -- Read response
  local res, rerr = read_redis_response(sock)
  
  if rerr then
    kong.log.err("[rag-retriever] Redis search failed: ", rerr)
    sock:close()
    return kong.response.exit(500, { 
      error = "Redis search failed", 
      detail = tostring(rerr)
    })
  end
  
  if type(res) == "table" and #res > 0 then
    kong.log.info("[rag-retriever] Found ", res[1], " results")
  end

  -- Keep connection alive for reuse
  sock:setkeepalive(10000, 100)

  local parsed_res = parse_redis_results(res)
  return kong.response.exit(200, parsed_res)
end

return RagRetriever