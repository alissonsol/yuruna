<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4202eb15-d68a-475f-9f7f-9e84da9b500a
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
    Updates Windows 11 system packages.
.DESCRIPTION
    Installs Windows updates, updates winget packages, and performs system cleanup.
    Run this script in an elevated PowerShell terminal.
#>

# --- REGION: Ensure running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output ""
    Write-Output "========"
    Write-Output "|  This script requires elevation (Run as Administrator)    |"
    Write-Output "|  Right-click PowerShell and select 'Run as Administrator' |"
    Write-Output "========"
    Write-Output ""
    throw 'Guest update failed; review the preceding error.'
}

# See https://yuruna.link/42e220c4-0005
# --- REGION: Invoke-GuestWingetInstall
function Invoke-GuestWingetInstall {
    <#
    .SYNOPSIS
        Install a prerequisite or accept its documented already-present outcome.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageId)
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    try {
        & winget install --id $PackageId --accept-source-agreements --accept-package-agreements --silent
        $wingetSucceeded = $?
        $wingetNativeExitCode = $global:LASTEXITCODE
    } catch {
        throw
    }
    $wingetExitCode = 0L
    if ($null -eq $wingetNativeExitCode -or -not [long]::TryParse([string]$wingetNativeExitCode, [ref]$wingetExitCode) -or $wingetExitCode -lt -2147483648 -or $wingetExitCode -gt 4294967295) {
        throw "Package installation failed for $PackageId without a valid native exit code."
    }
    if ($wingetExitCode -ge 2147483648) { $wingetExitCode -= 4294967296 }
    if ($wingetExitCode -notin @(0, -1978335189, -1978335135) -or ($wingetExitCode -eq 0 -and -not $wingetSucceeded)) {
        throw "Package installation failed for $PackageId (winget exit code $wingetExitCode)."
    }
}

# --- REGION: Ensure execution policy allows scripts
$ProgressPreference = 'SilentlyContinue'
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# --- REGION: Detect architecture
# See https://yuruna.link/42e220c4-0015
$nativeProcessor = Get-CimInstance -ClassName Win32_Processor -Property Architecture -ErrorAction Stop | Select-Object -First 1
if ($null -eq $nativeProcessor -or $null -eq $nativeProcessor.Architecture) { throw 'Cannot determine the native processor architecture for the guest update.' }
$arch = switch ($nativeProcessor.Architecture) {
    9 { 'AMD64' }
    12 { 'ARM64' }
    default { "Unknown ($($nativeProcessor.Architecture))" }
}
Write-Output "Detected architecture: $arch"
switch ($arch) {
    'AMD64' { Write-Output 'Environment: x86_64/amd64' }
    'ARM64' { Write-Output 'Environment: aarch64/arm64' }
    default {
        Write-Output "WARNING: Unsupported architecture: $arch"
        Write-Output "This script supports AMD64 and ARM64."
        throw 'Guest update failed; review the preceding error.'
    }
}

# --- REGION: Ensure PowerShell is installed
# See https://yuruna.link/42d69dfa-0036
Write-Output ""
Write-Output ">>> Checking for PowerShell 7..."
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshPath) {
    Write-Output "PowerShell 7 not found. Installing..."
    Invoke-GuestWingetInstall -PackageId 'Microsoft.PowerShell'
    # Refresh PATH so the newly installed pwsh is discoverable
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Output "<<< PowerShell 7 installation complete."
} else {
    Write-Output "PowerShell 7 found at $($pwshPath.Source)"
}

# --- REGION: Install powershell-yaml module
# See https://yuruna.link/42d69dfa-0038
Write-Output ""
Write-Output ">>> Installing PowerShell module: powershell-yaml..."
# 2.8.5.201 is Microsoft's documented TLS-1.2-capable NuGet provider
# bootstrap floor, not a workload pin.
$yamlInstall = "if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null }; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name powershell-yaml -Scope AllUsers -Force -Confirm:`$false"
$yamlOk = $false
for ($attempt = 1; $attempt -le 3 -and -not $yamlOk; $attempt++) {
    pwsh -NoProfile -Command $yamlInstall
    pwsh -NoProfile -Command "Import-Module powershell-yaml -ErrorAction Stop; if ((ConvertFrom-Yaml 'k: v').k -ne 'v') { exit 1 }"
    if ($LASTEXITCODE -eq 0) { $yamlOk = $true }
    else { Write-Output "powershell-yaml install/import attempt $attempt/3 failed; retrying..."; Start-Sleep -Seconds ($attempt * 5) }
}
if (-not $yamlOk) {
    Write-Error "powershell-yaml failed to install/import after 3 attempts; it is required by the in-guest sequence planner and Get-SystemDiagnostic.ps1."
    throw 'Guest update failed; review the preceding error.'
}
Write-Output "<<< PowerShell module: powershell-yaml installation complete."

# --- REGION: Early yuruna framework extraction
# See https://yuruna.link/42d69dfa-0037
# Tarball-only here; the git-clone fallback lives in the Materialize section below.
Write-Output ""
Write-Output ">>> Pre-fetching yuruna framework tarball (for diagnostic availability)..."
$yurunaRoot = Join-Path $env:USERPROFILE 'yuruna'
$frameworkVersion = Join-Path $yurunaRoot 'VERSION'
$hostEnv    = 'C:\ProgramData\yuruna\host.env'
if (Test-Path -LiteralPath $hostEnv -PathType Leaf) {
    Get-Content -LiteralPath $hostEnv | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$') {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
        }
    }
}
if ($env:YURUNA_STATUS_SERVICE_IP -and $env:YURUNA_STATUS_SERVICE_PORT -and -not (Test-Path -LiteralPath $yurunaRoot -PathType Container)) {
    $livecheckUrl = "http://$($env:YURUNA_STATUS_SERVICE_IP):$($env:YURUNA_STATUS_SERVICE_PORT)/livecheck"
    $tarballUrl   = "http://$($env:YURUNA_STATUS_SERVICE_IP):$($env:YURUNA_STATUS_SERVICE_PORT)/yuruna-archive.tar.gz"
    try {
        # Probe liveness without downloading a response body.
        $null = Invoke-WebRequest -Uri $livecheckUrl -Method Head -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        New-Item -ItemType Directory -Path $yurunaRoot -Force | Out-Null
        $tarPath = Join-Path $env:TEMP 'yuruna-archive.tar.gz'
        Invoke-WebRequest -Uri $tarballUrl -UseBasicParsing -OutFile $tarPath -ErrorAction Stop
        # tar.exe (bsdtar) ships in-box since Windows 10 1803 and reads .tar.gz directly.
        tar.exe -xzf $tarPath -C $yurunaRoot
        if ($LASTEXITCODE -ne 0) { throw "Framework archive extraction failed (tar exit code $LASTEXITCODE)." }
        if (-not (Test-Path -LiteralPath $frameworkVersion -PathType Leaf) -or (Get-Item -LiteralPath $frameworkVersion).Length -eq 0) {
            throw 'Framework archive lacks a nonempty VERSION file.'
        }
        Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
        Write-Output "<<< Yuruna framework available at $yurunaRoot (early extract)."
    } catch {
        if (Test-Path -LiteralPath $yurunaRoot) { Remove-Item -LiteralPath $yurunaRoot -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Output "yuruna: early tarball fetch failed -- $($_.Exception.Message)"
    }
} else {
    Write-Output "yuruna: host.env not present or yuruna already extracted -- skipping early extract."
}

# --- REGION: Disable services that may suspend the machine
# Match the Linux no-sleep contract; powercfg updates the active scheme.
# Suppress harmless output when firmware already disabled hibernation.
Write-Output ""
Write-Output "TESTHACK: Disabling services that may suspend the machine."
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change standby-timeout-dc 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-dc 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-dc 0 | Out-Null
powercfg /hibernate off 2>$null

# --- REGION: Update system packages
Write-Output ""
Write-Output ">>> Updating winget packages..."
winget upgrade --all --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< winget package update complete."

Write-Output ""
Write-Output ">>> Installing Windows Update module..."
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    # 2.8.5.201 is Microsoft's documented TLS-1.2-capable NuGet provider
    # bootstrap floor, not a workload pin.
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -Confirm:$false
}
Import-Module PSWindowsUpdate
Write-Output "<<< Windows Update module ready."

Write-Output ""
Write-Output ">>> Checking for Windows updates..."
# See https://yuruna.link/42e220c4-0005
# Bound Windows Update; the child job must import its own module.
$wuTimeoutSeconds = 1800
$wuJob = Start-Job -ScriptBlock { Import-Module PSWindowsUpdate; Get-WindowsUpdate -AcceptAll -Install -AutoReboot:$false -Verbose }
if (Wait-Job -Job $wuJob -Timeout $wuTimeoutSeconds) {
    Receive-Job -Job $wuJob
} else {
    Write-Warning "Get-WindowsUpdate exceeded ${wuTimeoutSeconds}s; stopping the update job and continuing provisioning."
    Stop-Job -Job $wuJob -ErrorAction SilentlyContinue
}
Remove-Job -Job $wuJob -Force -ErrorAction SilentlyContinue
Write-Output "<<< Windows update check complete."

# --- REGION: Ensure Git is installed
Write-Output ""
Write-Output ">>> Ensuring Git is installed..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Invoke-GuestWingetInstall -PackageId 'Git.Git'
    # Refresh PATH so the newly installed Git is discoverable in this session.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
}
git --version
Write-Output "<<< Git ready."

# --- REGION: Resolve framework and project URLs
# See https://yuruna.link/42fa6f45-000c
$frameworkUrl = ''
$projectUrl   = ''
if ($env:YURUNA_STATUS_SERVICE_IP -and $env:YURUNA_STATUS_SERVICE_PORT) {
    $cfgUrl = "http://$($env:YURUNA_STATUS_SERVICE_IP):$($env:YURUNA_STATUS_SERVICE_PORT)/control/test-config"
    try {
        $cfg = Invoke-RestMethod -Uri $cfgUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($cfg.repositories.frameworkUrl) { $frameworkUrl = [string]$cfg.repositories.frameworkUrl }
        if ($cfg.repositories.projectUrl)   { $projectUrl   = [string]$cfg.repositories.projectUrl }
    } catch {
        Write-Output "yuruna: /control/test-config unreachable -- using seeded clone URLs when available."
    }
}

# host.env keeps clone URLs available while the status service is unreachable.
if (-not $frameworkUrl) { $frameworkUrl = [string]$env:YURUNA_FRAMEWORK_URL }
if (-not $projectUrl) { $projectUrl = [string]$env:YURUNA_PROJECT_URL }

# --- REGION: Keep git non-interactive
# See https://yuruna.link/4220a755-004f
# See https://yuruna.link/42e220c4-0005
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'
$gitAskpassShim = 'C:\ProgramData\yuruna\git-askpass.cmd'
if (Test-Path -LiteralPath $gitAskpassShim -PathType Leaf) {
    $env:GIT_ASKPASS = $gitAskpassShim
}

# --- REGION: Materialize the yuruna framework and project repos
# See https://yuruna.link/42e220c4-000e
function Invoke-GuestPinnedFramework {
    <#
    .SYNOPSIS
        Materialize one trusted framework commit through the LAN or its origin.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Revision,
        [string]$MirrorIp = ''
    )
    if ($Repository -cnotmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$' -or
        $Revision -cnotmatch '^[0-9a-f]{40}$' -or (Test-Path -LiteralPath $Destination)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'Materialize the selected framework commit')) { return $false }
    $stage = "$Destination.fetch.$([Guid]::NewGuid().ToString('N'))"
    $origin = "https://github.com/$Repository.git"
    $sources = @()
    if ($MirrorIp -cmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { $sources += @{ Url = "http://$MirrorIp/git/$Repository.git"; Name = 'lan-mirror' } }
    $sources += @{ Url = $origin; Name = 'github' }
    try {
        foreach ($source in $sources) {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            $null = New-Item -ItemType Directory -Path $stage
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(120)
            $complete = $true
            foreach ($arguments in @(
                    ,@('init', '--quiet', $stage)
                    ,@('-C', $stage, 'fetch', '--quiet', '--depth', '1', '--no-tags', '--', $source.Url, $Revision)
                    ,@('-C', $stage, 'checkout', '--quiet', '--detach', 'FETCH_HEAD')
                )) {
                if (-not (Invoke-GuestPinnedGitCommand -Arguments $arguments -Mirror:($source.Name -eq 'lan-mirror') -Deadline $deadline)) { $complete = $false; break }
            }
            if (-not $complete) { continue }
            $actual = @(& git -C $stage rev-parse HEAD 2>$null)
            $version = Join-Path $stage VERSION
            if ($LASTEXITCODE -ne 0 -or ($actual -join '').Trim() -cne $Revision -or
                -not (Test-Path -LiteralPath $version -PathType Leaf) -or (Get-Item -LiteralPath $version).Length -eq 0) { continue }
            [IO.File]::WriteAllText((Join-Path $stage '.yuruna-revision'), "$Revision`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $stage '.yuruna-origin'), "$origin`n", [Text.UTF8Encoding]::new($false))
            foreach ($relative in @('.git', 'docs', 'dev-only')) {
                $excluded = Join-Path $stage $relative
                if (Test-Path -LiteralPath $excluded) { Remove-Item -LiteralPath $excluded -Recurse -Force }
            }
            [IO.Directory]::Move($stage, $Destination)
            Write-Information "yuruna: framework source=$($source.Name) commit=$Revision" -InformationAction Continue
            return $true
        }
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $false
}

function Invoke-GuestPinnedGitCommand {
    <#
    .SYNOPSIS
        Bound a standalone guest Git process without forwarding credentials to the LAN.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]]$Arguments, [switch]$Mirror, [DateTimeOffset]$Deadline)
    $remaining = [Math]::Floor(($Deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
    if ($remaining -le 0) { return $false }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = 'git'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $privateHome = ''
    $prefix = @('-c', 'http.lowSpeedLimit=1024', '-c', 'http.lowSpeedTime=30')
    if ($Mirror) {
        $prefix += @('-c', 'http.proxy=', '-c', 'credential.helper=', '-c', 'http.extraHeader=', '-c', 'http.followRedirects=false')
        foreach ($name in @($start.EnvironmentVariables.Keys)) {
            if ($name -like 'GIT_*' -or $name -like '*_PROXY' -or $name -in @('GH_TOKEN', 'GITHUB_TOKEN', 'SSH_ASKPASS')) { $start.EnvironmentVariables.Remove($name) }
        }
        $privateHome = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-git-home-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $privateHome
        foreach ($name in @('HOME', 'USERPROFILE', 'XDG_CONFIG_HOME')) { $start.EnvironmentVariables[$name] = $privateHome }
        $start.EnvironmentVariables['GIT_CONFIG_COUNT'] = '0'
        $start.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
        $start.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = '/dev/null'
        $start.EnvironmentVariables['GIT_CONFIG_SYSTEM'] = '/dev/null'
        $start.EnvironmentVariables['GIT_ASKPASS'] = ''
        $start.EnvironmentVariables['SSH_ASKPASS'] = ''
    }
    $start.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $start.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    # ProcessStartInfo.ArgumentList is absent in Windows PowerShell 5.1.
    # Quote each native argument using Windows' backslash-before-quote rules.
    $start.Arguments = (($prefix + $Arguments | ForEach-Object {
        '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }) -join ' ')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { return $false }
        $process.StandardInput.Close()
        # Discard native output while draining it; a mirror must not grow the
        # guest's memory or leave it blocked on a descendant's inherited pipe.
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        if (-not $process.WaitForExit([int][Math]::Min(120000, $remaining))) {
            if ($env:OS -eq 'Windows_NT') { & taskkill.exe /PID $process.Id /T /F *> $null }
            else { $process.Kill($true) }
            $null = $process.WaitForExit(5000)
            return $false
        }
        foreach ($drain in @($stdout, $stderr)) {
            $drainMilliseconds = [int][Math]::Max(0, [Math]::Min(120000, [Math]::Floor(($Deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)))
            if (-not $drain.Wait($drainMilliseconds)) { return $false }
        }
        return $process.ExitCode -eq 0
    } catch { return $false }
    finally {
        $process.Dispose()
        if ($privateHome) { Remove-Item -LiteralPath $privateHome -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if (-not (Test-Path -LiteralPath $yurunaRoot -PathType Container)) {
    $hostOk = $false
    if ($env:YURUNA_STATUS_SERVICE_IP -and $env:YURUNA_STATUS_SERVICE_PORT) {
        $livecheckUrl = "http://$($env:YURUNA_STATUS_SERVICE_IP):$($env:YURUNA_STATUS_SERVICE_PORT)/livecheck"
        $tarballUrl   = "http://$($env:YURUNA_STATUS_SERVICE_IP):$($env:YURUNA_STATUS_SERVICE_PORT)/yuruna-archive.tar.gz"
        try {
            $null = Invoke-WebRequest -Uri $livecheckUrl -Method Head -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            Write-Output "yuruna: fetching committed tarball from $tarballUrl"
            New-Item -ItemType Directory -Path $yurunaRoot -Force | Out-Null
            $tarPath = Join-Path $env:TEMP 'yuruna-archive.tar.gz'
            Invoke-WebRequest -Uri $tarballUrl -UseBasicParsing -OutFile $tarPath -ErrorAction Stop
            tar.exe -xzf $tarPath -C $yurunaRoot
            if ($LASTEXITCODE -ne 0) { throw "Framework archive extraction failed (tar exit code $LASTEXITCODE)." }
            if (-not (Test-Path -LiteralPath $frameworkVersion -PathType Leaf) -or (Get-Item -LiteralPath $frameworkVersion).Length -eq 0) {
                throw 'Framework archive lacks a nonempty VERSION file.'
            }
            Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
            $hostOk = $true
        } catch {
            Write-Output "yuruna: tarball fetch/extract failed - falling back to git clone"
            if (Test-Path -LiteralPath $yurunaRoot) { Remove-Item -LiteralPath $yurunaRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    $pinnedRepository = if ($env:E_FB_REPO) { $env:E_FB_REPO } else { $env:YURUNA_GITHUB_REPO }
    $pinnedRevision = if ($env:E_FB_REF) { $env:E_FB_REF } else { $env:YURUNA_GITHUB_REF }
    if (-not $hostOk -and ($pinnedRepository -or $pinnedRevision)) {
        $hostOk = Invoke-GuestPinnedFramework -Destination $yurunaRoot -Repository $pinnedRepository -Revision $pinnedRevision -MirrorIp $env:YURUNA_CACHING_PROXY_SERVICE_IP -Confirm:$false
        if (-not $hostOk) { throw 'The selected framework commit is unavailable; no different revision was installed.' }
    }
    if (-not $hostOk) {
        if (-not $frameworkUrl) {
            Write-Error 'yuruna: repositories.frameworkUrl missing from test.config.yml - cannot clone framework'
            throw 'Guest update failed; review the preceding error.'
        }
        $cloned = $false
        for ($attempt = 1; $attempt -le 3 -and -not $cloned; $attempt++) {
            git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone $frameworkUrl $yurunaRoot
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $frameworkVersion -PathType Leaf) -and (Get-Item -LiteralPath $frameworkVersion).Length -gt 0) { $cloned = $true; break }
            Write-Output "git clone attempt $attempt failed"
            if (Test-Path -LiteralPath $yurunaRoot) { Remove-Item -LiteralPath $yurunaRoot -Recurse -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt 3) { Start-Sleep -Seconds 60 }
        }
        if (-not $cloned) {
            Write-Error 'git clone failed after 3 attempts'
            throw 'Guest update failed; review the preceding error.'
        }
    }
}

$yurunaProject = Join-Path $yurunaRoot 'project'
if (-not (Test-Path -LiteralPath $yurunaProject -PathType Container)) {
    $projectHostOk = $false
    if ($env:YURUNA_STATUS_SERVICE_IP -and $env:YURUNA_STATUS_SERVICE_PORT) {
        $projectTarballUrl = "http://$($env:YURUNA_STATUS_SERVICE_IP):$($env:YURUNA_STATUS_SERVICE_PORT)/yuruna-project-archive.tar.gz"
        Write-Output "yuruna: trying project tarball at $projectTarballUrl"
        try {
            New-Item -ItemType Directory -Path $yurunaProject -Force | Out-Null
            $tarPath = Join-Path $env:TEMP 'yuruna-project-archive.tar.gz'
            Invoke-WebRequest -Uri $projectTarballUrl -UseBasicParsing -OutFile $tarPath -ErrorAction Stop
            tar.exe -xzf $tarPath -C $yurunaProject
            if ($LASTEXITCODE -ne 0) { throw "Project archive extraction failed (tar exit code $LASTEXITCODE)." }
            Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
            if (Get-ChildItem -LiteralPath $yurunaProject -Force -ErrorAction SilentlyContinue) {
                $projectHostOk = $true
            } else {
                throw 'tarball produced empty project directory'
            }
        } catch {
            Write-Output "yuruna: project tarball not served (or empty) - falling back to git clone"
            if (Test-Path -LiteralPath $yurunaProject) { Remove-Item -LiteralPath $yurunaProject -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not $projectHostOk -and $projectUrl) {
        $cloned = $false
        for ($attempt = 1; $attempt -le 3 -and -not $cloned; $attempt++) {
            git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone $projectUrl $yurunaProject
            if ($LASTEXITCODE -eq 0) { $cloned = $true; break }
            Write-Output "project git clone attempt $attempt failed"
            if (Test-Path -LiteralPath $yurunaProject) { Remove-Item -LiteralPath $yurunaProject -Recurse -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt 3) { Start-Sleep -Seconds 60 }
        }
        if (-not $cloned) {
            Write-Error 'project git clone failed after 3 attempts'
            throw 'Guest update failed; review the preceding error.'
        }
    }
}

# --- REGION: Clean up temporary files
Write-Output ""
Write-Output ">>> Cleaning up temporary files..."
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
cleanmgr /sagerun:1 2>$null
Write-Output "<<< Cleanup complete."
