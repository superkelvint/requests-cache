version       = "0.1.0"
author        = "Kelvin Tan"
description   = "A Nim HTTP caching library inspired by Python's requests-cache"
license       = "MIT"

# Dependencies

requires "nim >= 2.2.0"
requires "httpclient"
requires "db_connector"

# Tasks

task test, "Run tests":
  exec "nim c -r tests/test_requests_cache.nim"

task docs, "Generate documentation":
  exec "nim doc --project --out:docs src/requests_cache.nim"