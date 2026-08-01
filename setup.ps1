<#
.SYNOPSIS
    Hermes Agent Stack v2 -- automated setup for Windows 11
    Docker Desktop + Hermes Gateway + SearXNG + Mnemosyne + Hermes Desktop

.DESCRIPTION
    One-command setup. Features:
      - Dry-run mode (-DryRun)
      - Checkpoint/resume (survives crashes)
      - Multi-provider: DeepSeek, OpenRouter, Anthropic, OpenAI, Google
      - Unified docker-compose with shared network
      - Health verification at every step

.PARAMETER Provider
    LLM provider: deepseek (default), openrouter, anthropic, openai, google

.PARAMETER Model
    Model name. Default depends on provider.

.PARAMETER ApiKey
    API key for the selected provider. Prompts if not given.

.PARAMETER DryRun
    Show what would be installed without making changes.

.PARAMETER InstallDir
    Root directory. Default: %USERPROFILE%\hermes-stack

.EXAMPLE
    .\setup.ps1 -Provider deepseek -ApiKey "sk-abc..."
    .\setup.ps1 -Provider openrouter -Model "anthropic/claude-sonnet-4.6" -ApiKey "sk-or-..."
    .\setup.ps1 -DryRun
#>

param(
    [ValidateSet("deepseek","openrouter","anthropic","openai","google")]
    [string]$Provider = "deepseek",

    [string]$Model,

    [string]$ApiKey,

    [switch]$DryRun,

    [switch]$ResetState,

    [string]$InstallDir = "$env:USERPROFILE\hermes-stack"
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Force TLS 1.2 for PowerShell 5.1 compatibility
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ═══════════════════════════════════════════
# CONFIG: provider defaults
# ═══════════════════════════════════════════
$ProviderConfig = @{
    deepseek   = @{ defaultModel="deepseek-chat";            envKey="DEEPSEEK_API_KEY";    baseUrl="" }
    openrouter = @{ defaultModel="anthropic/claude-sonnet-4.6"; envKey="OPENROUTER_API_KEY"; baseUrl="https://openrouter.ai/api/v1" }
    anthropic  = @{ defaultModel="claude-sonnet-4.6";         envKey="ANTHROPIC_API_KEY";   baseUrl="" }
    openai     = @{ defaultModel="gpt-4o";                    envKey="OPENAI_API_KEY";      baseUrl="" }
    google     = @{ defaultModel="gemini-2.5-pro";            envKey="GOOGLE_API_KEY";      baseUrl="" }
}
$cfg = $ProviderConfig[$Provider]
if (-not $Model) { $Model = $cfg.defaultModel }

# ═══════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════
function Write-Step ($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "   OK  $msg" -ForegroundColor Green }
function Write-WARN ($msg) { Write-Host "   WARN $msg" -ForegroundColor Yellow }
function Write-ERR  ($msg) { Write-Host "   ERR $msg" -ForegroundColor Red }
function Write-INFO ($msg) { Write-Host "   $msg" -ForegroundColor Gray }

# ── Status bar ────────────────────────────────────────────
$StepNames = @("Prerequisites", "Directories & secrets", "Containers", "Mnemosyne plugin", "Verify health", "Hermes Desktop")
$StepTotal = $StepNames.Count
$StepCurrent = 0

function Write-StatusBar {
    # ASCII progress bar: [####------] 2/6 Prerequisites
    $script:StepCurrent++
    $idx = $StepCurrent - 1
    $w = 24
    $filled = [Math]::Floor($StepCurrent * $w / $StepTotal)
    $bar = "[" + ("#" * $filled) + ("-" * ($w - $filled)) + "]"
    $label = if ($idx -lt $StepNames.Count) { $StepNames[$idx] } else { "" }
    Write-Host ""
    Write-Host "  $bar  $StepCurrent/$StepTotal $label" -ForegroundColor Cyan
}

# Retry a scriptblock up to $max times with $delay seconds between
function Invoke-Retry([ScriptBlock]$Script, [int]$Max=3, [int]$Delay=5, [string]$Desc="") {
    for ($i=1; $i -le $Max; $i++) {
        try {
            if ($DryRun) { Write-INFO "[dry-run] would: $Desc"; return $true }
            & $Script
            return $true
        } catch {
            Write-WARN "$Desc -- attempt $i/$Max failed: $_"
            if ($i -lt $Max) { Start-Sleep $Delay }
        }
    }
    throw "$Desc -- all $Max attempts failed"
}

# Helper: write UTF-8 without BOM (works on PS 5.1 and 7+)
function Write-File {
    param(
        [Parameter(Mandatory, Position=0)] [string]$Path,
        [Parameter(ValueFromPipeline, Position=1)] [string]$Content
    )
    begin { $sb = New-Object System.Text.StringBuilder }
    process { [void]$sb.AppendLine($Content) }
    end {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Path, $sb.ToString().TrimEnd("`r`n"), $utf8NoBom)
    }
}

# Checkpoint state management
$StateFile = "$InstallDir\.hermes-stack-state.json"
function Get-State {
    if (Test-Path $StateFile) {
        try { return Get-Content $StateFile -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { }
    }
    return @{ completed=@(); provider=$Provider; model=$Model; installedAt=$null }
}
function Set-State($step) {
    if ($DryRun) { return }
    $s = Get-State
    if ($step -notin $s.completed) { $s.completed += $step }
    $s | ConvertTo-Json -Depth 3 | ForEach-Object { Write-File $StateFile $_ }
}
function Is-Completed($step) {
    if ($ResetState) { return $false }
    $s = Get-State
    return $step -in $s.completed
}

# ═══════════════════════════════════════════
# RESET STATE
# ═══════════════════════════════════════════
if ($ResetState) {
    Write-WARN "Resetting checkpoint state -- all steps will re-run"
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    Remove-Item "$InstallDir\credentials.txt" -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════
# DRY-RUN
# ═══════════════════════════════════════════
if ($DryRun) {
    Write-Host "=== DRY RUN -- no changes will be made ===" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Provider:   $Provider"
    Write-Host "Model:      $Model"
    Write-Host "InstallDir: $InstallDir"
    Write-Host "API key:    $($ApiKey.Substring(0,[Math]::Min(8,$ApiKey.Length)))..."
    Write-Host ""
    Write-Host "Will install/verify:"
    Write-Host "  1. Docker Desktop"
    Write-Host "  2. Docker containers (hermes, searxng-core, searxng-valkey, mnemosyne)"
    Write-Host "  3. Hermes configuration (~/.hermes/config.yaml)"
    Write-Host "  4. Mnemosyne plugin in Hermes"
    Write-Host "  5. Hermes Desktop + connection.json"
    Write-Host ""
    Write-Host "Ports: 8642 (API), 9119 (dashboard), 8080 (search), 8081 (memory)"
    exit 0
}

# ═══════════════════════════════════════════
# STEP 1: PREREQUISITES
# ═══════════════════════════════════════════
$step = "prerequisites"
Write-StatusBar
if (Is-Completed $step) { Write-OK "Step '$step' already done -- skipping" }
else {
    Write-Step "STEP 1: Prerequisites"

    # Admin check
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(2)
    if (-not $isAdmin) { Write-WARN "Not admin. Docker install may need UAC approval." }

    # Docker
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-WARN "Docker not found. Installing Docker Desktop..."
        $di = "$env:TEMP\DockerDesktopInstaller.exe"
        Invoke-Retry -Script { Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -OutFile $di } -Max 2 -Desc "Download Docker"
        Start-Process -FilePath $di -ArgumentList "install --quiet --accept-license" -Wait -Verb RunAs
        Write-INFO "Docker installed. Log out/in or start Docker Desktop, then re-run."
        exit 0
    }
    Write-OK "Docker found"

    # Docker daemon
    Invoke-Retry -Script {
        $r = docker info 2>&1; if ($LASTEXITCODE -ne 0) { throw "Docker not running" }
    } -Max 6 -Delay 10 -Desc "Wait for Docker daemon"
    Write-OK "Docker daemon running"

    # API key
    if (-not $ApiKey) { $ApiKey = Read-Host "Enter $Provider API key" }
    if ($ApiKey.Length -lt 10) { Write-WARN "API key looks too short -- verify it" }

    Set-State $step
}

# ═══════════════════════════════════════════
# STEP 2: DIRECTORIES & SECRETS
# ═══════════════════════════════════════════
$step = "directories"
Write-StatusBar
if (Is-Completed $step) { Write-OK "Step '$step' already done -- skipping" }
else {
    Write-Step "STEP 2: Directories & secrets"

    $dotHermes = "$env:USERPROFILE\.hermes"
    foreach ($d in @($InstallDir, $dotHermes)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Write-OK "Directories created"

    # Generate secrets
    $dashPass  = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | %{[char]$_})
    $dashSec   = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 44 | %{[char]$_}) + "=="
    $mcpTok    = -join ((48..57)+(65..70) | Get-Random -Count 64 | %{[char]$_})
    $searxngSec = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | %{[char]$_})

    # Write Hermes .env
    @"
$($cfg.envKey)=$ApiKey
SEARXNG_URL=http://searxng-core:8080
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$dashPass
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$dashSec
"@ | Write-File "$dotHermes\.env"
    Write-OK "Hermes .env"

    # Write Hermes config.yaml
    $baseUrlLine = if ($cfg.baseUrl) { "  base_url: `"$($cfg.baseUrl)`"" } else { "  base_url: `"`"" }
    @"
model:
  default: $Provider/$Model
  provider: $Provider
$baseUrlLine
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
"@ | Write-File "$dotHermes\config.yaml"
    Write-OK "Hermes config.yaml"

    # Write stack .env for docker-compose
    @"
MNEMOSYNE_MCP_TOKEN=$mcpTok
HERMES_API_PORT=8642
HERMES_DASHBOARD_PORT=9119
SEARXNG_HOST=127.0.0.1
SEARXNG_PORT=8080
MNEMOSYNE_PORT=127.0.0.1:8081
"@ | Write-File "$InstallDir\.env"
    Write-OK "Stack .env"

    # SearXNG env
    @"
SEARXNG_HOST=127.0.0.1
SEARXNG_PORT=8080
"@ | Write-File "$InstallDir\.env.searxng"
    Write-OK "SearXNG env"

    # Fix searxng-settings.yml with real secret
    (Get-Content "$InstallDir\searxng-settings.yml" -Raw) -replace '\$SEARXNG_SECRET_PLACEHOLDER', $searxngSec |
        Write-File "$InstallDir\searxng-settings.yml"
    Write-OK "SearXNG settings"

    # Save credentials
    @"
=== Hermes Agent Stack -- Credentials ===
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")

Dashboard: http://localhost:9119
  Username: admin
  Password: $dashPass

Mnemosyne MCP Token: $mcpTok
SearXNG Secret: $searxngSec
$Provider API Key: $($ApiKey.Substring(0,[Math]::Min(6,$ApiKey.Length)))...

Save this file in a secure location!
"@ | Write-File "$InstallDir\credentials.txt"

    Set-State $step
}

# ═══════════════════════════════════════════
# STEP 3: COMPOSE UP
# ═══════════════════════════════════════════
$step = "containers"
Write-StatusBar
if (Is-Completed $step) { Write-OK "Step '$step' already done -- skipping" }
else {
    Write-Step "STEP 3: Launching containers (docker compose up)"

    Push-Location $InstallDir
    try {
        # Clean up any previous containers (both old standalone and compose)
        docker compose down --remove-orphans 2>&1 | Out-Null
        docker rm -f hermes searxng-core searxng-valkey mnemosyne 2>&1 | Out-Null

        Invoke-Retry -Script {
            docker compose build mnemosyne 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "build failed" }
        } -Max 2 -Desc "Build Mnemosyne"

        Invoke-Retry -Script {
            docker compose up -d 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "compose up failed" }
        } -Max 3 -Delay 8 -Desc "docker compose up -d"

        Write-OK "All containers launched"
    } finally { Pop-Location }

    # Wait and verify
    Start-Sleep 10
    $expected = @("hermes","searxng-core","searxng-valkey","mnemosyne")
    foreach ($c in $expected) {
        $running = docker ps --filter "name=$c" --format "{{.Names}}" 2>&1
        if ($running -eq $c) { Write-OK "$c running" }
        else { Write-WARN "$c not running -- check: docker logs $c" }
    }

    Set-State $step
}

# ═══════════════════════════════════════════
# STEP 4: MNEMOSYNE PLUGIN
# ═══════════════════════════════════════════
$step = "plugin"
Write-StatusBar
if (Is-Completed $step) { Write-OK "Step '$step' already done -- skipping" }
else {
    Write-Step "STEP 4: Installing Mnemosyne plugin"

    Invoke-Retry -Script {
        docker exec hermes uv pip install --python /opt/hermes/.venv/bin/python mnemosyne-hermes 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
    } -Max 3 -Delay 8 -Desc "Install mnemosyne-hermes"

    docker exec hermes bash -c "cp -r /opt/hermes/.venv/lib/python3.13/site-packages/mnemosyne_hermes/* /opt/data/plugins/mnemosyne/" 2>&1 | Out-Null
    docker exec hermes hermes config set memory.provider mnemosyne 2>&1 | Out-Null

    docker restart hermes 2>&1 | Out-Null
    Start-Sleep 8
    Write-OK "Plugin installed, Hermes restarted"

    Set-State $step
}

# ═══════════════════════════════════════════
# STEP 5: VERIFY
# ═══════════════════════════════════════════
$step = "verify"
Write-StatusBar
if (Is-Completed $step) { Write-OK "Step '$step' already done -- skipping" }
else {
    Write-Step "STEP 5: Verifying stack health"

    # Hermes API (retry — gateway may still be initializing)
    try {
        $usr = "admin"; $pw = $dashPass
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$usr`:$pw"))
        $r = $null
        for ($i=1; $i -le 5; $i++) {
            try {
                $r = Invoke-RestMethod -Uri "http://localhost:9119/api/status" -Headers @{Authorization="Basic $b64"} -TimeoutSec 10
                break
            } catch { if ($i -ge 5) { throw $_ }; Start-Sleep 3 }
        }
        Write-OK "Hermes API v$($r.version) -- OK"
    } catch { Write-ERR "Hermes API: $_" }

    # SearXNG
    try {
        $r = Invoke-WebRequest -Uri 'http://localhost:8080/search?q=test&format=json' -TimeoutSec 10 -UseBasicParsing
        Write-OK "SearXNG -- HTTP $($r.StatusCode)"
    } catch { Write-WARN "SearXNG: $_" }

    # Mnemosyne
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8081/sse" -TimeoutSec 5 -UseBasicParsing -Headers @{Authorization="Bearer $mcpTok"}
        Write-OK "Mnemosyne -- HTTP $($r.StatusCode)"
    } catch { Write-WARN "Mnemosyne: $_" }

    # Memory provider
    $memStatus = docker exec hermes hermes memory status 2>&1
    if ($memStatus -match "mnemosyne.*active") { Write-OK "Memory provider: mnemosyne active" }
    else { Write-WARN "Memory provider may not be active" }

    Set-State $step
}

# ═══════════════════════════════════════════
# STEP 6: DESKTOP
# ═══════════════════════════════════════════
$step = "desktop"
Write-StatusBar
if (Is-Completed $step) { Write-OK "Step '$step' already done -- skipping" }
else {
    Write-Step "STEP 6: Hermes Desktop"

    $setupExe = "$InstallDir\hermes-setup.exe"
    $installed = Test-Path "$env:LOCALAPPDATA\hermes\hermes-agent\apps\desktop"

    if (-not $installed) {
        Invoke-Retry -Script {
            Invoke-WebRequest -Uri "https://hermes-agent.nousresearch.com/api/desktop/download/windows" -OutFile $setupExe
        } -Max 2 -Desc "Download installer"
        Start-Process -FilePath $setupExe -ArgumentList "--silent" -Wait
        Write-OK "Desktop installed"
    } else { Write-OK "Desktop already installed" }

    # Connection config
    $connDir = "$env:APPDATA\hermes"
    New-Item -ItemType Directory -Force -Path $connDir | Out-Null
    @{
        mode = "remote"
        remote = @{ url = "http://localhost:9119"; authMode = "basic" }
        profiles = @{}
    } | ConvertTo-Json -Depth 3 | Write-File "$connDir\connection.json"
    Write-OK "Connection → http://localhost:9119"

    Set-State $step
}

# ═══════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════
# Recover secrets from file if steps were skipped (checkpoint/resume)
if (-not $dashPass -or -not $dotHermes) {
    $dotHermes = "$env:USERPROFILE\.hermes"
    # Try credentials.txt first, then fall back to .env
    if (Test-Path "$InstallDir\credentials.txt") {
        $credContent = Get-Content "$InstallDir\credentials.txt" -Raw
        if ($credContent -match 'Password: (\S+)') { $dashPass = $Matches[1] }
    }
    if (-not $dashPass -and (Test-Path "$dotHermes\.env")) {
        $envContent = Get-Content "$dotHermes\.env" -Raw
        if ($envContent -match 'DASHBOARD_BASIC_AUTH_PASSWORD=(\S+)') { $dashPass = $Matches[1] }
    }
}

# Ports for the copy-paste links — read from stack .env (set in step 2),
# fall back to compose defaults.
$dashPort   = "9119"; $apiPort = "8642"; $searchPort = "8080"; $memPort = "8081"
if (Test-Path "$InstallDir\.env") {
    $stackEnv = Get-Content "$InstallDir\.env" -Raw
    if ($stackEnv -match 'HERMES_DASHBOARD_PORT=(\d+)') { $dashPort = $Matches[1] }
    if ($stackEnv -match 'HERMES_API_PORT=(\d+)')        { $apiPort = $Matches[1] }
    if ($stackEnv -match 'SEARXNG_PORT=(\d+)')           { $searchPort = $Matches[1] }
    if ($stackEnv -match 'MNEMOSYNE_PORT=.*?:(\d+)')     { $memPort = $Matches[1] }
}

$dashUrl   = "http://localhost:$dashPort"
$apiUrl    = "http://localhost:$apiPort/v1"
$searchUrl = "http://localhost:$searchPort"
$memUrl    = "http://localhost:$memPort/sse"

Write-Host ""
Write-Host "  $('#' * 72)" -ForegroundColor Cyan
Write-Host "  #  Hermes Agent Stack -- Ready" -ForegroundColor Cyan
Write-Host "  $('#' * 72)" -ForegroundColor Cyan
Write-Host "  Provider:    $Provider / $Model"
Write-Host "  Dashboard:   $dashUrl"
Write-Host "  Login:       admin / $dashPass"
Write-Host "  Configs:     $dotHermes"
Write-Host "  Credentials: $InstallDir\credentials.txt"
Write-Host "  State:       $StateFile"
Write-Host "  $('#' * 72)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  -- Copy-paste links --" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Hermes Dashboard :  $dashUrl" -ForegroundColor White
Write-Host "  Hermes API       :  $apiUrl" -ForegroundColor White
Write-Host "  SearXNG (search) :  $searchUrl" -ForegroundColor White
Write-Host "  Mnemosyne (MCP)  :  $memUrl" -ForegroundColor White
Write-Host ""
Write-Host "  -- Hermes Desktop connection --" -ForegroundColor Yellow
Write-Host "  Settings -> Gateway -> Remote gateway ->" -ForegroundColor White
Write-Host "  URL:  $dashUrl" -ForegroundColor White
Write-Host "  User: admin" -ForegroundColor White
Write-Host "  Pass: $dashPass" -ForegroundColor White
Write-Host ""
Write-Host "  -- Commands --" -ForegroundColor Yellow
Write-Host "  Launch Desktop: Start-Process `"$env:LOCALAPPDATA\hermes\hermes-agent\apps\desktop\Hermes Agent.exe`""
Write-Host "  Status:         cd $InstallDir && docker compose ps"
Write-Host "  Logs:           cd $InstallDir && docker compose logs -f"
Write-Host ""
Write-Host "  Rerun setup with -ResetState to rebuild everything from scratch."
Write-Host ""
