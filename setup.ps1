<#
.SYNOPSIS
    Hermes Agent Stack — automated setup for Windows 11
    Docker Desktop + Hermes Gateway + SearXNG + Mnemosyne + Hermes Desktop

.DESCRIPTION
    One-command setup that installs and configures the complete AI agent stack:
      - Docker Desktop (if not present)
      - SearXNG (private metasearch engine, port 8080)
      - Mnemosyne (persistent memory backend, port 8081)
      - Hermes Gateway (dashboard + API, ports 8642/9119)
      - Hermes Desktop (native app, connected to gateway)
    All services run in Docker. Data persists in %USERPROFILE%\.hermes.

.PARAMETER DeepSeekApiKey
    Your DeepSeek API key (sk-...). Prompts interactively if not provided.

.PARAMETER InstallDir
    Root directory for project files. Default: %USERPROFILE%\hermes-stack

.PARAMETER Model
    Model to use. Default: deepseek-chat

.PARAMETER Provider
    LLM provider. Default: deepseek

.EXAMPLE
    .\setup.ps1 -DeepSeekApiKey "sk-abc123..."

.EXAMPLE
    .\setup.ps1 -Model "deepseek-v4-pro" -Provider "deepseek"

.NOTES
    Requires: Windows 11, PowerShell 5.1+, internet connection, ~20GB free disk
    Author: Automated setup script
#>

param(
    [string]$DeepSeekApiKey,
    [string]$InstallDir = "$env:USERPROFILE\hermes-stack",
    [string]$Model = "deepseek-chat",
    [string]$Provider = "deepseek"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ═══════════════════════════════════════════════════════════════════
#  COLORS & OUTPUT HELPERS
# ═══════════════════════════════════════════════════════════════════
function Write-Step { Write-Host "`n▶ $args" -ForegroundColor Cyan }
function Write-OK   { Write-Host "  ✓ $args" -ForegroundColor Green }
function Write-Warn { Write-Host "  ⚠ $args" -ForegroundColor Yellow }
function Write-Err  { Write-Host "  ✗ $args" -ForegroundColor Red; exit 1 }
function Write-Info { Write-Host "    $args" -ForegroundColor Gray }

# ═══════════════════════════════════════════════════════════════════
#  1. PREREQUISITES
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 1: Checking prerequisites"

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn "Not running as Administrator. Docker Desktop install may require admin rights."
    Write-Info "Re-run: powershell -ExecutionPolicy Bypass -File setup.ps1"
}

# Docker check
$dockerVersion = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $dockerVersion) {
    Write-Warn "Docker not found. Installing Docker Desktop..."
    Write-Info "Downloading Docker Desktop installer..."
    $dockerInstaller = "$env:TEMP\DockerDesktopInstaller.exe"
    Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -OutFile $dockerInstaller
    Write-Info "Running installer (this requires admin and may prompt UAC)..."
    Start-Process -FilePath $dockerInstaller -ArgumentList "install --quiet --accept-license" -Wait -Verb RunAs
    Write-Info "Docker Desktop installed. You may need to log out and back in, or start it manually."
    Write-Info "After Docker is running, re-run this script."
    exit 0
}
Write-OK "Docker found: $dockerVersion"

# Docker running?
$dockerRunning = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Docker daemon is not running. Starting Docker Desktop..."
    Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    Write-Info "Waiting for Docker to start (up to 60s)..."
    for ($i = 1; $i -le 12; $i++) {
        Start-Sleep 5
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
    }
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "Docker failed to start. Please start Docker Desktop manually and re-run." }
}
Write-OK "Docker daemon is running"

# API Key
if (-not $DeepSeekApiKey) {
    $DeepSeekApiKey = Read-Host "Enter your DeepSeek API key (sk-...)"
}
if (-not $DeepSeekApiKey.StartsWith("sk-")) {
    Write-Warn "API key doesn't start with 'sk-'. Make sure it's correct."
}

# ═══════════════════════════════════════════════════════════════════
#  2. CREATE DIRECTORIES & SECRETS
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 2: Creating directories and generating secrets"

$dotHermesDir = "$env:USERPROFILE\.hermes"
$searxngDir  = "$InstallDir\searxng"
$mnemosyneDir = "$InstallDir\mnemosyne"

foreach ($d in @($dotHermesDir, $searxngDir, "$searxngDir\core-config", $mnemosyneDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Write-OK "Directories created"

# Generate secrets
$dashboardPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
$dashboardSecret   = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 44 | ForEach-Object { [char]$_ }) + "=="
$mcpToken          = -join ((48..57) + (65..70) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
$searxngSecret     = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
$apiServerKey      = -join ((48..57) + (65..70) | Get-Random -Count 32 | ForEach-Object { [char]$_ })

Write-OK "Secrets generated"
Write-Info "Dashboard password: $dashboardPassword (save this!)"

# ═══════════════════════════════════════════════════════════════════
#  3. WRITE CONFIG FILES
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 3: Writing configuration files"

# --- Hermes .env ---
@"
DEEPSEEK_API_KEY=$DeepSeekApiKey
SEARXNG_URL=http://searxng-core:8080
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$dashboardPassword
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$dashboardSecret
API_SERVER_KEY=$apiServerKey
"@ | Out-File -Encoding utf8NoBOM -FilePath "$dotHermesDir\.env"
Write-OK "Hermes .env written"

# --- Hermes config.yaml ---
@"
model:
  default: $Provider/$Model
  provider: $Provider
  base_url: ""
web:
  search_backend: searxng
memory:
  memory_enabled: true
  provider: "mnemosyne"
terminal:
  backend: local
approvals:
  mode: smart
display:
  language: ru
  show_cost: true
"@ | Out-File -Encoding utf8NoBOM -FilePath "$dotHermesDir\config.yaml"
Write-OK "Hermes config.yaml written"

# --- SearXNG settings.yml ---
@"
use_default_settings: true

server:
  secret_key: "$searxngSecret"
  image_proxy: true

search:
  formats:
    - html
    - json
    - csv
    - rss
"@ | Out-File -Encoding utf8NoBOM -FilePath "$searxngDir\core-config\settings.yml"
Write-OK "SearXNG settings.yml written"

# --- SearXNG .env ---
@"
SEARXNG_HOST=127.0.0.1
SEARXNG_PORT=8080
"@ | Out-File -Encoding utf8NoBOM -FilePath "$searxngDir\.env"
Write-OK "SearXNG .env written"

# --- SearXNG docker-compose.yml ---
@"
name: searxng

services:
  core:
    container_name: searxng-core
    image: docker.io/searxng/searxng:latest
    restart: always
    ports:
      - "127.0.0.1:8080:8080"
    env_file: ./.env
    volumes:
      - ./core-config/:/etc/searxng/:Z
      - core-data:/var/cache/searxng/

  valkey:
    container_name: searxng-valkey
    image: docker.io/valkey/valkey:9-alpine
    command: valkey-server --save 30 1 --loglevel warning
    restart: always
    volumes:
      - valkey-data:/data/

volumes:
  core-data:
  valkey-data:
"@ | Out-File -Encoding utf8NoBOM -FilePath "$searxngDir\docker-compose.yml"
Write-OK "SearXNG docker-compose.yml written"

# --- Mnemosyne Dockerfile ---
@"
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir "mnemosyne-memory[mcp]"
RUN apt-get update && apt-get install -y sqlite3 curl && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /data

EXPOSE 8080

ENV MNEMOSYNE_DATA_DIR=/data
ENV MNEMOSYNE_MCP_TOKEN=

CMD ["python", "-m", "mnemosyne.mcp_server", "--transport", "sse", "--host", "0.0.0.0", "--port", "8080"]
"@ | Out-File -Encoding utf8NoBOM -FilePath "$mnemosyneDir\Dockerfile"
Write-OK "Mnemosyne Dockerfile written"

# --- Mnemosyne .env ---
"MCP_TOKEN=$mcpToken" | Out-File -Encoding utf8NoBOM -FilePath "$mnemosyneDir\.env"
Write-OK "Mnemosyne .env written"

# --- Mnemosyne docker-compose.yml ---
@"
services:
  mnemosyne:
    build: .
    container_name: mnemosyne
    ports:
      - "127.0.0.1:8081:8080"
    volumes:
      - mnemosyne-data:/data
    environment:
      - MNEMOSYNE_DATA_DIR=/data
      - MNEMOSYNE_MCP_TOKEN=${MCP_TOKEN}
    restart: unless-stopped
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -s -o /dev/null --max-time 3 http://localhost:8080/sse || [ $$? -eq 28 ] || exit 1",
        ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

volumes:
  mnemosyne-data:
"@ | Out-File -Encoding utf8NoBOM -FilePath "$mnemosyneDir\docker-compose.yml"
Write-OK "Mnemosyne docker-compose.yml written"

# ═══════════════════════════════════════════════════════════════════
#  4. LAUNCH DOCKER CONTAINERS
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 4: Launching SearXNG and Mnemosyne"

# Launch SearXNG
Push-Location $searxngDir
try {
    Write-Info "Pulling and starting SearXNG..."
    docker compose up -d 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker compose failed" }
    Write-OK "SearXNG started"
} finally { Pop-Location }

# Launch Mnemosyne
Push-Location $mnemosyneDir
try {
    Write-Info "Building and starting Mnemosyne (this may take 2-5 minutes)..."
    docker compose build 2>&1 | Out-Null
    docker compose up -d 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker compose failed" }
    Write-OK "Mnemosyne started"
} finally { Pop-Location }

# Launch Hermes gateway
Write-Info "Starting Hermes Gateway container..."
# Stop existing hermes container if any
docker rm -f hermes 2>&1 | Out-Null

docker run -d --name hermes `
  --restart unless-stopped `
  --memory=4g --cpus=2 `
  -v "${dotHermesDir}:/opt/data" `
  -p 8642:8642 -p 9119:9119 `
  -e HERMES_DASHBOARD=1 `
  nousresearch/hermes-agent gateway run 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Err "Hermes container failed to start" }
Write-OK "Hermes Gateway started"

# ═══════════════════════════════════════════════════════════════════
#  5. CONNECT NETWORKS
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 5: Connecting Docker networks"

# Wait for containers to be ready
Write-Info "Waiting for containers to initialize..."
Start-Sleep 12

# Connect hermes to searxng network
docker network connect searxng_default hermes 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Could not connect hermes to searxng_default. SearXNG may already be connected."
} else {
    Write-OK "Hermes connected to searxng_default"
}

# Connect mnemosyne to searxng network for hermes access
docker network connect searxng_default mnemosyne 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Could not connect mnemosyne to searxng_default."
} else {
    Write-OK "Mnemosyne connected to searxng_default"
}

# ═══════════════════════════════════════════════════════════════════
#  6. INSTALL MNEMOSYNE PLUGIN IN HERMES
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 6: Installing Mnemosyne plugin in Hermes"

Write-Info "Installing mnemosyne-hermes package (this may take 2-3 minutes)..."
docker exec hermes uv pip install --python /opt/hermes/.venv/bin/python mnemosyne-hermes 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Err "Mnemosyne package install failed" }

# Copy plugin files
docker exec hermes bash -c "cp -r /opt/hermes/.venv/lib/python3.13/site-packages/mnemosyne_hermes/* /opt/data/plugins/mnemosyne/" 2>&1 | Out-Null

# Configure memory provider
docker exec hermes hermes config set memory.provider mnemosyne 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warn "Could not set memory.provider" }

Write-OK "Mnemosyne plugin installed"

# Restart hermes to pick up changes
Write-Info "Restarting Hermes to apply changes..."
docker restart hermes 2>&1 | Out-Null
Start-Sleep 10

# Reconnect network after restart
docker network connect searxng_default hermes 2>&1 | Out-Null

# ═══════════════════════════════════════════════════════════════════
#  7. VERIFY CONTAINERS
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 7: Verifying containers"

$containers = docker ps --format "{{.Names}}" | Out-String
$expected = @("hermes", "searxng-core", "searxng-valkey", "mnemosyne")
foreach ($c in $expected) {
    if ($containers -match $c) { Write-OK "$c is running" }
    else { Write-Warn "$c is NOT running — check docker logs $c" }
}

# Verify hermes gateway
try {
    $status = Invoke-RestMethod -Uri "http://localhost:9119/api/status" `
        -Headers @{Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$dashboardPassword"))} `
        -TimeoutSec 10 -ErrorAction Stop
    Write-OK "Hermes Gateway API: OK (v$($status.version))"
} catch {
    Write-Warn "Hermes API check failed: $_"
}

# ═══════════════════════════════════════════════════════════════════
#  8. INSTALL HERMES DESKTOP
# ═══════════════════════════════════════════════════════════════════
Write-Step "STEP 8: Setting up Hermes Desktop"

$desktopRoamingDir = "$env:APPDATA\hermes"
$hermesSetupExe  = "$dotHermesDir\hermes-setup.exe"
$hermesInstalled = Test-Path "$env:LOCALAPPDATA\hermes\hermes-agent\apps\desktop"

if (-not $hermesInstalled) {
    Write-Info "Downloading Hermes Desktop installer..."
    
    if (-not (Test-Path $hermesSetupExe)) {
        Invoke-WebRequest -Uri "https://hermes-agent.nousresearch.com/api/desktop/download/windows" `
            -OutFile $hermesSetupExe -ErrorAction Stop
    }
    
    Write-Info "Running Hermes Desktop installer..."
    Start-Process -FilePath $hermesSetupExe -ArgumentList "--silent" -Wait
    Write-OK "Hermes Desktop installed"
} else {
    Write-OK "Hermes Desktop already installed"
}

# Configure Desktop connection to remote gateway
Write-Info "Configuring Desktop connection to gateway..."
$connectionJson = @{
    mode = "remote"
    remote = @{
        url = "http://localhost:9119"
        authMode = "basic"
    }
    profiles = @{}
}

New-Item -ItemType Directory -Force -Path $desktopRoamingDir | Out-Null
$connectionJson | ConvertTo-Json -Depth 3 | Out-File -Encoding utf8NoBOM -FilePath "$desktopRoamingDir\connection.json"
Write-OK "Desktop connection configured → http://localhost:9119"

# ═══════════════════════════════════════════════════════════════════
#  9. SUMMARY
# ═══════════════════════════════════════════════════════════════════
Write-Step "DONE — Hermes Agent Stack is ready!"

Write-Host @"

╔══════════════════════════════════════════════════════════════╗
║              Hermes Agent Stack — Status                    ║
╠══════════════════════════════════════════════════════════════╣
║                                                            ║
║  Containers (docker ps):                                    ║
║    hermes           — Gateway + Dashboard (ports 8642,9119) ║
║    searxng-core     — Private search engine (port 8080)     ║
║    searxng-valkey   — Search cache                          ║
║    mnemosyne        — Memory backend (port 8081)           ║
║                                                            ║
║  Access:                                                    ║
║    Dashboard:  http://localhost:9119                        ║
║    Credentials: admin / $dashboardPassword              ║
║                                                            ║
║  Hermes Desktop:                                            ║
║    Installed and configured for http://localhost:9119       ║
║    Sign in with: admin / $dashboardPassword              ║
║                                                            ║
║  Files:                                                     ║
║    Configs: $dotHermesDir                       ║
║    SearXNG: $searxngDir                           ║
║    Mnemosyne: $mnemosyneDir                      ║
║                                                            ║
╚══════════════════════════════════════════════════════════════╝

  To launch Hermes Desktop:
    Start-Process "$env:LOCALAPPDATA\hermes\hermes-agent\apps\desktop\Hermes Agent.exe"

  Or just search "Hermes" in the Start Menu.

"@

# Save credentials to a file for reference
@"
=== Hermes Agent Stack — Credentials ===
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")

Dashboard:
  URL:      http://localhost:9119
  Username: admin
  Password: $dashboardPassword

API Server Key: $apiServerKey
Mnemosyne MCP Token: $mcpToken
SearXNG Secret: $searxngSecret
DeepSeek API Key: ${DeepSeekApiKey}: sk-...$($DeepSeekApiKey.Substring($DeepSeekApiKey.Length - 4))

Save this file in a secure location!
"@ | Out-File -Encoding utf8NoBOM -FilePath "$InstallDir\credentials.txt"

Write-Host "  Credentials saved to: $InstallDir\credentials.txt" -ForegroundColor Yellow
Write-Host "  ⚠ KEEP THIS FILE SAFE — it contains your passwords!" -ForegroundColor Yellow
