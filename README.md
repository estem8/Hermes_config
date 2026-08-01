# Hermes Agent Stack — Windows 11 Automated Setup

One-command setup for the complete AI agent stack on Windows 11:
**Docker Desktop + Hermes Gateway + SearXNG + Mnemosyne + Hermes Desktop**

## Quick Start

```powershell
# Download and run (PowerShell as Administrator recommended)
powershell -ExecutionPolicy Bypass -File setup.ps1 -DeepSeekApiKey "sk-your-key-here"
```

## What Gets Installed

| Component | Role | Port |
|---|---|---|
| **Hermes Gateway** | AI agent core + web dashboard | 8642 (API), 9119 (Dashboard) |
| **SearXNG** | Private metasearch engine | 8080 (internal) |
| **Mnemosyne** | Persistent memory backend | 8081 (internal) |
| **Hermes Desktop** | Native Windows app | Connected to localhost:9119 |

## Prerequisites

- Windows 11 (x64)
- Internet connection
- ~20 GB free disk space
- PowerShell 5.1+ (built-in)

## Parameters

| Parameter | Description | Default |
|---|---|---|
| `-DeepSeekApiKey` | DeepSeek API key (sk-...) | Prompted |
| `-InstallDir` | Root directory for project files | `%USERPROFILE%\hermes-stack` |
| `-Model` | LLM model | `deepseek-chat` |
| `-Provider` | LLM provider | `deepseek` |

## File Structure After Setup

```
%USERPROFILE%\
├── .hermes\              # Hermes config, sessions, skills, memory
│   ├── .env              # API keys + secrets
│   └── config.yaml       # Main configuration
├── hermes-stack\          # This project
│   ├── setup.ps1          # Main setup script
│   ├── credentials.txt    # Generated credentials (KEEP SAFE!)
│   ├── searxng\           # SearXNG docker-compose project
│   └── mnemosyne\         # Mnemosyne docker-compose project
```

## After Setup

1. Launch Hermes Desktop from Start Menu
2. Sign in with:
   - Username: `admin`
   - Password: see `credentials.txt`
3. Chat with your agent — it has web search (SearXNG) and persistent memory (Mnemosyne)

## Managing Containers

```powershell
# View all containers
docker ps

# View logs
docker logs hermes
docker logs searxng-core
docker logs mnemosyne

# Restart a service
docker restart hermes

# Full restart of all services
docker restart hermes searxng-core searxng-valkey mnemosyne
```

## Troubleshooting

| Problem | Solution |
|---|---|
| Docker not found | Install Docker Desktop manually from https://docker.com |
| Hermes API 401 | Check `%USERPROFILE%\.hermes\.env` — verify DEEPSEEK_API_KEY |
| SearXNG not working | `docker logs searxng-core` — check for search engine captchas |
| Memory not working | `docker exec hermes hermes memory status` |
| Desktop can't connect | Check `%APPDATA%\hermes\connection.json` has `localhost:9119` |
