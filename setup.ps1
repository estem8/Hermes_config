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

.PARAMETER Components
    Comma-separated components to install: hermes, searxng, mnemosyne (default: all).

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

    [switch]$Install,

    [switch]$ResetState,

    [switch]$Pause,

    [string]$InstallDir = "$env:USERPROFILE\hermes-stack",

    [string]$Components = ""
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

# ── Components (selective install) ───────────────────────
$ValidComponents = @("hermes","searxng","mnemosyne")
$ComponentsGiven  = $PSBoundParameters.ContainsKey("Components")

function ConvertTo-ComponentArray([string]$List) {
    return @($List -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne "" })
}

function Get-SelectedComponents {
    # Priority: explicit -Components > persisted STACK_COMPONENTS in .env > all
    if (Test-Path "$InstallDir\.env") {
        $e = Get-Content "$InstallDir\.env" -Raw
        if ($e -match 'STACK_COMPONENTS=([^\r\n]+)') {
            $p = ConvertTo-ComponentArray $Matches[1]
            if ($p.Count -gt 0) { return $p }
        }
    }
    return @("hermes","searxng","mnemosyne")
}

function Get-ComposeProfiles {
    # Compose profiles to enable for the selected components (see docker-compose.yml)
    $p = @()
    if ($script:SelectedComponents -contains "searxng")   { $p += "searxng" }
    if ($script:SelectedComponents -contains "mnemosyne") { $p += "mnemosyne" }
    return $p
}

function Get-ExpectedContainers {
    # Container names that must be running for the selected components
    $n = @()
    if ($script:SelectedComponents -contains "hermes")    { $n += "hermes" }
    if ($script:SelectedComponents -contains "searxng")   { $n += @("searxng-core","searxng-valkey") }
    if ($script:SelectedComponents -contains "mnemosyne") { $n += "mnemosyne" }
    return $n
}

if ($ComponentsGiven) {
    $script:SelectedComponents = ConvertTo-ComponentArray $Components
    foreach ($c in $script:SelectedComponents) {
        if ($c -notin $ValidComponents) { throw "Unknown component '$c'. Valid: $($ValidComponents -join ', ')" }
    }
    if ($script:SelectedComponents.Count -eq 0) { throw "Empty component list. Valid: $($ValidComponents -join ', ')" }
} else {
    $script:SelectedComponents = Get-SelectedComponents
}
# Hermes Gateway is the core of the stack and is always installed — the
# selection applies to the optional SearXNG / Mnemosyne components only.
if ("hermes" -notin $script:SelectedComponents) {
    $script:SelectedComponents = @("hermes") + @($script:SelectedComponents)
}

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
            if ($DryRun) { Write-INFO "[dry-run] would: $Desc"; return }
            $null = & $Script 2>&1
            return
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
        # Trailing newline обязателен: иначе последняя строка склеивается с
        # последующими (например, Add-Content в .env) и compose ломается
        $text = $sb.ToString().TrimEnd("`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
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

# Recover dashboard password across checkpoint/resume (credentials.txt → ~/.hermes/.env)
function Get-DashPass {
    if (-not $script:dashPass) {
        if (Test-Path "$InstallDir\credentials.txt") {
            $c = Get-Content "$InstallDir\credentials.txt" -Raw
            if ($c -match 'Password:\s*(\S+)') { $script:dashPass = $Matches[1] }
        }
        if (-not $script:dashPass -and (Test-Path "$env:USERPROFILE\.hermes\.env")) {
            $e = Get-Content "$env:USERPROFILE\.hermes\.env" -Raw
            if ($e -match 'DASHBOARD_BASIC_AUTH_PASSWORD=(\S+)') { $script:dashPass = $Matches[1] }
        }
    }
    return $script:dashPass
}

# ── Status panel + menu ─────────────────────────────────
function Test-TcpPort([int]$Port) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $Port)
        $tcp.Close()
        return $true
    } catch { return $false }
}

function Test-Docker {
    docker info 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Show-StatusCell([string]$Label, [bool]$Ok) {
    $mark = if ($Ok) { "[OK]" } else { "[FAIL]" }
    $fg   = if ($Ok) { "Green" } else { "Red" }
    Write-Host ("  {0,-10} {1}" -f $Label, $mark) -NoNewline -ForegroundColor $fg
}

function Show-StatusPanel {
    Write-Host ""
    Show-StatusCell "Docker"   (Test-Docker)
    if ($script:SelectedComponents -contains "hermes")    { Show-StatusCell "API"      (Test-TcpPort 9119) }
    if ($script:SelectedComponents -contains "searxng")   { Show-StatusCell "Search"   (Test-TcpPort 8080) }
    if ($script:SelectedComponents -contains "mnemosyne") { Show-StatusCell "Memory"   (Test-TcpPort 8081) }
    Write-Host ""
    Write-Host ""
}

function Select-Components {
    # Checkbox screen shown before install; returns the chosen component array.
    # Hermes Gateway is always installed — shown as [x] and not toggleable.
    $sel = @(Get-SelectedComponents | Where-Object { $_ -in $ValidComponents -and $_ -ne "hermes" })
    while ($true) {
        Clear-Host
        Write-Host "  Select components to install (Enter to continue):" -ForegroundColor Cyan
        Write-Host ""
        for ($i=0; $i -lt $ValidComponents.Count; $i++) {
            $c = $ValidComponents[$i]
            if ($c -eq "hermes") {
                Write-Host ("    [{0}] {1,-12} [x]  (always installed)" -f ($i+1), $c)
            } else {
                $mark = if ($sel -contains $c) { "[x]" } else { "[ ]" }
                Write-Host ("    [{0}] {1,-12} {2}" -f ($i+1), $c, $mark)
            }
        }
        Write-Host ""
        Write-Host "    [a] all    [n] none    [Enter] continue" -ForegroundColor Yellow
        Write-Host ""
        $k = Read-Host "  Toggle"
        if ($k -eq "") {
            # hermes is always installed — prepend it below; an empty optional set means Hermes only
            return @("hermes") + @($sel)
        }
        if ($k -eq "a") { $sel = @($ValidComponents | Where-Object { $_ -ne "hermes" }); continue }
        if ($k -eq "n") { $sel = @(); continue }
        $idx = 0
        if ([int]::TryParse($k, [ref]$idx) -and $idx -ge 1 -and $idx -le $ValidComponents.Count) {
            $c = $ValidComponents[$idx-1]
            if ($c -eq "hermes") { continue }  # not toggleable
            if ($sel -contains $c) { $sel = @($sel | Where-Object { $_ -ne $c }) }
            else { $sel = @($sel) + $c }
        }
    }
}

function Show-MainMenu {
    # Returns: "install" | "update" | "status" | "logs" | "start" | "restart" | "down" | "stats" | "exit"
    while ($true) {
        Clear-Host
        Write-Host "  Hermes Agent Stack" -ForegroundColor Cyan
        Show-StatusPanel
        Write-Host "  Menu:" -ForegroundColor Yellow
        Write-Host "    -- Setup --"
        Write-Host "    [1] Install"
        Write-Host "    [2] Update"
        Write-Host ""
        Write-Host "    -- Managing the Stack --"
        Write-Host "    [3] Status        docker compose ps"
        Write-Host "    [4] Logs          docker compose logs -f"
        Write-Host "    [5] Start         docker compose up -d"
        Write-Host "    [6] Restart       docker compose restart"
        Write-Host "    [7] Stop          docker compose down"
        Write-Host "    [8] Stats         docker stats (live)"
        Write-Host ""
        Write-Host "    [0] Exit"
        Write-Host ""
        $choice = Read-Host "  Select"
        switch ($choice) {
            "1" { return "install" }
            "2" { return "update" }
            "3" { return "status" }
            "4" { return "logs" }
            "5" { return "start" }
            "6" { return "restart" }
            "7" { return "down" }
            "8" { return "stats" }
            "0" { return "exit" }
            default { Write-WARN "Invalid choice: $choice" }
        }
    }
}

function Invoke-Update {
    Write-Step "UPDATE: pulling latest images and updating Hermes"
    Push-Location $InstallDir
    try {
        Invoke-Retry -Script {
            docker compose pull 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "pull failed" }
        } -Max 2 -Desc "docker compose pull"
        if ($script:SelectedComponents -contains "mnemosyne") {
            Invoke-Retry -Script {
                docker compose build mnemosyne 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "build failed" }
            } -Max 2 -Desc "Build Mnemosyne"
        }
        Invoke-Retry -Script {
            docker compose up -d 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "compose up failed" }
        } -Max 3 -Delay 8 -Desc "docker compose up -d"
        if ($script:SelectedComponents -contains "hermes") {
            $null = docker exec hermes hermes update 2>&1
            $null = docker restart hermes 2>&1
        }
        Write-OK "Update complete"
    } finally { Pop-Location }
}

function Invoke-Compose([string]$ComposeArgs, [string]$Desc) {
    Write-Step "$Desc`: docker compose $ComposeArgs"
    Push-Location $InstallDir
    try {
        docker compose $ComposeArgs.Split(" ")
        if ($LASTEXITCODE -ne 0) { Write-WARN "docker compose $ComposeArgs failed (exit code $LASTEXITCODE)" }
    } finally { Pop-Location }
}

function Invoke-Stats {
    Write-Step "STATS: docker stats (Ctrl+C to exit)"
    docker stats
}

function Pause-Menu {
    Write-Host ""
    Read-Host "Press Enter to return to the menu"
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
    Write-Host "Components: $($script:SelectedComponents -join ', ')"
    Write-Host "InstallDir: $InstallDir"
    Write-Host "API key:    $($ApiKey.Substring(0,[Math]::Min(8,$ApiKey.Length)))..."
    Write-Host ""
    $plan = @("Docker Desktop", "Docker containers: $((Get-ExpectedContainers) -join ', ')")
    if ($script:SelectedComponents -contains "hermes") {
        $plan += @("Hermes configuration (~/.hermes/config.yaml)", "Hermes Desktop + connection.json")
    }
    if ($script:SelectedComponents -contains "searxng")   { $plan += "SearXNG settings + containers" }
    if ($script:SelectedComponents -contains "mnemosyne") { $plan += "Mnemosyne plugin in Hermes + MCP server" }
    $pi = 1
    foreach ($p in $plan) { Write-Host ("  {0}. {1}" -f $pi, $p); $pi++ }
    Write-Host ""
    Write-Host "Ports: 8642 (API), 9119 (dashboard), 8080 (search), 8081 (memory)"
    exit 0
}

# ═══════════════════════════════════════════
# MAIN MENU
# ═══════════════════════════════════════════
if (-not $DryRun -and -not $Install) {
    $stayInMenu = $true
    while ($stayInMenu) {
        $menuAction = Show-MainMenu
        switch ($menuAction) {
            "update"   { Invoke-Update;   Pause-Menu }
            "status"   { Invoke-Compose "ps"      "STATUS";   Pause-Menu }
            "logs"     { Invoke-Compose "logs -f" "LOGS" }
            "start"    { Invoke-Compose "up -d"   "START";    Pause-Menu }
            "restart"  { Invoke-Compose "restart" "RESTART";  Pause-Menu }
            "down"     { Invoke-Compose "down"    "STOP";     Pause-Menu }
            "stats"    { Invoke-Stats }
            "exit"     { Write-Host "Bye!"; exit 0 }
            "install"  { $script:SelectedComponents = Select-Components; $stayInMenu = $false }  # fall through to the setup steps
        }
    }
}

# ═══════════════════════════════════════════
# COMPONENT-SELECTION GUARD
# ═══════════════════════════════════════════
# If the requested selection differs from what is installed, the checkpointed
# steps would silently skip and nothing would change. Re-apply automatically:
# reset the component-dependent checkpoints (steps 2-6); step 2 reuses existing
# secrets, so passwords/tokens are NOT rotated by a selection change.
if (-not $ResetState) {
    $s = Get-State
    $installedComps = $null
    if ($s.components) {
        $installedComps = $s.components
    } elseif ($s.completed -and $s.completed.Count -gt 0) {
        $installedComps = "hermes,searxng,mnemosyne"  # legacy full-stack install (no components recorded)
    }
    if ($installedComps -and ($installedComps -ne ($script:SelectedComponents -join ","))) {
        Write-WARN "Installed components ($installedComps) differ from requested ($($script:SelectedComponents -join ', '))"
        Write-WARN "Re-applying steps 2-6 (configs, containers, verification) -- existing secrets are reused"
        foreach ($st in @("directories","containers","plugin","verify","desktop")) {
            $s.completed = @($s.completed | Where-Object { $_ -ne $st })
        }
        $s | ConvertTo-Json -Depth 3 | ForEach-Object { Write-File $StateFile $_ }
    }
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

    # API key (only needed when the Hermes Gateway is installed)
    if ($script:SelectedComponents -contains "hermes") {
        if (-not $ApiKey) { $ApiKey = Read-Host "Enter $Provider API key" }
        if ($ApiKey.Length -lt 10) { Write-WARN "API key looks too short -- verify it" }
    }

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

    # Secrets: reuse existing ones on re-runs / selection re-applies (no rotation),
    # generate only what is missing.
    $dashPass = $null; $dashSec = $null; $mcpTok = $null; $searxngSec = $null; $serverKey = $null
    if (Test-Path "$dotHermes\.env") {
        $envFile = Get-Content "$dotHermes\.env" -Raw
        if ($envFile -match 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=(\S+)') { $dashPass = $Matches[1] }
        if ($envFile -match 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=(\S+)')   { $dashSec  = $Matches[1] }
        if (-not $ApiKey -and $envFile -match ([regex]::Escape($cfg.envKey) + '=(\S+)')) { $ApiKey = $Matches[1] }
    }
    if (Test-Path "$InstallDir\.env") {
        $envFile = Get-Content "$InstallDir\.env" -Raw
        if ($envFile -match 'MNEMOSYNE_MCP_TOKEN=(\S+)') { $mcpTok = $Matches[1] }
        if ($envFile -match 'API_SERVER_KEY=(\S+)')      { $serverKey = $Matches[1] }
    }
    if (Test-Path "$InstallDir\searxng-settings.yml") {
        $sxFile = Get-Content "$InstallDir\searxng-settings.yml" -Raw
        # only a real (>=20 alnum chars) secret matches; the placeholder contains '_' and '$'
        if ($sxFile -match 'secret_key:\s*"?([A-Za-z0-9]{20,})"?') { $searxngSec = $Matches[1] }
    }
    # Generate only the missing secrets
    $dashPass   = if ($dashPass)   { $dashPass }   else { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | %{[char]$_}) }
    $dashSec    = if ($dashSec)    { $dashSec }    else { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 44 | %{[char]$_}) + "==" }
    # NOTE: Get-Random -Count не повторяет элементы, поэтому hex-строки генерим
    # посимвольно: иначе длина упирается в размер алфавита (16) вместо 64/32.
    $mcpTok     = if ($mcpTok)     { $mcpTok }     else { -join (1..64 | %{ '{0:x}' -f (Get-Random -Maximum 16) }) }
    $searxngSec = if ($searxngSec) { $searxngSec } else { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | %{[char]$_}) }
    $serverKey  = if ($serverKey)  { $serverKey }  else { -join (1..32 | %{ '{0:x}' -f (Get-Random -Maximum 16) }) }

    # Write Hermes .env (only with the Hermes Gateway component)
    if ($script:SelectedComponents -contains "hermes") {
        $searxngUrlLine = if ($script:SelectedComponents -contains "searxng") { "SEARXNG_URL=http://searxng-core:8080" } else { "" }
        @"
$($cfg.envKey)=$ApiKey
$searxngUrlLine
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$dashPass
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$dashSec
"@ | Write-File "$dotHermes\.env"
        Write-OK "Hermes .env"

        # Write Hermes config.yaml — backends enabled only for selected components
        $webSection = if ($script:SelectedComponents -contains "searxng")   { "web:`n  search_backend: searxng" } else { "" }
        $memSection = if ($script:SelectedComponents -contains "mnemosyne") { "memory:`n  memory_enabled: true`n  provider: mnemosyne" } else { "" }
        $baseUrlLine = if ($cfg.baseUrl) { "  base_url: `"$($cfg.baseUrl)`"" } else { "  base_url: `"`"" }
        @"
model:
  default: $Provider/$Model
  provider: $Provider
$baseUrlLine
$webSection
$memSection
terminal:
  backend: local
approvals:
  mode: smart
display:
  language: ru
  show_cost: true
"@ | Write-File "$dotHermes\config.yaml"
        Write-OK "Hermes config.yaml"
    } else {
        Write-INFO "Component 'hermes' not selected -- skipping Hermes .env / config.yaml"
    }

    # Write stack .env for docker-compose (selection drives COMPOSE_PROFILES)
    $apiEnvLine  = if ($script:SelectedComponents -contains "hermes")    { "API_SERVER_KEY=$serverKey`nHERMES_API_PORT=8642`nHERMES_DASHBOARD_PORT=9119" } else { "" }
    $sxEnvLine   = if ($script:SelectedComponents -contains "searxng")    { "SEARXNG_HOST=127.0.0.1`nSEARXNG_PORT=8080" } else { "" }
    $memEnvLine  = if ($script:SelectedComponents -contains "mnemosyne")  { "MNEMOSYNE_MCP_TOKEN=$mcpTok`nMNEMOSYNE_PORT=127.0.0.1:8081" } else { "" }
    $profiles    = Get-ComposeProfiles
    $profilesLine = if ($profiles.Count -gt 0) { "COMPOSE_PROFILES=$($profiles -join ',')" } else { "" }
    @"
$apiEnvLine
$sxEnvLine
$memEnvLine
$profilesLine
STACK_COMPONENTS=$($script:SelectedComponents -join ',')
"@ | Write-File "$InstallDir\.env"
    Write-OK "Stack .env (components: $($script:SelectedComponents -join ', '))"

    # SearXNG env + settings secret (only with the SearXNG component)
    if ($script:SelectedComponents -contains "searxng") {
        @"
SEARXNG_HOST=127.0.0.1
SEARXNG_PORT=8080
"@ | Write-File "$InstallDir\.env.searxng"
        Write-OK "SearXNG env"

        # Fix searxng-settings.yml with real secret
        (Get-Content "$InstallDir\searxng-settings.yml" -Raw) -replace '\$SEARXNG_SECRET_PLACEHOLDER', $searxngSec |
            Write-File "$InstallDir\searxng-settings.yml"
        Write-OK "SearXNG settings"
    }

    # Save credentials (sections for selected components only)
    $credDash = if ($script:SelectedComponents -contains "hermes") { @"
Dashboard: http://localhost:9119
  Username: admin
  Password: $dashPass
"@ } else { "" }
    $credMem  = if ($script:SelectedComponents -contains "mnemosyne") { "Mnemosyne MCP Token: $mcpTok`n" } else { "" }
    $credSx   = if ($script:SelectedComponents -contains "searxng")   { "SearXNG Secret: $searxngSec`n" } else { "" }
    $credApi  = if ($script:SelectedComponents -contains "hermes")   { "$Provider API Key: $($ApiKey.Substring(0,[Math]::Min(6,$ApiKey.Length)))...`n" } else { "" }
    @"
=== Hermes Agent Stack -- Credentials ===
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")
Components: $($script:SelectedComponents -join ', ')

$credDash
$credMem$credSx$credApi
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
        # Только legacy-контейнеры старого standalone-сетапа (без label compose-
        # проекта); одноимённые контейнеры чужих compose-проектов не трогаем.
        # Фильтр label!= в docker ps не поддерживается (invalid filter 'label!'),
        # а вложенные кавычки в --format PS 5.1 передаёт с искажением, поэтому
        # label'ы читаем range-шаблоном без кавычек и проверяем клиентски.
        foreach ($n in @("hermes","searxng-core","searxng-valkey","mnemosyne")) {
            $ids = @(docker ps -aq --filter "name=^$n$")
            foreach ($id in $ids) {
                $labels = ((docker inspect $id --format '{{range $k,$v := .Config.Labels}}{{$k}};{{end}}' 2>$null) -join '')
                if ($labels -notmatch 'com\.docker\.compose\.project') { docker rm -f $id 2>&1 | Out-Null }
            }
        }

        if ($script:SelectedComponents -contains "mnemosyne") {
            Invoke-Retry -Script {
                docker compose build mnemosyne 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "build failed" }
            } -Max 2 -Desc "Build Mnemosyne"
        }

        Invoke-Retry -Script {
            docker compose up -d 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "compose up failed" }
        } -Max 3 -Delay 8 -Desc "docker compose up -d"

        # Remove project containers not in the selected set — e.g. leftovers from a
        # previous run with a wider selection (docker compose down with profiles
        # leaves disabled-profile containers running).
        $expected = Get-ExpectedContainers
        foreach ($id in @(docker ps -aq --filter "label=com.docker.compose.project=hermes-stack")) {
            $name = ((docker inspect $id --format "{{.Name}}" 2>$null) -replace "^/", "")
            if ($name -and ($name -notin $expected)) {
                Write-INFO "Removing leftover container $name (not in selected components)"
                docker rm -f $id 2>&1 | Out-Null
            }
        }

        Write-OK "All containers launched"
    } finally { Pop-Location }

    # Wait and verify
    Start-Sleep 10
    $expected = Get-ExpectedContainers
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
    if ($script:SelectedComponents -contains "mnemosyne" -and $script:SelectedComponents -contains "hermes") {
        Write-Step "STEP 4: Installing Mnemosyne plugin"

        Invoke-Retry -Script {
            docker exec hermes uv pip install --python /opt/hermes/.venv/bin/python mnemosyne-hermes 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
        } -Max 3 -Delay 8 -Desc "Install mnemosyne-hermes"

        # Путь к site-packages ищем динамически (в образе может смениться версия Python).
        # Скрипт передаём через stdin (docker exec -i): вложенные `"` в аргументе
        # bash -c PS 5.1 передаёт нативным командам с искажением (команда падает).
        Invoke-Retry -Script {
            @'
SRC=$(find /opt/hermes/.venv -type d -name mnemosyne_hermes 2>/dev/null | head -1)
mkdir -p /opt/data/plugins/mnemosyne
cp -r "$SRC/." /opt/data/plugins/mnemosyne/
test -n "$(ls -A /opt/data/plugins/mnemosyne)"
'@ | docker exec -i hermes bash -s 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "plugin copy failed" }
        } -Max 3 -Delay 5 -Desc "Copy mnemosyne_hermes to plugins"

        Invoke-Retry -Script {
            docker exec hermes hermes config set memory.provider mnemosyne 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "config set failed" }
        } -Max 3 -Delay 5 -Desc "Set memory.provider=mnemosyne"

        docker restart hermes 2>&1 | Out-Null
        Start-Sleep 8
        Write-OK "Plugin installed, Hermes restarted"
    } else {
        Write-INFO "Component 'mnemosyne' not selected (or 'hermes' missing) -- skipping plugin"
    }

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
    if ($script:SelectedComponents -contains "hermes") {
        try {
            $usr = "admin"; $pw = Get-DashPass
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
    }

    # SearXNG
    if ($script:SelectedComponents -contains "searxng") {
        try {
            $r = Invoke-WebRequest -Uri 'http://localhost:8080/search?q=test&format=json' -TimeoutSec 10 -UseBasicParsing
            Write-OK "SearXNG -- HTTP $($r.StatusCode)"
        } catch { Write-WARN "SearXNG: $_" }
    }

    # Mnemosyne (TCP probe — /sse is a streaming endpoint and would hang
    # Invoke-WebRequest, so check the port is accepting connections)
    if ($script:SelectedComponents -contains "mnemosyne") {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", 8081)
            $tcp.Close()
            Write-OK "Mnemosyne -- port 8081 open"
        } catch { Write-WARN "Mnemosyne: $_" }
    }

    # Memory provider
    if ($script:SelectedComponents -contains "mnemosyne" -and $script:SelectedComponents -contains "hermes") {
        $memStatus = docker exec hermes hermes memory status 2>&1
        if ($memStatus -match "mnemosyne.*active") { Write-OK "Memory provider: mnemosyne active" }
        else { Write-WARN "Memory provider may not be active" }
    }

    Set-State $step
}

# ═══════════════════════════════════════════
# STEP 6: DESKTOP
# ═══════════════════════════════════════════
$step = "desktop"
Write-StatusBar
if (Is-Completed $step) { Write-OK "Step '$step' already done -- skipping" }
else {
    if ($script:SelectedComponents -contains "hermes") {
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
    # NOTE: authMode must be "oauth" (not "basic"/"token"): the Desktop app
    # normalizes any non-"oauth" mode to token-auth, and token-auth cannot pass
    # the gateway's WebSocket auth gate (0.0.0.0 bind → ?ticket=/?internal= only).
    # With "oauth" the user signs in once via Settings → Gateway → Sign in using
    # the dashboard credentials below.
    $connDir = "$env:APPDATA\hermes"
    New-Item -ItemType Directory -Force -Path $connDir | Out-Null
    @{
        mode = "remote"
        remote = @{ url = "http://localhost:9119"; authMode = "oauth" }
        profiles = @{}
    } | ConvertTo-Json -Depth 3 | Write-File "$connDir\connection.json"
    Write-OK "Connection → http://localhost:9119 (oauth) "

    # Verify dashboard login works (validates the generated password against
    # the gateway's basic provider). Fail-fast so the user learns about a bad
    # password BEFORE they get a cryptic "session expired" in Desktop.
    $loginOk = $false
    $dashUser = "admin"
    $dashPassCheck = Get-DashPass
    try {
        $loginBody = @{ provider = "basic"; username = $dashUser; password = $dashPassCheck; next = "/" } | ConvertTo-Json
        $loginResp = Invoke-RestMethod -Uri "http://localhost:9119/auth/password-login" -Method Post -ContentType "application/json" -Body $loginBody -TimeoutSec 8
        $loginOk = ($loginResp.ok -eq $true)
    } catch { $loginOk = $false }
    if ($loginOk) {
        Write-OK "Gateway login verified (admin / <password from credentials.txt>)"
    } else {
        Write-Host "  WARN  Gateway login check failed — Desktop Sign in will fail too." -ForegroundColor Yellow
        Write-Host "        Fix: check HERMES_DASHBOARD_BASIC_AUTH_PASSWORD / credentials.txt" -ForegroundColor Yellow
    }

    Set-State $step
    } else {
        Write-INFO "Component 'hermes' not selected -- skipping Hermes Desktop"
        Set-State $step
    }
}

# ═══════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════
# Recover secrets from file if steps were skipped (checkpoint/resume)
$dotHermes = "$env:USERPROFILE\.hermes"
$dashPass  = Get-DashPass

# Persist the component selection in the checkpoint state (used to detect changes)
$s = Get-State
$s | Add-Member -NotePropertyName components -NotePropertyValue ($script:SelectedComponents -join ",") -Force
$s | ConvertTo-Json -Depth 3 | ForEach-Object { Write-File $StateFile $_ }

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
Write-Host "  Components:  $($script:SelectedComponents -join ', ')"
if ($script:SelectedComponents -contains "hermes") {
    Write-Host "  Dashboard:   $dashUrl"
    Write-Host "  Login:       admin / $dashPass"
}
Write-Host "  Configs:     $dotHermes"
Write-Host "  Credentials: $InstallDir\credentials.txt"
Write-Host "  State:       $StateFile"
Write-Host "  $('#' * 72)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  -- Copy-paste links --" -ForegroundColor Yellow
Write-Host ""
if ($script:SelectedComponents -contains "hermes") {
    Write-Host "  Hermes Dashboard :  $dashUrl" -ForegroundColor White
    Write-Host "  Hermes API       :  $apiUrl" -ForegroundColor White
}
if ($script:SelectedComponents -contains "searxng") {
    Write-Host "  SearXNG (search) :  $searchUrl" -ForegroundColor White
}
if ($script:SelectedComponents -contains "mnemosyne") {
    Write-Host "  Mnemosyne (MCP)  :  $memUrl" -ForegroundColor White
}
Write-Host ""
if ($script:SelectedComponents -contains "hermes") {
    Write-Host "  -- Hermes Desktop connection --" -ForegroundColor Yellow
    Write-Host "  Settings -> Gateway -> Remote gateway ->" -ForegroundColor White
    Write-Host "  URL:  $dashUrl" -ForegroundColor White
    Write-Host "  User: admin" -ForegroundColor White
    Write-Host "  Pass: $dashPass" -ForegroundColor White
    Write-Host "  Then click 'Sign in' (ONE time) -- Desktop stores the session." -ForegroundColor Green
    Write-Host "  If you see 'session expired', just Sign in again with these credentials." -ForegroundColor Green
    Write-Host ""
    Write-Host "  -- Commands --" -ForegroundColor Yellow
    Write-Host "  Launch Desktop: Start-Process `"$env:LOCALAPPDATA\hermes\hermes-agent\apps\desktop\Hermes Agent.exe`""
}
Write-Host "  Status:         cd $InstallDir && docker compose ps"
Write-Host "  Logs:           cd $InstallDir && docker compose logs -f"
Write-Host ""
Write-Host "  -- Updates --" -ForegroundColor Yellow
Write-Host "  Images:  cd $InstallDir && docker compose pull && docker compose up -d"
if ($script:SelectedComponents -contains "hermes") {
    Write-Host "  Hermes:  docker exec hermes hermes update"
}
Write-Host "  Script:  cd $InstallDir && git pull"
Write-Host ""
Write-Host "  Rerun setup with -ResetState to rebuild everything from scratch."
Write-Host ""
if ($Pause) { Read-Host "Press Enter to close" }
