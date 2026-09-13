# Demo — AI Social Media Campaign Generator

A minimal, showcase-only slice of the platform: a single n8n workflow (7 nodes) and
a single HTML page. No database, no scheduling, no publishing, no waits.

```
Browser form  →  n8n Webhook  →  validate  →  OpenAI  →  parse  →  JSON response  →  rendered cards
```

## Setup (about 3 minutes)

**1. Import the workflow**

n8n → Workflows → Import from File → `demo/n8n-demo-workflow.json`

**2. Add the OpenAI credential**

Open the `OpenAI - Generate Campaign` node → Credential → *Create new* → OpenAI →
paste your API key. Optionally set `OPENAI_MODEL` in the n8n environment
(defaults to `gpt-4.1-mini`); if you set env vars, also set
`N8N_BLOCK_ENV_ACCESS_IN_NODE=false` so expressions can read them.

**3. Activate and copy the URL**

Activate the workflow, open the `Webhook - Campaign` node, and copy the
**Production URL**:

```
http://localhost:5678/webhook/smmp-demo/campaign
```

While you are still building, use the **Test URL** (`/webhook-test/...`) and press
*Test workflow* on the canvas before each submission — test URLs only fire once.

**4. Open the UI**

Double-click `demo/index.html`. Paste the webhook URL into the first field (it is
remembered in the browser afterwards), fill in the brief, and hit **Generate campaign**.

## What it demonstrates

- **Webhook intake** with deterministic request validation before any model call
- **Structured JSON output** from the LLM (`response_format: json_object`)
- **Deterministic platform filtering** — the platform list comes from the form and is
  re-applied in `Code - Parse Result`, so the model cannot add a platform you didn't pick
- **Prompt-injection containment** — the brief is fenced in `<brief>` tags and the
  system prompt instructs the model to treat it as data only
- **Per-platform tone and hashtag rules** — Facebook, Instagram and WhatsApp get
  genuinely different copy
- **An image prompt** generated for the campaign (not the image itself — that would
  need the Gemini node from the full build)

## If it doesn't connect

| Symptom | Fix |
|---|---|
| "Could not reach n8n" | Workflow not active, wrong URL, or n8n not running |
| CORS error in the console | The Webhook node needs `Options → Allowed Origins (CORS) = *` — it is preset in the import, but re-check if you rebuilt the node |
| 404 from n8n | Using the production URL on an inactive workflow, or the test URL without pressing *Test workflow* first |
| "did not return usable JSON" | OpenAI credential missing or out of quota — check the node's execution log |

## Going further

The full production build lives alongside this demo: `n8n/` (six workflows with
PostgreSQL persistence, engagement-informed scheduling, Meta/WhatsApp publishing
and 24-hour analytics), `db/schema.sql`, and `docs/SETUP.md`.
