# datarep Integration Guide

datarep is your app's data rep — a local agent runtime that retrieves data from arbitrary sources on your behalf. Your app never writes retrieval code, handles credentials, or executes anything. It tells datarep what data it needs, and datarep's agent figures out how to get it — conversationally discovering access methods, writing extraction code, validating results, and delivering structured data.

This guide walks you through integrating datarep into your application, whether it's an agentic app like [thyself](https://github.com/jfru/thyself), a backend service, or a CLI tool.

---

## How it works

```
┌─────────────┐         ┌──────────────────────────────────────┐
│  Your App   │  HTTP   │              datarep                 │
│             │ ──────► │                                      │
│  - thyself  │  or     │  1. Asks user how they access data   │
│  - resman   │  MCP    │  2. Explores the device              │
│  - any app  │         │  3. Reports stats, gets user approval│
│             │ ◄────── │  4. Writes & validates retrieval code│
│             │         │  5. Saves a recipe                   │
│  GET /data/ │ ──────► │                                      │
│  {recipe_id}│ ◄────── │  6. Streams data directly from sandbox│
└─────────────┘         │     (NDJSON, no buffering)           │
                        └──────────────────────────────────────┘
```

Your app authenticates with an **API key**, tells datarep what data it wants, and datarep handles everything else — including conversational discovery, browser cookie extraction, sandboxed code execution, and caching working code as "recipes." Data is delivered via streaming — your app calls `GET /data/{recipe_id}` and receives NDJSON rows piped directly from the sandbox, with no intermediate storage or memory limits.

---

## 1. Prerequisites

datarep must be running on the user's machine. If your app bundles datarep (recommended for desktop apps), manage its lifecycle as a subprocess. If datarep is installed independently, your app discovers it at `localhost:7080`.

```bash
# One-time setup (done by the user or your app's installer)
pip install datarep
datarep init
datarep start
```

The user also needs an `ANTHROPIC_API_KEY` environment variable set for agent-driven retrieval. Recipe replay works without it.

## 2. Get an API key

Every consuming app needs its own API key. The user (or your installer) registers your app via the CLI:

```bash
# Unrestricted access to all sources
datarep app register my-app

# Or restricted to specific sources
datarep app register my-app --sources "gmail,imessage,whatsapp"
```

Output:

```
App registered: my-app
  App ID:  app_922df87334ef43e8
  API Key: dr_wwFzcZCmNBkdDgquwiJzZq9P_Zm9XG0K_hLWzfx9C1U
  (Save this key — it won't be shown again.)
```

Store the API key securely in your app (keychain, encrypted config, environment variable — never hardcoded in source). The key is bcrypt-hashed in datarep's database and cannot be retrieved after registration.

## 3. Authenticate requests

Every request to datarep (except `/health`) requires a Bearer token:

```
Authorization: Bearer dr_<your-api-key>
```

Unauthenticated requests return `401`. Requests to sources outside your app's allow-list return `403`.

---

## 4. Core workflows

### 4a. Agent-driven retrieval (`POST /get`)

This is the primary way to get data. You describe what you want in natural language; datarep's agent figures out how to get it. The `source` field is optional — the agent can discover sources on its own.

```bash
curl -X POST http://127.0.0.1:7080/get \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "get my Instagram DMs"
  }'
```

**Response** (success):

```json
{
  "status": "success",
  "result": "Retrieved 40 messages from 5 conversations..."
}
```

**Response** (agent needs user input):

```json
{
  "status": "question",
  "session_id": "s_abc123def456",
  "question": "How do you usually access your Instagram messages — in a browser, the app, or something else?"
}
```

When the agent needs information from the user (like how they access their data), it returns a `question` response with a `session_id`. Your app should relay the question to the user and send their answer back.

### 4b. Replying to agent questions (`POST /sessions/{id}/reply`)

When the agent asks a question, continue the conversation by replying with the user's answer:

```bash
curl -X POST http://127.0.0.1:7080/sessions/s_abc123def456/reply \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{"answer": "im logged in via Safari"}'
```

The response will be either another `question` (the conversation continues), a `success` (data retrieved), or an `error`.

**What happens under the hood:**

1. The agent checks for an existing recipe and validates it against the source
2. If no recipe exists, it asks the user how they access the data
3. Based on the answer, it explores the device — scanning browser profiles, app databases, local files
4. It extracts credentials programmatically (e.g., session cookies from Safari via `browser_cookie3`)
5. It reports data source stats (record count, date range) and waits for user approval
6. It writes Python retrieval code, runs a test (~1000 rows) to verify quality, and saves a **recipe**
7. The consuming app calls `GET /data/{recipe_id}` to stream the full dataset

### 4c. Incremental sync (`POST /sync`)

Same as `/get`, but signals to the agent that it should pick up where the last sync left off (using saved cursors/timestamps):

```bash
curl -X POST http://127.0.0.1:7080/sync \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "gmail",
    "query": "sync new emails since last run"
  }'
```

The `query` field is optional — if omitted, datarep defaults to a full incremental sync.


### 4d. Streaming data delivery (`GET /data/{recipe_id}`)

Once the agent has created a recipe, your app retrieves the actual data by streaming it:

```bash
curl http://127.0.0.1:7080/data/instagram_dms_v1 \
  -H "Authorization: Bearer dr_<key>"
```

**Response:** A chunked NDJSON stream (`application/x-ndjson`). Each line is a JSON object:

```
{"conversation_id": "123", "sender": "alice", "text": "hey", ...}
{"conversation_id": "124", "sender": "bob", "text": "meeting tomorrow?", ...}
...
{"_stream_complete": true, "rows_delivered": 40, "rows_failed": 0, "failed_row_ids": []}
```

The last line is always a `_stream_complete` summary telling your app how many rows were delivered and whether any failed. Data streams directly from the sandbox subprocess to the HTTP response — no intermediate storage, no memory buffering. This works for datasets of any size.

**If rows fail:** Recipes include per-row error handling — a single bad row never kills the stream. Failed rows are skipped and logged. After the stream completes, datarep automatically kicks off its agent to fix the recipe for those edge cases. Your app can then call the retry endpoint.

### 4e. Retrying failed rows (`GET /data/{recipe_id}/retry`)

If the stream summary reported failed rows, wait for datarep to fix the recipe (this happens automatically in the background), then request just the missing rows:

```bash
curl http://127.0.0.1:7080/data/instagram_dms_v1/retry \
  -H "Authorization: Bearer dr_<key>"
```

This runs the (now-fixed) recipe targeting only the previously-failed row IDs. Returns `404` if there are no pending retries. On success, the error record is marked as resolved.

### 4f. Recipe replay (`POST /recipe/run`)

You can also replay a recipe synchronously (returns all output in a single JSON response). This is useful for small datasets but not recommended for large ones — use `GET /data/{recipe_id}` for streaming instead.

```bash
curl -X POST http://127.0.0.1:7080/recipe/run \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{"recipe_id": "instagram_dms_v1"}'
```

**Recommended pattern:** Use `POST /get` to create the recipe, then `GET /data/{recipe_id}` to stream the data.

---

## 5. Conversational flow

The agent uses a conversational model to discover how to access data. This is the key difference from traditional integration systems — instead of requiring pre-configured sources, the agent asks the user and figures it out.

### For CLI apps

The CLI handles the conversation loop automatically:

```bash
datarep get "i want my Instagram DMs"
# Agent: "How do you usually access your Instagram messages — in a browser, the app, or something else?"
# You: "im logged in in browser"
# Agent: [extracts cookies, calls API, returns data]
```

### For HTTP API consumers

Your app needs to handle the question/reply loop:

```python
import httpx

DATAREP = "http://127.0.0.1:7080"
HEADERS = {"Authorization": "Bearer dr_<key>"}

async def get_data(query: str, source: str = None):
    body = {"query": query}
    if source:
        body["source"] = source

    result = (await httpx.AsyncClient().post(
        f"{DATAREP}/get", json=body, headers=HEADERS, timeout=120,
    )).json()

    while result.get("status") == "question":
        # Relay the question to your user and get their answer
        answer = await ask_user(result["question"])
        result = (await httpx.AsyncClient().post(
            f"{DATAREP}/sessions/{result['session_id']}/reply",
            json={"answer": answer},
            headers=HEADERS,
            timeout=120,
        )).json()

    return result
```

### For agentic apps

If your app has an LLM agent, pass the `question` response directly to your agent as context. Your agent can have a natural conversation with the user and relay answers back to datarep:

> **User:** "Import my Instagram DMs"
>
> **Your agent** calls datarep, gets a question back
>
> **Your agent:** "datarep wants to know — how do you usually access your Instagram? In a browser, the app, or something else?"
>
> **User:** "Safari"
>
> **Your agent** replies to the datarep session with "Safari"
>
> **datarep agent** extracts Safari cookies, calls API, returns data

---

## 6. Managing sources

Sources are **optional** in the new architecture. The agent can discover and access data without any pre-registered sources. When it successfully retrieves data, it auto-registers a "discovered" source for recipe tracking.

You can still pre-register sources if you want:

### Register a source

```bash
# Local SQLite database
curl -X POST http://127.0.0.1:7080/sources \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "imessage",
    "source_type": "local_db",
    "config": {"path": "~/Library/Messages/chat.db"}
  }'

# REST API
curl -X POST http://127.0.0.1:7080/sources \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "square",
    "source_type": "rest_api",
    "config": {
      "base_url": "https://connect.squareup.com/v2",
      "auth_url": "https://connect.squareup.com/oauth2/authorize",
      "token_url": "https://connect.squareup.com/oauth2/token",
      "client_id": "sq0idp-...",
      "client_secret": "sq0csp-...",
      "scopes": ["MERCHANT_PROFILE_READ", "ORDERS_READ"]
    }
  }'

# Local files
curl -X POST http://127.0.0.1:7080/sources \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "photos",
    "source_type": "local_files",
    "config": {"path": "~/Pictures"}
  }'
```

### Source types

| Type | Config | When to use |
|------|--------|-------------|
| `local_db` | `path`: path to SQLite file | You know the exact DB path upfront |
| `rest_api` | `base_url`, plus optional OAuth fields | You want to pre-configure OAuth credentials |
| `local_files` | `path`: directory path | You want to restrict the agent to a specific directory |
| `discovered` | Auto-created by agent | Agent found the data without a pre-registered source |

### List sources

```bash
curl http://127.0.0.1:7080/sources \
  -H "Authorization: Bearer dr_<key>"
```

### Remove a source

```bash
curl -X DELETE http://127.0.0.1:7080/sources/imessage \
  -H "Authorization: Bearer dr_<key>"
```

---

## 7. Handling credentials

The agent can often extract credentials on its own — particularly browser session cookies. For sources where this isn't possible, you have two options:

### Store an API key

```bash
curl -X POST http://127.0.0.1:7080/auth/credentials \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "openai",
    "cred_type": "api_key",
    "data": {"api_key": "sk-..."}
  }'
```

### Run an OAuth flow

If the source config includes `auth_url`, `token_url`, `client_id`, and `client_secret`, you can trigger a browser-based OAuth flow:

```bash
curl -X POST http://127.0.0.1:7080/auth/oauth \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{"source": "square"}'
```

This opens the user's browser to the provider's consent screen, runs a local redirect server to capture the authorization code, exchanges it for tokens, and stores them encrypted. Token refresh is automatic.

---

## 8. Handling `action_required` responses

When datarep needs something from the user — a permission grant, an OAuth login, a missing API key — it returns a structured `action_required` response instead of failing silently. **Your app is responsible for relaying this to the user.**

```json
{
  "status": "action_required",
  "action_type": "os_permission",
  "source": "imessage",
  "explanation": "Cannot read the iMessage database. macOS Full Disk Access is required.",
  "steps": [
    "Open System Preferences > Privacy & Security > Full Disk Access",
    "Enable access for the application"
  ],
  "deep_link": "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
  "retryable": true,
  "context": {
    "attempted_path": "/Users/you/Library/Messages/chat.db"
  }
}
```

### Action types

| `action_type` | Meaning | What your app should do |
|---------------|---------|------------------------|
| `os_permission` | macOS permission needed (Full Disk Access, etc.) | Guide the user to System Preferences. Use `deep_link` if provided. Retry after. |
| `oauth_login` | OAuth sign-in required | Call `POST /auth/oauth` with the source name, which opens the browser. Retry after. |
| `api_key_needed` | API key required for a source | Prompt the user for a key, then `POST /auth/credentials`. Retry after. |

### For agentic apps

If your app has an LLM agent, pass the full `action_required` response to your agent as context. The fields are designed to be LLM-friendly — your agent can read `explanation`, `steps`, and `context` and have a natural conversation with the user about what's needed:

> **User:** "Import my iMessages"
>
> **Your agent:** "I need Full Disk Access to read your iMessage database. You can enable it in System Preferences under Privacy & Security. Want me to open that for you?"

After the user completes the action, retry the original request. All `action_required` responses have `"retryable": true`.

---

## 9. Recipes

Recipes are datarep's caching layer. When the agent successfully retrieves data, it saves the working Python code as a recipe along with an **access strategy** that describes how the data is accessed (e.g., "Safari cookies + Instagram web API"). Recipes can be replayed instantly without an LLM call.

### List recipes

```bash
curl http://127.0.0.1:7080/recipes \
  -H "Authorization: Bearer dr_<key>"

# Filter by source
curl "http://127.0.0.1:7080/recipes?source=instagram" \
  -H "Authorization: Bearer dr_<key>"
```

**Response:**

```json
{
  "recipes": [
    {
      "id": "instagram_dms_v1",
      "source_name": "instagram",
      "description": "Retrieves Instagram DMs via browser cookies and web API",
      "access_strategy": "Extract Safari session cookies, call Instagram private API with rate limiting",
      "last_used_at": "2026-03-16T15:34:00+00:00",
      "times_used": 3,
      "created_at": "2026-03-16T15:22:00+00:00"
    }
  ]
}
```

### Get recipe details (including code)

```bash
curl http://127.0.0.1:7080/recipes/instagram_dms_v1 \
  -H "Authorization: Bearer dr_<key>"
```

### Recipe portability

Recipes capture a specific access strategy that worked on a specific device. They may not be universally portable — a recipe that extracts Safari cookies won't work on a machine where the user uses Chrome. The agent handles this gracefully: if a recipe fails, it diagnoses the issue and adapts rather than rewriting from scratch.

### Recommended integration pattern

```python
import json
import httpx

DATAREP = "http://127.0.0.1:7080"
HEADERS = {"Authorization": "Bearer dr_<key>"}

async def get_data(query: str, source: str = None):
    # 1. Check for an existing recipe
    params = {"source": source} if source else {}
    resp = await httpx.AsyncClient().get(
        f"{DATAREP}/recipes", params=params, headers=HEADERS
    )
    recipes = resp.json().get("recipes", [])
    recipe_id = recipes[0]["id"] if recipes else None

    if not recipe_id:
        # 2. No recipe — agent-driven retrieval creates one
        body = {"query": query}
        if source:
            body["source"] = source

        result = (await httpx.AsyncClient().post(
            f"{DATAREP}/get", json=body, headers=HEADERS, timeout=120,
        )).json()

        # Handle conversational flow
        while result.get("status") == "question":
            answer = await ask_user(result["question"])
            result = (await httpx.AsyncClient().post(
                f"{DATAREP}/sessions/{result['session_id']}/reply",
                json={"answer": answer},
                headers=HEADERS,
                timeout=120,
            )).json()

        if result.get("status") != "success":
            return result
        recipe_id = result.get("recipe_id")

    # 3. Stream the data
    async with httpx.AsyncClient() as client:
        async with client.stream(
            "GET", f"{DATAREP}/data/{recipe_id}", headers=HEADERS, timeout=3600,
        ) as resp:
            async for line in resp.aiter_lines():
                row = json.loads(line)
                if row.get("_stream_complete"):
                    summary = row
                    break
                yield row  # process each row as it arrives

    # 4. If rows failed, wait for fix and retry
    if summary.get("rows_failed", 0) > 0:
        await asyncio.sleep(30)  # wait for agent to fix the recipe
        async with httpx.AsyncClient() as client:
            async with client.stream(
                "GET", f"{DATAREP}/data/{recipe_id}/retry", headers=HEADERS,
            ) as resp:
                async for line in resp.aiter_lines():
                    row = json.loads(line)
                    if not row.get("_stream_complete"):
                        yield row
```

---

## 10. MCP interface (for agentic apps)

If your app uses the Model Context Protocol, datarep exposes itself as an MCP server. This is the most natural integration for LLM-powered apps — your agent discovers datarep's tools and uses them directly.

### Setup

Add datarep to your MCP config (e.g., in Cursor, Claude Desktop, or your app's MCP settings):

```json
{
  "mcpServers": {
    "datarep": {
      "command": "python",
      "args": ["-m", "datarep.mcp_server"],
      "env": {
        "ANTHROPIC_API_KEY": "<key-or-jwt>",
        "ANTHROPIC_BASE_URL": "https://your-proxy.example.com"
      }
    }
  }
}
```

### Available MCP tools

| Tool | Description |
|------|-------------|
| `datarep_get(query, source?)` | Agent-driven retrieval. Source is optional. May return a question. |
| `datarep_reply(session_id, answer)` | Reply to an agent question to continue a retrieval session. |
| `datarep_sync(source, query?)` | Incremental sync |
| `datarep_list_sources()` | List registered sources |
| `datarep_run_recipe(recipe_id)` | Replay a saved recipe |
| `datarep_list_recipes(source?)` | List saved recipes |
| `datarep_initiate_oauth(source)` | Start an OAuth flow |
| `datarep_check_permission(source)` | Check if a source is accessible |

### MCP resources

| URI | Description |
|-----|-------------|
| `datarep://sources` | List of registered sources |
| `datarep://recipes` | List of saved recipes |

The MCP interface does not use API key auth (it runs as a local subprocess, so trust is inherited from the process owner). Use the HTTP API if you need per-app access control.

---

## 11. Complete API reference

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | No | Health check. Returns `{"status": "ok"}`. |
| `POST` | `/get` | Bearer | Agent-driven data retrieval. Creates a recipe. `source` is optional. |
| `POST` | `/sessions/{id}/reply` | Bearer | Reply to an agent question, continuing the session. |
| `POST` | `/sync` | Bearer | Incremental sync. |
| `GET` | `/data/{recipe_id}` | Bearer | Stream full dataset as NDJSON. Primary data delivery endpoint. |
| `GET` | `/data/{recipe_id}/retry` | Bearer | Re-stream only previously-failed rows. Returns `404` if none pending. |
| `POST` | `/recipe/run` | Bearer | Replay a saved recipe (synchronous, non-streaming). |
| `GET` | `/sources` | Bearer | List sources (filtered to your app's allow-list). |
| `POST` | `/sources` | Bearer | Register a new source. |
| `DELETE` | `/sources/{name}` | Bearer | Remove a source. |
| `POST` | `/auth/credentials` | Bearer | Store credentials for a source. |
| `POST` | `/auth/oauth` | Bearer | Initiate an OAuth flow. |
| `GET` | `/recipes` | Bearer | List recipes. Optional `?source=` filter. |
| `GET` | `/recipes/{id}` | Bearer | Get recipe details and code. |
| `POST` | `/webhooks/{source}` | No | Webhook receiver (for push-based sources). |

### Request bodies

**`POST /get`**
```json
{"query": "string", "source": "string (optional)", "stream": false}
```

**`POST /sessions/{id}/reply`**
```json
{"answer": "string", "stream": false}
```

**`POST /sync`**
```json
{"source": "string", "query": "string (optional)"}
```

**`POST /recipe/run`**
```json
{"recipe_id": "string"}
```

**`POST /sources`**
```json
{"name": "string", "source_type": "local_db|rest_api|local_files", "config": {}}
```

**`POST /auth/credentials`**
```json
{"source": "string", "cred_type": "api_key|oauth2|custom", "data": {}, "expires_at": "ISO8601 (optional)"}
```

**`POST /auth/oauth`**
```json
{"source": "string"}
```

### Response shapes

All responses return JSON. The three primary response types are:

**Success:**
```json
{"status": "success", "result": "..."}
```

**Question (agent needs user input):**
```json
{"status": "question", "session_id": "s_abc123", "question": "How do you...?"}
```

**Error:**
```json
{"status": "error", "error": "...", "traceback": "..."}
```

### HTTP status codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 400 | Bad request (invalid source type, missing config, etc.) |
| 401 | Missing or invalid API key |
| 403 | App does not have access to the requested source |
| 404 | Source or recipe not found |
| 503 | Agent not available (missing `ANTHROPIC_API_KEY`) |

---

## 12. Sandbox model

The agent's code runs in a macOS `sandbox-exec` environment with:

- **Full read-only filesystem access** — the agent can read any file on the device (browser profiles, app databases, local files)
- **Open network access** — outbound TCP and UDP (including DNS resolution)
- **Write-restricted** — writes only allowed to the temporary working directory
- **No inbound connections** — the sandbox cannot listen for incoming traffic

The sandbox is designed for trust: the user runs datarep on their own machine and controls what data gets retrieved. The agent is instructed to never ask the user to manually extract data it can get programmatically.

---

## 13. Configuration

datarep is configured via environment variables:

| Variable | Purpose | Default |
|----------|---------|---------|
| `DATAREP_HOME` | Data directory | `~/.datarep` |
| `DATAREP_PORT` | HTTP server port | `7080` |
| `DATAREP_HOST` | Server bind address | `127.0.0.1` |
| `ANTHROPIC_API_KEY` | Powers the retrieval agent (or JWT when proxied) | Required for `/get` and `/sync` |
| `ANTHROPIC_BASE_URL` | Custom base URL for Anthropic API (proxy support) | `https://api.anthropic.com` |
| `DATAREP_MODEL` | Claude model to use | `claude-sonnet-4-20250514` |
| `DATAREP_KEY` | Fernet key for credential encryption | Auto-generated |

### Data stored in `~/.datarep/`

| File | Purpose |
|------|---------|
| `datarep.db` | SQLite database (sources, credentials, recipes, apps, audit log) |
| `master.key` | Fernet encryption key for credentials (mode `0600`) |
| `recipes/` | Saved recipe `.py` files |
| `logs/` | Per-request agent JSONL log files |
| `datarep.pid` | Server PID when running as daemon |

---

## 14. Security model

- **Credentials are encrypted at rest** using Fernet symmetric encryption. The master key is stored with `0600` permissions.
- **API keys are bcrypt-hashed** — datarep never stores your app's key in plaintext.
- **Code execution is sandboxed** — on macOS, datarep uses `sandbox-exec` to restrict filesystem writes and enforce read-only access to the rest of the system.
- **Per-app source restrictions** — each app can be limited to specific sources at registration time.
- **Full audit log** — every action (retrieval, sync, source changes, auth events) is logged with app ID, timestamp, and status.
- **Agent never delegates to user** — the agent extracts credentials programmatically rather than asking users to paste tokens or cookies.

---

## 15. Checking the audit log

For debugging or monitoring, query the audit log:

```bash
# Via CLI
datarep logs
datarep logs --source imessage
datarep logs --app-id app_922df87334ef43e8 --limit 10
```

Each entry includes: timestamp, app ID, action, source, status, and optional details.

---

## Quick-start checklist

1. [ ] `pip install datarep && datarep init`
2. [ ] Set `ANTHROPIC_API_KEY` in the environment
3. [ ] `datarep start`
4. [ ] `datarep app register <your-app>` — save the API key
5. [ ] Call `POST /get` with your query — datarep creates a recipe
6. [ ] Handle `question` responses by relaying to the user and replying with `POST /sessions/{id}/reply`
7. [ ] Stream the data with `GET /data/{recipe_id}`
8. [ ] Check the `_stream_complete` summary for failures; call `GET /data/{recipe_id}/retry` if needed
