version       = "0.2.0"
author        = "Kelvin Tan"
description   = "A Nim HTTP caching library inspired by Python's requests-cache"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["tests"]

# Dependencies

requires "nim >= 2.2.0"
requires "db_connector"
requires "malebolgia >= 1.3.0"

# Tasks

task test, "Run tests":
  exec "nim c --path:src -r tests/test_requests_cache.nim"

task docs, "Generate documentation":
  exec "nim doc --project --out:docs src/requests_cache.nim"