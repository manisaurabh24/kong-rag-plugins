#!/usr/bin/env lua

-- Minimal Redis Vector Search POC (only requires lua-cjson and luasocket)
-- Install: luarocks install lua-cjson luasocket

local cjson = require "cjson.safe"
local socket = require "socket"

-- Configuration (UPDATE THESE!)
local CONFIG = {
  redis_host = "redis-xx.crce206.ap-south-1-1.ec2.redns.redis-cloud.com",
  redis_port = xx,
  redis_password = "xx",  -- set if needed
  redis_index = "hr_mitr_index",
  
  azure_endpoint = "https://xx.openai.azure.com",
  deployment = "BTG_text-embedding-ada-002",
  api_version = "2025-01-01-preview",
  azure_api_key = "xx",
  
  query = "What is backpressure?",
  top_k = 3
}

-- Pack floats to binary (little-endian IEEE 754)
local function pack_floats(embedding)
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

-- Get embedding using curl (avoids SSL library issues)
local function get_embedding(text)
  print("[INFO] Getting embedding for: " .. text)
  
  local url = string.format("%s/openai/deployments/%s/embeddings?api-version=%s",
    CONFIG.azure_endpoint:gsub("/+$", ""),
    CONFIG.deployment,
    CONFIG.api_version)
  
  local request_body = cjson.encode({ input = text })
  local temp_file = os.tmpname()
  
  -- Use curl to make HTTPS request
  local curl_cmd = string.format(
    "curl -s -X POST '%s' -H 'Content-Type: application/json' -H 'api-key: %s' -d '%s' -o %s",
    url,
    CONFIG.azure_api_key,
    request_body:gsub("'", "'\\''"),
    temp_file
  )
  
  local result = os.execute(curl_cmd)
  if result ~= 0 and result ~= true then
    os.remove(temp_file)
    error("curl command failed")
  end
  
  -- Read response
  local file = io.open(temp_file, "r")
  local response = file:read("*all")
  file:close()
  os.remove(temp_file)
  
  local payload = cjson.decode(response)
  if not payload or not payload.data or not payload.data[1] then
    error("Invalid Azure API response: " .. response)
  end
  
  local embedding = payload.data[1].embedding
  print("[INFO] Embedding dimension: " .. #embedding)
  
  return pack_floats(embedding)
end

-- Redis protocol builder
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
  local line, err = sock:receive("*l")
  if not line then
    return nil, "read error: " .. tostring(err)
  end
  
  local prefix = line:sub(1, 1)
  local data = line:sub(2)
  
  if prefix == "+" then
    -- Simple string
    return data
  elseif prefix == "-" then
    -- Error
    return nil, data
  elseif prefix == ":" then
    -- Integer
    return tonumber(data)
  elseif prefix == "$" then
    -- Bulk string
    local len = tonumber(data)
    if len == -1 then
      return nil
    end
    local str = sock:receive(len)
    sock:receive(2) -- \r\n
    return str
  elseif prefix == "*" then
    -- Array
    local count = tonumber(data)
    if count == -1 then
      return nil
    end
    local arr = {}
    for i = 1, count do
      local val, err = read_redis_response(sock)
      if err then
        return nil, err
      end
      arr[i] = val
    end
    return arr
  else
    return nil, "unknown prefix: " .. prefix
  end
end

-- Connect to Redis
local function connect_redis()
  print("[INFO] Connecting to Redis " .. CONFIG.redis_host .. ":" .. CONFIG.redis_port)
  
  local sock = socket.tcp()
  sock:settimeout(10)
  
  local ok, err = sock:connect(CONFIG.redis_host, CONFIG.redis_port)
  if not ok then
    error("Redis connect failed: " .. tostring(err))
  end
  
  -- Auth if needed
  if CONFIG.redis_password then
    sock:send(build_redis_array("AUTH", CONFIG.redis_password))
    local res, err = read_redis_response(sock)
    if err then
      sock:close()
      error("Redis AUTH failed: " .. err)
    end
  end
  
  print("[INFO] Connected to Redis")
  return sock
end

-- Parse FT.SEARCH results
local function parse_results(res)
  if type(res) ~= "table" then
    return { total = 0, docs = {} }
  end
  
  local results = {}
  local total = tonumber(res[1]) or 0
  
  print("[INFO] Total results: " .. total)
  
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

-- Main execution
local function main()
  print("=== Redis Vector Search POC ===\n")
  
  -- Get embedding
  local query_vec = get_embedding(CONFIG.query)
  print("[INFO] Binary vector length: " .. #query_vec .. " bytes")
  
  -- Connect to Redis
  local sock = connect_redis()
  
  -- Test basic command
  print("\n[DEBUG] Testing PING...")
  sock:send(build_redis_array("PING"))
  local ping_res, ping_err = read_redis_response(sock)
  if ping_err then
    print("[ERROR] PING failed: " .. ping_err)
    sock:close()
    return
  end
  print("[DEBUG] PING response: " .. tostring(ping_res))
  
  -- Check if index exists
  print("\n[DEBUG] Checking index...")
  sock:send(build_redis_array("FT._LIST"))
  local list_res, list_err = read_redis_response(sock)
  if list_err then
    print("[ERROR] FT._LIST failed: " .. list_err)
  else
    print("[DEBUG] Available indices:")
    if type(list_res) == "table" then
      for i, idx in ipairs(list_res) do
        print("  - " .. idx)
      end
    end
  end
  
  -- Build and execute FT.SEARCH
  local knn_query = string.format("*=>[KNN %d @embedding $query_vec AS vector_distance]", 
    CONFIG.top_k)
  
  print("\n[INFO] Executing FT.SEARCH...")
  print("[INFO] Index: " .. CONFIG.redis_index)
  print("[INFO] Query: " .. knn_query)
  
  local search_cmd = build_redis_array(
    "FT.SEARCH",
    CONFIG.redis_index,
    knn_query,
    "PARAMS", "2", "query_vec", query_vec,
    "SORTBY", "vector_distance",
    "RETURN", "2", "content", "metadata",
    "DIALECT", "2",
    "LIMIT", "0", tostring(CONFIG.top_k)
  )
  
  sock:send(search_cmd)
  local res, err = read_redis_response(sock)
  
  if err then
    print("[ERROR] FT.SEARCH failed: " .. err)
    sock:close()
    return
  end
  
  -- Parse and display results
  local parsed = parse_results(res)
  
  print("\n=== RESULTS ===")
  print("Total matches: " .. parsed.total)
  print("\nDocuments:")
  
  if #parsed.docs == 0 then
    print("  (no results found)")
  else
    for i, doc in ipairs(parsed.docs) do
      print("\n" .. i .. ". ID: " .. doc.id)
      if doc.content then
        local content_preview = doc.content:sub(1, 100)
        if #doc.content > 100 then content_preview = content_preview .. "..." end
        print("   Content: " .. content_preview)
      end
      if doc.metadata then
        print("   Metadata: " .. doc.metadata)
      end
      if doc.vector_distance then
        print("   Distance: " .. doc.vector_distance)
      end
    end
  end
  
  sock:close()
  print("\n=== POC Complete ===")
end

-- Run with error handling
local status, err = pcall(main)
if not status then
  print("\n[FATAL ERROR] " .. tostring(err))
  print("\n[TROUBLESHOOTING TIPS]")
  print("1. Verify Redis is running: redis-cli ping")
  print("2. Check if index exists: redis-cli FT._LIST")
  print("3. Verify index schema: redis-cli FT.INFO " .. CONFIG.redis_index)
  print("4. Verify Azure OpenAI credentials")
  print("5. Make sure curl is installed")
  os.exit(1)
end