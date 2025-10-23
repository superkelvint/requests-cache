# requests_cache



A Nim HTTP caching library inspired by Python's [requests-cache](https://requests-cache.readthedocs.io/).

**requests_cache** provides intelligent caching for HTTP requests. It offers two session types: a simple **`SingleThreadedSession`** for easy, everyday use, and a high-performance, thread-safe **`CachedSession`** for advanced concurrent applications.



## Features



- **Thread-Safe by Design**: Choose between a simple, self-locking wrapper (`SingleThreadedSession`) or a manually-locked core (`CachedSession`) for maximum performance.
- **Persistent Caching**: Responses cached in a SQLite database.
- **Configurable Expiration**: Set custom TTLs for cached responses.
- **Smart Filtering**: URL filters and status code allowlists.
- **Cookie Management**: Automatic cookie persistence and sending.
- **Stale-If-Error**: Fallback to stale responses on request failures.
- **Cache Statistics**: Track hits, misses, and cache size.
- **Context Managers**: Temporarily enable/disable caching.
- **Cache Inspection**: Query and analyze cached entries.



## Installation





### Via Nimble

```bash
nimble install https://github.com/superkelvint/requests_cache
```



### Manual

Clone this repository and add it to your Nim path:

```bash
git clone https://github.com/superkelvint/requests_cache.git
cd requests_cache
nimble install
```



## Quick Start

The easiest way to get started is with `SingleThreadedSession`. It manages its own lock, so you don't have to worry about thread safety.


```nim
import requests_cache

# 1. Use the simple, single-threaded session
var session = newSingleThreadedSession(
  dbPath = "cache.db",
  expireAfter = 3600  # Cache for 1 hour
)

# 2. Make requests (no locks needed)
let response = session.get("https://api.example.com/data")
echo response

# 3. Check stats (no locks needed)
let stats = session.cacheStats()
echo "Hits: ", stats.hits, " Misses: ", stats.misses
```



## Usage Guide (SingleThreadedSession)



All examples below use the recommended `SingleThreadedSession`.



### Basic Requests


```nim
var session = newSingleThreadedSession()

# GET request
let data = session.get("https://api.example.com/users")

# GET with query parameters
let params = {"user_id": "123", "limit": "10"}.toTable
let filtered = session.get("https://api.example.com/users", params = params)

# POST request (must be enabled in settings)
session.settings.allowableMethods.incl("POST")
let created = session.post("https://api.example.com/users", data = """{"name": "Alice"}""")

# HEAD request
let headers = session.head("https://api.example.com/check")
```



### Configuration

You can configure the session on creation or by modifying the `.settings` object.


```nim
import std/sets

var session = newSingleThreadedSession(
  dbPath = "my_cache.db",
  expireAfter = 7200,                              # Cache for 2 hours
  allowableMethods = toHashSet(["GET", "HEAD"]),   # Only cache these methods
  allowableStatusCodes = toHashSet([200, 304]),    # Only cache these status codes
  staleIfError = true                              # Return stale data on network errors
)

# Add a URL filter after creation
session.settings.urlFilter = proc(url: string): bool =
  not url.contains("private")  # Don't cache URLs containing "private"
```



### Cookie Management

Cookies are automatically loaded on creation and persisted after requests.


```nim
var session = newSingleThreadedSession()

# Set a cookie
session.setCookie("user_session", "abc123xyz")

# Get a cookie
let token = session.getCookie("user_session")
if token.isSome:
  echo "Token: ", token.get()

# Clear all cookies
session.clearCookies()

# A new session will automatically load persisted cookies
var session2 = newSingleThreadedSession()
echo session2.getCookie("user_session").get() # "abc123xyz"
```



### Cache Control

```nim
var session = newSingleThreadedSession()

# Temporarily disable caching
session.cacheDisabled:
  let freshData = session.get("https://api.example.com/status")

# Temporarily enable caching (if you've set session.session.cacheEnabled = false)
session.cacheEnabled:
  let cached = session.get("https://api.example.com/data")

# Clear all cached entries
session.clearCache()

# Remove only expired entries
let removed = session.clearExpired()
echo "Removed ", removed, " expired entries"
```

### Cache Inspection

```nim
var session = newSingleThreadedSession()
# ... make some requests ...

# Get all cached URLs
let urls = session.getCachedUrls()
for url in urls:
  echo url

# Get details about a specific cache entry
let entry = session.getCacheEntry("https://api.example.com/data")
if entry.isSome:
  echo "Status: ", entry.get().statusCode
  echo "Hits: ", entry.get().hits
  echo "Created at: ", entry.get().createdAt

# Search cache by URL pattern
let results = session.searchCache("%.example.com%")
for result in results:
  echo result.url, " - Status: ", result.statusCode

# Get cache statistics
let stats = session.cacheStats()
echo "Size: ", stats.size
echo "Hits: ", stats.hits
echo "Misses: ", stats.misses
```


## Multi-Threading / Advanced Usage

For high-performance applications where you need to share **one session** across **multiple threads**, you must use the core `CachedSession` type.

This type is more complex because it requires you to **manually create and pass a lock** to *every* procedure. This manual control is what allows it to be safely shared.


```nim
import httpclient
import malebolgia
import malebolgia/ticketlocks
import requests_cache
import std/sets

proc fetchUrl(url: string; session: ptr CachedSession; lock: ptr TicketLock) {.gcsafe.} =
  {.cast(gcsafe).}:
    try:
      echo "Fetching: ", url
      let response = session[].get(url, lock)
      echo "  > Got: ", response.len, " bytes"
    except Exception as e:
      echo "Request failed: ", e.msg

proc main() =
  var session = newCachedSession(
    dbPath = "cache.db",
    expireAfter = 3600,
  )
  var lock = ticketlocks.initTicketLock() 

  session.loadCookies(addr lock)

  let urls = [
    "https://httpbin.org/delay/1",
    "https://httpbin.org/delay/1",
    "https://httpbin.org/delay/1",
  ]

  var m = malebolgia.createMaster()

  echo "--- Spawning 100 tasks... ---"
  m.awaitAll:
    for i in 0..<100:
      let url = urls[i mod urls.len]
      m.spawn fetchUrl(url, addr session, addr lock)
  echo "--- All tasks complete. ---"

  let stats = session.cacheStats(addr lock)
  echo "\n=== CACHE STATISTICS ==="
  echo "Total requests spawned: 100"
  echo "Cache hits: ", stats.hits, " (served from cache)"
  echo "Cache misses: ", stats.misses, " (fetched from server)"
  echo "Cache size: ", stats.size, " (unique URLs cached)"

main()
```

**Rule of thumb:** Use `SingleThreadedSession` unless you have a specific reason to share one session instance across many threads.



## API Reference

This library provides two main session objects.



### 1. `SingleThreadedSession` (Recommended)

The simple, self-locking wrapper. It owns its own lock.

- `newSingleThreadedSession()`: Creates a new session.
- `session.get(url)`
- `session.post(url, data)`
- `session.cacheStats()`
- `session.clearCache()`
- ...and so on for all other methods.



### 2. `CachedSession` (Multi-Threaded / Core)

The high-performance core type. It requires an external `TicketLock` to be passed to **every** call.

- `newCachedSession()`: Creates the core session.
- `session.get(url, addr myLock)`
- `session.post(url, addr myLock, data)`
- `session.cacheStats(addr myLock)`
- `session.clearCache(addr myLock)`
- ...and so on for all other methods.



### Shared API

Both session types provide the same set of methods. The only difference is the `lock` parameter.

- **HTTP Methods**: `get`, `post`, `head`, `request`
- **Cookie Management**: `getCookie`, `setCookie`, `clearCookies`, `loadCookies`
- **Cache Management**: `clearCache`, `clearExpired`, `cacheSize`, `cacheStats`
- **Cache Inspection**: `getCachedUrls`, `getCacheEntry`, `searchCache`
- **Context Managers**: `cacheDisabled`, `cacheEnabled`



## Configuration Options


The `CacheSettings` object (accessed via `session.settings`) is the same for both session types.

| **Option**             | **Type**          | **Default**       | **Description**                |
| ---------------------- | ----------------- | ----------------- | ------------------------------ |
| expireAfter          | int             | 3600            | Cache TTL in seconds           |
| allowableMethods     | HashSet[string] | ["GET", "HEAD"] | HTTP methods to cache          |
| allowableStatusCodes | HashSet[int]    | [200]           | Status codes to cache          |
| staleIfError         | bool            | false           | Return stale data on errors    |
| urlFilter            | proc            | nil             | Custom function to filter URLs |



## Performance Considerations

- **`SingleThreadedSession` vs. `CachedSession`**:
  - The **`SingleThreadedSession`** is the recommended choice for most applications, including simple scripts and web servers where each thread can manage its own session. It is safe and easy.
  - The **`CachedSession`** is designed for high-concurrency scenarios where you need **multiple threads to share a single cache connection**. By managing the lock externally, you have finer-grained control, but it is more complex to use correctly.
- **Database**: SQLite provides fast lookups with indexed queries. Cache entries are indexed by URL and method.
- **Maintenance**: Expired entries are not deleted automatically. You should periodically call `session.clearExpired()` to clean the database.



## Requirements

- Nim >= 2.0.x
- `db_connector` (for SQLite)
- `malebolgia` (for locking)

## Testing

Run the test suite:

```bash
nimble test
```

Tests cover:

- Cookie parsing and management
- Cache hit/miss behavior
- Expiration logic
- HTTP methods (GET, POST, HEAD)
- Configuration settings
- Context managers
- Cache inspection and management


## License
MIT

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Acknowledgments

Inspired by the Python [requests-cache](https://requests-cache.readthedocs.io/) library.