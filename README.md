# Hermes Agent Stack v2 — Windows 11 Automated Setup

One-command setup: **Docker Desktop + Hermes Gateway + SearXNG + Mnemosyne + Hermes Desktop**

## Quick Start

```powershell
# DeepSeek (default)
powershell -ExecutionPolicy Bypass -File setup.ps1 -ApiKey "sk-..."

# OpenRouter
powershell -ExecutionPolicy Bypass -File setup.ps1 -Provider openrouter -Model "anthropic/claude-sonnet-4.6" -ApiKey "sk-or-..."

# Anthropic
powershell -ExecutionPolicy Bypass -File setup.ps1 -Provider anthropic -Model "claude-sonnet-4.6" -ApiKey "sk-ant-..."

# Preview without installing
powershell -ExecutionPolicy Bypass -File setup.ps1 -DryRun
```

## Supported Providers

| Provider    | Default Model                 | API Key Env            |
|-------------|-------------------------------|------------------------|
| `deepseek`  | `deepseek-chat`               | `DEEPSEEK_API_KEY`     |
| `openrouter`| `anthropic/claude-sonnet-4.6` | `OPENROUTER_API_KEY`   |
| `anthropic` | `claude-sonnet-4.6`           | `ANTHROPIC_API_KEY`    |
| `openai`    | `gpt-4o`                      | `OPENAI_API_KEY`       |
| `google`    | `gemini-2.5-pro`              | `GOOGLE_API_KEY`       |

## What Gets Installed

| Service         | Container          | Port(s)            |
|-----------------|--------------------|--------------------|
| Hermes Gateway  | `hermes`           | 8642 (API), 9119 (Dashboard) |
| SearXNG         | `searxng-core`     | 127.0.0.1:8080     |
| SearXNG Cache   | `searxng-valkey`   | —                  |
| Mnemosyne       | `mnemosyne`        | 127.0.0.1:8081     |

All containers share `hermes-net` — no manual network wiring needed.

## Features

- **Dry-run**: `-DryRun` shows what will happen without changes
- **Checkpoint/resume**: survives crashes — re-running picks up where it left off
- **Retry logic**: transient failures (download, Docker startup) retry up to 3x
- **Unified compose**: `docker compose up -d` / `docker compose logs -f` / `docker compose down`

## File Structure

```
hermes-stack/
├── setup.ps1               # Main installer
├── docker-compose.yml      # All services
├── Dockerfile.mnemosyne     # Mnemosyne image
├── searxng-settings.yml    # SearXNG config
├── .env                     # Stack env vars (MCP_TOKEN, ports)
├── .env.searxng            # SearXNG env
├── .gitignore
├── .gitattributes
├── README.md
├── credentials.txt          # Generated (KEEP SAFE!)
└── .hermes-stack-state.json # Checkpoint state (auto-generated)
```

## Managing

```powershell
cd $env:USERPROFILE\hermes-stack

# View status
docker compose ps

# View logs
docker compose logs -f

# Restart all
docker compose restart

# Full stop
docker compose down
```

## After Setup

1. Launch **Hermes Desktop** from Start Menu
2. Sign in: `admin` / password from `credentials.txt`
3. Your agent has web search (SearXNG) + persistent memory (Mnemosyne)
