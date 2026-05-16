<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456700
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Yuruna Windows + Hyper-V bootstrap installer.

.DESCRIPTION
    One-liner bootstrap for a fresh Windows machine. Installs PowerShell 7,
    Git, the Windows ADK Deployment Tools (for oscdimg.exe), QEMU tools
    (for qemu-img used by guest.squid-cache/Get-Image.ps1), Tesseract OCR,
    and enables the Hyper-V Windows Feature. Clones the Yuruna repository
    into $HOME\git\yuruna, seeds test\test.config.yml from the template,
    and runs host\windows.hyper-v\Enable-TestAutomation.ps1 to disable
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
    irm https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1 | iex

.EXAMPLE
    # Or from a local clone:
    .\install\windows.hyper-v.ps1
#>

# --- See https://yuruna.link/memory#why-the-bootstrap-installer-must-stay-ascii-only
# (this file MUST stay 7-bit ASCII; no BOM; no Unicode -- see link above)
[CmdletBinding()]
param(
    [string]$YurunaDir    = (Join-Path $HOME 'git\yuruna'),
    [string]$YurunaRepo   = 'https://github.com/alissonsol/yuruna.git',
    [string]$YurunaBranch = 'main',
    # Internal: set by every self-relaunch site (UAC elevation + PS5->PS7
    # bootstrap) so the operator only sees the requirements prompt once,
    # in their original un-elevated shell. A user could pass this
    # manually as an "I know what I am doing" override.
    [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Output "==> $m" }
function Write-Warn { param([string]$m) Write-Warning $m }
function Write-Die  { param([string]$m) Write-Error $m }  # Write-Error under $ErrorActionPreference='Stop' already throws; no `exit 1` so an uncaught Die-path error doesn't close the user's hosting shell.

# -- Preflight: Windows only -------------------------------------------------
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Write-Die 'This installer only supports Windows.'
}

# -- System requirements: warn + confirm if below the tested baseline -------
# Tested baseline (Windows host):
#   32 GB RAM, 512 GB free on the system drive, Windows 11 Pro / Enterprise /
#   Education or Windows Server with Hyper-V on AMD64, 16+ physical cores.
# Anything below is permitted but UNTESTED -- prompt the operator before
# proceeding so an under-spec'd host does not burn an hour of installs only
# to fail in the first test cycle. The function is silent when every
# requirement is met. Gated by -SkipPreflight so self-relaunches (UAC
# elevation, PS5->PS7 bootstrap) do not re-prompt.
function Test-SystemRequirement {
    $issues = New-Object System.Collections.Generic.List[string]
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { $null = $issues.Add("could not read Win32_OperatingSystem: $($_.Exception.Message)") }
    $caption = if ($os) { $os.Caption } else { 'unknown' }
    if ($os) {
        $isWindows11ProClass = $caption -match 'Windows 11 (Pro|Enterprise|Education)'
        $isWindowsServer     = $caption -match 'Windows Server'
        if (-not ($isWindows11ProClass -or $isWindowsServer)) {
            $null = $issues.Add("Windows edition '$caption' detected (need Windows 11 Pro/Enterprise/Education or Windows Server with Hyper-V)")
        }
    }
    $archEnv = $env:PROCESSOR_ARCHITECTURE
    if ($archEnv -ne 'AMD64') {
        $null = $issues.Add("architecture '$archEnv' detected (need AMD64/x86_64)")
    }
    $cores = 0
    try {
        $cores = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfCores -Sum).Sum
    } catch {
        Write-Verbose "Win32_Processor query failed: $($_.Exception.Message); treating physical-core count as 0."
    }
    if (-not $cores) { $cores = 0 }
    if ($cores -lt 16) {
        $null = $issues.Add("$cores physical cores detected (need 16+)")
    }
    $memGB = 0
    if ($os) { $memGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0) }  # TotalVisibleMemorySize is KB; KB / 1MB = GB
    if ($memGB -lt 32) {
        $null = $issues.Add("${memGB}GB RAM detected (need 32GB+)")
    }
    $freeGB = 0
    $sysDriveLetter = $env:SystemDrive
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDriveLetter'" -ErrorAction Stop
        if ($disk) { $freeGB = [math]::Round($disk.FreeSpace / 1GB, 0) }
    } catch {
        Write-Verbose "Win32_LogicalDisk query for $sysDriveLetter failed: $($_.Exception.Message); treating free space as 0 GB."
    }
    if ($freeGB -lt 512) {
        $null = $issues.Add("${freeGB}GB free on $sysDriveLetter (need 512GB+)")
    }
    if ($issues.Count -eq 0) {
        Write-Step "System OK: $caption, $archEnv, $cores cores, ${memGB}GB RAM, ${freeGB}GB free on $sysDriveLetter"
        return
    }
    Write-Warning ''
    Write-Warning '============================================================'
    Write-Warning '  System does not meet Yuruna TESTED requirements:'
    foreach ($i in $issues) { Write-Warning "    - $i" }
    Write-Warning ''
    Write-Warning '  Tested baseline (Windows host):'
    Write-Warning '    32GB RAM, 512GB free, Windows 11 Pro/Enterprise/Education'
    Write-Warning '    or Windows Server with Hyper-V on AMD64, 16+ cores.'
    Write-Warning ''
    Write-Warning '  Continuing is permitted but UNTESTED; the test harness may'
    Write-Warning '  fail in ways the core development team cannot reproduce.'
    Write-Warning '============================================================'
    Write-Warning ''
    $ans = Read-Host 'Continue anyway? [y/N]'
    if ($ans -notmatch '^[Yy](es)?$') {
        Write-Die 'Aborted by user (system requirements not met).'
    }
    Write-Warning 'Proceeding despite unmet requirements.'
}

if (-not $SkipPreflight) {
    Test-SystemRequirement
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
  |    * enabling the Hyper-V Windows Feature (via DISM.exe)      |
  |    * powercfg / registry edits in                             |
  |      host\windows.hyper-v\Enable-TestAutomation.ps1       |
  |  All of the above are run automatically -- you do NOT need    |
  |  to type any command yourself. You will see ONE UAC prompt    |
  |  if the script was not already launched from an elevated      |
  |  shell.                                                       |
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
        # -SkipPreflight: preflight already ran in this (un-elevated) shell
        # and the operator already answered Y. The elevated child runs in a
        # new console; we do not want to re-prompt them there.
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"", '-SkipPreflight')
        if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
        if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
        if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
        Start-Process -FilePath $currentShellExe -Verb RunAs -ArgumentList $argList
    } else {
        # iex path: the downloaded script has no $PSCommandPath, and `iex`
        # itself does not forward args to the invoked code. Parse the
        # download as a scriptblock and invoke it with -SkipPreflight so
        # the elevated child does not re-prompt the requirements check.
        $bootstrap = @"
`$ErrorActionPreference='Stop'
`$u='https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1'
`$src = Invoke-RestMethod `$u
`$sb  = [scriptblock]::Create(`$src)
& `$sb -SkipPreflight
"@
        Start-Process -FilePath $currentShellExe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-Command', $bootstrap)
    }
    # `return` instead of `exit` -- `exit` at the script's top level
    # terminates the hosting PowerShell process, which would close the
    # user's own shell when the script is invoked via `irm | iex` in
    # their non-admin console. `return` exits only the script scope,
    # leaving the user's window intact while the self-spawned admin
    # window does the real work.
    return
}

Write-Step "Yuruna Windows installer starting"
Write-Step "  repo   : $YurunaRepo ($YurunaBranch)"
Write-Step "  target : $YurunaDir"
Write-Step "  shell  : $((Get-Process -Id $PID).ProcessName) (PowerShell $($PSVersionTable.PSVersion))"

# -- PowerShell 7 bootstrap ------------------------------------------------
# Fresh Windows 11 ships Windows PowerShell 5.1 only. The rest of Yuruna --
# every pwsh-shebanged script under test/, host/, and guest/ -- expects pwsh 7+. If we
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
    # --source option to proceed." -- so pinning sidesteps the disambiguation.
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
    # user sees all further output in this single console. Using `return`
    # instead of `exit` so that if this block runs in the user's own
    # admin PS 5.x shell (not a self-spawned one), the script ends but
    # their session stays open; $LASTEXITCODE is already set by the
    # `&` invocation above and remains visible to the caller.
    if ($PSCommandPath) {
        # Same -SkipPreflight rationale as the elevation block: preflight
        # already ran in this elevated PS5 shell; the re-exec under pwsh
        # must not re-prompt the operator.
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"", '-SkipPreflight')
        if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
        if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
        if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
        & $pwshCmd.Source $argList
        return
    } else {
        $tmp = Join-Path $env:TEMP ("yuruna-windows-hyper-v-" + [guid]::NewGuid().ToString('N') + '.ps1')
        $u   = 'https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1'
        Invoke-RestMethod $u | Set-Content -Path $tmp -Encoding UTF8
        try {
            & $pwshCmd.Source -NoProfile -ExecutionPolicy Bypass -File $tmp -SkipPreflight
            return
        } finally {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# -- Stop anything that would block an upgrade ------------------------------
function Stop-YurunaProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    # Outer runner, per-cycle inner (now under modules/), dev sequence
    # helper, status server. The Invoke-TestRunner.ps1 pattern is a
    # substring of itself only -- it does NOT match Invoke-TestInner-
    # Runner.ps1, so the inner needs its own entry to be killed too.
    $patterns = @('Invoke-TestRunner.ps1','Invoke-TestInnerRunner.ps1','Confirm-Sequence.ps1','Start-StatusServer.ps1')
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

# -- yuruna-caching-proxy preservation ----------------------------------------
# A running cache VM (yuruna-caching-proxy, formerly squid-cache) holds
# tens of GB of pre-fetched .deb / .iso content built up across prior
# test cycles. The installer never stops Hyper-V VMs (vmms keeps
# running, no Stop-VM / Remove-VM in this script), so the cache
# survives re-runs by default. This helper surfaces that fact in the
# install log -- if a future change ever adds a Stop-VM / Stop-Service
# vmms in this script, the operator sees the "preserving cached
# content" line right before it and can flag the regression instead of
# having to rebuild squid's spool from scratch (10-20 minutes of LAN
# apt traffic on first re-prime).
function Test-SquidCacheRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy')
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return $false }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    return ($vm -and $vm.State -eq 'Running')
}

# Everything from here to the matching finally runs the actual install.
# Wrapped in try/catch/finally so that ANY failure (Write-Die, a winget
# non-zero exit, a DISM failure, a throw from a called module, ...) still
# lands in the finally block where we print a clear SUCCESS / FAILED
# summary and pause with Read-Host. Without this wrap, the admin window
# spawned by Start-Process -Verb RunAs closes the instant the script
# exits, and the user never gets to read the final status.
$script:InstallSucceeded   = $false
$script:InstallError       = $null
# Set when 'git pull --ff-only' could not advance the local repo and the
# clone/update block had to move the existing checkout aside as a
# timestamped backup. Read by the finally{} success/fallback paths so the
# operator sees the backup location loudly in the spawned pwsh window
# (and in the admin-console fallback when the spawn fails).
$script:YurunaBackupCreated = $null
try {

if (Test-SquidCacheRunning) {
    Write-Step 'yuruna-caching-proxy VM is running -- preserving cached content (no Stop-VM / Remove-VM in this installer)'
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
        # DISM flips State to "Enabled" immediately after /Enable-Feature,
        # but the Hyper-V *components* (vmms service, virtmgmt.msc) are
        # only deployed once the pending reboot runs. On a second pass
        # before that reboot, /Get-FeatureInfo still says "Enabled" even
        # though nothing actually works -- which is why a second run of
        # this installer used to plough past this block, call Enable-
        # TestAutomation.ps1 (which complained "vmms not installed -- run
        # Enable-WindowsOptionalFeature..."), and then fail to launch
        # virtmgmt.msc with "file not found". Three contradictory signals
        # for one underlying condition: reboot pending.
        #
        # So: cross-check DISM's "Enabled" against the presence of vmms
        # and virtmgmt.msc. If either is missing, treat it the same as
        # just-enabled and set RestartNeeded -- the rest of the script
        # (the skip of Enable-TestAutomation.ps1, the finally-block
        # RESTART REQUIRED path) then gives the user one clear message.
        $vmmsExists     = [bool](Get-Service -Name vmms -ErrorAction SilentlyContinue)
        $virtmgmtExists = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\virtmgmt.msc')
        if ($vmmsExists -and $virtmgmtExists) {
            Write-Step '  Hyper-V already enabled and deployed'
        } else {
            Write-Warn '  Hyper-V reports Enabled but the components are not deployed yet'
            if (-not $vmmsExists)     { Write-Warn '    (vmms service is missing)' }
            if (-not $virtmgmtExists) { Write-Warn '    (virtmgmt.msc is missing)' }
            Write-Warn '  This means a Windows RESTART from a previous run of this'
            Write-Warn '  installer is still pending. Reboot and re-run to finish.'
            $script:RestartNeeded = $true
        }
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

# -- Preserve test/status runtime state across the clone/update -------------
# Re-running the installer on a host that's been executing test cycles
# must not lose the dashboard's history, per-cycle log transcripts, or
# the track-dir state (status.json with history[], runner.gating.json,
# runner.pid, control flags). None of those are tracked by git -- per
# .gitignore they live under test/status/{track,log}/ as runtime
# artifacts. The clone/update/renormalize block below is designed to
# leave untracked files alone (`git rm -r --cached . && git reset --hard
# HEAD` only touches tracked files), but we backstop that contract with
# an explicit snapshot-and-restore so a future regression in the
# renormalize logic, or a manual Remove-Item -Recurse on YurunaDir
# between attempts, can't silently wipe weeks of cycle history.
$YurunaStatusBackup = $null
function Backup-YurunaStatus {
    $src = Join-Path $YurunaDir 'test/status'
    if (-not (Test-Path $src)) { return }
    $hasRuntime = $false
    foreach ($sub in @('track', 'log')) {
        $subPath = Join-Path $src $sub
        if (-not (Test-Path $subPath)) { continue }
        $extras = Get-ChildItem -LiteralPath $subPath -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' }
        if ($extras) { $hasRuntime = $true; break }
    }
    if (-not $hasRuntime) { return }
    $script:YurunaStatusBackup = Join-Path $env:TEMP "yuruna-status-backup-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:YurunaStatusBackup -Force | Out-Null
    Write-Step "Preserving test/status runtime state (cycle history, logs)"
    Write-Step "  source : $src"
    Write-Step "  backup : $($script:YurunaStatusBackup)"
    foreach ($sub in @('track', 'log')) {
        $subPath = Join-Path $src $sub
        if (Test-Path $subPath) {
            Copy-Item -LiteralPath $subPath -Destination $script:YurunaStatusBackup -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
function Restore-YurunaStatus {
    if (-not $script:YurunaStatusBackup -or -not (Test-Path $script:YurunaStatusBackup)) { return }
    $dst = Join-Path $YurunaDir 'test/status'
    Write-Step 'Restoring preserved test/status runtime state'
    foreach ($sub in @('track', 'log')) {
        $bsub = Join-Path $script:YurunaStatusBackup $sub
        if (Test-Path $bsub) {
            $dsub = Join-Path $dst $sub
            if (-not (Test-Path $dsub)) { New-Item -ItemType Directory -Path $dsub -Force | Out-Null }
            Copy-Item -Path (Join-Path $bsub '*') -Destination $dsub -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $script:YurunaStatusBackup -Recurse -Force -ErrorAction SilentlyContinue
    $script:YurunaStatusBackup = $null
}

Backup-YurunaStatus

if (Test-Path (Join-Path $YurunaDir '.git')) {
    Write-Step "Updating existing Yuruna checkout at $YurunaDir"
    & $gitExe -C $YurunaDir fetch --tags origin
    & $gitExe -C $YurunaDir checkout $YurunaBranch
    & $gitExe -C $YurunaDir pull --ff-only origin $YurunaBranch 2>&1 | ForEach-Object {
        if ($_ -match 'Already up to date|Fast-forward|Updating') { Write-Output "     $_" }
        else { Write-Warn $_ }
    }
    # $LASTEXITCODE in PowerShell propagates through native-cmd pipelines:
    # the value here is git's exit code, not ForEach-Object's.
    $pullExit = $LASTEXITCODE
    if ($pullExit -ne 0) {
        # Fast-forward not possible: uncommitted changes, divergent
        # commits, detached HEAD, or any other condition that prevents
        # git from advancing the working tree. Rather than leaving the
        # installer in a half-updated state, move the existing checkout
        # aside as a timestamped backup and re-clone fresh. The
        # test/status runtime state was already captured to TEMP by
        # Backup-YurunaStatus above, so cycle history survives this
        # path. The finally{} block surfaces $script:YurunaBackupCreated
        # in the spawned pwsh window (and admin-console fallback) so
        # the operator can salvage local edits before deleting it.
        $stamp = Get-Date -Format 'yyyy-MM-dd.HH-mm'
        $YurunaBackupDir = "$YurunaDir.backup.$stamp"
        Write-Warn "git pull --ff-only failed (exit $pullExit) -- moving the existing checkout aside and re-cloning."
        Write-Warn "  from: $YurunaDir"
        Write-Warn "  to:   $YurunaBackupDir"
        try {
            Move-Item -LiteralPath $YurunaDir -Destination $YurunaBackupDir -ErrorAction Stop
        } catch {
            Write-Die "Could not move '$YurunaDir' to '$YurunaBackupDir': $($_.Exception.Message). Close any shells / editors / Explorer windows holding the path open, then re-run this installer."
        }
        $script:YurunaBackupCreated = $YurunaBackupDir
        Write-Step "Cloning fresh Yuruna into $YurunaDir"
        & $gitExe clone --branch $YurunaBranch $YurunaRepo $YurunaDir
    }
} else {
    Write-Step "Cloning Yuruna into $YurunaDir"
    & $gitExe clone --branch $YurunaBranch $YurunaRepo $YurunaDir
}

# -- Renormalize line endings under .gitattributes -------------------------
# .gitattributes (committed at repo root) locks LF for every text type a
# Linux guest reads -- *.sh, *.yml, user-data, meta-data, etc. But adding
# .gitattributes does NOT rewrite files already in the working tree:
# without this step, a developer who originally cloned with
# core.autocrlf=true still has fetch-and-execute.sh sitting on disk as
# CRLF, the host status server serves those CRLF bytes byte-faithfully
# to the guest, and the guest's bash chokes with `$'\r': command not
# found` on line 2 of the script. We force a one-shot rebuild of the
# working tree from the index so every file picks up the eol= rules.
#
# Pin core.autocrlf=input on the LOCAL repo too, so any future file
# added without a matching .gitattributes rule still avoids CRLF on
# commit. (Local config beats global; doesn't touch the user's other
# repos.)
if (Test-Path (Join-Path $YurunaDir '.git')) {
    Write-Step 'Renormalizing repo line endings (per .gitattributes)'
    & $gitExe -C $YurunaDir config core.autocrlf input | Out-Null

    # Pull in .gitconfig.yuruna (tracked in the repo root) for
    # pull.rebase + rebase.autoStash defaults so `git pull` here rebases
    # instead of creating merge commits. include.path can hold multiple
    # values, so add idempotently rather than overwriting whatever else
    # the operator may have included.
    $existingIncludes = @(& $gitExe -C $YurunaDir config --get-all include.path 2>$null)
    if ($existingIncludes -notcontains '../.gitconfig.yuruna') {
        & $gitExe -C $YurunaDir config --local --add include.path '../.gitconfig.yuruna' | Out-Null
        Write-Step '  Enabled pull.rebase via .gitconfig.yuruna include'
    }

    # `git diff-index --quiet HEAD` exits 0 when the working tree matches
    # HEAD (clean), 1 otherwise. Suppress its output and read $LASTEXITCODE.
    & $gitExe -C $YurunaDir update-index --refresh 2>&1 | Out-Null
    & $gitExe -C $YurunaDir diff-index --quiet HEAD -- 2>&1 | Out-Null
    $repoDirty = ($LASTEXITCODE -ne 0)

    if ($repoDirty) {
        # Uncommitted local changes -- don't clobber them. Only renormalize
        # the index (stages CRLF->LF for tracked-and-modified files) and
        # tell the user how to finish the job.
        Write-Warn '  Working tree has uncommitted changes -- only renormalizing the index.'
        & $gitExe -C $YurunaDir add --renormalize . | Out-Null
        Write-Warn '  After resolving local changes, run: git checkout HEAD -- .'
    } else {
        # Clean tree -- empty the index and reset --hard to force every
        # file to be re-checked-out under the current .gitattributes.
        & $gitExe -C $YurunaDir rm -r --cached --quiet . | Out-Null
        & $gitExe -C $YurunaDir reset --hard HEAD 2>&1 | Out-Null
        Write-Step '  Working tree rebuilt under current .gitattributes (LF for *.sh, etc.)'
    }
}
Restore-YurunaStatus

# -- Seed test.config.yml from template ------------------------------------
$testDir = Join-Path $YurunaDir 'test'
$cfg     = Join-Path $testDir 'test.config.yml'
$tpl     = Join-Path $testDir 'test.config.yml.template'
if (-not (Test-Path $cfg) -and (Test-Path $tpl)) {
    Write-Step 'Creating test\test.config.yml from template (review before running tests)'
    Copy-Item $tpl $cfg
}

# -- Baseline reset: remove every `test-*` VM left over from prior cycles --
# --- See https://yuruna.link/memory#why-the-installers-baseline-reset-removes-legacy-test-vms
$removeTestVMs = Join-Path $YurunaDir 'test\Remove-TestVMFiles.ps1'
if ($script:RestartNeeded) {
    Write-Warn 'Skipping test\Remove-TestVMFiles.ps1 until after the pending Hyper-V restart.'
} elseif (Test-Path $removeTestVMs) {
    $pwshCmd3 = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe3 = if ($pwshCmd3) { $pwshCmd3.Source } else { $null }
    if (-not $pwshExe3) {
        Write-Warn 'pwsh not on PATH yet -- skipping test\Remove-TestVMFiles.ps1. Open a new terminal and run it manually.'
    } else {
        Write-Step 'Removing test-* VMs left over from previous cycles (cache VM preserved)'
        & $pwshExe3 -NoLogo -NoProfile -File $removeTestVMs
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Remove-TestVMFiles.ps1 exited $LASTEXITCODE; continuing install."
        }
    }
} else {
    Write-Warn "test\Remove-TestVMFiles.ps1 not found under $YurunaDir -- skipping test-VM cleanup."
}

# -- Host configuration (display timeout, screen lock, etc.) ---------------
# Skip this block when Hyper-V was just enabled in THIS run: the vmms
# service only exists after the pending reboot, and Set-WindowsHostConditionSet
# reacts to its absence by printing "Enable-WindowsOptionalFeature ... Then
# reboot and re-run" -- a misleading message to greet the user with two
# lines after we already said we just enabled Hyper-V. Enable-TestAutomation
# will run cleanly after the reboot, either on the next installer run or on
# first use of Invoke-TestRunner.ps1.
$setHost = Join-Path $YurunaDir 'host\windows.hyper-v\Enable-TestAutomation.ps1'
if ($script:RestartNeeded) {
    Write-Warn 'Skipping host\windows.hyper-v\Enable-TestAutomation.ps1 until after the pending Hyper-V restart.'
} elseif (Test-Path $setHost) {
    # Same PS 5.1-safe resolution pattern as $gitExe above. By this point
    # we are guaranteed to be under pwsh (the PS 7 bootstrap re-exec'd if
    # we weren't), so this will always find pwsh.exe; the fallback is
    # defensive for anyone running with -Command against the raw script.
    $pwshCmd2 = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshExe  = if ($pwshCmd2) { $pwshCmd2.Source } else { $null }
    if (-not $pwshExe) {
        Write-Warn 'pwsh not on PATH yet -- skipping host\windows.hyper-v\Enable-TestAutomation.ps1. Open a new terminal and run it manually.'
    } else {
        Write-Step 'Running host\windows.hyper-v\Enable-TestAutomation.ps1'
        & $pwshExe -NoLogo -NoProfile -File $setHost
    }
} else {
    Write-Warn "host\windows.hyper-v\Enable-TestAutomation.ps1 not found under $YurunaDir -- skipping host config."
}

# -- Done -------------------------------------------------------------------
$script:InstallSucceeded = $true

} catch {
    # Any terminating error from the main install body lands here. Keep the
    # exception around so the finally block can decide what to print; do NOT
    # rethrow, or the process would die before the finally-block pause runs.
    $script:InstallError = $_
} finally {
    Write-Output ''
    Write-Output '================================================================'
    if ($script:InstallSucceeded) {
        Write-Output '   INSTALL RESULT: SUCCESS'
    } else {
        Write-Output '   INSTALL RESULT: FAILED'
    }
    Write-Output '================================================================'
    Write-Output ''

    if (-not $script:InstallSucceeded) {
        # ---- Failure path ----------------------------------------------
        if ($script:InstallError) {
            Write-Warning ("Installer error: " + $script:InstallError.Exception.Message)
            if ($script:InstallError.InvocationInfo -and $script:InstallError.InvocationInfo.PositionMessage) {
                Write-Warning $script:InstallError.InvocationInfo.PositionMessage
            }
        }
        Write-Output ''
        Write-Output 'The installer did not complete. Review the messages above,'
        Write-Output 'address the problem, and re-run this script. Re-running is'
        Write-Output 'safe -- completed steps are skipped.'
        if ($script:YurunaBackupCreated) {
            Write-Output ''
            Write-Output '================================================================'
            Write-Output 'NOTE: a backup of your previous Yuruna checkout was created'
            Write-Output "  earlier in this run because 'git pull --ff-only' could"
            Write-Output '  not advance the local repo. The backup is on disk even'
            Write-Output '  though a later install step failed.'
            Write-Output ''
            Write-Output ("  Backup location: " + $script:YurunaBackupCreated)
            Write-Output ''
            Write-Output 'Review the backup for any local edits you want to preserve.'
            Write-Output 'When you no longer need it, delete it manually:'
            Write-Output ("  Remove-Item -Recurse -Force '" + $script:YurunaBackupCreated + "'")
            Write-Output '================================================================'
        }
        # No `exit 1` here -- that would terminate the hosting PowerShell
        # process, closing the user's own window when they invoked this
        # script directly (e.g. `.\install\windows.hyper-v.ps1`). The
        # if/elseif/else already skips the other branches, so falling
        # through leaves the finally block cleanly and returns the user
        # to their shell prompt.
    }
    elseif ($script:RestartNeeded) {
        # ---- Reboot-blocked path ---------------------------------------
        # Don't automate Hyper-V Manager (vmms isn't running yet), don't
        # open a notepad for test.config.yml (the user cannot run tests
        # before the reboot anyway), don't spawn a fresh pwsh window
        # (same reason). Keep guidance to the single thing that matters:
        # reboot, then re-run.
        Write-Warning 'RESTART REQUIRED'
        Write-Warning '  Hyper-V needs a Windows restart to finish activation.'
        Write-Warning '  (Either it was just enabled in this run, or a previous'
        Write-Warning '   run enabled it and the reboot is still pending.)'
        Write-Warning '  After the reboot, re-run this installer -- it will finish'
        Write-Warning '  the host configuration step, open Hyper-V Manager and'
        Write-Warning '  notepad for test.config.yml if needed, and drop you at'
        Write-Warning '  a pwsh prompt in the test directory.'
        if ($script:YurunaBackupCreated) {
            Write-Warning ''
            Write-Warning '================================================================'
            Write-Warning 'NOTE: a backup of your previous Yuruna checkout was created'
            Write-Warning "  earlier in this run because 'git pull --ff-only' could"
            Write-Warning '  not advance the local repo.'
            Write-Warning ''
            Write-Warning ("  Backup location: " + $script:YurunaBackupCreated)
            Write-Warning ''
            Write-Warning 'Review the backup for any local edits you want to preserve.'
            Write-Warning 'When you no longer need it, delete it manually:'
            Write-Warning ("  Remove-Item -Recurse -Force '" + $script:YurunaBackupCreated + "'")
            Write-Warning '================================================================'
        }
    }
    else {
        # ---- Full success path -- automate the handoff ----------------
        # The admin console this script is running in was spawned by the
        # self-elevation block via Start-Process -Verb RunAs and closes
        # the moment we return. Anything we Write-Output AFTER that exit
        # is unreadable -- which is why the previous revision's NEXT
        # STEPS block vanished before the user could read it. So:
        # all NEXT STEPS guidance lives INSIDE the spawned pwsh window's
        # welcome banner. This window can close right after the spawn;
        # nothing critical is lost.

        Write-Step 'Finishing up -- opening handoff windows'

        # 1. Hyper-V Manager. First-run dialog registration still has to
        #    happen interactively (per-user MMC snap-in setup), so we
        #    launch the console and let the user dismiss it.
        $hypervOpened = $false
        try {
            Write-Step '  launching Hyper-V Manager (virtmgmt.msc)'
            Start-Process -FilePath 'virtmgmt.msc' | Out-Null
            $hypervOpened = $true
        } catch {
            Write-Warn ('  could not launch virtmgmt.msc: ' + $_.Exception.Message)
        }

        # 2. test.config.yml review. The earlier seed step copied the
        #    template over if the file was absent, but the user still
        #    has to fill in environment-specific values. Only open
        #    notepad when the file is still byte-identical to the
        #    template -- if they already customized it, leave it alone
        #    so we do not nag on every re-run.
        $notepadOpened = $false
        $testDirFinal = Join-Path $YurunaDir 'test'
        $cfgFinal     = Join-Path $testDirFinal 'test.config.yml'
        $tplFinal     = Join-Path $testDirFinal 'test.config.yml.template'
        if ((Test-Path -LiteralPath $cfgFinal) -and (Test-Path -LiteralPath $tplFinal)) {
            $cfgHash = (Get-FileHash -LiteralPath $cfgFinal -Algorithm SHA256).Hash
            $tplHash = (Get-FileHash -LiteralPath $tplFinal -Algorithm SHA256).Hash
            if ($cfgHash -eq $tplHash) {
                Write-Step '  test.config.yml is unchanged from the template -- opening notepad for review'
                try {
                    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $cfgFinal + '"') | Out-Null
                    $notepadOpened = $true
                } catch {
                    Write-Warn ('  could not launch notepad: ' + $_.Exception.Message)
                }
            } else {
                Write-Step '  test.config.yml already customized -- leaving as-is'
            }
        }

        # 3. Build the welcome banner for the spawned pwsh window. All
        #    NEXT STEPS guidance goes HERE, not in the admin console,
        #    because the admin console closes right after we spawn.
        #    Build the banner as a list of Write-Host statements, one
        #    per line, each using single-quoted strings to avoid any
        #    $-expansion surprises inside the spawned shell.
        $testDirForScript = $testDirFinal -replace "'", "''"
        $lines = New-Object System.Collections.Generic.List[string]
        $null = $lines.Add("Set-Location -LiteralPath '$testDirForScript'")
        $null = $lines.Add("Write-Host ''")
        $null = $lines.Add("Write-Host '================================================================' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '  Yuruna installer finished -- continue working here.' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '================================================================' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host ''")
        $null = $lines.Add("Write-Host 'NEXT STEPS:' -ForegroundColor Cyan")
        if ($hypervOpened) {
            $null = $lines.Add("Write-Host '  * Hyper-V Manager is open -- dismiss the first-run dialog,' -ForegroundColor Cyan")
            $null = $lines.Add("Write-Host '    then close that window.' -ForegroundColor Cyan")
        }
        if ($notepadOpened) {
            $null = $lines.Add("Write-Host '  * notepad is open on test.config.yml -- edit values for' -ForegroundColor Cyan")
            $null = $lines.Add("Write-Host '    your environment, then save and close notepad.' -ForegroundColor Cyan")
        }
        $null = $lines.Add("Write-Host '  * Run the test harness from THIS window:' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '      pwsh .\Invoke-TestRunner.ps1' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host ''")
        if ($script:YurunaBackupCreated) {
            # Loud notice so the operator can salvage local edits before
            # deleting the backup. Double-up apostrophes for the embedded
            # path so it survives a single-quoted Write-Host literal.
            $backupForScript = $script:YurunaBackupCreated -replace "'", "''"
            $null = $lines.Add("Write-Host '============================================================' -ForegroundColor Yellow")
            $null = $lines.Add("Write-Host 'IMPORTANT: a backup of your previous Yuruna checkout was created' -ForegroundColor Yellow")
            $null = $lines.Add('Write-Host "  because ''git pull --ff-only'' could not advance the local repo." -ForegroundColor Yellow')
            $null = $lines.Add("Write-Host ''")
            $null = $lines.Add("Write-Host '  Backup location: $backupForScript' -ForegroundColor Yellow")
            $null = $lines.Add("Write-Host ''")
            $null = $lines.Add("Write-Host 'Review the backup for any local edits you want to preserve.' -ForegroundColor Yellow")
            $null = $lines.Add("Write-Host 'When you no longer need it, delete it manually:' -ForegroundColor Yellow")
            $null = $lines.Add("Write-Host '  Remove-Item -Recurse -Force ''$backupForScript''' -ForegroundColor Yellow")
            $null = $lines.Add("Write-Host '============================================================' -ForegroundColor Yellow")
            $null = $lines.Add("Write-Host ''")
        }
        $null = $lines.Add("Write-Host 'Re-running the installer is safe; it upgrades winget packages' -ForegroundColor DarkGray")
        $null = $lines.Add("Write-Host 'and fast-forwards the Yuruna checkout.' -ForegroundColor DarkGray")
        $null = $lines.Add("Write-Host ''")
        $welcomeScript = $lines -join "`r`n"

        # -EncodedCommand sidesteps every shell-quoting pitfall for the
        # spawned process -- pwsh.exe expects the base64 payload as
        # UTF-16LE (Unicode) bytes.
        $encoded = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes($welcomeScript))

        $shellOpened = $false
        $pwshCmd3 = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($pwshCmd3) {
            Write-Step ('  opening a new pwsh window at ' + $testDirFinal)
            try {
                Start-Process -FilePath $pwshCmd3.Source -ArgumentList @(
                    '-NoExit','-NoLogo','-EncodedCommand', $encoded
                ) | Out-Null
                $shellOpened = $true
            } catch {
                Write-Warn ('  could not open a new pwsh window: ' + $_.Exception.Message)
            }
        } else {
            Write-Warn '  pwsh not on PATH -- could not open a new shell.'
        }

        if (-not $shellOpened) {
            # Rare: the handoff pwsh window didn't open, so the NEXT
            # STEPS banner that lives inside it never ran. Print the
            # same guidance here in the admin console and hold the
            # window open long enough to read it -- timed auto-close
            # (no Read-Host, so an accidental Enter cannot end things).
            Write-Output ''
            Write-Output '================================================================'
            Write-Output '   HANDOFF WINDOW DID NOT OPEN -- DO THIS MANUALLY:'
            Write-Output '================================================================'
            if ($hypervOpened) {
                Write-Output '   * Hyper-V Manager is open -- dismiss the first-run dialog,'
                Write-Output '     then close that window.'
            }
            if ($notepadOpened) {
                Write-Output '   * notepad is open on test.config.yml -- edit values for'
                Write-Output '     your environment, then save and close notepad.'
            }
            Write-Output '   * Open a new pwsh window, then run:'
            Write-Output ("       cd `"$testDirFinal`"")
            Write-Output  '       pwsh .\Invoke-TestRunner.ps1'
            Write-Output '================================================================'
            if ($script:YurunaBackupCreated) {
                Write-Output ''
                Write-Output '================================================================'
                Write-Output 'IMPORTANT: a backup of your previous Yuruna checkout was created'
                Write-Output "  because 'git pull --ff-only' could not advance the local repo."
                Write-Output ''
                Write-Output ("  Backup location: " + $script:YurunaBackupCreated)
                Write-Output ''
                Write-Output 'Review the backup for any local edits you want to preserve.'
                Write-Output 'When you no longer need it, delete it manually:'
                Write-Output ("  Remove-Item -Recurse -Force '" + $script:YurunaBackupCreated + "'")
                Write-Output '================================================================'
            }
            Write-Output ''
            Write-Output 'This window will close automatically in 60 seconds.'
            Start-Sleep -Seconds 60
        }
    }
}
