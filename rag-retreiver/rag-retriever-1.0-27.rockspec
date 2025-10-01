package = "rag-retriever"
version = "1.0-27"
source = {
 url = ".",
}
description = {
 summary = "rag-retriever plugin",
 license = "MIT",
}
dependencies = {
 "kong >= 3.6.0",
 "lua >= 5.1"
}
build = {
 type = "builtin",
 modules = {
   ["kong.plugins.rag-retriever.handler"] = "kong/plugins/rag-retriever/handler.lua",
   ["kong.plugins.rag-retriever.schema"] = "kong/plugins/rag-retriever/schema.lua",
 },
}