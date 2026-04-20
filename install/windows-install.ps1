<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456700
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    Yuruna Windows + Hyper-V bootstrap installer.

.DESCRIPTION
    One-liner bootstrap for a fresh Windows machine. Installs PowerShell 7,
    Git, the Windows ADK Deployment Tools (for oscdimg.exe), QEMU tools
    (for qemu-img used by guest.squid-cache/Get-Image.ps1), Tesseract OCR,
    and enables the Hyper-V Windows Feature. Clones the Yuruna repository
    into $HOME\git\yuruna, seeds test\test-config.json from the template,
    and runs vde\host.windows.hyper-v\Enable-TestAutomation.ps1 to disable
    display timeout and screen lock so Hyper-V screen captures stay readable.

    Idempotent -- safe to re-run to pick up updates. On re-run it stops any
    running Yuruna test processes, upgrades installed packages via winget,
    and fast-forwards the repository checkout.

    Startup shell -- works from either Windows PowerShell 5.1 (the only
    shell a fresh Windows 11 ships with) or pwsh.exe (7+). The script is
    written in PS 5.1-compatible syntax through the self-relaunch block,
    then:
      1. Elevates itself if started unelevated (UAC). The new elevated
         shell is whichever one the user started from -- powershell.exe
         on PS 5.1, pwsh.exe on PS 7+.
      2. If still running in PS 5.1 after elevation, installs pwsh.exe
         via winget, refreshes PATH, and re-executes this same script
         under pwsh. The rest of Yuruna's harness also runs on pwsh so
         unifying the shell version here means the user never has to
         switch consoles mid-install.

    Requires Administrator elevation. The script will relaunch itself
    elevated if started from a non-admin shell. Requires winget ("App
    Installer" from the Microsoft Store) which ships with Windows 11.

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

# -- Preflight: Windows only -------------------------------------------------
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Write-Die 'This installer only supports Windows.'
}

# -- Elevation announcement + self-relaunch ----------------------------------
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
    # Preserve the shell the user started from -- powershell.exe on PS 5.1,
    # pwsh.exe on PS 7+ -- so a pwsh session doesn't get silently
    # downgraded to Windows PowerShell across the UAC boundary. If the
    # current process path can't be read (unusual but possible on locked-
    # down hosts), fall back to powershell.exe which is always present.
    $currentShellExe = $null
    try { $currentShellExe = (Get-Process -Id $PID).Path } catch { $currentShellExe = $null }
    if (-not $currentShellExe) { $currentShellExe = 'powershell.exe' }
    # Build an argument list that preserves the caller's parameters. When
    # invoked via `irm | iex` the script has no $PSCommandPath, so in that
    # case re-download and run from a temp file inside the elevated shell.
    if ($PSCommandPath) {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"")
        if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
        if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
        if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
        Start-Process -FilePath $currentShellExe -Verb RunAs -ArgumentList $argList
    } else {
        $bootstrap = @"
`$ErrorActionPreference='Stop'
`$u='https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows-install.ps1'
Invoke-RestMethod `$u | Invoke-Expression
"@
        Start-Process -FilePath $currentShellExe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-Command', $bootstrap)
    }
    exit 0
}

Write-Step "Yuruna Windows installer starting"
Write-Step "  repo   : $YurunaRepo ($YurunaBranch)"
Write-Step "  target : $YurunaDir"
Write-Step "  shell  : $((Get-Process -Id $PID).ProcessName) (PowerShell $($PSVersionTable.PSVersion))"

# -- PowerShell 7 bootstrap ------------------------------------------------
# Fresh Windows 11 ships Windows PowerShell 5.1 only. The rest of Yuruna --
# every pwsh-shebanged script under test/ and vde/ -- expects pwsh 7+. If we
# are still in PS 5.x after elevation, install pwsh via winget, refresh
# PATH so pwsh.exe resolves in this same session, and re-execute this
# script under pwsh. The child inherits the elevated token, so no second
# UAC prompt. The parent exits with the child's exit code so a caller
# chaining this install with `&&` or checking $LASTEXITCODE sees the
# right outcome.
#
# This block must stay PS 5.1-compatible (no ?./??/ternary/chain ops) --
# the whole file is parsed up-front, and even one PS 7-only token would
# fail the file to load on 5.1 before this check can run.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Step 'Bootstrapping PowerShell 7 (Windows PowerShell 5.x detected)'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Die @'
winget is not available on this system. Install "App Installer" from the
Microsoft Store (or update Windows) and re-run this script.
'@
    }
    # Pin --source winget on every call. Without the pin, winget searches
    # every registered source (including msstore) and fails hard when one
    # of them has a stale/untrusted server cert, even if the package was
    # found in the trusted `winget` source. Seen in the wild as:
    #   Failed when searching source: msstore
    #   0x8a15005e : The server certificate did not match any of the
    #                expected values.
    # When that happens winget refuses to pick a source automatically and
    # aborts the install with "Please specify one of them using the
    # --source option to proceed." -- so pinning sidesteps the disamb.
    $pwshPkg = winget list --id 'Microsoft.PowerShell' --exact --source winget --accept-source-agreements 2>$null |
        Select-String -SimpleMatch 'Microsoft.PowerShell'
    if (-not $pwshPkg) {
        Write-Step '  installing PowerShell 7 via winget'
        winget install --id 'Microsoft.PowerShell' --exact --silent --source winget `
            --accept-package-agreements --accept-source-agreements `
            --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Write-Die "winget install Microsoft.PowerShell exited $LASTEXITCODE. Re-run after resolving the winget source error shown above (e.g. 'winget source reset --force' from an elevated prompt)."
        }
    } else {
        Write-Step '  PowerShell 7 already installed (winget reports present)'
    }
    # Refresh PATH in the current PS 5.1 session so pwsh.exe resolves. The
    # winget install adds C:\Program Files\PowerShell\7 to the Machine PATH
    # but the running shell keeps a stale copy until we merge it in.
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshCmd) {
        Write-Die @'
pwsh.exe is still not on PATH after the winget install. Open a NEW
elevated PowerShell window (so it inherits the updated Machine PATH) and
re-run this installer.
'@
    }
    Write-Step "  Re-executing under $($pwshCmd.Source)"
    # Same param-forwarding dance as the elevation block. When invoked via
    # `irm | iex` there is no $PSCommandPath, so we re-download the script
    # to a temp file and hand THAT to pwsh. Synchronous `&` call so the
    # user sees all further output in this single console, and exit code
    # propagates. Run the rest under the child pwsh and terminate here.
    if ($PSCommandPath) {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"")
        if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
        if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
        if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
        & $pwshCmd.Source $argList
        exit $LASTEXITCODE
    } else {
        $tmp = Join-Path $env:TEMP ("yuruna-windows-install-" + [guid]::NewGuid().ToString('N') + '.ps1')
        $u   = 'https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows-install.ps1'
        Invoke-RestMethod $u | Set-Content -Path $tmp -Encoding UTF8
        try {
            & $pwshCmd.Source -NoProfile -ExecutionPolicy Bypass -File $tmp
            exit $LASTEXITCODE
        } finally {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# -- Stop anything that would block an upgrade ------------------------------
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

# -- winget availability ----------------------------------------------------
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
    # --source winget on every call -- see the PS 7 bootstrap block above
    # for the msstore-cert rationale; same hazard applies to every other
    # package we install.
    $installed = winget list --id $Id --exact --source winget --accept-source-agreements 2>$null |
        Select-String -SimpleMatch $Id
    if ($installed) {
        Write-Step "  upgrading $FriendlyName (if outdated)"
        winget upgrade --id $Id --exact --silent --source winget `
            --accept-package-agreements --accept-source-agreements `
            --disable-interactivity 2>&1 |
            Where-Object { $_ -notmatch 'No applicable upgrade|No installed package' } |
            ForEach-Object { Write-Output "     $_" }
    } else {
        Write-Step "  installing $FriendlyName"
        winget install --id $Id --exact --silent --source winget `
            --accept-package-agreements --accept-source-agreements `
            --disable-interactivity
    }
}

Write-Step 'Installing / upgrading required packages via winget'
Install-WingetPackage -Id 'Microsoft.PowerShell'              -FriendlyName 'PowerShell 7'
Install-WingetPackage -Id 'Git.Git'                           -FriendlyName 'Git (brings openssl.exe used by Ubuntu guest New-VM.ps1 password hashing)'
Install-WingetPackage -Id 'Microsoft.WindowsADK'              -FriendlyName 'Windows ADK (Deployment Tools / oscdimg)'
Install-WingetPackage -Id 'SoftwareFreedomConservancy.QEMU'   -FriendlyName 'QEMU tools (qemu-img for guest.squid-cache/Get-Image.ps1)'
Install-WingetPackage -Id 'UB-Mannheim.TesseractOCR'          -FriendlyName 'Tesseract OCR'

# Refresh PATH in the current session so pwsh.exe / git.exe / oscdimg.exe
# become reachable without opening a new terminal.
Write-Step 'Refreshing PATH in current session'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

foreach ($cmd in 'git','pwsh') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Warn "$cmd not yet on PATH -- you may need to open a new terminal."
    }
}

# -- Hyper-V feature --------------------------------------------------------
# Call DISM.exe directly rather than Get-/Enable-WindowsOptionalFeature.
# Those cmdlets dispatch to the DISM provider via COM, and on some pwsh 7
# sessions the COM class fails to resolve with "Class not registered"
# (HRESULT 0x80040154). That terminates the script on re-runs; and when
# -ErrorAction SilentlyContinue silences it on the first run, $feature
# becomes $null and the enable step is skipped without the user noticing
# -- which is why the first run of this installer can leave Hyper-V off.
# DISM.exe is a plain Win32 tool with no COM dependency and is what the
# cmdlets wrap internally.
Write-Step 'Enabling Hyper-V Windows Feature (if not already enabled)'
$dismExe = Join-Path $env:WINDIR 'System32\dism.exe'
$infoOut  = & $dismExe /English /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
$infoExit = $LASTEXITCODE
if ($infoExit -ne 0) {
    if ($infoOut -match '0x800f080c' -or $infoOut -match 'Feature name .* is unknown') {
        Write-Warn 'Microsoft-Hyper-V-All feature not available on this SKU (Home edition?). Skipping.'
    } else {
        Write-Die "dism.exe /Get-FeatureInfo exited $infoExit. Output:`n$($infoOut -join [Environment]::NewLine)"
    }
} else {
    $state = 'Unknown'
    foreach ($line in $infoOut) {
        if ($line -match '^State\s*:\s*(\S+)') { $state = $Matches[1]; break }
    }
    if ($state -eq 'Enabled') {
        Write-Step '  Hyper-V already enabled'
    } else {
        Write-Step "  current state: $state -- enabling"
        $enableOut  = & $dismExe /English /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart /Quiet 2>&1
        $enableExit = $LASTEXITCODE
        # DISM: 0 = success, 3010 = success + reboot required.
        if ($enableExit -eq 0 -or $enableExit -eq 3010) {
            Write-Warn 'Hyper-V was just enabled -- a RESTART is required before Invoke-TestRunner will work.'
            $script:RestartNeeded = $true
        } else {
            Write-Die "dism.exe /Enable-Feature exited $enableExit. Output:`n$($enableOut -join [Environment]::NewLine)"
        }
    }
}

# -- Clone / update the repo ------------------------------------------------
# Pre-PS7 fallback -- null-conditional ?.Source doesn't parse on PS 5.1,
# and this whole file still has to load cleanly in 5.1 for the bootstrap
# block above to fire. Resolve via an intermediate variable.
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
$gitExe = if ($gitCmd) { $gitCmd.Source } else { $null }
if (-not $gitExe) { Write-Die 'git not found after install -- open a new terminal and re-run.' }

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

# -- Seed test-config.json from template -----------------------------------
$testDir = Join-Path $YurunaDir 'test'
$cfg     = Join-Path $testDir 'test-config.json'
$tpl     = Join-Path $testDir 'test-config.json.template'
if (-not (Test-Path $cfg) -and (Test-Path $tpl)) {
    Write-Step 'Creating test\test-config.json from template (review before running tests)'
    Copy-Item $tpl $cfg
}

# -- Host configuration (display timeout, screen lock, etc.) ---------------
$setHost = Join-Path $YurunaDir 'vde\host.windows.hyper-v\Enable-TestAutomation.ps1'
if (Test-Path $setHost) {
    # Same PS 5.1-safe resolution pattern as $gitExe above. By this point
    # we are guaranteed to be under pwsh (the PS 7 bootstrap re-exec'd if
    # we weren't), so this will always find pwsh.exe; the fallback is
    # defensive for anyone running with -Command against the raw script.
    $pwshCmd2 = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe  = if ($pwshCmd2) { $pwshCmd2.Source } else { $null }
    if (-not $pwshExe) {
        Write-Warn 'pwsh not on PATH yet -- skipping vde\host.windows.hyper-v\Enable-TestAutomation.ps1. Open a new terminal and run it manually.'
    } else {
        Write-Step 'Running vde\host.windows.hyper-v\Enable-TestAutomation.ps1'
        & $pwshExe -NoLogo -NoProfile -File $setHost
    }
} else {
    Write-Warn "vde\host.windows.hyper-v\Enable-TestAutomation.ps1 not found under $YurunaDir -- skipping host config."
}

# -- Done -------------------------------------------------------------------
@"

==> Yuruna is ready.

Next steps (in order):

  1. Open a NEW PowerShell window (so the updated PATH and any freshly
     installed pwsh.exe / git.exe / oscdimg.exe are picked up). Inside that
     new window you can use 'pwsh' instead of 'powershell' from here on.

"@ | Write-Output

if ($script:RestartNeeded) {
    Write-Warning '  2. RESTART Windows -- Hyper-V was just enabled and needs a reboot.'
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
