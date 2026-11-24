<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4229b3e5-247e-423a-a9c5-8ffd8e93a5ab
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update controller snapshot
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.CriticalRecord.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.DiagnosticPreservation.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostOperationJournal.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RunnerElevation.psm1') -DisableNameChecking

# The host controller: the one process a host update does not have to kill.
# It runs from a private snapshot of the framework's code, keeps the request
# journal, holds the locks and the runner gate, and runs the work of each
# phase in a step child from the live checkout. The snapshot is what lets it
# run the source update with code that predates a bad commit.

# Snapshot file set, relative to the checkout. Folders are taken whole except
# for the exclusions; single files are taken when present.
$script:HostUpdateSnapshotFolder = @('automation', 'test/modules', 'globalization/generated/powershell')
$script:HostUpdateSnapshotSingleFile = @(
    'globalization/locale-manifest.json'
    'globalization/manifests/catalog-set.json'
    'test/extension/pool-aggregator-service/default.psm1'
    'test/lab/Invoke-HostUpdateController.ps1'
    'test/lab/Invoke-HostUpdateStep.ps1'
    'test/host-update.protocol-version'
)
$script:HostUpdateHashPattern = '\A[0-9a-f]{16}\z'
$script:HostUpdateNamePattern = '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z'
$script:HostUpdateDirectoryMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute

# The phases of each scope, in order; index and count of the public state
# count these. restore and recover are activities, not phases. The full scope
# adds the install, the PowerShell upgrade (Windows only: PowerShell 7 cannot
# replace itself there, so the shim runs it) and the host settings.
$script:HostUpdateRestartPhase = @('preflight', 'drain', 'stop_runner', 'update_source', 'start_listener', 'start_runner')
$script:HostUpdateFullPhase = @('preflight', 'drain', 'stop_runner', 'update_source', 'install', 'upgrade_pwsh', 'enable', 'start_listener', 'start_runner')
# Bounds in seconds per host type: the installer on Windows runs longer, and
# the enable phase on macOS waits on settings the repair's catalog already
# estimates at 300 s.
$script:HostUpdatePhaseBoundSeconds = @{
    preflight = 60; stop_runner = 120; update_source = 300; install = 2400; upgrade_pwsh = 1200; enable = 300
    start_listener = 60; start_runner = 240; restore = 300; recover = 540
}
$script:HostUpdatePhaseBoundOverride = @{
    'host.windows.hyper-v' = @{ install = 3600 }
    'host.macos.utm'       = @{ enable = 600 }
}
# The scopes each host type declares it can run. A host lists full only when
# its declaration has it and the controller's elevation probe passes.
$script:HostUpdateScopeDeclaration = @{
    'host.ubuntu.kvm'      = @('restart', 'full')
    'host.windows.hyper-v' = @('restart', 'full')
    'host.macos.utm'       = @('restart', 'full')
}
$script:HostUpdatePhaseMaxStart = 3
# Tokens of the step contract and the public state (the closed lists the
# journal also checks). A value outside them never reaches a state file.
$script:HostUpdateVerdictToken = @('refused', 'drain_timeout', 'stop_failed', 'recovering', 'released', 'superseded', 'failed_restored',
    'reboot_required', 'updated_not_started', 'updated_with_remarks', 'updated')
$script:HostUpdateActionToken = @('end_one_shot', 'release_diagnostic_hold', 'provision_elevation', 'retry_or_drain_now', 'stop_runner_by_hand',
    'repair_checkout', 'act_at_host', 'release', 'read_remarks', 'start_runner', 'reboot_host', 'none')
$script:HostUpdateReasonToken = @('lock_unqualified', 'home_unverified', 'runtime_unresolved', 'host_identity_unresolved', 'one_shot_active',
    'diagnostic_hold', 'runner_elevation_missing', 'launch_record_invalid', 'gate_busy', 'drain_timeout', 'runner_identity_unknown',
    'runner_survived', 'pull_failed', 'commit_mismatch', 'protocol_mismatch', 'request_expired', 'runner_start_failed',
    'runner_start_timeout', 'runner_exited', 'config_gate_failed', 'console_state_unknown', 'step_interrupted', 'scope_unavailable',
    'installer_unmarked', 'not_provisioned', 'not_elevated', 'runner_present', 'elevation_rule_refused', 'installer_failed', 'enable_failed',
    'clt_missing', 'session_unusable')
$script:HostUpdateRemarkToken = @('runner_console_unavailable', 'ring_held', 'checkout_pinned', 'no_git_pull', 'listener_disabled',
    'install_issues', 'host_settings_unmet', 'pwsh_upgrade_failed', 'utm_upgrade_deferred', 'brew_update_failed')
$script:HostUpdateConsoleToken = @('tmux', 'screen', 'window', 'none')
# What a refusal asks of the operator when the step did not name it.
$script:HostUpdateReasonAction = @{
    one_shot_active = 'end_one_shot'; diagnostic_hold = 'release_diagnostic_hold'; runner_elevation_missing = 'provision_elevation'
    launch_record_invalid = 'start_runner'; drain_timeout = 'retry_or_drain_now'; scope_unavailable = 'none'
    clt_missing = 'act_at_host'; session_unusable = 'act_at_host'
}
$script:HostUpdateRecoverBackoffMinutes = @(5, 10, 15)
$script:HostUpdateFirstCycleWindowMs = [long]7200000
# Two boot epochs closer than this are the same boot: the epoch is read as
# wall clock minus uptime, and a clock step moves it.
$script:HostUpdateBootSlackMs = [long]120000
$script:HostUpdateResultMaxBytes = 65536
# How long a controller waits for the listener it stopped to exit.
$script:HostUpdateListenerStopMs = [long]15000

# --- REGION: Host type
function Get-HostUpdateHostType {
    <#
    .SYNOPSIS
        This host's type, from the platform: host.windows.hyper-v,
        host.macos.utm or host.ubuntu.kvm.
    .DESCRIPTION
        The controller does not load Test.HostContract, so the platform is
        mapped here. Functions that branch on the host type take it as a
        parameter or from the controller's context, so a test can drive the
        macOS rules on any host.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'host.windows.hyper-v' }
    if ($IsMacOS) { return 'host.macos.utm' }
    return 'host.ubuntu.kvm'
}

function Get-HostUpdatePhaseBound {
    <#
    .SYNOPSIS
        The bound of every phase and activity, in seconds, for a host type.
    .OUTPUTS
        [hashtable] a copy the caller may change.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$HostType = (Get-HostUpdateHostType))
    $bound = $script:HostUpdatePhaseBoundSeconds.Clone()
    $override = $script:HostUpdatePhaseBoundOverride[$HostType]
    if ($override) { foreach ($name in $override.Keys) { $bound[$name] = $override[$name] } }
    return $bound
}

# --- REGION: Snapshot
function New-HostUpdatePrivateDirectory {
    <#
    .SYNOPSIS
        Create (or reuse) one owner-only directory below an already secured
        parent, refusing a link.
    .PARAMETER Parent
        The parent directory; it must exist.
    .PARAMETER Name
        One path segment.
    .OUTPUTS
        [string] the directory, or $null when it cannot be used.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Name -notmatch $script:HostUpdateNamePattern -or -not [System.IO.Directory]::Exists($Parent)) { return $null }
    $path = [System.IO.Path]::Combine($Parent, $Name)
    $info = [System.IO.DirectoryInfo]::new($path)
    if ($info.Exists -and $info.LinkTarget) {
        Write-Verbose "New-HostUpdatePrivateDirectory: '$path' is a link; refused."
        return $null
    }
    if ([System.IO.File]::Exists($path)) { return $null }
    if (-not $info.Exists) {
        if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return $null }
        try {
            if ($IsWindows) { $null = [System.IO.Directory]::CreateDirectory($path) }
            else { $null = [System.IO.Directory]::CreateDirectory($path, $script:HostUpdateDirectoryMode) }
        } catch {
            Write-Verbose "New-HostUpdatePrivateDirectory: '$path' not created: $($_.Exception.Message)"
            return $null
        }
    }
    return $path
}

function Get-HostUpdateSnapshotFile {
    <#
    .SYNOPSIS
        The relative paths of the snapshot file set of a tree, ordinal
        sorted, forward slashes.
    .DESCRIPTION
        Links are not followed: a linked file or folder is not part of the
        set. Test files and the suite baseline stay out; they are not code
        a controller runs.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter(Mandatory)][string]$SourceRoot)
    $options = [System.IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
    $options.IgnoreInaccessible = $false
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($folder in $script:HostUpdateSnapshotFolder) {
        $path = [System.IO.Path]::Combine($SourceRoot, $folder)
        if (-not [System.IO.Directory]::Exists($path)) { continue }
        foreach ($file in [System.IO.Directory]::EnumerateFiles($path, '*', $options)) {
            $relative = [System.IO.Path]::GetRelativePath($SourceRoot, $file).Replace('\', '/')
            if ($folder -eq 'test/modules') {
                $leaf = [System.IO.Path]::GetFileName($relative)
                if ($leaf.EndsWith('.Tests.ps1', [StringComparison]::Ordinal) -or $leaf.EndsWith('.test.js', [StringComparison]::Ordinal) -or
                    $leaf -ceq 'suite-baseline.json') { continue }
            }
            $files.Add($relative)
        }
    }
    foreach ($single in $script:HostUpdateSnapshotSingleFile) {
        $path = [System.IO.Path]::Combine($SourceRoot, $single)
        $info = [System.IO.FileInfo]::new($path)
        if ($info.Exists -and -not $info.LinkTarget) { $files.Add($single) }
    }
    $array = $files.ToArray()
    [Array]::Sort($array, [StringComparer]::Ordinal)
    return , [string[]]$array
}

function Get-HostUpdateSnapshotManifest {
    <#
    .SYNOPSIS
        The snapshot file set of a tree and its hash.
    .DESCRIPTION
        SHA-256 over the UTF-8 lines "<relative path><TAB><SHA-256 of the
        file bytes><LF>" in ordinal order; the snapshot folder is named by
        the first 16 hex digits. The same tree always gets the same name,
        and any byte change, added or removed file gets another.
    .PARAMETER SourceRoot
        A checkout or a snapshot folder.
    .OUTPUTS
        [pscustomobject] @{ Hash; Hash16; Files }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$SourceRoot)
    $files = Get-HostUpdateSnapshotFile -SourceRoot $SourceRoot
    $text = [System.Text.StringBuilder]::new()
    foreach ($relative in $files) {
        $stream = [System.IO.File]::OpenRead([System.IO.Path]::Combine($SourceRoot, $relative))
        try { $digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
        finally { $stream.Dispose() }
        $null = $text.Append($relative).Append("`t").Append($digest).Append("`n")
    }
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text.ToString()))).ToLowerInvariant()
    return [pscustomobject]@{ Hash = $hash; Hash16 = $hash.Substring(0, 16); Files = $files }
}

function Test-HostUpdateSnapshotParse {
    <#
    .SYNOPSIS
        Whether every PowerShell file of a tree's snapshot set parses.
    .OUTPUTS
        [pscustomobject] @{ Ok; File; Error }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$SourceRoot)
    foreach ($relative in (Get-HostUpdateSnapshotFile -SourceRoot $SourceRoot)) {
        if (-not ($relative.EndsWith('.ps1', [StringComparison]::Ordinal) -or $relative.EndsWith('.psm1', [StringComparison]::Ordinal))) { continue }
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile([System.IO.Path]::Combine($SourceRoot, $relative), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { return [pscustomobject]@{ Ok = $false; File = $relative; Error = [string]$errors[0].Message } }
    }
    return [pscustomobject]@{ Ok = $true; File = $null; Error = $null }
}

function Get-HostUpdateRejected {
    <#
    .SYNOPSIS
        The snapshot hashes the shim gave up on.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter(Mandatory)][string]$ControllerRoot)
    $path = [System.IO.Path]::Combine($ControllerRoot, 'rejected')
    $hashes = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.File]::Exists($path)) { return , [string[]]@() }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $value = $line.Trim()
            if ($value -cmatch $script:HostUpdateHashPattern -and -not $hashes.Contains($value)) { $hashes.Add($value) }
        }
    } catch {
        Write-Verbose "Get-HostUpdateRejected: '$path' unreadable: $($_.Exception.Message)"
    }
    return , [string[]]$hashes.ToArray()
}

function Remove-HostUpdateTreeQuietly {
    <#
    .SYNOPSIS
        Remove a directory tree, or only the link when it is one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return $false }
    try {
        $info = [System.IO.DirectoryInfo]::new($Path)
        if (-not $info.Exists) { return $true }
        if ($info.LinkTarget) { [System.IO.Directory]::Delete($Path, $false) } else { [System.IO.Directory]::Delete($Path, $true) }
        return $true
    } catch {
        Write-Verbose "Remove-HostUpdateTreeQuietly: '$Path' not removed: $($_.Exception.Message)"
        return $false
    }
}

function New-HostUpdateSnapshot {
    <#
    .SYNOPSIS
        Stage the snapshot file set of a checkout as versions/<hash16>/.
    .DESCRIPTION
        The set is copied to versions/<hash16>.tmp-<pid>/, hashed and parsed
        there, and renamed into place, so a half-copied snapshot never has
        its final name and a checkout that moves during the copy names the
        snapshot by what was actually copied. A hash listed in rejected is
        not staged; a set that does not parse is not staged either.
    .PARAMETER SourceRoot
        The checkout.
    .PARAMETER ControllerRoot
        The controller root.
    .OUTPUTS
        [pscustomobject] @{ Created; Hash16; Reason exists|staged|
        parse-failed|rejected|io-error; Detail }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ControllerRoot
    )
    $answer = { param([bool]$Created, $Hash16, [string]$Reason, $Detail) [pscustomobject]@{ Created = $Created; Hash16 = $Hash16; Reason = $Reason; Detail = $Detail } }
    if (-not $PSCmdlet.ShouldProcess($ControllerRoot, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return (& $answer $false $null 'io-error' 'preview') }
    $versions = New-HostUpdatePrivateDirectory -Parent $ControllerRoot -Name 'versions' -Confirm:$false
    if (-not $versions) { return (& $answer $false $null 'io-error' 'versions-unavailable') }
    $temp = [System.IO.Path]::Combine($versions, "staging.tmp-$PID")
    $null = Remove-HostUpdateTreeQuietly -Path $temp -Confirm:$false
    if (-not (New-HostUpdatePrivateDirectory -Parent $versions -Name "staging.tmp-$PID" -Confirm:$false)) { return (& $answer $false $null 'io-error' 'staging-unavailable') }
    try {
        $files = Get-HostUpdateSnapshotFile -SourceRoot $SourceRoot
        foreach ($relative in $files) {
            $target = [System.IO.Path]::Combine($temp, $relative)
            $directory = [System.IO.Path]::GetDirectoryName($target)
            if ($IsWindows) { $null = [System.IO.Directory]::CreateDirectory($directory) }
            else { $null = [System.IO.Directory]::CreateDirectory($directory, $script:HostUpdateDirectoryMode) }
            [System.IO.File]::Copy([System.IO.Path]::Combine($SourceRoot, $relative), $target, $true)
        }
        $manifest = Get-HostUpdateSnapshotManifest -SourceRoot $temp
    } catch {
        $null = Remove-HostUpdateTreeQuietly -Path $temp -Confirm:$false
        return (& $answer $false $null 'io-error' $_.Exception.Message)
    }
    $hash16 = $manifest.Hash16
    if ((Get-HostUpdateRejected -ControllerRoot $ControllerRoot) -ccontains $hash16) {
        $null = Remove-HostUpdateTreeQuietly -Path $temp -Confirm:$false
        return (& $answer $false $hash16 'rejected' $null)
    }
    $final = [System.IO.Path]::Combine($versions, $hash16)
    if ([System.IO.Directory]::Exists($final)) {
        $null = Remove-HostUpdateTreeQuietly -Path $temp -Confirm:$false
        return (& $answer $false $hash16 'exists' $null)
    }
    $parse = Test-HostUpdateSnapshotParse -SourceRoot $temp
    if (-not $parse.Ok) {
        $null = Remove-HostUpdateTreeQuietly -Path $temp -Confirm:$false
        return (& $answer $false $hash16 'parse-failed' $parse.File)
    }
    try {
        [System.IO.Directory]::Move($temp, $final)
    } catch {
        $null = Remove-HostUpdateTreeQuietly -Path $temp -Confirm:$false
        if ([System.IO.Directory]::Exists($final)) { return (& $answer $false $hash16 'exists' $null) }
        return (& $answer $false $hash16 'io-error' $_.Exception.Message)
    }
    return (& $answer $true $hash16 'staged' $null)
}

function Read-HostUpdateControllerCurrent {
    <#
    .SYNOPSIS
        The shim's current file: the snapshot to start, the previous one and
        the checkout.
    .OUTPUTS
        [pscustomobject] @{ Found; Current; Previous; Checkout }; a value
        that is not a snapshot hash reads as empty.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$ControllerRoot)
    $out = [ordered]@{ Found = $false; Current = ''; Previous = ''; Checkout = '' }
    $path = [System.IO.Path]::Combine($ControllerRoot, 'current')
    if (-not [System.IO.File]::Exists($path)) { return [pscustomobject]$out }
    try { $lines = [System.IO.File]::ReadAllLines($path) } catch {
        Write-Verbose "Read-HostUpdateControllerCurrent: '$path' unreadable: $($_.Exception.Message)"
        return [pscustomobject]$out
    }
    $out.Found = $true
    foreach ($line in $lines) {
        if ($line.StartsWith('current=', [StringComparison]::Ordinal)) { $out.Current = $line.Substring(8) }
        elseif ($line.StartsWith('previous=', [StringComparison]::Ordinal)) { $out.Previous = $line.Substring(9) }
        elseif ($line.StartsWith('checkout=', [StringComparison]::Ordinal)) { $out.Checkout = $line.Substring(9) }
    }
    if ($out.Current -notmatch $script:HostUpdateHashPattern) { $out.Current = '' }
    if ($out.Previous -notmatch $script:HostUpdateHashPattern) { $out.Previous = '' }
    return [pscustomobject]$out
}

function Write-HostUpdateControllerCurrent {
    <#
    .SYNOPSIS
        Write the shim's current file through a temporary file and a rename.
    .PARAMETER ControllerRoot
        The controller root.
    .PARAMETER Current
        The snapshot to start, or empty.
    .PARAMETER Previous
        The snapshot to return to, or empty.
    .PARAMETER Checkout
        The absolute checkout path.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ControllerRoot,
        [AllowEmptyString()][string]$Current,
        [AllowEmptyString()][string]$Previous,
        [Parameter(Mandatory)][string]$Checkout
    )
    foreach ($value in @($Current, $Previous)) { if ($value -and $value -notmatch $script:HostUpdateHashPattern) { return $false } }
    if ($Checkout -match "[`r`n]" -or -not [System.IO.Path]::IsPathRooted($Checkout)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($ControllerRoot, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return $false }
    $path = [System.IO.Path]::Combine($ControllerRoot, 'current')
    $temp = "$path.tmp-$PID"
    try {
        [System.IO.File]::WriteAllText($temp, "current=$Current`nprevious=$Previous`ncheckout=$Checkout`n", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $path, $true)
        return $true
    } catch {
        Write-Verbose "Write-HostUpdateControllerCurrent: '$path' not written: $($_.Exception.Message)"
        try { [System.IO.File]::Delete($temp) } catch { Write-Verbose "Write-HostUpdateControllerCurrent: '$temp' left: $($_.Exception.Message)" }
        return $false
    }
}

function Remove-HostUpdateStaleSnapshot {
    <#
    .SYNOPSIS
        Remove every snapshot except the ones to keep, and staging folders
        of processes that are gone.
    .PARAMETER ControllerRoot
        The controller root.
    .PARAMETER Keep
        Hashes to keep: current and previous.
    .OUTPUTS
        [string[]] the names removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][string]$ControllerRoot,
        [AllowEmptyCollection()][string[]]$Keep = @()
    )
    $removed = [System.Collections.Generic.List[string]]::new()
    $versions = [System.IO.Path]::Combine($ControllerRoot, 'versions')
    if (-not [System.IO.Directory]::Exists($versions)) { return , [string[]]@() }
    foreach ($directory in [System.IO.Directory]::GetDirectories($versions)) {
        $name = [System.IO.Path]::GetFileName($directory)
        $remove = $false
        if ($name -cmatch $script:HostUpdateHashPattern) { $remove = $Keep -cnotcontains $name }
        elseif ($name -cmatch '\Astaging\.tmp-([0-9]{1,10})\z') {
            $owner = 0
            [void][int]::TryParse($Matches[1], [ref]$owner)
            $remove = $owner -ne $PID -and -not (Get-Process -Id $owner -ErrorAction SilentlyContinue)
        }
        if ($remove -and $PSCmdlet.ShouldProcess($directory, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) {
            if (Remove-HostUpdateTreeQuietly -Path $directory -Confirm:$false) { $removed.Add($name) }
        }
    }
    return , [string[]]$removed.ToArray()
}

# --- REGION: Registration
function Get-HostUpdateControllerShimSpec {
    <#
    .SYNOPSIS
        The shim's name under the controller root and its source in the
        checkout. Windows runs the shim under Windows PowerShell, everything
        else under sh.
    .OUTPUTS
        [hashtable] @{ Name; Source }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($IsWindows) { return @{ Name = 'shim.ps1'; Source = 'test/lab/yuruna-host-controller-shim.ps1' } }
    return @{ Name = 'shim'; Source = 'test/lab/yuruna-host-controller-shim.sh' }
}

function Get-HostUpdateControllerShimPath {
    <#
    .SYNOPSIS
        Where the shim is deployed, without creating anything; $null when
        the controller root does not exist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-HostUpdateControllerRoot -NoCreate
    if (-not $root) { return $null }
    return [System.IO.Path]::Combine($root, (Get-HostUpdateControllerShimSpec).Name)
}

function Test-HostUpdateControllerDeployment {
    <#
    .SYNOPSIS
        Whether the deployed controller is the one this checkout would
        deploy, changing nothing.
    .DESCRIPTION
        Enable-TestAutomation -NoOperatorPrompt runs inside a host update, so
        it verifies instead of registering: a registration would restart
        the controller that runs the update. The shim's bytes are compared
        with the checkout's, and the registered definition (the unit file,
        or the task definition the registration kept) with the one this
        checkout renders. The snapshot is not compared: the controller
        stages the checkout's own when its protocol number changes. macOS
        registers nothing (a runner start starts the shim), so there the
        shim is compared and current must name a snapshot that exists.
    .PARAMETER RepoRoot
        The checkout.
    .PARAMETER Definition
        The definition this checkout renders.
    .PARAMETER InstalledDefinition
        The registered definition's text; $null when none is registered.
    .PARAMETER NoDefinition
        No job is registered (macOS): check current instead of a definition.
    .OUTPUTS
        [string] ready, shim-missing, shim-differs, definition-missing,
        definition-differs or current-missing.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Definition')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory, ParameterSetName = 'Definition')][string]$Definition,
        [Parameter(ParameterSetName = 'Definition')][AllowNull()][string]$InstalledDefinition,
        [Parameter(Mandatory, ParameterSetName = 'NoDefinition')][switch]$NoDefinition
    )
    $deployed = Get-HostUpdateControllerShimPath
    $source = [System.IO.Path]::Combine($RepoRoot, (Get-HostUpdateControllerShimSpec).Source)
    try {
        if (-not $deployed -or -not [System.IO.File]::Exists($deployed) -or -not [System.IO.File]::Exists($source)) { return 'shim-missing' }
        $a = [System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($deployed))
        $b = [System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($source))
        if ([Convert]::ToHexString($a) -cne [Convert]::ToHexString($b)) { return 'shim-differs' }
    } catch {
        Write-Verbose "Test-HostUpdateControllerDeployment: shim unreadable: $($_.Exception.Message)"
        return 'shim-missing'
    }
    if ($NoDefinition) {
        $root = [System.IO.Path]::GetDirectoryName($deployed)
        $current = Read-HostUpdateControllerCurrent -ControllerRoot $root
        if (-not $current.Current -or -not [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, 'versions', $current.Current))) { return 'current-missing' }
        return 'ready'
    }
    if ([string]::IsNullOrEmpty($InstalledDefinition)) { return 'definition-missing' }
    if ($InstalledDefinition -cne $Definition) { return 'definition-differs' }
    return 'ready'
}

function Install-HostUpdateControllerFile {
    <#
    .SYNOPSIS
        Deploy the shim and the checkout's snapshot under the controller
        root, and point current at that snapshot. On Windows the shim is
        yuruna-host-controller-shim.ps1, deployed as shim.ps1.
    .DESCRIPTION
        The shim is written only when its bytes differ, owner-only. The
        checkout's snapshot is staged when missing and current names it,
        with the snapshot it replaces as previous. A first deployment has
        no previous, so a first snapshot the shim rejects is never started
        again. Every other snapshot is removed.
    .PARAMETER RepoRoot
        The checkout.
    .OUTPUTS
        [pscustomobject] @{ ShimChanged; Snapshot; CurrentWritten; Shim;
        Reason installed|unchanged|preview|root-unavailable|shim-missing|
        shim-io-error|parse-failed|rejected|io-error|current-io-error }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $result = [ordered]@{ ShimChanged = $false; Snapshot = $null; CurrentWritten = $false; Shim = $null; Reason = 'unchanged' }
    $done = { param([string]$Reason) $result.Reason = $Reason; [pscustomobject]$result }
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return (& $done 'preview') }
    $root = Get-HostUpdateControllerRoot
    if (-not $root) { return (& $done 'root-unavailable') }
    $shim = Get-HostUpdateControllerShimSpec
    $result.Shim = [System.IO.Path]::Combine($root, $shim.Name)
    $source = [System.IO.Path]::Combine($RepoRoot, $shim.Source)
    if (-not [System.IO.File]::Exists($source)) { return (& $done 'shim-missing') }
    $temp = "$($result.Shim).tmp-$PID"
    try {
        $bytes = [System.IO.File]::ReadAllBytes($source)
        $same = $false
        if ([System.IO.File]::Exists($result.Shim)) {
            $deployed = [System.IO.File]::ReadAllBytes($result.Shim)
            $same = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($deployed)) -ceq [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
        }
        if (-not $same) {
            [System.IO.File]::WriteAllBytes($temp, $bytes)
            if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($temp, $script:HostUpdateDirectoryMode) }
            [System.IO.File]::Move($temp, $result.Shim, $true)
            $result.ShimChanged = $true
        }
    } catch {
        Write-Verbose "Install-HostUpdateControllerFile: '$($result.Shim)' not written: $($_.Exception.Message)"
        try { [System.IO.File]::Delete($temp) } catch { Write-Verbose "Install-HostUpdateControllerFile: '$temp' left: $($_.Exception.Message)" }
        return (& $done 'shim-io-error')
    }
    $staged = New-HostUpdateSnapshot -SourceRoot $RepoRoot -ControllerRoot $root -Confirm:$false
    if ($staged.Reason -notin @('staged', 'exists')) { return (& $done ([string]$staged.Reason)) }
    $result.Snapshot = $staged.Hash16
    $checkout = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($RepoRoot))
    $current = Read-HostUpdateControllerCurrent -ControllerRoot $root
    $previous = if ($current.Current -cne $staged.Hash16) { $current.Current } else { $current.Previous }
    if ($previous -ceq $staged.Hash16) { $previous = '' }
    if ($current.Current -cne $staged.Hash16 -or $current.Checkout -cne $checkout) {
        if (-not (Write-HostUpdateControllerCurrent -ControllerRoot $root -Current $staged.Hash16 -Previous $previous -Checkout $checkout -Confirm:$false)) {
            return (& $done 'current-io-error')
        }
        $result.CurrentWritten = $true
    }
    $null = Remove-HostUpdateStaleSnapshot -ControllerRoot $root -Keep @($staged.Hash16, $previous | Where-Object { $_ }) -Confirm:$false
    return (& $done $(if ($result.ShimChanged -or $result.CurrentWritten) { 'installed' } else { 'unchanged' }))
}

function Get-HostUpdateControllerUnitText {
    <#
    .SYNOPSIS
        The host controller's systemd unit for this account and shim.
    .DESCRIPTION
        The shim path is written as one quoted ExecStart argument, with the
        characters systemd reads specially escaped, so a home folder whose
        path holds a space, a quote, a percent or a dollar sign still names
        the shim.
    .PARAMETER TemplatePath
        host/ubuntu.kvm/host-controller/yuruna-host-controller.service.
    .PARAMETER Account
        The test account the unit runs as.
    .PARAMETER ShimPath
        The absolute path of the deployed shim.
    .OUTPUTS
        [string] the unit text, LF line ends, one final newline.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z', Options = 'None')][string]$Account,
        [Parameter(Mandatory)][ValidatePattern('\A/[^\x00-\x1f\x7f]*\z', Options = 'None')][string]$ShimPath
    )
    $quoted = '"' + $ShimPath.Replace('\', '\\').Replace('"', '\"').Replace('%', '%%').Replace('$', '$$') + '"'
    $text = [System.IO.File]::ReadAllText($TemplatePath).Replace("`r`n", "`n").Replace('@ACCOUNT@', $Account).Replace('@SHIM@', $quoted)
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) { $text += "`n" }
    return $text
}

function Get-HostUpdateControllerTaskXml {
    <#
    .SYNOPSIS
        The host controller's scheduled task for this account and shim.
    .DESCRIPTION
        Filled from host/windows.hyper-v/host-controller/
        yuruna-host-controller.task.xml with every value XML-escaped. The
        task starts Windows PowerShell on the shim, hidden, at the logon of
        the test account, with the highest privileges that account has, at
        normal priority, with no time limit, one instance, and a restart
        every minute after a failure. The leading comment of the template
        is dropped: Task Scheduler stores the definition without it.
    .PARAMETER TemplatePath
        The task template.
    .PARAMETER AccountSid
        The security identifier of the test account.
    .PARAMETER PowerShellPath
        Windows PowerShell (powershell.exe).
    .PARAMETER ShimPath
        The deployed shim.ps1.
    .OUTPUTS
        [string] the task definition.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][ValidatePattern('\AS-1-[0-9]+(-[0-9]+){1,14}\z', Options = 'None')][string]$AccountSid,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z]:\\[^\x00-\x1f"]*\.exe\z', Options = 'None')][string]$PowerShellPath,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z]:\\[^\x00-\x1f"]*\z', Options = 'None')][string]$ShimPath
    )
    $escape = { param([string]$Value) [System.Security.SecurityElement]::Escape($Value) }
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ShimPath
    $text = [System.IO.File]::ReadAllText($TemplatePath).Replace("`r`n", "`n")
    $start = $text.IndexOf('<Task ', [StringComparison]::Ordinal)
    if ($start -lt 0) { throw [System.IO.InvalidDataException]::new("$TemplatePath holds no <Task> element") }
    $text = $text.Substring($start)
    $text = $text.Replace('@ACCOUNT@', (& $escape $AccountSid)).Replace('@POWERSHELL@', (& $escape $PowerShellPath))
    $text = $text.Replace('@ARGUMENTS@', (& $escape $arguments)).Replace('@ROOT@', (& $escape $ShimPath.Substring(0, $ShimPath.LastIndexOf('\'))))
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) { $text += "`n" }
    return $text
}

function Get-HostUpdateControllerTaskService {
    <#
    .SYNOPSIS
        The Task Scheduler and lock calls the task registration and removal
        make, as replaceable script blocks.
    .OUTPUTS
        [hashtable] Get, Register, Start, Stop, Unregister, LockState, Sleep,
        Queue.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Service = @{})
    $default = @{
        Get        = { param([string]$Name) Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue }
        Register   = { param([string]$Name, [string]$Xml) $null = Register-ScheduledTask -TaskName $Name -Xml $Xml -Force -ErrorAction Stop }
        Start      = { param([string]$Name) Start-ScheduledTask -TaskName $Name -ErrorAction Stop }
        Stop       = { param([string]$Name) Stop-ScheduledTask -TaskName $Name -ErrorAction Stop }
        Unregister = { param([string]$Name) Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop }
        LockState  = { Get-HostUpdateControllerLockState }
        Sleep      = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
        Queue      = { Get-HostUpdateQueue }
    }
    foreach ($key in @($Service.Keys)) { $default[$key] = $Service[$key] }
    return $default
}

function Wait-HostUpdateControllerLock {
    # Polls the controller lock every 500 ms until it reads one of the wanted
    # states or the attempts run out; returns the last state read.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Service, [Parameter(Mandatory)][string[]]$Until, [int]$Attempts = 30)
    $state = [string](& $Service.LockState)
    for ($i = 0; $i -lt $Attempts -and $state -notin $Until; $i++) {
        & $Service.Sleep 500
        $state = [string](& $Service.LockState)
    }
    return $state
}

function Register-HostUpdateControllerTask {
    <#
    .SYNOPSIS
        Register the host controller's scheduled task when its definition
        changed, start it, and wait for a controller to take its lock.
    .DESCRIPTION
        The definition is registered again only when it differs from the one
        last registered, which is kept at DefinitionPath, or when no task
        exists. A running task is restarted when its definition or the shim
        changed: the stop file makes the shim end its controller alone and
        exit, so ending the task ends nothing the controller started, and
        the stop file is removed before the start. A task that is not
        running is started. The lock, not the task state, says that a
        controller started.
    .PARAMETER TaskName
        The task.
    .PARAMETER Definition
        The rendered definition.
    .PARAMETER DefinitionPath
        Where the last registered definition is kept.
    .PARAMETER StopPath
        The shim's stop file.
    .PARAMETER ShimChanged
        The shim was written by this run.
    .PARAMETER Service
        Replacements for Get-HostUpdateControllerTaskService.
    .OUTPUTS
        [pscustomobject] @{ Outcome running|not-running|failed; Change
        registered|replaced|none; Detail }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Definition,
        [Parameter(Mandatory)][string]$DefinitionPath,
        [Parameter(Mandatory)][string]$StopPath,
        [bool]$ShimChanged,
        [hashtable]$Service = @{}
    )
    $calls = Get-HostUpdateControllerTaskService -Service $Service
    $result = [ordered]@{ Outcome = 'failed'; Change = 'none'; Detail = '' }
    if (-not $PSCmdlet.ShouldProcess($TaskName, (Format-YurunaOperatorMessage -Key 'host.host_controller_task_action'))) {
        $result.Outcome = 'not-running'; $result.Detail = 'preview'
        return [pscustomobject]$result
    }
    try {
        $registered = & $calls.Get $TaskName
        $recorded = if ([System.IO.File]::Exists($DefinitionPath)) { [System.IO.File]::ReadAllText($DefinitionPath) } else { $null }
        $changed = (-not $registered) -or ($recorded -cne $Definition)
        if ($changed) {
            & $calls.Register $TaskName $Definition
            [System.IO.File]::WriteAllText($DefinitionPath, $Definition)
            $result.Change = if ($registered) { 'replaced' } else { 'registered' }
        }
        $running = [string]((& $calls.Get $TaskName).State) -eq 'Running'
        if ($running -and ($changed -or $ShimChanged)) {
            [System.IO.File]::WriteAllText($StopPath, '')
            $null = Wait-HostUpdateControllerLock -Service $calls -Until @('free', 'absent') -Attempts 60
            & $calls.Stop $TaskName
            $running = $false
        }
        if ([System.IO.File]::Exists($StopPath)) { [System.IO.File]::Delete($StopPath) }
        if (-not $running) { & $calls.Start $TaskName }
    } catch {
        $result.Detail = [string]$_.Exception.Message
        return [pscustomobject]$result
    }
    $result.Outcome = if ((Wait-HostUpdateControllerLock -Service $calls -Until @('held')) -eq 'held') { 'running' } else { 'not-running' }
    return [pscustomobject]$result
}

function Unregister-HostUpdateControllerTask {
    <#
    .SYNOPSIS
        Stop and remove the host controller's scheduled task, unless the
        controller claimed a host update while it was being stopped.
    .DESCRIPTION
        The stop file makes the shim end its controller alone and exit; the
        task is stopped once nobody holds the controller lock, or after 30
        seconds. A host update claimed before the stop is continued by
        starting the task again, and nothing is removed. A journal that
        cannot be read once the task stopped can hide such an update, so it
        is handled the same way.
    .PARAMETER TaskName
        The task.
    .PARAMETER StopPath
        The shim's stop file, or empty when the controller root is gone.
    .PARAMETER Service
        Replacements for Get-HostUpdateControllerTaskService.
    .OUTPUTS
        [pscustomobject] @{ Outcome absent|removed|claimed|claimed-not-restarted|
        unknown|unknown-not-restarted|failed|preview; RequestId; Status (the
        journal read status once the task stopped, or empty); Detail }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [AllowEmptyString()][string]$StopPath = '',
        [hashtable]$Service = @{}
    )
    $calls = Get-HostUpdateControllerTaskService -Service $Service
    $result = [ordered]@{ Outcome = 'absent'; RequestId = ''; Status = ''; Detail = '' }
    if (-not (& $calls.Get $TaskName)) { return [pscustomobject]$result }
    if (-not $PSCmdlet.ShouldProcess($TaskName, (Format-YurunaOperatorMessage -Key 'host.operator_f61cceb0afee5ae4'))) {
        $result.Outcome = 'preview'
        return [pscustomobject]$result
    }
    try {
        if ($StopPath) { [System.IO.File]::WriteAllText($StopPath, '') }
        $null = Wait-HostUpdateControllerLock -Service $calls -Until @('free', 'absent') -Attempts 60
        & $calls.Stop $TaskName
    } catch {
        $result.Outcome = 'failed'; $result.Detail = "Stop-ScheduledTask: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    $queue = & $calls.Queue
    $result.Status = [string]$queue.Status
    $unknown = $result.Status -notin @('ok', 'absent', 'recovered-previous')
    if ($unknown -or $queue.Claimed) {
        $kind = if ($unknown) { 'unknown' } else { 'claimed' }
        if (-not $unknown) { $result.RequestId = [string]$queue.Claimed['requestId'] }
        try {
            if ($StopPath -and [System.IO.File]::Exists($StopPath)) { [System.IO.File]::Delete($StopPath) }
            & $calls.Start $TaskName
            $result.Outcome = $kind
        } catch {
            $result.Outcome = "$kind-not-restarted"; $result.Detail = "Start-ScheduledTask: $($_.Exception.Message)"
        }
        return [pscustomobject]$result
    }
    try {
        & $calls.Unregister $TaskName
        $result.Outcome = 'removed'
    } catch {
        $result.Outcome = 'failed'; $result.Detail = "Unregister-ScheduledTask: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}

# --- REGION: Controller session (macOS)
# macOS registers no job: an ordinary runner start from the desktop session
# starts the shim in a detached multiplexer session of its own, whose server is
# no descendant of the runner, so a stop of the runner never reaches it. tmux
# gets a server and socket of its own (-L) and neither multiplexer reads the
# operator's configuration. screen, which macOS ships, accepts two sessions of
# one name; the shim's rule for a first exit 76 removes the extra one.
$script:HostUpdateControllerSessionName = 'yuruna-controller'

function Find-HostUpdateMultiplexerTool {
    <#
    .SYNOPSIS
        The path of tmux or screen, or $null.
    .DESCRIPTION
        A process that never ran brew shellenv has no Homebrew folder on
        PATH, so tmux is also looked for where Homebrew installs it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('tmux', 'screen')][string]$Name)
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    $fallback = if ($Name -eq 'tmux') { @('/opt/homebrew/bin/tmux', '/usr/local/bin/tmux') } else { @('/usr/bin/screen') }
    foreach ($path in $fallback) { if ([System.IO.File]::Exists($path)) { return $path } }
    return $null
}

function Get-HostUpdateControllerSessionService {
    <#
    .SYNOPSIS
        The calls the controller session's start and end make, as
        replaceable script blocks.
    .OUTPUTS
        [hashtable] LockState, Sleep, SessionKind ('Aqua', 'Remote' or
        'Unknown'), SshSession, FindTool (the path of tmux or screen, or
        $null), ResolveMultiplexer (@{ Kind; Path } or $null, tmux first),
        Native (a bounded call: FilePath, ArgumentList, TimeoutSeconds,
        RemoveEnvironmentVariable).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Service = @{})
    $default = @{
        LockState          = { Get-HostUpdateControllerLockState }
        Sleep              = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
        SessionKind        = {
            if (-not (Get-Command -Name Get-MacSessionKind -ErrorAction SilentlyContinue)) { return 'Unknown' }
            Get-MacSessionKind -TimeoutSeconds 5
        }
        SshSession         = { -not [string]::IsNullOrEmpty("$($env:SSH_CONNECTION)$($env:SSH_TTY)") }
        FindTool           = { param([string]$Name) Find-HostUpdateMultiplexerTool -Name $Name }
        ResolveMultiplexer = $null
        Native             = {
            param($FilePath, $ArgumentList, $TimeoutSeconds, $RemoveEnvironmentVariable)
            Invoke-BoundedNativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -RemoveEnvironmentVariable $RemoveEnvironmentVariable
        }
    }
    foreach ($key in @($Service.Keys)) { $default[$key] = $Service[$key] }
    if (-not $default.ResolveMultiplexer) {
        $find = $default.FindTool
        $default.ResolveMultiplexer = {
            foreach ($name in @('tmux', 'screen')) {
                $path = & $find $name
                if ($path) { return @{ Kind = $name; Path = [string]$path } }
            }
            return $null
        }.GetNewClosure()
    }
    return $default
}

function Get-HostUpdateControllerAttachCommand {
    <#
    .SYNOPSIS
        How an operator reads the controller's session.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('tmux', 'screen')][string]$Kind)
    if ($Kind -eq 'tmux') { return "tmux -L $($script:HostUpdateControllerSessionName) attach -t $($script:HostUpdateControllerSessionName)" }
    return "screen -r $($script:HostUpdateControllerSessionName)"
}

function Get-HostUpdateScreenSessionId {
    <#
    .SYNOPSIS
        The live screen sessions named yuruna-controller, as <pid>.<name>,
        from screen -ls output; a Dead entry is not live.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ("$Text" -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s+([0-9]+\.' + [regex]::Escape($script:HostUpdateControllerSessionName) + ')\s')
        if ($match.Success -and $line -notmatch '\(Dead') { $ids.Add($match.Groups[1].Value) }
    }
    return , [string[]]$ids.ToArray()
}

function Test-HostUpdateControllerSessionExist {
    <#
    .SYNOPSIS
        Whether the yuruna-controller session exists: yes, no or unknown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Calls, [Parameter(Mandatory)][hashtable]$Multiplexer)
    $name = $script:HostUpdateControllerSessionName
    if ($Multiplexer.Kind -eq 'tmux') {
        $r = & $Calls.Native $Multiplexer.Path @('-L', $name, '-f', '/dev/null', 'has-session', '-t', "=$name") 5 @()
        if (-not $r -or $r.TimedOut -or -not $r.Started) { return 'unknown' }
        # 1: no such session, or no server on the socket at all.
        switch ([int]$r.ExitCode) { 0 { return 'yes' } 1 { return 'no' } default { return 'unknown' } }
    }
    $r = & $Calls.Native $Multiplexer.Path @('-ls') 5 @()
    if (-not $r -or $r.TimedOut -or -not $r.Started) { return 'unknown' }
    # screen -ls exits non-zero with sessions and without; its listing decides.
    if ((Get-HostUpdateScreenSessionId -Text ([string]$r.StdOut)).Count -gt 0) { return 'yes' }
    return 'no'
}

function Start-HostUpdateControllerSession {
    <#
    .SYNOPSIS
        On a macOS runner start: start the host controller's shim in its own
        multiplexer session when no controller holds the lock.
    .DESCRIPTION
        The lock is the only test, so this can run at every ordinary start.
        In order: nothing deployed; not the desktop session (an SSH login or
        a background session, where a controller could never start a working
        runner and would hold the lock against a later, good start); a
        controller holds the lock (the usual case); a lock that cannot be
        read (a second controller is never risked); no multiplexer; the
        session already exists (its shim is between two runs of the
        controller). Otherwise the session is created, bounded at 5 s, with
        the runner's environment less the multiplexer's own variables and
        every YURUNA_* variable but the documented operator overrides
        (YURUNA_SKIP_*), so the controller resolves its runtime directory as
        on the other host types, while an override that lets this desktop
        session run a runner holds for the controller, its session probe and
        the runner it starts too; then the lock is watched for 10 s. A
        create that fails while the session exists is a second start that
        won the same race. Nothing here ends the runner start.
    .PARAMETER Service
        Replacements for Get-HostUpdateControllerSessionService.
    .OUTPUTS
        [pscustomobject] @{ Result not_deployed|not_desktop_session|running|
        lock_unreadable|no_multiplexer|session_exists|session_unknown|started|
        not_held|start_failed; Line; LockState; Multiplexer }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The ordinary runner start''s own step: it starts the controller only when none runs, and its result line is the report.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([hashtable]$Service = @{})
    $calls = Get-HostUpdateControllerSessionService -Service $Service
    $name = $script:HostUpdateControllerSessionName
    $state = [ordered]@{ Result = $null; Line = $null; LockState = $null; Multiplexer = $null }
    $done = {
        param([string]$Result, [hashtable]$Arguments = @{})
        $state.Result = $Result
        $state.Line = Format-YurunaOperatorMessage -Key "runner.host_controller_start_$Result" -Arguments $Arguments
        [pscustomobject]$state
    }
    $shim = Get-HostUpdateControllerShimPath
    if (-not $shim -or -not [System.IO.File]::Exists($shim) -or -not [System.IO.File]::Exists([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($shim), 'current'))) {
        return (& $done 'not_deployed')
    }
    if ([bool](& $calls.SshSession) -or [string](& $calls.SessionKind) -cne 'Aqua') { return (& $done 'not_desktop_session') }
    $state.LockState = [string](& $calls.LockState)
    if ($state.LockState -ceq 'held') { return (& $done 'running') }
    if ($state.LockState -cnotin @('free', 'absent')) { return (& $done 'lock_unreadable') }
    $multiplexer = & $calls.ResolveMultiplexer
    if (-not $multiplexer) { return (& $done 'no_multiplexer') }
    $state.Multiplexer = [string]$multiplexer.Kind
    $named = @{ multiplexer = $state.Multiplexer; attach = (Get-HostUpdateControllerAttachCommand -Kind $state.Multiplexer) }
    switch (Test-HostUpdateControllerSessionExist -Calls $calls -Multiplexer $multiplexer) {
        'yes' { return (& $done 'session_exists' $named) }
        'unknown' { return (& $done 'session_unknown') }
    }
    $remove = [System.Collections.Generic.List[string]]::new()
    foreach ($variable in @([Environment]::GetEnvironmentVariables().Keys)) {
        if ([string]$variable -clike 'YURUNA_*' -and [string]$variable -cnotlike 'YURUNA_SKIP_*') { $remove.Add([string]$variable) }
    }
    foreach ($variable in @('TMUX', 'TMUX_PANE', 'STY', 'WINDOW')) { $remove.Add($variable) }
    $create = if ($multiplexer.Kind -eq 'tmux') {
        & $calls.Native $multiplexer.Path @('-L', $name, '-f', '/dev/null', 'new-session', '-d', '-s', $name, '/bin/sh', $shim) 5 $remove.ToArray()
    } else {
        # The screen backend outlives the call: it must hold no pipe of it.
        & $calls.Native '/bin/sh' @('-c', 'exec "$@" </dev/null >/dev/null 2>&1', 'sh', $multiplexer.Path, '-c', '/dev/null', '-dmS', $name, '/bin/sh', $shim) 5 $remove.ToArray()
    }
    if (-not $create -or $create.TimedOut -or [int]$create.ExitCode -ne 0) {
        if ((Test-HostUpdateControllerSessionExist -Calls $calls -Multiplexer $multiplexer) -eq 'yes') { return (& $done 'session_exists' $named) }
        return (& $done 'start_failed' @{ multiplexer = $state.Multiplexer })
    }
    $state.LockState = Wait-HostUpdateControllerLock -Service $calls -Until @('held') -Attempts 20
    if ($state.LockState -ceq 'held') { return (& $done 'started' $named) }
    return (& $done 'not_held' $named)
}

function Stop-HostUpdateControllerSession {
    <#
    .SYNOPSIS
        End the host controller's multiplexer session on macOS: the tmux
        session on its own socket and every screen session of that name.
    .DESCRIPTION
        Both multiplexers are looked at, whichever started the session. The
        shim passes the hangup to its controller, which ends as if killed:
        the next controller continues from the journal.
    .PARAMETER Service
        Replacements for Get-HostUpdateControllerSessionService.
    .OUTPUTS
        [pscustomobject] @{ Ended; Reason ended|absent|failed|preview }:
        Ended is $true when no such session is left.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([hashtable]$Service = @{})
    $calls = Get-HostUpdateControllerSessionService -Service $Service
    $name = $script:HostUpdateControllerSessionName
    if (-not $PSCmdlet.ShouldProcess($name, (Format-YurunaOperatorMessage -Key 'runner.host_controller_session_action'))) {
        return [pscustomobject]@{ Ended = $false; Reason = 'preview' }
    }
    $ended = $false
    $failed = $false
    $tmux = & $calls.FindTool 'tmux'
    if ($tmux) {
        $kind = @{ Kind = 'tmux'; Path = [string]$tmux }
        $exists = Test-HostUpdateControllerSessionExist -Calls $calls -Multiplexer $kind
        if ($exists -eq 'yes') {
            $r = & $calls.Native $tmux @('-L', $name, '-f', '/dev/null', 'kill-session', '-t', "=$name") 10 @()
            if ($r -and -not $r.TimedOut -and [int]$r.ExitCode -eq 0) { $ended = $true } else { $failed = $true }
        } elseif ($exists -eq 'unknown') { $failed = $true }
    }
    $screen = & $calls.FindTool 'screen'
    if ($screen) {
        $r = & $calls.Native $screen @('-ls') 5 @()
        if (-not $r -or $r.TimedOut -or -not $r.Started) { $failed = $true }
        else {
            foreach ($id in (Get-HostUpdateScreenSessionId -Text ([string]$r.StdOut))) {
                $quit = & $calls.Native $screen @('-S', $id, '-X', 'quit') 10 @()
                if ($quit -and -not $quit.TimedOut -and [int]$quit.ExitCode -eq 0) { $ended = $true } else { $failed = $true }
            }
        }
    }
    $reason = if ($failed) { 'failed' } elseif ($ended) { 'ended' } else { 'absent' }
    return [pscustomobject]@{ Ended = -not $failed; Reason = $reason }
}

function Get-HostUpdateMacSessionReading {
    <#
    .SYNOPSIS
        Whether this process's session can start a working runner on macOS:
        no SSH login, the desktop (Aqua) session, and no blocking privacy
        grant whose silent probe reads denied.
    .DESCRIPTION
        Callable where Test.HostCondition.Mac is loaded. A grant whose state
        cannot be read (unknown) does not make the session unusable: the
        probes time out, and UTM's data reads unknown before UTM has any.
        Automation for UTM has no silent probe and is not read.
    .PARAMETER Service
        SessionKind, SshSession and GrantState (Get-MacOperatorGrantState).
    .OUTPUTS
        [hashtable] @{ SessionKind; Ssh; Grants @{ id = state }; Usable }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Service = @{})
    $calls = @{
        SessionKind = { Get-MacSessionKind -TimeoutSeconds 5 }
        SshSession  = { -not [string]::IsNullOrEmpty("$($env:SSH_CONNECTION)$($env:SSH_TTY)") }
        GrantState  = { Get-MacOperatorGrantState }
    }
    foreach ($key in @($Service.Keys)) { $calls[$key] = $Service[$key] }
    $kind = [string](& $calls.SessionKind)
    $ssh = [bool](& $calls.SshSession)
    $grants = [ordered]@{}
    $denied = $false
    foreach ($grant in @(& $calls.GrantState)) {
        if (-not $grant -or [string]$grant.State -ceq 'unprobed') { continue }
        $grants[[string]$grant.Id] = [string]$grant.State
        if ([bool]$grant.Blocking -and [string]$grant.State -ceq 'denied') { $denied = $true }
    }
    return @{ SessionKind = $kind; Ssh = $ssh; Grants = $grants; Usable = (-not $ssh -and $kind -ceq 'Aqua' -and -not $denied) }
}

function Invoke-HostUpdateMacSessionProbe {
    <#
    .SYNOPSIS
        Read the controller's session on macOS in a bounded child pwsh that
        imports from the controller's snapshot.
    .DESCRIPTION
        The macOS condition module imports the common module globally and
        with -Force, which must not happen inside the controller; and a
        grant probe that hangs must not stall it. The child prints the
        reading as one JSON line.
    .OUTPUTS
        [hashtable] the reading, or $null when the child gave none.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$SnapshotRoot, [AllowNull()][scriptblock]$Native)
    $quote = { param([string]$Path) "'" + $Path.Replace("'", "''") + "'" }
    $modules = [System.IO.Path]::Combine($SnapshotRoot, 'test', 'modules')
    $command = "`$ErrorActionPreference = 'Stop'; Import-Module $(& $quote ([System.IO.Path]::Combine($modules, 'Test.HostCondition.Mac.psm1'))) -DisableNameChecking; " +
        "Import-Module $(& $quote ([System.IO.Path]::Combine($modules, 'Test.HostUpdate.psm1'))) -DisableNameChecking; " +
        'Get-HostUpdateMacSessionReading | ConvertTo-Json -Compress -Depth 4'
    $pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $r = Invoke-HostUpdateNative -Native $Native -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command) -TimeoutSeconds 30
    if (-not $r -or $r.TimedOut -or [int]$r.ExitCode -ne 0) { return $null }
    $line = @("$($r.StdOut)" -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    if (-not $line) { return $null }
    try {
        $reading = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "Invoke-HostUpdateMacSessionProbe: reading unreadable: $($_.Exception.Message)"
        return $null
    }
    if ($reading -isnot [hashtable] -or $reading['Usable'] -isnot [bool]) { return $null }
    return $reading
}

# --- REGION: Elevation for the full scope
# See https://yuruna.link/42f909ad-002b
# KVM writes a temporary rule through the runner's passwordless manifest, and a
# transient timer removes it at the attempt's bound; the timer has one fixed
# name, so starting it again replaces one an earlier attempt left. macOS writes
# a rule with its own expiry (NOTAFTER) through a permanent sudoers entry, which
# sudo matches by command path and every argument literally: these calls name
# the absolute paths and never /private/etc or a tool found on PATH.
$script:HostUpdateSudoRulePath = '/etc/sudoers.d/yuruna-host-update'
$script:HostUpdateSudoExpiryUnit = 'yuruna-host-update-expire'
$script:HostUpdateAccessEntryPath = '/etc/sudoers.d/yuruna-host-update-access'
$script:HostUpdateHostTypes = @('host.ubuntu.kvm', 'host.windows.hyper-v', 'host.macos.utm')

function Invoke-HostUpdateNative {
    <#
    .SYNOPSIS
        One bounded native call, or the replacement a test gives.
    .PARAMETER Native
        A replacement: { param($FilePath, $ArgumentList, $TimeoutSeconds) }
        returning @{ ExitCode; TimedOut }.
    .OUTPUTS
        [hashtable] @{ ExitCode; TimedOut; StdOut; StdErr }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][scriptblock]$Native,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 2147483)][int]$TimeoutSeconds = 30
    )
    if ($Native) { return [hashtable](& $Native $FilePath $ArgumentList $TimeoutSeconds) }
    return (Invoke-BoundedNativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds)
}

function Get-HostUpdateSudoRuleText {
    <#
    .SYNOPSIS
        The temporary rule for one account: everything, without a password.
    .PARAMETER Account
        The test account.
    .PARAMETER NotAfterUtc
        The rule's own expiry (macOS): sudo stops honoring it after this UTC
        instant. The option precedes the tag, as sudoers requires.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z', Options = 'None')][string]$Account,
        [DateTimeOffset]$NotAfterUtc
    )
    if ($PSBoundParameters.ContainsKey('NotAfterUtc')) {
        $stamp = $NotAfterUtc.UtcDateTime.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
        return "$Account ALL=(ALL:ALL) NOTAFTER=${stamp}Z NOPASSWD: ALL`n"
    }
    return "$Account ALL=(ALL:ALL) NOPASSWD: ALL`n"
}

function Stop-HostUpdateElevatedUnit {
    <#
    .SYNOPSIS
        Stop transient units through the runner's passwordless systemctl and
        confirm each one gone.
    .OUTPUTS
        [bool] every unit is stopped or was never loaded.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Unit, [AllowNull()][scriptblock]$Native, [ValidateRange(1, 600)][int]$TimeoutSeconds = 120)
    $all = $true
    foreach ($name in $Unit) {
        if ($name -cnotmatch '\Ayuruna-host-update-[a-z_]+(-[0-9]{1,4})?(\.service|\.timer)?\z') { $all = $false; continue }
        if (-not $PSCmdlet.ShouldProcess($name, (Format-YurunaOperatorMessage -Key 'runner.host_update_elevation_action'))) { continue }
        $r = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', 'systemctl', 'stop', $name) -TimeoutSeconds $TimeoutSeconds
        # 5: the unit is not loaded, which is gone too.
        if (-not $r -or [int]$r.ExitCode -notin @(0, 5)) { $all = $false }
    }
    return $all
}

function Get-HostUpdateElevatedUnit {
    <#
    .SYNOPSIS
        Every loaded transient unit of an install or enable phase, whichever
        host update started it.
    .DESCRIPTION
        A unit is named by phase and attempt only, so a unit an earlier
        update left (its release kept it as debt) would otherwise run beside
        a new update's unit, or block a new unit of the same name.
    .OUTPUTS
        [string[]] unit names, or $null when systemctl could not say.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([AllowNull()][scriptblock]$Native)
    $r = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -TimeoutSeconds 30 -ArgumentList @(
        '-n', 'systemctl', 'list-units', '--all', '--plain', '--no-legend', '--no-pager', 'yuruna-host-update-install-*.service', 'yuruna-host-update-enable-*.service')
    if (-not $r -or [int]$r.ExitCode -ne 0) { return $null }
    # The comma keeps an empty list a list: unrolled, it would read as $null,
    # which means systemctl could not say.
    return , [string[]]@("$($r.StdOut)" -split "`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] } |
            Where-Object { $_ -cmatch '\Ayuruna-host-update-(install|enable)-[0-9]{1,4}\.service\z' })
}

function Remove-HostUpdateSudoRule {
    <#
    .SYNOPSIS
        Remove the temporary rule through the runner's passwordless rm, then
        stop its expiry timer once the rule is gone.
    .DESCRIPTION
        A rule rm could not remove keeps its timer: the timer is what removes
        a rule nothing else could. The next attempt replaces the timer before
        it writes a rule of its own. On macOS the call is exactly the one the
        permanent entry allows, and there is no timer: the rule's own expiry
        stands in for it.
    .OUTPUTS
        [bool] the rule is gone: rm -f exited 0.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [AllowNull()][scriptblock]$Native,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30,
        [ValidateScript({ $_ -cin $script:HostUpdateHostTypes })][string]$HostType = (Get-HostUpdateHostType)
    )
    if (-not $PSCmdlet.ShouldProcess($script:HostUpdateSudoRulePath, (Format-YurunaOperatorMessage -Key 'runner.host_update_elevation_action'))) { return $false }
    if ($HostType -ceq 'host.macos.utm') {
        $removed = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '/bin/rm', '-f', $script:HostUpdateSudoRulePath) -TimeoutSeconds $TimeoutSeconds
        return [bool]($removed -and [int]$removed.ExitCode -eq 0)
    }
    $removed = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', 'rm', '-f', $script:HostUpdateSudoRulePath) -TimeoutSeconds $TimeoutSeconds
    $gone = [bool]($removed -and [int]$removed.ExitCode -eq 0)
    if ($gone) { $null = Stop-HostUpdateElevatedUnit -Unit @("$($script:HostUpdateSudoExpiryUnit).timer") -Native $Native -TimeoutSeconds $TimeoutSeconds -Confirm:$false }
    return $gone
}

function Set-HostUpdateSudoRule {
    <#
    .SYNOPSIS
        Write the temporary rule, confirm it, and have root start the timer
        that removes it.
    .DESCRIPTION
        visudo checks the text before it reaches /etc/sudoers.d: a malformed
        drop-in breaks sudo for every command on the host, including the
        rm that would remove it. The rule is confirmed with sudo -n -k, so a
        cached credential cannot pass for it. A rule that is not confirmed,
        or whose timer cannot be started, is removed again. On macOS the rule
        carries its expiry as NOTAFTER and is written through the tee the
        permanent entry allows, under a umask that leaves it 0440, so no
        chmod and no timer follow.
    .PARAMETER Account
        The test account.
    .PARAMETER ExpirySeconds
        When the rule ends: the attempt's bound plus a margin.
    .PARAMETER WorkDirectory
        A private folder for the text visudo checks.
    .PARAMETER Native
        A replacement for the native calls.
    .PARAMETER HostType
        The host type; this host's by default.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason ok|visudo-refused|write-failed|
        not-confirmed|timer-failed|preview }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z', Options = 'None')][string]$Account,
        [Parameter(Mandatory)][ValidateRange(60, 86400)][int]$ExpirySeconds,
        [Parameter(Mandatory)][string]$WorkDirectory,
        [AllowNull()][scriptblock]$Native,
        [ValidateScript({ $_ -cin $script:HostUpdateHostTypes })][string]$HostType = (Get-HostUpdateHostType)
    )
    $answer = { param([bool]$Written, [string]$Reason) [pscustomobject]@{ Written = $Written; Reason = $Reason } }
    if (-not $PSCmdlet.ShouldProcess($script:HostUpdateSudoRulePath, (Format-YurunaOperatorMessage -Key 'runner.host_update_elevation_action'))) { return (& $answer $false 'preview') }
    $text = [System.IO.Path]::Combine($WorkDirectory, "sudo-rule.$PID")
    if ($HostType -ceq 'host.macos.utm') {
        try {
            $notAfter = [DateTimeOffset]::UtcNow.AddSeconds($ExpirySeconds)
            [System.IO.File]::WriteAllText($text, (Get-HostUpdateSudoRuleText -Account $Account -NotAfterUtc $notAfter))
            if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($text, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite) }
            $check = Invoke-HostUpdateNative -Native $Native -FilePath '/usr/sbin/visudo' -ArgumentList @('-cf', $text) -TimeoutSeconds 30
            if (-not $check -or [int]$check.ExitCode -ne 0) { return (& $answer $false 'visudo-refused') }
            $write = Invoke-HostUpdateNative -Native $Native -FilePath '/bin/sh' -TimeoutSeconds 30 -ArgumentList @(
                '-c', 'umask 0227; exec sudo -n /usr/bin/tee "$1" < "$2" > /dev/null', 'sh', $script:HostUpdateSudoRulePath, $text)
            if (-not $write -or [int]$write.ExitCode -ne 0) {
                $null = Remove-HostUpdateSudoRule -Native $Native -HostType $HostType -Confirm:$false
                return (& $answer $false 'write-failed')
            }
            $confirm = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '-k', 'true') -TimeoutSeconds 30
            if (-not $confirm -or [int]$confirm.ExitCode -ne 0) {
                $null = Remove-HostUpdateSudoRule -Native $Native -HostType $HostType -Confirm:$false
                return (& $answer $false 'not-confirmed')
            }
            return (& $answer $true 'ok')
        } catch {
            Write-Verbose "Set-HostUpdateSudoRule: $($_.Exception.Message)"
            $null = Remove-HostUpdateSudoRule -Native $Native -HostType $HostType -Confirm:$false
            return (& $answer $false 'write-failed')
        } finally {
            try { [System.IO.File]::Delete($text) } catch { Write-Verbose "Set-HostUpdateSudoRule: '$text' left: $($_.Exception.Message)" }
        }
    }
    try {
        [System.IO.File]::WriteAllText($text, (Get-HostUpdateSudoRuleText -Account $Account))
        if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($text, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite) }
        $visudo = if ([System.IO.File]::Exists('/usr/sbin/visudo')) { '/usr/sbin/visudo' } else { 'visudo' }
        $check = Invoke-HostUpdateNative -Native $Native -FilePath $visudo -ArgumentList @('-cf', $text) -TimeoutSeconds 30
        if (-not $check -or [int]$check.ExitCode -ne 0) { return (& $answer $false 'visudo-refused') }
        # tee reads the text on standard input, which only a shell redirect
        # gives it here; sudo matches tee, which the manifest allows.
        $write = Invoke-HostUpdateNative -Native $Native -FilePath '/bin/sh' -TimeoutSeconds 30 -ArgumentList @(
            '-c', 'exec sudo -n tee "$1" < "$2" > /dev/null', 'sh', $script:HostUpdateSudoRulePath, $text)
        if (-not $write -or [int]$write.ExitCode -ne 0) {
            $null = Remove-HostUpdateSudoRule -Native $Native -Confirm:$false
            return (& $answer $false 'write-failed')
        }
        $confirm = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '-k', 'true') -TimeoutSeconds 30
        if (-not $confirm -or [int]$confirm.ExitCode -ne 0) {
            $null = Remove-HostUpdateSudoRule -Native $Native -Confirm:$false
            return (& $answer $false 'not-confirmed')
        }
        $null = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', 'chmod', '0440', $script:HostUpdateSudoRulePath) -TimeoutSeconds 30
        $null = Stop-HostUpdateElevatedUnit -Unit @("$($script:HostUpdateSudoExpiryUnit).timer") -Native $Native -Confirm:$false
        $null = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -TimeoutSeconds 30 -ArgumentList @(
            '-n', 'systemctl', 'reset-failed', "$($script:HostUpdateSudoExpiryUnit).timer", "$($script:HostUpdateSudoExpiryUnit).service")
        $timer = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -TimeoutSeconds 60 -ArgumentList @(
            '-n', 'systemd-run', "--unit=$($script:HostUpdateSudoExpiryUnit)", "--on-active=$($ExpirySeconds)s", '--timer-property=AccuracySec=1s',
            '--quiet', '/usr/bin/rm', '-f', $script:HostUpdateSudoRulePath)
        if (-not $timer -or [int]$timer.ExitCode -ne 0) {
            $null = Remove-HostUpdateSudoRule -Native $Native -Confirm:$false
            return (& $answer $false 'timer-failed')
        }
        return (& $answer $true 'ok')
    } catch {
        Write-Verbose "Set-HostUpdateSudoRule: $($_.Exception.Message)"
        $null = Remove-HostUpdateSudoRule -Native $Native -Confirm:$false
        return (& $answer $false 'write-failed')
    } finally {
        try { [System.IO.File]::Delete($text) } catch { Write-Verbose "Set-HostUpdateSudoRule: '$text' left: $($_.Exception.Message)" }
    }
}

function Test-HostUpdateFullScopeReady {
    <#
    .SYNOPSIS
        Whether this host can run the full scope: on KVM the runner's
        passwordless manifest (the elevation probe), on Windows an elevated
        Administrator token. On macOS it answers false: the probe there
        writes the temporary rule's path, so only the controller makes it
        (Test-HostUpdateMacElevationEntry), never a step child.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($IsWindows) {
        try {
            $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { return $false }
    }
    if ($IsMacOS) { return $false }
    $commands = @(Get-RunnerElevationCommand -HostType 'host.ubuntu.kvm')
    if ($commands.Count -eq 0) { return $false }
    return (Test-RunnerElevationReady -Command $commands)
}

function Test-HostUpdateMacElevationEntry {
    <#
    .SYNOPSIS
        Whether the permanent entry lets this account write and remove the
        temporary rule's file without a password (macOS).
    .DESCRIPTION
        The controller's own probe, made only while no host update is
        claimed, because it writes the rule's path. A file holding only a
        comment goes through the tee the entry allows and is removed through
        its rm, both with sudo -n -k, so a cached credential cannot pass for
        the entry. The file never holds a rule. A tee that passed with an rm
        that failed leaves a comment-only file and reads as false.
    .PARAMETER Native
        A replacement for the native calls.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][scriptblock]$Native)
    $write = Invoke-HostUpdateNative -Native $Native -FilePath '/bin/sh' -TimeoutSeconds 30 -ArgumentList @(
        '-c', 'umask 0227; printf ''# yuruna host update elevation probe\n'' | exec sudo -n -k /usr/bin/tee "$1" > /dev/null', 'sh', $script:HostUpdateSudoRulePath)
    if (-not $write -or [int]$write.ExitCode -ne 0) { return $false }
    $remove = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '-k', '/bin/rm', '-f', $script:HostUpdateSudoRulePath) -TimeoutSeconds 30
    return [bool]($remove -and [int]$remove.ExitCode -eq 0)
}

function Get-HostUpdateAccessEntryText {
    <#
    .SYNOPSIS
        The permanent sudoers entry of a macOS host: the two commands, with
        their fixed arguments, that the temporary rule needs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z', Options = 'None')][string]$Account)
    return "$Account ALL=(root) NOPASSWD: /usr/bin/tee $($script:HostUpdateSudoRulePath), /bin/rm -f $($script:HostUpdateSudoRulePath)`n"
}

function Install-HostUpdateAccessEntry {
    <#
    .SYNOPSIS
        Install the permanent sudoers entry of a macOS host, with the sudo
        credential an attended Enable-TestAutomation already primed.
    .DESCRIPTION
        The entry is Yuruna's own file, like the KVM unit file: a text that
        differs is replaced. The text is checked by visudo in a private file
        before it reaches /etc/sudoers.d, installed root-owned with mode
        0440, and checked again in place; an installed file visudo refuses
        is removed at once, because a malformed drop-in breaks sudo for the
        whole host.
    .PARAMETER Account
        The test account.
    .PARAMETER Native
        A replacement for the native calls.
    .PARAMETER WorkDirectory
        Where the private text is written; the temporary folder by default.
    .OUTPUTS
        [pscustomobject] @{ Reason installed|unchanged|replaced|failed|preview;
        Detail }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z', Options = 'None')][string]$Account,
        [AllowNull()][scriptblock]$Native,
        [string]$WorkDirectory
    )
    $answer = { param([string]$Reason, $Detail) [pscustomobject]@{ Reason = $Reason; Detail = $Detail } }
    $entry = $script:HostUpdateAccessEntryPath
    if (-not $PSCmdlet.ShouldProcess($entry, (Format-YurunaOperatorMessage -Key 'runner.host_update_access_entry_action'))) { return (& $answer 'preview' $null) }
    $wanted = Get-HostUpdateAccessEntryText -Account $Account
    $read = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '/bin/cat', $entry) -TimeoutSeconds 30
    $present = [bool]($read -and [int]$read.ExitCode -eq 0)
    if ($present -and [string]$read.StdOut -ceq $wanted) { return (& $answer 'unchanged' $null) }
    $directory = if ($WorkDirectory) { $WorkDirectory } else { [System.IO.Path]::GetTempPath() }
    $text = [System.IO.Path]::Combine($directory, "yuruna-host-update-access.$PID.$([Guid]::NewGuid().ToString('N').Substring(0, 8))")
    try {
        $options = [System.IO.FileStreamOptions]::new()
        $options.Mode = [System.IO.FileMode]::CreateNew
        $options.Access = [System.IO.FileAccess]::Write
        if (-not $IsWindows) { $options.UnixCreateMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite }
        $stream = [System.IO.FileStream]::new($text, $options)
        try {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($wanted)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
        $check = Invoke-HostUpdateNative -Native $Native -FilePath '/usr/sbin/visudo' -ArgumentList @('-cf', $text) -TimeoutSeconds 30
        if (-not $check -or [int]$check.ExitCode -ne 0) { return (& $answer 'failed' 'visudo-refused') }
        $install = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -TimeoutSeconds 30 -ArgumentList @(
            '-n', '/usr/bin/install', '-m', '0440', '-o', 'root', '-g', 'wheel', $text, $entry)
        if (-not $install -or [int]$install.ExitCode -ne 0) { return (& $answer 'failed' 'install-failed') }
        $installed = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '/usr/sbin/visudo', '-cf', $entry) -TimeoutSeconds 30
        if (-not $installed -or [int]$installed.ExitCode -ne 0) {
            $null = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '/bin/rm', '-f', $entry) -TimeoutSeconds 30
            return (& $answer 'failed' 'installed-check-refused')
        }
        return (& $answer $(if ($present) { 'replaced' } else { 'installed' }) $null)
    } catch {
        Write-Verbose "Install-HostUpdateAccessEntry: $($_.Exception.Message)"
        return (& $answer 'failed' 'io-error')
    } finally {
        try { [System.IO.File]::Delete($text) } catch { Write-Verbose "Install-HostUpdateAccessEntry: '$text' left: $($_.Exception.Message)" }
    }
}

function Remove-HostUpdateAccessEntry {
    <#
    .SYNOPSIS
        Remove the permanent sudoers entry of a macOS host. The entry does not
        allow its own removal: this needs the credential the caller primed.
    .OUTPUTS
        [bool] rm -f exited 0.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([AllowNull()][scriptblock]$Native)
    if (-not $PSCmdlet.ShouldProcess($script:HostUpdateAccessEntryPath, (Format-YurunaOperatorMessage -Key 'runner.host_update_access_entry_action'))) { return $false }
    $removed = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '/bin/rm', '-f', $script:HostUpdateAccessEntryPath) -TimeoutSeconds 30
    return [bool]($removed -and [int]$removed.ExitCode -eq 0)
}

function Get-HostUpdateProcessLiveness {
    <#
    .SYNOPSIS
        alive, dead or unknown for a process identity, read from the process
        table, which (unlike the process object) sees another user's start
        time.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$ProcessId, [AllowNull()]$StartTimeUnixMs)
    $number = 0
    if (-not [int]::TryParse("$ProcessId", [ref]$number) -or $number -le 0) { return 'unknown' }
    $table = Get-YurunaProcessTable -ProcessId @($number) -TimeoutSeconds 10
    if (-not $table -or -not $table.Complete) { return 'unknown' }
    $row = @($table.Rows | Where-Object { [int]$_.Pid -eq $number })[0]
    if (-not $row) { return 'dead' }
    $recorded = [long]0; $live = [long]0
    if (-not [long]::TryParse("$StartTimeUnixMs", [ref]$recorded) -or $recorded -le 0 -or -not [long]::TryParse("$($row.StartTimeUnixMs)", [ref]$live) -or $live -le 0) { return 'unknown' }
    if ([Math]::Abs($live - $recorded) -le 2000) { return 'alive' }
    return 'dead'
}

function Get-HostUpdateProcessTreeMember {
    <#
    .SYNOPSIS
        A process and its descendants in one process table, parents first.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object[]]$Row, [Parameter(Mandatory)][int[]]$RootPid, [Parameter(Mandatory)][hashtable]$Kind)
    $byParent = @{}
    foreach ($process in $Row) {
        $parent = [int]$process.ParentPid
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = [System.Collections.Generic.List[object]]::new() }
        $byParent[$parent].Add($process)
    }
    $byPid = @{}
    foreach ($process in $Row) { $byPid[[int]$process.Pid] = $process }
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($rootId in $RootPid) {
        if ($byPid.ContainsKey($rootId)) { $queue.Enqueue(@{ Process = $byPid[$rootId]; Kind = $Kind[$rootId] }) }
    }
    $members = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $id = [int]$item.Process.Pid
        if ($id -eq $PID -or -not $seen.Add($id)) { continue }
        $members.Add([pscustomobject]@{
                ProcessId = $id; StartTimeUnixMs = $item.Process.StartTimeUnixMs; Kind = [string]$item.Kind; Root = ("$($item.Process.OwnerId)" -eq '0')
            })
        if ($byParent.ContainsKey($id)) { foreach ($child in $byParent[$id]) { $queue.Enqueue(@{ Process = $child; Kind = $item.Kind }) } }
    }
    return , [object[]]$members.ToArray()
}

function Get-HostUpdateProcessArgument {
    <#
    .SYNOPSIS
        The argument vector of one process-table row: its Argv where the
        platform reads one (Linux /proc), else its joined command line split
        into tokens.
    .DESCRIPTION
        macOS ps and Windows CIM rows carry only the joined command line. A
        double-quoted run is one token, as a Windows command line quotes a
        path with spaces; ps on macOS joins the vector with single spaces
        and no quotes, so an argument with a space in it reads there as two.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter(Mandatory)][AllowNull()]$Process)
    if ($null -ne $Process.Argv -and @($Process.Argv).Count -gt 0) { return , [string[]]@($Process.Argv | ForEach-Object { [string]$_ }) }
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches([string]$Process.CommandLine, '"([^"]*)"|(\S+)')) {
        $tokens.Add($(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }))
    }
    return , [string[]]$tokens.ToArray()
}

function Get-HostUpdateMacElevatedWork {
    <#
    .SYNOPSIS
        The live processes of a host update's install or enable phase on
        macOS, descendants included, from one process table.
    .DESCRIPTION
        The unattended installer names the request in its arguments
        (install/macos.utm.sh --unattended --request-id <id>). The enable
        phase runs Enable-TestAutomation.ps1 with -NoOperatorPrompt, whose
        arguments name no request; it is told apart from an unattended Enable
        of another checkout (another runner's update, or a suite that runs
        the real script) by its full script path, test/lab or
        host/macos.utm under the update's checkout.
        A member running as root (a sudo child of the installer or of
        Homebrew) cannot be signaled by the test account, so each member
        says whether it is one. A root process that its parent left is
        reparented and no longer found here: callers take this snapshot
        before they end anything.
    .PARAMETER RequestId
        The host update.
    .PARAMETER Checkout
        The checkouts whose Enable runs belong to the update; by default the
        checkout this module was loaded from.
    .PARAMETER Service
        ProcessTable: a replacement for Get-YurunaProcessTable.
    .OUTPUTS
        [pscustomobject[]] @{ ProcessId; StartTimeUnixMs; Kind install|
        enable; Root }, or $null when the process table is incomplete.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z', Options = 'None')][string]$RequestId,
        [ValidateNotNullOrEmpty()][string[]]$Checkout = @([System.IO.Path]::Combine($PSScriptRoot, '..', '..')),
        [hashtable]$Service = @{}
    )
    $enableScript = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $Checkout) {
        $full = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($root)).Replace('\', '/')
        $enableScript.Add("$full/test/lab/Enable-TestAutomation.ps1")
        $enableScript.Add("$full/host/macos.utm/Enable-TestAutomation.ps1")
    }
    $table = if ($Service.ProcessTable) { & $Service.ProcessTable } else { Get-YurunaProcessTable -TimeoutSeconds 20 }
    if (-not $table -or -not $table.Complete) { return $null }
    $rows = @($table.Rows | Where-Object { $_ })
    $roots = [System.Collections.Generic.List[int]]::new()
    $kind = @{}
    foreach ($process in $rows) {
        $argv = Get-HostUpdateProcessArgument -Process $process
        if ($argv.Count -lt 2 -or [int]$process.Pid -eq $PID) { continue }
        $found = $null
        for ($i = 0; $i -lt $argv.Count; $i++) {
            $token = $argv[$i].Replace('\', '/')
            if ($token.EndsWith('/install/macos.utm.sh', [StringComparison]::Ordinal) -or $token -ceq 'install/macos.utm.sh') {
                $rest = @($argv | Select-Object -Skip ($i + 1))
                $at = [array]::IndexOf([string[]]$rest, '--request-id')
                if ($rest -ccontains '--unattended' -and $at -ge 0 -and $at + 1 -lt $rest.Count -and $rest[$at + 1] -ceq $RequestId) { $found = 'install' }
                break
            }
            if ([System.IO.Path]::GetFileName($token) -ceq 'Enable-TestAutomation.ps1' -and [System.IO.Path]::GetFileName($argv[0]) -like 'pwsh*' -and
                $argv -ccontains '-NoOperatorPrompt') {
                # macOS ps joins the vector with single spaces, so a script
                # path with a space in it ends in this token and starts in
                # an earlier one; it is rebuilt from them. A real vector
                # holds the path in this token alone.
                $path = $token
                $match = $enableScript -ccontains $path
                $joined = $null -eq $process.Argv -or @($process.Argv).Count -eq 0
                for ($k = $i - 1; $joined -and -not $match -and $k -ge 1; $k--) {
                    $path = $argv[$k].Replace('\', '/') + ' ' + $path
                    $match = $enableScript -ccontains $path
                }
                if ($match) { $found = 'enable' }
                break
            }
        }
        if ($found) { $roots.Add([int]$process.Pid); $kind[[int]$process.Pid] = $found }
    }
    if ($roots.Count -eq 0) { return , [object[]]@() }
    return (Get-HostUpdateProcessTreeMember -Row $rows -RootPid $roots.ToArray() -Kind $kind)
}

function Stop-HostUpdateMacElevatedWork {
    <#
    .SYNOPSIS
        End the processes Get-HostUpdateMacElevatedWork found, and confirm
        each one gone.
    .DESCRIPTION
        Members that run as the test account are stopped first, each only
        while its start time still matches, so a reused pid is never hit.
        Members that run as root are signaled through sudo -n /bin/kill,
        which only the temporary rule allows: callers end the work while the
        rule is in force and remove the rule afterwards. TERM first, KILL
        after a grace.
    .PARAMETER Work
        The members; $null (the table could not say) is never all gone.
    .PARAMETER Native
        A replacement for the native calls.
    .PARAMETER Service
        Liveness (alive, dead or unknown for a pid and start time),
        StopProcess (end a test-account process tree), Sleep (milliseconds).
    .OUTPUTS
        [bool] every member is gone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Work,
        [AllowNull()][scriptblock]$Native,
        [hashtable]$Service = @{}
    )
    if ($null -eq $Work) { return $false }
    $calls = @{
        Liveness    = { param($ProcessId, $StartTimeUnixMs) Get-HostUpdateProcessLiveness -ProcessId $ProcessId -StartTimeUnixMs $StartTimeUnixMs }
        StopProcess = { param($ProcessId) Stop-YurunaProcessTree -ProcessId $ProcessId -GraceMilliseconds 2000 -Confirm:$false }
        Sleep       = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    }
    foreach ($key in @($Service.Keys)) { $calls[$key] = $Service[$key] }
    $members = @($Work | Where-Object { $_ })
    if ($members.Count -eq 0) { return $true }
    if (-not $PSCmdlet.ShouldProcess(((@($members | ForEach-Object { $_.ProcessId })) -join ','), (Format-YurunaOperatorMessage -Key 'runner.host_update_elevated_work_action'))) { return $false }
    $alive = { param($Member) (& $calls.Liveness $Member.ProcessId $Member.StartTimeUnixMs) -eq 'alive' }
    foreach ($member in @($members | Where-Object { -not $_.Root })) {
        if (& $alive $member) { & $calls.StopProcess ([int]$member.ProcessId) }
    }
    $root = @($members | Where-Object { $_.Root })
    foreach ($signal in @('-TERM', '-KILL')) {
        $left = @($root | Where-Object { & $alive $_ })
        if ($left.Count -eq 0) { break }
        foreach ($member in $left) {
            $null = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList @('-n', '/bin/kill', $signal, "$([int]$member.ProcessId)") -TimeoutSeconds 10
        }
        for ($wait = 0; $wait -lt 10 -and @($root | Where-Object { & $alive $_ }).Count -gt 0; $wait++) { & $calls.Sleep 500 }
    }
    foreach ($member in $members) {
        if ((& $calls.Liveness $member.ProcessId $member.StartTimeUnixMs) -ne 'dead') { return $false }
    }
    return $true
}

function Stop-HostUpdateMacStepTree {
    <#
    .SYNOPSIS
        End a step child on macOS with every descendant, root members
        included.
    .DESCRIPTION
        The tree is read before anything is ended: a root child of an
        installer that is killed is reparented and could not be found again.
        With no complete process table, only the test-account tree is ended.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$ProcessId, [AllowNull()][scriptblock]$Native)
    if (-not $PSCmdlet.ShouldProcess("$ProcessId", (Format-YurunaOperatorMessage -Key 'runner.host_update_elevated_work_action'))) { return }
    $table = Get-YurunaProcessTable -TimeoutSeconds 20
    if (-not $table -or -not $table.Complete) {
        Stop-YurunaProcessTree -ProcessId $ProcessId -Confirm:$false
        return
    }
    $work = Get-HostUpdateProcessTreeMember -Row @($table.Rows | Where-Object { $_ }) -RootPid @($ProcessId) -Kind @{ $ProcessId = 'step' }
    $null = Stop-HostUpdateMacElevatedWork -Work $work -Native $Native -Confirm:$false
}

# --- REGION: Controller context, clock and logs
function Write-HostUpdateControllerLine {
    <#
    .SYNOPSIS
        One controller event line: on standard error, and appended to the
        file YURUNA_HOST_CONTROLLER_LOG names when the shim set one.
    .DESCRIPTION
        A system unit hands standard error to the journal. A scheduled task
        keeps nothing, so the Windows shim names a file in the controller
        root; at 1 MiB it is moved to <file>.1 and started again.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line)
    [Console]::Error.WriteLine($Line)
    $path = [string]$env:YURUNA_HOST_CONTROLLER_LOG
    if (-not $path -or -not [System.IO.Path]::IsPathFullyQualified($path)) { return }
    try {
        $info = [System.IO.FileInfo]::new($path)
        if ($info.Exists -and $info.Length -gt 1048576) { [System.IO.File]::Move($path, "$path.1", $true) }
        [System.IO.File]::AppendAllText($path, ([DateTime]::UtcNow.ToString('o') + ' ' + $Line + [Environment]::NewLine))
    } catch {
        Write-Verbose "Write-HostUpdateControllerLine: '$path' not written: $($_.Exception.Message)"
    }
}

function New-HostUpdateControllerContext {
    <#
    .SYNOPSIS
        Everything one controller instance runs with: its paths, identity,
        bounds, and the services a test replaces.
    .DESCRIPTION
        Services: UtcNow (a DateTimeOffset), TickMs (monotonic
        milliseconds), Sleep (milliseconds), StartStep (launch one step
        child), StepLiveness (alive, dead or unknown for a pid and start
        time), StopStep (end a step child's tree), FindStep (the live step
        children of a phase and request, found by command line), Log (one
        event line), SupportedScope (the scopes this host type declares),
        ElevationProbe (whether the full scope can run here), SessionProbe
        (on macOS, whether this session can start a working runner),
        StopListener (stop the listener of a runtime directory),
        ElevatedWork and StopElevatedWork (on macOS, find the processes of
        an install or enable phase, given the request and the checkout, and
        end them), Native (a replacement for the sudo and systemctl calls,
        $null for the real ones), ShouldStop (end the idle loop),
        OnPhaseWritten (after each journaled phase
        change). Services that depend on the host type receive it as their
        first argument; a replacement may ignore it.
    .PARAMETER ControllerRoot
        The controller root.
    .PARAMETER Snapshot
        The 16-hex snapshot this instance runs.
    .PARAMETER Checkout
        The checkout every checkout step runs from.
    .PARAMETER Service
        Replacements for the default services.
    .PARAMETER HostType
        The host type; this host's by default.
    .OUTPUTS
        [hashtable]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory context only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ControllerRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{16}$', Options = 'None')][string]$Snapshot,
        [Parameter(Mandatory)][string]$Checkout,
        [hashtable]$Service = @{},
        [ValidateScript({ $_ -cin $script:HostUpdateHostTypes })][string]$HostType = (Get-HostUpdateHostType)
    )
    $snapshotRoot = [System.IO.Path]::Combine($ControllerRoot, 'versions', $Snapshot)
    $services = @{
        UtcNow       = { [DateTimeOffset]::UtcNow }
        TickMs       = { [Environment]::TickCount64 }
        Sleep        = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
        StartStep    = { param($Launch) Start-HostUpdateStepProcess -Launch $Launch }
        StepLiveness = { param($ProcessId, $StartTimeUnixMs) Get-YurunaProcessIdentityLiveness -ProcessId $ProcessId -StartTimeUnixMs $StartTimeUnixMs }
        # On macOS a step child of a privileged phase can have root
        # descendants the test account cannot signal.
        StopStep     = {
            param($ProcessId, $HostType, $Native)
            if ($HostType -ceq 'host.macos.utm') { Stop-HostUpdateMacStepTree -ProcessId $ProcessId -Native $Native -Confirm:$false }
            else { Stop-YurunaProcessTree -ProcessId $ProcessId -Confirm:$false }
        }
        FindStep     = { param($Phase, $RequestId) Find-HostUpdateStepProcess -Phase $Phase -RequestId $RequestId }
        Log          = { param([string]$Line) Write-HostUpdateControllerLine -Line $Line }
        SupportedScope = { param($HostType) Get-HostUpdateSupportedScope -HostType $HostType }
        ElevationProbe = {
            param($HostType, $Native)
            if ($HostType -ceq 'host.macos.utm') { Test-HostUpdateMacElevationEntry -Native $Native } else { Test-HostUpdateFullScopeReady }
        }
        SessionProbe = {
            param($HostType, $SnapshotRoot, $Native)
            if ($HostType -ceq 'host.macos.utm') { Invoke-HostUpdateMacSessionProbe -SnapshotRoot $SnapshotRoot -Native $Native } else { $null }
        }
        StopListener = { param([string]$RuntimeDir) Stop-HostUpdateListenerProcess -RuntimeDir $RuntimeDir -Confirm:$false }
        ElevatedWork = { param($RequestId, $Checkout) Get-HostUpdateMacElevatedWork -RequestId $RequestId -Checkout $Checkout }
        StopElevatedWork = { param($Work, $Native) Stop-HostUpdateMacElevatedWork -Work $Work -Native $Native -Confirm:$false }
        Native       = $null
        ShouldStop   = $null
        OnPhaseWritten = $null
    }
    foreach ($key in @($Service.Keys)) { $services[$key] = $Service[$key] }
    $start = $null
    try { $start = [long][DateTimeOffset]::new([System.Diagnostics.Process]::GetCurrentProcess().StartTime).ToUnixTimeMilliseconds() } catch {
        Write-Verbose "New-HostUpdateControllerContext: own start time unreadable: $($_.Exception.Message)"
    }
    return @{
        ControllerRoot = $ControllerRoot; Snapshot = $Snapshot; SnapshotRoot = $snapshotRoot; Checkout = $Checkout
        Protocol = (Get-HostUpdateProtocolVersion -RepoRoot $snapshotRoot)
        CheckoutStepScript = [System.IO.Path]::Combine($Checkout, 'test', 'lab', 'Invoke-HostUpdateStep.ps1')
        SnapshotStepScript = [System.IO.Path]::Combine($snapshotRoot, 'test', 'lab', 'Invoke-HostUpdateStep.ps1')
        ControllerPid = $PID; ControllerStartTimeUnixMs = $start; StartedUtc = $null
        PrivateRoot = $null; RuntimeDir = $null; HostType = $HostType
        Session = 'system-unit'; SessionUsable = $true
        Bound = (Get-HostUpdatePhaseBound -HostType $HostType)
        LifetimeLock = $null; ControllerLock = $null; ActiveRequestId = $null; Activity = 'idle'
        LastPublishTick = [long]::MinValue; LastProjection = @{}; LastVerdict = $null; StageFailed = @{}
        Scopes = [string[]]@('restart'); LastProbeTick = [long]::MinValue; PreClaimProbe = $null
        Service = $services
    }
}

function Get-HostUpdateWallClock {
    <#
    .SYNOPSIS
        The context's wall clock in Unix milliseconds.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [long]([DateTimeOffset](& $Context.Service.UtcNow)).ToUnixTimeMilliseconds()
}

function Get-HostUpdateTick {
    <#
    .SYNOPSIS
        The context's monotonic clock in milliseconds.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [long](& $Context.Service.TickMs)
}

function Get-HostUpdateBootEpoch {
    <#
    .SYNOPSIS
        This boot's epoch as the context's clocks see it.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][hashtable]$Context)
    return (Get-HostUpdateWallClock -Context $Context) - (Get-HostUpdateTick -Context $Context)
}

function Write-HostUpdateControllerLog {
    <#
    .SYNOPSIS
        One event line for the journal of the job supervisor: an event token
        and token values, never prose, paths of the operator's files or
        step output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$EventName,
        [hashtable]$Detail = @{}
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("yuruna-host-controller: event=$EventName")
    foreach ($key in ($Detail.Keys | Sort-Object)) {
        $value = [string]$Detail[$key]
        if ($value -match '\s') { $value = '"' + ($value -replace '"', "'") + '"' }
        $parts.Add("$key=$value")
    }
    try { & $Context.Service.Log ($parts -join ' ') } catch { Write-Verbose "Write-HostUpdateControllerLog: $($_.Exception.Message)" }
}

function Wait-HostUpdateInterval {
    <#
    .SYNOPSIS
        Wait in one-second steps, keeping the state files fresh.
    .DESCRIPTION
        Every wait inside an operation runs the heartbeat, so a long drain,
        a hung step child or a backoff never leaves a stale heartbeat.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][int]$Milliseconds)
    $remaining = $Milliseconds
    while ($remaining -gt 0) {
        $step = [Math]::Min(1000, $remaining)
        & $Context.Service.Sleep $step
        $remaining -= $step
        Step-HostUpdateHeartbeat -Context $Context
    }
}

function Stop-HostUpdateOperation {
    <#
    .SYNOPSIS
        End the operation in place: no new phase and no restore. The next
        controller continues from the journal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Raises an exception only; nothing is changed.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reason)
    $exception = [System.InvalidOperationException]::new("host-update-stop: $Reason")
    $exception.Data['HostUpdateStop'] = $Reason
    throw $exception
}

# --- REGION: State files
function Get-HostUpdateTokenValue {
    <#
    .SYNOPSIS
        A value when it is one of the allowed tokens, else $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value, [Parameter(Mandatory)][string[]]$Allowed)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($Allowed -ccontains $text) { return $text }
    return $null
}

function Get-HostUpdateTokenList {
    <#
    .SYNOPSIS
        The allowed tokens of a list, in order, once each.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([AllowNull()]$Value, [Parameter(Mandatory)][string[]]$Allowed)
    $list = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Value) {
        foreach ($item in @($Value)) {
            $text = [string]$item
            if ($Allowed -ccontains $text -and -not $list.Contains($text)) { $list.Add($text) }
        }
    }
    return , [string[]]$list.ToArray()
}

function Get-HostUpdateRowBlock {
    <#
    .SYNOPSIS
        A row's update block, or an empty one.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [hashtable])]
    param([AllowNull()]$Row)
    if ($Row -is [System.Collections.IDictionary] -and $Row['update'] -is [System.Collections.IDictionary]) { return $Row['update'] }
    return @{}
}

function Get-HostUpdatePhaseEntry {
    <#
    .SYNOPSIS
        One phase's journal entry of a row, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([AllowNull()]$Row, [Parameter(Mandatory)][string]$Phase)
    $phases = (Get-HostUpdateRowBlock -Row $Row)['phases']
    if ($phases -is [System.Collections.IDictionary] -and $phases[$Phase] -is [System.Collections.IDictionary]) { return $phases[$Phase] }
    return $null
}

function Get-HostUpdateArmedObligation {
    <#
    .SYNOPSIS
        The ids of a row's armed obligations.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([AllowNull()]$Row)
    $ids = [System.Collections.Generic.List[string]]::new()
    if ($Row -is [System.Collections.IDictionary]) {
        foreach ($obligation in @($Row['obligations'])) {
            if ($obligation -is [System.Collections.IDictionary] -and [string]$obligation['status'] -eq 'armed') { $ids.Add([string]$obligation['id']) }
        }
    }
    return , [string[]]$ids.ToArray()
}

function Get-HostUpdateScopePhase {
    <#
    .SYNOPSIS
        The phases of a scope on this host, in order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][string]$Scope)
    if ($Scope -cne 'full') { return [string[]]$script:HostUpdateRestartPhase }
    if ($IsWindows) { return [string[]]$script:HostUpdateFullPhase }
    return [string[]]@($script:HostUpdateFullPhase | Where-Object { $_ -ne 'upgrade_pwsh' })
}

function Get-HostUpdateSupportedScope {
    <#
    .SYNOPSIS
        The scopes a host type declares it can run at all, from the
        declaration table; an unknown host type runs restart only.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$HostType = (Get-HostUpdateHostType))
    $declared = $script:HostUpdateScopeDeclaration[$HostType]
    if (-not $declared) { return [string[]]@('restart') }
    return [string[]]@($declared)
}

function Test-HostUpdateProbeAllowed {
    <#
    .SYNOPSIS
        Whether the controller may run its elevation probe now.
    .DESCRIPTION
        Only a host type whose declaration has the full scope is probed. On
        macOS the probe writes the temporary rule's own path, so it never
        runs while a host update is claimed: it would overwrite and remove a
        live rule. A journal that cannot be read cannot rule a claim out, so
        it allows no probe either.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Context)
    if (@(& $Context.Service.SupportedScope $Context.HostType) -cnotcontains 'full') { return $false }
    if ($Context.HostType -cne 'host.macos.utm') { return $true }
    $queue = Get-HostUpdateQueue -UtcNow $Context.Service.UtcNow
    return ($queue.Status -cin @('ok', 'recovered-previous', 'absent')) -and -not $queue.Claimed
}

function Update-HostUpdateScopeList {
    <#
    .SYNOPSIS
        Probe whether this host can run the full scope and record the scopes
        the controller's state publishes.
    .DESCRIPTION
        A host type that does not declare the full scope is not probed. Where
        the probe may not run now (macOS while a host update is claimed, or
        while the journal cannot say whether one is), the full scope the
        last published state listed is kept, so a claimed update that
        continues reads the result of the probe made before its claim.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the in-memory context only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $declared = [string[]]@(& $Context.Service.SupportedScope $Context.HostType)
    $Context.LastProbeTick = Get-HostUpdateTick -Context $Context
    if ($declared -cnotcontains 'full') { $Context.Scopes = $declared; return }
    if (-not (Test-HostUpdateProbeAllowed -Context $Context)) {
        $Context.Scopes = if ((Get-HostUpdatePublishedScope -Context $Context) -ccontains 'full') { $declared } else { [string[]]@('restart') }
        return
    }
    $ready = $false
    try { $ready = [bool](& $Context.Service.ElevationProbe $Context.HostType $Context.Service.Native) } catch { Write-Verbose "Update-HostUpdateScopeList: probe threw: $($_.Exception.Message)" }
    $Context.Scopes = if ($ready) { $declared } else { [string[]]@('restart') }
}

function Get-HostUpdatePublishedScope {
    <#
    .SYNOPSIS
        The scopes the controller's state file in its runtime directory
        lists, or none.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $runtime = [string]$Context.RuntimeDir
    if (-not $runtime) { return , [string[]]@() }
    try {
        $path = [System.IO.Path]::Combine($runtime, 'host-controller.state.json')
        if (-not [System.IO.File]::Exists($path)) { return , [string[]]@() }
        $state = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        return , [string[]]@(([string]$state['scopes']) -split ',' | Where-Object { $_ -cin @('restart', 'full') })
    } catch {
        Write-Verbose "Get-HostUpdatePublishedScope: $($_.Exception.Message)"
        return , [string[]]@()
    }
}

function Update-HostUpdateSession {
    <#
    .SYNOPSIS
        Record which session the controller runs in and whether it can start
        a working runner: on macOS the multiplexer the runner start used and
        the session probe; elsewhere a system unit or task, always usable.
    .DESCRIPTION
        A probe that gives no reading leaves the session usable: a grant that
        cannot be read is not a missing one, and the preflight of every
        update reads the session again for itself.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the in-memory context only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.HostType -cne 'host.macos.utm') { return }
    $Context.Session = if ($env:TMUX) { 'tmux' } elseif ($env:STY) { 'screen' } else { 'terminal' }
    $reading = $null
    try { $reading = & $Context.Service.SessionProbe $Context.HostType $Context.SnapshotRoot $Context.Service.Native } catch {
        Write-Verbose "Update-HostUpdateSession: probe threw: $($_.Exception.Message)"
    }
    $usable = $true
    if ($reading -is [System.Collections.IDictionary] -and $reading['Usable'] -is [bool]) { $usable = [bool]$reading['Usable'] }
    else { Write-HostUpdateControllerLog -Context $Context -EventName 'session-probe-unread' }
    $Context.SessionUsable = $usable
}

function ConvertTo-HostUpdatePublicState {
    <#
    .SYNOPSIS
        The public, allow-listed projection of a host-update row.
    .DESCRIPTION
        Tokens, hashes, times and counts only: a step's output, an
        installer's text, a path or a credential never reach the file. A
        queued row that expired unclaimed reads as refused, with the reason
        protocol_mismatch when the controller could not claim it for that
        reason, else request_expired.
    .PARAMETER Row
        The journal row.
    .PARAMETER Now
        The heartbeat instant.
    .PARAMETER FirstCycle
        The first cycle's note: pass, fail or pending.
    .PARAMETER HostType
        The host type whose phase bounds the state names; this host's by
        default.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Row,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [AllowNull()][string]$FirstCycle,
        [string]$HostType = (Get-HostUpdateHostType)
    )
    $update = Get-HostUpdateRowBlock -Row $Row
    $request = if ($update['request'] -is [System.Collections.IDictionary]) { $update['request'] } else { @{} }
    $rowState = [string]$Row['state']
    $nowMs = $Now.ToUnixTimeMilliseconds()
    $expires = [long]0
    [void][long]::TryParse("$($Row['expiresUnixMs'])", [ref]$expires)
    $expired = ($rowState -eq 'refused' -and @($Row['reasonCodes']) -contains 'request-expired' -and -not $update['verdict']) -or
        ($rowState -eq 'queued' -and $expires -gt 0 -and $nowMs -ge $expires)
    $state = switch ($rowState) {
        'queued' { 'queued' }
        'running' { 'running' }
        'recovery-pending' { 'recovering' }
        default { 'terminal' }
    }
    $verdict = Get-HostUpdateTokenValue -Value $update['verdict'] -Allowed $script:HostUpdateVerdictToken
    $reason = Get-HostUpdateTokenValue -Value $update['reason'] -Allowed $script:HostUpdateReasonToken
    $action = Get-HostUpdateTokenValue -Value $update['operatorAction'] -Allowed $script:HostUpdateActionToken
    if ($expired) {
        $state = 'terminal'; $verdict = 'refused'; $action = 'none'
        $reason = if ([string]$update['claimBlocked'] -ceq 'protocol_mismatch') { 'protocol_mismatch' } else { 'request_expired' }
    }
    $phase = $null
    $phases = Get-HostUpdateScopePhase -Scope ([string]$request['scope'])
    $name = Get-HostUpdateTokenValue -Value $update['phase'] -Allowed @($phases + @('restore', 'recover'))
    if ($state -in @('running', 'recovering') -and $name) {
        $bound = if ($name -eq 'drain') {
            $seconds = 0; [void][int]::TryParse("$($request['drainSeconds'])", [ref]$seconds); $seconds
        } else { [int](Get-HostUpdatePhaseBound -HostType $HostType)[$name] }
        $phase = [ordered]@{
            index = [array]::IndexOf($phases, $name) + 1
            count = $phases.Count
            name  = $name
            bound = $bound
        }
    }
    # Only while the update still owes the listener: once one answers again
    # the time is moot.
    $expectedBack = [string]$update['listenerExpectedBackUtc']
    if ($state -eq 'terminal' -or (Get-HostUpdateArmedObligation -Row $Row) -cnotcontains 'listener' -or
        $expectedBack -notmatch '\A\d{4}-\d{2}-\d{2}T[0-9:.]+Z\z') { $expectedBack = $null }
    $commit = [ordered]@{ before = $null; after = $null; resident = $null }
    if ($update['commit'] -is [System.Collections.IDictionary]) {
        foreach ($key in @('before', 'after', 'resident')) {
            $sha = [string]$update['commit'][$key]
            if ($sha -cmatch '\A[0-9a-f]{7,64}\z') { $commit[$key] = $sha }
        }
    }
    $debt = [System.Collections.Generic.List[object]]::new()
    foreach ($debtRow in @($update['debt'])) {
        if ($debtRow -isnot [System.Collections.IDictionary]) { continue }
        $obligation = Get-HostUpdateTokenValue -Value $debtRow['obligation'] -Allowed @('listener', 'elevation')
        $debtAction = Get-HostUpdateTokenValue -Value $debtRow['action'] -Allowed @('start_listener', 'remove_sudo_rule')
        if ($obligation -and $debtAction) { $debt.Add([ordered]@{ obligation = $obligation; action = $debtAction }) }
    }
    $idPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
    $started = if ($update['claimedUtc']) { [string]$update['claimedUtc'] } else { [string]$Row['createdUtc'] }
    $terminal = if ($state -eq 'terminal') {
        if ($Row['terminalUtc']) { [string]$Row['terminalUtc'] } elseif ($expired) { $Now.UtcDateTime.ToString('o') } else { $null }
    } else { $null }
    $requestId = [string]$Row['requestId']
    $superseded = [string]$update['supersededBy']
    return [ordered]@{
        schemaVersion           = 1
        requestId               = if ($requestId -cmatch $idPattern) { $requestId } else { $null }
        scope                   = Get-HostUpdateTokenValue -Value $request['scope'] -Allowed @('restart', 'full')
        channel                 = Get-HostUpdateTokenValue -Value $Row['channel'] -Allowed @('listener', 'local', 'remote')
        state                   = $state
        phase                   = $phase
        startedUtc              = if ($started -match '\A\d{4}-\d{2}-\d{2}T[0-9:.]+Z?\z') { $started } else { $null }
        heartbeatUtc            = $Now.UtcDateTime.ToString('o')
        mutated                 = [bool]$update['mutated']
        listenerExpectedBackUtc = $expectedBack
        remarks                 = Get-HostUpdateTokenList -Value $update['remarks'] -Allowed $script:HostUpdateRemarkToken
        debt                    = [object[]]$debt.ToArray()
        verdict                 = $verdict
        operatorAction          = $action
        reason                  = $reason
        commit                  = $commit
        runnerConsole           = Get-HostUpdateTokenValue -Value $update['runnerConsole'] -Allowed $script:HostUpdateConsoleToken
        supersededBy            = if ($superseded -cmatch $idPattern) { $superseded } else { $null }
        firstCycle              = Get-HostUpdateTokenValue -Value $FirstCycle -Allowed @('pass', 'fail', 'pending')
        terminalUtc             = if ($terminal -match '\A\d{4}-\d{2}-\d{2}T[0-9:.]+Z?\z') { $terminal } else { $null }
    }
}

function Write-HostUpdatePublicState {
    <#
    .SYNOPSIS
        Write a row's public state into its runtime directory.
    .OUTPUTS
        [string] the projection's hash without its heartbeat, or $null when
        nothing was written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    $runtime = [string]$Row['runtimeDir']
    if (-not $runtime -or -not [System.IO.Directory]::Exists($runtime)) { return $null }
    $note = if ($Context.LastVerdict -and $Context.LastVerdict.RequestId -ceq [string]$Row['requestId']) { $Context.LastVerdict.FirstCycle } else { $null }
    $state = ConvertTo-HostUpdatePublicState -Row $Row -Now ([DateTimeOffset](& $Context.Service.UtcNow)) -FirstCycle $note -HostType $Context.HostType
    $copy = [ordered]@{}
    foreach ($key in $state.Keys) { if ($key -ne 'heartbeatUtc') { $copy[$key] = $state[$key] } }
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(($copy | ConvertTo-Json -Depth 6 -Compress))))
    if (-not $PSCmdlet.ShouldProcess($runtime, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return $null }
    $written = Write-YurunaStateFileJson -Path ([System.IO.Path]::Combine($runtime, 'host-update.state.json')) -InputObject $state -Depth 6 -Confirm:$false
    if (-not $written) { Write-HostUpdateControllerLog -Context $Context -EventName 'state-write-failed' -Detail @{ file = 'host-update.state.json' }; return $null }
    return $hash
}

function Write-HostUpdateControllerState {
    <#
    .SYNOPSIS
        Write runtime/host-controller.state.json: which snapshot runs, the
        heartbeat, and what this controller can run.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $runtime = [string]$Context.RuntimeDir
    if (-not $runtime -or -not [System.IO.Directory]::Exists($runtime)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($runtime, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return $false }
    $now = [DateTimeOffset](& $Context.Service.UtcNow)
    $state = [ordered]@{
        schemaVersion   = 1
        snapshot        = $Context.Snapshot
        protocol        = [int]$Context.Protocol
        pid             = $Context.ControllerPid
        startTimeUnixMs = $Context.ControllerStartTimeUnixMs
        startedUtc      = $Context.StartedUtc
        heartbeatUtc    = $now.UtcDateTime.ToString('o')
        activity        = if ($Context.ActiveRequestId) { 'busy' } else { 'idle' }
        requestId       = $Context.ActiveRequestId
        session         = [string]$Context.Session
        sessionUsable   = [bool]$Context.SessionUsable
        scopes          = (@($Context.Scopes) -join ',')
    }
    $written = Write-YurunaStateFileJson -Path ([System.IO.Path]::Combine($runtime, 'host-controller.state.json')) -InputObject $state -Confirm:$false
    if (-not $written) { Write-HostUpdateControllerLog -Context $Context -EventName 'state-write-failed' -Detail @{ file = 'host-controller.state.json' } }
    return [bool]$written
}

function Step-HostUpdateHeartbeat {
    <#
    .SYNOPSIS
        Every 5 s: both state files, whatever the controller is waiting on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [switch]$Force)
    $tick = Get-HostUpdateTick -Context $Context
    if (-not $Force -and $Context.LastPublishTick -ne [long]::MinValue -and ($tick - $Context.LastPublishTick) -lt 5000) { return }
    $Context.LastPublishTick = $tick
    $null = Write-HostUpdateControllerState -Context $Context -Confirm:$false
    if ($Context.ActiveRequestId) {
        $row = Get-HostUpdateRequest -RequestId $Context.ActiveRequestId
        if ($row) { $null = Write-HostUpdatePublicState -Context $Context -Row $row -Confirm:$false }
    }
}

# --- REGION: Journal writes of the operation
function Get-HostUpdateRow {
    <#
    .SYNOPSIS
        The row of the operation, read again; a vanished row ends the
        operation in place.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$RequestId)
    $row = Get-HostUpdateRequest -RequestId $RequestId
    if (-not $row) { Stop-HostUpdateOperation -Reason 'row-unreadable' }
    return $row
}

function Write-HostUpdatePhaseRecord {
    <#
    .SYNOPSIS
        Journal a phase change, then publish the public state at once.
    .OUTPUTS
        [int] the phase's attempts.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][hashtable]$Change
    )
    $arguments = @{ RequestId = $RequestId; ControllerPid = $Context.ControllerPid; UtcNow = $Context.Service.UtcNow; Confirm = $false }
    foreach ($key in $Change.Keys) { if ($null -ne $Change[$key]) { $arguments[$key] = $Change[$key] } }
    $write = Set-HostUpdatePhase @arguments
    if (-not $write.Written) {
        Write-HostUpdateControllerLog -Context $Context -EventName 'journal-write-failed' -Detail @{ requestId = $RequestId; phase = $Change.Phase; reason = $write.Reason }
        Stop-HostUpdateOperation -Reason 'journal-write-failed'
    }
    $row = Get-HostUpdateRequest -RequestId $RequestId
    if ($row) { $null = Write-HostUpdatePublicState -Context $Context -Row $row -Confirm:$false }
    if ($Context.Service.OnPhaseWritten) { & $Context.Service.OnPhaseWritten $Change }
    return [int]$write.Attempts
}

function Set-HostUpdateObligationRecord {
    <#
    .SYNOPSIS
        Arm, discharge or dispose an obligation; a write that fails ends the
        operation in place.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The journal writer it calls gates the change with ShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$ObligationId,
        [Parameter(Mandatory)][string]$State,
        [string]$Evidence,
        [string]$Actor
    )
    $arguments = @{ RequestId = $RequestId; ControllerPid = $Context.ControllerPid; ObligationId = $ObligationId; State = $State; UtcNow = $Context.Service.UtcNow; Confirm = $false }
    if ($Evidence) { $arguments.Evidence = $Evidence }
    if ($Actor) { $arguments.Actor = $Actor }
    $write = Set-HostUpdateObligation @arguments
    if (-not $write.Written -and $write.Reason -notin @('disposed', 'unchanged', 'absent')) {
        Write-HostUpdateControllerLog -Context $Context -EventName 'journal-write-failed' -Detail @{ requestId = $RequestId; obligation = $ObligationId; reason = $write.Reason }
        Stop-HostUpdateOperation -Reason 'journal-write-failed'
    }
}

# --- REGION: Locks and the runner gate
function Enter-HostUpdateLifetimeLock {
    <#
    .SYNOPSIS
        Take host-operation.lock, trying again every 2 s: the controller never
        writes a claim, a continuation or a restore without it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.LifetimeLock -and $Context.LifetimeLock.Held) { return }
    $logged = $false
    while ($true) {
        $path = Get-YurunaHostOperationLockPath
        if ($path) {
            $lock = Enter-YurunaSingleFlightLock -Path $path -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 1500 `
                -Metadata @{ purpose = 'host-update'; requestId = [string]$Context.ActiveRequestId }
            if ($lock.Held) { $Context.LifetimeLock = $lock; return }
            if (-not $logged) { Write-HostUpdateControllerLog -Context $Context -EventName 'lifetime-lock-busy' -Detail @{ reason = $lock.Reason }; $logged = $true }
        }
        Wait-HostUpdateInterval -Context $Context -Milliseconds 2000
    }
}

function Exit-HostUpdateLifetimeLock {
    <#
    .SYNOPSIS
        Release host-operation.lock when this controller holds it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.LifetimeLock) { Exit-YurunaSingleFlightLock -Lock $Context.LifetimeLock }
    $Context.LifetimeLock = $null
}

function Get-HostUpdateGate {
    <#
    .SYNOPSIS
        The runner gate under this controller's private root.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    return (Get-YurunaRunnerGateState -RuntimeDir ([string]$Row['runtimeDir']) -PrivateRoot $Context.PrivateRoot)
}

function Test-HostUpdateGateOwnership {
    <#
    .SYNOPSIS
        Whether a gate is held under this update's id or the id it inherited.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    $ids = @([string]$Row['requestId'])
    $inherited = [string](Get-HostUpdateRowBlock -Row $Row)['inheritedGateRequestId']
    if ($inherited) { $ids += $inherited }
    return ($ids -ccontains [string]$Gate.RequestId)
}

function Set-HostUpdateGateRecord {
    <#
    .SYNOPSIS
        One compare-and-set write of the gate, owned by this controller.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The gate writer it calls gates the change with ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Row,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)]$Gate
    )
    return (Set-YurunaRunnerGate -State $State -RequestId ([string]$Row['requestId']) -Attempt 1 -RuntimeDir ([string]$Row['runtimeDir']) `
            -ExpectedGeneration ([string]$Gate.Generation) -OwnerPid $Context.ControllerPid -OwnerRole controller -PrivateRoot $Context.PrivateRoot -Confirm:$false)
}

function Update-HostUpdateGateOwner {
    <#
    .SYNOPSIS
        Re-stamp the gate's owner as this controller.
    .DESCRIPTION
        Only a gate that is closed or recovery-pending under this update's id
        (or the id it inherited) is re-stamped, with a compare-and-set on the
        generation read. A handoff is left to its acknowledgment; a write
        that loses the race is read again once, then left.
    .OUTPUTS
        [string] restamped, handoff, open, not-ours or failed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    if (-not $PSCmdlet.ShouldProcess([string]$Row['requestId'], (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return 'failed' }
    for ($try = 0; $try -lt 2; $try++) {
        $gate = Get-HostUpdateGate -Context $Context -Row $Row
        if ($gate.State -eq 'open') { return 'open' }
        if ($gate.State -eq 'handoff') { return 'handoff' }
        if ($gate.State -notin @('closed', 'recovery-pending') -or -not (Test-HostUpdateGateOwnership -Gate $gate -Row $Row)) { return 'not-ours' }
        $write = Set-HostUpdateGateRecord -Context $Context -Row $Row -State $gate.State -Gate $gate
        if ($write.Written) { return 'restamped' }
        if ($write.Reason -ne 'generation-mismatch') { break }
    }
    Write-HostUpdateControllerLog -Context $Context -EventName 'gate-restamp-left' -Detail @{ requestId = [string]$Row['requestId'] }
    return 'failed'
}

function Close-HostUpdateGate {
    <#
    .SYNOPSIS
        Close the gate as this controller, or take over the owner of a gate
        this update already closed.
    .OUTPUTS
        [string] closed or busy.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    if (-not $PSCmdlet.ShouldProcess([string]$Row['requestId'], (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return 'busy' }
    for ($try = 0; $try -lt 2; $try++) {
        $gate = Get-HostUpdateGate -Context $Context -Row $Row
        if ($gate.State -eq 'open') {
            $write = Set-HostUpdateGateRecord -Context $Context -Row $Row -State 'closed' -Gate $gate
            if ($write.Written) { return 'closed' }
            continue
        }
        if ($gate.State -in @('closed', 'recovery-pending', 'handoff') -and (Test-HostUpdateGateOwnership -Gate $gate -Row $Row)) {
            $null = Update-HostUpdateGateOwner -Context $Context -Row $Row -Confirm:$false
            return 'closed'
        }
        return 'busy'
    }
    return 'busy'
}

function Open-HostUpdateGate {
    <#
    .SYNOPSIS
        Open the gate with a compare-and-set under this update's id; this
        also revokes a handoff token an interrupted start left.
    .OUTPUTS
        [string] opened, open, not-ours or failed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    if (-not $PSCmdlet.ShouldProcess([string]$Row['requestId'], (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) { return 'failed' }
    for ($try = 0; $try -lt 2; $try++) {
        $gate = Get-HostUpdateGate -Context $Context -Row $Row
        if ($gate.State -eq 'open') { return 'open' }
        if ($gate.State -eq 'unknown') { return 'failed' }
        if (-not (Test-HostUpdateGateOwnership -Gate $gate -Row $Row)) { return 'not-ours' }
        $write = Set-HostUpdateGateRecord -Context $Context -Row $Row -State 'released' -Gate $gate
        if ($write.Written) { return 'opened' }
    }
    return 'failed'
}

# --- REGION: Step children
function Start-HostUpdateStepProcess {
    <#
    .SYNOPSIS
        Launch one step child detached, so a controller that starts again
        finds it by pid and start time.
    .PARAMETER Launch
        @{ ScriptPath; ArgumentList; WorkingDirectory; Environment;
        StdOutPath; StdErrPath; PrivateDirectory }
    .OUTPUTS
        [pscustomobject] @{ Launched; Pid; StartTimeUnixMs; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Launch)
    if (-not $PSCmdlet.ShouldProcess($Launch.ScriptPath, (Format-YurunaOperatorMessage -Key 'runner.detached_launch_action'))) {
        return [pscustomobject]@{ Launched = $false; Pid = $null; StartTimeUnixMs = $null; Reason = 'whatif' }
    }
    $start = Start-YurunaDetachedProcess -FilePath $Launch.ScriptPath -ArgumentList $Launch.ArgumentList -WorkingDirectory $Launch.WorkingDirectory `
        -Environment $Launch.Environment -StdOutPath $Launch.StdOutPath -StdErrPath $Launch.StdErrPath -PrivateDirectory $Launch.PrivateDirectory -Confirm:$false
    return [pscustomobject]@{ Launched = [bool]$start.Launched; Pid = $start.FinalPid; StartTimeUnixMs = $start.FinalStartTimeUnixMs; Reason = [string]$start.Reason }
}

function Read-HostUpdateStepResult {
    <#
    .SYNOPSIS
        A step child's result file, when it is this step's and attempt's.
    .OUTPUTS
        [hashtable] or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][int]$Attempt
    )
    try {
        $info = [System.IO.FileInfo]::new($Path)
        if (-not $info.Exists -or $info.LinkTarget -or $info.Length -gt $script:HostUpdateResultMaxBytes) { return $null }
        $result = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "Read-HostUpdateStepResult: '$Path' unreadable: $($_.Exception.Message)"
        return $null
    }
    if ($result -isnot [hashtable] -or "$($result['schemaVersion'])" -ne '1' -or [string]$result['step'] -cne $Step -or
        [string]$result['requestId'] -cne $RequestId -or "$($result['attempt'])" -ne "$Attempt" -or
        [string]$result['outcome'] -cnotin @('done', 'skipped', 'failed')) { return $null }
    return $result
}

function Get-HostUpdateWorkDirectory {
    <#
    .SYNOPSIS
        work/<requestId> under the controller root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId)
    $work = New-HostUpdatePrivateDirectory -Parent $Context.ControllerRoot -Name 'work' -Confirm:$false
    if (-not $work) { Stop-HostUpdateOperation -Reason 'work-unavailable' }
    $directory = New-HostUpdatePrivateDirectory -Parent $work -Name $RequestId -Confirm:$false
    if (-not $directory) { Stop-HostUpdateOperation -Reason 'work-unavailable' }
    return $directory
}

function Wait-HostUpdateStepChild {
    <#
    .SYNOPSIS
        Wait for a step child to end, at most to its expiry on the monotonic
        clock, then end its tree.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)]$ProcessId, [AllowNull()]$StartTimeUnixMs, [Parameter(Mandatory)][long]$ExpiryTick)
    while ($true) {
        $live = & $Context.Service.StepLiveness $ProcessId $StartTimeUnixMs
        if ($live -eq 'dead') { return }
        if ((Get-HostUpdateTick -Context $Context) -ge $ExpiryTick) {
            if ($live -eq 'alive') { & $Context.Service.StopStep $ProcessId $Context.HostType $Context.Service.Native }
            Write-HostUpdateControllerLog -Context $Context -EventName 'step-bound-reached' -Detail @{ pid = "$ProcessId" }
            return
        }
        Wait-HostUpdateInterval -Context $Context -Milliseconds 1000
    }
}

function Find-HostUpdateStepProcess {
    <#
    .SYNOPSIS
        The step children of one phase of one request, found by their
        command line.
    .DESCRIPTION
        An attempt is journaled before its child is launched and the child
        after, so a controller stopped between the two, or a launch that
        reported failure after the child was forked, leaves a child the
        journal does not name. The child's argument vector names the step
        script, the step, the request and the attempt, one token each; where
        the process table has no vector (macOS, Windows) the command line is
        split into one. The bash launcher that forks the child is not a pwsh
        process and is skipped.
    .PARAMETER Phase
        The step.
    .PARAMETER RequestId
        The host update.
    .PARAMETER ProcessTable
        A Get-YurunaProcessTable result; read when not given.
    .OUTPUTS
        [pscustomobject] @{ Pid; StartTimeUnixMs; Attempt }, one per child.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$RequestId, [psobject]$ProcessTable)
    $table = if ($ProcessTable) { $ProcessTable } else { Get-YurunaProcessTable }
    foreach ($process in @($table.Rows)) {
        $argv = Get-HostUpdateProcessArgument -Process $process
        if ($argv.Count -lt 2 -or [System.IO.Path]::GetFileName($argv[0].Replace('\', '/')) -notlike 'pwsh*') { continue }
        $named = @{}
        for ($i = 1; $i -lt $argv.Count - 1; $i++) {
            if ($argv[$i] -cin @('-File', '-Step', '-RequestId', '-Attempt') -and -not $named.ContainsKey($argv[$i])) { $named[$argv[$i]] = $argv[$i + 1] }
        }
        if ([System.IO.Path]::GetFileName(([string]$named['-File']).Replace('\', '/')) -cne 'Invoke-HostUpdateStep.ps1' -or
            [string]$named['-Step'] -cne $Phase -or [string]$named['-RequestId'] -cne $RequestId) { continue }
        $attempt = 0
        if (-not [int]::TryParse([string]$named['-Attempt'], [ref]$attempt) -or $attempt -le 0) { continue }
        [pscustomobject]@{ Pid = [int]$process.Pid; StartTimeUnixMs = $process.StartTimeUnixMs; Attempt = $attempt }
    }
}

function Resume-HostUpdateUnrecordedStep {
    <#
    .SYNOPSIS
        Adopt or end the live step children of a phase that the journal does
        not name.
    .DESCRIPTION
        The child of the journaled attempt is adopted: recorded, then waited
        for to its bound, counted from its own start. Any other child, and
        one already past its bound, is ended and must be seen dead before
        another attempt runs, so two children of one phase never run side by
        side. A child that cannot be seen dead ends the operation in place.
    .OUTPUTS
        [bool] whether the journaled attempt's child was adopted.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The journal writer and the stop service it calls gate each change.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$Attempt
    )
    $adopted = $false
    foreach ($child in @(& $Context.Service.FindStep $Phase $RequestId)) {
        if (-not $child -or (& $Context.Service.StepLiveness $child.Pid $child.StartTimeUnixMs) -eq 'dead') { continue }
        if (-not $adopted -and [int]$child.Attempt -eq $Attempt) {
            $remaining = [long]$Context.Bound[$Phase] * 1000
            $startMs = [long]0
            if ([long]::TryParse("$($child.StartTimeUnixMs)", [ref]$startMs) -and $startMs -gt 0) {
                $remaining -= [Math]::Max([long]0, (Get-HostUpdateWallClock -Context $Context) - $startMs)
            }
            if ($remaining -gt 0) {
                $expiry = (Get-HostUpdateTick -Context $Context) + $remaining
                $record = @{ pid = $child.Pid; startTimeUnixMs = $child.StartTimeUnixMs; expiryTick = $expiry; bootEpochMs = (Get-HostUpdateBootEpoch -Context $Context) }
                $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = $Phase; State = 'started'; ChildOnly = $true; Child = $record }
                Write-HostUpdateControllerLog -Context $Context -EventName 'step-adopted' -Detail @{ requestId = $RequestId; step = $Phase; attempt = "$Attempt"; recorded = 'no' }
                Wait-HostUpdateStepChild -Context $Context -ProcessId $child.Pid -StartTimeUnixMs $child.StartTimeUnixMs -ExpiryTick $expiry
                $adopted = $true
                continue
            }
        }
        Write-HostUpdateControllerLog -Context $Context -EventName 'step-unrecorded-stopped' -Detail @{ requestId = $RequestId; step = $Phase; attempt = "$($child.Attempt)" }
        & $Context.Service.StopStep $child.Pid $Context.HostType $Context.Service.Native
        $deadline = (Get-HostUpdateTick -Context $Context) + 10000
        while ((& $Context.Service.StepLiveness $child.Pid $child.StartTimeUnixMs) -ne 'dead') {
            if ((Get-HostUpdateTick -Context $Context) -ge $deadline) {
                Write-HostUpdateControllerLog -Context $Context -EventName 'step-not-stopped' -Detail @{ requestId = $RequestId; step = $Phase; pid = "$($child.Pid)" }
                Stop-HostUpdateOperation -Reason 'step-not-stopped'
            }
            Wait-HostUpdateInterval -Context $Context -Milliseconds 1000
        }
    }
    return $adopted
}

function Test-HostUpdateStepResultCurrent {
    <#
    .SYNOPSIS
        Whether a step attempt left a valid result in this boot.
    .DESCRIPTION
        A child can finish while no controller watches it. Its result is
        used instead of running the phase again, which would repeat work
        already done (a second pull would report no change, a second start
        would stop the runner it started). A result written before this boot
        describes processes that no longer run, and is not used.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][int]$Attempt)
    if ($Attempt -le 0 -or -not (Read-HostUpdateStepResult -Path $Path -Step $Phase -RequestId $RequestId -Attempt $Attempt)) { return $false }
    try { $written = [DateTimeOffset]::new([System.IO.File]::GetLastWriteTimeUtc($Path)).ToUnixTimeMilliseconds() } catch {
        Write-Verbose "Test-HostUpdateStepResultCurrent: '$Path' time unreadable: $($_.Exception.Message)"
        return $false
    }
    return ($written -ge (Get-HostUpdateBootEpoch -Context $Context) - $script:HostUpdateBootSlackMs)
}

function Invoke-HostUpdateStepPhase {
    <#
    .SYNOPSIS
        Run one phase as a step child: journal its start, launch it, wait
        to its bound and journal its outcome from the result file.
    .DESCRIPTION
        A phase whose child is still alive is waited for, not run beside it,
        also when the journal does not name it; a child that finished while
        no controller watched it is read, not run again. A child that ends
        with no result, or is ended at its bound, is
        interrupted: the phase runs again, at most three starts in all, and
        then counts as failed with step_interrupted. A recovering update's
        steps have no such limit (-Unlimited): it keeps trying on its
        backoff until it starts, is taken over or released.
    .OUTPUTS
        [pscustomobject] @{ Outcome done|skipped|failed; Reason; Action;
        Remarks; Result }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Phase,
        [string]$ScriptPath,
        [hashtable]$StartChange = @{},
        [switch]$Unlimited
    )
    if (-not $ScriptPath) { $ScriptPath = $Context.CheckoutStepScript }
    $work = Get-HostUpdateWorkDirectory -Context $Context -RequestId $RequestId
    $bound = [long]$Context.Bound[$Phase]
    while ($true) {
        $row = Get-HostUpdateRow -RequestId $RequestId
        $entry = Get-HostUpdatePhaseEntry -Row $row -Phase $Phase
        $attempt = 0
        $adopted = $false
        if ($entry -and [string]$entry['state'] -eq 'started') {
            $journaled = [int]$entry['attempts']
            if ($entry['child'] -is [System.Collections.IDictionary]) {
                $child = $entry['child']
                $sameBoot = [Math]::Abs([long]$child['bootEpochMs'] - (Get-HostUpdateBootEpoch -Context $Context)) -le $script:HostUpdateBootSlackMs
                if ($sameBoot -and (& $Context.Service.StepLiveness $child['pid'] $child['startTimeUnixMs']) -ne 'dead') {
                    Write-HostUpdateControllerLog -Context $Context -EventName 'step-adopted' -Detail @{ requestId = $RequestId; step = $Phase; attempt = "$journaled" }
                    Wait-HostUpdateStepChild -Context $Context -ProcessId $child['pid'] -StartTimeUnixMs $child['startTimeUnixMs'] -ExpiryTick ([long]$child['expiryTick'])
                    $adopted = $true
                }
            }
            if (-not $adopted) { $adopted = Resume-HostUpdateUnrecordedStep -Context $Context -RequestId $RequestId -Phase $Phase -Attempt $journaled }
            if (-not $adopted) {
                $adopted = Test-HostUpdateStepResultCurrent -Context $Context -Path ([System.IO.Path]::Combine($work, "$Phase.$journaled.result.json")) `
                    -Phase $Phase -RequestId $RequestId -Attempt $journaled
            }
            if ($adopted) { $attempt = $journaled }
        }
        if (-not $adopted) {
            if (-not $Unlimited -and $entry -and [int]$entry['attempts'] -ge $script:HostUpdatePhaseMaxStart) {
                $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = $Phase; State = 'finished'; Outcome = 'failed'; Reason = 'step_interrupted' }
                return [pscustomobject]@{ Outcome = 'failed'; Reason = 'step_interrupted'; Action = $null; Remarks = [string[]]@(); Result = $null }
            }
            $change = @{ Phase = $Phase; State = 'started' }
            foreach ($key in $StartChange.Keys) { $change[$key] = $StartChange[$key] }
            $attempt = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change $change
            $resultPath = [System.IO.Path]::Combine($work, "$Phase.$attempt.result.json")
            $arguments = @('-Step', $Phase, '-RequestId', $RequestId, '-Attempt', "$attempt", '-ResultPath', $resultPath, '-RepoRoot', $Context.Checkout)
            if ($Phase -eq 'start_runner') { $arguments += @('-ControllerPid', "$($Context.ControllerPid)") }
            $launch = @{
                ScriptPath = $ScriptPath; ArgumentList = [string[]]$arguments; WorkingDirectory = $Context.Checkout
                Environment = @{ YURUNA_RUNTIME_DIR = [string]$row['runtimeDir'] }
                StdOutPath = [System.IO.Path]::Combine($work, "$Phase.$attempt.out"); StdErrPath = [System.IO.Path]::Combine($work, "$Phase.$attempt.err")
                PrivateDirectory = $work; Step = $Phase; Attempt = $attempt; ResultPath = $resultPath; RequestId = $RequestId
            }
            $started = & $Context.Service.StartStep $launch
            if ($started.Launched) {
                $expiry = (Get-HostUpdateTick -Context $Context) + $bound * 1000
                $child = @{ pid = $started.Pid; startTimeUnixMs = $started.StartTimeUnixMs; expiryTick = $expiry; bootEpochMs = (Get-HostUpdateBootEpoch -Context $Context) }
                $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = $Phase; State = 'started'; ChildOnly = $true; Child = $child }
                Wait-HostUpdateStepChild -Context $Context -ProcessId $started.Pid -StartTimeUnixMs $started.StartTimeUnixMs -ExpiryTick $expiry
            } else {
                Write-HostUpdateControllerLog -Context $Context -EventName 'step-launch-failed' -Detail @{ requestId = $RequestId; step = $Phase; reason = $started.Reason }
                # The launcher can fail after it forked the child.
                $null = Resume-HostUpdateUnrecordedStep -Context $Context -RequestId $RequestId -Phase $Phase -Attempt $attempt
            }
        }
        $result = Read-HostUpdateStepResult -Path ([System.IO.Path]::Combine($work, "$Phase.$attempt.result.json")) -Step $Phase -RequestId $RequestId -Attempt $attempt
        if (-not $result) {
            Write-HostUpdateControllerLog -Context $Context -EventName 'step-interrupted' -Detail @{ requestId = $RequestId; step = $Phase; attempt = "$attempt" }
            $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = $Phase; State = 'finished'; Outcome = 'interrupted' }
            continue
        }
        $outcome = [string]$result['outcome']
        $reason = Get-HostUpdateTokenValue -Value $result['reason'] -Allowed $script:HostUpdateReasonToken
        if ($outcome -eq 'failed' -and -not $reason) { $reason = 'step_interrupted' }
        $remarks = Get-HostUpdateTokenList -Value $result['remarks'] -Allowed $script:HostUpdateRemarkToken
        $change = @{ Phase = $Phase; State = 'finished'; Outcome = $outcome; Result = $result }
        if ($reason) { $change.Reason = $reason }
        if ($remarks.Count -gt 0) { $change.Remarks = $remarks }
        if ($result['reclaimed'] -is [System.Collections.IDictionary]) { $change.Reclaimed = $result['reclaimed'] }
        if ($result['commit'] -is [System.Collections.IDictionary]) { $change.Commit = $result['commit'] }
        $console = Get-HostUpdateTokenValue -Value $result['runnerConsole'] -Allowed @('tmux', 'window', 'none')
        if ($console) { $change.RunnerConsole = $console }
        if ($Phase -eq 'update_source' -and $outcome -eq 'done' -and $result['commit'] -is [System.Collections.IDictionary]) {
            # An earlier attempt may already have moved the checkout: compare
            # with the commit the journal recorded first.
            $journaledCommit = (Get-HostUpdateRowBlock -Row (Get-HostUpdateRow -RequestId $RequestId))['commit']
            $before = if ($journaledCommit -is [System.Collections.IDictionary] -and $journaledCommit['before']) { [string]$journaledCommit['before'] } else { [string]$result['commit']['before'] }
            if ($before -cne [string]$result['commit']['after']) { $change.Mutated = $true }
        }
        $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change $change
        return [pscustomobject]@{
            Outcome = $outcome; Reason = $reason; Remarks = $remarks; Result = $result
            Action = Get-HostUpdateTokenValue -Value $result['operatorAction'] -Allowed $script:HostUpdateActionToken
        }
    }
}

# --- REGION: Snapshot replacement
function Compare-HostUpdateSnapshot {
    <#
    .SYNOPSIS
        Compare the running snapshot with the checkout and stage the
        checkout's snapshot when it differs.
    .DESCRIPTION
        A controller never starts an operation on a snapshot older than the
        checkout it runs steps from. A checkout whose snapshot was rejected
        or does not parse is remembered and not copied again.
    .OUTPUTS
        [pscustomobject] @{ Action same|staged|cannot-stage; ProtocolDiffers; Hash16 }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $checkoutProtocol = Get-HostUpdateProtocolVersion -RepoRoot $Context.Checkout
    $protocolDiffers = $checkoutProtocol -ne [int]$Context.Protocol
    try { $manifest = Get-HostUpdateSnapshotManifest -SourceRoot $Context.Checkout } catch {
        Write-HostUpdateControllerLog -Context $Context -EventName 'checkout-unreadable' -Detail @{ reason = 'manifest' }
        return [pscustomobject]@{ Action = 'cannot-stage'; ProtocolDiffers = $protocolDiffers; Hash16 = $null }
    }
    if ($manifest.Hash16 -ceq $Context.Snapshot -and -not $protocolDiffers) {
        return [pscustomobject]@{ Action = 'same'; ProtocolDiffers = $false; Hash16 = $manifest.Hash16 }
    }
    $known = $Context.StageFailed[$manifest.Hash16]
    if (-not $known -and (Get-HostUpdateRejected -ControllerRoot $Context.ControllerRoot) -ccontains $manifest.Hash16) { $known = 'rejected' }
    if (-not $known) {
        $staged = New-HostUpdateSnapshot -SourceRoot $Context.Checkout -ControllerRoot $Context.ControllerRoot -Confirm:$false
        if ($staged.Reason -in @('staged', 'exists') -and $staged.Hash16 -cne $Context.Snapshot) {
            if (Write-HostUpdateControllerCurrent -ControllerRoot $Context.ControllerRoot -Current $staged.Hash16 -Previous $Context.Snapshot -Checkout $Context.Checkout -Confirm:$false) {
                $null = Remove-HostUpdateStaleSnapshot -ControllerRoot $Context.ControllerRoot -Keep @($staged.Hash16, $Context.Snapshot) -Confirm:$false
                Write-HostUpdateControllerLog -Context $Context -EventName 'snapshot-staged' -Detail @{ snapshot = $staged.Hash16; previous = $Context.Snapshot }
                return [pscustomobject]@{ Action = 'staged'; ProtocolDiffers = $protocolDiffers; Hash16 = $staged.Hash16 }
            }
            $known = 'io-error'
        } elseif ($staged.Reason -in @('staged', 'exists')) {
            return [pscustomobject]@{ Action = 'same'; ProtocolDiffers = $protocolDiffers; Hash16 = $staged.Hash16 }
        } else {
            $known = $staged.Reason
        }
        # An io-error may clear; a rejected or unparseable tree never changes
        # under its hash.
        if ($known -ne 'io-error') { $Context.StageFailed[$manifest.Hash16] = $known }
        Write-HostUpdateControllerLog -Context $Context -EventName 'snapshot-not-staged' -Detail @{ snapshot = $manifest.Hash16; reason = $known }
    }
    return [pscustomobject]@{ Action = 'cannot-stage'; ProtocolDiffers = $protocolDiffers; Hash16 = $manifest.Hash16 }
}

# --- REGION: Operation
function Complete-HostUpdateOperation {
    <#
    .SYNOPSIS
        Write the verdict, opening the gate first: no terminal verdict is
        written with the gate closed. Obligations still armed other than
        the runner become debt.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The journal and gate writers it calls gate each change with ShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][string]$Action,
        [string]$Reason
    )
    $row = Get-HostUpdateRow -RequestId $RequestId
    if ((Get-HostUpdateArmedObligation -Row $row) -ccontains 'gate') {
        $open = Open-HostUpdateGate -Context $Context -Row $row -Confirm:$false
        if ($open -eq 'failed') {
            Write-HostUpdateControllerLog -Context $Context -EventName 'gate-not-opened' -Detail @{ requestId = $RequestId }
            Stop-HostUpdateOperation -Reason 'gate-not-opened'
        }
        Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'gate' -State 'discharged' -Evidence 'gate-open'
    }
    $armed = Get-HostUpdateArmedObligation -Row (Get-HostUpdateRow -RequestId $RequestId)
    $debt = @($armed | Where-Object { $_ -in @('listener', 'elevation') })
    $arguments = @{
        RequestId = $RequestId; ControllerPid = $Context.ControllerPid; Verdict = $Verdict; OperatorAction = $Action
        UtcNow = $Context.Service.UtcNow; Confirm = $false
    }
    if ($Reason) { $arguments.Reason = $Reason }
    if ($debt.Count -gt 0) { $arguments.Debt = [string[]]$debt }
    $write = Complete-HostUpdate @arguments
    if (-not $write.Written) {
        Write-HostUpdateControllerLog -Context $Context -EventName 'journal-write-failed' -Detail @{ requestId = $RequestId; verdict = $Verdict; reason = $write.Reason }
        Stop-HostUpdateOperation -Reason 'journal-write-failed'
    }
    Write-HostUpdateControllerLog -Context $Context -EventName 'verdict' -Detail @{ requestId = $RequestId; verdict = $Verdict; reason = $Reason }
    $row = Get-HostUpdateRequest -RequestId $RequestId
    if ($row) {
        Set-HostUpdateLastVerdict -Context $Context -Row $row
        $hash = Write-HostUpdatePublicState -Context $Context -Row $row -Confirm:$false
        if ($hash) { $Context.LastProjection[$RequestId] = $hash }
        Remove-HostUpdateInstallerCopy -Row $row -Confirm:$false
    }
    Exit-HostUpdateLifetimeLock -Context $Context
}

function Set-HostUpdateLastVerdict {
    <#
    .SYNOPSIS
        Remember a terminal row whose runner was started, for the
        first-cycle note.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the in-memory context only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    $update = Get-HostUpdateRowBlock -Row $Row
    if ([string]$update['verdict'] -notin @('updated', 'updated_with_remarks', 'failed_restored')) { return }
    $start = Get-HostUpdatePhaseEntry -Row $Row -Phase 'start_runner'
    if (-not $start -or [string]$start['outcome'] -ne 'done') { return }
    $since = [long]0
    try { $since = [DateTimeOffset]::Parse([string]$start['startedUtc'], [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() } catch {
        Write-Verbose "Set-HostUpdateLastVerdict: start time unreadable: $($_.Exception.Message)"
        return
    }
    $terminal = [long]0
    [void][long]::TryParse("$($Row['terminalUnixMs'])", [ref]$terminal)
    $Context.LastVerdict = @{ RequestId = [string]$Row['requestId']; RuntimeDir = [string]$Row['runtimeDir']; SinceUnixMs = $since; TerminalUnixMs = $terminal; FirstCycle = 'pending' }
}

function Get-HostUpdateFailureAction {
    <#
    .SYNOPSIS
        The operator action of a refusal: the step's own, else the one its
        reason implies.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Reason, [AllowNull()][string]$Action)
    if ($Action -and $Action -cin $script:HostUpdateActionToken) { return $Action }
    if ($Reason -and $script:HostUpdateReasonAction.ContainsKey($Reason)) { return $script:HostUpdateReasonAction[$Reason] }
    return 'act_at_host'
}

function Test-HostUpdateInherited {
    <#
    .SYNOPSIS
        Whether a row took over armed obligations from a recovering update:
        such a row is touched, so a refusal restores instead of leaving the
        runner stopped.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    return ([bool](Get-HostUpdateRowBlock -Row $Row)['inheritedFrom']) -and (Get-HostUpdateArmedObligation -Row $Row).Count -gt 0
}

function Resolve-HostUpdateRefusal {
    <#
    .SYNOPSIS
        End an update refused in the preflight or drain phase: the verdict,
        or restore for a row that inherited armed obligations.
    #>
    [CmdletBinding()]
    [OutputType([object], [int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Reason,
        [AllowNull()][string]$Action
    )
    $row = Get-HostUpdateRow -RequestId $RequestId
    if (Test-HostUpdateInherited -Row $row) { return (Invoke-HostUpdateRestore -Context $Context -RequestId $RequestId -Reason $Reason) }
    $verdict = if ($Reason -eq 'drain_timeout') { 'drain_timeout' } else { 'refused' }
    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict $verdict -Action (Get-HostUpdateFailureAction -Reason $Reason -Action $Action) -Reason $Reason
    return $null
}

function Test-HostUpdateParkedCycle {
    <#
    .SYNOPSIS
        Whether the cycle is parked on "Pause after cycle".
    .DESCRIPTION
        No durable marker says so; all three must hold: the pause flag, a
        live owned cycle process, and the cycle's last event a cycle-scope
        sequence_paused. Anything less is not parked, because a false
        positive would end a running cycle.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RuntimeDir, [Parameter(Mandatory)][string]$Checkout, [AllowNull()]$LaunchRecord)
    if (-not [System.IO.File]::Exists([System.IO.Path]::Combine($RuntimeDir, 'control.cycle-pause'))) { return $false }
    if ((Read-YurunaRunnerCycleRecord -RuntimeDir $RuntimeDir).State -ne 'AliveOwned') { return $false }
    try {
        $status = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($RuntimeDir, 'status.json')) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $url = [string]$status['cycleFolderUrl']
        if ($url -notmatch '\Alog/([A-Za-z0-9._-]+)/?\z') { return $false }
        $leaf = $Matches[1]
        $logDir = $null
        if ($LaunchRecord -is [System.Collections.IDictionary] -and $LaunchRecord['environment'] -is [System.Collections.IDictionary]) { $logDir = [string]$LaunchRecord['environment']['YURUNA_LOG_DIR'] }
        if (-not $logDir) { $logDir = [System.IO.Path]::Combine($Checkout, 'test', 'status', 'log') }
        $path = [System.IO.Path]::Combine($logDir, $leaf, 'cycle.events.ndjson')
        if (-not [System.IO.File]::Exists($path)) { return $false }
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $length = [Math]::Min([long]65536, $stream.Length)
            $null = $stream.Seek(-$length, [System.IO.SeekOrigin]::End)
            $buffer = [byte[]]::new($length)
            $read = $stream.Read($buffer, 0, $length)
            $tail = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        } finally { $stream.Dispose() }
        $lines = @($tail -split "`n" | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { return $false }
        $last = $lines[-1] | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        return ([string]$last['event'] -ceq 'sequence_paused' -and [string]$last['pauseScope'] -ceq 'cycle')
    } catch {
        Write-Verbose "Test-HostUpdateParkedCycle: $($_.Exception.Message)"
        return $false
    }
}

function Get-HostUpdateResidentState {
    <#
    .SYNOPSIS
        The resident runner's record state in a runtime directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir, [Parameter(Mandatory)][string]$Checkout)
    $record = Get-YurunaRunnerRecordState -PidFile ([System.IO.Path]::Combine($RuntimeDir, 'runner.pid')) -StartFile ([System.IO.Path]::Combine($RuntimeDir, 'runner.start')) `
        -ExpectedScriptPath @([System.IO.Path]::Combine($Checkout, 'test', 'Start-TestRunner.ps1'))
    return [string]$record.State
}

function Add-HostUpdateDrainLog {
    <#
    .SYNOPSIS
        One line per drain check in the work folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][string]$Line)
    try {
        $work = Get-HostUpdateWorkDirectory -Context $Context -RequestId $RequestId
        $stamp = ([DateTimeOffset](& $Context.Service.UtcNow)).UtcDateTime.ToString('o')
        [System.IO.File]::AppendAllText([System.IO.Path]::Combine($work, 'drain.log'), "$stamp $Line`n")
    } catch {
        Write-Verbose "Add-HostUpdateDrainLog: $($_.Exception.Message)"
    }
}

function Invoke-HostUpdateDrain {
    <#
    .SYNOPSIS
        The drain phase: close the gate as this controller and wait for the running
        cycle to end, from the journaled start.
    .OUTPUTS
        [pscustomobject] @{ Outcome done|failed; Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId)
    $answer = {
        param([string]$Outcome, [string]$Reason)
        $change = @{ Phase = 'drain'; State = 'finished'; Outcome = $Outcome }
        if ($Reason) { $change.Reason = $Reason }
        $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change $change
        [pscustomobject]@{ Outcome = $Outcome; Reason = $Reason }
    }
    $row = Get-HostUpdateRow -RequestId $RequestId
    $entry = Get-HostUpdatePhaseEntry -Row $row -Phase 'drain'
    if ($entry -and [int]$entry['attempts'] -ge $script:HostUpdatePhaseMaxStart) { return (& $answer 'failed' 'step_interrupted') }
    $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{
        Phase = 'drain'; State = 'started'; Drain = @{ startedUnixMs = (Get-HostUpdateWallClock -Context $Context) }
    }
    $row = Get-HostUpdateRow -RequestId $RequestId
    $runtime = [string]$row['runtimeDir']
    $gate = Get-HostUpdateGate -Context $Context -Row $row
    if ($gate.State -ne 'open' -and -not (Test-HostUpdateGateOwnership -Gate $gate -Row $row)) { return (& $answer 'failed' 'gate_busy') }
    Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'gate' -State 'armed'
    if ((Close-HostUpdateGate -Context $Context -Row $row -Confirm:$false) -ne 'closed') {
        # Nothing was taken away: the gate was never this update's.
        Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'gate' -State 'discharged' -Evidence 'not-closed'
        return (& $answer 'failed' 'gate_busy')
    }
    if ((Get-YurunaOneShotLeaseState -RuntimeDir $runtime).State -eq 'Held') { return (& $answer 'failed' 'one_shot_active') }
    $update = Get-HostUpdateRowBlock -Row $row
    if ([string]$update['request']['drain'] -eq 'now') { return (& $answer 'done' $null) }
    $startedMs = [long]$update['drain']['startedUnixMs']
    $limitMs = [long]$update['request']['drainSeconds'] * 1000
    $launch = (Read-YurunaRunnerLaunchRecord -RuntimeDir $runtime -PrivateRoot $Context.PrivateRoot).Record
    $cycleFree = 0
    $parked = 0
    while ($true) {
        if (Get-DiagnosticVmPreservation -RuntimeDir $runtime) {
            Add-HostUpdateDrainLog -Context $Context -RequestId $RequestId -Line 'diagnostic-hold'
            return (& $answer 'failed' 'diagnostic_hold')
        }
        $resident = Get-HostUpdateResidentState -RuntimeDir $runtime -Checkout $Context.Checkout
        if ($resident -ne 'AliveOwned') {
            Add-HostUpdateDrainLog -Context $Context -RequestId $RequestId -Line "resident=$resident done"
            return (& $answer 'done' $null)
        }
        $cycle = [string](Read-YurunaRunnerCycleRecord -RuntimeDir $runtime).State
        $cycleFree = if ($cycle -in @('Missing', 'DeadOrRecycled')) { $cycleFree + 1 } else { 0 }
        $parked = if (Test-HostUpdateParkedCycle -RuntimeDir $runtime -Checkout $Context.Checkout -LaunchRecord $launch) { $parked + 1 } else { 0 }
        Add-HostUpdateDrainLog -Context $Context -RequestId $RequestId -Line "resident=$resident cycle=$cycle cycleFree=$cycleFree parked=$parked"
        if ($cycleFree -ge 2 -or $parked -ge 2) { return (& $answer 'done' $null) }
        if ((Get-HostUpdateWallClock -Context $Context) - $startedMs -ge $limitMs) { return (& $answer 'failed' 'drain_timeout') }
        Wait-HostUpdateInterval -Context $Context -Milliseconds 5000
    }
}

function Get-HostUpdateRunnerPlan {
    <#
    .SYNOPSIS
        What the start_runner phase will do, decided before anything is stopped.
    .OUTPUTS
        [hashtable] @{ start; basis }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    if ((Get-HostUpdateArmedObligation -Row $Row) -ccontains 'runner') { return @{ start = $true; basis = 'inherited' } }
    $runtime = [string]$Row['runtimeDir']
    if ((Get-HostUpdateResidentState -RuntimeDir $runtime -Checkout $Context.Checkout) -eq 'AliveOwned') { return @{ start = $true; basis = 'resident-alive' } }
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $runtime -PrivateRoot $Context.PrivateRoot
    if (-not $launch.Found) { return @{ start = $false; basis = 'no-launch-record' } }
    if ($launch.Record -is [System.Collections.IDictionary] -and [bool]$launch.Record['cleanExit']) { return @{ start = $false; basis = 'clean-exit' } }
    return @{ start = $true; basis = 'unclean-exit' }
}

function Test-HostUpdateProtocolAfterSource {
    <#
    .SYNOPSIS
        After the source update: replace the snapshot when the checkout's
        protocol number differs from this controller's.
    .OUTPUTS
        [pscustomobject] @{ Disposition same|exit|cannot-stage }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context, [AllowNull()]$Protocol)
    $number = -1
    if ($null -eq $Protocol -or -not [int]::TryParse("$Protocol", [ref]$number)) { $number = Get-HostUpdateProtocolVersion -RepoRoot $Context.Checkout }
    if ($number -eq [int]$Context.Protocol) { return [pscustomobject]@{ Disposition = 'same' } }
    $compare = Compare-HostUpdateSnapshot -Context $Context
    if ($compare.Action -eq 'staged') { return [pscustomobject]@{ Disposition = 'exit' } }
    return [pscustomobject]@{ Disposition = 'cannot-stage' }
}

function Invoke-HostUpdateStartRunner {
    <#
    .SYNOPSIS
        The start_runner phase, also as the last step of restore: start the
        runner the plan asks for, or open the gate when it asks for none.
    .OUTPUTS
        [pscustomobject] @{ Outcome done|none|failed; Reason; Action }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId, [switch]$Unlimited)
    $row = Get-HostUpdateRow -RequestId $RequestId
    $plan = (Get-HostUpdateRowBlock -Row $row)['runnerPlan']
    $wanted = ((Get-HostUpdateArmedObligation -Row $row) -ccontains 'runner') -or ($plan -is [System.Collections.IDictionary] -and [bool]$plan['start'])
    if (-not $wanted) { return [pscustomobject]@{ Outcome = 'none'; Reason = $null; Action = $null } }
    $step = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase 'start_runner' -Unlimited:$Unlimited
    if ($step.Outcome -eq 'failed') { return [pscustomobject]@{ Outcome = 'failed'; Reason = $step.Reason; Action = $step.Action } }
    $row = Get-HostUpdateRow -RequestId $RequestId
    $open = Open-HostUpdateGate -Context $Context -Row $row -Confirm:$false
    if ($open -eq 'failed') { Stop-HostUpdateOperation -Reason 'gate-not-opened' }
    Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'runner' -State 'discharged' -Evidence 'runner-ready'
    return [pscustomobject]@{ Outcome = 'done'; Reason = $null; Action = $null }
}

function Get-HostUpdateRecoveringAction {
    <#
    .SYNOPSIS
        What a recovering update asks of the operator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Reason, [AllowNull()][string]$Action)
    if ($Action -cin @('repair_checkout', 'act_at_host', 'release')) { return $Action }
    if ($Reason -cin @('config_gate_failed', 'console_state_unknown')) { return 'act_at_host' }
    return 'repair_checkout'
}

function Get-HostUpdateFirstFailure {
    <#
    .SYNOPSIS
        The reason of the first failed phase of a row, in phase order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    foreach ($phase in $script:HostUpdateFullPhase) {
        $entry = Get-HostUpdatePhaseEntry -Row $Row -Phase $phase
        if ($entry -and [string]$entry['outcome'] -eq 'failed' -and $entry['reason'] -and $phase -ne 'start_listener') { return [string]$entry['reason'] }
    }
    $reason = [string](Get-HostUpdateRowBlock -Row $Row)['reason']
    if ($reason -cin $script:HostUpdateReasonToken) { return $reason }
    return 'step_interrupted'
}

function Invoke-HostUpdateRestore {
    <#
    .SYNOPSIS
        Give back what the update took away: the transient units and the
        sudo rule of a privileged phase, the listener, then the runner on the
        checkout as it is, or the gate when no runner is to start.
    .DESCRIPTION
        Journaled like a phase, and each step acts only on an obligation
        that is still armed, so running it again is safe.
    #>
    [CmdletBinding()]
    [OutputType([object], [int])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][string]$Reason)
    $row = Get-HostUpdateRow -RequestId $RequestId
    $entry = Get-HostUpdatePhaseEntry -Row $row -Phase 'restore'
    if ($entry -and [string]$entry['state'] -ne 'finished' -and [int]$entry['attempts'] -ge $script:HostUpdatePhaseMaxStart) {
        $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'restore'; State = 'finished'; Outcome = 'failed'; Reason = 'step_interrupted' }
        return (Invoke-HostUpdateRecovering -Context $Context -RequestId $RequestId -Reason 'step_interrupted' -Action $null -Enter)
    }
    $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'restore'; State = 'started' }
    # The transient units end and the sudo rule goes first: nothing of a
    # privileged phase may outlive the restore.
    if ((Get-HostUpdateArmedObligation -Row (Get-HostUpdateRow -RequestId $RequestId)) -ccontains 'elevation') {
        $null = Clear-HostUpdateElevation -Context $Context -RequestId $RequestId
    }
    if ((Get-HostUpdateArmedObligation -Row (Get-HostUpdateRow -RequestId $RequestId)) -ccontains 'listener') {
        $listener = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase 'start_listener'
        if ($listener.Outcome -ne 'failed') { Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'listener' -State 'discharged' -Evidence 'listener-ready' }
    }
    $runner = Invoke-HostUpdateStartRunner -Context $Context -RequestId $RequestId
    if ($runner.Outcome -eq 'failed') {
        $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'restore'; State = 'finished'; Outcome = 'failed'; Reason = $runner.Reason }
        return (Invoke-HostUpdateRecovering -Context $Context -RequestId $RequestId -Reason $runner.Reason -Action $runner.Action -Enter)
    }
    $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'restore'; State = 'finished'; Outcome = 'done' }
    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'failed_restored' -Action 'read_remarks' -Reason $Reason
    return $null
}

function Invoke-HostUpdateRelease {
    <#
    .SYNOPSIS
        Honor a release mark: open the gate, dispose the gate and the
        runner for the operator who asked, and end as released.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId)
    Enter-HostUpdateLifetimeLock -Context $Context
    $row = Get-HostUpdateRow -RequestId $RequestId
    $release = (Get-HostUpdateRowBlock -Row $row)['release']
    $actor = if ($release -is [System.Collections.IDictionary] -and $release['by']) { [string]$release['by'] } else { [Environment]::UserName }
    if ((Get-HostUpdateArmedObligation -Row $row) -ccontains 'elevation') { $null = Clear-HostUpdateElevation -Context $Context -RequestId $RequestId }
    $open = Open-HostUpdateGate -Context $Context -Row $row -Confirm:$false
    if ($open -eq 'failed') { Stop-HostUpdateOperation -Reason 'gate-not-opened' }
    foreach ($id in @('gate', 'runner')) {
        Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId $id -State 'disposed' -Actor $actor -Evidence 'released'
    }
    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'released' -Action 'none'
}

function Invoke-HostUpdateRecovering {
    <#
    .SYNOPSIS
        Keep trying to start the runner on a backoff of 5, 10, 15, 15...
        minutes, with the lifetime lock released between attempts.
    .DESCRIPTION
        Each attempt runs the source update with the snapshot's own step
        script, which predates a bad commit, then the protocol check, then
        the start steps from the checkout: the listener when the walk never
        finished the start_listener phase and nothing was restored, then the runner. A release
        mark ends it as released; a takeover by a new update ends it here.
    .OUTPUTS
        [object] $null, or the exit code 75 after a snapshot replacement.
    #>
    [CmdletBinding()]
    [OutputType([object], [int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [AllowNull()][string]$Reason,
        [AllowNull()][string]$Action,
        [switch]$Enter
    )
    $schedule = {
        param([string]$Why, [string]$What)
        $row = Get-HostUpdateRow -RequestId $RequestId
        $recover = Get-HostUpdatePhaseEntry -Row $row -Phase 'recover'
        $attempts = if ($recover) { [int]$recover['attempts'] } else { 0 }
        $minutes = $script:HostUpdateRecoverBackoffMinutes[[Math]::Min($attempts, $script:HostUpdateRecoverBackoffMinutes.Count - 1)]
        $next = (Get-HostUpdateWallClock -Context $Context) + [long]$minutes * 60000
        $why = if ($Why -cin $script:HostUpdateReasonToken) { $Why } else { 'runner_start_failed' }
        $write = Set-HostUpdateRecovering -RequestId $RequestId -ControllerPid $Context.ControllerPid -OperatorAction (Get-HostUpdateRecoveringAction -Reason $why -Action $What) `
            -Reason $why -NextUnixMs $next -UtcNow $Context.Service.UtcNow -Confirm:$false
        if (-not $write.Written) { Stop-HostUpdateOperation -Reason 'journal-write-failed' }
        Write-HostUpdateControllerLog -Context $Context -EventName 'recovering' -Detail @{ requestId = $RequestId; reason = $why; minutes = "$minutes" }
        $fresh = Get-HostUpdateRequest -RequestId $RequestId
        if ($fresh) { $null = Write-HostUpdatePublicState -Context $Context -Row $fresh -Confirm:$false }
        Exit-HostUpdateLifetimeLock -Context $Context
    }
    if ($Enter) { & $schedule $Reason $Action } else { Exit-HostUpdateLifetimeLock -Context $Context }
    $lastCheck = [long]::MinValue
    while ($true) {
        $tick = Get-HostUpdateTick -Context $Context
        if ($lastCheck -eq [long]::MinValue -or $tick - $lastCheck -ge 2000) {
            $lastCheck = $tick
            $row = Get-HostUpdateRequest -RequestId $RequestId
            if (-not $row -or [string]$row['state'] -ne 'recovery-pending') {
                Write-HostUpdateControllerLog -Context $Context -EventName 'recovering-ended' -Detail @{ requestId = $RequestId; state = if ($row) { [string]$row['state'] } else { 'gone' } }
                return $null
            }
            $update = Get-HostUpdateRowBlock -Row $row
            if ($update['release'] -is [System.Collections.IDictionary]) { Invoke-HostUpdateRelease -Context $Context -RequestId $RequestId; return $null }
            $next = [long]0
            if ($update['recovering'] -is [System.Collections.IDictionary]) { [void][long]::TryParse("$($update['recovering']['nextUnixMs'])", [ref]$next) }
            if ((Get-HostUpdateWallClock -Context $Context) -ge $next) {
                Enter-HostUpdateLifetimeLock -Context $Context
                $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'recover'; State = 'started' }
                $source = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase 'update_source' -ScriptPath $Context.SnapshotStepScript -Unlimited
                if ($source.Outcome -eq 'failed') {
                    $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'recover'; State = 'finished'; Outcome = 'failed'; Reason = $source.Reason }
                    & $schedule $source.Reason $null
                    continue
                }
                $protocol = Test-HostUpdateProtocolAfterSource -Context $Context -Protocol $source.Result['protocol']
                if ($protocol.Disposition -eq 'exit') { return 75 }
                if ($protocol.Disposition -eq 'cannot-stage') {
                    $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'recover'; State = 'finished'; Outcome = 'failed'; Reason = 'protocol_mismatch' }
                    & $schedule 'protocol_mismatch' 'repair_checkout'
                    continue
                }
                $row = Get-HostUpdateRow -RequestId $RequestId
                $listenerEntry = Get-HostUpdatePhaseEntry -Row $row -Phase 'start_listener'
                if (-not (Get-HostUpdatePhaseEntry -Row $row -Phase 'restore') -and -not ($listenerEntry -and [string]$listenerEntry['state'] -eq 'finished')) {
                    $listener = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase 'start_listener' -Unlimited
                    if ($listener.Outcome -eq 'failed') { Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'listener' -State 'armed' }
                    elseif ((Get-HostUpdateArmedObligation -Row (Get-HostUpdateRow -RequestId $RequestId)) -ccontains 'listener') {
                        Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'listener' -State 'discharged' -Evidence 'listener-ready'
                    }
                }
                $start = Invoke-HostUpdateStartRunner -Context $Context -RequestId $RequestId -Unlimited
                if ($start.Outcome -eq 'failed') {
                    $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'recover'; State = 'finished'; Outcome = 'failed'; Reason = $start.Reason }
                    & $schedule $start.Reason $start.Action
                    continue
                }
                $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'recover'; State = 'finished'; Outcome = 'done' }
                $row = Get-HostUpdateRow -RequestId $RequestId
                $restored = $null -ne (Get-HostUpdatePhaseEntry -Row $row -Phase 'restore')
                if ($restored) {
                    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'failed_restored' -Action 'read_remarks' -Reason (Get-HostUpdateFirstFailure -Row $row)
                } elseif ($start.Outcome -eq 'none') {
                    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'updated_not_started' -Action 'start_runner'
                } else {
                    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'updated_with_remarks' -Action 'read_remarks'
                }
                return $null
            }
        }
        Wait-HostUpdateInterval -Context $Context -Milliseconds 1000
    }
}

function Stop-HostUpdateListenerProcess {
    <#
    .SYNOPSIS
        Stop the listener by its pid record, with the identity check, and
        wait for it to exit.
    .DESCRIPTION
        server.pid has no start-time sidecar, so the classifier dates it by
        its write time and calls a healthy listener, which started before the
        write, Unknown (no-exact-identity). Such a process is the listener
        when its command line names this runtime's generated server script,
        the rule Get-StatusServerOwnership applies; nothing else is stopped.
    .OUTPUTS
        [bool] no owned listener is alive afterwards.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $script = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RuntimeDir, '.status-service.ps1'))
    $record = Get-YurunaRunnerRecordState -PidFile ([System.IO.Path]::Combine($RuntimeDir, 'server.pid')) -MtimeIdentity -ExpectedScriptPath @($script)
    $owned = [string]$record.State -eq 'AliveOwned'
    if (-not $owned -and [string]$record.State -eq 'Unknown' -and [string]$record.Reason -eq 'no-exact-identity' -and $record.Row) {
        $commandLine = [string]$record.Row.CommandLine
        $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
        $owned = -not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine.IndexOf($script, $comparison) -ge 0
    }
    if (-not $owned -or -not $record.Pid) { return $true }
    if (-not $PSCmdlet.ShouldProcess("$($record.Pid)", (Format-YurunaOperatorMessage -Key 'runner.host_update_elevation_action'))) { return $false }
    $null = Stop-YurunaProcessTree -ProcessId ([int]$record.Pid) -Confirm:$false
    $deadline = [Environment]::TickCount64 + $script:HostUpdateListenerStopMs
    while ([Environment]::TickCount64 -lt $deadline) {
        if ((Get-YurunaProcessIdentityLiveness -ProcessId $record.Pid -StartTimeUnixMs $record.LiveStartTimeUnixMs) -eq 'dead') { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Stop-HostUpdateListener {
    <#
    .SYNOPSIS
        Arm the listener obligation with the time it is expected back, then
        stop the listener: before a restart of the controller on a new
        PowerShell, and before the PowerShell upgrade on Windows.
    .PARAMETER After
        The phase the stop follows; the expected time is the sum of the
        bounds of the phases from it to the listener's start.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The journal writer and the stop service it calls gate each change.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][string]$After)
    $row = Get-HostUpdateRow -RequestId $RequestId
    $phases = Get-HostUpdateScopePhase -Scope ([string](Get-HostUpdateRowBlock -Row $row)['request']['scope'])
    $seconds = 0
    for ($i = [array]::IndexOf($phases, $After); $i -ge 0 -and $i -lt $phases.Count -and $phases[$i] -ne 'start_runner'; $i++) {
        if ($phases[$i] -ne $After) { $seconds += [int]$Context.Bound[$phases[$i]] }
    }
    if ($After -eq 'upgrade_pwsh') { $seconds += [int]$Context.Bound['upgrade_pwsh'] }
    $back = ([DateTimeOffset](& $Context.Service.UtcNow)).AddSeconds($seconds).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    $write = Set-HostUpdateObligation -RequestId $RequestId -ControllerPid $Context.ControllerPid -ObligationId listener -State armed -ListenerExpectedBackUtc $back `
        -UtcNow $Context.Service.UtcNow -Confirm:$false
    if (-not $write.Written -and $write.Reason -notin @('unchanged', 'disposed')) { Stop-HostUpdateOperation -Reason 'journal-write-failed' }
    # Published before the stop: the page that loses its host reads why and
    # until when from this file.
    $armed = Get-HostUpdateRequest -RequestId $RequestId
    if ($armed) { $null = Write-HostUpdatePublicState -Context $Context -Row $armed -Confirm:$false }
    $stopped = [bool](& $Context.Service.StopListener ([string]$row['runtimeDir']))
    Write-HostUpdateControllerLog -Context $Context -EventName 'listener-stopped' -Detail @{ requestId = $RequestId; after = $After; stopped = "$stopped" }
}

function Clear-HostUpdateElevation {
    <#
    .SYNOPSIS
        End the transient units of the install and enable phases (KVM), or
        their process trees (macOS), and remove the temporary sudo rule, then
        disarm the elevation obligation.
    .DESCRIPTION
        The step removes both itself, however its work ends; this covers a
        step child that was ended at its bound, or a controller that died,
        before it could. What cannot be cleared stays armed and becomes debt.
        On macOS the processes are ended while the rule is still in force,
        because a root member can only be signaled through it.
    .OUTPUTS
        [bool] cleared.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The unit and rule helpers it calls gate each change.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId)
    if ($Context.HostType -ceq 'host.windows.hyper-v') { return $true }
    if ($Context.HostType -ceq 'host.macos.utm') {
        $work = & $Context.Service.ElevatedWork $RequestId $Context.Checkout
        $ended = ($null -ne $work) -and [bool](& $Context.Service.StopElevatedWork $work $Context.Service.Native)
        $removed = Remove-HostUpdateSudoRule -Native $Context.Service.Native -HostType $Context.HostType -Confirm:$false
        Write-HostUpdateControllerLog -Context $Context -EventName 'elevation-cleared' -Detail @{ requestId = $RequestId; work = "$ended"; rule = "$removed" }
        if ($ended -and $removed) {
            Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'elevation' -State 'discharged' -Evidence 'rule-removed'
            return $true
        }
        return $false
    }
    # Every loaded unit of the two phases is ended, also one an earlier
    # update left; a list systemctl could not give leaves the obligation armed.
    $units = Get-HostUpdateElevatedUnit -Native $Context.Service.Native
    $stopped = ($null -ne $units) -and ((@($units).Count -eq 0) -or (Stop-HostUpdateElevatedUnit -Unit $units -Native $Context.Service.Native -Confirm:$false))
    $removed = Remove-HostUpdateSudoRule -Native $Context.Service.Native -Confirm:$false
    Write-HostUpdateControllerLog -Context $Context -EventName 'elevation-cleared' -Detail @{ requestId = $RequestId; units = "$stopped"; rule = "$removed" }
    if ($stopped -and $removed) {
        Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'elevation' -State 'discharged' -Evidence 'rule-removed'
        return $true
    }
    return $false
}

function Invoke-HostUpdatePrivilegedPhase {
    <#
    .SYNOPSIS
        The install or enable phase: arm the elevation obligation on KVM and
        macOS, run the step, and clear the elevation afterwards whatever the
        step did.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][ValidateSet('install', 'enable')][string]$Phase)
    if ($Context.HostType -cne 'host.windows.hyper-v') { Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'elevation' -State 'armed' }
    $run = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase $Phase
    $null = Clear-HostUpdateElevation -Context $Context -RequestId $RequestId
    return $run
}

function Invoke-HostUpdatePwshUpgrade {
    <#
    .SYNOPSIS
        The upgrade_pwsh phase on Windows: hand the PowerShell upgrade the
        install phase found pending to the shim, then read how it went.
    .DESCRIPTION
        PowerShell 7 cannot replace itself, so the controller stops the
        listener, writes the request naming the installer copy of the
        install phase, journals the phase started and exits with 77; the
        shim runs the upgrade, writes its result file and starts the
        controller again, which finds the phase started and reads the
        result. The phase is never started twice. A failed upgrade is a
        remark: the old PowerShell still runs.
    .OUTPUTS
        [pscustomobject] @{ Outcome done|skipped; Exit $null or 77 }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId)
    $requestPath = [System.IO.Path]::Combine($Context.ControllerRoot, 'pwsh-upgrade.request')
    $resultPath = [System.IO.Path]::Combine($Context.ControllerRoot, 'pwsh-upgrade.result')
    $finish = {
        param([string]$Outcome, [bool]$Failed)
        $change = @{ Phase = 'upgrade_pwsh'; State = 'finished'; Outcome = $Outcome }
        if ($Failed) { $change.Remarks = [string[]]@('pwsh_upgrade_failed') }
        $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change $change
        [pscustomobject]@{ Outcome = $Outcome; Exit = $null }
    }
    $row = Get-HostUpdateRow -RequestId $RequestId
    $entry = Get-HostUpdatePhaseEntry -Row $row -Phase 'upgrade_pwsh'
    if ($entry -and [string]$entry['state'] -eq 'started') {
        $reason = $null
        try {
            if ([System.IO.File]::Exists($resultPath)) { $reason = [string](([System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)['reason']) }
        } catch { Write-Verbose "Invoke-HostUpdatePwshUpgrade: result unreadable: $($_.Exception.Message)" }
        Write-HostUpdateControllerLog -Context $Context -EventName 'pwsh-upgrade-read' -Detail @{ requestId = $RequestId; reason = if ($reason) { $reason } else { 'none' } }
        # Journaled before the file goes: a controller stopped in between
        # reads the same result again.
        $done = & $finish 'done' ($reason -cne 'ok')
        try { if ([System.IO.File]::Exists($resultPath)) { [System.IO.File]::Delete($resultPath) } } catch { Write-Verbose "Invoke-HostUpdatePwshUpgrade: result left: $($_.Exception.Message)" }
        return $done
    }
    $install = Get-HostUpdatePhaseEntry -Row $row -Phase 'install'
    $pending = $IsWindows -and $install -and $install['result'] -is [System.Collections.IDictionary] -and [bool]$install['result']['pwshUpgradePending']
    $null = Write-HostUpdatePhaseRecord -Context $Context -RequestId $RequestId -Change @{ Phase = 'upgrade_pwsh'; State = 'started' }
    if (-not $pending) { return (& $finish 'skipped' $false) }
    $copyDirectory = Get-HostUpdateInstallerCopyDirectory -RequestId $RequestId -Attempt ([Math]::Max(1, [int]$install['attempts']))
    $copy = if ($copyDirectory) { [System.IO.Path]::Combine($copyDirectory, 'windows.hyper-v.ps1') } else { $null }
    # The shim runs the copy elevated, maybe long after the install phase made
    # it: it must still be the file the install phase checked, in a folder only
    # Administrators can change.
    if (-not $copy -or -not (Test-HostUpdateInstallerCopy -Path $copy -Sha256 ([string]$install['result']['installerSha256']))) { return (& $finish 'done' $true) }
    try {
        if ([System.IO.File]::Exists($resultPath)) { [System.IO.File]::Delete($resultPath) }
        $temp = "$requestPath.tmp-$PID"
        [System.IO.File]::WriteAllText($temp, $copy)
        [System.IO.File]::Move($temp, $requestPath, $true)
    } catch {
        Write-HostUpdateControllerLog -Context $Context -EventName 'pwsh-upgrade-request-failed' -Detail @{ requestId = $RequestId }
        return (& $finish 'done' $true)
    }
    Stop-HostUpdateListener -Context $Context -RequestId $RequestId -After 'upgrade_pwsh'
    Write-HostUpdateControllerLog -Context $Context -EventName 'pwsh-upgrade-requested' -Detail @{ requestId = $RequestId }
    return [pscustomobject]@{ Outcome = 'started'; Exit = 77 }
}

function Test-HostUpdateInstallerCopy {
    <#
    .SYNOPSIS
        Whether an installer copy is still the one the install phase made:
        its folder is no link and only Administrators and SYSTEM can change
        it, and the file has the hash the phase recorded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Sha256)
    try {
        $file = [System.IO.FileInfo]::new($Path)
        if (-not $file.Exists -or $file.LinkTarget -or $file.Directory.LinkTarget -or $Sha256 -cnotmatch '\A[0-9A-F]{64}\z') { return $false }
        if (-not (Test-HostUpdateWindowsAdminOnlyAcl -Path $file.DirectoryName)) { return $false }
        return ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($Path))) -ceq $Sha256)
    } catch {
        Write-Verbose "Test-HostUpdateInstallerCopy: '$Path' unreadable: $($_.Exception.Message)"
        return $false
    }
}

function Test-HostUpdateRebootRequired {
    <#
    .SYNOPSIS
        Whether the install phase reported that Windows must restart before
        the hypervisor can run.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    $install = Get-HostUpdatePhaseEntry -Row $Row -Phase 'install'
    return [bool]($install -and $install['result'] -is [System.Collections.IDictionary] -and [bool]$install['result']['restartRequired'])
}

function Remove-HostUpdateInstallerCopy {
    <#
    .SYNOPSIS
        Remove the installer copies of a host update's install attempts on
        Windows, once the update is terminal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    if (-not $IsWindows) { return }
    $install = Get-HostUpdatePhaseEntry -Row $Row -Phase 'install'
    if (-not $install) { return }
    for ($n = 1; $n -le [int]$install['attempts']; $n++) {
        $directory = Get-HostUpdateInstallerCopyDirectory -RequestId ([string]$Row['requestId']) -Attempt $n
        if (-not $directory -or -not [System.IO.Directory]::Exists($directory)) { continue }
        if (-not $PSCmdlet.ShouldProcess($directory, (Format-YurunaOperatorMessage -Key 'runner.host_update_elevation_action'))) { continue }
        try { [System.IO.Directory]::Delete($directory, $true) } catch { Write-Verbose "Remove-HostUpdateInstallerCopy: '$directory' left: $($_.Exception.Message)" }
    }
}

function Invoke-HostUpdateOperation {
    <#
    .SYNOPSIS
        Run, or continue from the journal, the phases of a claimed host
        update's scope.
    .DESCRIPTION
        The phases are walked in order: a phase finished as done or skipped
        is passed, a failed one is handled as if it had just failed, and the
        first phase not finished runs (again). A finished or started restore
        is continued before the walk, and a recovering row goes straight to
        its backoff; in a new boot the listener is started before any of
        them.
    .OUTPUTS
        [object] $null when the operation ended or waits elsewhere, the exit
        code 75 after a snapshot replacement or a PowerShell that changed, or
        77 for the shim's PowerShell upgrade.
    #>
    [CmdletBinding()]
    [OutputType([object], [int])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$RequestId, [switch]$Continuation)
    $row = Get-HostUpdateRow -RequestId $RequestId
    if ([string]$row['state'] -notin @('running', 'recovery-pending')) { return $null }
    $update = Get-HostUpdateRowBlock -Row $row
    # After a restart of the host the listener is started first, once in
    # this boot, whatever the update is doing (walking, restoring or
    # recovering), so a page can follow the rest of it.
    $bootEpoch = [long]0
    [void][long]::TryParse("$($update['bootEpochMs'])", [ref]$bootEpoch)
    $thisBoot = Get-HostUpdateBootEpoch -Context $Context
    if ($Continuation -and $bootEpoch -gt 0 -and [Math]::Abs($bootEpoch - $thisBoot) -gt $script:HostUpdateBootSlackMs) {
        $listenerEntry = Get-HostUpdatePhaseEntry -Row $row -Phase 'start_listener'
        $finishedMs = [long]0
        if ($listenerEntry -and $listenerEntry['finishedUtc']) {
            try { $finishedMs = [DateTimeOffset]::Parse([string]$listenerEntry['finishedUtc'], [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() } catch { $finishedMs = 0 }
        }
        if ($finishedMs -lt $thisBoot) {
            Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'listener' -State 'armed'
            $listener = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase 'start_listener'
            if ($listener.Outcome -ne 'failed') { Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'listener' -State 'discharged' -Evidence 'listener-ready' }
        }
        $row = Get-HostUpdateRow -RequestId $RequestId
    }
    if ([string]$row['state'] -eq 'recovery-pending') { return (Invoke-HostUpdateRecovering -Context $Context -RequestId $RequestId -Reason $null -Action $null) }
    $scope = [string]$update['request']['scope']
    if (@(& $Context.Service.SupportedScope $Context.HostType) -cnotcontains $scope) {
        if (Test-HostUpdateInherited -Row $row) { return (Invoke-HostUpdateRestore -Context $Context -RequestId $RequestId -Reason 'scope_unavailable') }
        Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'refused' -Action 'none' -Reason 'scope_unavailable'
        return $null
    }
    $restore = Get-HostUpdatePhaseEntry -Row $row -Phase 'restore'
    if ($restore) {
        if ([string]$restore['state'] -eq 'finished' -and [string]$restore['outcome'] -eq 'done') {
            Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'failed_restored' -Action 'read_remarks' -Reason (Get-HostUpdateFirstFailure -Row $row)
            return $null
        }
        if ([string]$restore['state'] -eq 'finished' -and [string]$restore['outcome'] -eq 'failed') {
            return (Invoke-HostUpdateRecovering -Context $Context -RequestId $RequestId -Reason ([string]$restore['reason']) -Action $null -Enter)
        }
        return (Invoke-HostUpdateRestore -Context $Context -RequestId $RequestId -Reason (Get-HostUpdateFirstFailure -Row $row))
    }
    # A controller stopped after a privileged phase was journaled finished,
    # and before it cleared the elevation, left the obligation armed. No
    # privileged phase runs here; one that has not finished arms it again.
    if ((Get-HostUpdateArmedObligation -Row (Get-HostUpdateRow -RequestId $RequestId)) -ccontains 'elevation') {
        $null = Clear-HostUpdateElevation -Context $Context -RequestId $RequestId
    }
    foreach ($phase in (Get-HostUpdateScopePhase -Scope $scope)) {
        $row = Get-HostUpdateRow -RequestId $RequestId
        $entry = Get-HostUpdatePhaseEntry -Row $row -Phase $phase
        $finished = $entry -and [string]$entry['state'] -eq 'finished' -and [string]$entry['outcome'] -in @('done', 'skipped', 'failed')
        # A start that passed is always followed by the discharge of the
        # listener, so an armed listener beside it means a later stop (phase
        # 5 or 6, after a start the boot block made): the listener starts again.
        if ($phase -eq 'start_listener' -and $finished -and [string]$entry['outcome'] -ne 'failed' -and (Get-HostUpdateArmedObligation -Row $row) -ccontains 'listener') {
            $finished = $false
        }
        $outcome = if ($finished) { [string]$entry['outcome'] } else { $null }
        $reason = if ($finished) { [string]$entry['reason'] } else { $null }
        $action = if ($finished -and $entry['result'] -is [System.Collections.IDictionary]) { [string]$entry['result']['operatorAction'] } else { $null }
        $protocol = if ($finished -and $entry['result'] -is [System.Collections.IDictionary]) { $entry['result']['protocol'] } else { $null }
        $result = $null
        if (-not $finished) {
            switch ($phase) {
                'install' {
                    $run = Invoke-HostUpdatePrivilegedPhase -Context $Context -RequestId $RequestId -Phase 'install'
                    $outcome = $run.Outcome; $reason = $run.Reason; $action = $run.Action; $result = $run.Result
                }
                'enable' {
                    $run = Invoke-HostUpdatePrivilegedPhase -Context $Context -RequestId $RequestId -Phase 'enable'
                    $outcome = $run.Outcome; $reason = $run.Reason; $action = $run.Action
                }
                'upgrade_pwsh' {
                    $run = Invoke-HostUpdatePwshUpgrade -Context $Context -RequestId $RequestId
                    if ($run.Exit) { return [int]$run.Exit }
                    $outcome = $run.Outcome
                }
                'drain' {
                    $run = Invoke-HostUpdateDrain -Context $Context -RequestId $RequestId
                    $outcome = $run.Outcome; $reason = $run.Reason
                }
                'stop_runner' {
                    $current = Get-HostUpdateRow -RequestId $RequestId
                    $startChange = @{}
                    if ((Get-HostUpdateRowBlock -Row $current)['runnerPlan'] -isnot [System.Collections.IDictionary]) { $startChange.Plan = Get-HostUpdateRunnerPlan -Context $Context -Row $current }
                    $planned = if ($startChange.Plan) { [bool]$startChange.Plan.start } else { [bool](Get-HostUpdateRowBlock -Row $current)['runnerPlan']['start'] }
                    if ($planned) { Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'runner' -State 'armed' }
                    $run = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase 'stop_runner' -StartChange $startChange
                    $outcome = $run.Outcome; $reason = $run.Reason; $action = $run.Action
                }
                'start_runner' {
                    $run = Invoke-HostUpdateStartRunner -Context $Context -RequestId $RequestId
                    if ($run.Outcome -eq 'none') {
                        Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'updated_not_started' -Action 'start_runner'
                        return $null
                    }
                    $outcome = $run.Outcome; $reason = $run.Reason; $action = $run.Action
                }
                default {
                    $run = Invoke-HostUpdateStepPhase -Context $Context -RequestId $RequestId -Phase $phase
                    $outcome = $run.Outcome; $reason = $run.Reason; $action = $run.Action
                    if ($run.Result) { $protocol = $run.Result['protocol'] }
                }
            }
        }
        switch ($phase) {
            'preflight' {
                if ($outcome -eq 'failed') { return (Resolve-HostUpdateRefusal -Context $Context -RequestId $RequestId -Reason $reason -Action $action) }
            }
            'drain' {
                if ($outcome -eq 'failed') { return (Resolve-HostUpdateRefusal -Context $Context -RequestId $RequestId -Reason $reason -Action $null) }
            }
            'stop_runner' {
                if ($outcome -eq 'failed') {
                    $current = Get-HostUpdateRow -RequestId $RequestId
                    $open = Open-HostUpdateGate -Context $Context -Row $current -Confirm:$false
                    if ($open -eq 'failed') { Stop-HostUpdateOperation -Reason 'gate-not-opened' }
                    Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'runner' -State 'disposed' -Evidence 'stop_failed'
                    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'stop_failed' -Action 'stop_runner_by_hand' -Reason $reason
                    return $null
                }
            }
            'update_source' {
                if ($outcome -eq 'failed') { return (Invoke-HostUpdateRestore -Context $Context -RequestId $RequestId -Reason $reason) }
                $check = Test-HostUpdateProtocolAfterSource -Context $Context -Protocol $protocol
                if ($check.Disposition -eq 'exit') { return 75 }
                if ($check.Disposition -eq 'cannot-stage') {
                    return (Invoke-HostUpdateRecovering -Context $Context -RequestId $RequestId -Reason 'protocol_mismatch' -Action 'repair_checkout' -Enter)
                }
            }
            'install' {
                if ($outcome -eq 'failed') { return (Invoke-HostUpdateRestore -Context $Context -RequestId $RequestId -Reason $reason) }
                # A PowerShell the installer moved in place: every later phase,
                # and the listener, runs on the new runtime. Only the run that
                # just finished does this; a controller that continues the
                # walk already runs on it.
                if ($result -is [System.Collections.IDictionary] -and [bool]$result['pwshChanged']) {
                    Stop-HostUpdateListener -Context $Context -RequestId $RequestId -After 'install'
                    return 75
                }
            }
            'enable' {
                if ($outcome -eq 'failed') { return (Invoke-HostUpdateRestore -Context $Context -RequestId $RequestId -Reason $reason) }
            }
            'start_listener' {
                if ($outcome -eq 'failed') { Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'listener' -State 'armed' }
                elseif ((Get-HostUpdateArmedObligation -Row (Get-HostUpdateRow -RequestId $RequestId)) -ccontains 'listener') {
                    Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'listener' -State 'discharged' -Evidence 'listener-ready'
                }
            }
            'start_runner' {
                if ($outcome -eq 'failed' -and (Test-HostUpdateRebootRequired -Row (Get-HostUpdateRow -RequestId $RequestId))) {
                    # Only a restart of Windows can help: nothing is tried again.
                    Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'runner' -State 'disposed' -Evidence 'reboot_required'
                    Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'reboot_required' -Action 'reboot_host' -Reason $reason
                    return $null
                }
                if ($outcome -eq 'failed') { return (Invoke-HostUpdateRecovering -Context $Context -RequestId $RequestId -Reason $reason -Action $action -Enter) }
                $current = Get-HostUpdateRow -RequestId $RequestId
                if ((Get-HostUpdateArmedObligation -Row $current) -ccontains 'runner') {
                    Set-HostUpdateObligationRecord -Context $Context -RequestId $RequestId -ObligationId 'runner' -State 'discharged' -Evidence 'runner-ready'
                }
                $remarks = Get-HostUpdateTokenList -Value (Get-HostUpdateRowBlock -Row $current)['remarks'] -Allowed $script:HostUpdateRemarkToken
                if ($remarks.Count -gt 0) { Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'updated_with_remarks' -Action 'read_remarks' }
                else { Complete-HostUpdateOperation -Context $Context -RequestId $RequestId -Verdict 'updated' -Action 'none' }
                return $null
            }
        }
    }
    return $null
}

function Invoke-HostUpdateClaimed {
    <#
    .SYNOPSIS
        Claim a queued update, or continue a claimed one, under the lifetime
        lock, and run it.
    .PARAMETER RecoverReason
        Claim straight into recovering for this reason instead of walking
        the phases: a row that took over a recovering update's stopped runner
        and closed gate, whose checkout this controller may not run from.
    .OUTPUTS
        [object] $null, or an exit code for the shim.
    #>
    [CmdletBinding()]
    [OutputType([object], [int])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('claim', 'continue')][string]$Mode,
        [ValidateSet('protocol_mismatch')][string]$RecoverReason
    )
    $Context.ActiveRequestId = $RequestId
    try {
        Enter-HostUpdateLifetimeLock -Context $Context
        $claim = Confirm-HostUpdateClaim -RequestId $RequestId -LifetimeLock $Context.LifetimeLock -ControllerPid $Context.ControllerPid `
            -ControllerStartTimeUnixMs ([long]$Context.ControllerStartTimeUnixMs) -Snapshot $Context.Snapshot -RepoRoot $Context.Checkout -Mode $Mode `
            -UtcNow $Context.Service.UtcNow -Confirm:$false
        if (-not $claim.Accepted) {
            Write-HostUpdateControllerLog -Context $Context -EventName 'claim-refused' -Detail @{ requestId = $RequestId; mode = $Mode; reason = $claim.Reason }
            return $null
        }
        Write-HostUpdateControllerLog -Context $Context -EventName "claim-$Mode" -Detail @{ requestId = $RequestId }
        # A first claim registers the journal owner, whose runtime directory
        # then holds this controller's state file too.
        $Context.RuntimeDir = Resolve-HostUpdateControllerRuntime -Context $Context -Journal (Read-HostOperationJournal).Journal
        if ($Mode -eq 'continue' -or $RecoverReason) { $null = Update-HostUpdateGateOwner -Context $Context -Row $claim.Row -Confirm:$false }
        Step-HostUpdateHeartbeat -Context $Context -Force
        if ($RecoverReason) { return (Invoke-HostUpdateRecovering -Context $Context -RequestId $RequestId -Reason $RecoverReason -Action 'repair_checkout' -Enter) }
        return (Invoke-HostUpdateOperation -Context $Context -RequestId $RequestId -Continuation:($Mode -eq 'continue'))
    } finally {
        Exit-HostUpdateLifetimeLock -Context $Context
        $Context.ActiveRequestId = $null
    }
}

# --- REGION: Idle duties
function Resolve-HostUpdateControllerRuntime {
    <#
    .SYNOPSIS
        The runtime directory for host-controller.state.json: the journal
        owner's, else the checkout's default.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context, [AllowNull()]$Journal)
    if ($Journal -is [System.Collections.IDictionary] -and $Journal['owner'] -is [System.Collections.IDictionary] -and $Journal['owner']['runtimeDir']) {
        return [string]$Journal['owner']['runtimeDir']
    }
    return [System.IO.Path]::Combine($Context.Checkout, 'test', 'status', 'runtime')
}

function Publish-HostUpdateIdleProjection {
    <#
    .SYNOPSIS
        Project the newest host-update row nobody is running: a queued one
        on every pass, a terminal one only when it changed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [AllowNull()]$Journal)
    if ($Journal -isnot [System.Collections.IDictionary]) { return }
    $newest = $null
    foreach ($row in @($Journal['requests'])) {
        if ($row -isnot [System.Collections.IDictionary] -or [string]$row['kind'] -cne 'host-update') { continue }
        if (-not $newest -or [long]$row['createdUnixMs'] -gt [long]$newest['createdUnixMs']) { $newest = $row }
    }
    if (-not $newest -or [string]$newest['state'] -in @('running', 'recovery-pending')) { return }
    $id = [string]$newest['requestId']
    if ([string]$newest['state'] -eq 'queued') { $null = Write-HostUpdatePublicState -Context $Context -Row $newest -Confirm:$false; return }
    $note = if ($Context.LastVerdict -and $Context.LastVerdict.RequestId -ceq $id) { $Context.LastVerdict.FirstCycle } else { $null }
    $projection = ConvertTo-HostUpdatePublicState -Row $newest -Now ([DateTimeOffset](& $Context.Service.UtcNow)) -FirstCycle $note -HostType $Context.HostType
    $copy = [ordered]@{}
    foreach ($key in $projection.Keys) { if ($key -ne 'heartbeatUtc') { $copy[$key] = $projection[$key] } }
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(($copy | ConvertTo-Json -Depth 6 -Compress))))
    if ($Context.LastProjection[$id] -ceq $hash) { return }
    $written = Write-HostUpdatePublicState -Context $Context -Row $newest -Confirm:$false
    if ($written) { $Context.LastProjection[$id] = $written }
}

function Update-HostUpdateFirstCycle {
    <#
    .SYNOPSIS
        For two hours after a verdict that started a runner, copy the first
        cycle's result into the public state.
    .DESCRIPTION
        The resident deletes its cycle outcome file as it reads it, so the
        note reads status.json's history, newest first, for the first cycle
        that started after the new resident.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Context)
    $last = $Context.LastVerdict
    if (-not $last) { return }
    if ((Get-HostUpdateWallClock -Context $Context) - [long]$last.TerminalUnixMs -gt $script:HostUpdateFirstCycleWindowMs) { $Context.LastVerdict = $null; return }
    $note = 'pending'
    try {
        $statusPath = [System.IO.Path]::Combine($last.RuntimeDir, 'status.json')
        if ([System.IO.File]::Exists($statusPath)) {
            $status = [System.IO.File]::ReadAllText($statusPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $first = $null; $firstMs = [long]::MaxValue
            foreach ($entry in @($status['history'])) {
                if ($entry -isnot [System.Collections.IDictionary] -or -not $entry['startedAt']) { continue }
                $at = [DateTimeOffset]::Parse([string]$entry['startedAt'], [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
                if ($at -gt [long]$last.SinceUnixMs -and $at -lt $firstMs) { $first = $entry; $firstMs = $at }
            }
            if ($first) { $note = switch ([string]$first['overallStatus']) { 'pass' { 'pass' } 'fail' { 'fail' } default { 'pending' } } }
        }
    } catch {
        Write-Verbose "Update-HostUpdateFirstCycle: $($_.Exception.Message)"
    }
    if ($note -ceq $last.FirstCycle) { return }
    $last.FirstCycle = $note
    $path = [System.IO.Path]::Combine($last.RuntimeDir, 'host-update.state.json')
    try {
        $state = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ([string]$state['requestId'] -cne $last.RequestId) { return }
        $ordered = [ordered]@{}
        foreach ($key in $state.Keys) { $ordered[$key] = $state[$key] }
        $ordered['firstCycle'] = $note
        if ($PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_40eeaa317b25e65f'))) {
            $null = Write-YurunaStateFileJson -Path $path -InputObject $ordered -Depth 6 -Confirm:$false
        }
    } catch {
        Write-Verbose "Update-HostUpdateFirstCycle: '$path' not updated: $($_.Exception.Message)"
    }
}

function Find-HostUpdateLastVerdict {
    <#
    .SYNOPSIS
        Pick up the first-cycle note of a verdict an earlier instance wrote.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [AllowNull()]$Journal)
    if ($Journal -isnot [System.Collections.IDictionary]) { return }
    $newest = $null
    foreach ($row in @($Journal['requests'])) {
        if ($row -isnot [System.Collections.IDictionary] -or [string]$row['kind'] -cne 'host-update' -or -not $row['terminalUnixMs']) { continue }
        if (-not $newest -or [long]$row['terminalUnixMs'] -gt [long]$newest['terminalUnixMs']) { $newest = $row }
    }
    if ($newest -and (Get-HostUpdateWallClock -Context $Context) - [long]$newest['terminalUnixMs'] -le $script:HostUpdateFirstCycleWindowMs) {
        Set-HostUpdateLastVerdict -Context $Context -Row $newest
    }
}

# --- REGION: Controller entry
function Invoke-HostUpdateController {
    <#
    .SYNOPSIS
        The host controller: take the controller lock, read the journal,
        finish what an earlier instance left, then claim queued host updates
        and keep the snapshot current.
    .DESCRIPTION
        Exit codes for the shim: 75 start me again on the current snapshot
        (one was staged, or the install phase changed PowerShell), 76
        another controller holds the lock, 77 run the PowerShell upgrade
        (Windows), 1 anything else. A stop signal ends the process as if killed: no restore and no
        new phase; the next controller continues from the journal.
    .PARAMETER ControllerRoot
        The controller root.
    .PARAMETER Snapshot
        The snapshot this instance runs from.
    .PARAMETER Checkout
        The checkout.
    .PARAMETER Service
        Replacement services (see New-HostUpdateControllerContext).
    .PARAMETER Context
        A context built by New-HostUpdateControllerContext; when given, the
        other parameters are not read.
    .OUTPUTS
        [int] the exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Paths')][string]$ControllerRoot,
        [Parameter(Mandatory, ParameterSetName = 'Paths')][ValidatePattern('^[0-9a-f]{16}$', Options = 'None')][string]$Snapshot,
        [Parameter(Mandatory, ParameterSetName = 'Paths')][string]$Checkout,
        [Parameter(ParameterSetName = 'Paths')][hashtable]$Service = @{},
        [Parameter(Mandatory, ParameterSetName = 'Context')][hashtable]$Context
    )
    if ($PSCmdlet.ParameterSetName -eq 'Paths') { $Context = New-HostUpdateControllerContext -ControllerRoot $ControllerRoot -Snapshot $Snapshot -Checkout $Checkout -Service $Service }
    $Context.StartedUtc = ([DateTimeOffset](& $Context.Service.UtcNow)).UtcDateTime.ToString('o')
    $root = Get-HostOperationPrivateRoot
    if (-not $root.Resolved) {
        Write-HostUpdateControllerLog -Context $Context -EventName 'private-root-unavailable' -Detail @{ reason = [string]$root.Reason }
        return 1
    }
    $Context.PrivateRoot = [string]$root.Path
    $lockPath = Get-HostUpdateControllerLockPath
    if (-not $lockPath) { Write-HostUpdateControllerLog -Context $Context -EventName 'lock-path-unavailable'; return 1 }
    $lock = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 1500 -Metadata @{ purpose = 'host-controller'; snapshot = $Context.Snapshot }
    if (-not $lock.Held) {
        if ($lock.Reason -eq 'held-elsewhere') { Write-HostUpdateControllerLog -Context $Context -EventName 'lock-held-elsewhere'; return 76 }
        Write-HostUpdateControllerLog -Context $Context -EventName 'lock-refused' -Detail @{ reason = [string]$lock.Reason }
        return 1
    }
    $Context.ControllerLock = $lock
    try {
        try { $read = Read-HostOperationJournal } catch {
            Write-HostUpdateControllerLog -Context $Context -EventName 'journal-read-threw'
            return 1
        }
        # The snapshot's own code ran: a corrupt journal is data, not a broken
        # snapshot, and must not get a good snapshot rejected.
        $ok = [System.IO.Path]::Combine($Context.SnapshotRoot, 'ok')
        if ([System.IO.Directory]::Exists($Context.SnapshotRoot) -and -not [System.IO.File]::Exists($ok)) {
            try { [System.IO.File]::WriteAllText($ok, $Context.StartedUtc) } catch { Write-HostUpdateControllerLog -Context $Context -EventName 'ok-not-written' }
        }
        $journal = if ($read.Status -in @('ok', 'recovered-previous')) { $read.Journal } else { $null }
        $Context.RuntimeDir = Resolve-HostUpdateControllerRuntime -Context $Context -Journal $journal
        Find-HostUpdateLastVerdict -Context $Context -Journal $journal
        Write-HostUpdateControllerLog -Context $Context -EventName 'started' -Detail @{ snapshot = $Context.Snapshot; protocol = "$($Context.Protocol)"; journal = [string]$read.Status }
        Update-HostUpdateSession -Context $Context
        Update-HostUpdateScopeList -Context $Context
        Step-HostUpdateHeartbeat -Context $Context -Force
        $start = Get-HostUpdateTick -Context $Context
        $lastQueue = [long]::MinValue
        $lastSnapshot = $start
        $lastNote = $start
        while ($true) {
            if ($Context.Service.ShouldStop -and (& $Context.Service.ShouldStop $Context)) { return 0 }
            $tick = Get-HostUpdateTick -Context $Context
            if ($Context.LastPublishTick -eq [long]::MinValue -or $tick - $Context.LastPublishTick -ge 5000) {
                $read = Read-HostOperationJournal
                $journal = if ($read.Status -in @('ok', 'recovered-previous')) { $read.Journal } else { $null }
                $Context.RuntimeDir = Resolve-HostUpdateControllerRuntime -Context $Context -Journal $journal
                Step-HostUpdateHeartbeat -Context $Context -Force
                Publish-HostUpdateIdleProjection -Context $Context -Journal $journal
            }
            if ($lastQueue -eq [long]::MinValue -or $tick - $lastQueue -ge 2000) {
                $lastQueue = $tick
                $queue = Get-HostUpdateQueue -UtcNow $Context.Service.UtcNow
                $exit = $null
                if ($queue.Claimed) {
                    $exit = Invoke-HostUpdateClaimed -Context $Context -RequestId ([string]$queue.Claimed['requestId']) -Mode continue
                } elseif ($queue.Queued) {
                    $id = [string]$queue.Queued['requestId']
                    $compare = Compare-HostUpdateSnapshot -Context $Context
                    $lastSnapshot = $tick
                    if ($compare.Action -eq 'staged') { return 75 }
                    if ($compare.Action -eq 'cannot-stage' -and $compare.ProtocolDiffers -and (Test-HostUpdateInherited -Row $queue.Queued)) {
                        # A takeover already owns a stopped runner and a closed
                        # gate: left queued, nothing would ever give them back.
                        # Recovering pulls with the snapshot's code and starts
                        # nothing from the checkout until its protocol matches.
                        $exit = Invoke-HostUpdateClaimed -Context $Context -RequestId $id -Mode claim -RecoverReason protocol_mismatch
                    } elseif ($compare.Action -eq 'cannot-stage' -and $compare.ProtocolDiffers) {
                        $blocked = Set-HostUpdateClaimBlocked -RequestId $id -Reason protocol_mismatch -UtcNow $Context.Service.UtcNow -Confirm:$false
                        if ($blocked.Written -and $blocked.Reason -eq 'written') { Write-HostUpdateControllerLog -Context $Context -EventName 'claim-blocked' -Detail @{ requestId = $id; reason = 'protocol_mismatch' } }
                    } else {
                        # On macOS the elevation probe is the controller's
                        # own and never runs while an update is claimed: the
                        # full scope is probed once more just before its
                        # claim, and published, so its preflight reads a
                        # fresh result. A claim that is refused leaves the
                        # row queued and is tried on every queue read; each
                        # probe writes and removes a file in /etc/sudoers.d,
                        # so one request is probed at most once a minute.
                        $scope = [string](Get-HostUpdateRowBlock -Row $queue.Queued)['request']['scope']
                        $last = $Context.PreClaimProbe
                        if ($Context.HostType -ceq 'host.macos.utm' -and $scope -ceq 'full' -and
                            (-not $last -or $last.RequestId -cne $id -or $tick - $last.Tick -ge 60000)) {
                            Update-HostUpdateScopeList -Context $Context
                            Step-HostUpdateHeartbeat -Context $Context -Force
                            $Context.PreClaimProbe = @{ RequestId = $id; Tick = $tick }
                        }
                        $exit = Invoke-HostUpdateClaimed -Context $Context -RequestId $id -Mode claim
                    }
                }
                if ($null -ne $exit) { return [int]$exit }
            }
            $tick = Get-HostUpdateTick -Context $Context
            if ($tick - $lastSnapshot -ge 300000) {
                $lastSnapshot = $tick
                if ((Compare-HostUpdateSnapshot -Context $Context).Action -eq 'staged') { return 75 }
            }
            if ($tick - $lastNote -ge 60000) {
                $lastNote = $tick
                Update-HostUpdateFirstCycle -Context $Context -Confirm:$false
            }
            # A host that cannot run the full scope is probed again every ten
            # minutes, so an elevation provisioned meanwhile shows without a
            # restart of the controller; one that can is not probed on a timer.
            if (@($Context.Scopes) -cnotcontains 'full' -and $tick - $Context.LastProbeTick -ge 600000 -and (Test-HostUpdateProbeAllowed -Context $Context)) {
                Update-HostUpdateScopeList -Context $Context
                if (@($Context.Scopes) -ccontains 'full') { Step-HostUpdateHeartbeat -Context $Context -Force }
            }
            & $Context.Service.Sleep 1000
        }
    } catch {
        $stop = $_.Exception.Data['HostUpdateStop']
        $detail = @{ reason = if ($stop) { [string]$stop } else { 'exception' } }
        if (-not $stop) { $detail.type = $_.Exception.GetType().Name; Write-Verbose "Invoke-HostUpdateController: $($_.Exception.Message) $($_.ScriptStackTrace)" }
        Write-HostUpdateControllerLog -Context $Context -EventName 'operation-stopped' -Detail $detail
        return 1
    } finally {
        Exit-HostUpdateLifetimeLock -Context $Context
        Exit-YurunaSingleFlightLock -Lock $lock
        $Context.ControllerLock = $null
    }
}

Export-ModuleMember -Function New-HostUpdatePrivateDirectory, Get-HostUpdateSnapshotManifest, Test-HostUpdateSnapshotParse, New-HostUpdateSnapshot, `
    Read-HostUpdateControllerCurrent, Write-HostUpdateControllerCurrent, Get-HostUpdateRejected, Remove-HostUpdateStaleSnapshot, `
    Install-HostUpdateControllerFile, Get-HostUpdateControllerShimPath, Test-HostUpdateControllerDeployment, `
    Get-HostUpdateControllerUnitText, Get-HostUpdateControllerTaskXml, Register-HostUpdateControllerTask, `
    Unregister-HostUpdateControllerTask, Write-HostUpdateControllerLine, `
    Invoke-HostUpdateNative, Get-HostUpdateSudoRuleText, Set-HostUpdateSudoRule, Remove-HostUpdateSudoRule, Stop-HostUpdateElevatedUnit, Get-HostUpdateElevatedUnit, `
    Test-HostUpdateFullScopeReady, Get-HostUpdateScopePhase, `
    Get-HostUpdateHostType, Get-HostUpdatePhaseBound, Get-HostUpdateSupportedScope, `
    Test-HostUpdateMacElevationEntry, Get-HostUpdateAccessEntryText, Install-HostUpdateAccessEntry, Remove-HostUpdateAccessEntry, `
    Get-HostUpdateMacElevatedWork, Stop-HostUpdateMacElevatedWork, Clear-HostUpdateElevation, `
    Find-HostUpdateMultiplexerTool, Get-HostUpdateControllerAttachCommand, Start-HostUpdateControllerSession, Stop-HostUpdateControllerSession, `
    Get-HostUpdateMacSessionReading, Invoke-HostUpdateMacSessionProbe, `
    New-HostUpdateControllerContext, ConvertTo-HostUpdatePublicState, Invoke-HostUpdateController
