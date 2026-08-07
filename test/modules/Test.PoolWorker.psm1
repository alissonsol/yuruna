<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42c9e4a7-1b83-4d56-9e07-3a5c8b1d4e26
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool worker standalone conversion service teardown
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
    Turning a standalone host into a pool worker: the decisions, as pure rules,
    plus the host-neutral steps that act on them.
.DESCRIPTION
    A standalone machine runs the whole lab by itself -- its own caching proxy,
    its own stash, its own pool-control and download-agent services, its own SMB
    shares served over a loopback alias, and locally minted credentials for all
    of it. Joining a lab replaces every one of those with a remote counterpart,
    and Sync-HostConfiguration replaces the CONFIGURATION that names them. What
    it cannot do is retire the things the old configuration pointed at, and three
    of those actively defeat the conversion if they are left running:

      * a local service VM WINS the lookup. Get-ExtensionHostAddress resolves an
        area as operator pin -> a VM on THIS host -> the pool's record, so a
        leftover stash VM keeps serving this host's cycles and the lab's stash is
        never consulted. Nothing reports this: the cycles pass, against the wrong
        service.
      * a registered-but-stopped service VM is STARTED again at every cycle
        start by Restore-YurunaServiceVM, so stopping one is not a teardown.
      * the runtime/<area>.json markers keep this host advertised to the
        aggregator as running services it no longer should, which is what the
        dashboard's Extension hosts row deep-links into. A marker outlives the
        VM it describes -- a host whose service VMs were removed by other means
        goes on advertising them forever -- so the advertisements are swept from
        the markers themselves rather than as a side effect of the VM teardown.
      * the SMB shares this machine SERVED are still published, their accounts
        still exist, and its own mounts of them still stand on the very mount
        points the synced configuration now points at the lab's storage. That
        last one is not merely untidy: an SMB client keeps ONE session per
        server name, so while a mount made against this machine under the name
        'ypool-nas' is up, a mount of the repointed 'ypool-nas' is answered by
        the OLD session, fails to find the lab's share there, and reports "No
        such file or directory" with every visible detail correct.

    So the conversion is a teardown as much as a sync, and it has to converge:
    an operator who runs it twice, or who runs it on a machine half-way through
    an earlier attempt, must land in the same place. Every rule below is
    therefore expressed over OBSERVED state rather than over what a previous run
    did, and every step reports 'absent' where there was nothing to do.

    The pure halves (which VMs to retire, which aliases are stale, whether the
    end state is actually a worker) are separated from the acting halves so the
    rules can be verified on any platform without a hypervisor, a lab, or a
    reachable reference host.
#>

# Get-YurunaServiceVmRoster is the single source of truth for "which VMs are
# services", and the extension half of it is discovered from the area manifests
# -- so a service added to the framework joins this teardown by existing.
Import-Module (Join-Path $PSScriptRoot 'Test.ServiceVm.psm1')        -Force -DisableNameChecking -Verbose:$false
Import-Module (Join-Path $PSScriptRoot 'Test.ExtensionService.psm1') -Force -DisableNameChecking -Verbose:$false
# Get-PoolStorageServerName: the share-path grammar lives in one module, so this
# converter and the mount path cannot disagree on what a share path names. The
# same module owns the mount table, the superseded-mount rule and the mount
# itself, which is the whole storage half of the conversion.
Import-Module (Join-Path $PSScriptRoot 'Test.PoolStorage.psm1')      -Force -DisableNameChecking -Verbose:$false
# Get-LocalLabStorageSharePath: whether this machine still PUBLISHES a share can
# only be answered by the OS share table -- the configuration of a machine backed
# by a NAS and one serving its own shares is identical in every key.
#
# -Global is load-bearing here, unlike the two imports above. Test.LocalLabStorage
# is a module ENTRY POINTS import for their own use, and a bare `-Force` import
# from inside this one unloads the instance their exports resolve through: the
# caller keeps running with the commands it loaded a moment ago no longer
# defined, and fails on the first call with "not recognized as a name of a
# cmdlet". Re-importing globally keeps one instance that both scopes see.
Import-Module (Join-Path $PSScriptRoot 'Test.LocalLabStorage.psm1')  -Global -Force -DisableNameChecking -Verbose:$false
# Get-SudoPwshArgumentList (the nested-sudo argument vector) lives here.
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1') -Global -Force -DisableNameChecking -Verbose:$false

# Every list-returning function below hands its result to the pipeline, which
# unrolls it: a one-element result arrives at the caller as the bare element, and
# an empty one as nothing at all. Callers therefore wrap in `@(...)`, the same
# contract every other roster/plan producer in this tree keeps. The `return ,$x`
# idiom is deliberately NOT used here -- it fixes the one-element case and breaks
# the empty one into a single empty array, and these functions return empty
# routinely (a host with no service built, a config naming no storage).

# The hosts-file names a standalone bring-up publishes that a worker has no use
# for. The two storage aliases are handled by NAME rather than by this list --
# a lab's NAS may legitimately carry the same name, and the sync repoints it --
# so only the dashboard alias is unconditional here. install/setup.ps1 publishes
# it from the local proxy's lease, and the proxy is the first VM this conversion
# retires, so it is dangling by definition the moment the teardown runs.
$script:StandaloneOnlyAlias = @('yuruna-dash')

# The extension areas the caching-proxy VM answers for. The aggregator is hosted
# INSIDE that VM and declares no vmName of its own, so no service-roster entry
# covers it and nothing else would keep its marker alive when the operator keeps
# the proxy running.
$script:CachingProxyArea = @('caching-proxy-service', 'caching-proxy-parser-service', 'pool-aggregator-service')

# --- REGION: Pure rules (no I/O; unit-tested directly)

<#
.SYNOPSIS
    Which extension advertisements a converted worker should withdraw. Pure:
    takes the areas this host currently claims and the ones the caller is
    keeping on purpose.
.DESCRIPTION
    Driven by the MARKERS, not by the service teardown, and that is the whole
    point. Each Stop-*ServiceVM.ps1 clears its own marker, so a conversion that
    retires a VM also stops advertising it -- but a host whose VMs are already
    gone (removed by hand, lost with a hypervisor reinstall, or retired by an
    earlier half-finished conversion) has nothing left to run a stop script
    against, and its markers survive every re-run. The dashboard then deep-links
    into services that do not exist, and the conversion's own verdict refuses
    the host forever with no step that can fix it.

    So the sweep asks the only question that converges: what does this host
    still claim? Anything it claims and is not deliberately running comes down.
.OUTPUTS
    [pscustomobject[]] Area, Action ('clear' or 'kept'), Reason.
#>
function Get-PoolWorkerAdvertisementPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        # Areas with a live runtime marker (Get-ActiveExtensionService).
        # AllowEmptyString because Mandatory otherwise rejects the whole array
        # over one blank element, and a blank is something to skip, not to fail.
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][AllowEmptyString()][string[]]$AdvertisedArea,
        # Areas the caller is keeping on purpose, so their claim is still true.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ExemptArea
    )
    $exempt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($ExemptArea)) {
        $v = "$e".Trim()
        if ($v) { [void]$exempt.Add($v) }
    }
    $plan = [System.Collections.Generic.List[pscustomobject]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in @($AdvertisedArea)) {
        $area = "$raw".Trim()
        if (-not $area -or -not $seen.Add($area)) { continue }
        if ($exempt.Contains($area)) {
            [void]$plan.Add([pscustomobject]@{ Area = $area; Action = 'kept'
                Reason = 'the caller is still running this service, so the advertisement is true' })
            continue
        }
        [void]$plan.Add([pscustomobject]@{ Area = $area; Action = 'clear'
            Reason = 'this host no longer runs the service the marker advertises' })
    }
    return [pscustomobject[]]@($plan)
}

<#
.SYNOPSIS
    The share name a networkStorage path ends in -- which is also the name a
    local storage bring-up publishes for that tier. '' when the path names no
    share. Pure.
.DESCRIPTION
    The two layouts a tier is reached through differ in everything but this. A
    NAS carries a directory inside a share ('//ypool-nas/work/yuruna.pool'); a
    machine serving its own storage publishes the share itself
    ('//ypool-nas/yuruna.pool'). New-LocalLabStorage.ps1 names that published
    share after the tier, so the leaf segment is the name to look for in the OS
    share table whichever layout the configuration currently carries -- and the
    configuration after a sync carries the NAS one, which is exactly when the
    question "does this machine still publish it?" needs asking.
#>
function Get-PoolWorkerLocalShareName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$NetworkPath)
    $p = "$NetworkPath".Trim().Replace('\', '/').TrimEnd('/')
    if (-not $p) { return '' }
    $parts = @($p.TrimStart('/') -split '/' | Where-Object { $_ })
    # server alone is not a share, and a share needs a server in front of it.
    if ($parts.Count -lt 2) { return '' }
    return [string]$parts[-1]
}

<#
.SYNOPSIS
    The Stop-*ServiceVM.ps1 that retires what a roster entry's StartScript
    builds, or '' when the name does not have that shape. Pure.
.DESCRIPTION
    Derived rather than listed. The roster carries StartScript because a
    reboot sweep needs it; adding a parallel StopScript field would be a second
    place for the pairing to drift, and the pairing is a naming convention the
    whole tree already keeps (install/setup.ps1's Invoke-ServiceVMEnsure states
    both names for exactly the same pairs).

    Anything not matching 'Start-<something>.ps1' yields '' so the caller reports
    a service it cannot retire instead of composing a path that does not exist.
#>
function Get-PoolWorkerStopScriptName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$StartScript)
    $name = "$StartScript".Trim()
    if ($name -notmatch '^Start-(?<rest>.+\.ps1)$') { return '' }
    return "Stop-$($Matches['rest'])"
}

<#
.SYNOPSIS
    What to do with each local service VM when this host becomes a pool worker.
    Pure: takes the observed states, returns one decision per service.
.DESCRIPTION
    Every service is retired, with no exception for the caching proxy. A worker
    reads vmStart.cachingProxyIp -- which the sync has just repointed at the
    lab's proxy -- so a local cache VM is memory and disk spent on a squid no
    client is configured to use, and its aggregator would go on answering
    dashboard traffic for a lab it is not part of.

    'absent' is the converged state, not a failure: it is what a second run
    sees, and what a host that never built the service sees. The distinction
    that matters is 'unretirable' -- a VM that exists with no stop script to
    retire it -- because that one needs an operator, and reporting it as
    anything softer would let a conversion claim an end state it did not reach.
.OUTPUTS
    [pscustomobject[]] Key, VMName, DisplayName, State, StopScript, Action
    (one of 'retire', 'absent', 'unretirable').
#>
function Get-PoolWorkerServiceTeardownPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        # Roster records enriched with a State field: Key, VMName, DisplayName,
        # StartScript, State.
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Service
    )
    $plan = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($svc in $Service) {
        $state = "$($svc.State)".Trim()
        $stop  = Get-PoolWorkerStopScriptName -StartScript ([string]$svc.StartScript)
        # 'unknown' is treated as PRESENT. It means the host driver could not
        # answer, and assuming absence there would skip the teardown of a VM
        # that is running -- the one outcome this conversion cannot tolerate,
        # since a live local service silently wins every lookup. A stop script
        # run against a genuinely absent VM is a cheap no-op; the reverse is not.
        $exists = ($state -ne 'absent')
        $action = if (-not $exists) { 'absent' } elseif (-not $stop) { 'unretirable' } else { 'retire' }
        [void]$plan.Add([pscustomobject]@{
            Key         = [string]$svc.Key
            VMName      = [string]$svc.VMName
            DisplayName = [string]$svc.DisplayName
            State       = $state
            StopScript  = $stop
            Action      = $action
        })
    }
    return [pscustomobject[]]@($plan)
}

<#
.SYNOPSIS
    Which hosts-file aliases a converted worker should drop. Pure: takes the
    published names, the names the synced config still needs, and how each one
    resolves here.
.DESCRIPTION
    Two different questions, and conflating them is what makes this dangerous.

    The DASHBOARD alias is standalone-only by construction: it names this
    machine's own proxy VM, which the teardown has just deleted, so it is
    dropped whenever it resolves to anything at all.

    A STORAGE alias is not standalone-only. 'ypool-nas' means this machine on a
    host that served its own shares and the lab's NAS on a host that does not,
    and the synced config names the tier by that same name either way -- so an
    alias the config still needs is KEPT, whatever it resolves to. The sync owns
    repointing it (Sync-ConfigSyncHostAlias converges every configured name onto
    the reference host's answer); dropping it here would undo that and leave the
    mount with a name nothing resolves.

    What is left is the interesting case: a storage alias the machine published,
    resolving to LOOPBACK, that the synced config no longer names. That is a
    dangling pointer at a share this machine is about to stop serving, and
    nothing else will ever clean it up.
.OUTPUTS
    [pscustomobject[]] Name, Address, Action ('drop' or 'keep'), Reason.
#>
function Get-PoolWorkerAliasPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        # Names to consider: the storage server aliases a local bring-up
        # publishes, plus whatever the caller adds.
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CandidateName,
        # Server names the POST-SYNC config still names. Never dropped.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ConfiguredServer,
        # name -> address as THIS host resolves it now; a name absent from the
        # map (or mapping to '') does not resolve and is nothing to drop.
        [Parameter()][AllowNull()][System.Collections.IDictionary]$Resolution
    )
    $configured = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in @($ConfiguredServer)) {
        $v = "$c".Trim()
        if ($v) { [void]$configured.Add($v) }
    }
    $plan = [System.Collections.Generic.List[pscustomobject]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in @($CandidateName)) {
        $name = "$raw".Trim()
        if (-not $name -or -not $seen.Add($name)) { continue }
        $address = ''
        if ($Resolution -and $Resolution.Contains($name)) { $address = "$($Resolution[$name])".Trim() }

        if (-not $address) {
            [void]$plan.Add([pscustomobject]@{ Name = $name; Address = ''; Action = 'keep'
                Reason = 'does not resolve here, so there is no entry to drop' })
            continue
        }
        if ($configured.Contains($name)) {
            [void]$plan.Add([pscustomobject]@{ Name = $name; Address = $address; Action = 'keep'
                Reason = "the synced configuration still names this server; the sync owns where it points ($address)" })
            continue
        }
        if ($script:StandaloneOnlyAlias -contains $name) {
            [void]$plan.Add([pscustomobject]@{ Name = $name; Address = $address; Action = 'drop'
                Reason = 'names a service VM this host no longer runs' })
            continue
        }
        $parsed = [System.Net.IPAddress]::Any
        $isLoopback = [System.Net.IPAddress]::TryParse($address, [ref]$parsed) -and [System.Net.IPAddress]::IsLoopback($parsed)
        if ($isLoopback) {
            [void]$plan.Add([pscustomobject]@{ Name = $name; Address = $address; Action = 'drop'
                Reason = 'points at a share this host served and the synced configuration no longer names' })
            continue
        }
        # Resolves off-box and the config does not name it: someone else's, or an
        # earlier lab's. Not this conversion's to remove.
        [void]$plan.Add([pscustomobject]@{ Name = $name; Address = $address; Action = 'keep'
            Reason = "resolves off this machine ($address); not published by a local storage bring-up" })
    }
    return [pscustomobject[]]@($plan)
}

<#
.SYNOPSIS
    Whether this host has actually become a pool worker. Pure: takes the
    observed facts, returns the verdict and the operator-actionable reasons.
.DESCRIPTION
    The check a conversion needs and Test-Config cannot give: Test-Config
    validates the FILE, and every failure below is a machine that carries a
    perfectly valid worker configuration while behaving like a standalone.

    Ordered by how badly each one misleads. A surviving service VM comes first
    because it is the only failure that produces GREEN cycles run against the
    wrong service; storage that still resolves to -- or is still served by --
    this machine is next, because the cycles then replicate into a share the lab
    cannot see; the credential, mount and proxy checks follow, because those fail
    loudly and get fixed.
.OUTPUTS
    [pscustomobject] Ready [bool], Problem [string[]], Checked [string[]].
#>
function Get-PoolWorkerReadinessVerdict {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Post-teardown service records: Key, DisplayName, State.
        [Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Service,
        # Marker areas this host still advertises (Get-ActiveExtensionService).
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ActiveExtension,
        # $true when a configured storage tier still resolves to this machine.
        [Parameter()][AllowNull()][object]$StorageIsLocal,
        # Share names this machine still PUBLISHES for a tier its configuration
        # now mounts from elsewhere.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ServedShare,
        # Configured tiers whose share is not mounted at its localPath.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$UnmountedTier,
        # networkStorage users whose vault entry did NOT converge on the
        # reference host's value. Names only -- no secret reaches this rule.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$UnconvergedVaultUser,
        # vmStart.cachingProxyIp after the sync.
        [Parameter()][AllowEmptyString()][AllowNull()][string]$CachingProxyIp,
        # $true when that address is one of THIS machine's own.
        [Parameter()][AllowNull()][object]$CachingProxyIsLocal,
        # Roster keys the caller deliberately left running, so the verdict does
        # not fail a conversion for doing exactly what it was asked to do. Named
        # rather than inferred: "still present" and "still present ON PURPOSE"
        # are indistinguishable from the observed state alone.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ExemptServiceKey
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $checked = [System.Collections.Generic.List[string]]::new()
    $exempt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($ExemptServiceKey)) {
        $v = "$k".Trim()
        if ($v) { [void]$exempt.Add($v) }
    }

    [void]$checked.Add('local service VMs retired')
    foreach ($svc in @($Service)) {
        $state = "$($svc.State)".Trim()
        if ($state -eq 'absent') { continue }
        if ($exempt.Contains("$($svc.Key)".Trim())) { continue }
        # 'unknown' is reported rather than passed: it means the host driver
        # could not answer, and a conversion cannot certify a VM it could not
        # look at. The remedy differs, so the sentence does too.
        $observed = if ($state -eq 'unknown') {
            "could not be read (the per-host VM contract did not answer)"
        } else {
            "is still registered on this host (state: $state)"
        }
        [void]$problem.Add("The $($svc.DisplayName) VM ($($svc.VMName)) $observed. A local service VM wins the address lookup over the pool's, so this host would keep using its own instead of the lab's -- and its cycles would pass while doing it. Re-run the conversion, or retire the VM with its own test/Stop-*ServiceVM.ps1.")
    }

    [void]$checked.Add('extension advertisements cleared')
    foreach ($area in @($ActiveExtension)) {
        $a = "$area".Trim()
        if (-not $a) { continue }
        [void]$problem.Add("This host still advertises '$a' to the pool aggregator (runtime/$a.json). The dashboard's Extension hosts row will deep-link into a service that is gone.")
    }

    [void]$checked.Add('storage served remotely')
    if ($StorageIsLocal -is [bool] -and $StorageIsLocal) {
        [void]$problem.Add('A configured networkStorage server still resolves to this machine, so cycles would replicate into a share the rest of the lab cannot read. Check the hosts-file alias against the reference host.')
    }
    foreach ($share in @($ServedShare)) {
        $s = "$share".Trim()
        if (-not $s) { continue }
        [void]$problem.Add("This machine still publishes the SMB share '$s', which is the share its configuration now mounts from the lab. Serving it keeps a second copy of the tier alive behind the same name, and its live session decides where a mount of that name actually lands. Withdraw it with test/Clear-LocalLabStorage.ps1 (no data is deleted).")
    }

    [void]$checked.Add('the lab''s storage is mounted here')
    foreach ($tier in @($UnmountedTier)) {
        $t = "$tier".Trim()
        if (-not $t) { continue }
        [void]$problem.Add("The $t tier is configured but is not mounted at its localPath, so this host would run cycles that cannot reach the lab's $t storage -- replication and stash uploads buffer locally and are lost with the VM. Re-run this script, or see the mount error in test/Test-Config.ps1.")
    }

    [void]$checked.Add('credentials converged on the reference host')
    foreach ($user in @($UnconvergedVaultUser)) {
        $u = "$user".Trim()
        if (-not $u) { continue }
        [void]$problem.Add("The vault credential for '$u' did not converge on the reference host's, so this host still holds a locally generated password the lab's share has never seen. The mount will fail with a credential error.")
    }

    [void]$checked.Add('caching proxy is the lab''s')
    $proxy = "$CachingProxyIp".Trim()
    if (-not $proxy) {
        [void]$problem.Add('vmStart.cachingProxyIp is empty after the sync, so this host has no caching proxy and no aggregator to register with.')
    } elseif ($CachingProxyIsLocal -is [bool] -and $CachingProxyIsLocal) {
        [void]$problem.Add("vmStart.cachingProxyIp ($proxy) is an address of this machine. A worker points at the lab's proxy; the reference host's configuration should have supplied it.")
    }

    return [pscustomobject]@{
        Ready   = ($problem.Count -eq 0)
        Problem = [string[]]@($problem)
        Checked = [string[]]@($checked)
    }
}

# --- REGION: Observation and action

<#
.SYNOPSIS
    The service roster enriched with each VM's current state on this host.
.DESCRIPTION
    'unknown' rather than a throw when the per-host VM contract is not loaded or
    a driver call fails -- Get-PoolWorkerServiceTeardownPlan treats unknown as
    present, so an unreadable state costs a redundant stop-script run rather
    than a skipped teardown.
.OUTPUTS
    [pscustomobject[]] the roster records plus State.
#>
function Get-PoolWorkerServiceState {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    $roster = @(Get-YurunaServiceVmRoster)
    $canState = [bool](Get-Command Get-VMState -ErrorAction SilentlyContinue)
    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($svc in $roster) {
        $state = 'unknown'
        if ($canState) {
            try { $state = [string](Get-VMState -VMName $svc.VMName) } catch {
                Write-Verbose "Get-PoolWorkerServiceState('$($svc.VMName)'): $($_.Exception.Message)"
            }
        }
        [void]$out.Add([pscustomobject]@{
            Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
            StartScript = $svc.StartScript; HealthPort = $svc.HealthPort; State = $state
        })
    }
    return [pscustomobject[]]@($out)
}

<#
.SYNOPSIS
    Retires the local service VMs named by a teardown plan, by running each
    service's own Stop-*ServiceVM.ps1. Returns one result record per service.
.DESCRIPTION
    The stop scripts are reused rather than reimplemented because each one does
    more than stop a VM: it clears the extension marker, refreshes
    host.registration.json so the host drops off the dashboard within one
    aggregator poll, removes the VM AND its on-disk files, and -- for the
    caching proxy -- tears down the host proxy settings and the yuruna-managed
    port forwards. Every one of those is part of the conversion, and none of
    them is discoverable from a Remove-VM call.

    Each runs in a CHILD pwsh. They are entry-point scripts that call
    Initialize-YurunaHost and import their own module set globally; running four
    of them in this session would leave the caller holding whichever host driver
    the last one imported. A child also contains a stop that fails: the
    conversion reports it and carries on to the next service rather than
    abandoning the remaining teardown.
.OUTPUTS
    [pscustomobject[]] Key, DisplayName, Action ('retired', 'absent',
    'unretirable', 'failed', 'whatif'), ExitCode, Message.
#>
function Invoke-PoolWorkerServiceTeardown {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan
    )
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $pwshExe = [System.Environment]::ProcessPath
    foreach ($item in $Plan) {
        if ($item.Action -eq 'absent') {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'absent'; ExitCode = 0; Message = 'not built on this host' })
            continue
        }
        # A caller may have downgraded an entry to 'kept' (the conversion's
        # -KeepCachingProxy). Passed through with its own action rather than
        # folded into 'absent': the report has to distinguish a service that was
        # never here from one deliberately left running, because only the second
        # one goes on answering for a lab this host has left.
        if ($item.Action -eq 'kept') {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'kept'; ExitCode = 0
                Message = "left running at the caller's request (state: $($item.State))" })
            continue
        }
        if ($item.Action -eq 'unretirable') {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'unretirable'; ExitCode = -1
                Message = "the VM '$($item.VMName)' exists but no Stop script could be derived from '$($item.StartScript)'; remove it with the host's own tooling" })
            continue
        }
        $script = Join-Path $TestRoot $item.StopScript
        if (-not (Test-Path -LiteralPath $script)) {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'unretirable'; ExitCode = -1; Message = "$($item.StopScript) not found in $TestRoot" })
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.VMName, "Retire the $($item.DisplayName) VM and delete its files")) {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'whatif'; ExitCode = 0; Message = "would run $($item.StopScript)" })
            continue
        }
        if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'failed'; ExitCode = -1; Message = 'the running pwsh executable could not be located, so the stop script could not be launched' })
            continue
        }
        Write-Information "  Retiring the $($item.DisplayName) VM ($($item.VMName), state: $($item.State)) ..." -InformationAction Continue
        & $pwshExe -NoProfile -File $script
        $code = [int]$LASTEXITCODE
        if ($code -eq 0) {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'retired'; ExitCode = 0; Message = 'VM and its files removed; marker and registration refreshed' })
        } else {
            [void]$results.Add([pscustomobject]@{ Key = $item.Key; DisplayName = $item.DisplayName
                Action = 'failed'; ExitCode = $code; Message = "$($item.StopScript) exited $code; review its output above" })
        }
    }
    return [pscustomobject[]]@($results)
}

<#
.SYNOPSIS
    The extension areas this host currently advertises to the pool aggregator.
.DESCRIPTION
    A wrapper, and it earns its place: Get-ActiveExtensionService is exported by
    a module this one imports for its OWN scope, so it does not resolve from a
    calling SCRIPT. A caller that reaches for it directly gets a
    command-not-found which its best-effort catch reports as "this host
    advertises nothing" -- the same answer a clean host gives, for a host that
    is advertising two services it no longer runs.

    Best-effort: an unreadable runtime directory reports nothing. The caller
    checks that it HAS a runtime directory, which is the difference between
    "nothing to withdraw" and "could not look".
.OUTPUTS
    [string[]] area names, possibly empty.
#>
function Get-PoolWorkerAdvertisedArea {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return [string[]]@() }
    try {
        return [string[]]@((Get-ActiveExtensionService -RuntimeDir $RuntimeDir).Areas)
    } catch {
        Write-Verbose "Get-PoolWorkerAdvertisedArea: $($_.Exception.Message)"
        return [string[]]@()
    }
}

<#
.SYNOPSIS
    Removes the runtime markers an advertisement plan marks 'clear', then
    regenerates host.registration.json so the withdrawal reaches the aggregator
    on its next poll instead of waiting for a cycle.
.DESCRIPTION
    The same two writes each Stop-*ServiceVM.ps1 performs, applied to what this
    host still CLAIMS rather than to what it just stopped -- because the claims
    that outlive their VM are precisely the ones no stop script will ever be run
    for. Idempotent: a host advertising nothing gets an empty plan and no write.

    The registration is refreshed once, after the last marker is gone, rather
    than per area: it is rebuilt whole from the markers on disk, so one write
    after the sweep publishes the same record as one write per area and costs
    the aggregator one change instead of several.

    Best-effort on the refresh. A marker that is gone is already the truth for
    every consumer that reads this host directly; the regenerated registration
    only shortens how long the dashboard keeps showing the stale row.
.OUTPUTS
    [pscustomobject[]] Area, Action ('cleared', 'kept', 'absent', 'failed',
    'whatif'), Message.
#>
function Clear-PoolWorkerAdvertisement {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [Parameter()][AllowEmptyString()][string]$HostType
    )
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $cleared = 0
    foreach ($item in $Plan) {
        if ($item.Action -ne 'clear') {
            [void]$results.Add([pscustomobject]@{ Area = $item.Area; Action = 'kept'; Message = [string]$item.Reason })
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("runtime/$($item.Area).json", 'Withdraw the extension advertisement')) {
            [void]$results.Add([pscustomobject]@{ Area = $item.Area; Action = 'whatif'; Message = [string]$item.Reason })
            continue
        }
        try {
            # -Confirm:$false so a caller running under ConfirmImpact does not
            # get a second prompt for a removal this plan already decided.
            if (Remove-ExtensionServiceMarker -Area ([string]$item.Area) -RuntimeDir $RuntimeDir -Confirm:$false) {
                $cleared++
                [void]$results.Add([pscustomobject]@{ Area = $item.Area; Action = 'cleared'; Message = [string]$item.Reason })
            } else {
                [void]$results.Add([pscustomobject]@{ Area = $item.Area; Action = 'absent'
                    Message = 'the marker was already gone' })
            }
        } catch {
            [void]$results.Add([pscustomobject]@{ Area = $item.Area; Action = 'failed'
                Message = "the marker could not be removed: $($_.Exception.Message); delete runtime/$($item.Area).json by hand" })
        }
    }
    if ($cleared -gt 0 -and (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue)) {
        try {
            # Write-HostRegistrationRecord resolves the host id from a global the
            # entry point sets, rather than calling into Test.YurunaDir itself.
            if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) {
                Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
            }
            if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
                Write-Information '  Refreshed host.registration.json (this host drops off the dashboard within one aggregator poll).' -InformationAction Continue
            }
        } catch {
            Write-Warning "The advertisements were withdrawn but host.registration.json could not be refreshed ($($_.Exception.Message)); the dashboard clears it at the next cycle instead."
        }
    }
    return [pscustomobject[]]@($results)
}

<#
.SYNOPSIS
    Drops the hosts-file aliases a teardown plan marks 'drop', through
    automation/Set-HostAlias.ps1 (which deletes when given no address).
.OUTPUTS
    [pscustomobject[]] Name, Action ('dropped', 'kept', 'failed', 'whatif'), Message.
#>
function Remove-PoolWorkerAlias {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [switch]$NonInteractive
    )
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $aliasScript = Join-Path $RepoRoot 'automation/Set-HostAlias.ps1'
    foreach ($item in $Plan) {
        if ($item.Action -ne 'drop') {
            [void]$results.Add([pscustomobject]@{ Name = $item.Name; Action = 'kept'; Message = [string]$item.Reason })
            continue
        }
        if (-not (Test-Path -LiteralPath $aliasScript)) {
            [void]$results.Add([pscustomobject]@{ Name = $item.Name; Action = 'failed'
                Message = "Set-HostAlias.ps1 not found at $aliasScript; remove the '$($item.Name)' line from the hosts file by hand" })
            continue
        }
        if (-not $PSCmdlet.ShouldProcess('hosts file', "Remove the '$($item.Name)' mapping ($($item.Reason))")) {
            [void]$results.Add([pscustomobject]@{ Name = $item.Name; Action = 'whatif'; Message = [string]$item.Reason })
            continue
        }
        # Same elevation shape as the sync's alias writer: Windows asserts an
        # elevated session at the entry point, macOS/Linux re-launch under sudo
        # through Get-SudoPwshArgumentList (a bare 'pwsh' under sudo's stripped
        # environment exits 131 before reading the script).
        $needsSudo = (-not $IsWindows)
        if ($needsSudo) {
            try { $needsSudo = ((& id -u 2>$null | Out-String).Trim() -ne '0') } catch { $needsSudo = $true }
        }
        try {
            if ($needsSudo) {
                $sudoArgs = Get-SudoPwshArgumentList -ScriptPath $aliasScript `
                    -ScriptArgument @('-ComputerName', $item.Name) -NonInteractive:$NonInteractive
                & sudo @sudoArgs
                if ($LASTEXITCODE -ne 0) {
                    [void]$results.Add([pscustomobject]@{ Name = $item.Name; Action = 'failed'
                        Message = "sudo Set-HostAlias exited $LASTEXITCODE; remove the '$($item.Name)' line from /etc/hosts by hand" })
                    continue
                }
            } else {
                & $aliasScript -ComputerName $item.Name
            }
            [void]$results.Add([pscustomobject]@{ Name = $item.Name; Action = 'dropped'; Message = [string]$item.Reason })
        } catch {
            [void]$results.Add([pscustomobject]@{ Name = $item.Name; Action = 'failed'
                Message = "removing the '$($item.Name)' alias failed: $($_.Exception.Message)" })
        }
    }
    return [pscustomobject[]]@($results)
}

<#
.SYNOPSIS
    The networkStorage server names a config document points at, de-duplicated.
    '' entries and unconfigured tiers contribute nothing.
#>
function Get-PoolWorkerConfiguredServer {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()]$Config)
    $names = [System.Collections.Generic.List[string]]::new()
    if ($Config -isnot [System.Collections.IDictionary]) { return [string[]]@() }
    $ns = $Config['networkStorage']
    if ($ns -isnot [System.Collections.IDictionary]) { return [string[]]@() }
    foreach ($key in @('poolStorageNetworkPath', 'stashStorageNetworkPath')) {
        $np = if ($ns.Contains($key)) { "$($ns[$key])".Trim() } else { '' }
        if (-not $np) { continue }
        $server = Get-PoolStorageServerName -NetworkPath $np
        if ($server -and $names -notcontains $server) { [void]$names.Add($server) }
    }
    return [string[]]@($names)
}

<#
.SYNOPSIS
    The networkStorage tiers a config document configures, normalized through the
    same readers the mount path uses.
.DESCRIPTION
    Read through Get-YurunaPoolStorageConfig / Get-YurunaStashStorageConfig
    rather than off the raw keys, because those apply the normalizations the
    mount depends on -- most importantly the '~' expansion, without which the
    mount point compared here and the one mount(8) reports can never match.

    -IgnoreReplicate on the pool tier: a converting host may not have flipped
    pool.networkReplicate yet, and its mount still has to be transferred to the
    lab's storage either way.
.OUTPUTS
    [pscustomobject[]] Kind, Storage, NetworkPath, LocalPath, Server, ShareName.
#>
function Get-PoolWorkerStorageTier {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][AllowNull()]$Config)
    $tiers = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($Config -isnot [System.Collections.IDictionary]) { return [pscustomobject[]]@($tiers) }
    $readers = @(
        @{ Kind = 'pool';  Read = { Get-YurunaPoolStorageConfig  -Config $Config -IgnoreReplicate -WarningAction SilentlyContinue } }
        @{ Kind = 'stash'; Read = { Get-YurunaStashStorageConfig -Config $Config -WarningAction SilentlyContinue } }
    )
    foreach ($reader in $readers) {
        $storage = $null
        try { $storage = & $reader.Read } catch { Write-Verbose "Get-PoolWorkerStorageTier($($reader.Kind)): $($_.Exception.Message)" }
        if (-not $storage -or -not $storage.NetworkPath -or -not $storage.LocalPath) { continue }
        [void]$tiers.Add([pscustomobject]@{
            Kind        = [string]$reader.Kind
            Storage     = $storage
            NetworkPath = [string]$storage.NetworkPath
            LocalPath   = [string]$storage.LocalPath
            Server      = [string](Get-PoolStorageServerName -NetworkPath $storage.NetworkPath)
            ShareName   = Get-PoolWorkerLocalShareName -NetworkPath $storage.NetworkPath
        })
    }
    return [pscustomobject[]]@($tiers)
}

<#
.SYNOPSIS
    The share names this machine still PUBLISHES for the tiers it now mounts
    from the lab. Empty on a machine that never served its own storage.
.DESCRIPTION
    Asked of the OS share table, which is the only place that can answer it: the
    configuration of a machine backed by a NAS and one serving its own shares is
    identical in every key, and after a sync the configuration names the NAS on
    both. Best-effort -- an unreadable share table reports nothing rather than
    failing the conversion.
.OUTPUTS
    [string[]] share names, possibly empty.
#>
function Get-PoolWorkerServedShare {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Tier)
    $served = [System.Collections.Generic.List[string]]::new()
    $platform = ''
    try { $platform = Get-LocalLabStoragePlatform } catch { Write-Verbose "Get-PoolWorkerServedShare(platform): $($_.Exception.Message)" }
    if (-not $platform) { return [string[]]@($served) }
    foreach ($t in @($Tier)) {
        $name = "$($t.ShareName)".Trim()
        if (-not $name -or $served -contains $name) { continue }
        try {
            if (Get-LocalLabStorageSharePath -ShareName $name -Platform $platform) { [void]$served.Add($name) }
        } catch {
            Write-Verbose "Get-PoolWorkerServedShare($name): $($_.Exception.Message)"
        }
    }
    return [string[]]@($served)
}

<#
.SYNOPSIS
    Releases the mounts standing between each tier and the lab's storage: the
    one occupying its mount point, and any other mount pinning the same server
    name's SMB session.
.DESCRIPTION
    The step Sync-HostConfiguration cannot take and Connect-YurunaPoolStorage
    will not: Connect tears down a dead mount of OUR share at OUR point, but a
    mount of a DIFFERENT share there -- which is exactly what a machine leaving
    standalone has, its own '//ypool-nas/yuruna.pool' where the lab's
    '//ypool-nas/work/yuruna.pool' now belongs -- is left alone, and the session
    behind it goes on answering for the name. The mount that follows then looks
    for the lab's share on THIS machine, does not find it, and reports "No such
    file or directory" with the alias, the share path, the account and the mount
    point all correct.

    Run BEFORE the shares are withdrawn, deliberately. Unmounting a live share
    is ordinary; unmounting one whose server-side sharepoint has just been
    removed can wedge on I/O that will never complete.
.OUTPUTS
    [pscustomobject[]] Kind, MountPoint, Remote, Reason, Action ('released',
    'failed', 'whatif').
#>
function Clear-PoolWorkerSupersededMount {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Tier)
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($t in @($Tier)) {
        $superseded = @()
        try { $superseded = @(Get-PoolStorageSupersededMount -Config $t.Storage) } catch {
            Write-Verbose "Clear-PoolWorkerSupersededMount($($t.Kind)): $($_.Exception.Message)"
        }
        foreach ($old in $superseded) {
            $reason = if ($old.Reason -eq 'server-session') {
                "holds the '$($t.Server)' SMB session, which decides where a mount of that name lands"
            } else {
                "stands on the $($t.Kind) mount point"
            }
            if (-not $PSCmdlet.ShouldProcess("$($old.MountPoint) [$($old.Remote)]", 'Release the superseded SMB mount')) {
                [void]$results.Add([pscustomobject]@{ Kind = $t.Kind; MountPoint = $old.MountPoint
                    Remote = $old.Remote; Reason = $reason; Action = 'whatif' })
                continue
            }
            $ok = Dismount-PoolStoragePoint -MountPoint ([string]$old.MountPoint)
            [void]$results.Add([pscustomobject]@{ Kind = $t.Kind; MountPoint = $old.MountPoint
                Remote = $old.Remote; Reason = $reason
                Action = $(if ($ok) { 'released' } else { 'failed' }) })
        }
    }
    return [pscustomobject[]]@($results)
}

<#
.SYNOPSIS
    Stops this machine serving its own pool and stash storage, by running
    test/Clear-LocalLabStorage.ps1. No data is deleted.
.DESCRIPTION
    Delegated rather than reimplemented: that script owns withdrawing the SMB
    shares, deleting the accounts scoped to them, dropping the Windows loopback
    exemption, and reporting the disk the DATA still holds -- and it is the
    script an operator runs by hand for the same job, so a conversion that did
    its own version of it would be a second place for the rules to drift.

    In a CHILD pwsh, and that is not optional. Clear-LocalLabStorage is an entry
    point: it imports its module set with -Force into the GLOBAL scope, this
    module among them, which would unload the very module this function is
    executing inside.
.OUTPUTS
    [pscustomobject] Action ('withdrawn', 'failed', 'whatif', 'missing'),
    ExitCode, Message.
#>
function Invoke-PoolWorkerShareWithdrawal {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$TestRoot)
    $script = Join-Path $TestRoot 'Clear-LocalLabStorage.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        return [pscustomobject]@{ Action = 'missing'; ExitCode = -1
            Message = "Clear-LocalLabStorage.ps1 not found in $TestRoot; withdraw the shares and accounts by hand" }
    }
    if (-not $PSCmdlet.ShouldProcess('this machine''s own pool and stash shares', 'Withdraw the SMB shares and their storage accounts')) {
        return [pscustomobject]@{ Action = 'whatif'; ExitCode = 0; Message = 'would run Clear-LocalLabStorage.ps1' }
    }
    $pwshExe = [System.Environment]::ProcessPath
    if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
        return [pscustomobject]@{ Action = 'failed'; ExitCode = -1
            Message = 'the running pwsh executable could not be located, so Clear-LocalLabStorage.ps1 could not be launched' }
    }
    # -Force: the conversion took the operator's consent for this already, and a
    # second confirmation for a step they were told about is how an unattended
    # run stops half-way.
    & $pwshExe -NoProfile -File $script -Force
    $code = [int]$LASTEXITCODE
    if ($code -eq 0) {
        return [pscustomobject]@{ Action = 'withdrawn'; ExitCode = 0
            Message = 'the shares and their accounts are gone; the data under the storage root is untouched' }
    }
    return [pscustomobject]@{ Action = 'failed'; ExitCode = $code
        Message = "Clear-LocalLabStorage.ps1 exited $code; review its output above" }
}

<#
.SYNOPSIS
    Mounts each configured tier from the lab's storage, creating the tier's
    target folder on the share when the share does not have it yet.
.DESCRIPTION
    The same two initializers test/Test-Config.ps1 runs, in the same order, so a
    tier this leaves mounted is a tier the cycle gate agrees is mounted.
    Initialize-PoolStorageTargetFolder goes first because a share path that
    names a directory inside a share ('//ypool-nas/work/yuruna.pool') cannot be
    mounted until that directory exists, and it cannot be created through a
    mount of itself. For the pool tier the per-host folder follows, which is
    where a cycle's replication actually writes.

    Both are best-effort and bounded; a tier that will not mount is reported,
    never thrown, because the other tier's mount is still worth having.
.OUTPUTS
    [pscustomobject[]] Kind, Mounted [bool], Action ('mounted', 'failed',
    'whatif'), Message.
#>
function Connect-PoolWorkerStorage {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Tier,
        # This host's id; the pool tier's per-host destination folder is named
        # for it. Empty skips that half and mounts the share only.
        [Parameter()][AllowEmptyString()][string]$HostId
    )
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($t in @($Tier)) {
        if (-not $PSCmdlet.ShouldProcess("$($t.NetworkPath) at $($t.LocalPath)", "Mount the lab's $($t.Kind) storage")) {
            [void]$results.Add([pscustomobject]@{ Kind = $t.Kind; Mounted = $false; Action = 'whatif'
                Message = "would mount $($t.NetworkPath) at $($t.LocalPath)" })
            continue
        }
        # Only when the tier is not already standing. Ensuring the target folder
        # means mounting the PARENT share over this same mount point, checking,
        # and releasing it again -- so on a converged host it would tear down a
        # healthy mount to re-establish it, and the folder it looks for is one
        # the live mount is already proof of.
        if (-not (Test-PoolStorageMountEntry -Config $t.Storage)) {
            $folder = Initialize-PoolStorageTargetFolder -Config $t.Storage -Confirm:$false
            if (-not $folder.ok) {
                [void]$results.Add([pscustomobject]@{ Kind = $t.Kind; Mounted = $false; Action = 'failed'
                    Message = "the target folder on the share could not be ensured -- $($folder.error)" })
                continue
            }
        }
        if ($t.Kind -eq 'pool' -and $HostId) {
            $ready = Initialize-PoolStorageHostFolder -Config $t.Storage -HostId $HostId -Confirm:$false
            [void]$results.Add([pscustomobject]@{ Kind = $t.Kind; Mounted = [bool]$ready.ok
                Action  = $(if ($ready.ok) { 'mounted' } else { 'failed' })
                Message = $(if ($ready.ok) { "mounted at $($t.LocalPath); per-host folder '$($ready.folder)' ready" } else { [string]$ready.error }) })
            continue
        }
        $ok = Connect-YurunaPoolStorage -Config $t.Storage -Confirm:$false
        [void]$results.Add([pscustomobject]@{ Kind = $t.Kind; Mounted = [bool]$ok
            Action  = $(if ($ok) { 'mounted' } else { 'failed' })
            Message = $(if ($ok) { "mounted at $($t.LocalPath)" } else { "could not mount $($t.NetworkPath) at $($t.LocalPath)" }) })
    }
    return [pscustomobject[]]@($results)
}

<#
.SYNOPSIS
    The configured tiers whose share is NOT mounted at its localPath.
.DESCRIPTION
    The mount TABLE only, deliberately: Test-YurunaPoolStorageMounted also write-
    probes the share, and a verdict that writes a file into the lab's storage
    every time it is asked is a side effect a readiness check should not have.
    The mount step immediately before this one already exercised the write path.
.OUTPUTS
    [string[]] tier kinds, possibly empty.
#>
function Get-PoolWorkerUnmountedTier {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Tier)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @($Tier)) {
        $mounted = $false
        try { $mounted = [bool](Test-PoolStorageMountEntry -Config $t.Storage) } catch {
            Write-Verbose "Get-PoolWorkerUnmountedTier($($t.Kind)): $($_.Exception.Message)"
        }
        if (-not $mounted) { [void]$out.Add([string]$t.Kind) }
    }
    return [string[]]@($out)
}

<#
.SYNOPSIS
    $true when an address is one this machine answers on (loopback or a bound
    local interface). Best-effort; any resolver error is $false.
.DESCRIPTION
    Used to catch a converted host whose vmStart.cachingProxyIp still names its
    own proxy. Loopback alone is not enough: install/setup.ps1 writes the proxy
    VM's LAN lease into that key, so the value to recognize is a routable
    address that happens to be this machine's.
#>
function Test-PoolWorkerAddressIsThisHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Address)
    $value = "$Address".Trim()
    if (-not $value) { return $false }
    $parsed = [System.Net.IPAddress]::Any
    if (-not [System.Net.IPAddress]::TryParse($value, [ref]$parsed)) {
        # A NAME, not an address. Resolve it and ask the same question of what
        # it resolves to, so an alias pointing back here is caught too.
        try {
            foreach ($a in @([System.Net.Dns]::GetHostAddresses($value))) {
                if (Test-PoolWorkerAddressIsThisHost -Address $a.ToString()) { return $true }
            }
        } catch {
            Write-Verbose "Test-PoolWorkerAddressIsThisHost($value): $($_.Exception.Message)"
        }
        return $false
    }
    if ([System.Net.IPAddress]::IsLoopback($parsed)) { return $true }
    try {
        foreach ($local in @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()))) {
            if ($local.Equals($parsed)) { return $true }
        }
    } catch {
        Write-Verbose "Test-PoolWorkerAddressIsThisHost(local addresses): $($_.Exception.Message)"
    }
    return $false
}

<#
.SYNOPSIS
    Gathers the end-state facts and returns the Get-PoolWorkerReadinessVerdict
    verdict for this host.
.OUTPUTS
    [pscustomobject] Ready, Problem, Checked.
#>
function Test-PoolWorkerReady {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Config,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$UnconvergedVaultUser,
        [Parameter()][AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ExemptServiceKey,
        # Areas the caller is still running on purpose, so their advertisement is
        # not a leftover.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ExemptArea,
        # Do not fail this host for still publishing the shares -- the operator
        # asked to keep serving them (other machines may still mount them).
        [switch]$KeepServedShare
    )
    $services = @(Get-PoolWorkerServiceState)

    $active = @()
    try {
        if ($RuntimeDir) { $active = @((Get-ActiveExtensionService -RuntimeDir $RuntimeDir).Areas) }
    } catch {
        Write-Verbose "Test-PoolWorkerReady(active extensions): $($_.Exception.Message)"
    }
    if ($active.Count -gt 0) {
        $active = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea $active -ExemptArea $ExemptArea |
            Where-Object { $_.Action -eq 'clear' } | ForEach-Object { [string]$_.Area })
    }

    $storageIsLocal = $false
    foreach ($server in @(Get-PoolWorkerConfiguredServer -Config $Config)) {
        if (Test-PoolWorkerAddressIsThisHost -Address $server) { $storageIsLocal = $true; break }
    }

    $tiers = @(Get-PoolWorkerStorageTier -Config $Config)
    $servedShare = if ($KeepServedShare) { @() } else { @(Get-PoolWorkerServedShare -Tier $tiers) }
    $unmounted = @(Get-PoolWorkerUnmountedTier -Tier $tiers)

    $proxyIp = ''
    if ($Config -is [System.Collections.IDictionary] -and $Config['vmStart'] -is [System.Collections.IDictionary]) {
        $proxyIp = "$($Config['vmStart']['cachingProxyIp'])".Trim()
    }

    return Get-PoolWorkerReadinessVerdict -Service $services -ActiveExtension $active `
        -StorageIsLocal $storageIsLocal -ServedShare $servedShare -UnmountedTier $unmounted `
        -UnconvergedVaultUser $UnconvergedVaultUser `
        -CachingProxyIp $proxyIp -CachingProxyIsLocal (Test-PoolWorkerAddressIsThisHost -Address $proxyIp) `
        -ExemptServiceKey $ExemptServiceKey
}

<#
.SYNOPSIS
    The extension areas the caching-proxy VM answers for -- what -KeepCachingProxy
    exempts from the advertisement sweep.
#>
function Get-PoolWorkerCachingProxyArea {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@($script:CachingProxyArea)
}

Export-ModuleMember -Function `
    Get-PoolWorkerStopScriptName, Get-PoolWorkerServiceTeardownPlan, Get-PoolWorkerAliasPlan, `
    Get-PoolWorkerAdvertisementPlan, Get-PoolWorkerAdvertisedArea, Get-PoolWorkerLocalShareName, `
    Get-PoolWorkerCachingProxyArea, `
    Get-PoolWorkerReadinessVerdict, Get-PoolWorkerServiceState, Invoke-PoolWorkerServiceTeardown, `
    Clear-PoolWorkerAdvertisement, Remove-PoolWorkerAlias, Get-PoolWorkerConfiguredServer, `
    Get-PoolWorkerStorageTier, Get-PoolWorkerServedShare, Get-PoolWorkerUnmountedTier, `
    Clear-PoolWorkerSupersededMount, Invoke-PoolWorkerShareWithdrawal, Connect-PoolWorkerStorage, `
    Test-PoolWorkerAddressIsThisHost, Test-PoolWorkerReady

# Copyright (c) 2019-2026 by Alisson Sol et al.
