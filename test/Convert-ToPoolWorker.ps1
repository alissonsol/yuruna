<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42a3e79c-5f14-4b28-8d60-1e9b3c7d5a42
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool worker standalone conversion lab join
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Convert a standalone machine into a pool worker: sync the lab's
    configuration onto it, retire the local services it replaces, converge its
    credentials on the reference host, and verify the result.

.DESCRIPTION
    Sync-HostConfiguration copies a reference host's configuration and reconciles
    the two side channels it depends on. That is the right operation for a
    machine joining a lab, and it is not sufficient for one LEAVING standalone,
    because a standalone machine has running counterparts to everything the new
    configuration now names elsewhere -- and one of them silently wins.

    Extension areas resolve as: operator pin, then a VM on THIS host, then the
    pool's record (Get-ExtensionHostAddress). So a converted host that still has
    its own stash VM keeps using it, forever, and its cycles PASS while doing so.
    The pool's stash is never consulted, no warning is emitted, and the artifacts
    the lab expects to collect are written to a share only this machine can read.
    Stopping the VM does not help either: Restore-YurunaServiceVM starts every
    registered-but-stopped service VM at each cycle start, by design, so the
    service comes back on the next cycle.

    Hence this script, in order:

      1. Pre-flight   -- reference host reachable, shared token available.
      2. Sync         -- test/Sync-HostConfiguration.ps1, with the credential
                         convergence made mandatory.
      3. Teardown     -- every local service VM retired through its own
                         Stop-*ServiceVM.ps1, which clears that service's own
                         marker and deletes the VM's files.
      4. Advertise    -- every runtime marker STILL claimed after step 3
                         withdrawn, and host.registration.json regenerated so
                         this host drops off the dashboard. Driven by the
                         markers rather than by the teardown, because a marker
                         outlives the VM it describes: a host whose service VMs
                         are already gone has no stop script left to run and
                         would go on advertising them forever.
      5. Storage      -- the mounts this machine held of its OWN shares released,
                         the shares and their accounts withdrawn, and the lab's
                         storage mounted in their place.
      6. Aliases      -- hosts-file entries that named a retired local service.
      7. Verify       -- test/Test-Config.ps1, then the question it cannot
                         answer: is the end state actually a worker.

    The shared lab-auth-token is REQUIRED. Without one nothing can be fetched
    from the reference, and the vault entries this machine minted for the shares
    it used to serve itself would survive the conversion -- a password the lab's
    NAS has never seen, on a host whose configuration now points at that NAS.
    That failure surfaces later as a mount error nobody connects to this step.
    Enroll first with test/Set-LabToken.ps1, or pass -SharedToken.

    Step 5 is the one whose necessity is least visible. A standalone machine
    mounts its own shares at exactly the mount points the synced configuration
    now points at the lab's storage, and an SMB client keeps ONE session per
    server name -- so while those mounts stand, a mount of the repointed
    'ypool-nas' is answered by the session to THIS machine, does not find the
    lab's share there, and fails with "No such file or directory" while the
    alias, the share path, the account and the mount point are all correct.

    DATA is never deleted. Step 5 withdraws the share definitions and the
    accounts scoped to them -- machine configuration that is wrong the moment
    this host stops serving -- and leaves every byte under the storage root
    alone: cycle archives, stash artifacts, the lab vault and the pool-intent
    repository all live there, and no automated rule can judge which of them is
    the only copy. The closing output prints what remains and the one command
    that reclaims it. Pass -KeepLocalShares on a machine other hosts still mount
    from.

    Idempotent. A second run finds every service absent, nothing advertised,
    nothing of this machine's own standing in the way of the lab's storage,
    every alias already dropped and every credential already converged, and
    changes nothing.

.PARAMETER ReferenceHost
    Network name or IP of the pool host to copy the configuration from. Any host
    type -- converting between them is the point.

.PARAMETER StatusPort
    The reference host's status-service port. Default 8080.

.PARAMETER SharedToken
    The raw shared lab-auth-token. Omit it when this host is already enrolled
    (test/Set-LabToken.ps1 stores it); this is the path for when the aggregator
    is unreachable and the token has to be carried by hand.

.PARAMETER KeepCachingProxy
    Retire the pool services but leave the local caching-proxy service VM
    running. For a machine on a slow or metered link, where a warm local squid is
    worth its memory even though vmStart.cachingProxyIp now names the lab's.
    Note that its aggregator keeps answering dashboard traffic for a lab this
    host is no longer part of.

.PARAMETER KeepLocalShares
    Keep serving this machine's own pool and stash SMB shares, and keep the
    accounts scoped to them. For a machine other hosts still mount from -- a lab
    whose storage server is being converted into a worker of a bigger lab
    without moving its storage yet. This host stops MOUNTING its own shares
    either way: that release is what lets the lab's storage mount at all.

.PARAMETER SkipValidation
    Skip the Test-Config.ps1 run. The conversion's own verification still runs
    -- it asks a different question.

.PARAMETER NonInteractive
    Never prompt. The confirmation is skipped, and anything needing operator
    input is skipped with a warning.

.PARAMETER Force
    Skip this script's own confirmation prompt. The operating system may still
    prompt (UAC consent, sudo password).

.EXAMPLE
    pwsh test/Set-LabToken.ps1 -LabToken k3v9qa
    pwsh test/Convert-ToPoolWorker.ps1 -ReferenceHost 192.168.7.12
    # The ordinary path: enroll, then convert.

.EXAMPLE
    pwsh test/Convert-ToPoolWorker.ps1 -ReferenceHost alius202607a1 -WhatIf
    # Every step rehearsed, nothing changed.

.EXAMPLE
    pwsh test/Convert-ToPoolWorker.ps1 -ReferenceHost 192.168.7.12 -SharedToken '<raw>' -Force
    # Aggregator unreachable, token carried by hand, unattended.

.NOTES
    Requires Administrator (Windows) or sudo (macOS / Ubuntu): the sync writes
    the hosts file, the teardown removes VMs, and the storage step withdraws the
    SMB shares and their accounts. Expect one password prompt on macOS / Ubuntu.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'SharedToken',
    Justification = 'Forwarded as the plaintext vault stores it, to a sync that takes it the same way; only its HMAC proof crosses the wire.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceHost,

    [Parameter()][int]$StatusPort = 8080,
    [Parameter()][string]$SharedToken = '',
    [switch]$KeepCachingProxy,
    [switch]$KeepLocalShares,
    [switch]$SkipValidation,
    [switch]$NonInteractive,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

# $WhatIfPreference is suppressed across the imports and restored immediately
# after. The host contract's module-level state is built by New-YurunaRegistry,
# whose Set-Variable is under ShouldProcess, so an inherited -WhatIf makes the
# anchor a no-op and the very next line indexes a null array -- a dry run failing
# on module load, three steps before the first thing it was asked to rehearse.
# Only the imports are covered; every ShouldProcess gate this script owns still
# honors the operator's switch.
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
    $paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
    $RepoRoot   = $paths.RepoRoot
    $ModulesDir = $paths.ModulesDir
    $ConfigPath = $paths.ConfigPath

    Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1')     -Global -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1')             -Global -Force
    # Write-HostRegistrationRecord: the advertisement sweep regenerates the
    # registration record so the withdrawal reaches the aggregator on its next
    # poll instead of at the next cycle.
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1')            -Global -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesDir 'Test.PoolWorker.psm1')            -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'extension/authentication/default.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesDir 'Test.ConfigServiceSync.psm1')     -Global -Force -DisableNameChecking
    # LAST, and that ordering is load-bearing. Test.HostContract re-exports
    # Test.HostDetection's Get-HostType / Initialize-YurunaHost, and a later
    # `-Force` import of Test.HostDetection by any other module -- which
    # Test.ConfigServiceSync above does -- unloads the instance those exports
    # point at, leaving Get-HostType unresolvable. Importing the contract after
    # every module that pulls its nested dependencies keeps the host functions
    # this script needs for the service-state probe in scope.
    Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1')          -Global -Force
} finally {
    $WhatIfPreference = $PreviousWhatIf
}

# On KVM the VM contract needs the libvirt group, which a fresh membership does
# not grant an already-running shell. Re-exec before anything is read, so the
# service-state probe below answers from the hypervisor rather than reporting
# every VM 'unknown' and making the teardown plan guess.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# Elevation is asserted before anything happens rather than at the line that
# needs it: the sync rewrites the hosts file and the teardown deletes VMs, and an
# unelevated operator would otherwise pay the reference fetch, the credential
# probes and the config replacement before the first thing that cannot finish.
#
# A rehearsal is exempt. -WhatIf writes nothing, and demanding an Administrator
# shell to LOOK at the plan is what makes an operator skip the preview and run
# the real thing first.
if ($IsWindows -and -not $WhatIfPreference -and -not (Test-IsAdministrator)) {
    Write-Error ('Convert-ToPoolWorker needs an elevated session: the sync writes the hosts file and the teardown removes VMs. ' +
                 'Re-run from an elevated PowerShell (Start-Process pwsh -Verb RunAs), or add -WhatIf to preview from here.')
    exit 1
}

$step = 0
$StepCount = 7
function Write-ConvertStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    $script:step++
    Write-Information '' -InformationAction Continue
    Write-Information "[$script:step/$script:StepCount] $Title" -InformationAction Continue
}

# --- REGION: 1. Pre-flight
# Everything that can refuse the run is asked BEFORE the first change. A
# conversion that syncs the configuration and then discovers it has no token has
# already repointed this host at a lab it cannot authenticate to, which is a
# worse state than the standalone it started from.
Write-ConvertStep -Title "Pre-flight against $ReferenceHost"

$reference = $null
try {
    $reference = Get-ConfigSyncReferenceConfig -ReferenceHost $ReferenceHost -Port $StatusPort
} catch {
    Write-Error ("$ReferenceHost is not serving its configuration on :$StatusPort ($($_.Exception.Message)). " +
                 'Start the status service there (pwsh test/Start-StatusService.ps1) and re-run.')
    exit 1
}
Write-Information "  Reference host $ReferenceHost is serving its configuration." -InformationAction Continue

# The token is resolved here rather than left to the sync, because THIS script
# treats its absence as fatal and the sync does not. Order matches the sync's:
# an explicit -SharedToken wins, else this host's own stored lab-auth-token.
$token = $SharedToken
$tokenSource = 'the -SharedToken parameter'
if (-not $token) {
    $token = Get-LabAuthTokenValue
    $tokenSource = "this host's vault"
}
if (-not $token) {
    Write-Error (
        "This host holds no shared lab-auth-token, so the credentials for the lab's shares cannot be fetched from $ReferenceHost.`n" +
        "Without them the conversion would leave the passwords this machine minted for the shares it served ITSELF -- which the lab's`n" +
        "storage has never seen -- and the mount would fail later with a credential error.`n" +
        "Enroll first:  pwsh test/Set-LabToken.ps1 -LabToken <code from the Yuruna hosts dashboard>`n" +
        "or pass the raw token:  -SharedToken '<value>'")
    exit 1
}
Write-Information "  Shared lab-auth-token available (from $tokenSource)." -InformationAction Continue

# A reference that cannot serve credentials fails the run for the same reason:
# the sync would degrade to prompting, and under -NonInteractive to keeping the
# local value, which is the outcome this conversion exists to prevent. Probed
# with a deliberately wrong proof, so it cannot leak anything.
$refNs = if ($reference -is [System.Collections.IDictionary]) { $reference['networkStorage'] } else { $null }
$refUsers = @()
if ($refNs -is [System.Collections.IDictionary]) {
    foreach ($key in @('poolStorageNetworkUser', 'stashStorageNetworkUser')) {
        $u = if ($refNs.Contains($key)) { "$($refNs[$key])".Trim() } else { '' }
        if ($u -and $refUsers -notcontains $u) { $refUsers += $u }
    }
}
foreach ($user in $refUsers) {
    $capability = Test-ConfigSyncCredentialEndpoint -ReferenceHost $ReferenceHost -Port $StatusPort -User $user
    if (-not $capability.Ready) {
        Write-Error "The '$user' credential cannot be fetched from the reference host -- $($capability.Error)"
        exit 1
    }
}
if ($refUsers.Count -gt 0) {
    Write-Information "  $ReferenceHost can serve the credentials for: $($refUsers -join ', ')." -InformationAction Continue
} else {
    Write-Information "  $ReferenceHost names no networkStorage users; this host will join without shared storage." -InformationAction Continue
}

# Same $WhatIfPreference suppression, and for the same reason, as the imports
# above: the host driver's module-level state is built with Set-Variable under
# ShouldProcess, so an inherited -WhatIf makes the anchor a no-op and the first
# read of that state throws "Cannot find a variable" -- a dry run failing on the
# state it needs to LOOK at the plan, before it has rehearsed anything. Loading a
# driver changes nothing on the host; the gates that do are all below.
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType (Get-HostType))
} finally {
    $WhatIfPreference = $PreviousWhatIf
}
$servicesBefore = @(Get-PoolWorkerServiceState)
$plan = @(Get-PoolWorkerServiceTeardownPlan -Service $servicesBefore)
if ($KeepCachingProxy) {
    # Rewritten rather than filtered out, so the caching proxy still appears in
    # the plan and in the report. A service silently missing from a teardown
    # summary is indistinguishable from one that was never in the roster -- and
    # these two need opposite follow-up, since a kept proxy goes on answering
    # dashboard traffic for a lab this host has left.
    foreach ($item in $plan) {
        if ($item.Key -eq 'caching-proxy' -and $item.Action -eq 'retire') { $item.Action = 'kept' }
    }
}
$toRetire = @($plan | Where-Object { $_.Action -eq 'retire' })
Write-Information '  Local service VMs:' -InformationAction Continue
foreach ($item in $plan) {
    $note = switch ($item.Action) {
        'retire'      { "will be retired (state: $($item.State))" }
        'kept'        { "left running (-KeepCachingProxy); it still answers for this lab's dashboard traffic" }
        'absent'      { 'not built here' }
        'unretirable' { "PRESENT but no stop script could be derived from '$($item.StartScript)'" }
        default       { $item.Action }
    }
    Write-Information "    $($item.DisplayName) -- $note" -InformationAction Continue
}

# The two facts a standalone machine carries that no VM state reports, asked
# before the consent so the operator is told what actually comes down. Both are
# read-only probes: the runtime markers on disk, and the OS share table.
$exemptArea = if ($KeepCachingProxy) { @(Get-PoolWorkerCachingProxyArea) } else { @() }
$runtimeDir = ''
try { $runtimeDir = Initialize-YurunaRuntimeDir } catch { Write-Verbose "runtime dir: $($_.Exception.Message)" }
if (-not $runtimeDir) {
    Write-Warning 'The runtime directory could not be resolved, so what this host advertises to the pool cannot be read -- it may keep claiming services it no longer runs.'
}
$adPlan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea (Get-PoolWorkerAdvertisedArea -RuntimeDir $runtimeDir) -ExemptArea $exemptArea)
$toClear = @($adPlan | Where-Object { $_.Action -eq 'clear' })
if ($adPlan.Count -eq 0) {
    Write-Information '  Extension advertisements: none; this host claims no service.' -InformationAction Continue
} else {
    Write-Information '  Extension advertisements:' -InformationAction Continue
    foreach ($item in $adPlan) {
        $note = if ($item.Action -eq 'clear') { 'will be withdrawn' } else { 'kept (-KeepCachingProxy)' }
        Write-Information "    $($item.Area) -- $note" -InformationAction Continue
    }
}

# Read from the config this host carries NOW. The synced one names the same
# share leaf for each tier -- '//ypool-nas/work/yuruna.pool' and the
# '//ypool-nas/yuruna.pool' a local bring-up publishes both end in
# 'yuruna.pool' -- so the pre-flight answer holds for the post-sync config too.
#
# The YAML import is $WhatIfPreference-suppressed: powershell-yaml registers two
# aliases at load, New-Alias supports ShouldProcess, and a rehearsal would
# otherwise narrate "What if: New Alias" twice into the middle of a report that
# only READS. Reading a config file changes nothing under either preference.
$preflightConfig = $null
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module powershell-yaml -ErrorAction Stop
    if (Test-Path -LiteralPath $ConfigPath) {
        $preflightConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Yaml -Ordered
    }
} catch {
    Write-Verbose "pre-flight config read: $($_.Exception.Message)"
} finally {
    $WhatIfPreference = $PreviousWhatIf
}
$servedShare = @(Get-PoolWorkerServedShare -Tier (Get-PoolWorkerStorageTier -Config $preflightConfig))
if ($servedShare.Count -eq 0) {
    Write-Information '  Storage this machine serves: none; it already mounts its storage from elsewhere.' -InformationAction Continue
} elseif ($KeepLocalShares) {
    Write-Information "  Storage this machine serves: $($servedShare -join ', ') -- left published (-KeepLocalShares); only this host's own mounts of them are released." -InformationAction Continue
} else {
    Write-Information "  Storage this machine serves: $($servedShare -join ', ') -- the shares and their accounts will be withdrawn (the data is kept)." -InformationAction Continue
}

# --- REGION: Consent
if (-not $Force -and -not $NonInteractive -and -not $WhatIfPreference) {
    if (-not (Test-YurunaCanPrompt)) {
        Write-Error 'This session cannot prompt and neither -Force nor -NonInteractive was passed; nothing was changed.'
        exit 1
    }
    Write-Information '' -InformationAction Continue
    Write-Information "This converts this machine from a standalone host into a worker in ${ReferenceHost}'s lab:" -InformationAction Continue
    Write-Information "  * test.config.yml is replaced with ${ReferenceHost}'s, converted for this host (the previous file is backed up)" -InformationAction Continue
    if ($toRetire.Count -gt 0) {
        Write-Information "  * $($toRetire.Count) local service VM(s) are DELETED along with their disks: $(($toRetire | ForEach-Object { $_.DisplayName }) -join ', ')" -InformationAction Continue
    }
    if ($toClear.Count -gt 0) {
        Write-Information "  * this host stops advertising $($toClear.Count) service(s) to the pool: $(($toClear | ForEach-Object { $_.Area }) -join ', ')" -InformationAction Continue
    }
    if ($servedShare.Count -gt 0 -and -not $KeepLocalShares) {
        Write-Information "  * the SMB share(s) $($servedShare -join ', ') and their storage accounts are withdrawn, and this host mounts the lab's storage instead" -InformationAction Continue
    } elseif ($servedShare.Count -gt 0) {
        Write-Information "  * the SMB share(s) $($servedShare -join ', ') stay published (-KeepLocalShares), but this host's own mounts of them are released so the lab's storage can take their place" -InformationAction Continue
    }
    Write-Information "  * the networkStorage vault entries are overwritten with ${ReferenceHost}'s" -InformationAction Continue
    Write-Information '' -InformationAction Continue
    Write-Information 'No data is deleted. Cycle archives, stash artifacts, the lab vault and the' -InformationAction Continue
    Write-Information 'pool-intent repository under the storage root are left exactly as they are;' -InformationAction Continue
    Write-Information 'the command that reclaims that disk is printed at the end for you to run.' -InformationAction Continue
    Write-Information '' -InformationAction Continue
    $answer = (Read-Host 'Proceed? [y/N]').Trim()
    if ($answer -notmatch '^(y|yes)$') {
        Write-Information 'Cancelled; nothing was changed.' -InformationAction Continue
        exit 0
    }
}

# --- REGION: 2. Sync the lab's configuration
# Through the documented redirector rather than the module function, so this
# conversion gets the per-host conversion, the elevation checks, and the
# freshness gate exactly as an operator running the sync by hand would.
#
# -SharedToken is passed explicitly even when it came from this host's own vault:
# the sync would find it again, but passing it makes the value this script
# pre-flighted the value the sync uses, so the two cannot disagree about which
# token the run is built on. Supplying it also makes the sync store it in this
# host's vault and bounce the status service, which is what a converting host
# needs: a worker that syncs a pool config but holds no token accepts control
# only from loopback, and the dashboard's deep link into it answers 403.
Write-ConvertStep -Title "Sync configuration from $ReferenceHost"
$syncScript = Join-Path $PSScriptRoot 'Sync-HostConfiguration.ps1'
# By-name (hashtable) splatting is REQUIRED here. Array splatting binds every
# element POSITIONALLY -- a literal '-ReferenceHost' string element is never
# re-parsed as a parameter name, so it lands in $ReferenceHost and the real
# address, the port and the token all fall through to the sync's
# ValueFromRemainingArguments catch-all. That catch-all is why the mistake is
# silent on this path: the sync binds and runs, and only its own child rejects
# the doubled '-ReferenceHost -ReferenceHost' with a binding error that names a
# script the operator never typed.
#
# -SkipValidation is passed UNCONDITIONALLY, and the validation is run by this
# script at the end instead. Test-Config's storage checks mount the lab's shares,
# and at this point in a conversion they cannot mount: this machine is still
# serving its own shares under the same names and still holds the SMB sessions
# that decide where those names lead. Validating here reports a FAILURE that the
# next two steps exist to remove, which is the worst possible moment to show it
# -- the operator reads a hard failure from a run that has not finished.
$syncArgs = @{
    ReferenceHost              = $ReferenceHost
    StatusPort                 = $StatusPort
    SharedToken                = $token
    RequireReferenceCredential = $true
    SkipValidation             = $true
}
if ($NonInteractive)   { $syncArgs['NonInteractive'] = $true }
if ($WhatIfPreference) { $syncArgs['WhatIf'] = $true }
if ($PSBoundParameters.ContainsKey('Verbose')) { $syncArgs['Verbose'] = $true }

# In-process, not a child pwsh: the sync's own redirector already runs the
# per-host script in its own child, and a second nesting level would put the
# reference-host prompts two pipes away from the operator's console.
& $syncScript @syncArgs
$syncExit = [int]$LASTEXITCODE
if ($syncExit -ne 0) {
    Write-Error ("Sync-HostConfiguration exited $syncExit; the conversion stopped before retiring anything. " +
                 'This host still has its standalone services and, if the sync wrote a config, its backup at test/test.config.yml.backup.')
    exit 1
}

# The sync runs in THIS session and re-imports Test.ConfigServiceSync with
# -Force, which unloads the Test.HostDetection instance Test.HostContract's
# re-exports point at -- so Get-HostType stops resolving from here on. The
# contract is re-imported for the same reason it is imported last above: after
# everything that pulls its nested dependencies. The -WhatIf suppression is
# needed for the same reason too, since New-YurunaRegistry builds the contract's
# module-level state under ShouldProcess.
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
} finally {
    $WhatIfPreference = $PreviousWhatIf
}

# --- REGION: 3. Retire the local services
# After the sync, deliberately. The sync is the step that can refuse (a stale
# reference, an unreachable host, a rejected credential), and a refusal after
# the VMs were deleted would leave a machine with neither its own services nor a
# configuration naming anyone else's.
Write-ConvertStep -Title 'Retire the local service VMs'
if ($toRetire.Count -eq 0) {
    Write-Information '  Nothing to retire.' -InformationAction Continue
}
$teardown = @(Invoke-PoolWorkerServiceTeardown -TestRoot $PSScriptRoot -Plan $plan)
foreach ($result in $teardown) {
    Write-Information "  $($result.DisplayName) -> $($result.Action) ($($result.Message))" -InformationAction Continue
}
$teardownFailed = @($teardown | Where-Object { $_.Action -in @('failed', 'unretirable') })

# --- REGION: 4. Stop advertising the services this host no longer runs
# Re-read rather than reusing the pre-flight list: the teardown above cleared the
# marker of every service it retired, and re-clearing those would report work
# that step 3 already did. What is left here is what no stop script could reach
# -- a claim whose VM was already gone, which is the case that survives every
# re-run and refuses the conversion forever with no step that repairs it.
Write-ConvertStep -Title 'Stop announcing the retired services'
$adPlan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea (Get-PoolWorkerAdvertisedArea -RuntimeDir $runtimeDir) -ExemptArea $exemptArea)
if ($adPlan.Count -eq 0) {
    Write-Information '  Nothing advertised; this host claims no service.' -InformationAction Continue
}
foreach ($outcome in @(Clear-PoolWorkerAdvertisement -Plan $adPlan -RepoRoot $RepoRoot -RuntimeDir $runtimeDir -HostType (Get-HostType))) {
    Write-Information "  $($outcome.Area) -> $($outcome.Action) ($($outcome.Message))" -InformationAction Continue
}

# --- REGION: 5. Hand the storage over to the lab
# Read the POST-SYNC configuration first: every decision below is about the
# tiers this host now mounts from elsewhere, and the file that names them was
# rewritten two steps ago.
$config = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Yaml -Ordered
    } catch {
        Write-Warning "Could not read $ConfigPath ($($_.Exception.Message)); the storage handover, alias cleanup and verification are limited."
    }
}

Write-ConvertStep -Title 'Hand the storage over to the lab'
$tiers = @(Get-PoolWorkerStorageTier -Config $config)
if ($tiers.Count -eq 0) {
    Write-Information '  The synced configuration names no networkStorage tier; nothing to hand over.' -InformationAction Continue
} else {
    # Order is load-bearing, and each step is the precondition of the next.
    #
    # RELEASE first: this host's mounts of its own shares stand on the very mount
    # points the synced config names, and their sessions own the server names it
    # resolves through. Nothing else can mount until they are gone. Released
    # while their server is still up, too -- unmounting a share whose sharepoint
    # has just been withdrawn can wedge on I/O that never completes.
    $released = @(Clear-PoolWorkerSupersededMount -Tier $tiers)
    if ($released.Count -eq 0) {
        Write-Information '  No mount of this host''s own storage is standing in the way.' -InformationAction Continue
    }
    foreach ($item in $released) {
        Write-Information "  $($item.MountPoint) [$($item.Remote)] -> $($item.Action) ($($item.Reason))" -InformationAction Continue
    }
    $releaseFailed = @($released | Where-Object { $_.Action -eq 'failed' })
    foreach ($item in $releaseFailed) {
        Write-Warning ("The mount at $($item.MountPoint) could not be released, so the '$($item.Kind)' tier will not mount: " +
                       "until it goes, its SMB session keeps answering for that server name. Unmount it by hand (macOS: diskutil unmount force '$($item.MountPoint)').")
    }

    # THEN stop serving. Withdrawing the shares while a copy of each is still
    # reachable under the same name is what leaves a machine mounting itself.
    if ($KeepLocalShares) {
        Write-Information '  -KeepLocalShares: the shares and their accounts stay published for the hosts that still mount them.' -InformationAction Continue
    } elseif ($servedShare.Count -eq 0) {
        Write-Information '  This machine publishes no lab share; nothing to withdraw.' -InformationAction Continue
    } else {
        $withdrawal = Invoke-PoolWorkerShareWithdrawal -TestRoot $PSScriptRoot
        if ($withdrawal.Action -in @('failed', 'missing')) {
            Write-Warning "The shares this machine serves were NOT withdrawn: $($withdrawal.Message). It keeps answering for $($servedShare -join ', ') under the same names the lab's storage uses."
        } else {
            Write-Information "  shares + accounts -> $($withdrawal.Action) ($($withdrawal.Message))" -InformationAction Continue
        }
    }

    # ONLY NOW mount. A fresh session to each server name, resolved through the
    # hosts file the sync converged, with nothing of this machine's answering for
    # it any more.
    $hostId = ''
    try { $hostId = [string](Get-YurunaHostId) } catch { Write-Verbose "host id: $($_.Exception.Message)" }
    if (-not $hostId) {
        Write-Warning "This host's id (runtime/host.uuid) could not be resolved, so the pool tier's per-host destination folder is not pre-created; the first replication creates it."
    }
    foreach ($item in @(Connect-PoolWorkerStorage -Tier $tiers -HostId $hostId)) {
        if ($item.Action -eq 'failed') {
            Write-Warning "The $($item.Kind) tier did not mount: $($item.Message)"
        } else {
            Write-Information "  $($item.Kind) storage -> $($item.Message)" -InformationAction Continue
        }
    }
}

# --- REGION: 6. Drop the aliases the retired services owned
# Scoped by the POST-SYNC configuration: a storage alias the new config still
# names is the lab's now, and the sync has repointed it. What comes down is the
# dashboard alias, which named the local proxy VM that step 3 just deleted.
Write-ConvertStep -Title 'Hosts-file aliases'
$candidates = @('yuruna-dash', 'ypool-nas', 'ystash-nas')
$resolution = @{}
foreach ($name in $candidates) {
    $address = ''
    try {
        $addrs = @([System.Net.Dns]::GetHostAddresses($name))
        $pick  = $addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $pick) { $pick = $addrs | Select-Object -First 1 }
        if ($pick) { $address = $pick.ToString() }
    } catch {
        Write-Verbose "resolving '$name': $($_.Exception.Message)"
    }
    $resolution[$name] = $address
}
$aliasPlan = @(Get-PoolWorkerAliasPlan -CandidateName $candidates `
    -ConfiguredServer (Get-PoolWorkerConfiguredServer -Config $config) -Resolution $resolution)
foreach ($outcome in @(Remove-PoolWorkerAlias -RepoRoot $RepoRoot -Plan $aliasPlan -NonInteractive:$NonInteractive)) {
    Write-Information "  $($outcome.Name) -> $($outcome.Action) ($($outcome.Message))" -InformationAction Continue
}

# --- REGION: 7. Verify
# Two questions, in this order. Test-Config validates the FILE and the
# connections it names -- deferred to here, where every step it depends on has
# run, so what it reports is the end state rather than the middle of one. Then
# the question it cannot answer: every failure below is a machine carrying a
# perfectly valid worker configuration while behaving like a standalone.
Write-ConvertStep -Title 'Verify this host is now a pool worker'
if ($WhatIfPreference) {
    Write-Information '  -WhatIf: nothing was changed, so there is no end state to verify.' -InformationAction Continue
    exit 0
}
$validationExit = 0
if ($SkipValidation) {
    Write-Information '  -SkipValidation: test/Test-Config.ps1 was not run.' -InformationAction Continue
} else {
    Write-Information '  Validating the converted host (test/Test-Config.ps1) ...' -InformationAction Continue
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-Config.ps1')
    $validationExit = [int]$LASTEXITCODE
    if ($validationExit -ne 0) {
        Write-Warning "Test-Config.ps1 reported failures (exit $validationExit); review its output above."
    }
}
# Re-asked in-process rather than read off the sync. The sync ran the same
# convergence, but behind the redirector's child pwsh, so its per-user records
# never came back here -- only an exit code, which is 0 for a sync that reported
# an unconverged credential as a warning. Asking again is idempotent (an entry
# that already matches is a no-op and no write) and it is the only way this
# script can name the users that did not converge in its verdict.
$unconverged = @()
$syncCredentials = @(Sync-ConfigSyncVaultCredential -RepoRoot $RepoRoot -NetworkStorage `
    $(if ($config -is [System.Collections.IDictionary] -and $config['networkStorage'] -is [System.Collections.IDictionary]) { $config['networkStorage'] } else { @{} }) `
    -ReferenceHost $ReferenceHost -Port $StatusPort -SharedToken $token `
    -NonInteractive:$NonInteractive -RequireReferenceValue)
foreach ($credential in $syncCredentials) {
    if (-not $credential.Converged) { $unconverged += [string]$credential.User }
}

$verdictArgs = @{ Config = $config; UnconvergedVaultUser = $unconverged; RuntimeDir = $runtimeDir }
# A proxy the operator asked to keep must not fail the verdict for still being
# there. Exempted by key rather than dropped from the probe, so it is still
# reported as running -- just not as a problem. Its areas go with it: the
# aggregator it hosts is a real, running service, so its advertisement is true.
if ($KeepCachingProxy) {
    $verdictArgs['ExemptServiceKey'] = @('caching-proxy')
    $verdictArgs['ExemptArea'] = $exemptArea
}
if ($KeepLocalShares) { $verdictArgs['KeepServedShare'] = $true }
$verdict = Test-PoolWorkerReady @verdictArgs
foreach ($checked in $verdict.Checked) { Write-Information "  checked: $checked" -InformationAction Continue }

$took = '{0:N1}s' -f $elapsed.Elapsed.TotalSeconds
Write-Information '' -InformationAction Continue
if (-not $verdict.Ready) {
    Write-Warning "This host is NOT yet a pool worker (after ${took}):"
    foreach ($problem in $verdict.Problem) { Write-Warning "  * $problem" }
    if ($teardownFailed.Count -gt 0) {
        Write-Warning 'A service teardown did not complete; re-running this script is safe and resumes from where it stopped.'
    }
    exit 1
}
# A worker by every measure this script owns, but with a config the cycle gate
# refuses to start on. Reported as its own outcome rather than folded into the
# verdict above: the conversion converged, and what is left is a configuration
# problem whose reasons Test-Config already printed in full.
if ($validationExit -ne 0) {
    Write-Warning ("This host is a worker in ${ReferenceHost}'s lab (after ${took}), but test/Test-Config.ps1 still reports failures " +
                   'the cycle gate will refuse to start on. Fix those, then re-run: pwsh test/Test-Config.ps1')
    exit 1
}

Write-Information "Done in ${took}: this host is a worker in ${ReferenceHost}'s lab." -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Next:' -InformationAction Continue
if (-not $KeepLocalShares -and $servedShare.Count -gt 0) {
    Write-Information '  pwsh test/Clear-LocalLabStorage.ps1 -ReportOnly   # the data the withdrawn shares still hold, and how to reclaim it' -InformationAction Continue
}
Write-Information '  pwsh test/Invoke-TestProject.ps1                  # one cycle against the lab, before the pool drives it' -InformationAction Continue
exit 0

# Copyright (c) 2019-2026 by Alisson Sol et al.
