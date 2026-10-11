<#PSScriptInfo
.VERSION 2026.10.11
.GUID 420d0ea8-9177-435e-9354-be537258454f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test private-state startup permissions
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking

# --- REGION: Test-YurunaStartupLockAccess
function Test-YurunaStartupLockAccess {
    <# .SYNOPSIS
        Check lock metadata without opening or competing for a live lock.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RootPath)
    try {
        $owner = Get-YurunaCurrentOwnerId
        if (-not $owner.Resolved) { return $false }
        $required = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        foreach ($lock in Get-ChildItem -LiteralPath $RootPath -Filter 'status-service.*.start.lock' -Force -ErrorAction Stop) {
            if ($lock.PSIsContainer -or $lock.LinkTarget) { return $false }
            $identity = Get-YurunaPathOwnerId -Path $lock.FullName
            if (-not $identity.Resolved -or $identity.OwnerId -ne $owner.OwnerId) { return $false }
            if (([IO.File]::GetUnixFileMode($lock.FullName) -band $required) -ne $required) { return $false }
        }
        return $true
    } catch {
        Write-Verbose "Private startup lock metadata unavailable: $($_.Exception.Message)"
        return $false
    }
}

# --- REGION: Invoke-YurunaPrivateStateSudoValidation
function Invoke-YurunaPrivateStateSudoValidation {
    <# .SYNOPSIS
        Authenticate through sudo's own terminal prompt without handling the password.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-YurunaCanPrompt)) { return $false }
    $PSNativeCommandUseErrorActionPreference = $false
    # The prompt must inherit the terminal; capturing it would hide the question
    # while sudo still waits for a password from /dev/tty.
    & sudo -p 'Yuruna private-state repair: [sudo] password for %p: ' -v
    return ($LASTEXITCODE -eq 0)
}

# --- REGION: Repair-YurunaStartupPrivateState
function Repair-YurunaStartupPrivateState {
    <#
    .SYNOPSIS
        Recover private-state permissions before an interactive runner loses its terminal.
    .DESCRIPTION
        Ordinary resolver calls stay read-only or unprivileged. Only an explicit
        startup recovery can elevate, and an unattended caller never prompts.
        The repair keeps every lock inode intact and is rechecked by the normal
        resolver before startup can proceed.
    .PARAMETER RepairFileAccess
        Inspect startup locks before a relaunch or after an access-denied result.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string[]]$ServedRoot,
        [switch]$AllowPrompt,
        [switch]$RepairFileAccess
    )
    $root = Get-YurunaPrivateStateRoot -NoCreate -VerifyHome -ServedRoot $ServedRoot
    $result = [ordered]@{
        Resolved = [bool]$root.Resolved; Reason = [string]$root.Reason
        OriginalReason = [string]$root.Reason; RepairAttempted = $false; Privileged = $false
    }
    if ($root.Resolved -and -not $RepairFileAccess) { return [pscustomobject]$result }
    if ($root.Resolved -and $RepairFileAccess -and -not $IsWindows -and (Test-YurunaStartupLockAccess -RootPath $root.Path)) {
        return [pscustomobject]$result
    }
    if ($root.Reason -in @('no-home', 'home-mismatch', 'reparse-point', 'network-filesystem', 'served-tree')) {
        return [pscustomobject]$result
    }
    if (-not $PSCmdlet.ShouldProcess('Yuruna private state', 'Repair startup permissions')) {
        $result.Resolved = $false; $result.Reason = 'preview'; return [pscustomobject]$result
    }
    $result.RepairAttempted = $true
    # The ordinary resolver already creates missing directories and secures a
    # user-owned root. It needs no sudo and preserves Windows ACL behavior.
    $root = Get-YurunaPrivateStateRoot -VerifyHome -ServedRoot $ServedRoot
    if ($root.Resolved -and (-not $RepairFileAccess -or
            (-not $IsWindows -and (Test-YurunaStartupLockAccess -RootPath $root.Path)))) {
        $result.Resolved = $true; $result.Reason = 'ok'; return [pscustomobject]$result
    }
    $result.Resolved = $false; $result.Reason = [string]$root.Reason
    if ($IsWindows) {
        if ($root.Resolved) { $result.Reason = 'file-access-denied' }
        return [pscustomobject]$result
    }
    if ($root.Reason -notin @('ok', 'owner-mismatch', 'owner-unverified', 'parent-untrusted', 'permission-failed', 'permission-loose', 'create-failed', 'resolve-failed')) {
        return [pscustomobject]$result
    }
    if ($root.HomeVerified -ne 'verified') {
        $result.Reason = 'home-unverified'; return [pscustomobject]$result
    }
    $owner = Get-YurunaCurrentOwnerId
    if (-not $owner.Resolved -or $owner.OwnerId -notmatch '^\d+$' -or $owner.PrimaryGroupId -notmatch '^\d+$') {
        $result.Reason = 'owner-unverified'; return [pscustomobject]$result
    }
    $homeCanonical = Resolve-YurunaCanonicalPath -Path $HOME
    if (-not $homeCanonical.Resolved) { $result.Reason = 'home-unverified'; return [pscustomobject]$result }
    $drive = Get-YurunaPathDriveInfo -Path $homeCanonical.Path
    if (-not $drive.Resolved -or $drive.DriveType -eq 'Network') {
        $result.Reason = 'filesystem-unverified'; return [pscustomobject]$result
    }
    # Validate containment without entering a possibly root-owned directory.
    # The helper refuses links and mount crossings before changing permissions.
    $candidate = Join-Path $homeCanonical.Path '.yuruna/host-refresh'
    $comparison = if ($IsMacOS) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($served in @($ServedRoot | Where-Object { $_ })) {
        $canonical = Resolve-YurunaCanonicalPath -Path $served
        if (-not $canonical.Resolved) { $result.Reason = 'served-root-unverified'; return [pscustomobject]$result }
        $servedPath = $canonical.Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($candidate.Equals($servedPath, $comparison) -or
            $candidate.StartsWith($servedPath + [IO.Path]::DirectorySeparatorChar, $comparison) -or
            $servedPath.StartsWith($candidate + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            $result.Reason = 'served-tree'; return [pscustomobject]$result
        }
    }
    $python = Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) { $result.Reason = 'python-missing'; return [pscustomobject]$result }
    $arguments = @((Join-Path $PSScriptRoot '../service/Repair-PrivateState.py'), '--home', $homeCanonical.Path,
        '--uid', [string]$owner.OwnerId, '--gid', [string]$owner.PrimaryGroupId)
    $repair = Invoke-BoundedNativeCommand -FilePath $python.Source -ArgumentList $arguments -TimeoutSeconds 30
    if ((Test-BoundedNativeResultComplete -Result $repair) -and $repair.ExitCode -eq 2 -and -not $owner.IsRoot) {
        $sudo = Get-Command sudo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $sudo) { $result.Reason = 'sudo-missing'; return [pscustomobject]$result }
        $sudoArguments = @('-n', '--', $python.Source) + $arguments
        $repair = Invoke-BoundedNativeCommand -FilePath $sudo.Source -ArgumentList $sudoArguments -TimeoutSeconds 30 -Environment @{ LC_ALL = 'C' }
        $result.Privileged = $true
        if ((Test-BoundedNativeResultComplete -Result $repair) -and $repair.ExitCode -ne 0 -and
            (Test-YurunaSudoRefusal -Output $repair.StdErr)) {
            if (-not $AllowPrompt -or -not (Test-YurunaCanPrompt)) {
                $result.Reason = 'sudo-password-required'; return [pscustomobject]$result
            }
            if (-not (Invoke-YurunaPrivateStateSudoValidation)) {
                $result.Reason = 'sudo-authentication-failed'; return [pscustomobject]$result
            }
            $repair = Invoke-BoundedNativeCommand -FilePath $sudo.Source -ArgumentList $sudoArguments -TimeoutSeconds 30 -Environment @{ LC_ALL = 'C' }
            if ((Test-BoundedNativeResultComplete -Result $repair) -and $repair.ExitCode -ne 0 -and
                (Test-YurunaSudoRefusal -Output $repair.StdErr)) {
                $result.Reason = 'sudo-authorization-failed'; return [pscustomobject]$result
            }
        }
    }
    if (-not (Test-BoundedNativeResultComplete -Result $repair)) {
        $result.Reason = 'repair-incomplete'; return [pscustomobject]$result
    }
    if ($repair.ExitCode -ne 0) {
        $result.Reason = 'repair-failed'
        try {
            $detail = $repair.StdOut | ConvertFrom-Json -ErrorAction Stop
            if ($detail.reason) { $result.Reason = [string]$detail.reason }
        } catch { Write-Verbose 'Private-state repair returned no outcome record.' }
        return [pscustomobject]$result
    }
    $verified = Get-YurunaPrivateStateRoot -VerifyHome -ServedRoot $ServedRoot
    $result.Resolved = [bool]$verified.Resolved; $result.Reason = [string]$verified.Reason
    return [pscustomobject]$result
}

Export-ModuleMember -Function Repair-YurunaStartupPrivateState
