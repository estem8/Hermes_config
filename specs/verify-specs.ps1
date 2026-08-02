<#
.SYNOPSIS
    hermes-stack spec verifier — исполняет все машинопроверяемые приёмочные
    критерии (AC) из specs/*.md против живого стека. Read-only, ничего не меняет.

.DESCRIPTION
    Exit code = число проваленных проверок (0 = всё зелёное).

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

Write-Host "=== hermes-stack spec verification ===" -ForegroundColor Cyan
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

$allUp = ($names -contains "hermes") -and ($names -contains "searxng-core") -and `
         ($names -contains "searxng-valkey") -and ($names -contains "mnemosyne")
Add-Result "C1" $allUp "containers: $($names -join ', ')"

$netOk = $true
foreach ($n in @("hermes","searxng-core","searxng-valkey","mnemosyne")) {
    if ((Get-ContainerNetworks $n) -notmatch 'hermes-net') { $netOk = $false }
}
Add-Result "C2" $netOk "all on hermes-net"

$hermesPorts = (Get-ContainerPorts "hermes") -join "`n"
Add-Result "C3" (($hermesPorts -match '0\.0\.0\.0:8642') -and ($hermesPorts -match '0\.0\.0\.0:9119')) "hermes 8642+9119 on 0.0.0.0"

$sxPorts = (Get-ContainerPorts "searxng-core") -join "`n"
Add-Result "C4" (($sxPorts -match '127\.0\.0\.1:8080') -and ($sxPorts -notmatch '0\.0\.0\.0')) "searxng-core loopback only"

$mnPorts = (Get-ContainerPorts "mnemosyne") -join "`n"
Add-Result "C5" (($mnPorts -match '127\.0\.0\.1:8081') -and ($mnPorts -notmatch '0\.0\.0\.0')) "mnemosyne loopback only"

$hermesCmd = ((& docker inspect hermes --format '{{json .Config.Cmd}}' 2>$null) -join '')
Add-Result "C6" (($hermesCmd -match 'gateway') -and ($hermesCmd -match 'run')) "Cmd=$hermesCmd"

$hermesMounts = Get-ContainerMounts "hermes"
Add-Result "C7" ($hermesMounts -match '\.hermes[^;]*=>/opt/data\(rw=True\)') "bind-mount ~/.hermes -> /opt/data"

$sxMounts = Get-ContainerMounts "searxng-core"
Add-Result "C9" ($sxMounts -match 'settings\.yml[^;]*\(rw=False\)') "settings.yml mounted ro"

$hermesEnvC = Get-ContainerEnv "hermes"
Add-Result "C10" (($hermesEnvC -match 'API_SERVER_KEY=[0-9a-f]{32}') -and ($hermesEnvC -notmatch 'change-me')) "API_SERVER_KEY = 32 hex (non-default)"

# ═══════════════════════════════════════════════════════════════════════
# HERMES  (spec-hermes-service.md)
# ═══════════════════════════════════════════════════════════════════════
$hermesEnv = Read-FileRaw "$env:USERPROFILE\.hermes\.env"
Add-Result "H1" ($hermesEnv -match 'SEARXNG_URL=http://searxng-core:8080') "SEARXNG_URL in ~/.hermes/.env"
Add-Result "H2" (($hermesEnv -match 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin') -and `
                 ($hermesEnv -match 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=\S+')) "dashboard basic auth admin + pass"

$cfg = Read-FileRaw "$env:USERPROFILE\.hermes\config.yaml"
Add-Result "H3" ($cfg -match 'search_backend:\s*searxng') "config.yaml search_backend=searxng"
Add-Result "H4" (($cfg -match 'memory_enabled:\s*true') -and ($cfg -match 'provider:\s*mnemosyne')) "config.yaml memory=mnemosyne"

Add-Result "H5" (Test-Path "$env:USERPROFILE\.hermes\plugins\mnemosyne") "~/.hermes/plugins/mnemosyne exists"

$apiOk = $false; $apiVer = ""
if ($dashPass) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$dashPass"))
    for ($i=1; $i -le 3; $i++) {
        try {
            $r = Invoke-RestMethod -Uri "http://localhost:9119/api/status" -Headers @{Authorization="Basic $b64"} -TimeoutSec 10
            $apiOk = $true; $apiVer = [string]$r.version; break
        } catch { Start-Sleep 2 }
    }
}
Add-Result "H6" $apiOk "GET /api/status -> version $apiVer"

$memOut = ((& docker exec hermes hermes memory status 2>&1) -join "`n")
Add-Result "H7" ($memOut -match 'mnemosyne.*active') "hermes memory status -> mnemosyne active"

$connOk = $false; $connPath = "$env:APPDATA\hermes\connection.json"
if (Test-Path $connPath) {
    try {
        $j = Get-Content $connPath -Raw | ConvertFrom-Json
        $connOk = ($j.mode -eq "remote") -and ($j.remote.url -eq "http://localhost:9119") -and ($j.remote.authMode -eq "basic")
    } catch {}
}
Add-Result "H8" $connOk "connection.json remote -> localhost:9119 (basic)"

# ═══════════════════════════════════════════════════════════════════════
# SEARXNG  (spec-searxng-service.md)
# ═══════════════════════════════════════════════════════════════════════
$sxLive = $false
try {
    $sr = Invoke-WebRequest -Uri 'http://localhost:8080/search?q=test&format=json' -UseBasicParsing -TimeoutSec 20
    $sxLive = ($sr.StatusCode -eq 200)
} catch {}
Add-Result "S1" $sxLive "live JSON search HTTP 200"

$sxCfg = Read-FileRaw "$InstallDir\searxng-settings.yml"
Add-Result "S2" (($sxCfg -match '(?m)^\s*-\s*html') -and ($sxCfg -match '(?m)^\s*-\s*json') -and `
                 ($sxCfg -match '(?m)^\s*-\s*csv') -and ($sxCfg -match '(?m)^\s*-\s*rss')) "formats html/json/csv/rss"

Add-Result "S3" ($names -contains "searxng-valkey") "valkey running"
Add-Result "S4" ($sxCfg -notmatch '\$SEARXNG_SECRET_PLACEHOLDER') "secret placeholder replaced"

# ═══════════════════════════════════════════════════════════════════════
# MNEMOSYNE  (spec-mnemosyne-service.md)
# ═══════════════════════════════════════════════════════════════════════
$mnHealth = ((& docker inspect mnemosyne --format '{{.State.Health.Status}}' 2>$null) -join '')
Add-Result "M1" ($mnHealth -eq "healthy") "health=$mnHealth"
Add-Result "M2" (Test-TcpPort 8081) "TCP 8081 open"

$mnEnv = Get-ContainerEnv "mnemosyne"
Add-Result "M3" ($mnEnv -match 'MNEMOSYNE_MCP_TOKEN=[^|]+') "MCP token set in container env"
Add-Result "M4" ($mnEnv -match 'MNEMOSYNE_DATA_DIR=/data') "DATA_DIR=/data"

$plugOut = ((& docker exec hermes sh -c 'ls /opt/data/plugins/mnemosyne/ 2>/dev/null | head -1') -join '').Trim()
Add-Result "M5" ($plugOut -ne "") "plugin dir non-empty ($plugOut)"

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
Add-Result "P3" (($stackEnv -match 'MNEMOSYNE_MCP_TOKEN=[^|]+') -and `
                 ($stackEnv -match 'API_SERVER_KEY=[0-9a-f]{32}') -and `
                 ($stackEnv -match 'HERMES_API_PORT=8642') -and `
                 ($stackEnv -match 'HERMES_DASHBOARD_PORT=9119')) "stack .env: MCP token + API key + ports"

$sxEnv = Read-FileRaw "$InstallDir\.env.searxng"
Add-Result "P4" (($sxEnv -match 'SEARXNG_HOST=127\.0\.0\.1') -and ($sxEnv -match 'SEARXNG_PORT=8080')) ".env.searxng loopback"

$tokens = $null; $parseErrs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$InstallDir\setup.ps1", [ref]$tokens, [ref]$parseErrs)
Add-Result "P5" ($parseErrs.Count -eq 0) "setup.ps1 parses clean ($($parseErrs.Count) errors)"

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════
$passed = @($results | Where-Object { $_.Ok }).Count
$total  = $results.Count
$failed = $total - $passed
$manual = "P6 (DryRun no-op), P7 (TUI menu) -- manual"

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
