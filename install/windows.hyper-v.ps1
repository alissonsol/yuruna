<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42c2a1aa-2e97-414a-9393-0d097d2e2a2c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Yuruna Windows + Hyper-V bootstrap installer.
.DESCRIPTION
    See https://yuruna.link/install/explained for the operator-facing
    rationale. This file MUST stay 7-bit ASCII, no BOM -- PowerShell
    5.1's `irm | iex` parses byte-for-byte and any non-ASCII char or
    UTF-8 BOM aborts at line 1 before the param block is reached.
    See repo memory feedback_bootstrap_installer_no_bom.md for the
    trap class.
#>

[CmdletBinding()]
param(
    [string]$YurunaDir    = (Join-Path $HOME 'git\yuruna'),
    [string]$YurunaRepo   = 'https://github.com/alissonsol/yuruna.git',
    [string]$YurunaBranch = 'main',
    # Freeze the checkout at the current release instead of tracking 'main':
    # after cloning, the repo's own VERSION file is read and that release tag is
    # checked out as a detached HEAD, so the per-cycle `git pull` is a no-op and
    # the host never auto-updates. An explicit -YurunaBranch wins over this.
    [switch]$PinVersion,
    [switch]$SkipPreflight,
    # On-disk transcript for this run. Generated once at first launch and
    # forwarded verbatim through every relaunch so all stages append to one
    # file. Operators do not normally pass this.
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
# This installer drives native tools (winget, git, dism) that signal status via
# their EXIT CODE, not exceptions, and several are EXPECTED to exit non-zero
# (`git diff-index --quiet` on a dirty tree, `winget upgrade` on an already-
# current package). Every call that matters checks $LASTEXITCODE explicitly.
# On PowerShell 7.4+ $PSNativeCommandUseErrorActionPreference can be $true, which
# turns ANY non-zero native exit into a terminating error under EAP=Stop and
# would abort the install on those benign cases. Pin it off so behaviour does
# not depend on the host's PowerShell default. (Harmless no-op on PS 5.1.)
$PSNativeCommandUseErrorActionPreference = $false

$script:YurunaRepoPublic  = 'https://github.com/alissonsol/yuruna.git'
$script:YurunaRepoPrivate = 'https://github.com/alissonsol/yurunadev.git'

# Did the operator pin a ref explicitly? The development repo (yurunadev) is
# only tagged at the weekly release, so its pinned-CalVer default would never
# resolve mid-week; when targeting it we fall back to latest 'main' unless the
# operator asked for a specific ref.
$script:YurunaBranchExplicit = $PSBoundParameters.ContainsKey('YurunaBranch')

function Write-Step { param([string]$m) Write-Output "==> $m" }
function Write-Warn { param([string]$m) Write-Warning $m }
function Write-Die  { param([string]$m) Write-Error $m }

# --- REGION: Install log
# The elevated relaunch runs in a SEPARATE console window that vanishes the
# instant the script ends or dies, so a mid-install failure there leaves
# nothing on screen to read. Transcript every elevated stage to a file under a
# standard, discoverable location (%ProgramData%\Yuruna\logs, falling back to
# %TEMP%) so the failure can be inspected after the window is gone. The path is
# generated ONCE and forwarded through every relaunch via -LogPath, so the line
# printed before the UAC relaunch names the exact file the elevated window
# writes, and every stage appends to that one file.
$script:InstallLogActive = $false

function Resolve-InstallLogPath {
    [OutputType([string])]
    param([string]$Provided)
    if ($Provided) { return $Provided }
    $baseDir = $null
    foreach ($candidate in @((Join-Path $env:ProgramData 'Yuruna\logs'),
                             (Join-Path $env:TEMP 'yuruna-install-logs'))) {
        if (-not $candidate) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidate)) {
                New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
            }
            $baseDir = $candidate
            break
        } catch { continue }
    }
    if (-not $baseDir) { $baseDir = $env:TEMP }
    return (Join-Path $baseDir ('windows.hyper-v.install.{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Start-InstallLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort transcript toggle; -WhatIf is meaningless and the install must proceed even if logging fails.')]
    param([string]$Path)
    if (-not $Path -or $script:InstallLogActive) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    try {
        Start-Transcript -Path $Path -Append -ErrorAction Stop | Out-Null
        $script:InstallLogActive = $true
    } catch {
        Write-Warning "Could not start install transcript at ${Path}: $($_.Exception.Message)"
    }
}

function Stop-InstallLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort transcript toggle; -WhatIf is meaningless.')]
    param()
    if (-not $script:InstallLogActive) { return }
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
    $script:InstallLogActive = $false
}

$LogPath = Resolve-InstallLogPath -Provided $LogPath

# --- REGION: Preflight: Windows only
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Write-Die 'This installer only supports Windows.'
}

# --- REGION: Preflight: Hyper-V-capable Windows edition (HARD requirement)
# Distinct from the "tested baseline" warnings below. Those (low RAM, fewer
# cores, an untested-but-Hyper-V-capable Windows version) are soft, and the
# operator may continue past them. A Windows Home / S mode edition is not
# negotiable: it ships no Hyper-V platform at all, so every VM the test harness
# needs is impossible and there is nothing the elevated stage can enable to
# change that. Catch it HERE -- before the UAC elevation and the winget
# installs -- and abort naming the real cause, rather than running on to a
# misleading "INSTALL RESULT: SUCCESS" whose only hint is a buried "feature not
# available on this SKU" warning emitted mid-run.
function Assert-HyperVCapableEdition {
    $os = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    } catch {
        # Can't read the edition here -- defer to the elevated DISM feature
        # probe (the authority) rather than risk a false abort on a capable box.
        Write-Verbose "Win32_OperatingSystem query failed: $($_.Exception.Message); deferring the Hyper-V edition gate to the elevated DISM probe."
        return
    }
    if (-not $os) { return }
    $caption = [string]$os.Caption
    # Consumer SKUs with no Hyper-V platform: Core/Home family = 98-101,
    # Cloud / "S mode" = 178-179. Match by SKU number (language-independent),
    # with the caption "Home" as a readable secondary signal.
    $incapableSkus = 98, 99, 100, 101, 178, 179
    if (($os.OperatingSystemSKU -notin $incapableSkus) -and ($caption -notmatch '\bHome\b')) {
        return
    }
    Write-Die @"
This Windows edition cannot run Hyper-V, which the Yuruna test harness requires.

  Detected edition: $caption

Hyper-V is available only on Windows 11/10 Pro, Enterprise, or Education, or on
Windows Server. Windows Home and S mode editions do not include the Hyper-V
platform, so there is nothing this installer can enable to make it work.

To run Yuruna on this machine, upgrade it to a Hyper-V-capable edition (for
example Windows 11 Pro) or use a different host. Aborting now, before any
packages are installed or the Hyper-V feature is touched.
"@
}

# --- REGION: Preflight: system requirements
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
    if ($os) { $memGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0) }
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
    Assert-HyperVCapableEdition
    Test-SystemRequirement
}

# --- REGION: Preflight: display scaling
# --- REGION: https://yuruna.link/install/explained#display-scaling-check
function Test-DisplayScaling {
    $asSignedDword = {
        param($raw)
        if ($null -eq $raw) { return 0 }
        $u = [uint32]$raw
        if ($u -gt [int32]::MaxValue) { return [int32]($u - 0x100000000) } else { return [int32]$u }
    }

    $issues = New-Object System.Collections.Generic.List[string]

    $perMonRoot = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
    if (Test-Path -LiteralPath $perMonRoot) {
        $monKeys = Get-ChildItem -LiteralPath $perMonRoot -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSIsContainer }
        foreach ($mon in $monKeys) {
            $props = Get-ItemProperty -LiteralPath $mon.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            if (-not ($props.PSObject.Properties.Name -contains 'DpiValue')) { continue }
            $current     = & $asSignedDword $props.DpiValue
            $recommended = if ($props.PSObject.Properties.Name -contains 'RecommendedDpiValue') {
                               & $asSignedDword $props.RecommendedDpiValue
                           } else { 0 }
            $target = -$recommended
            if ($current -ne $target) {
                $offsetSteps = $current - $target
                $percent = 100 + ($offsetSteps * 25)
                $null = $issues.Add("Monitor $($mon.PSChildName): $percent% display scale (DpiValue=$current, recommended offset=$recommended)")
            }
        }
    }

    $dp = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
    $logPixels = if ($dp -and ($dp.PSObject.Properties.Name -contains 'LogPixels')) {
                     & $asSignedDword $dp.LogPixels
                 } else { 96 }
    if ($logPixels -ne 96) {
        $percent = [math]::Round(($logPixels / 96.0) * 100)
        $null = $issues.Add("System DPI (LogPixels): $logPixels ($percent%)")
    }

    $ap = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Accessibility' -ErrorAction SilentlyContinue
    $tsf = if ($ap -and ($ap.PSObject.Properties.Name -contains 'TextScaleFactor')) {
               [int]$ap.TextScaleFactor
           } else { 100 }
    if ($tsf -ne 100) {
        $null = $issues.Add("Accessibility TextScaleFactor: $tsf% (Settings > Accessibility > Text size)")
    }

    if ($issues.Count -eq 0) {
        Write-Step 'Display scaling: all sources at 100% (good for OCR).'
        return
    }

    Write-Warning ''
    Write-Warning '============================================================'
    Write-Warning '  Display / text scaling is not 100%:'
    foreach ($i in $issues) { Write-Warning "    - $i" }
    Write-Warning ''
    Write-Warning '  Yuruna OCR (Tesseract on VM screenshots) degrades when host'
    Write-Warning '  DPI is above 100%. The install will proceed; AFTER install,'
    Write-Warning '  run Enable-TestAutomation.ps1 to reset display scale to 100%'
    Write-Warning '  (then sign out / back in for it to take effect):'
    Write-Warning "    pwsh `"$YurunaDir\host\windows.hyper-v\Enable-TestAutomation.ps1`""
    Write-Warning '============================================================'
    Write-Warning ''
}

if (-not $SkipPreflight) {
    Test-DisplayScaling
}

# --- REGION: Single-fetch materialization (irm|iex path)
# Under `irm | iex` there is no $PSCommandPath, so the elevation and PS7
# relaunches below would each RE-FETCH the installer from the moving ref --
# extra unverified swings, two of them in the elevated context. Instead fetch
# the source ONCE here to a BOM-less temp file and relaunch via -File, so
# every child runs from that one file with a real
# $PSCommandPath and never re-fetches. Byte-true IRM-to-temp (not
# ScriptBlock.ToString(), whose PS5.1 round-trip fidelity is unverified), so
# the materialized bytes match the canonical installer.
#
# Sweep stale materialization temps left by a crashed prior run (>1h old; the
# age guard never touches a concurrent run's fresh temp).
Get-ChildItem -LiteralPath $env:TEMP -Filter 'yuruna-windows-hyper-v-*.ps1' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

if (-not $PSCommandPath) {
    $installerUrl = 'https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1'
    $matTmp = Join-Path $env:TEMP ('yuruna-windows-hyper-v-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Write-Step 'Materializing installer to a temp file (single fetch; relaunches use -File)'
    $src = Invoke-RestMethod $installerUrl
    # BOM-less UTF-8: Set-Content -Encoding UTF8 emits a BOM on PS5.1 that breaks
    # the relaunched -File at the param block (feedback_bootstrap_installer_no_bom).
    [System.IO.File]::WriteAllText($matTmp, $src, (New-Object System.Text.UTF8Encoding $false))
    $currentShellExe = $null
    try { $currentShellExe = (Get-Process -Id $PID).Path } catch { $currentShellExe = $null }
    if (-not $currentShellExe) { $currentShellExe = 'powershell.exe' }
    # Preflight already ran in this iex process, so the -File child skips it.
    $matArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$matTmp`"", '-SkipPreflight')
    if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $matArgs += @('-YurunaDir',    "`"$YurunaDir`"") }
    if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $matArgs += @('-YurunaRepo',   "`"$YurunaRepo`"") }
    if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $matArgs += @('-YurunaBranch', "`"$YurunaBranch`"") }
    if ($PinVersion) { $matArgs += '-PinVersion' }
    $matArgs += @('-LogPath', "`"$LogPath`"")   # forward the one log file to every stage
    & $currentShellExe $matArgs
    # Propagate the -File child's exit code so a wrapping script / CI sees the
    # install's real result; a bare `return` here otherwise always exits 0.
    # Kept 5.1-safe (no `??`): this gate runs in the original irm|iex shell,
    # which may be Windows PowerShell 5.1.
    $childExit = $LASTEXITCODE
    if ($null -eq $childExit) { $childExit = 0 }
    exit $childExit
}

# --- REGION: Elevation announcement + self-relaunch
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

@'

  +---------------------------------------------------------------+
  |  This installer needs Administrator privileges for:           |
  |    * winget package installs (PowerShell 7, Git, ADK, ...)    |
  |    * enabling the Hyper-V Windows Feature (via DISM.exe)      |
  |  All of the above are run automatically -- you do NOT need    |
  |  to type any command yourself. You will see ONE UAC prompt    |
  |  if the script was not already launched from an elevated      |
  |  shell.                                                       |
  +---------------------------------------------------------------+

'@ | Write-Output

if (-not $isAdmin) {
    Write-Step 'Relaunching elevated (UAC prompt)'
    $currentShellExe = $null
    try { $currentShellExe = (Get-Process -Id $PID).Path } catch { $currentShellExe = $null }
    if (-not $currentShellExe) { $currentShellExe = 'powershell.exe' }
    # $PSCommandPath is always set here (the materialization gate above relaunches
    # the irm|iex case via -File), so the elevated child runs from a file and
    # never re-fetches in the elevated context.
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"", '-SkipPreflight')
    if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
    if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
    if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
    if ($PinVersion) { $argList += '-PinVersion' }
    $argList += @('-LogPath', "`"$LogPath`"")
    # The elevated window closes the moment it finishes or fails, so name the
    # log file here -- in THIS window, which stays open -- before launching it.
    Write-Step ''
    Write-Step 'The elevated window will write a full install log to:'
    Write-Step "    $LogPath"
    Write-Step 'If that window closes before finishing, open that file to see where it stopped.'
    Write-Step ''
    Start-Process -FilePath $currentShellExe -Verb RunAs -ArgumentList $argList
    return
}

# Elevated from here on. Begin the on-disk transcript so a failure in this
# window (which closes on exit) is recoverable afterwards, and echo the path.
Start-InstallLog -Path $LogPath
if ($script:InstallLogActive) {
    Write-Step "Logging this elevated session to: $LogPath"
} else {
    Write-Warn "Proceeding WITHOUT an install transcript (could not open $LogPath)."
}

Write-Step "Yuruna Windows installer starting"
Write-Step "  repo   : $YurunaRepo ($YurunaBranch)"
Write-Step "  target : $YurunaDir"
Write-Step "  shell  : $((Get-Process -Id $PID).ProcessName) (PowerShell $($PSVersionTable.PSVersion))"

# --- REGION: PowerShell 7 bootstrap (PS 5.1 -> PS 7)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Step 'Bootstrapping PowerShell 7 (Windows PowerShell 5.x detected)'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Die @'
winget is not available on this system. Install "App Installer" from the
Microsoft Store (or update Windows) and re-run this script.
'@
    }
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
        # Safe to UPGRADE here: this stage runs under Windows PowerShell
        # (powershell.exe), a different binary from the pwsh.exe being
        # replaced, so the upgrade can't terminate the running process. (The
        # main package loop below runs UNDER pwsh and must NOT upgrade it --
        # see the Microsoft.PowerShell self-upgrade guard there.) Best-effort:
        # winget upgrade exits non-zero when nothing is outdated, which is not
        # a failure, so don't gate on $LASTEXITCODE.
        Write-Step '  PowerShell 7 already installed -- upgrading if outdated'
        winget upgrade --id 'Microsoft.PowerShell' --exact --silent --source winget `
            --accept-package-agreements --accept-source-agreements `
            --disable-interactivity 2>&1 |
            Where-Object { $_ -notmatch 'No applicable upgrade|No installed package' } |
            ForEach-Object { Write-Output "     $_" }
    }
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
    # $PSCommandPath is always set here (materialization gate above) -- relaunch
    # from the file under pwsh, never re-fetch.
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"", '-SkipPreflight')
    if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
    if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
    if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
    if ($PinVersion) { $argList += '-PinVersion' }
    $argList += @('-LogPath', "`"$LogPath`"")
    # Hand the transcript off to the PS7 child (it re-opens the same file with
    # -Append); release our handle first so its Start-Transcript does not
    # collide on the open file.
    Stop-InstallLog
    & $pwshCmd.Source $argList
    return
}

# --- REGION: Status-port lookup (lightweight YAML scan)
# Read statusService.port from test.config.yml WITHOUT powershell-yaml: the
# module may not be installed yet at this point in the bootstrap. Returns 0
# when the file/key is absent so the caller falls back to the 8080 default.
function Get-StatusServicePort {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    try {
        $lines = Get-Content -LiteralPath $ConfigPath -ErrorAction Stop
    } catch {
        Write-Verbose "Could not read $ConfigPath for status port: $($_.Exception.Message)"
        return 0
    }
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^statusService:\s*$') { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -match '^\S') { break }                 # next top-level key ends the block
            if ($line -match '^\s+port:\s*(\d+)') { return [int]$Matches[1] }
        }
    }
    return 0
}

# --- REGION: https://yuruna.link/install/explained#stop-running-yuruna-processes-before-updating
# taskkill /T /F is deliberate: a soft Ctrl+C only requests "exit after the
# current cycle", which can pin the checkout for a full VM cycle. VMs untouched.
function Stop-YurunaProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$YurunaDir)

    $candidatePids = New-Object System.Collections.Generic.List[int]

    # (1) PID files under the runtime dir (env override wins, else the
    #     <testRoot>/status/runtime default the runner uses).
    $runtimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR }
                  elseif ($YurunaDir) { Join-Path $YurunaDir 'test\status\runtime' }
                  else { $null }
    if ($runtimeDir -and (Test-Path -LiteralPath $runtimeDir)) {
        foreach ($pidName in 'runner.pid','inner.pid','server.pid') {
            $pidFile = Join-Path $runtimeDir $pidName
            if (-not (Test-Path -LiteralPath $pidFile)) { continue }
            try {
                $raw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop).Trim()
                $n = 0
                if ([int]::TryParse($raw, [ref]$n)) { $candidatePids.Add($n) }
            } catch { Write-Verbose "Could not read ${pidFile}: $($_.Exception.Message)" }
        }
    }

    # (2) Command-line pattern match.
    $patterns = @('Invoke-TestRunner.ps1','Invoke-TestInnerRunner.ps1','Test-Sequence.ps1','Start-StatusService.ps1','.status-service.ps1')
    foreach ($pat in $patterns) {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$pat*" }
        foreach ($p in $procs) { $candidatePids.Add([int]$p.ProcessId) }
    }

    # (3) Status-port listener(s): the configured port plus the 8080 default.
    $ports = New-Object System.Collections.Generic.List[int]
    $ports.Add(8080)
    if ($YurunaDir) {
        $cfg = Join-Path $YurunaDir 'test\test.config.yml'
        if (Test-Path -LiteralPath $cfg) {
            $configuredPort = Get-StatusServicePort -ConfigPath $cfg
            if ($configuredPort -gt 0) { $ports.Add($configuredPort) }
        }
    }
    foreach ($port in ($ports | Select-Object -Unique)) {
        try {
            $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            foreach ($c in $conns) { if ($c.OwningProcess) { $candidatePids.Add([int]$c.OwningProcess) } }
        } catch { Write-Verbose "port $port check skipped: $($_.Exception.Message)" }
    }

    # Never target our own process; dedupe so a service found via two channels
    # is killed once.
    $targetPids = @($candidatePids | Where-Object { $_ -gt 0 -and $_ -ne $PID } | Select-Object -Unique)
    if ($targetPids.Count -eq 0) {
        Write-Step '  no running Yuruna runner / status server found'
        return
    }

    foreach ($targetPid in $targetPids) {
        $proc  = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }   # already gone (e.g. killed as a child of an earlier target's tree)
        # Identity-validate: only stop actual PowerShell processes (the runner /
        # inner / status server are all pwsh). A PID read from a stale PID file
        # may have been recycled by the OS to an unrelated process -- never
        # taskkill /T /F an innocent recycled PID's whole tree.
        if ($proc.ProcessName -notmatch '^(pwsh|powershell)$') {
            Write-Verbose "  skipping pid $targetPid ($($proc.ProcessName)) -- not a PowerShell process (stale/recycled PID file?)"
            continue
        }
        $label = "$($proc.ProcessName) (pid $targetPid)"
        if (-not $PSCmdlet.ShouldProcess($label, 'Force-stop Yuruna service and its child processes')) { continue }
        Write-Step "  stopping $label and its child processes"
        # taskkill /T /F hard-terminates the whole tree. Guard the native call:
        # taskkill exits 128 when the PID is already gone (it may have died as a
        # child of an earlier target's /T tree), and under this script's
        # $ErrorActionPreference='Stop' + $PSNativeCommandUseErrorActionPreference
        # (default $true on PS 7.4+) a non-zero native exit throws -- which would
        # abort the whole install. Swallow it and fall back to Stop-Process.
        try {
            & taskkill.exe /PID $targetPid /T /F *>$null
        } catch {
            Write-Verbose "taskkill /PID $targetPid failed ($($_.Exception.Message)); falling back to Stop-Process."
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
        }
    }

    # Wait for every target to actually exit before returning -- the caller
    # renames the checkout aside next (Assert-YurunaCheckoutMovable + the
    # update/re-clone), which fails while any of these still holds a handle
    # inside the tree.
    $deadline = (Get-Date).AddSeconds(20)
    $alive = @()
    do {
        $alive = @($targetPids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if ($alive.Count -gt 0) {
        Write-Warn "  PID(s) $($alive -join ', ') did not exit within 20s and may still hold the checkout; re-run the installer if the update step reports the checkout is in use."
    }
}

# --- REGION: Preflight: the checkout is not held open
# The update path (below) may have to move the existing checkout aside to
# re-clone, and Move-Item of a directory is a rename that fails when the
# folder is held open -- most often a shell sitting inside it (its current
# location pins the tree), or an editor / Explorer window with it open. That
# failure is otherwise only reached AFTER the winget installs, the Hyper-V
# enable, and the test/status backup, so the operator waits minutes for a
# surprising "item is in use" abort. Probe it up front with the SAME operation
# the fallback uses -- a sibling rename -- after first dropping our own lock by
# stepping out of the tree. A pass renames straight back (no disruption); a
# failure moves nothing and is the early, actionable abort.
function Assert-YurunaCheckoutMovable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)
    # A first-time clone creates the dir, so there is nothing to move.
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return }

    $full  = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\')
    $probe = "$full.locktest"

    # Drop a self-inflicted lock: a working directory inside the tree pins it,
    # failing both the probe and the later move-aside. Step out to the parent.
    $cwd = [System.IO.Path]::GetFullPath((Get-Location).ProviderPath).TrimEnd('\')
    if ($cwd -eq $full -or $cwd.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Location -LiteralPath (Split-Path -Parent $full)
        Write-Warn "Stepped out of '$Dir' -- the installer was launched from inside the checkout, which would block updating it."
    }

    # Recover from a probe a prior run left half-applied (renamed away, never
    # renamed back), then refuse to clobber any unexpected leftover.
    if ((Test-Path -LiteralPath $probe) -and -not (Test-Path -LiteralPath $full)) {
        Move-Item -LiteralPath $probe -Destination $full -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $probe) {
        Write-Die "A previous lock-probe left '$probe' behind. Inspect it, then remove it or rename it back to '$Dir' before re-running."
    }

    try {
        Move-Item -LiteralPath $full -Destination $probe -ErrorAction Stop
    } catch {
        Write-Die "The Yuruna checkout '$Dir' is in use and cannot be updated: $($_.Exception.Message). Close any shell sitting inside it (cd elsewhere), and any editor (VS Code) or Explorer window holding it open, then re-run. (Checked up front so the package installs and Hyper-V setup are not run first.)"
    }
    try {
        Move-Item -LiteralPath $probe -Destination $full -ErrorAction Stop
    } catch {
        Write-Die "Verified '$Dir' is movable but could not restore it from the probe name '$probe': $($_.Exception.Message). Rename '$probe' back to '$Dir' manually, then re-run."
    }
}

# --- REGION: yuruna-caching-proxy detection
function Test-CachingProxyRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy')
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return $false }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    return ($vm -and $vm.State -eq 'Running')
}

$script:InstallSucceeded    = $false
$script:InstallError        = $null
$script:YurunaBackupCreated = $null
try {

if (Test-CachingProxyRunning) {
    Write-Step 'yuruna-caching-proxy VM is running -- preserving cached content (no Stop-VM / Remove-VM in this installer)'
}

Write-Step 'Stopping anything that would block a repo update (runner + status server; VMs preserved)'
Stop-YurunaProcess -YurunaDir $YurunaDir

Write-Step 'Checking the Yuruna checkout is not locked by a shell / editor / Explorer'
Assert-YurunaCheckoutMovable -Dir $YurunaDir

# --- REGION: winget availability
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

# --- REGION: Install platform packages
Write-Step 'Installing / upgrading required packages via winget'
# PowerShell 7 itself: do NOT `winget upgrade` the interpreter we are running
# under. winget's MSI uses the Restart Manager to close every process holding
# pwsh's files open -- including THIS one -- which terminates the installer
# mid-step (the runspace dies with "The pipeline has been stopped"). PS7 is
# installed-if-missing and upgraded-if-present in the bootstrap stage above,
# which runs under Windows PowerShell and is therefore safe to replace pwsh
# from. An in-place upgrade of the live pwsh has to come from another process.
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Step "  PowerShell 7 is the running interpreter ($($PSVersionTable.PSVersion)) -- skipping its winget upgrade (would terminate this installer). Update it later from Windows PowerShell or a separate window: winget upgrade --id Microsoft.PowerShell"
} else {
    Install-WingetPackage -Id 'Microsoft.PowerShell'          -FriendlyName 'PowerShell 7'
}
Install-WingetPackage -Id 'Git.Git'                           -FriendlyName 'Git (brings openssl.exe used by Ubuntu guest New-VM.ps1 password hashing)'
Install-WingetPackage -Id 'Microsoft.WindowsADK'              -FriendlyName 'Windows ADK (Deployment Tools / oscdimg)'
Install-WingetPackage -Id 'SoftwareFreedomConservancy.QEMU'   -FriendlyName 'QEMU tools (qemu-img for guest.caching-proxy/Get-Image.ps1)'
Install-WingetPackage -Id 'UB-Mannheim.TesseractOCR'          -FriendlyName 'Tesseract OCR'
Install-WingetPackage -Id 'GitHub.cli'                        -FriendlyName 'GitHub CLI (gh) -- run `gh auth login` after install to authenticate'

Write-Step 'Refreshing PATH in current session'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

foreach ($cmd in 'git','pwsh') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Warn "$cmd not yet on PATH -- you may need to open a new terminal."
    }
}

# --- REGION: PowerShell modules
Write-Step 'Installing required PowerShell modules'
if (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue) {
    Write-Step '  powershell-yaml already installed'
} else {
    Write-Step '  installing powershell-yaml (CurrentUser scope)'
    try {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        Write-Warn "  Install-Module powershell-yaml failed: $($_.Exception.Message)"
        Write-Warn "  Test-Project.ps1 will refuse to run until this is fixed."
        Write-Warn "  Try manually: Install-Module powershell-yaml -Scope CurrentUser"
    }
}

# --- REGION: Hyper-V feature
Write-Step 'Enabling Hyper-V Windows Feature (if not already enabled)'
$dismExe = Join-Path $env:WINDIR 'System32\dism.exe'
$infoOut  = & $dismExe /English /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
$infoExit = $LASTEXITCODE
if ($infoExit -ne 0) {
    if ($infoOut -match '0x800f080c' -or $infoOut -match 'Feature name .* is unknown') {
        Write-Die @'
Hyper-V is not available on this Windows edition, so the test harness cannot run.

DISM reports the Microsoft-Hyper-V-All feature is unknown on this SKU, which
means a Windows Home or S mode edition with no Hyper-V platform. Upgrade to
Windows 11 Pro/Enterprise/Education or Windows Server, or use a different host.
(The pre-flight edition check normally stops this before elevation; it was
reached here only because preflight was skipped or the edition was unrecognized.)
'@
    } else {
        Write-Die "dism.exe /Get-FeatureInfo exited $infoExit. Output:`n$($infoOut -join [Environment]::NewLine)"
    }
} else {
    $state = 'Unknown'
    foreach ($line in $infoOut) {
        if ($line -match '^State\s*:\s*(\S+)') { $state = $Matches[1]; break }
    }
    if ($state -eq 'Enabled') {
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
        if ($enableExit -eq 0 -or $enableExit -eq 3010) {
            Write-Warn 'Hyper-V was just enabled -- a RESTART is required before Invoke-TestRunner will work.'
            $script:RestartNeeded = $true
        } else {
            Write-Die "dism.exe /Enable-Feature exited $enableExit. Output:`n$($enableOut -join [Environment]::NewLine)"
        }
    }
}

# --- REGION: Preserve test/status runtime state
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
$gitExe = if ($gitCmd) { $gitCmd.Source } else { $null }
if (-not $gitExe) { Write-Die 'git not found after install -- open a new terminal and re-run.' }

$parent = Split-Path -Parent $YurunaDir
if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

$YurunaStatusBackup = $null
$TestStatusSubdirs  = @('runtime', 'perf', 'log', 'extension', 'captures', 'ssh')
function Backup-YurunaStatus {
    $src = Join-Path $YurunaDir 'test/status'
    if (-not (Test-Path $src)) { return }
    $hasRuntime = $false
    foreach ($sub in $TestStatusSubdirs) {
        $subPath = Join-Path $src $sub
        if (-not (Test-Path $subPath)) { continue }
        $extras = Get-ChildItem -LiteralPath $subPath -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' }
        if ($extras) { $hasRuntime = $true; break }
    }
    if (-not $hasRuntime) { return }
    # 4-digit entropy (10k possibilities) is weak by design: enough to
    # defeat the deterministic-path symlink trap an attacker could lay
    # at a predictable backup folder ahead of a known-time install, but
    # still readable for the operator inspecting %TEMP%.
    $script:YurunaStatusBackup = Join-Path $env:TEMP ("yuruna-status-backup-{0:D4}" -f (Get-Random -Maximum 10000))
    New-Item -ItemType Directory -Path $script:YurunaStatusBackup -Force | Out-Null
    Write-Step "Preserving test/status runtime state (cycle history, logs, perf, vault, captures, ssh keys)"
    Write-Step "  source : $src"
    Write-Step "  backup : $($script:YurunaStatusBackup)"
    foreach ($sub in $TestStatusSubdirs) {
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
    foreach ($sub in $TestStatusSubdirs) {
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

# --- REGION: Tolerate a v / no-v tag mismatch
# --- REGION: https://yuruna.link/install/explained#tolerating-a-v-prefixed-tag-ref
function Resolve-YurunaRef {
    [OutputType([string])]
    param([string]$GitExe, [string]$Remote, [string]$Ref)
    if (-not $GitExe -or -not $Remote -or -not $Ref) { return $Ref }
    $variant = $null
    if     ($Ref -match '^v(\d{4}\.\d{2}\.\d{2}(\.\d+)?)$') { $variant = $Matches[1] }
    elseif ($Ref -match '^(\d{4}\.\d{2}\.\d{2}(\.\d+)?)$')  { $variant = "v$Ref" }
    if (-not $variant) { return $Ref }
    $prev = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'   # never block on a credential prompt during the probe
    try {
        & $GitExe ls-remote --exit-code $Remote "refs/tags/$Ref" "refs/heads/$Ref" *> $null
        if ($LASTEXITCODE -eq 0) { return $Ref }                 # requested form exists -- prefer it
        & $GitExe ls-remote --exit-code $Remote "refs/tags/$variant" "refs/heads/$variant" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Warn "Requested ref '$Ref' not found on $Remote; using existing variant '$variant' (canonical Yuruna release tags are bare CalVer, no 'v')."
            return $variant
        }
    } finally {
        if ($null -eq $prev) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $prev }
    }
    # Neither form resolves. For a CalVer-shaped ref this usually means the
    # pinned release tag has not been published yet (the VERSION/installer pin
    # ran ahead of the tag). Surface that before the clone fails on it.
    Write-Warn "Neither '$Ref' nor '$variant' resolves on $Remote -- the pinned release tag may not be published yet. To install the latest unreleased code, re-run with -YurunaBranch main."
    return $Ref
}

# --- REGION: Development repo pulls latest main, not a release tag
# --- REGION: https://yuruna.link/install/explained#development-repo-tracks-latest-main
function Resolve-YurunaDevBranch {
    [OutputType([string])]
    param([string]$Basename, [string]$Ref)
    if ($Basename -eq 'yurunadev' -and -not $script:YurunaBranchExplicit -and $Ref -ne 'main') {
        Write-Warn "yurunadev is a development repo (tagged only at release) -- tracking latest 'main' instead of '$Ref'"
        return 'main'
    }
    return $Ref
}

# --- REGION: Clone / update the repo
if (Test-Path (Join-Path $YurunaDir '.git')) {
    Write-Step "Updating existing Yuruna checkout at $YurunaDir"
    $actualRemote   = (& $gitExe -C $YurunaDir remote get-url origin 2>$null)
    if ($actualRemote) { $actualRemote = ([string]$actualRemote).Trim() } else { $actualRemote = '' }
    $remoteForBase  = $actualRemote.TrimEnd('/')
    $remoteForBase  = $remoteForBase -replace '\.git$',''
    $remoteBasename = ($remoteForBase -replace '.*[\\/:]',  '')
    if ($actualRemote) {
        Write-Step "  remote : $actualRemote"
    } else {
        Write-Step "  remote : (none -- 'git remote get-url origin' returned nothing)"
    }

    $skipPull = $false
    if ($remoteBasename -eq 'yurunadev') {
        $prevGitTermPrompt = $env:GIT_TERMINAL_PROMPT
        $env:GIT_TERMINAL_PROMPT = '0'
        try {
            & $gitExe ls-remote --exit-code $actualRemote HEAD *> $null
        } finally {
            if ($null -eq $prevGitTermPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
            else { $env:GIT_TERMINAL_PROMPT = $prevGitTermPrompt }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Warn ''
            Write-Warn '============================================================'
            Write-Warn "  $actualRemote requires GitHub authentication to pull, and"
            Write-Warn "  the current credentials don't grant access (or no credentials"
            Write-Warn '  are configured).'
            Write-Warn ''
            Write-Warn '  Authenticate first, then re-run this installer:'
            Write-Warn '    gh auth login     # interactive GitHub CLI sign-in'
            Write-Warn '    # OR configure an SSH key with read access to the repo'
            Write-Warn ''
            Write-Warn "  Continuing this run WITHOUT updating $YurunaDir --"
            Write-Warn '  existing on-disk content will be used as-is.'
            Write-Warn '============================================================'
            Write-Warn ''
            $skipPull = $true
        }
    }

    if (-not $skipPull) {
        $YurunaBranch = Resolve-YurunaDevBranch -Basename $remoteBasename -Ref $YurunaBranch
        if ($actualRemote) { $YurunaBranch = Resolve-YurunaRef -GitExe $gitExe -Remote $actualRemote -Ref $YurunaBranch }
        # --force so a remote-moved release tag overwrites the stale local one. A
        # CalVer tag (YYYY.MM.DD) can point at different commits in the public vs
        # development repo, so a plain `fetch --tags` hits "would clobber existing
        # tag" and git exits non-zero. PSNativeCommandUseErrorActionPreference is
        # $false here so that does not throw, but without --force the moved tag is
        # silently never adopted; warn on any residual non-zero so it is visible.
        & $gitExe -C $YurunaDir fetch --tags --force origin
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "git fetch reported rejected/partial tag updates (exit $LASTEXITCODE) -- continuing; checkout/pull below will surface anything fatal."
        }
        & $gitExe -C $YurunaDir checkout $YurunaBranch
        $checkoutExit = $LASTEXITCODE
        if ($checkoutExit -eq 0) {
            # Match the shell installers' { checkout && pull } semantics: only pull when the
            # branch switch actually succeeded. A failed checkout must trigger the same move-
            # aside-and-re-clone rescue as a failed pull, otherwise the update proceeds on the
            # wrong ref.
            & $gitExe -C $YurunaDir pull --ff-only origin $YurunaBranch 2>&1 | ForEach-Object {
                if ($_ -match 'Already up to date|Fast-forward|Updating') { Write-Output "     $_" }
                else { Write-Warn $_ }
            }
            $pullExit = $LASTEXITCODE
        }
        else {
            Write-Warn "git checkout $YurunaBranch failed (exit $checkoutExit) -- skipping pull; moving the existing checkout aside and re-cloning."
            $pullExit = $checkoutExit
        }
        if ($pullExit -ne 0) {
            # Seconds-precision stamp so re-running the installer within
            # the same minute (transient git failure -> immediate retry)
            # doesn't collide on the destination directory and abort the
            # Move-Item below.
            $stamp = Get-Date -Format 'yyyy-MM-dd.HH-mm-ss'
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

            # Cap the backup-dir history at N=3 newest. Without this prune,
            # every failed-pull re-clone leaves another <YurunaDir>.backup.*
            # behind; on a long-lived host that's tens of multi-GB copies
            # silently chewing disk. Sort by name (timestamp-prefixed so
            # lexicographic == chronological), keep newest 3, delete rest.
            try {
                $parentDir   = Split-Path -Parent $YurunaDir
                $baseName    = Split-Path -Leaf   $YurunaDir
                $allBackups  = @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter "$baseName.backup.*" -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending)
                if ($allBackups.Count -gt 3) {
                    $toDelete = $allBackups[3..($allBackups.Count - 1)]
                    foreach ($d in $toDelete) {
                        Write-Warn "  pruning old backup: $($d.FullName)"
                        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
                    }
                }
            } catch {
                Write-Warn "  backup-dir prune skipped (non-fatal): $($_.Exception.Message)"
            }

            $recloneRemote = if ($actualRemote) { $actualRemote } else { $YurunaRepo }
            Write-Step "Cloning fresh Yuruna into $YurunaDir from $recloneRemote"
            & $gitExe clone --branch $YurunaBranch $recloneRemote $YurunaDir
            if ($LASTEXITCODE -ne 0) { Write-Die "git clone --branch $YurunaBranch failed (exit $LASTEXITCODE) -- the branch/tag '$YurunaBranch' may not exist on $recloneRemote. No checkout was created." }
        }
    }
} else {
    $cloneBasename = (($YurunaRepo.TrimEnd('/') -replace '\.git$','') -replace '.*[\\/:]','')
    $YurunaBranch  = Resolve-YurunaDevBranch -Basename $cloneBasename -Ref $YurunaBranch
    $YurunaBranch = Resolve-YurunaRef -GitExe $gitExe -Remote $YurunaRepo -Ref $YurunaBranch
    Write-Step "Cloning Yuruna into $YurunaDir from $YurunaRepo"
    & $gitExe clone --branch $YurunaBranch $YurunaRepo $YurunaDir
    if ($LASTEXITCODE -ne 0) { Write-Die "git clone --branch $YurunaBranch failed (exit $LASTEXITCODE) -- the branch/tag '$YurunaBranch' may not exist on $YurunaRepo. No checkout was created." }
}

# --- REGION: Renormalize line endings under .gitattributes
if (Test-Path (Join-Path $YurunaDir '.git')) {
    Write-Step 'Renormalizing repo line endings (per .gitattributes)'
    & $gitExe -C $YurunaDir config core.autocrlf input | Out-Null

    $existingIncludes = @(& $gitExe -C $YurunaDir config --get-all include.path 2>$null)
    if ($existingIncludes -notcontains '../.gitconfig.yuruna') {
        & $gitExe -C $YurunaDir config --local --add include.path '../.gitconfig.yuruna' | Out-Null
        Write-Step '  Enabled pull.rebase via .gitconfig.yuruna include'
    }

    & $gitExe -C $YurunaDir update-index --refresh 2>&1 | Out-Null
    & $gitExe -C $YurunaDir diff-index --quiet HEAD -- 2>&1 | Out-Null
    $repoDirty = ($LASTEXITCODE -ne 0)

    if ($repoDirty) {
        Write-Warn '  Working tree has uncommitted changes -- only renormalizing the index.'
        & $gitExe -C $YurunaDir add --renormalize . | Out-Null
        Write-Warn '  After resolving local changes, run: git checkout HEAD -- .'
    } else {
        & $gitExe -C $YurunaDir rm -r --cached --quiet . | Out-Null
        & $gitExe -C $YurunaDir reset --hard HEAD 2>&1 | Out-Null
        Write-Step '  Working tree rebuilt under current .gitattributes (LF for *.sh, etc.)'
    }
}

# --- REGION: Pin to the current release (opt-in)
# -PinVersion: now that 'main' is cloned/updated, read the repo's own VERSION
# file (single source of truth -- top of the repository) and detach HEAD at that
# release tag so the host freezes there and the per-cycle `git pull` is a no-op.
# An explicit -YurunaBranch already chose a ref, so skip. If VERSION runs ahead
# of the published tag, warn and leave the host on 'main' rather than fail.
if ($PinVersion -and -not $script:YurunaBranchExplicit -and (Test-Path (Join-Path $YurunaDir '.git'))) {
    $versionFile = Join-Path $YurunaDir 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        $pinTag = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        Write-Step "Pinning to release $pinTag (from VERSION) -- this host will NOT auto-update"
        & $gitExe -C $YurunaDir checkout $pinTag 2>&1 | ForEach-Object { Write-Output "     $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not check out '$pinTag' (the release tag may not be published yet) -- leaving the host on 'main' (it will auto-update). Re-run -PinVersion after the tag is cut, or use -YurunaBranch <tag>."
        }
    } else {
        Write-Warn "No VERSION file at $versionFile -- cannot resolve a release to pin; leaving the host on 'main'."
    }
}
Restore-YurunaStatus

# --- REGION: Seed test.config.yml from template
$testDir = Join-Path $YurunaDir 'test'
$cfg     = Join-Path $testDir 'test.config.yml'
$tpl     = Join-Path $testDir 'test.config.yml.template'
if (-not (Test-Path $cfg) -and (Test-Path $tpl)) {
    Write-Step 'Creating test\test.config.yml from template (review before running tests)'
    Copy-Item $tpl $cfg
}

# --- REGION: Baseline reset: remove test-* VMs
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

# --- REGION: Enable-TestAutomation.ps1 hint
$setHost = Join-Path $YurunaDir 'host\windows.hyper-v\Enable-TestAutomation.ps1'
Write-Step ''
Write-Step 'Host configuration (test-host setup) is NOT auto-applied.'
Write-Step 'To enable this machine as a test host (disables display timeout'
Write-Step 'and screen lock so Hyper-V screen captures stay readable), run:'
Write-Step "    pwsh `"$setHost`""

$script:InstallSucceeded = $true

} catch {
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
        Write-Output ''
        Write-Output ("Full log of this run: " + $LogPath)
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
    }
    elseif ($script:RestartNeeded) {
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
        Write-Step 'Finishing up -- opening handoff windows'

        $hypervOpened = $false
        try {
            Write-Step '  launching Hyper-V Manager (virtmgmt.msc)'
            Start-Process -FilePath 'virtmgmt.msc' | Out-Null
            $hypervOpened = $true
        } catch {
            Write-Warn ('  could not launch virtmgmt.msc: ' + $_.Exception.Message)
        }

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
        $null = $lines.Add("Write-Host '  * (Optional) To enable this machine as a test host (display timeout' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '    and screen lock off so Hyper-V screen captures stay readable):' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '      pwsh ..\host\windows.hyper-v\Enable-TestAutomation.ps1' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '  * Run the test harness from THIS window:' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '      pwsh .\Invoke-TestRunner.ps1' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '  * Authenticate the GitHub CLI (one-time, optional):' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host '      gh auth login' -ForegroundColor Cyan")
        $null = $lines.Add("Write-Host ''")
        if ($script:YurunaBackupCreated) {
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
            Write-Output '   * (Optional) Enable this machine as a test host (display timeout'
            Write-Output '     and screen lock off so Hyper-V screen captures stay readable):'
            Write-Output ("       pwsh `"" + (Join-Path $YurunaDir 'host\windows.hyper-v\Enable-TestAutomation.ps1') + "`"")
            Write-Output '   * Open a new pwsh window, then run:'
            Write-Output ("       cd `"$testDirFinal`"")
            Write-Output  '       pwsh .\Invoke-TestRunner.ps1'
            Write-Output '   * Authenticate the GitHub CLI (one-time, optional):'
            Write-Output '       gh auth login'
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

# --- REGION: Clean up the single-fetch materialization temp
# Only the final stage reaches here (relaunch stages return earlier). When this
# run arrived via the irm|iex materialization gate, $PSCommandPath is that temp
# file -- remove it now. A crash before this point leaves it for the >1h sweep
# at the next run's top.
if ($PSCommandPath -and (Split-Path -Leaf $PSCommandPath) -match '^yuruna-windows-hyper-v-[0-9a-fA-F]{32}\.ps1$') {
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}

# Close the transcript (best-effort). A hard failure earlier already flushed
# its content to disk even if this footer line is never reached.
Stop-InstallLog
