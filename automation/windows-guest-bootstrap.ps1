<#PSScriptInfo
.VERSION 2026.11.05
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
YURUNA_GITHUB_REPO=__GITHUB_REPO__
YURUNA_GITHUB_REF=__GITHUB_REF__
YURUNA_FRAMEWORK_URL=__FRAMEWORK_URL__
YURUNA_PROJECT_URL=__PROJECT_URL__
"@

# The host's guest-channel key: the resolver accepts a status service only when
# it proves this key, so a directory answer cannot move this guest to another
# responder. Empty for a host that has none, which leaves the probe unverified.
Set-Content -Path (Join-Path $dir 'guest-channel.key') -Encoding Ascii -Value '__GUEST_CHANNEL_KEY__'

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

# The seed CD carries this script, with the repository token, and the answer
# file, with the default password, in plain text, and every account on the
# guest can read CD media. Nothing reads it after the copy above, so ask
# Windows to eject it. Best-effort: a hypervisor that ignores a guest eject
# leaves the media attached as before.
try {
    $seedDrive = (Split-Path -Qualifier $PSScriptRoot) + '\'
    $seedItem = (New-Object -ComObject Shell.Application).Namespace(17).ParseName($seedDrive)
    if ($seedItem) { $seedItem.InvokeVerb('Eject') }
} catch {
    Write-Output "yuruna seed media: eject failed -- $($_.Exception.Message)"
}

# --- REGION: https://yuruna.link/42fa6f45-000c
# See https://yuruna.link/4213a0b3-0004
[Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Machine')
$env:GIT_TERMINAL_PROMPT = '0'

$token = '__TOKEN__'
if (-not $token) { return }

# The token lives in the user's own profile directory, readable only by that
# user and SYSTEM. A Machine-scope variable would hand it to every account and
# service on the guest.
$tokenDir = Join-Path $env:USERPROFILE '.config\yuruna'
New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null
$tokenFile = Join-Path $tokenDir 'github-token'
[IO.File]::WriteAllText($tokenFile, $token)
$tokenAcl = New-Object System.Security.AccessControl.FileSecurity
$tokenAcl.SetAccessRuleProtection($true, $false)
foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'))) {
    $tokenAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
}
Set-Acl -LiteralPath $tokenFile -AclObject $tokenAcl

# The URL-scoped helper is git's own way to keep a credential to one host: git
# consults it for https://github.com remotes only, and the empty entry first
# drops Git Credential Manager for that host so no dialog can appear. The
# helper still checks the protocol and host git hands it.
$helper = Join-Path $dir 'git-credential-github.ps1'
Set-Content -Path $helper -Encoding Ascii -Value @'
if ($args.Count -lt 1 -or $args[0] -ne 'get') { exit 0 }
$fields = @{}
while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ($line -eq '') { break }
    $i = $line.IndexOf('=')
    if ($i -gt 0) { $fields[$line.Substring(0, $i)] = $line.Substring($i + 1) }
}
if ($fields['protocol'] -ne 'https' -or $fields['host'] -ne 'github.com') { exit 0 }
$token = $env:GH_TOKEN
if (-not $token) {
    $file = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/yuruna/github-token'
    if (Test-Path -LiteralPath $file) { $token = ([IO.File]::ReadAllText($file)).Trim() }
}
if (-not $token) { exit 0 }
[Console]::Out.Write("username=x-access-token`npassword=$token`n")
'@
Add-Content -Path (Join-Path $env:USERPROFILE '.gitconfig') -Encoding Ascii -Value @"
[credential "https://github.com"]
    helper =
    helper = "!powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $($helper.Replace('\', '/'))"
"@

$askpass = Join-Path $dir 'git-askpass.cmd'
Set-Content -Path $askpass -Encoding Ascii -Value @'
@echo off
rem Answers github.com alone; any other host a remote names gets nothing.
echo %* | findstr /i /c:"//github.com'" /c:"@github.com'" >nul
if errorlevel 1 (echo.& exit /b 0)
echo %* | find /i "Username" >nul
if not errorlevel 1 (echo x-access-token& exit /b 0)
if defined GH_TOKEN (echo %GH_TOKEN%& exit /b 0)
if exist "%USERPROFILE%\.config\yuruna\github-token" (type "%USERPROFILE%\.config\yuruna\github-token"& echo.& exit /b 0)
echo.
'@

# Machine scope for the non-secret settings, because a profile only reaches the
# interactive shell of the edition that owns it: pwsh 7 reads a different
# $PROFILE than powershell.exe, and a non-interactive SSH command reads neither.
# The helper and the askpass shim read the token file themselves, so no shell
# needs the token in its environment.
[Environment]::SetEnvironmentVariable('GIT_ASKPASS', $askpass, 'Machine')
[Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Machine')
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PROFILE) | Out-Null

# Single-quoted so the '$env:...' text survives as written into the profile.
# The __ASKPASS__ marker is replaced HERE, at guest run time, by the .Replace()
# on the last line; the seed-time substitution deliberately leaves it alone.
$profileText = @'
if (Test-Path -LiteralPath "$env:USERPROFILE\.config\yuruna\github-token") { $env:GH_TOKEN = [IO.File]::ReadAllText("$env:USERPROFILE\.config\yuruna\github-token").Trim() }
$env:GIT_ASKPASS = '__ASKPASS__'
$env:GIT_TERMINAL_PROMPT = '0'
'@
Add-Content -Path $PROFILE -Value ($profileText.Replace('__ASKPASS__', $askpass))
