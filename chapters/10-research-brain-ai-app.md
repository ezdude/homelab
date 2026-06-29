# Chapter 10: Research Brain — AI-Powered Research App

## What it is

Research Brain is a personal RAG (Retrieval-Augmented Generation) app built from scratch. The idea: ingest research sources (web pages, YouTube transcripts, PDFs, text), store them as vector embeddings, and chat with an AI that can cite specific passages from those sources. A synthesis layer lets you build persistent "memory documents" that accumulate durable understanding across sessions.

It's deployed publicly (with password auth) at `brain.YOUR_DOMAIN` — accessible from any browser, including mobile. Unlike the other services in this stack, this one required building custom application code, not just configuring existing software.

## Stack choices

| Component | Choice | Why |
|---|---|---|
| Backend | FastAPI (Python) | Async, fast, excellent for SSE streaming; good typing story |
| Embeddings DB | ChromaDB (embedded) | In-process, no separate container, persistent to disk |
| Embedding model | `gemini-embedding-001` | Google's current embedding endpoint (not `text-embedding-004` — see below) |
| Chat model | `gemini-2.5-flash` | Fast, capable, generous free tier |
| Frontend | Single-file vanilla JS | No build step, no framework, served by FastAPI itself |
| Auth | Single password + signed cookie | Personal tool; single-user; fail2ban handles brute-force |

**ChromaDB in-process, not a container:** On a 2 GB VPS already running 7+ containers, adding another container (and the network hop it introduces) for a dataset that fits easily in a single process is wasteful. ChromaDB runs embedded inside the FastAPI process, persisting to a Docker volume. This works well for single-user personal use — it would need to change for multi-user or large datasets.

## The API key problem

The original spec used `text-embedding-004` and `gemini-2.0-flash`. Both failed:

**`text-embedding-004` → 404:** This model was retired from the `v1beta/embedContent` endpoint. The error is a plain 404 — not a quota error, not a permission error. The fix was to query Google's model list endpoint to see what's actually available:
```
GET https://generativelanguage.googleapis.com/v1beta/models?key=YOUR_KEY
```
This returned `gemini-embedding-001` as the current embedding model. Switched, embeddings worked.

**`gemini-2.0-flash` free-tier quota = 0:** The model existed (it showed up in the API model list) but all requests returned 429 quota exceeded immediately. Checking the same model list endpoint showed `gemini-2.5-flash` as a model with actual free-tier capacity.

**Lesson:** When a Google AI model gives unexpected errors, query `/v1beta/models` first. The response shows available models for your key with their rate limits. Don't assume the model name from a tutorial still works — the ecosystem moves fast.

## Model deprecation: the `google-generativeai` vs `google-genai` problem

The Python package `google-generativeai` is the legacy SDK. Google's current SDK is `google-genai`. They have different import paths and different API shapes:

```python
# Legacy (don't use)
import google.generativeai as genai

# Current
from google import genai
```

The `google-genai` SDK with `gemini-2.5-flash` supports streaming via `generate_content_stream`, structured JSON output via `response_mime_type="application/json"`, and the current embedding endpoint. The legacy SDK has different method names and doesn't support all current features.

## SSE streaming through Caddy

The chat interface streams responses token-by-token using Server-Sent Events (SSE). The backend generates SSE:

```python
async def chat_stream(...):
    async def generate():
        for chunk in response:
            yield f"data: {json.dumps({'token': chunk.text})}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(generate(), media_type="text/event-stream")
```

Caddy buffered the entire response before forwarding it, making streaming appear as a single blob. The fix: `flush_interval -1` in the Caddy reverse_proxy block for the brain vhost. (nginx's equivalent `X-Accel-Buffering: no` header is nginx-specific and ignored by Caddy.)

## The blank page after login bug

After deploying, some users (including the first visit after a fresh deploy) got a blank white page instead of the app. The bug:

1. On the very first request to `GET /`, the server briefly returned an empty response while initializing
2. The browser cached that empty response (standard HTTP caching behavior)
3. All subsequent requests served the cached empty page from browser cache

Fix: add `Cache-Control: no-store` to the `GET /` response. The app shell should never be cached — it's a single-page app where the browser needs the latest version each time.

```python
return FileResponse("frontend/index.html", 
                    headers={"Cache-Control": "no-store"})
```

## YouTube transcript ingestion on a VPS

`youtube-transcript-api` 0.6.x used a timedtext endpoint that YouTube deprecated. Version 1.2.4 uses the current API:

```python
# Old (broken)
YouTubeTranscriptApi.get_transcript(video_id)

# New (1.2.4)
transcript = YouTubeTranscriptApi().fetch(video_id)
data = transcript.to_raw_data()  # list of {text, start, duration} dicts
```

Beyond the version issue: YouTube's datacenter IP detection can block transcript fetches from VPS IPs. Transcripts that work locally (from a home IP) may fail on the VPS with `IpBlocked` or `RequestBlocked` exceptions. These need to be caught and surfaced to the user rather than causing a generic server error.

## Architecture: two context streams

Every chat turn injects two types of context:
- **SOURCES:** retrieved from ChromaDB (top-5 most semantically similar chunks to the question) — cited in the answer
- **MEMORY:** the attached memory document (if any) — treated as established context, not cited

The system prompt explicitly distinguishes these:
```
RESEARCH NOTES (cite with [1], [2], etc.):
<retrieved chunks>

MEMORY (established context — do not cite):
<memory document content>
```

This prevents the AI from incorrectly citing the memory document as a source while still using its content.

## Memory as structured append-only documents

Memory documents have four fixed sections: Established Facts, Working Hypotheses, Open Questions, Session Log. The AI can only append to a section — nothing is ever overwritten. Before any write, the prior version is backed up to `.versions/<doc>.<timestamp>.md`.

This structure was chosen to prevent the AI from "helpfully" reorganizing or rewriting what you've built up — which would be hard to catch and would lose the historical progression of understanding.

## Persistent chats with capped history

Each chat is a JSON file (`data/chats/<project>/<chat_id>.json`). Every turn is saved. When a chat is reopened, the backend replays recent history into the context window, capped at ~12,000 characters.

The cap exists because the full history of a long research session can easily exceed the model's practical context window. The strategy: important findings get saved to a memory document; the chat history is just the recent working context. Starting a new chat is the "reset context" action.

## Deployment: build on the VPS, not the Mac

Development happens on an arm64 Mac (Mac mini). The VPS is amd64. Docker images built on arm64 won't run on amd64 without emulation.

The deploy workflow: rsync the code to the VPS, then build on the VPS:
```bash
rsync -az --delete --exclude '.env' --exclude 'data/' \
    ./ root@YOUR_VPS_IP:/opt/research-brain/
ssh root@YOUR_VPS_IP 'cd /opt/research-brain && docker compose up -d --build'
```

Building on the VPS means the image is native amd64 and runs without emulation overhead.

## What's next (and not yet built)

- **Nextcloud External Storage sync:** Memory documents are `.md` files on the VPS. They'd sync to Obsidian automatically if exposed via Nextcloud External Storage — but wiring that up is deferred.
- **Version restore UI:** The `.versions/` backups exist but there's no UI to browse or restore them.
- **Pay-as-you-go billing:** The free tier is adequate for personal use. If rate limits become a problem, enabling pay-as-you-go on Google AI Studio is the fix (pennies per month for this usage).
- **FlareSolverr:** Still pending from the arr-stack setup — unrelated to Research Brain but on the same VPS to-do list.

## Final thoughts

Building this app on top of the existing VPS stack forced real constraint-aware engineering: no extra containers on 2 GB RAM, build on the same machine you deploy to, use the API model list to figure out what's actually available before assuming the tutorial still applies.

The troubleshooting was the most educational part — blank pages, blank transcripts, SSE that doesn't stream, API models that 404. Each one had a specific, diagnosable cause and a specific fix. That's the part of infrastructure work that doesn't show up in tutorials, and it's the part that actually builds the skill.
