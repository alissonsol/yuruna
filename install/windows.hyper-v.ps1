<#PSScriptInfo
.VERSION 2026.05.29
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
    [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'

$script:YurunaRepoPublic  = 'https://github.com/alissonsol/yuruna.git'
$script:YurunaRepoPrivate = 'https://github.com/alissonsol/yurunadev.git'

function Write-Step { param([string]$m) Write-Output "==> $m" }
function Write-Warn { param([string]$m) Write-Warning $m }
function Write-Die  { param([string]$m) Write-Error $m }

# -- Preflight: Windows only -----------------------------------------------
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Write-Die 'This installer only supports Windows.'
}

# -- Preflight: system requirements ----------------------------------------
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
    Test-SystemRequirement
}

# -- Preflight: display scaling --------------------------------------------
# --- See https://yuruna.link/install/explained#display-scaling-check
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

# -- Elevation announcement + self-relaunch --------------------------------
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
    if ($PSCommandPath) {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"", '-SkipPreflight')
        if ($PSBoundParameters.ContainsKey('YurunaDir'))    { $argList += @('-YurunaDir',    "`"$YurunaDir`"") }
        if ($PSBoundParameters.ContainsKey('YurunaRepo'))   { $argList += @('-YurunaRepo',   "`"$YurunaRepo`"") }
        if ($PSBoundParameters.ContainsKey('YurunaBranch')) { $argList += @('-YurunaBranch', "`"$YurunaBranch`"") }
        Start-Process -FilePath $currentShellExe -Verb RunAs -ArgumentList $argList
    } else {
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
    return
}

Write-Step "Yuruna Windows installer starting"
Write-Step "  repo   : $YurunaRepo ($YurunaBranch)"
Write-Step "  target : $YurunaDir"
Write-Step "  shell  : $((Get-Process -Id $PID).ProcessName) (PowerShell $($PSVersionTable.PSVersion))"

# -- PowerShell 7 bootstrap (PS 5.1 -> PS 7) -------------------------------
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
        Write-Step '  PowerShell 7 already installed (winget reports present)'
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
    if ($PSCommandPath) {
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

# -- Stop running Yuruna processes -----------------------------------------
function Stop-YurunaProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $patterns = @('Invoke-TestRunner.ps1','Invoke-TestInnerRunner.ps1','Test-Sequence.ps1','Start-StatusService.ps1')
    foreach ($pat in $patterns) {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$pat*" -and $_.ProcessId -ne $PID }
        foreach ($p in $procs) {
            Write-Step "  stopping $pat (pid $($p.ProcessId))"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
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

# -- yuruna-caching-proxy detection ----------------------------------------
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

Write-Step 'Stopping anything that would block an upgrade'
Stop-YurunaProcess

# -- winget availability ---------------------------------------------------
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

# -- Install platform packages ---------------------------------------------
Write-Step 'Installing / upgrading required packages via winget'
Install-WingetPackage -Id 'Microsoft.PowerShell'              -FriendlyName 'PowerShell 7'
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

# -- PowerShell modules ----------------------------------------------------
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

# -- Hyper-V feature -------------------------------------------------------
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

# -- Preserve test/status runtime state ------------------------------------
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

# -- Clone / update the repo -----------------------------------------------
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
        & $gitExe -C $YurunaDir fetch --tags origin
        & $gitExe -C $YurunaDir checkout $YurunaBranch
        & $gitExe -C $YurunaDir pull --ff-only origin $YurunaBranch 2>&1 | ForEach-Object {
            if ($_ -match 'Already up to date|Fast-forward|Updating') { Write-Output "     $_" }
            else { Write-Warn $_ }
        }
        $pullExit = $LASTEXITCODE
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
        }
    }
} else {
    Write-Step "Cloning Yuruna into $YurunaDir from $YurunaRepo"
    & $gitExe clone --branch $YurunaBranch $YurunaRepo $YurunaDir
}

# -- Renormalize line endings under .gitattributes -------------------------
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
Restore-YurunaStatus

# -- Seed test.config.yml from template ------------------------------------
$testDir = Join-Path $YurunaDir 'test'
$cfg     = Join-Path $testDir 'test.config.yml'
$tpl     = Join-Path $testDir 'test.config.yml.template'
if (-not (Test-Path $cfg) -and (Test-Path $tpl)) {
    Write-Step 'Creating test\test.config.yml from template (review before running tests)'
    Copy-Item $tpl $cfg
}

# -- Baseline reset: remove test-* VMs -------------------------------------
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

# -- Enable-TestAutomation.ps1 hint ----------------------------------------
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
