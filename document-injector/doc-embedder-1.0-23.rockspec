package = "doc-embedder"
version = "1.0-23"
source = {
 url = ".",
}
description = {
 summary = "doc-embedder plugin",
 license = "MIT",
}
dependencies = {
 "kong >= 3.6.0",
 "lua >= 5.1"
}
build = {
 type = "builtin",
 modules = {
   ["kong.plugins.doc-embedder.handler"] = "kong/plugins/doc-embedder/handler.lua",
   ["kong.plugins.doc-embedder.schema"] = "kong/plugins/doc-embedder/schema.lua",
 },
}