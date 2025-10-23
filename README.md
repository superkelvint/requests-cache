# requests_cache

A Nim HTTP caching library inspired by Python's [requests-cache](https://requests-cache.readthedocs.io/).

**requests_cache** provides intelligent caching for HTTP requests with support for expiration, cookie management, cache statistics, and flexible filtering policies.

## Features

- **Persistent Caching**: Responses cached in SQLite database
- **Configurable Expiration**: Set custom TTLs for cached responses
- **Smart Filtering**: URL filters and status code allowlists
- **Cookie Management**: Automatic cookie persistence and sending
- **Stale-If-Error**: Fallback to stale responses on request failures
- **Cache Statistics**: Track hits, misses, and cache size
- **Context Managers**: Temporarily enable/disable caching
- **Cache Inspection**: Query and analyze cached entries

## Installation

### Via Nimble

```bash
nimble install requests_cache
```

### Manual

Clone this repository and add it to your Nim path:

```bash
git clone https://github.com/superkelvint/requests_cache.git
cd requests_cache
nimble install
```

## Quick Start

```nim
import requests_cache

# Create a new cached session
var session = newCachedSession(
  dbPath = "cache.db",
  expireAfter = 3600  # Cache for 1 hour
)

# Make a GET request (cached automatically)
let response = session.get("https://api.example.com/data")
echo response

# Check cache statistics
let stats = session.cacheStats()
echo "Hits: ", stats.hits, " Misses: ", stats.misses
```

## Usage Guide

### Basic Requests

```nim
# GET request
let data = session.get("https://api.example.com/users")

# GET with query parameters
let params = {"user_id": "123", "limit": "10"}.toTable
let filtered = session.get("https://api.example.com/users", params = params)

# POST request (enable in settings)
session.settings.allowableMethods.incl("POST")
let created = session.post("https://api.example.com/users", data = """{"name": "Alice"}""")

# HEAD request
let headers = session.head("https://api.example.com/check")
```

### Configuration

```nim
import std/sets

var session = newCachedSession(
  dbPath = "my_cache.db",
  expireAfter = 7200,                              # Cache for 2 hours
  allowableMethods = toHashSet(["GET", "HEAD"]),   # Only cache these methods
  allowableStatusCodes = toHashSet([200, 304]),    # Only cache these status codes
  staleIfError = true                              # Return stale data on network errors
)

# Add a URL filter
session.settings.urlFilter = proc(url: string): bool =
  not url.contains("private")  # Don't cache URLs containing "private"
```

### Cookie Management

```nim
# Set a cookie
session.setCookie("user_session", "abc123xyz")

# Get a cookie
let token = session.getCookie("user_session")
if token.isSome:
  echo "Token: ", token.get()

# Clear all cookies
session.clearCookies()

# Cookies are automatically persisted and loaded on session creation
```

### Cache Control

```nim
# Temporarily disable caching
session.cacheDisabled:
  let freshData = session.get("https://api.example.com/status")

# Temporarily enable caching (when globally disabled)
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

## API Reference

### Session Management

- `newCachedSession()`: Create a new cached session
- `getCookie()`: Get a cookie by name
- `setCookie()`: Set a cookie
- `loadCookies()`: Load cookies from database
- `saveCookies()`: Persist cookies to database
- `clearCookies()`: Clear all cookies

### HTTP Methods

- `get()`: Perform a cached GET request
- `post()`: Perform a cached POST request
- `head()`: Perform a cached HEAD request
- `request()`: Core request function (used by above methods)

### Cache Management

- `clearCache()`: Delete all cache entries
- `clearExpired()`: Remove only expired entries
- `cacheSize()`: Get total number of cached entries
- `cacheStats()`: Get hits, misses, and size

### Cache Inspection

- `getCachedUrls()`: List all cached URLs
- `getCacheEntry()`: Get details for a specific entry
- `searchCache()`: Find entries matching a URL pattern

### Context Managers

- `cacheDisabled`: Temporarily disable caching
- `cacheEnabled`: Temporarily enable caching

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `expireAfter` | `int` | `3600` | Cache TTL in seconds |
| `allowableMethods` | `HashSet[string]` | `["GET", "HEAD"]` | HTTP methods to cache |
| `allowableStatusCodes` | `HashSet[int]` | `[200]` | Status codes to cache |
| `staleIfError` | `bool` | `false` | Return stale data on errors |
| `urlFilter` | `proc` | `nil` | Custom function to filter URLs |

## Requirements

- Nim >= 2.2.x
- SQLite support (via `db_connector`)

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

## Performance Considerations

- SQLite provides fast lookups with indexed queries
- Cache entries are indexed by URL and method
- Expired entries should be periodically cleared via `clearExpired()`
- For high-traffic scenarios, consider adjusting `expireAfter` based on data freshness needs

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