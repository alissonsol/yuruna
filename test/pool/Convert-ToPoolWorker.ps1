<#PSScriptInfo
.VERSION 2026.10.11
.GUID 423d3dd4-8e4d-441b-9914-81735aaf24c6
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
    See https://yuruna.link/42010605-0004.
.PARAMETER ReferenceHost
    Network name or IP of the pool host to copy the configuration from. Any host
    type -- converting between them is the point.

.PARAMETER StatusPort
    The reference host's status-service port. Default 8080.

.PARAMETER InternalAuthKey
    The raw internal authentication key. Omit it when this host is already enrolled
    (test/lab/Set-LabToken.ps1 stores it); this is the path for when the aggregator
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
    pwsh test/lab/Set-LabToken.ps1 -LabToken k3v9qa
    pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost 192.168.7.12
    # The ordinary path: enroll, then convert.

.EXAMPLE
    pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost alius202607a1 -WhatIf
    # Every step rehearsed, nothing changed.

.EXAMPLE
    pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost 192.168.7.12 -InternalAuthKey '<raw>' -Force
    # Aggregator unreachable, token carried by hand, unattended.

.NOTES
    Requires Administrator (Windows) or sudo (macOS / Ubuntu): the sync writes
    the hosts file, the teardown removes VMs, and the storage step withdraws the
    SMB shares and their accounts. Expect one password prompt on macOS / Ubuntu.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'InternalAuthKey',
    Justification = 'Forwarded as the plaintext vault stores it, to a sync that takes it the same way; only its HMAC proof crosses the wire.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceHost,

    [Parameter()][int]$StatusPort = 8080,
    [Parameter()][Alias('SharedToken')][string]$InternalAuthKey = '',
    [switch]$KeepCachingProxy,
    [switch]$KeepLocalShares,
    [switch]$SkipValidation,
    [switch]$NonInteractive,
    [switch]$Force
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: https://yuruna.link/42162449-0004
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default. $InformationPreference
# is re-read afterwards because the script-scoped assignment above shadows the
# global the cascade writes.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

# See https://yuruna.link/42010605-0004
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
    $paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
    $RepoRoot   = $paths.RepoRoot
    $TestRoot   = $paths.TestRoot
    $ModulesDir = $paths.ModulesDir
    $ConfigPath = $paths.ConfigPath

    Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1')     -Global -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1')             -Global -Force
    # Write-HostRegistrationRecord: the advertisement sweep regenerates the
    # registration record so the withdrawal reaches the aggregator on its next
    # poll instead of at the next cycle.
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1')            -Global -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesDir 'Test.PoolWorker.psm1')            -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../extension/authentication/default.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $ModulesDir 'Test.ConfigServiceSync.psm1')     -Global -Force -DisableNameChecking
    # See https://yuruna.link/42010605-0004
    Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1')          -Global -Force
} finally {
    $WhatIfPreference = $PreviousWhatIf
}

# On KVM the VM contract needs the libvirt group, which a fresh membership does
# not grant an already-running shell. Re-exec before anything is read, so the
# service-state probe below answers from the hypervisor rather than reporting
# every VM 'unknown' and making the teardown plan guess.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# See https://yuruna.link/42010605-0004
if ($IsWindows -and -not $WhatIfPreference -and -not (Test-IsAdministrator)) {
    Write-Error ((Format-YurunaOperatorMessage -Key 'runner.operator_b42ca86b5468a010'))
    exit 1
}

$step = 0
$StepCount = 7
# --- REGION: Write-ConvertStep
function Write-ConvertStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    $script:step++
    Write-Information '' -InformationAction Continue
    Write-Information "[$script:step/$script:StepCount] $Title" -InformationAction Continue
}

# --- REGION: 1. Pre-flight against the reference host
# Everything that can refuse the run is asked BEFORE the first change. A
# conversion that syncs the configuration and then discovers it has no token has
# already repointed this host at a lab it cannot authenticate to, which is a
# worse state than the standalone it started from.
Write-ConvertStep -Title "Pre-flight against $ReferenceHost"

$reference = $null
try {
    $reference = Get-ConfigSyncReferenceConfig -ReferenceHost $ReferenceHost -Port $StatusPort
} catch {
    Write-Error ((Format-YurunaOperatorMessage -Key 'runner.operator_0b5b89a98217c515' -Arguments @{ referenceHost = "$ReferenceHost"; statusPort = "$StatusPort"; message = "$($_.Exception.Message)" }))
    exit 1
}
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_492e3907acfd538a' -Arguments @{ referenceHost = "$ReferenceHost" }) -InformationAction Continue

# The token is resolved here rather than left to the sync, because THIS script
# treats its absence as fatal and the sync does not. Order matches the sync's:
# an explicit -InternalAuthKey wins, else this host's own stored key.
$token = $InternalAuthKey
$tokenSource = 'the -InternalAuthKey parameter'
if (-not $token) {
    $token = Get-InternalAuthKeyValue
    $tokenSource = "this host's vault"
}
if (-not $token) {
    Write-Error (
        (Format-YurunaOperatorMessage -Key 'runner.operator_12c561c4673122c2' -Arguments @{ referenceHost = "$ReferenceHost" }))
    exit 1
}
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8d497fa5c51c5694' -Arguments @{ tokenSource = "$tokenSource" }) -InformationAction Continue

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
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_05c7282e24926d99' -Arguments @{ user = "$user"; error = "$($capability.Error)" })
        exit 1
    }
}
if ($refUsers.Count -gt 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c4039a9cab875775' -Arguments @{ referenceHost = "$ReferenceHost"; join = "$($refUsers -join ', ')" }) -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_005f0cdc10b5b3bf' -Arguments @{ referenceHost = "$ReferenceHost" }) -InformationAction Continue
}

# See https://yuruna.link/42010605-0004
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
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_48b519cc6b1730fe') -InformationAction Continue
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d032f928223f6a19')
}
$adPlan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea (Get-PoolWorkerAdvertisedArea -RuntimeDir $runtimeDir) -ExemptArea $exemptArea)
$toClear = @($adPlan | Where-Object { $_.Action -eq 'clear' })
if ($adPlan.Count -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6f5475cfe0463b76') -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_2db0e26ab514e113') -InformationAction Continue
    foreach ($item in $adPlan) {
        $note = if ($item.Action -eq 'clear') { 'will be withdrawn' } else { 'kept (-KeepCachingProxy)' }
        Write-Information "    $($item.Area) -- $note" -InformationAction Continue
    }
}

# See https://yuruna.link/42010605-0004
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
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5ba9084b1d879b87') -InformationAction Continue
} elseif ($KeepLocalShares) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_eb02c2b5ad84571f' -Arguments @{ join = "$($servedShare -join ', ')" }) -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f2fc8e0c8ff8ad11' -Arguments @{ join = "$($servedShare -join ', ')" }) -InformationAction Continue
}

# --- REGION: 1b. Consent
if (-not $Force -and -not $NonInteractive -and -not $WhatIfPreference) {
    if (-not (Test-YurunaCanPrompt)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_e00f34b9d984deb1')
        exit 1
    }
    Write-Information '' -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_128daa13cdfaa03b' -Arguments @{ referenceHost = "${ReferenceHost}" }) -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_48a02c490af1798a' -Arguments @{ referenceHost = "${ReferenceHost}" }) -InformationAction Continue
    if ($toRetire.Count -gt 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0d13c4e9be217ef7' -Arguments @{ count = "$($toRetire.Count)"; join = "$(($toRetire | ForEach-Object { $_.DisplayName }) -join ', ')" }) -InformationAction Continue
    }
    if ($toClear.Count -gt 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9b91e6b509e4aa1d' -Arguments @{ count = "$($toClear.Count)"; join = "$(($toClear | ForEach-Object { $_.Area }) -join ', ')" }) -InformationAction Continue
    }
    if ($servedShare.Count -gt 0 -and -not $KeepLocalShares) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b8c9d8a96559ab86' -Arguments @{ join = "$($servedShare -join ', ')" }) -InformationAction Continue
    } elseif ($servedShare.Count -gt 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c552ef08d35b50bd' -Arguments @{ join = "$($servedShare -join ', ')" }) -InformationAction Continue
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9e0394d14d46767b' -Arguments @{ referenceHost = "${ReferenceHost}" }) -InformationAction Continue
    Write-Information '' -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ab7b14042d87e157') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_051583e964e5ccb5') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_93d9eec8ac1ddbb1') -InformationAction Continue
    Write-Information '' -InformationAction Continue
    $answer = (Read-Host 'Proceed? [y/N]').Trim()
    if ($answer -notmatch '^(y|yes)$') {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_2b91fa5b6a130260') -InformationAction Continue
        exit 0
    }
}

# --- REGION: 2. Sync configuration from the reference host
# See https://yuruna.link/42010605-0004
Write-ConvertStep -Title "Sync configuration from $ReferenceHost"
$syncScript = Join-Path $TestRoot 'lab/Sync-HostConfiguration.ps1'
# See https://yuruna.link/42010605-0004
$syncArgs = @{
    ReferenceHost              = $ReferenceHost
    StatusPort                 = $StatusPort
    InternalAuthKey            = $token
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
    Write-Error ((Format-YurunaOperatorMessage -Key 'runner.operator_ac5925b7ec6e9ced' -Arguments @{ syncExit = "$syncExit" }))
    exit 1
}

# See https://yuruna.link/42010605-0004
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
} finally {
    $WhatIfPreference = $PreviousWhatIf
}

# --- REGION: 3. Retire the local service VMs
# After the sync, deliberately. The sync is the step that can refuse (a stale
# reference, an unreachable host, a rejected credential), and a refusal after
# the VMs were deleted would leave a machine with neither its own services nor a
# configuration naming anyone else's.
Write-ConvertStep -Title 'Retire the local service VMs'
if ($toRetire.Count -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7b3131e52bc106ed') -InformationAction Continue
}
$teardown = @(Invoke-PoolWorkerServiceTeardown -TestRoot $TestRoot -Plan $plan)
foreach ($result in $teardown) {
    Write-Information "  $($result.DisplayName) -> $($result.Action) ($($result.Message))" -InformationAction Continue
}
$teardownFailed = @($teardown | Where-Object { $_.Action -in @('failed', 'unretirable') })

# --- REGION: 4. Stop announcing the retired services
# Re-read rather than reusing the pre-flight list: the teardown above cleared the
# marker of every service it retired, and re-clearing those would report work
# that step 3 already did. What is left here is what no stop script could reach
# -- a claim whose VM was already gone, which is the case that survives every
# re-run and refuses the conversion forever with no step that repairs it.
Write-ConvertStep -Title 'Stop announcing the retired services'
$adPlan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea (Get-PoolWorkerAdvertisedArea -RuntimeDir $runtimeDir) -ExemptArea $exemptArea)
if ($adPlan.Count -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e4ef019adc61cf69') -InformationAction Continue
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a68e62c0387fe161' -Arguments @{ configPath = "$ConfigPath"; message = "$($_.Exception.Message)" })
    }
}

Write-ConvertStep -Title 'Hand the storage over to the lab'
$tiers = @(Get-PoolWorkerStorageTier -Config $config)
if ($tiers.Count -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d37c37886aaefc65') -InformationAction Continue
} else {
    # See https://yuruna.link/42010605-0004
    $released = @(Clear-PoolWorkerSupersededMount -Tier $tiers)
    if ($released.Count -eq 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a1491541b62120ad') -InformationAction Continue
    }
    foreach ($item in $released) {
        Write-Information "  $($item.MountPoint) [$($item.Remote)] -> $($item.Action) ($($item.Reason))" -InformationAction Continue
    }
    $releaseFailed = @($released | Where-Object { $_.Action -eq 'failed' })
    foreach ($item in $releaseFailed) {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_18e115dd3f5303d5' -Arguments @{ mountPoint = "$($item.MountPoint)"; kind = "$($item.Kind)"; mountPoint2 = "$($item.MountPoint)" }))
    }

    # THEN stop serving. Withdrawing the shares while a copy of each is still
    # reachable under the same name is what leaves a machine mounting itself.
    if ($KeepLocalShares) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_1cb00ee9f6034d6e') -InformationAction Continue
    } elseif ($servedShare.Count -eq 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_271f3ed69f32cd7c') -InformationAction Continue
    } else {
        $withdrawal = Invoke-PoolWorkerShareWithdrawal -TestRoot $TestRoot
        if ($withdrawal.Action -in @('failed', 'missing')) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_65802ea5d5be8110' -Arguments @{ message = "$($withdrawal.Message)"; join = "$($servedShare -join ', ')" })
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_105801cd48a8b5ae')
    }
    foreach ($item in @(Connect-PoolWorkerStorage -Tier $tiers -HostId $hostId)) {
        if ($item.Action -eq 'failed') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a40a19ce8bb36556' -Arguments @{ kind = "$($item.Kind)"; message = "$($item.Message)" })
        } else {
            Write-Information "  $($item.Kind) storage -> $($item.Message)" -InformationAction Continue
        }
    }
}

# --- REGION: 6. Hosts-file aliases
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

# --- REGION: 7. Verify this host is now a pool worker
# Two questions, in this order. Test-Config validates the FILE and the
# connections it names -- deferred to here, where every step it depends on has
# run, so what it reports is the end state rather than the middle of one. Then
# the question it cannot answer: every failure below is a machine carrying a
# perfectly valid worker configuration while behaving like a standalone.
Write-ConvertStep -Title 'Verify this host is now a pool worker'
if ($WhatIfPreference) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e45625b8aae24091') -InformationAction Continue
    exit 0
}
$validationExit = 0
if ($SkipValidation) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_48c2def57446e5b5') -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f91fa6f03cfc81e6') -InformationAction Continue
    & pwsh -NoProfile -File (Join-Path $TestRoot 'Test-Config.ps1')
    $validationExit = [int]$LASTEXITCODE
    if ($validationExit -ne 0) {
        Write-Warning "Test-Config.ps1 reported failures (exit $validationExit); review its output above."
    }
}
# See https://yuruna.link/42010605-0004
$unconverged = @()
$syncCredentials = @(Sync-ConfigSyncVaultCredential -RepoRoot $RepoRoot -NetworkStorage `
    $(if ($config -is [System.Collections.IDictionary] -and $config['networkStorage'] -is [System.Collections.IDictionary]) { $config['networkStorage'] } else { @{} }) `
    -ReferenceHost $ReferenceHost -Port $StatusPort -InternalAuthKey $token `
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_46a2f78e87cff704' -Arguments @{ took = "${took}" })
    foreach ($problem in $verdict.Problem) { Write-Warning "  * $problem" }
    if ($teardownFailed.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ff67962efb5a7e60')
    }
    exit 1
}
# A worker by every measure this script owns, but with a config the cycle gate
# refuses to start on. Reported as its own outcome rather than folded into the
# verdict above: the conversion converged, and what is left is a configuration
# problem whose reasons Test-Config already printed in full.
if ($validationExit -ne 0) {
    Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_4c525448b228ec4a' -Arguments @{ referenceHost = "${ReferenceHost}"; took = "${took}" }))
    exit 1
}

Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_539a739cfc7d9841' -Arguments @{ took = "${took}"; referenceHost = "${ReferenceHost}" }) -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Next:' -InformationAction Continue
if (-not $KeepLocalShares -and $servedShare.Count -gt 0) {
    Write-Information '  pwsh test/lab/Clear-LocalLabStorage.ps1 -ReportOnly   # the data the withdrawn shares still hold, and how to reclaim it' -InformationAction Continue
}
Write-Information '  pwsh test/Invoke-TestProject.ps1                  # one cycle against the lab, before the pool drives it' -InformationAction Continue
exit 0
