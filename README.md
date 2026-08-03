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

# Selective install — Hermes Gateway is always included; pick the optional components
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Components "searxng" -ApiKey "sk-..."
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Components "mnemosyne"
```

> **Interactive mode:** run `setup.ps1` without arguments to open a menu. A live status panel on top shows Docker / API / SearXNG / Mnemosyne as `[OK]`/`[FAIL]` (only for selected components), then choose:
> - **Setup:** **1. Install** — pick components (checkbox screen) then run the 6-step setup (status bar `[####------] 4/6`) · **2. Update** — `docker compose pull` + `hermes update` + restart
> - **Managing the Stack:** **3. Status** (`docker compose ps`) · **4. Logs** (`logs -f`) · **5. Start** (`up -d`) · **6. Restart** · **7. Stop** (`down`) · **8. Stats** (`docker stats`)
> - **0. Exit**
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

## Selective Install

The **Hermes Gateway is always installed** — it is the core of the stack (SearXNG and Mnemosyne are its search/memory backends). The selection applies to the optional components:

| Component | Compose profile | Services | Config/setup affected |
|-----------|-----------------|----------|------------------------|
| **Hermes Gateway** | *(always on, no profile)* | `hermes` | API key, `~/.hermes/.env`, `config.yaml`, Hermes Desktop, dashboard/API links |
| **SearXNG** | `searxng` | `searxng-core`, `searxng-valkey` | `web.search_backend=searxng`, `SEARXNG_URL`, `.env.searxng`, search link |
| **Mnemosyne** | `mnemosyne` | `mnemosyne` | `memory.provider=mnemosyne`, MCP token, plugin install, memory link |

Choose optional components (Hermes is added automatically):

```powershell
# CLI (non-interactive) — Hermes + SearXNG
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Components "searxng" -ApiKey "sk-..."

# Hermes + Mnemosyne (no web search)
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -Components "mnemosyne" -ApiKey "sk-..."

# Interactive: run setup.ps1 → [1] Install → toggle 2/3 ([x]/[ ]), Enter to continue
powershell -ExecutionPolicy Bypass -File setup.ps1
```

Passing `hermes` in `-Components` is allowed but has no effect — it is always included.

The selection is persisted in `./.env`:

- `STACK_COMPONENTS=hermes,searxng` — the chosen set (used by the menu/status panel)
- `COMPOSE_PROFILES=searxng` — enables the matching compose profiles, so **every** `docker compose` command (script, menu, or manual) automatically starts/manages only the selected services

> SearXNG/Mnemosyne start only when their profile is enabled (`COMPOSE_PROFILES`); `hermes` has no profile and is always part of `docker compose up -d`. Requires Docker Compose v2.20+ (ships with current Docker Desktop).
>
> Changing the selection after an install requires a clean rebuild (checkpointed steps would otherwise skip): `setup.ps1 -Install -ResetState -Components "<csv>"`.

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
├── specs/                   # SDD-спецификации + verify-specs.ps1
├── .env                     # Stack env vars (MCP_TOKEN, API_SERVER_KEY, ports) — NOT in git
├── .env.searxng            # SearXNG env — NOT in git
├── .gitignore
├── .gitattributes
├── README.md
├── credentials.txt          # Generated on first run (KEEP SAFE!)
└── .hermes-stack-state.json # Checkpoint state (auto-generated)
```

## Managing the Stack

Most commands below are also exposed in the interactive menu (`setup.ps1` → **Managing the Stack**).

```powershell
cd $env:USERPROFILE\hermes-stack

docker compose ps           # status
docker compose logs -f      # follow logs
docker compose restart      # restart all
docker compose down         # full stop (named volumes are kept)
docker compose up -d        # start all (e.g. after `down`)
```

> `docker compose up -d` / `ps` / `logs` respect `COMPOSE_PROFILES` from `./.env`, so a selective install manages exactly the installed services — no extra flags needed.

More useful commands:

```powershell
docker compose logs hermes          # logs of one service: hermes | searxng-core | searxng-valkey | mnemosyne
docker compose logs --tail=100      # last 100 lines without following
docker compose exec hermes sh       # interactive shell inside the Hermes container
docker compose build mnemosyne      # rebuild the local Mnemosyne image
docker stats                        # live CPU / memory usage (Ctrl+C to exit)
docker system df                    # disk usage of images / containers / volumes
docker system prune                 # clean up unused Docker data (read the prompt before confirming)
```

> `docker compose down` keeps your data: named volumes (`searxng-cache`, `valkey-data`, `mnemosyne-data`) survive. Use `docker compose down -v` only if you really want to wipe them.

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

# 1. Pull latest images and rebuild the local Mnemosyne image
docker compose pull
docker compose build mnemosyne
docker compose up -d

# 2. Update Hermes inside the container (self-updater)
docker exec hermes hermes update
docker restart hermes

# 3. Update this script/stack repo
git pull

# 4. Full rebuild from scratch (new configs, new secrets)
powershell -ExecutionPolicy Bypass -File setup.ps1 -ResetState -ApiKey "sk-..."

# Rebuild with a component selection (Hermes always included)
powershell -ExecutionPolicy Bypass -File setup.ps1 -Install -ResetState -Components "mnemosyne" -ApiKey "sk-..."
```

> `setup.ps1 -ResetState` regenerates dashboard password and MCP token — update `credentials.txt` afterwards.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Script stuck at step 3 ("compose up failed") | Ensure Docker Desktop is running, then re-run — checkpoints resume |
| `SearXNG -- HTTP 000` in verify step | Check `docker compose ps` (all 4 up) and `docker network inspect hermes-net`; re-run `docker compose up -d` |
| Wrong dashboard password | See `credentials.txt`; reset with `-ResetState` |
| Port 9119/8642 busy | Change ports in `.env` (`HERMES_DASHBOARD_PORT`, `HERMES_API_PORT`) then `docker compose up -d` |
