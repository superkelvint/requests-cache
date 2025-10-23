# requests_cache.nim
# A Nim HTTP caching library inspired by Python's requests-cache.

import db_connector/db_sqlite
import httpclient
import json
import tables
import times
import strutils
import options
import uri
import std/sets

# --- Core Types ---

type
  CacheSettings* = object
    expireAfter*: int
    allowableMethods*: HashSet[string]
    allowableStatusCodes*: HashSet[int]
    staleIfError*: bool
    urlFilter*: proc(url: string): bool

type
  CachedSession* = object
    dbPath*: string
    db*: DbConn
    cacheEnabled*: bool
    cookies*: Table[string, string]
    settings*: CacheSettings

# --- Forward Declarations ---

proc loadCookies*(session: var CachedSession)
proc setCookie*(session: var CachedSession, name: string, value: string)
proc formatCookieHeader(session: CachedSession): string
proc extractAndSaveCookies(session: var CachedSession, response: Response)

# --- Session Initialization ---

proc newCachedSession*(dbPath: string = "cache.db",
                       expireAfter: int = 3600,
                       allowableMethods: HashSet[string] = toHashSet(["GET", "HEAD"]),
                       allowableStatusCodes: HashSet[int] = toHashSet([200]),
                       staleIfError: bool = false): CachedSession =
  ## Initializes a new session with a SQLite cache database.
  
  let settings = CacheSettings(
    expireAfter: expireAfter,
    allowableMethods: allowableMethods,
    allowableStatusCodes: allowableStatusCodes,
    staleIfError: staleIfError,
    urlFilter: nil
  )

  let db = open(dbPath, "", "", "")

  # Create Cache Table
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS cache (
      id INTEGER PRIMARY KEY,
      url TEXT NOT NULL,
      method TEXT NOT NULL,
      response BLOB NOT NULL,
      status_code INTEGER NOT NULL DEFAULT 200,
      headers TEXT,
      created_at INTEGER,
      expires_at INTEGER,
      hits INTEGER DEFAULT 0,
      UNIQUE(url, method)
    );
  """)
  db.exec(sql"CREATE INDEX IF NOT EXISTS idx_expires_at ON cache(expires_at);")
  db.exec(sql"CREATE INDEX IF NOT EXISTS idx_url ON cache(url);")

  # Create Cookies Table
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS cookies (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      value TEXT NOT NULL,
      domain TEXT,
      path TEXT,
      expires_at INTEGER,
      secure INTEGER DEFAULT 0,
      http_only INTEGER DEFAULT 0
    );
  """)
  
  # Create Stats Table
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS stats (
      id INTEGER PRIMARY KEY,
      hits INTEGER DEFAULT 0,
      misses INTEGER DEFAULT 0
    );
  """)

  # Ensure stats row exists
  db.exec(sql"INSERT OR IGNORE INTO stats (id, hits, misses) VALUES (1, 0, 0);")

  var session = CachedSession(
    dbPath: dbPath,
    db: db,
    cacheEnabled: true,
    cookies: initTable[string, string](),
    settings: settings
  )

  session.loadCookies()
  return session

# --- Internal Cookie Helpers ---

proc parseSetCookie*(header: string): tuple[name: string, value: string] =
  ## Simplified parser for Set-Cookie header.
  let parts = header.split(';')
  if parts.len > 0:
    let kv = parts[0].split('=', 1)
    if kv.len == 2:
      return (kv[0].strip(), kv[1].strip())
  return ("", "")

proc formatCookieHeader(session: CachedSession): string =
  ## Formats the Cookie header string to be sent with a request.
  var pairs: seq[string]
  for name, value in session.cookies:
    pairs.add(name & "=" & value)
  return pairs.join("; ")

proc extractAndSaveCookies(session: var CachedSession, response: Response) =
  ## Extracts Set-Cookie headers from a response and saves them.
  if response.headers.table.hasKey("Set-Cookie"):
    for cookieString in response.headers.table["Set-Cookie"]:
      let cookie = parseSetCookie(cookieString)
      if cookie.name.len > 0:
        session.setCookie(cookie.name, cookie.value)

# --- Public Cookie Management ---

proc loadCookies*(session: var CachedSession) =
  ## Loads persisted cookies from the database into the session.
  session.cookies.clear()
  let now = epochTime().int
  for row in session.db.fastRows(sql"SELECT name, value FROM cookies WHERE expires_at IS NULL OR expires_at > ?", now):
    session.cookies[row[0]] = row[1]

proc saveCookies*(session: var CachedSession) =
  ## Persists the session's current cookies to the database (overwrite strategy).
  session.db.exec(sql"DELETE FROM cookies")
  for name, value in session.cookies:
    session.db.exec(sql"INSERT INTO cookies (name, value) VALUES (?, ?)", name, value)

proc clearCookies*(session: var CachedSession) =
  ## Clears cookies from the session and the database.
  session.cookies.clear()
  session.db.exec(sql"DELETE FROM cookies")

proc setCookie*(session: var CachedSession, name: string, value: string) =
  ## Sets a cookie in the session and persists it to the database.
  session.cookies[name] = value
  session.db.exec(sql"INSERT OR REPLACE INTO cookies (name, value) VALUES (?, ?)", name, value)

proc getCookie*(session: CachedSession, name: string): Option[string] =
  ## Gets a cookie value from the session by name.
  if session.cookies.hasKey(name):
    return some(session.cookies[name])
  else:
    return none[string]()

# --- Core HTTP Methods ---

proc request*(session: var CachedSession, meth: string, url: string,
              data: string = "",
              headers: Table[string, string] = initTable[string, string]()): string =
  ## The core request function that handles caching logic.
  
  let meth = meth.toUpper()
  let now = epochTime().int
  var staleResponse: Option[string] = none[string]()

  # 1. Check if we should even look at the cache
  let tryCache = session.cacheEnabled and
                 (meth in session.settings.allowableMethods) and
                 (session.settings.urlFilter == nil or session.settings.urlFilter(url))

  if tryCache:
    let row = session.db.getRow(sql"SELECT response, expires_at, hits FROM cache WHERE url = ? AND method = ?", url, meth)
    if row.len == 3 and row[0].len > 0 and row[1].len > 0 and row[2].len > 0:
      let responseBody = row[0]
      let expiresAt = parseInt(row[1])
      let hits = parseInt(row[2])

      if now < expiresAt:
        # Cache hit and valid
        session.db.exec(sql"UPDATE cache SET hits = ? WHERE url = ? AND method = ?", hits + 1, url, meth)
        session.db.exec(sql"UPDATE stats SET hits = hits + 1 WHERE id = 1")
        return responseBody
      else:
        # Cache hit but stale
        staleResponse = some(responseBody)

  # 2. Cache miss or conditions not met, make request
  if tryCache:
    session.db.exec(sql"UPDATE stats SET misses = misses + 1 WHERE id = 1")

  var client = newHttpClient()
  var httpHeaders = newHttpHeaders()
  for key, value in headers:
    httpHeaders[key] = value
  httpHeaders["Cookie"] = formatCookieHeader(session)
  client.headers = httpHeaders

  var response: Response
  try:
    case meth:
    of "GET":
      response = client.get(url)
    of "POST":
      response = client.post(url, body = data)
    of "HEAD":
      response = client.head(url)
    else:
      response = client.request(url, httpMethod = parseEnum[HttpMethod](meth), body = data)

  except Exception as e:
    echo "HTTP Request Error: ", e.msg
    if session.settings.staleIfError and staleResponse.isSome:
      return staleResponse.get()
    raise e

  # 3. Process and potentially cache the response
  extractAndSaveCookies(session, response)

  let statusCode = response.code.int
  if tryCache and (statusCode in session.settings.allowableStatusCodes):
    let expiresAt = now + session.settings.expireAfter
    
    var headersTable: Table[string, string]
    for key, values in response.headers:
      headersTable[key] = values.join(",")

    let headersJson = $(%headersTable)

    session.db.exec(sql"""INSERT OR REPLACE INTO cache
                          (url, method, response, status_code, headers, created_at, expires_at, hits)
                          VALUES (?, ?, ?, ?, ?, ?, ?, 0)""",
                       url, meth, response.body, statusCode, headersJson, now, expiresAt)

  return response.body

proc get*(session: var CachedSession, url: string, params: Table[string, string] = default(Table[string, string])): string =
  ## Performs a cached GET request.
  var finalUrl = url
  if params.len > 0:
    var uri = parseUri(url)
    var queryPairs = initTable[string, string]()
    for key, value in decodeQuery(uri.query):
      queryPairs[key] = value
    for k, v in params:
      queryPairs[k] = v
    var queryStr = ""
    var first = true
    for k, v in queryPairs:
      if not first:
        queryStr.add("&")
      queryStr.add(k & "=" & v)
      first = false
    uri.query = queryStr
    finalUrl = $uri
  return session.request("GET", finalUrl)

proc post*(session: var CachedSession, url: string, data: string = "", headers: Table[string, string] = default(Table[string, string])): string =
  ## Performs a cached POST request.
  return session.request("POST", url, data = data, headers = headers)

proc head*(session: var CachedSession, url: string): string =
  ## Performs a cached HEAD request.
  return session.request("HEAD", url)

# --- Cache Context Managers ---

template cacheDisabled*(session: var CachedSession, body: untyped) =
  ## Temporarily disables caching for the code block.
  let prevCacheState = session.cacheEnabled
  session.cacheEnabled = false
  try:
    body
  finally:
    session.cacheEnabled = prevCacheState

template cacheEnabled*(session: var CachedSession, body: untyped) =
  ## Temporarily enables caching for the code block.
  let prevCacheState = session.cacheEnabled
  session.cacheEnabled = true
  try:
    body
  finally:
    session.cacheEnabled = prevCacheState

# --- Cache Inspection ---

proc getCachedUrls*(session: CachedSession): seq[string] =
  ## Returns a list of all unique cached URLs.
  result = newSeq[string]()
  for row in session.db.fastRows(sql"SELECT DISTINCT url FROM cache"):
    result.add(row[0])

type
  CacheEntry* = tuple[response: string, statusCode: int, createdAt: int, expiresAt: int, hits: int]

proc getCacheEntry*(session: CachedSession, url: string, meth: string = "GET"): Option[CacheEntry] =
  ## Returns details for a specific cache entry.
  let row = session.db.getRow(sql"""SELECT response, status_code, created_at, expires_at, hits
                                      FROM cache WHERE url = ? AND method = ?""", url, meth.toUpper())
  if row.len == 5 and row[0].len > 0:
    if row[1].len == 0 or row[2].len == 0 or row[3].len == 0 or row[4].len == 0:
      return none[CacheEntry]()
    return some((response: row[0],
                 statusCode: parseInt(row[1]),
                 createdAt: parseInt(row[2]),
                 expiresAt: parseInt(row[3]),
                 hits: parseInt(row[4])))
  return none[CacheEntry]()

proc searchCache*(session: CachedSession, urlPattern: string): seq[tuple[url: string, statusCode: int]] =
  ## Searches the cache for URLs matching a pattern (using SQL LIKE).
  result = newSeq[tuple[url: string, statusCode: int]]()
  for row in session.db.fastRows(sql"SELECT url, status_code FROM cache WHERE url LIKE ?", urlPattern):
    result.add((url: row[0], statusCode: parseInt(row[1])))

proc cacheSize*(session: CachedSession): int =
  ## Returns the total number of entries in the cache.
  return session.db.getValue(sql"SELECT count(*) FROM cache").parseInt()

# --- Cache Management ---

proc clearCache*(session: var CachedSession) =
  ## Deletes all entries from the cache and resets stats.
  session.db.exec(sql"DELETE FROM cache")
  session.db.exec(sql"UPDATE stats SET hits = 0, misses = 0 WHERE id = 1")

proc clearExpired*(session: var CachedSession): int =
  ## Deletes expired entries from the cache and returns the count of deleted items.
  let now = epochTime().int
  return session.db.execAffectedRows(sql"DELETE FROM cache WHERE expires_at <= ?", now).int

proc cacheStats*(session: CachedSession): tuple[hits: int, misses: int, size: int] =
  ## Returns a tuple of cache hits, misses, and current size.
  let row = session.db.getRow(sql"SELECT hits, misses FROM stats WHERE id = 1")
  let hits = parseInt(row[0])
  let misses = parseInt(row[1])
  let size = session.cacheSize()
  return (hits: hits, misses: misses, size: size)


# --- Example Usage ---

when isMainModule:
  import os

  if fileExists("example_cache.db"):
    removeFile("example_cache.db")

  echo "--- Initializing CachedSession ---"
  var session = newCachedSession(
    dbPath = "example_cache.db",
    expireAfter = 10,
    staleIfError = true
  )

  session.settings.urlFilter = proc(url: string): bool =
    not url.contains("api/private")

  echo "\n--- Making Requests ---"
  let url = "https://httpbin.org/get?user=test"
  
  echo "1. First request (cache miss)..."
  let r1 = session.get(url)
  echo "  > Response length: ", r1.len
  
  echo "2. Second request (cache hit)..."
  let r2 = session.get(url)
  echo "  > Response length: ", r2.len

  let privateUrl = "https://httpbin.org/get?user=private&val=api/private"
  echo "3. Request to private URL (skipped by urlFilter)..."
  let r3 = session.get(privateUrl)
  let r4 = session.get(privateUrl)
  
  echo "\n--- Cache Stats ---"
  var stats = session.cacheStats()
  echo "  > Hits: ", stats.hits
  echo "  > Misses: ", stats.misses
  echo "  > Size: ", stats.size
  
  echo "\n--- Context Manager (cacheDisabled) ---"
  session.cacheDisabled:
    echo "  > Making request with cache disabled..."
    let freshData = session.get(url)

  stats = session.cacheStats()
  echo "  > Stats after disabled request:"
  echo "    > Hits: ", stats.hits
  echo "    > Misses: ", stats.misses

  echo "\n--- Clearing Cache ---"
  session.clearCache()
  echo "  > Final cache size: ", session.cacheSize()