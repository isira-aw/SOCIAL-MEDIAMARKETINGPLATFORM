# Deploying to Railway

Two services in one Railway project:

| Service | What it is | Source |
|---|---|---|
| **postly-web** | FastAPI app + marketing site, settings page and generator UI | this repo |
| **n8n** | Workflow automation, optional but part of the showcase | `n8nio/n8n` Docker image |

You can deploy **postly-web alone** and the app works end to end. n8n is only
needed if you want to demo the orchestration path.

---

## Part 1 — Rotate the API key first

If a Gemini API key has ever been pasted into a chat, a commit, a screenshot or
a shared document, treat it as public. Go to Google AI Studio, delete it, and
create a new one. Only ever put the new key into Railway's **Variables** tab —
never into a file in this repo. `.gitignore` already blocks `.env`.

---

## Part 2 — Deploy the web service

### 2.1 Push the repo

```bash
git add .
git commit -m "Add Postly web app and Railway config"
git push
```

### 2.2 Create the service

1. [railway.app](https://railway.app) → **New Project** → **Deploy from GitHub repo**
2. Pick this repository. Railway detects Python via `requirements.txt` and uses
   the start command in `railway.json`.

### 2.3 Set the variables

Service → **Variables** → **Raw Editor**, paste and edit:

```
GEMINI_API_KEY=<your rotated key>
GEMINI_MODEL=gemini-3.6-flash
GEMINI_IMAGE_MODEL=gemini-2.5-flash-image
MEDIA_DIR=/data/media
ALLOWED_ORIGINS=*
```

### 2.4 Add a volume (recommended)

Generated images are written to disk. Railway containers have an ephemeral
filesystem, so without a volume every image 404s after a redeploy or restart.

Service → **Settings** → **Volumes** → **New Volume**, mount path `/data`.
That matches `MEDIA_DIR=/data/media` above. Skip this and the app still works —
images just do not survive restarts.

### 2.5 Generate a domain

Service → **Settings** → **Networking** → **Generate Domain**.

You get `https://postly-web-production-xxxx.up.railway.app`. Open it — the
marketing page loads, `/generate.html` is the generator, `/settings.html` the
settings.

### 2.6 Verify

```bash
curl https://<your-domain>/api/health
```

Expect `"gemini_key_configured": true`. If it is `false`, the variable name is
wrong or the service has not redeployed since you set it.

---

## Part 3 — Deploy n8n (optional)

### 3.1 Create the service

Same project → **New** → **Docker Image** → `n8nio/n8n:latest`

### 3.2 Variables

```
N8N_HOST=<will-be-your-n8n-domain>.up.railway.app
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://<will-be-your-n8n-domain>.up.railway.app/
GENERIC_TIMEZONE=Asia/Colombo
N8N_ENCRYPTION_KEY=<any long random string, keep it forever>
N8N_BLOCK_ENV_ACCESS_IN_NODE=false
GEMINI_MODEL=gemini-3.6-flash
GEMINI_IMAGE_MODEL=gemini-2.5-flash-image
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=<pick a strong password>
```

Two things matter here. `N8N_ENCRYPTION_KEY` encrypts your stored credentials —
if you change it later, every saved credential becomes unreadable. And
`N8N_BLOCK_ENV_ACCESS_IN_NODE=false` is what lets the workflow read
`$env.GEMINI_MODEL`; without it those expressions resolve to undefined.

### 3.3 Volume and domain

Add a volume mounted at `/home/node/.n8n` — this is where n8n keeps its SQLite
database. Without it you lose every workflow on redeploy.

Then **Generate Domain**, and go back and correct `N8N_HOST` and `WEBHOOK_URL`
to the real domain. Redeploy.

### 3.4 Set up the workflow

Full walkthrough in [N8N-SETUP.md](N8N-SETUP.md). Short version:

1. Open your n8n domain, create the owner account.
2. **Workflows → Import from File** → `n8n/demo-gemini-workflow.json`
3. **Credentials → New → Header Auth**: name `x-goog-api-key`, value your Gemini
   key. Name the credential `GEMINI_CREDENTIAL` and select it on both Gemini nodes.
4. **Activate** the workflow.
5. Open the **Webhook - Campaign** node and copy the **Production URL**.

### 3.5 Connect the two

In the Postly app → **Settings** → paste the webhook URL → **Test n8n
connection**. A green result means the round trip works. Tick *Route generation
through my n8n workflow* to use it by default.

---

## Local development

```bash
python -m venv .venv
.venv\Scripts\activate          # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
copy .env.example .env          # then edit it
uvicorn app.main:app --reload
```

Open http://localhost:8000. The `.env` file is not loaded automatically — either
export the variables in your shell, or add `python-dotenv` and load it in
`main.py` if you prefer file-based config locally.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `GEMINI_API_KEY is not configured` | Variable missing or service not redeployed. Check `/api/health`. |
| `Gemini rejected the model name 'gemini-3.6-flash'` | Your key does not have access to that model name, or the name is wrong. Set `GEMINI_MODEL` to a model your key can list, and `GEMINI_IMAGE_MODEL` to an image-capable one. |
| Posts generate but no image | Text and image models are different. The content model cannot produce images — check `GEMINI_IMAGE_MODEL`. The UI tells you the specific reason under the image slot. |
| Image loads, then 404s tomorrow | No volume attached. See 2.4. |
| Build fails on Railway | `requirements.txt` and `railway.json` must be at the repo root, and `app/main.py` must exist. |
| Health check timeout | Railway passes `$PORT`; the start command must bind `0.0.0.0:$PORT`. Do not hard-code 8000. |
| n8n loses workflows after deploy | No volume at `/home/node/.n8n`. See 3.3. |
| n8n webhook returns 404 | Workflow not activated, or you copied the Test URL instead of the Production URL. |
| CORS error calling n8n | Only applies if the browser calls n8n directly. In this app the FastAPI backend proxies the call, so CORS is not involved. |

---

## Cost note

Railway's free trial credit covers both services for a demo. Two always-on
services plus two volumes will consume it faster than one. If you only need the
app, skip n8n and use direct mode.
