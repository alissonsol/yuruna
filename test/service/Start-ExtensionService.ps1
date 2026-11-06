<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42a250bd-06e8-40d3-8cee-cc9f04e23650
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna extension service
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

<#
.SYNOPSIS
    Brings up an extension service on its own VM and publishes its readiness.
.DESCRIPTION
    The one Start pipeline behind Start-StashServiceVM.ps1,
    Start-PoolControlServiceVM.ps1 and Start-DownloadAgentServiceVM.ps1, which
    name their service and run this script. Every phase up to the VM build is
    the same for the three services. The phases from the guest address on --
    Shared NAT forwarding, the readiness wait, the outcome, the marker and the
    report -- differ per service and live in Start-ExtensionService.<key>.ps1,
    which this script runs in its own scope inside the start operation's try
    block, so each of their exits closes the operation like an exit here.
.PARAMETER VMName
    Name of the service VM.
.PARAMETER ServiceKey
    The service's roster key: stash, pool-control or download-agent.
.PARAMETER Area
    The service's extension area, such as stash-service.
.PARAMETER CallerScript
    The entry script that named the service; its file name is what the
    operation record and the operator messages show.
.PARAMETER AllowMirrorSource
    Build the daemon from the public github mirror instead of this enlistment.
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for the rebuilt service VM.
.PARAMETER ForceRebuild
    Rebuild the VM even when the running one serves the current build or is
    still building it.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ExitOk',
    Justification = 'The service readiness parts this script runs in its scope exit with it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'resolveServiceVmAddress',
    Justification = 'The service readiness parts this script runs in its scope dot-source it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'recoverServiceVmAddress',
    Justification = 'The service readiness parts this script runs in its scope dot-source it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'reportServiceVmSource',
    Justification = 'The service readiness parts this script runs in its scope dot-source it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'decideServiceStartOutcome',
    Justification = 'The service readiness parts this script runs in its scope dot-source it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'vmIp',
    Justification = 'Set by a shared readiness step for the part that dot-sources it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ipWaitSeconds',
    Justification = 'Set by a shared readiness step for the part that dot-sources it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'sourceAccepted',
    Justification = 'Set by a shared readiness step for the part that dot-sources it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'serviceOpResult',
    Justification = 'Set by the shared outcome step; read in the finally that closes the start operation.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][ValidateSet('stash', 'download-agent', 'pool-control')][string]$ServiceKey,
    [Parameter(Mandatory)][string]$Area,
    [Parameter(Mandatory)][string]$CallerScript,
    [switch]$AllowMirrorSource,
    [switch]$AllowPseudoLocale,
    [switch]$ForceRebuild
)

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if (-not $PSCmdlet.ShouldProcess($VMName, 'Start or rebuild the service VM and configure host services')) { return }

# What differs between the three services before their readiness phases. The
# stash start sets the session's information and progress preferences, which
# the module functions it calls then follow; the other two set only their own
# scope's. Pool-control and download-agent need the runtime directory from the
# withdrawal before a rebuild on, so a missing one stops them early; stash
# initializes it right before its readiness probe and goes on without it.
$serviceProfile = @{
    'stash'          = @{
        User = 'stash-admin'; Storage = 'stash'; SessionPreferences = $true; EarlyRuntimeModules = $null; OutcomeToOutput = $true
        ElevationRemedy = 'Re-launch PowerShell as Administrator and run this script again.'
        StorageUnconfigured = @'
requires the stash storage to be configured (isolated from the pool):
set networkStorage.stashStorageNetworkPath / stashStorageNetworkUser / stashStorageLocalPath in
test/test.config.yml and Set-Password the stashStorageNetworkUser. See docs/test-config.md.
'@
        CredentialImpact = @'
The stash-service VM mounts the stash share with this account; without a stored credential the
VM seed bakes an auto-generated value the NAS rejects (cifs mount error(13)), so the
share never mounts. Store the real NAS password first, then re-run:
'@
        MountConsequence = @'
Bringing the VM up anyway: the daemon will START and BUFFER uploads locally, but they will
NOT persist to the stash share until this is fixed.
'@
    }
    'pool-control'   = @{
        User = 'pool-control-service-admin'; Storage = 'pool'; SessionPreferences = $false; EarlyRuntimeModules = @('Test.Config.psm1', 'Test.Locale.psm1'); OutcomeToOutput = $false
        ElevationRemedy = 'Re-launch PowerShell as Administrator, or use -HostSideProof (no VM, no elevation).'
        StorageUnconfigured = @'
requires the pool storage to be configured:
set networkStorage.poolStorageNetworkPath / poolStorageNetworkUser / poolStorageLocalPath in
test/test.config.yml and Set-Password the poolStorageNetworkUser. See docs/test-config.md
and the Pool control service section of docs/pool-admin.md.
'@
        CredentialImpact = @'
The pool-control-service VM mounts the pool NAS with this account; without a stored credential
the VM seed bakes an auto-generated value the NAS rejects (cifs mount error(13)), so the
state dir never mounts. Store the real NAS password first, then re-run:
'@
        MountConsequence = @'
Bringing the VM up anyway: the daemon will START but persist NOTHING until this is fixed.
'@
    }
    'download-agent' = @{
        User = 'download-agent-service-admin'; Storage = 'pool'; SessionPreferences = $false; EarlyRuntimeModules = @('Test.DownloadAgentService.psm1'); OutcomeToOutput = $false
        ElevationRemedy = 'Re-launch PowerShell as Administrator and run this script again.'
        StorageUnconfigured = @'
requires the pool storage to be configured:
set networkStorage.poolStorageNetworkPath / poolStorageNetworkUser / poolStorageLocalPath in
test/test.config.yml and Set-Password the poolStorageNetworkUser. See docs/test-config.md
and docs/download-agent.md.
'@
        CredentialImpact = @'
The download-agent-service VM mounts the pool share with this account; without a stored
credential the VM seed bakes an auto-generated value the NAS rejects (cifs mount
error(13)), so the image pool never mounts. Store the real NAS password first, then re-run:
'@
        MountConsequence = @'
Bringing the VM up anyway: the daemon will START but serve an EMPTY pool -- every ensure
answers 'pool-unavailable' and hosts fall back to downloading for themselves -- until this
is fixed.
'@
    }
}[$ServiceKey]
$guestKey  = "guest.$Area"
$guestUser = $serviceProfile.User
$startName = [IO.Path]::GetFileNameWithoutExtension($CallerScript)
# The stop entry script paired with the caller, which the messages that send
# the operator to it name.
$stopScript = "$($startName -replace '^Start-', 'Stop-').ps1"

if ($serviceProfile.SessionPreferences) {
    $global:InformationPreference = "Continue"
    $global:ProgressPreference    = "SilentlyContinue"
} else {
    $InformationPreference = 'Continue'
}

# --- REGION: Initialize service runtime
# See https://yuruna.link/42fffc2c-000b
# See https://yuruna.link/42162449-0004
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
if (-not $serviceProfile.SessionPreferences) { $InformationPreference = $global:InformationPreference }

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
$RepoRoot    = $paths.RepoRoot
$ModulesDir  = $paths.ModulesDir
Import-Module (Join-Path $ModulesDir 'Test.ServiceVm.psm1') -Global -DisableNameChecking -Verbose:$false

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit $ExitFailure
}

# --- REGION: Elevation check
# See https://yuruna.link/42e220c4-0008
if ($IsWindows -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output ""
    Write-Output "This script requires elevation (Run as Administrator)."
    Write-Output "$startName needs an elevated session to:"
    Write-Output "  * query Hyper-V for the VHD folder (Get-VMHost)"
    Write-Output "  * create and remove the '$VMName' VM and its disk"
    Write-Output $serviceProfile.ElevationRemedy
    Write-Error "$startName requires Administrator on Windows. Nothing was changed."
    exit $ExitFailure
}

# --- REGION: Initialize the runtime directory
# See https://yuruna.link/42e220c4-0008
# See https://yuruna.link/42f52e37-0020
# After the elevation check, so a refusal changes nothing.
$runtimeDir = $null
if ($serviceProfile.EarlyRuntimeModules) {
    Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
    foreach ($module in $serviceProfile.EarlyRuntimeModules) { Import-Module (Join-Path $ModulesDir $module) -Global -Force }
    $runtimeDir = Initialize-YurunaRuntimeDir
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }
}

# --- REGION: Initialize host access
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit $ExitFailure }
Write-Verbose "Host type: $HostType"
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# --- REGION: Record the start intent
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.ServiceCensus.psm1') -Global -Force -DisableNameChecking
$serviceOp = Enter-YurunaServiceOperation -Key $ServiceKey -VMName $VMName -Operation Start -Script (Split-Path -Leaf $CallerScript) -Confirm:$false
if (-not $serviceOp.Proceed) {
    Write-Error $serviceOp.Message
    exit $ExitFailure
}
# Every exit below, the service's own readiness phases included, runs the
# finally that closes this operation: it records the result and releases the
# operation lock even inside a long-lived shell.
$serviceOpResult = 'failed'
try {

# --- REGION: Storage preflight
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1')      -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.PoolStorage.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Extension.psm1')   -Global -Force
$null = @(Import-Extension -Area 'authentication' -RequireSingle)
$tcPath = Join-Path $RepoRoot 'test/test.config.yml'
$tc = $null
if (Test-Path -LiteralPath $tcPath) {
    try { $tc = Read-TestConfig -Path $tcPath } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
}
$storageKind = $serviceProfile.Storage
$storageCfg = $null
if ($tc) {
    try {
        $storageCfg = if ($storageKind -eq 'stash') { Get-YurunaStashStorageConfig -Config $tc } else { Get-YurunaPoolStorageConfig -Config $tc }
    } catch { Write-Verbose "$storageKind storage config: $($_.Exception.Message)" }
}
if (-not $storageCfg) {
    Write-Error "$startName $($serviceProfile.StorageUnconfigured)"
    exit $ExitFailure
}
# Hard gate: a REAL password must already be stored for the storage's SMB user.
# A mapped-but-unstored vaultKey would make the seed bake an AUTO-GENERATED
# junk password the NAS rejects (cifs mount error(13)); the SMB user
# authenticates to a PRE-EXISTING NAS account, so require a stored entry.
if (-not (Test-PoolStorageStoredCredential -Config $storageCfg)) {
    Write-Error @"
$storageKind networkUser '$($storageCfg.NetworkUser)' has NO password stored in the vault.
$($serviceProfile.CredentialImpact)
    Set-Password -Username '$($storageCfg.NetworkUser)' -NewPassword '<the real NAS password>'
See docs/test-config.md (networkStorage credentials).
"@
    exit $ExitFailure
}
# Soft gate: a credential IS stored -- verify it actually AUTHENTICATES to the
# share. WARNING, not a hard stop: each daemon runs without its share (stash
# buffers uploads locally, pool-control persists nothing, download-agent serves
# an empty pool), and the NAS may merely be transiently unreachable.
if (Connect-YurunaPoolStorage -Config $storageCfg -Confirm:$false) {
    Write-Verbose "$storageKind storage pre-flight OK (networkUser='$($storageCfg.NetworkUser)'; credential authenticates)."
} else {
    # Report the reason the mount RECORDED, and prescribe from it. A mount that
    # sudo refused never reaches the NAS, so naming the credential there sends
    # the operator to reset a password that was never wrong -- and to rebuild the
    # VM for it -- while the actual fault stays in place.
    $why = Get-PoolStorageLastMountError
    if (-not $why) { $why = 'the attempt recorded no reason (check that the NAS is reachable and the share name is right).' }
    $remedy = if (Test-PoolStorageSudoRefusal -StdErr $why) {
        "sudo refused the mount, so the $storageKind credential is NOT implicated. Fix passwordless
sudo for mount on this host (see docs/pool-storage.md) or run Sync-HostConfiguration, then
re-run. No rebuild is needed once the mount works."
    } else {
        "If the password is stale, update it and rebuild:
    Set-Password -Username '$($storageCfg.NetworkUser)' -NewPassword '<the real NAS password>'"
    }
    Write-Warning @"
$storageKind share '$($storageCfg.NetworkPath)' did NOT mount just now as networkUser
'$($storageCfg.NetworkUser)': $why
$($serviceProfile.MountConsequence)
$remedy
"@
}

# --- REGION: Resolve the VM builder
$hostFolder = Get-HostFolder $HostType
$guestDir   = Join-Path -Path $RepoRoot -ChildPath $hostFolder -AdditionalChildPath $guestKey
$newVm      = Join-Path $guestDir 'New-VM.ps1'
if (-not (Test-Path -LiteralPath $newVm)) {
    Write-Error "New-VM.ps1 not found for $HostType at $newVm"
    exit $ExitFailure
}

# --- REGION: Start the host status service
# See https://yuruna.link/42fffc2c-0013
$statusDecision = $null
try {
    $statusScript = Join-Path $RepoRoot 'test/service/Start-StatusService.ps1'
    if ($tc -and (Test-Path -LiteralPath $statusScript)) {
        # Start-YurunaStatusServiceIfEnabled's own console output is intentionally
        # not surfaced; keep only the {ShouldStart; Port} record, the last
        # non-string object the gate returns.
        $statusResult = Start-YurunaStatusServiceIfEnabled -Config $tc -StartScript $statusScript
        $statusDecision = @($statusResult | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -Last 1
    }
} catch { Write-Verbose "status service ensure: $($_.Exception.Message)" }

# --- REGION: Verify the framework source
# See https://yuruna.link/42fffc2c-0013
Import-Module (Join-Path $ModulesDir 'Test.FrameworkSource.psm1') -Global -Force
$frameworkExpected = Get-FrameworkSourceSnapshot -RepoRoot $RepoRoot
if (-not (Assert-GuestFrameworkSource -RepoRoot $RepoRoot -StatusDecision $statusDecision `
            -ServiceLabel $Area -AllowMirrorSource:$AllowMirrorSource)) {
    exit $ExitFailure
}

# --- REGION: Adopt a running VM
# See https://yuruna.link/42e220c4-0008
# A running guest that serves the current build, or is still building it, is
# kept: a re-run only re-asserts what the host publishes about it.
Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
$adoption = if ($ForceRebuild) { [pscustomobject]@{ Decision = 'rebuild'; Reason = '-ForceRebuild'; Address = '' } } else {
    Resolve-YurunaServiceVmAdoption -VMName $VMName -Port 80 -GuestKey $guestKey -User $guestUser -SourceCheck {
        param($Address)
        $deployed = Test-ServiceVmFrameworkSource -Address $Address -Port 80 -GuestKey $guestKey -User $guestUser -Expected $frameworkExpected
        -not ($deployed.Verified -and -not $deployed.Matches -and -not $AllowMirrorSource)
    }
}
$buildDegraded = @()
if ($adoption.Decision -ne 'rebuild') {
    $adoptedMessage = Format-YurunaOperatorMessage -Key 'runner.service_adopted' -Arguments @{ vmName = $VMName; reason = [string]$adoption.Reason; address = [string]$adoption.Address }
    if ($serviceProfile.OutcomeToOutput) { Write-Output $adoptedMessage } else { Write-Information $adoptedMessage -InformationAction Continue }
} else {
    # --- REGION: Create the VM
    # The builder's plan runs first, while the working VM and its advertisement
    # are still in place; only an accepted plan withdraws the advertisement and
    # lets the builder tear down the prior VM, create the new one, and
    # (Hyper-V + KVM) start it. UTM only builds the bundle;
    # Invoke-YurunaServiceVmBuild registers and starts it.
    $bringUpLine = "== Bringing up '$VMName' on $HostType ($($adoption.Reason)) =="
    if ($serviceProfile.OutcomeToOutput) {
        Write-Verbose ""
        Write-Output $bringUpLine
    } else {
        Write-Information $bringUpLine -InformationAction Continue
    }
    $plan = Test-YurunaServiceVmBuildPlan -BuilderPath $newVm -VMName $VMName -AllowPseudoLocale:$AllowPseudoLocale
    if (-not $plan.Ok) { Write-Error $plan.Error -ErrorAction Continue; exit $ExitFailure }
    # A stash start has no runtime directory yet; the withdrawal then resolves it.
    [void](Remove-YurunaServiceVmAdvertisement -Area $Area -HostType $HostType -RepoRoot $RepoRoot -RuntimeDir $runtimeDir -Confirm:$false)
    $build = Invoke-YurunaServiceVmBuild -BuilderPath $newVm -HostType $HostType -VMName $VMName -OperationContext $serviceOp -AllowPseudoLocale:$AllowPseudoLocale -Confirm:$false
    if (-not $build.Ok) { Write-Error $build.Error -ErrorAction Continue; exit $build.ExitCode }
    $buildDegraded = @($build.Degraded)
}

# --- REGION: Shared readiness steps
# The pool-control and download-agent parts run the same steps around their
# readiness probe, and every part decides its outcome the same way. The steps
# live here once, as script blocks a part dot-sources in this scope where it
# runs them, so the variables a step reads and sets ($vmIp, $endpoint,
# $verdict, ...) are the part's own; a part hands a step what differs through
# those variables, such as the forwarder re-point in $repointForwarder.
# See https://yuruna.link/42e220c4-0008
$resolveServiceVmAddress = {
    # The address the hypervisor reports is where the part's host forward
    # and readiness wait start. None within the wait is not a boot failure:
    # the VM is running, so the part asks the guest itself, and the seconds
    # spent here are what its messages and a recovered endpoint report.
    Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
    $ipWaitStart = (Get-Date)
    $vmIp = try { Wait-VMIp -VMName $VMName -TimeoutSeconds 120 } catch { Write-Verbose "Wait-VMIp: $($_.Exception.Message)"; $null }
    $ipWaitSeconds = [int]((Get-Date) - $ipWaitStart).TotalSeconds
}
# See https://yuruna.link/4220a755-0046
$recoverServiceVmAddress = {
    # A wait that ended without the daemon answering looks for the guest by a
    # route the wait could not use; a guest found serving there is adopted at
    # that address, and the host forward is re-pointed to it. The probe is
    # deliberately short: it runs only after the ordinary wait has already
    # spent its whole budget, and it is confirming a listener that either
    # answers within a few polls or was never there.
    $recoveryProbeSeconds = 60
    $recoveredIp = ''
    if ((Get-ServiceVmReadinessVerdict -Endpoint $endpoint).IsFailure) {
        $recovery = Confirm-ServiceVmAtRecoveredAddress -VMName $VMName -Port 80 -KnownAddress ([string]$vmIp) -TimeoutSeconds $recoveryProbeSeconds
        $recoveredIp = [string]$recovery.Address
        Write-Verbose "  $($recovery.Summary)."
        if ($recovery.Ready) {
            $vmIp = $recoveredIp
            $endpoint = New-ServiceVmRecoveredEndpoint -Endpoint $endpoint -Address $recoveredIp -WaitedSeconds $ipWaitSeconds
            & $repointForwarder $recoveredIp
        }
    }
}
# See https://yuruna.link/42fffc2c-0013
$reportServiceVmSource = {
    # The daemon is serving, so this is the first point where the framework it
    # was built from can be answered from evidence rather than prediction. It
    # is read before anything is published, so a refused build is never
    # advertised.
    $sourceAccepted = $true
    if ($daemonReady) {
        $sourceAccepted = Assert-ServiceVmFrameworkSource -Address ([string]$vmIp) -Port 80 `
            -GuestKey $guestKey -User $guestUser -Expected $frameworkExpected -ServiceLabel $Area `
            -AllowMirrorSource:$AllowMirrorSource
    }
}
$decideServiceStartOutcome = {
    # One record decides the census result, the advertisement and the exit. A
    # stop requested while this start ran wins: nothing is advertised for it.
    $stillWanted = Test-YurunaServiceOperationCurrent -Context $serviceOp
    $startOutcome = Resolve-YurunaServiceStartOutcome -Verdict $verdict -StillWanted $stillWanted -SourceAccepted $sourceAccepted -Degraded $buildDegraded
    if ($startOutcome.Result -eq 'confirmed') { $serviceOpResult = 'confirmed' }
    if (-not $stillWanted) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_start_stop_requested' -Arguments @{ vmName = $VMName; stopScript = $stopScript })
    }
}

# --- REGION: Run the service's readiness phases
# Dot-sourcing the part's script block, not its path: the part shares this
# scope as before, and an exit in it ends this script through the finally
# below. An exit in a dot-sourced script FILE would end only that file and
# fall through to here.
$startPart = Join-Path $PSScriptRoot "Start-ExtensionService.$ServiceKey.ps1"
. (Get-Command -CommandType ExternalScript -Name $startPart).ScriptBlock
} finally {
    [void](Exit-YurunaServiceOperation -Context $serviceOp -Result $serviceOpResult -Confirm:$false)
}
