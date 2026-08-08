<#
.SYNOPSIS
    hermes-stack spec verifier — исполняет все машинопроверяемые приёмочные
    критерии (AC) из specs/*.md против живого стека. Read-only, ничего не меняет.

.DESCRIPTION
    Exit code = число проваленных проверок (0 = всё зелёное).

    Учитывает селективную установку: состав ожидаемых контейнеров и проверок
    определяется из STACK_COMPONENTS в $InstallDir\.env (по умолчанию — полный
    стек hermes,searxng,mnemosyne). Проверки для невыбранных компонентов
    пропускаются и считаются PASS. Порты читаются из того же .env.

    Автоматически гоняет:
      Compose  : C1-C7, C9-C10
      Hermes   : H1-H8
      SearXNG  : S1-S4
      Mnemosyne: M1-M5
      Setup    : P1-P5   (P6/P7 - ручные, в спеке помечены [manual])

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1
    powershell -ExecutionPolicy Bypass -File specs/verify-specs.ps1 -Quiet
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    [string]$InstallDir = "$env:USERPROFILE\hermes-stack"
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Id, [bool]$Ok, [string]$Evidence = "")
    [void]$results.Add([pscustomobject]@{ Id = $Id; Ok = $Ok })
    $mark = if ($Ok) { "[PASS]" } else { "[FAIL]" }
    $fg   = if ($Ok) { "Green" } else { "Red" }
    if (-not $Quiet) { Write-Host ("  {0} {1,-6} {2}" -f $mark, $Id, $Evidence) -ForegroundColor $fg }
}

function Test-TcpPort([int]$Port) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $Port)
        $tcp.Close()
        return $true
    } catch { return $false }
}

function Get-ContainerNames {
    return @(& docker ps --format '{{.Names}}' 2>$null | ForEach-Object { $_.Trim() })
}

function Get-ContainerNetworks([string]$Name) {
    return ((& docker inspect $Name --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>$null) -join ' ')
}

function Get-ContainerPorts([string]$Name) {
    return @(& docker port $Name 2>$null)
}

function Get-ContainerMounts([string]$Name) {
    return ((& docker inspect $Name --format '{{range .Mounts}}{{.Source}}=>{{.Destination}}(rw={{.RW}}); {{end}}' 2>$null) -join ' ')
}

function Get-ContainerEnv([string]$Name) {
    return ((& docker inspect $Name --format '{{range .Config.Env}}{{.}}|{{end}}' 2>$null) -join '')
}

function Read-FileRaw([string]$Path) {
    if (Test-Path $Path) { return (Get-Content $Path -Raw) } else { return "" }
}

# ── Selection + ports from stack .env (selective-install support) ────────
$selected = @("hermes","searxng","mnemosyne")   # default: full stack
$stackEnvRaw = Read-FileRaw "$InstallDir\.env"
if ($stackEnvRaw -match 'STACK_COMPONENTS=([^\r\n]+)') {
    $sel = @($Matches[1] -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne "" })
    if ($sel.Count -gt 0) { $selected = $sel }
}
$selHermes  = $selected -contains "hermes"
$selSearxng = $selected -contains "searxng"
$selMnemo   = $selected -contains "mnemosyne"

$dashPort = 9119; $apiPort = 8642; $searchPort = 8080; $memPort = 8081
if ($stackEnvRaw -match 'HERMES_DASHBOARD_PORT=(\d+)') { $dashPort = [int]$Matches[1] }
if ($stackEnvRaw -match 'HERMES_API_PORT=(\d+)')       { $apiPort  = [int]$Matches[1] }
if ($stackEnvRaw -match 'SEARXNG_PORT=(\d+)')          { $searchPort = [int]$Matches[1] }
if ($stackEnvRaw -match 'MNEMOSYNE_PORT=.*?:(\d+)')    { $memPort = [int]$Matches[1] }

function Skip([string]$Id, [string]$Why) { Add-Result $Id $true "(skipped: $Why)" }

Write-Host "=== hermes-stack spec verification ===" -ForegroundColor Cyan
Write-Host "  Selection: $($selected -join ', ')" -ForegroundColor Gray
Write-Host ""

# ── Dashboard password (для H6), маскируется в выводе ──────────────────
$dashPass = $null
$credFile = "$InstallDir\credentials.txt"
if (Test-Path $credFile) {
    $credRaw = Get-Content $credFile -Raw
    if ($credRaw -match 'Password:\s*(\S+)') { $dashPass = $Matches[1] }
}
if (-not $dashPass) {
    $hermesEnvFile = "$env:USERPROFILE\.hermes\.env"
    if (Test-Path $hermesEnvFile) {
        $envRaw = Get-Content $hermesEnvFile -Raw
        if ($envRaw -match 'DASHBOARD_BASIC_AUTH_PASSWORD=(\S+)') { $dashPass = $Matches[1] }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# COMPOSE  (spec-compose-infra.md)
# ═══════════════════════════════════════════════════════════════════════
$names = Get-ContainerNames

$expected = @()
if ($selHermes)  { $expected += "hermes" }
if ($selSearxng) { $expected += @("searxng-core","searxng-valkey") }
if ($selMnemo)   { $expected += "mnemosyne" }

$allUp = $true
foreach ($n in $expected) { if ($names -notcontains $n) { $allUp = $false } }
Add-Result "C1" $allUp "expected: $($expected -join ', '); running: $($names -join ', ')"

$netOk = $true
foreach ($n in $expected) {
    if ((Get-ContainerNetworks $n) -notmatch 'hermes-net') { $netOk = $false }
}
Add-Result "C2" $netOk "all expected on hermes-net"

$hermesPorts = (Get-ContainerPorts "hermes") -join "`n"
Add-Result "C3" (($hermesPorts -match [regex]::Escape("0.0.0.0:$apiPort")) -and ($hermesPorts -match [regex]::Escape("0.0.0.0:$dashPort"))) "hermes $apiPort+$dashPort on 0.0.0.0"

if ($selSearxng) {
    $sxPorts = (Get-ContainerPorts "searxng-core") -join "`n"
    Add-Result "C4" (($sxPorts -match [regex]::Escape("127.0.0.1:$searchPort")) -and ($sxPorts -notmatch '0\.0\.0\.0')) "searxng-core loopback only"
    $sxMounts = Get-ContainerMounts "searxng-core"
    Add-Result "C9" ($sxMounts -match 'settings\.yml[^;]*\(rw=False\)') "settings.yml mounted ro"
} else { Skip "C4" "searxng not selected"; Skip "C9" "searxng not selected" }

if ($selMnemo) {
    $mnPorts = (Get-ContainerPorts "mnemosyne") -join "`n"
    Add-Result "C5" (($mnPorts -match [regex]::Escape("127.0.0.1:$memPort")) -and ($mnPorts -notmatch '0\.0\.0\.0')) "mnemosyne loopback only"
} else { Skip "C5" "mnemosyne not selected" }

$hermesCmd = ((& docker inspect hermes --format '{{json .Config.Cmd}}' 2>$null) -join '')
Add-Result "C6" (($hermesCmd -match 'gateway') -and ($hermesCmd -match 'run')) "Cmd=$hermesCmd"

$hermesMounts = Get-ContainerMounts "hermes"
Add-Result "C7" ($hermesMounts -match '\.hermes[^;]*=>/opt/data\(rw=True\)') "bind-mount ~/.hermes -> /opt/data"

$hermesEnvC = Get-ContainerEnv "hermes"
Add-Result "C10" (($hermesEnvC -match 'API_SERVER_KEY=[0-9a-f]{32}') -and ($hermesEnvC -notmatch 'change-me')) "API_SERVER_KEY = 32 hex (non-default)"

# ═══════════════════════════════════════════════════════════════════════
# HERMES  (spec-hermes-service.md)
# ═══════════════════════════════════════════════════════════════════════
$hermesEnv = Read-FileRaw "$env:USERPROFILE\.hermes\.env"
Add-Result "H2" (($hermesEnv -match 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin') -and `
                 ($hermesEnv -match 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=\S+')) "dashboard basic auth admin + pass"

$cfg = Read-FileRaw "$env:USERPROFILE\.hermes\config.yaml"
if ($selSearxng) {
    Add-Result "H1" ($hermesEnv -match 'SEARXNG_URL=http://searxng-core:8080') "SEARXNG_URL in ~/.hermes/.env"
    Add-Result "H3" ($cfg -match 'search_backend:\s*searxng') "config.yaml search_backend=searxng"
} else { Skip "H1" "searxng not selected"; Skip "H3" "searxng not selected" }

if ($selMnemo) {
    Add-Result "H4" (($cfg -match 'memory_enabled:\s*true') -and ($cfg -match 'provider:\s*mnemosyne')) "config.yaml memory_enabled+provider=mnemosyne"
    Add-Result "H5" (Test-Path "$env:USERPROFILE\.hermes\plugins\mnemosyne") "~/.hermes/plugins/mnemosyne exists"
} else { Skip "H4" "mnemosyne not selected"; Skip "H5" "mnemosyne not selected" }

$apiOk = $false; $apiVer = ""
if ($dashPass) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$dashPass"))
    for ($i=1; $i -le 3; $i++) {
        try {
            $r = Invoke-RestMethod -Uri "http://localhost:$dashPort/api/status" -Headers @{Authorization="Basic $b64"} -TimeoutSec 10
            $apiOk = $true; $apiVer = [string]$r.version; break
        } catch { Start-Sleep 2 }
    }
}
Add-Result "H6" $apiOk "GET /api/status -> version $apiVer"

if ($selMnemo) {
    $memOut = ((& docker exec hermes hermes memory status 2>&1) -join "`n")
    # H7 must assert the provider is actually available, NOT just that
    # "mnemosyne ... active" appears (that string is in the plugin list even
    # when memory is broken).
    $memOk = ($memOut -match 'Provider:\s*mnemosyne') -and ($memOut -notmatch 'Status:\s*not available')
    Add-Result "H7" $memOk "hermes memory status: provider=mnemosyne, status != 'not available'"
} else { Skip "H7" "mnemosyne not selected" }

$connOk = $false; $connPath = "$env:APPDATA\hermes\connection.json"
if (Test-Path $connPath) {
    try {
        $j = Get-Content $connPath -Raw | ConvertFrom-Json
        $connOk = ($j.mode -eq "remote") -and ($j.remote.url -eq "http://localhost:$dashPort") -and ($j.remote.authMode -eq "oauth")
    } catch {}
}
Add-Result "H8" $connOk "connection.json remote -> localhost:$dashPort (oauth)"

# ═══════════════════════════════════════════════════════════════════════
# SEARXNG  (spec-searxng-service.md)
# ═══════════════════════════════════════════════════════════════════════
if ($selSearxng) {
    $sxLive = $false
    try {
        $sr = Invoke-WebRequest -Uri "http://localhost:$searchPort/search?q=test&format=json" -UseBasicParsing -TimeoutSec 20
        $sxLive = ($sr.StatusCode -eq 200)
    } catch {}
    Add-Result "S1" $sxLive "live JSON search HTTP 200"

    $sxCfg = Read-FileRaw "$InstallDir\searxng-settings.yml"
    Add-Result "S2" (($sxCfg -match '(?m)^\s*-\s*html') -and ($sxCfg -match '(?m)^\s*-\s*json') -and `
                     ($sxCfg -match '(?m)^\s*-\s*csv') -and ($sxCfg -match '(?m)^\s*-\s*rss')) "formats html/json/csv/rss"
    Add-Result "S3" ($names -contains "searxng-valkey") "valkey running"
    Add-Result "S4" ($sxCfg -notmatch '__SEARXNG_SECRET__') "secret placeholder replaced"
} else { Skip "S1" "searxng not selected"; Skip "S2" "searxng not selected"; Skip "S3" "searxng not selected"; Skip "S4" "searxng not selected" }

# ═══════════════════════════════════════════════════════════════════════
# MNEMOSYNE  (spec-mnemosyne-service.md)
# ═══════════════════════════════════════════════════════════════════════
if ($selMnemo) {
    $mnHealth = ((& docker inspect mnemosyne --format '{{.State.Health.Status}}' 2>$null) -join '')
    Add-Result "M1" ($mnHealth -eq "healthy") "health=$mnHealth"
    Add-Result "M2" (Test-TcpPort $memPort) "TCP $memPort open"

    $mnEnv = Get-ContainerEnv "mnemosyne"
    Add-Result "M3" ($mnEnv -match 'MNEMOSYNE_MCP_TOKEN=[^|]+') "MCP token set in container env"
    Add-Result "M4" ($mnEnv -match 'MNEMOSYNE_DATA_DIR=/data') "DATA_DIR=/data"

    $plugOut = ((& docker exec hermes sh -c 'ls /opt/data/plugins/mnemosyne/ 2>/dev/null | head -1') -join '').Trim()
    Add-Result "M5" ($plugOut -ne "") "plugin dir non-empty ($plugOut)"
} else { Skip "M1" "mnemosyne not selected"; Skip "M2" "mnemosyne not selected"; Skip "M3" "mnemosyne not selected"; Skip "M4" "mnemosyne not selected"; Skip "M5" "mnemosyne not selected" }

# ═══════════════════════════════════════════════════════════════════════
# SETUP  (spec-setup-script.md)
# ═══════════════════════════════════════════════════════════════════════
$stateOk = $false
if (Test-Path "$InstallDir\.hermes-stack-state.json") {
    try {
        $st = Get-Content "$InstallDir\.hermes-stack-state.json" -Raw | ConvertFrom-Json
        $stateOk = ($null -ne $st.completed)
    } catch {}
}
Add-Result "P1" $stateOk ".hermes-stack-state.json valid"
Add-Result "P2" (Test-Path "$InstallDir\credentials.txt") "credentials.txt exists"

$stackEnv = Read-FileRaw "$InstallDir\.env"
$p3ok = ($stackEnv -match 'API_SERVER_KEY=[0-9a-f]{32}') -and `
        ($stackEnv -match 'HERMES_API_PORT=\d+') -and `
        ($stackEnv -match 'HERMES_DASHBOARD_PORT=\d+')
if ($selMnemo) { $p3ok = $p3ok -and ($stackEnv -match 'MNEMOSYNE_MCP_TOKEN=[^|]+') }
Add-Result "P3" $p3ok "stack .env: API key + ports (MCP token when mnemosyne selected)"

if ($selSearxng) {
    $sxEnv = Read-FileRaw "$InstallDir\.env.searxng"
    Add-Result "P4" (($sxEnv -match 'SEARXNG_HOST=127\.0\.0\.1') -and ($sxEnv -match "SEARXNG_PORT=$searchPort")) ".env.searxng loopback"
} else { Skip "P4" "searxng not selected" }

$tokens = $null; $parseErrs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$InstallDir\setup.ps1", [ref]$tokens, [ref]$parseErrs)
Add-Result "P5" ($parseErrs.Count -eq 0) "setup.ps1 parses clean ($($parseErrs.Count) errors)"

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════
$passed = @($results | Where-Object { $_.Ok }).Count
$total  = $results.Count
$failed = $total - $passed
$manual = "P6 (DryRun no-op), P7 (TUI menu), P8 (component validation) -- manual"

Write-Host ""
Write-Host ("  Summary: {0}/{1} passed, {2} failed" -f $passed, $total, $failed) -ForegroundColor Cyan
Write-Host "  Manual checks: $manual" -ForegroundColor Gray
if ($failed -gt 0) {
    Write-Host "  Failed:" -ForegroundColor Red
    $results | Where-Object { -not $_.Ok } | ForEach-Object {
        Write-Host ("    - {0}" -f $_.Id) -ForegroundColor Red
    }
}
Write-Host ""
exit $failed
