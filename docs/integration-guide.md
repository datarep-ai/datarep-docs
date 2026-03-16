# datarep Integration Guide

datarep is your app's data rep — a local agent runtime that retrieves data from arbitrary sources on your behalf. Your app never writes retrieval code, handles credentials, or executes anything. It tells datarep what data it needs, and datarep figures out how to get it, writes the extraction code, validates it, and delivers the results.

This guide walks you through integrating datarep into your application, whether it's an agentic app like [thyself](https://github.com/jfru/thyself), a backend service, or a CLI tool.

---

## How it works

```
┌─────────────┐         ┌──────────────────────────────────────┐
│  Your App   │  HTTP   │              datarep                 │
│             │ ──────► │                                      │
│  - thyself  │  or     │  1. Inspects the source              │
│  - resman   │  MCP    │  2. Writes retrieval code            │
│  - any app  │         │  3. Executes it in a sandbox         │
│             │ ◄────── │  4. Returns data (or saves a recipe) │
└─────────────┘         └──────────────────────────────────────┘
```

Your app authenticates with an **API key**, tells datarep what source and what data it wants, and datarep handles everything else — including credential management, sandboxed code execution, and caching working code as "recipes" for instant replay.

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

This is the primary way to get data. You describe what you want in natural language; datarep's Claude agent figures out how to get it.

```bash
curl -X POST http://127.0.0.1:7080/get \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "imessage",
    "query": "get all messages from the last 7 days"
  }'
```

**Response** (success):

```json
{
  "status": "success",
  "result": "Retrieved 142 messages from the last 7 days. Data output as JSON lines..."
}
```

The agent inspects the source, writes Python code, executes it in a sandbox, and returns the result. On first use this takes 10-30 seconds. The agent automatically saves a **recipe** — a cached version of the working code — so subsequent requests for the same pattern are instant.

**What happens under the hood:**

1. datarep checks if credentials are needed (returns `action_required` if so)
2. The Claude agent inspects the source (schema, tables, API docs)
3. It writes Python retrieval code
4. The code runs in a sandboxed subprocess with network/filesystem restrictions
5. If it fails, the agent reads the error and tries again (up to 50 turns)
6. On success, it saves a recipe and updates sync state


### 4b. Incremental sync (`POST /sync`)

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


### 4c. Recipe replay (`POST /recipe/run`)

Once a recipe exists, you can replay it without any LLM call. This is the fast path — sub-second, deterministic, no API costs:

```bash
curl -X POST http://127.0.0.1:7080/recipe/run \
  -H "Authorization: Bearer dr_<key>" \
  -H "Content-Type: application/json" \
  -d '{"recipe_id": "imessage_messages_v1"}'
```

**Response:**

```json
{
  "status": "success",
  "stdout": "{\"id\": 1, \"text\": \"hey\", \"date\": \"2026-03-15\"}\n{\"id\": 2, \"text\": \"what's up\", \"date\": \"2026-03-15\"}\n",
  "stderr": "Retrieved 2 messages\n"
}
```

Recipe replay returns raw `stdout`/`stderr` from the Python script. Data is in JSON lines format (one JSON object per line in `stdout`).

**Recommended pattern:** Try recipe replay first. If no recipe exists, fall back to agent-driven retrieval. The agent will create the recipe for you.

---

## 5. Managing sources

Sources must be registered before retrieval. Your app can do this via the API:

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

| Type | Config | Sandbox behavior |
|------|--------|-----------------|
| `local_db` | `path`: path to SQLite file | No network access. Read-only filesystem access to the DB path. |
| `rest_api` | `base_url`, plus optional OAuth fields | Network restricted to `base_url` domain and `token_url` domain only. |
| `local_files` | `path`: directory path | No network access. Read-only access to the directory. |

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

## 6. Handling credentials

For `local_db` and `local_files` sources, no credentials are needed (the agent accesses the filesystem directly).

For `rest_api` sources, you have two options:

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

## 7. Handling `action_required` responses

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

If your app has an LLM agent (like thyself), pass the full `action_required` response to your agent as context. The fields are designed to be LLM-friendly — your agent can read `explanation`, `steps`, and `context` and have a natural conversation with the user about what's needed:

> **User:** "Import my iMessages"
>
> **Your agent:** "I need Full Disk Access to read your iMessage database. You can enable it in System Preferences under Privacy & Security. Want me to open that for you?"

After the user completes the action, retry the original request. All `action_required` responses have `"retryable": true`.

---

## 8. Recipes

Recipes are datarep's caching layer. When the agent successfully retrieves data, it saves the working Python code as a recipe. Recipes can be replayed instantly without an LLM call.

### List recipes

```bash
curl http://127.0.0.1:7080/recipes \
  -H "Authorization: Bearer dr_<key>"

# Filter by source
curl "http://127.0.0.1:7080/recipes?source=imessage" \
  -H "Authorization: Bearer dr_<key>"
```

**Response:**

```json
{
  "recipes": [
    {
      "id": "imessage_messages_v1",
      "source_name": "imessage",
      "description": "Retrieves all iMessage conversations",
      "last_used_at": "2026-03-15T10:00:00+00:00",
      "times_used": 12,
      "created_at": "2026-03-14T08:30:00+00:00"
    }
  ]
}
```

### Get recipe details (including code)

```bash
curl http://127.0.0.1:7080/recipes/imessage_messages_v1 \
  -H "Authorization: Bearer dr_<key>"
```

### Recommended integration pattern

```python
import httpx

DATAREP = "http://127.0.0.1:7080"
HEADERS = {"Authorization": "Bearer dr_<key>"}

async def get_data(source: str, query: str):
    # 1. Check for an existing recipe
    resp = await httpx.AsyncClient().get(
        f"{DATAREP}/recipes", params={"source": source}, headers=HEADERS
    )
    recipes = resp.json().get("recipes", [])

    if recipes:
        # 2. Fast path: replay the recipe
        result = await httpx.AsyncClient().post(
            f"{DATAREP}/recipe/run",
            json={"recipe_id": recipes[0]["id"]},
            headers=HEADERS,
            timeout=30,
        )
        data = result.json()
        if data.get("status") == "success":
            return data["stdout"]

    # 3. Slow path: agent-driven retrieval (creates a recipe for next time)
    result = await httpx.AsyncClient().post(
        f"{DATAREP}/get",
        json={"source": source, "query": query},
        headers=HEADERS,
        timeout=120,
    )
    return result.json()
```

---

## 9. MCP interface (for agentic apps)

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
| `datarep_get(source, query)` | Agent-driven retrieval |
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

## 10. Complete API reference

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | No | Health check. Returns `{"status": "ok"}`. |
| `POST` | `/get` | Bearer | Agent-driven data retrieval. |
| `POST` | `/sync` | Bearer | Incremental sync. |
| `POST` | `/recipe/run` | Bearer | Replay a saved recipe. |
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
{"source": "string", "query": "string"}
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

All responses return JSON. Successful responses vary by endpoint (see examples above). Errors follow this pattern:

```json
{"detail": "Error description"}
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

## 11. Configuration

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
| `datarep.pid` | Server PID when running as daemon |

---

## 12. Security model

- **Credentials are encrypted at rest** using Fernet symmetric encryption. The master key is stored with `0600` permissions.
- **API keys are bcrypt-hashed** — datarep never stores your app's key in plaintext.
- **Code execution is sandboxed** — on macOS, datarep uses `sandbox-exec` to restrict network access (only the source's registered domains) and filesystem access (read-only to the source path, read-write to a temp working directory).
- **Per-app source restrictions** — each app can be limited to specific sources at registration time.
- **Full audit log** — every action (retrieval, sync, source changes, auth events) is logged with app ID, timestamp, and status.

---

## 13. Checking the audit log

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
5. [ ] Register sources (`POST /sources` or `datarep source add`)
6. [ ] Store credentials if needed (`POST /auth/credentials` or `POST /auth/oauth`)
7. [ ] Call `POST /get` with your query — datarep handles the rest
8. [ ] On subsequent calls, use `POST /recipe/run` for instant replay
