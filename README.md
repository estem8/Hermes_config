# Hermes Agent Stack — Windows 11 Automated Setup

One-command setup for a local AI-agent stack: **Hermes Gateway (Docker) + SearXNG + Mnemosyne + Hermes Desktop**.

Everything runs under Docker Desktop on Windows 11 and is managed by a single `docker-compose.yml` plus an idempotent `setup.ps1`.

## Quick Start

```powershell
# Interactive menu: status panel (Docker/API/Search/Memory) + actions
powershell -ExecutionPolicy Bypass -File setup.ps1

# Install with DeepSeek (skips menu, runs setup directly)
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -ApiKey "sk-..."

# Other providers
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Provider openrouter -Model "anthropic/claude-sonnet-4.6" -ApiKey "sk-or-..."
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Provider anthropic -Model "claude-sonnet-4.6" -ApiKey "sk-ant-..."
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Provider openai -Model "gpt-4o" -ApiKey "sk-..."
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Provider google -Model "gemini-2.5-pro" -ApiKey "AIza..."

# Preview without making changes
powershell -ExecutionPolicy Bypass -File setup.ps1 -DryRun

# Rebuild everything from scratch (clears checkpoint state + credentials)
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -ResetState -ApiKey "sk-..."
```

> **Interactive mode:** run `setup.ps1` without arguments to open a menu. A live status panel on top shows Docker / API / SearXNG / Mnemosyne as `[OK]`/`[FAIL]`, then choose:
> - **1. Install** — run the 6-step setup (status bar `[####------] 4/6`)
> - **2. Update** — `docker compose pull` + `hermes update` + restart
> - **3. Logs** — follow `docker compose logs -f`
> - **4. Exit**
>
> The final summary prints copy-paste links (dashboard, API, SearXNG, Mnemosyne) and Desktop connection settings.

## Supported Providers

| Provider    | Default Model                 | API Key Env            |
|-------------|-------------------------------|------------------------|
| `deepseek`  | `deepseek-chat`               | `DEEPSEEK_API_KEY`     |
| `openrouter`| `anthropic/claude-sonnet-4.6` | `OPENROUTER_API_KEY`   |
| `anthropic` | `claude-sonnet-4.6`           | `ANTHROPIC_API_KEY`    |
| `openai`    | `gpt-4o`                      | `OPENAI_API_KEY`       |
| `google`    | `gemini-2.5-pro`              | `GOOGLE_API_KEY`       |

## What Gets Installed

| Service        | Container        | Port(s)                        |
|----------------|------------------|--------------------------------|
| Hermes Gateway | `hermes`         | 8642 (API), 9119 (Dashboard)   |
| SearXNG        | `searxng-core`   | 127.0.0.1:8080 (search)        |
| SearXNG Cache  | `searxng-valkey` | — (internal)                   |
| Mnemosyne      | `mnemosyne`      | 127.0.0.1:8081 (MCP SSE)       |

All containers share the `hermes-net` network — no manual wiring needed.

## Features

- **Live status bar** — `[####------] 3/6 Containers` shows progress through the 6 setup steps
- **Copy-paste links** — final summary prints dashboard/API/SearXNG/Mnemosyne URLs and the Desktop connection settings (URL / user / pass) ready to copy
- **Dry-run**: `-DryRun` shows what would happen, changes nothing
- **Checkpoint/resume**: state lives in `.hermes-stack-state.json`; re-running picks up where it left off (crashes safe)
- **Reset**: `-ResetState` clears checkpoints + `credentials.txt` and rebuilds from scratch
- **Retry logic**: transient failures (downloads, Docker startup, compose up) retry with backoff
- **Multi-provider**: DeepSeek / OpenRouter / Anthropic / OpenAI / Google via one parameter
- **Unified compose**: `docker compose up -d` / `logs -f` / `down`

## File Structure

```
hermes-stack/
├── setup.ps1               # Main installer (status bar + links)
├── docker-compose.yml      # hermes + searxng + valkey + mnemosyne
├── Dockerfile.mnemosyne     # Mnemosyne image
├── searxng-settings.yml    # SearXNG config (secret placeholder → real value at setup)
├── .env                     # Stack env vars (MCP_TOKEN, ports) — NOT in git
├── .env.searxng            # SearXNG env — NOT in git
├── .gitignore
├── .gitattributes
├── README.md
├── credentials.txt          # Generated on first run (KEEP SAFE!)
└── .hermes-stack-state.json # Checkpoint state (auto-generated)
```

## Managing the Stack

```powershell
cd $env:USERPROFILE\hermes-stack

docker compose ps          # status
docker compose logs -f     # follow logs
docker compose restart     # restart all
docker compose down        # full stop
```

## Connecting Hermes Desktop

1. Launch **Hermes Desktop** from the Start Menu
2. Open **Settings → Gateway → Remote gateway**
3. Enter the values printed by the script:
   - **URL:** `http://localhost:9119`
   - **User:** `admin`
   - **Pass:** (from `credentials.txt`)
4. **Save and reconnect**

The desktop app talks to the gateway in Docker through `localhost:9119` — no extra configuration needed.

## After Setup

Your agent has:
- **Web search** via SearXNG (`web.search_backend=searxng`)
- **Persistent memory** via Mnemosyne (`memory.provider=mnemosyne`, MCP server)
- **Dashboard** on `http://localhost:9119` (basic auth)

## Updating

```powershell
cd $env:USERPROFILE\hermes-stack

# 1. Pull latest images (hermes, searxng, valkey) and recreate containers
docker compose pull
docker compose up -d

# 2. Update Hermes inside the container (self-updater)
docker exec hermes hermes update
docker restart hermes

# 3. Update this script/stack repo
git pull

# 4. Full rebuild from scratch (new configs, new secrets)
powershell -ExecutionPolicy Bypass -File setup.ps1 -ResetState -ApiKey "sk-..."
```

> `setup.ps1 -ResetState` regenerates dashboard password and MCP token — update `credentials.txt` afterwards.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Script stuck at step 3 ("compose up failed") | Ensure Docker Desktop is running, then re-run — checkpoints resume |
| `SearXNG -- HTTP 000` in verify step | Check `docker network connect searxng_default hermes` after manual container recreation |
| Wrong dashboard password | See `credentials.txt`; reset with `-ResetState` |
| Port 9119/8642 busy | Change ports in `.env` (`HERMES_DASHBOARD_PORT`, `HERMES_API_PORT`) then `docker compose up -d` |
