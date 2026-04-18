<#
.SYNOPSIS
    Yuruna Windows + Hyper-V bootstrap installer.

.DESCRIPTION
    One-liner bootstrap for a fresh Windows machine. Installs PowerShell 7,
    Git, the Windows ADK Deployment Tools (for oscdimg.exe), Tesseract OCR,
    and enables the Hyper-V Windows Feature. Clones the Yuruna repository
    into $HOME\git\yuruna, seeds test\test-config.json from the template,
    and runs vde\host.windows.hyper-v\Enable-TestAutomation.ps1 to disable
    display timeout and screen lock so Hyper-V screen captures stay readable.

    Idempotent — safe to re-run to pick up updates. On re-run it stops any
    running Yuruna test processes, upgrades installed packages via winget,
    and fast-forwards the repository checkout.

    Requires Administrator elevation. The script will relaunch itself
    elevated if started from a non-admin shell.

.PARAMETER YurunaDir
    Target directory for the repository checkout. Default: $HOME\git\yuruna

.PARAMETER YurunaRepo
    Git URL of the Yuruna repository.

.PARAMETER YurunaBranch
    Branch to check out. Default: main

.EXAMPLE
    # One-liner on a fresh Windows machine (run in Windows PowerShell or pwsh):
    irm https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows-install.ps1 | iex

.EXAMPLE
    # Or from a local clone:
    .\install\windows-install.ps1
#>

[CmdletBinding()]
param(
    [string]$YurunaDir    = (Join-Path $HOME 'git\yuruna'),
    [string]$YurunaRepo   = 'https://github.com/alissonsol/yuruna.git',
    [string]$YurunaBranch = 'main'
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Output "==> $m" }
function Write-Warn { param([string]$m) Write-Warning $m }
function Write-Die  { param([string]$m) Write-Error $m; exit 1 }

# ── Preflight: Windows only ─────────────────────────────────────────────────
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Write-Die 'This installer only supports Windows.'
}

# ── Elevation announcement + self-relaunch ──────────────────────────────────
# Every Yuruna script that needs elevation says so up front rather than
# surprising the user midway through. Match that convention here.
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

@'

  +---------------------------------------------------------------+
  |  This installer needs Administrator privileges for:           |
  |    * winget package installs (PowerShell 7, Git, ADK, ...)    |
  |    * Enable-WindowsOptionalFeature -FeatureName Hyper-V       |
  |    * powercfg / registry edits in                             |
  |      vde\host.windows.hyper-v\Enable-TestAutomation.ps1       |
  |  You will see ONE UAC prompt if the script was not already    |
  |  launched from an elevated shell.                             |
  +---------------------------------------------------------------+

'@ | Write-Output

if (-not $isAdmin) {
    Write-Step 'Relaunching elevated (UAC prompt)'
    # Build an argument list that preserves the caller's parameters. When
    # invoked via `irm | iex` the script has no $PSCommandPath, so in that
    # case re-download and run from a temp file inside the elevated shell.
    if ($PSCommandPath) {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"")
        if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
        if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
        if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } else {
        $bootstrap = @"
`$ErrorActionPreference='Stop'
`$u='https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows-install.ps1'
Invoke-RestMethod `$u | Invoke-Expression
"@
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-Command', $bootstrap)
    }
    exit 0
}

Write-Step "Yuruna Windows installer starting"
Write-Step "  repo   : $YurunaRepo ($YurunaBranch)"
Write-Step "  target : $YurunaDir"

# ── Stop anything that would block an upgrade ──────────────────────────────
function Stop-YurunaProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $patterns = @('Invoke-TestRunner.ps1','Invoke-TestSequence.ps1','Start-StatusServer.ps1')
    foreach ($pat in $patterns) {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$pat*" -and $_.ProcessId -ne $PID }
        foreach ($p in $procs) {
            Write-Step "  stopping $pat (pid $($p.ProcessId))"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    # Free port 8080 if the status server is still holding it.
    try {
        $conns = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            if ($c.OwningProcess -and $c.OwningProcess -ne $PID) {
                Write-Warn "  freeing port 8080 (pid $($c.OwningProcess))"
                Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { Write-Verbose "port 8080 check skipped: $($_.Exception.Message)" }
}

Write-Step 'Stopping anything that would block an upgrade'
Stop-YurunaProcess

# ── winget availability ────────────────────────────────────────────────────
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Die @'
winget is not available on this system. Install "App Installer" from the
Microsoft Store (or update Windows) and re-run this script.
'@
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$FriendlyName = $Id
    )
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null |
        Select-String -SimpleMatch $Id
    if ($installed) {
        Write-Step "  upgrading $FriendlyName (if outdated)"
        winget upgrade --id $Id --exact --silent `
            --accept-package-agreements --accept-source-agreements `
            --disable-interactivity 2>&1 |
            Where-Object { $_ -notmatch 'No applicable upgrade|No installed package' } |
            ForEach-Object { Write-Output "     $_" }
    } else {
        Write-Step "  installing $FriendlyName"
        winget install --id $Id --exact --silent `
            --accept-package-agreements --accept-source-agreements `
            --disable-interactivity
    }
}

Write-Step 'Installing / upgrading required packages via winget'
Install-WingetPackage -Id 'Microsoft.PowerShell'      -FriendlyName 'PowerShell 7'
Install-WingetPackage -Id 'Git.Git'                   -FriendlyName 'Git'
Install-WingetPackage -Id 'Microsoft.WindowsADK'      -FriendlyName 'Windows ADK (Deployment Tools / oscdimg)'
Install-WingetPackage -Id 'UB-Mannheim.TesseractOCR'  -FriendlyName 'Tesseract OCR'

# Refresh PATH in the current session so pwsh.exe / git.exe / oscdimg.exe
# become reachable without opening a new terminal.
Write-Step 'Refreshing PATH in current session'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

foreach ($cmd in 'git','pwsh') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Warn "$cmd not yet on PATH — you may need to open a new terminal."
    }
}

# ── Hyper-V feature ────────────────────────────────────────────────────────
Write-Step 'Enabling Hyper-V Windows Feature (if not already enabled)'
$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
if (-not $feature) {
    Write-Warn 'Microsoft-Hyper-V-All feature not available on this SKU (Home edition?). Skipping.'
} elseif ($feature.State -ne 'Enabled') {
    $result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
    if ($result.RestartNeeded) {
        Write-Warn 'Hyper-V was just enabled — a RESTART is required before Invoke-TestRunner will work.'
        $script:RestartNeeded = $true
    }
} else {
    Write-Step '  Hyper-V already enabled'
}

# ── Clone / update the repo ────────────────────────────────────────────────
$gitExe = (Get-Command git -ErrorAction SilentlyContinue)?.Source
if (-not $gitExe) { Write-Die 'git not found after install — open a new terminal and re-run.' }

$parent = Split-Path -Parent $YurunaDir
if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

if (Test-Path (Join-Path $YurunaDir '.git')) {
    Write-Step "Updating existing Yuruna checkout at $YurunaDir"
    & $gitExe -C $YurunaDir fetch --tags origin
    & $gitExe -C $YurunaDir checkout $YurunaBranch
    & $gitExe -C $YurunaDir pull --ff-only origin $YurunaBranch 2>&1 | ForEach-Object {
        if ($_ -match 'Already up to date|Fast-forward|Updating') { Write-Output "     $_" }
        else { Write-Warn $_ }
    }
} else {
    Write-Step "Cloning Yuruna into $YurunaDir"
    & $gitExe clone --branch $YurunaBranch $YurunaRepo $YurunaDir
}

# ── Seed test-config.json from template ───────────────────────────────────
$testDir = Join-Path $YurunaDir 'test'
$cfg     = Join-Path $testDir 'test-config.json'
$tpl     = Join-Path $testDir 'test-config.json.template'
if (-not (Test-Path $cfg) -and (Test-Path $tpl)) {
    Write-Step 'Creating test\test-config.json from template (review before running tests)'
    Copy-Item $tpl $cfg
}

# ── Host configuration (display timeout, screen lock, etc.) ───────────────
$setHost = Join-Path $YurunaDir 'vde\host.windows.hyper-v\Enable-TestAutomation.ps1'
if (Test-Path $setHost) {
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $pwshExe) {
        Write-Warn 'pwsh not on PATH yet — skipping vde\host.windows.hyper-v\Enable-TestAutomation.ps1. Open a new terminal and run it manually.'
    } else {
        Write-Step 'Running vde\host.windows.hyper-v\Enable-TestAutomation.ps1'
        & $pwshExe -NoLogo -NoProfile -File $setHost
    }
} else {
    Write-Warn "vde\host.windows.hyper-v\Enable-TestAutomation.ps1 not found under $YurunaDir — skipping host config."
}

# ── Done ───────────────────────────────────────────────────────────────────
@"

==> Yuruna is ready.

Next steps (in order):

  1. Open a NEW PowerShell window (so the updated PATH and any freshly
     installed pwsh.exe / git.exe / oscdimg.exe are picked up). Inside that
     new window you can use 'pwsh' instead of 'powershell' from here on.

"@ | Write-Output

if ($script:RestartNeeded) {
    Write-Warning '  2. RESTART Windows — Hyper-V was just enabled and needs a reboot.'
    Write-Warning '     After the reboot, continue with step 3.'
    Write-Output ''
}

@"
  3. Review and edit the test config:
       notepad $cfg

  4. Launch the Hyper-V Manager once so it registers with your account and
     surfaces any first-run dialogs:
       Start-Process virtmgmt.msc

  5. Run the test harness from the new pwsh window:
       cd $testDir
       pwsh .\Invoke-TestRunner.ps1

Re-running this installer is safe; it will upgrade winget packages and
fast-forward the Yuruna checkout when possible.
"@ | Write-Output
