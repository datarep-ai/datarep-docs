# datarep

**Your app's data rep.**

A **rep** is someone you send to go get something on your behalf. You don't tell them how — you tell them what you need, and they figure it out. They show up, assess the situation, adapt to whatever they find, and come back with the goods.

That's what datarep does. Your app says "get me the user's recent iMessages" and datarep handles it — explores the database schema, identifies the data formats, picks the right parsing libraries, writes the extraction code, tests it, and delivers the data. No one wrote an iMessage integration. The rep wrote one at runtime.

And like a good rep, it learns. Working code is saved as **recipes** so next time it doesn't have to figure it out again. First request takes seconds. Every request after that is instant.

---

## Why datarep?

Every app that needs user data today has to build and maintain its own integrations — or depend on a cloud service that proxies the user's data through someone else's servers. datarep is a different approach: a local agent runtime that synthesizes integrations on demand, runs on the user's machine, and never sends their data anywhere.

There isn't really a category for this yet. It's not a connector (those are pre-built by humans), not an ETL pipeline, not an SDK. It's an autonomous agent that *becomes* a connector — for any source, on the fly.

datarep replaces bespoke integration code with a single trusted runtime:

- **Your app never writes retrieval code.** It sends a natural-language query. datarep's agent inspects the source, writes Python code, and executes it in a sandbox.
- **Your app never handles credentials.** datarep manages encrypted storage, browser-based OAuth, and automatic token refresh.
- **Your app never executes untrusted code.** All code runs inside datarep's sandbox with network and filesystem restrictions.
- **Users grant trust once** — to datarep — instead of to every app that wants their data.

## Install

=== "pip"

    ```bash
    pip install datarep
    ```

=== "curl"

    ```bash
    curl -sSL https://datarep-ai.github.io/datarep-docs/install.sh | sh
    ```

## Quick start

```bash
# Initialize datarep
datarep init

# Set your Anthropic API key (powers the retrieval agent)
export ANTHROPIC_API_KEY="sk-ant-..."

# Start the server
datarep start

# Register your app
datarep app register my-app
# => App ID:  app_...
# => API Key: dr_...  (save this)
```

Then retrieve data:

```bash
curl -X POST http://127.0.0.1:7080/get \
  -H "Authorization: Bearer dr_<your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{"source": "my_source", "query": "get recent records"}'
```

datarep inspects the source, writes retrieval code, executes it, returns data, and saves a **recipe** — a cached version of the working code — so subsequent requests are instant.

## How it works

```mermaid
sequenceDiagram
    participant App as Your App
    participant DR as datarep
    participant Agent as Claude Agent
    participant Sandbox as Sandbox

    App->>DR: POST /get {source, query}
    DR->>Agent: Inspect source, write code
    Agent->>Sandbox: Execute Python in sandbox
    Sandbox-->>Agent: stdout (JSON lines)
    Agent->>DR: Save recipe, update sync state
    DR-->>App: {status: "success", result: "..."}

    Note over App,DR: Next time: POST /recipe/run — instant, no LLM call
```

## Interfaces

| Interface | Use case |
|-----------|----------|
| **HTTP API** (`localhost:7080`) | Primary interface for all apps. Bearer token auth. |
| **MCP server** | Native protocol for LLM-powered / agentic apps. |
| **CLI** (`datarep`) | Setup, source management, debugging. |

## Source types

| Type | Example | Sandbox restrictions |
|------|---------|---------------------|
| `local_db` | iMessage, WhatsApp, any SQLite | No network. Read-only DB access. |
| `rest_api` | Square, Gmail, Quickbooks | Network restricted to source domain only. |
| `local_files` | Photos, documents, exports | No network. Read-only directory access. |

## Next steps

Read the **[Integration Guide](integration-guide.md)** for the full walkthrough: API reference, authentication, handling permissions, MCP setup, recipes, and code examples.
