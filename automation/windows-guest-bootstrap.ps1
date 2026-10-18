<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42ae98ea-d3b9-46df-ad7b-f011055484ff
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna windows guest bootstrap seed
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    First-logon bootstrap for a Windows guest: establish its Yuruna
    coordinates, then its git credentials.

.DESCRIPTION
    Template rendered by New-WindowsGuestBootstrap onto trusted seed media.
    Runs under Windows PowerShell 5.1 at first logon.
    See https://yuruna.link/42e220c4-0006 for template and launcher design.
#>

$ErrorActionPreference = 'Stop'
$dir = 'C:\ProgramData\yuruna'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# --- REGION: https://yuruna.link/4220a755-002d
# Coordinates, split by whether DHCP can invalidate them. The seed ISO
# carrying this script was burned before Windows Setup ran, and Setup takes
# longer than a short lease, so the address below may already name a host
# that has moved. The hostId and the caching-proxy address cannot go stale --
# one is permanent, the other is pinned by MAC reservation -- and they are
# what let the resolver repair the address.
Set-Content -Path (Join-Path $dir 'host.env') -Encoding Ascii -Value @"
YURUNA_HOST_ID=__HOST_ID__
YURUNA_STATUS_SERVICE_IP=__STATUS_IP__
YURUNA_STATUS_SERVICE_PORT=__STATUS_PORT__
YURUNA_CACHING_PROXY_SERVICE_IP=__CACHE_IP__
YURUNA_FRAMEWORK_URL=__FRAMEWORK_URL__
YURUNA_PROJECT_URL=__PROJECT_URL__
"@

# Seeded, never fetched: this decides WHERE the guest fetches from, so it has
# to arrive over the same trusted channel as the answer file rather than over
# the network it exists to repair.
$locate = Join-Path $dir 'yuruna-host-locate.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'yuruna-host-locate.ps1') -Destination $locate -Force

# Once now, before anything reads the coordinates, so a hint that went stale
# during Setup is corrected on this first logon rather than a minute later.
try {
    & $locate | Out-Null
} catch {
    Write-Output "yuruna-host-locate: first run failed -- $($_.Exception.Message)"
}

# ...and keep it true. SYSTEM because neither the hosts file nor ProgramData is
# writable by the test user, and AtStartup alongside the repeating trigger so a
# guest that boots after the host moved is correct before anyone logs in.
# Best-effort: a guest that cannot register the task still has the coordinates
# written above, and still repaired them once.
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$locate`""
    $atStart = New-ScheduledTaskTrigger -AtStartup
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName 'YurunaHostLocate' -Force `
        -Action $action -Trigger @($atStart, $repeat) -Principal $principal -Settings $settings | Out-Null
} catch {
    Write-Output "yuruna-host-locate: scheduled task registration failed -- $($_.Exception.Message)"
}

# --- REGION: https://yuruna.link/42fa6f45-000c
# See https://yuruna.link/4213a0b3-0004
[Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Machine')
$env:GIT_TERMINAL_PROMPT = '0'

$token = '__TOKEN__'
if (-not $token) { return }
$askpass = Join-Path $dir 'git-askpass.cmd'
Set-Content -Path $askpass -Encoding Ascii -Value @'
@echo off
echo %* | find /i "Username" >nul
if errorlevel 1 (echo %GH_TOKEN%) else (echo x-access-token)
'@

# Machine-scope env vars alongside the profile because a profile only reaches
# the interactive shell of the edition that owns it: pwsh 7 reads a different
# $PROFILE than powershell.exe, and a non-interactive SSH command reads
# neither. Machine scope covers every shell the guest scripts might use.
[Environment]::SetEnvironmentVariable('GH_TOKEN', $token, 'Machine')
[Environment]::SetEnvironmentVariable('GIT_ASKPASS', $askpass, 'Machine')
[Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Machine')
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PROFILE) | Out-Null

# Single-quoted so '$env:...' survives as literal text into the profile. A
# double-quoted value would expand $env:GH_TOKEN while this bootstrap is
# running -- it is empty then -- and silently write ' = <token>' into the
# profile: a broken line, on a VM nobody is watching. The two markers below are
# replaced HERE, at guest run time, by the .Replace() on the last line; the
# seed-time substitution deliberately leaves them alone.
$profileText = @'
$env:GH_TOKEN = '__TOKEN__'
$env:GIT_ASKPASS = '__ASKPASS__'
$env:GIT_TERMINAL_PROMPT = '0'
'@
Add-Content -Path $PROFILE -Value ($profileText.Replace('__TOKEN__', $token).Replace('__ASKPASS__', $askpass))
