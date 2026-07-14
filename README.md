# JARVIS

Real-time person intelligence platform. Point smart glasses at someone, get a full dossier in seconds.

**Glasses camera → facial recognition → browser agent swarm → social enrichment → corkboard UI**

Built for the Web Agents Hackathon (Browser Use + YC).

## How It Works

1. **Capture** — Meta Ray-Ban glasses stream video frames to the backend (or upload a photo manually)
2. **Detect & Identify** — MediaPipe detects faces, ArcFace generates embeddings, PimEyes + reverse image search identifies the person
3. **Research** — A swarm of Browser Use agents fans out across LinkedIn, Twitter/X, Instagram, and Google in parallel. Exa API provides a fast-pass enrichment layer
4. **Synthesize** — Claude 3.5 Sonnet (or Gemini 2.0 Flash fallback) generates a structured dossier from all collected intel
5. **Display** — Results stream live to a military-themed corkboard UI with pushpins, red string connections, and real-time activity feed

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | FastAPI (Python 3.11+) |
| Frontend | Next.js 16, Framer Motion, Tailwind CSS |
| Real-time DB | Convex |
| Face Detection | MediaPipe |
| Face Embeddings | ArcFace (insightface) |
| Reverse Face Search | PimEyes, PicImageSearch |
| Browser Agents | Browser Use (cloud sessions) |
| Fast Search | Exa API |
| Twitter Scraping | twscrape |
| Synthesis | Anthropic Claude (primary), Google Gemini (fallback) |
| Observability | Laminar |
| Voice Commands | Gemini Flash transcription via WebSocket |

## Quick Start

### Prerequisites

- Python 3.11+
- Node.js 20+
- API keys (see [Environment Variables](#environment-variables))

### 1. Clone and set up environment

```bash
git clone <repo-url> && cd YC_hackathon
cp .env.example .env
# Fill in your API keys in .env
```

### 2. Backend

```bash
cd backend
uv sync
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

The backend starts even with missing API keys — features degrade gracefully. Check what's available:

```
GET http://localhost:8000/api/health
GET http://localhost:8000/api/services
```

### 3. Frontend

```bash
cd frontend
npm install
npm run dev
```

Opens at [http://localhost:3000](http://localhost:3000). The UI will show a "BACKEND OFFLINE" indicator if the backend isn't reachable.

### 4. Convex (real-time database)

```bash
cd frontend
npx convex dev
```

Convex is optional — the app works without it using in-memory storage, but you lose persistence and real-time sync across tabs.

## Environment Variables

Copy `.env.example` to `.env` and fill in what you have. Nothing is strictly required — the app degrades gracefully.

| Variable | Required For | Where to Get It |
|----------|-------------|-----------------|
| `NEXT_PUBLIC_CONVEX_URL` | Real-time DB | [convex.dev](https://convex.dev) |
| `EXA_API_KEY` | Fast person search | [exa.ai](https://exa.ai) |
| `BROWSER_USE_API_KEY` | Agent swarm (LinkedIn, Twitter, etc.) | [cloud.browser-use.com](https://cloud.browser-use.com/new-api-key) |
| `OPENAI_API_KEY` | Agent LLM backbone | [platform.openai.com](https://platform.openai.com) |
| `GEMINI_API_KEY` | Vision, synthesis fallback, voice | [ai.google.dev](https://ai.google.dev) |
| `ANTHROPIC_API_KEY` | Dossier synthesis (primary) | [console.anthropic.com](https://console.anthropic.com) |
| `CONVEX_URL` | Backend → Convex writes | Same Convex deployment |
| `MONGODB_URI` | Persistent storage | [mongodb.com/atlas](https://mongodb.com/atlas) |
| `TELEGRAM_BOT_TOKEN` | Telegram photo intake | [BotFather](https://t.me/BotFather) |
| `LAMINAR_API_KEY` | Agent tracing | [lmnr.ai](https://www.lmnr.ai) |
| `SUPERMEMORY_API_KEY` | Dossier caching | [supermemory.ai](https://supermemory.ai) |
| `PIMEYES_ACCOUNT_POOL` | Facial recognition search | JSON array of PimEyes accounts |

### Google-authenticated PimEyes session

The Identify Person flow uses the existing Google-authenticated PimEyes browser
session for `jonakfir@gmail.com`; it does not store or automate Google credentials.

1. Open an incognito/private browser window and sign in to
   [PimEyes](https://pimeyes.com) with **Continue with Google** for
   `jonakfir@gmail.com`.
2. Confirm that a PimEyes search succeeds manually in that browser session.
3. Using a trusted cookie-export extension, export only `pimeyes.com` cookies as
   JSON. Cookie-Editor list JSON and name/value dictionary JSON are supported.
4. Save the export at `backend/identification/pimeyes_cookies.json`.
5. Never commit, share, or paste this file into logs or documentation. It grants
   access to the authenticated PimEyes session and is ignored by Git.
6. Restart the backend after creating or replacing the file because the cookies
   are cached in memory.
7. If JARVIS reports expired or unauthorized cookies, repeat the export from a
   fresh authenticated session and restart the backend again.

`PIMEYES_EMAIL` and `PIMEYES_PASSWORD` cannot reproduce Continue with Google for
this account. Leave those values blank if they exist in a local environment; the
cookie file is the supported authentication path.

### Identify Person from a physical iPhone

Run the backend on all interfaces using the command above, then find the Mac's
Wi-Fi address with `ipconfig getifaddr en0` (`en1` may be used if `en0` is blank).
Set the iOS app backend URL to `http://<mac-ip>:8000`. On a signed physical iPhone,
the deliberate flow is: **Connect glasses → grant camera permission → Start Stream
→ obtain the person's consent → Identify person**. Normal stream frames send
`target: false`; only that explicit action sends one frame with `target: true`.
See [`ios/JarvisMetaBridge/README.md`](ios/JarvisMetaBridge/README.md) for signing,
Meta callback, and device setup details.

## Project Structure

```
backend/
├── agents/           # Browser Use agent swarm (LinkedIn, Twitter, Google, etc.)
├── capture/          # Camera input, frame extraction, Telegram bot
├── identification/   # Face detection, ArcFace embeddings, PimEyes search
├── enrichment/       # Exa API fast lookups, 6ixfour OSINT
├── synthesis/        # Claude/Gemini dossier generation
├── db/               # Convex client, in-memory fallback
├── memory/           # SuperMemory for dossier caching
├── observability/    # Laminar tracing
├── main.py           # FastAPI app & route handlers
├── pipeline.py       # CapturePipeline orchestrator
├── config.py         # Settings (pydantic-settings)
└── schemas.py        # Request/response models

frontend/
├── src/
│   ├── app/          # Next.js app router (single-page corkboard)
│   ├── components/   # IntelBoard, Corkboard, PersonCard, DossierView, etc.
│   ├── hooks/        # useResearchStream, useFrameCapture, useVoiceCommands
│   └── lib/          # Types, animations, utilities
├── convex/           # Schema, queries, mutations
└── e2e/              # Playwright tests
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/health` | Health check & configured services |
| `GET` | `/api/services` | Detailed service status |
| `POST` | `/api/capture` | Upload image for identification |
| `POST` | `/api/capture/frame` | Process video frame (real-time face detection) |
| `POST` | `/api/capture/identify` | Identify person by name + image |
| `GET` | `/api/research/{name}/stream` | SSE stream of research results |
| `GET` | `/api/person/{id}` | Get person dossier |
| `POST` | `/api/agents/research` | Spawn Browser Use sessions |
| `GET` | `/api/agents/sessions/{id}` | Poll session status |
| `WS` | `/ws/audio/{room}` | Audio transcription (glasses mic) |

## Development

```bash
# Backend tests
cd backend && pytest

# Frontend tests
cd frontend && npm test

# Type checking
cd frontend && npm run typecheck

# Linting
cd backend && ruff check .
cd frontend && npm run lint

# E2E tests
cd frontend && npm run test:e2e
```

## Architecture

The system is designed around graceful degradation. Each service is optional:

- **No Browser Use key?** Falls back to Exa-only research
- **No Exa key?** Returns a clear "configure API key" message
- **No Convex?** Uses in-memory storage
- **No Anthropic key?** Falls back to Gemini for synthesis
- **No Gemini key?** Skips synthesis, still returns raw research

The research pipeline streams results via Server-Sent Events so the UI updates incrementally as agents report back.

## Further Documentation

| Document | What's In It |
|----------|-------------|
| `SYSTEM_DESIGN.md` | Detailed component architecture, data flows, anti-bot strategies |
| `TECH_DOC.md` | Implementation guide, 6-phase build order, Convex schema details |
| `DESIGN_HANDOFF.md` | UI/UX specs, color system, typography, animation details |
| `ARCHITECTURE.md` | System overview diagrams, component deep-dives |
| `TASKS.md` | Build task checklist with acceptance criteria |
| `PRD.md` | Product requirements, success metrics, risk analysis |
