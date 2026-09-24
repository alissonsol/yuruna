<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42765a89-9026-4dfc-bda8-481ccd6555ce
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna extension service framework source version preflight
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

# Which framework snapshot an extension service VM is built from.
#
# The service daemons are Go binaries whose version is stamped at COMPILE time
# (`go build -ldflags "-X main.version=$VERSION_STR"`, read from the VERSION
# file of whatever enlistment the guest fetched). Nothing re-reads it later:
# the guest builds once and the number it prints on its UI, in /api/hostinfo,
# and in every diagnostics payload is frozen at that moment for the life of
# the VM.
#
# That makes the FETCH the whole story. The cloud-init seed pulls this host's
# enlistment from the status service (/yuruna-archive.tar.gz) and falls back to
# cloning the public github mirror when the host does not answer. The mirror is
# a release snapshot -- it lags the working enlistment by however long since
# the last publish -- so the fallback silently swaps the code being deployed
# for an older codebase, and the only evidence left behind is one line in the
# guest's cloud-init log.
#
# This module makes that visible from both ends:
#
#   * BEFORE the build, Assert-GuestFrameworkSource refuses a bring-up whose
#     guest could not possibly reach this host's enlistment. It is a cheap
#     early stop -- it saves the half-hour in-guest build, nothing more. It
#     cannot prove which address the seed will end up baking, because that is
#     resolved per host type inside New-VM.ps1.
#
#   * AFTER the daemon serves, Assert-ServiceVmFrameworkSource reads what the
#     guest ACTUALLY did (/etc/yuruna/framework-source, written by the seed)
#     and what the daemon actually reports (/api/hostinfo). That one is
#     authoritative, and it is the check that fails a bring-up.
#
# The split matters: the pre-flight is a prediction and the post-boot check is
# an observation, so only the second may be trusted to say a deployed service
# is running current code.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Set-StrictMode -Version Latest

# The seed writes this after it decides where the framework came from. Read as
# the unprivileged service account, so the seed keeps it world-readable.
$script:GuestSourceMarkerPath = '/etc/yuruna/framework-source'

<#
.SYNOPSIS
    What this enlistment would hand a guest: its version, its revision, and
    whether uncommitted work would be left behind.
.DESCRIPTION
    The status service serves the archive with `git archive HEAD`, so what
    reaches the guest is the COMMITTED tree -- an edit sitting in the working
    tree does not travel, however current it looks here. Reporting the dirty
    paths alongside the version is what stops an operator concluding a VM runs
    a change they can see on disk in front of them.

    Best-effort: a missing VERSION file or an unavailable git reports empty
    fields rather than throwing, because a reporting nicety must not be able to
    fail a bring-up.
.PARAMETER RepoRoot
    Framework enlistment root (the directory holding VERSION).
.OUTPUTS
    [hashtable] with Version, Revision, DirtyPaths ([string[]]), IsDirty.
#>
function Get-FrameworkSourceSnapshot {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $version = ''
    try {
        $versionFile = Join-Path $RepoRoot 'VERSION'
        if (Test-Path -LiteralPath $versionFile) {
            $version = ((Get-Content -LiteralPath $versionFile -TotalCount 1 -ErrorAction Stop) -join '').Trim()
        }
    } catch { Write-Verbose "framework VERSION read: $($_.Exception.Message)" }

    $revision = ''
    $dirty    = @()
    try {
        if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
            $revision = (& git -C $RepoRoot rev-parse --short HEAD 2>$null | Select-Object -First 1)
            if (-not $revision) { $revision = '' }
            # Porcelain v1 so the two-column status prefix stays parseable
            # across git versions; the paths are for a human to read, so the
            # rename arrow and quoting git applies are left as git wrote them.
            $dirty = @(& git -C $RepoRoot status --porcelain 2>$null | Where-Object { $_ })
        }
    } catch { Write-Verbose "framework revision read: $($_.Exception.Message)" }

    return @{
        Version    = [string]$version
        Revision   = [string]$revision
        DirtyPaths = [string[]]$dirty
        IsDirty    = ([int]$dirty.Count -gt 0)
    }
}

<#
.SYNOPSIS
    Capitalized repository basename of a framework repo URL ('Yuruna',
    'Yurunadev', ...).
.DESCRIPTION
    The rule mirrors the status pages' own derivation byte for byte -- strip
    query and fragment, strip a trailing '.git' and trailing slashes, take the
    last path segment, upper-case its first character -- because the two names
    are read side by side and a page and a dashboard disagreeing about which
    enlistment they came from is worse than either being absent.
.PARAMETER Url
    Repository URL, in any of the forms an operator writes it.
.OUTPUTS
    [string] the capitalized basename, or '' when the URL yields none.
#>
function ConvertTo-YurunaBrandName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)

    $trimmed = ($Url -split '[?#]')[0] -replace '\.git$', '' -replace '/+$', ''
    $last    = ($trimmed -split '/')[-1]
    if (-not $last) { return '' }
    return ($last.Substring(0, 1).ToUpperInvariant() + $last.Substring(1))
}

<#
.SYNOPSIS
    The name and version an enlistment brands its built artifacts with.
.DESCRIPTION
    A caching-proxy VM serves dashboards long after the bring-up that built it
    has scrolled away, and nothing on those dashboards otherwise says which
    enlistment they came from -- a lab that runs both the public and the private
    repository can hold two proxies whose dashboards are indistinguishable.

    The repository is the configured frameworkUrl when there is one and this
    enlistment's own origin remote otherwise, which is the order the status
    pages resolve it in, so both surfaces name the same repository.

    Both values ride into a guest through a shell env file and a JSON document,
    so they are reduced here to the characters that are safe in either. A value
    that survives nothing falls back to 'Yuruna' for the name and to empty for
    the version -- an unbranded tile is a cosmetic loss, while a value that
    breaks the env file takes the guest's whole dashboard-branding step with it.

    Best-effort throughout, for the same reason Get-FrameworkSourceSnapshot is:
    a reporting nicety must not be able to fail a bring-up.
.PARAMETER RepoRoot
    Framework enlistment root (the directory holding VERSION).
.PARAMETER Config
    Parsed test.config.yml, when the caller has one. Its
    repositories.frameworkUrl wins over the local git remote.
.OUTPUTS
    [hashtable] with Name and Version.
#>
function Get-YurunaBrandIdentity {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()]$Config = $null
    )

    # Reached through Contains() rather than dot notation: the config arrives as
    # an ordered dictionary, and under StrictMode a missing key is a terminating
    # error there, not the $null this wants.
    $repoUrl = ''
    if ($null -ne $Config) {
        try {
            if ($Config -is [System.Collections.IDictionary] -and $Config.Contains('repositories')) {
                $repositories = $Config['repositories']
                if ($repositories -is [System.Collections.IDictionary] -and $repositories.Contains('frameworkUrl')) {
                    $repoUrl = "$($repositories['frameworkUrl'])".Trim()
                }
            }
        } catch { Write-Verbose "brand identity: frameworkUrl read: $($_.Exception.Message)" }
    }
    if (-not $repoUrl) {
        try {
            if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
                # Collected whole, then narrowed: a Select-Object -First in the
                # native command's own pipeline can stop git early and leave
                # $LASTEXITCODE reporting on a run that was never allowed to
                # finish, which reads here as "this host has no remote".
                $remote = & git -C $RepoRoot remote get-url origin 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $first = @($remote) | Select-Object -First 1
                    if ($first) { $repoUrl = "$first".Trim() }
                }
            }
        } catch { Write-Verbose "brand identity: git remote read: $($_.Exception.Message)" }
    }

    $name = ''
    if ($repoUrl) { $name = ConvertTo-YurunaBrandName -Url $repoUrl }
    # Reduce to the repository-name alphabet rather than rejecting: a host whose
    # remote carries anything else still gets a usable name out of what is left.
    $name = ($name -replace '[^A-Za-z0-9._-]', '')
    if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
    if (-not $name) { $name = 'Yuruna' }

    $version = ''
    try { $version = [string](Get-FrameworkSourceSnapshot -RepoRoot $RepoRoot).Version } catch { $version = '' }
    $version = ($version -replace '[^A-Za-z0-9._+-]', '')
    if ($version.Length -gt 32) { $version = $version.Substring(0, 32) }

    return @{
        Name    = [string]$name
        Version = [string]$version
    }
}

<#
.SYNOPSIS
    Whether a status service at this address would actually hand a guest the
    framework archive.
.DESCRIPTION
    Probes the two endpoints the seed uses, in the seed's own order:
    /livecheck (the reachability gate) and /yuruna-archive.tar.gz (the payload).

    The archive is requested with HEAD rather than GET. The status service runs
    `git archive` either way and only skips writing the body, so a HEAD that
    answers 200 proves the tarball can be PRODUCED -- an empty enlistment or a
    broken git fails here exactly as it would for the guest -- without pulling
    the whole framework across the wire to learn it.

    -NoProxy throughout: this host commonly has a caching proxy configured for
    package traffic, and a proxy that answers for the status service would
    report reachability the guest (which also fetches --no-proxy) does not have.
.PARAMETER Address
    Host address to probe.
.PARAMETER Port
    Status service port.
.PARAMETER TimeoutSeconds
    Per-request timeout. Default 5, matching the seed's own --timeout=5.
.OUTPUTS
    [hashtable] with Address, Port, BaseUrl, Ok, Detail.
#>
function Test-FrameworkArchiveEndpoint {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 5
    )

    $baseUrl = "http://${Address}:${Port}"
    $result  = @{ Address = $Address; Port = $Port; BaseUrl = $baseUrl; Ok = $false; Detail = '' }
    try {
        $null = Invoke-WebRequest -Uri "$baseUrl/livecheck" -Method Get -NoProxy -UseBasicParsing `
            -TimeoutSec $TimeoutSeconds -ErrorAction Stop -Verbose:$false
    } catch {
        $result.Detail = (Format-YurunaOperatorMessage -Key 'runner.operator_fc8677fa2528c6a0' -Arguments @{ message = "$($_.Exception.Message)" })
        return $result
    }
    try {
        $resp = Invoke-WebRequest -Uri "$baseUrl/yuruna-archive.tar.gz" -Method Head -NoProxy -UseBasicParsing `
            -TimeoutSec $TimeoutSeconds -ErrorAction Stop -Verbose:$false
        if ([int]$resp.StatusCode -ne 200) {
            $result.Detail = (Format-YurunaOperatorMessage -Key 'runner.operator_828a744dd128fc8c' -Arguments @{ statusCode = "$([int]$resp.StatusCode)" })
            return $result
        }
    } catch {
        $result.Detail = (Format-YurunaOperatorMessage -Key 'runner.operator_7ecfcd6675e5bb94' -Arguments @{ message = "$($_.Exception.Message)" })
        return $result
    }
    $result.Ok     = $true
    $result.Detail = (Format-YurunaOperatorMessage -Key 'runner.operator_3bb05a74210fa85e')
    return $result
}

<#
.SYNOPSIS
    The host addresses a service guest might be told to fetch the framework
    from, most-likely first.
.DESCRIPTION
    A CANDIDATE set, deliberately, not a prediction. The address baked into a
    seed is resolved inside the per-host New-VM.ps1 from things only it knows
    -- the resolved libvirt network on KVM, the vSwitch on Hyper-V, the vmnet
    mode on UTM -- and re-deriving that here would be a second implementation
    free to disagree with the one that actually bakes the seed.

    So this asks the host contract for every address it offers and lets the
    caller probe them all. None answering is a sound reason to stop; one
    answering only means the guest is LIKELY to be served, which is why the
    post-boot check exists and why it is the one that decides.

    Every lookup is guarded: these are host-contract functions loaded by
    Initialize-YurunaHost, and a caller that has not initialized a host gets
    the candidates that are available rather than a terminating error.
.OUTPUTS
    [string[]] distinct addresses, in probe order; possibly empty.
#>
function Get-FrameworkSourceHostCandidate {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $candidates = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$Value)
        $v = ([string]$Value).Trim()
        if ($v -and -not $candidates.Contains($v)) { $candidates.Add($v) }
    }

    # The operator's explicit override outranks every discovered address: it is
    # the same variable the seed bakers themselves consult first.
    if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) { & $add $env:YURUNA_GUEST_REACHABLE_HOST_IP }

    # KVM's service New-VM scripts bake $guestBinding.HostIp, which follows the
    # network the guest is actually attached to -- and differs from the NAT
    # default whenever that network is a bridge.
    if (Get-Command Resolve-GuestHostBinding -ErrorAction SilentlyContinue) {
        try {
            $binding = Resolve-GuestHostBinding
            if ($binding) { & $add ([string]$binding.HostIp) }
        } catch { Write-Verbose "Resolve-GuestHostBinding: $($_.Exception.Message)" }
    }
    if (Get-Command Get-GuestReachableHostIp -ErrorAction SilentlyContinue) {
        try { & $add ([string](Get-GuestReachableHostIp)) }
        catch { Write-Verbose "Get-GuestReachableHostIp: $($_.Exception.Message)" }
    }
    if (Get-Command Get-BestHostIp -ErrorAction SilentlyContinue) {
        try { & $add ([string](Get-BestHostIp)) }
        catch { Write-Verbose "Get-BestHostIp: $($_.Exception.Message)" }
    }
    return [string[]]$candidates.ToArray()
}

<#
.SYNOPSIS
    Whether a service guest built now could fetch this enlistment, or would
    fall back to the public mirror.
.DESCRIPTION
    Answers three questions the operator would otherwise only learn from a
    guest log two days later: is the status service even meant to run, is it
    serving the archive at all, and can it be reached at an address a guest
    would be handed.

    Loopback is probed alongside the guest-facing candidates because the two
    failures need different fixes and look identical from the outside: a server
    that is down is a server to start, while a server that answers on loopback
    and nowhere else is a firewall or a binding problem.
.PARAMETER RepoRoot
    Framework enlistment root.
.PARAMETER StatusDecision
    The {ShouldStart; Port} record from Start-YurunaStatusServiceIfEnabled /
    Resolve-StatusServiceStart. $null means the decision was never reached
    (no test.config.yml), which is treated as "no status service".
.OUTPUTS
    [hashtable] with Ok, Reason, Summary, Snapshot, Port, Probes, ServingHosts.
#>
function Test-GuestFrameworkSourcePreflight {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowNull()]$StatusDecision
    )

    $snapshot = Get-FrameworkSourceSnapshot -RepoRoot $RepoRoot
    $enabled  = [bool]($StatusDecision -and $StatusDecision.ShouldStart)
    $port     = if ($StatusDecision -and $StatusDecision.Port) { [int]$StatusDecision.Port } else { 8080 }

    if (-not $enabled) {
        return @{
            Ok           = $false
            Reason       = 'StatusServiceDisabled'
            Summary      = (Format-YurunaOperatorMessage -Key 'runner.operator_4c43a7e1778e8b3d')
            Snapshot     = $snapshot
            Port         = $port
            Probes       = @()
            ServingHosts = @()
        }
    }

    $probes = [System.Collections.Generic.List[hashtable]]::new()
    $probes.Add((Test-FrameworkArchiveEndpoint -Address '127.0.0.1' -Port $port))
    $serving = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in (Get-FrameworkSourceHostCandidate)) {
        if ($candidate -eq '127.0.0.1') { continue }
        $probe = Test-FrameworkArchiveEndpoint -Address $candidate -Port $port
        $probes.Add($probe)
        if ($probe.Ok) { $serving.Add($candidate) }
    }

    $loopbackOk = [bool]($probes[0].Ok)
    if ($serving.Count -gt 0) {
        return @{
            Ok           = $true
            Reason       = 'Ok'
            Summary      = (Format-YurunaOperatorMessage -Key 'runner.operator_4c14858ef689505d' -Arguments @{ join = "$($serving -join ', ')" })
            Snapshot     = $snapshot
            Port         = $port
            Probes       = $probes.ToArray()
            ServingHosts = $serving.ToArray()
        }
    }
    $reason = if ($loopbackOk) { 'UnreachableFromGuest' } else { 'ArchiveNotServed' }
    $summary = if ($loopbackOk) {
        (Format-YurunaOperatorMessage -Key 'runner.operator_3d611df3f14a3a66')
    } else {
        (Format-YurunaOperatorMessage -Key 'runner.operator_dfa46994723032d8' -Arguments @{ port = "$port" })
    }
    return @{
        Ok           = $false
        Reason       = $reason
        Summary      = $summary
        Snapshot     = $snapshot
        Port         = $port
        Probes       = $probes.ToArray()
        ServingHosts = @()
    }
}

<#
.SYNOPSIS
    Report the framework-source pre-flight and decide whether the bring-up may
    proceed.
.DESCRIPTION
    The gate the three service bring-up scripts share, so all three refuse on
    the same evidence and print the same explanation.

    A failure here is a REFUSAL rather than a warning. The guest's fallback
    still works and still produces a running service -- which is precisely the
    problem: a bring-up that fell back reports success, serves normally, and
    differs from what the operator built only in being weeks behind. Nothing
    downstream ever revisits that decision, so the moment to make it is now.

    -AllowMirrorSource is the deliberate escape: building from the published
    mirror is legitimate off-LAN, and the switch turns the refusal into a
    warning that names exactly what is being accepted.

    A dirty working tree is reported but never blocks. Serving HEAD is normal
    and usually intended; the operator only needs to know it is happening.
.PARAMETER RepoRoot
    Framework enlistment root.
.PARAMETER StatusDecision
    The {ShouldStart; Port} record from the status-service ensure.
.PARAMETER ServiceLabel
    Service name for the messages (e.g. 'stash-service').
.PARAMETER AllowMirrorSource
    Proceed even when the guest would fall back to the public mirror.
.OUTPUTS
    [bool] $true to proceed with the build.
#>
function Assert-GuestFrameworkSource {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowNull()]$StatusDecision,
        [Parameter(Mandatory)][string]$ServiceLabel,
        [switch]$AllowMirrorSource
    )

    $result   = Test-GuestFrameworkSourcePreflight -RepoRoot $RepoRoot -StatusDecision $StatusDecision
    $snapshot = $result.Snapshot
    $stamp    = if ($snapshot.Revision) { "$($snapshot.Version) ($($snapshot.Revision))" } else { [string]$snapshot.Version }

    Write-Information "" -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_773fe3cd9e3d3c34') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_119791056d611140' -Arguments @{ stamp = "$stamp" }) -InformationAction Continue
    foreach ($probe in $result.Probes) {
        Write-Information "  $($probe.BaseUrl): $($probe.Detail)" -InformationAction Continue
    }

    if ($snapshot.IsDirty) {
        # Named, not counted: "3 uncommitted files" leaves the operator to
        # guess whether the one they care about is among them.
        $shown = @($snapshot.DirtyPaths | Select-Object -First 10)
        Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_ee290ed0b258ce2a' -Arguments @{ count = "$($snapshot.DirtyPaths.Count)"; serviceLabel = "$ServiceLabel"; n = [string](($shown -join "`n  ")); else = [string]($(if ($snapshot.DirtyPaths.Count -gt $shown.Count) { "`n  ... and $($snapshot.DirtyPaths.Count - $shown.Count) more" } else { '' })) }))
    }

    if ($result.Ok) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_303857a13937ce8d') -InformationAction Continue
        return $true
    }

    $explanation = (Format-YurunaOperatorMessage -Key 'runner.operator_b188a62cdd3e5530' -Arguments @{ serviceLabel = "$ServiceLabel"; stamp = "$stamp"; summary = "$($result.Summary)" })

    if ($AllowMirrorSource) {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_89cfb2db259f0f2e' -Arguments @{ trim = [string]($explanation.Trim()) }))
        return $true
    }

    $fix = switch ($result.Reason) {
        'StatusServiceDisabled' {
            "Set statusService.enabled: true (and its port) in test/test.config.yml, then re-run."
        }
        'UnreachableFromGuest' {
            "The server is up but unreachable at the guest-facing address. Open the status port to the guest network, " +
            "or pin the address the seed bakes with `$env:YURUNA_GUEST_REACHABLE_HOST_IP."
        }
        default {
            "Start it with test/service/Start-StatusService.ps1 and confirm http://127.0.0.1:$($result.Port)/yuruna-archive.tar.gz answers, then re-run."
        }
    }
    Write-Information "" -InformationAction Continue
    Write-Information $explanation.Trim() -InformationAction Continue
    Write-Information "" -InformationAction Continue
    Write-Information "Fix: $fix" -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b2cd9d115f3e8faa') -InformationAction Continue
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_090a0a742ee6d009' -Arguments @{ serviceLabel = "$ServiceLabel" })
    return $false
}

<#
.SYNOPSIS
    What framework snapshot a running service VM was actually built from.
.DESCRIPTION
    Two independent readings, because each covers the other's blind spot.

    The seed's marker (/etc/yuruna/framework-source) is the direct answer: it
    records which fetch won at boot, so a mirror-sourced guest says so in one
    word instead of being inferred from a version that merely looks old. It
    needs SSH, and it is absent on a VM built by an older seed.

    The daemon's own /api/hostinfo carries the version compiled into the
    binary, which is the number every other surface in the pool shows. It needs
    only the HTTP port the readiness probe just used, so it answers on a guest
    SSH cannot be established to.

    Never throws: an unreachable guest reports Verified = $false with the
    reason, which is a different outcome from a mismatch and is treated as one.
.PARAMETER Address
    The address the daemon was observed serving at.
.PARAMETER Port
    The daemon's HTTP port. Default 80.
.PARAMETER GuestKey
    Guest identifier for the SSH key lookup (e.g. guest.stash-service).
.PARAMETER User
    Login account the seed created. Pinned by the caller for the same reason
    the diagnostics captures pin it: it is the only account these VMs have.
.PARAMETER Expected
    The Get-FrameworkSourceSnapshot record this bring-up intended to deploy.
.OUTPUTS
    [hashtable] with Verified, Matches, Source, Version, ExpectedVersion,
    Summary, Evidence.
#>
function Test-ServiceVmFrameworkSource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # Empty is accepted rather than rejected at the binder: a daemon that
        # the readiness wait confirmed only from INSIDE the guest leaves this
        # host without an address for it, and that must degrade to "could not
        # verify" -- not to a parameter-binding error thrown over a healthy VM.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address,
        [int]$Port = 80,
        [string]$GuestKey = '',
        [string]$User = '',
        [Parameter(Mandatory)][hashtable]$Expected
    )

    $out = @{
        Verified        = $false
        Matches         = $false
        Source          = ''
        Version         = ''
        ExpectedVersion = [string]$Expected.Version
        Summary         = ''
        Evidence        = ''
    }

    # 1. The seed's marker, over SSH.
    if ($Address -and (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
        try {
            $ssh = Invoke-GuestSsh -VMName $Address -GuestKey $GuestKey -User $User `
                -Command "cat $script:GuestSourceMarkerPath 2>/dev/null" -TimeoutSeconds 60 -AddressWaitSeconds 0
            if ($ssh -and $ssh.success -and -not [string]::IsNullOrWhiteSpace([string]$ssh.output)) {
                foreach ($line in ([string]$ssh.output -split "`r?`n")) {
                    if ($line -match '^\s*source\s*=\s*(.+?)\s*$')  { $out.Source  = $Matches[1] }
                    if ($line -match '^\s*version\s*=\s*(.+?)\s*$') { $out.Version = $Matches[1] }
                }
                if ($out.Source) {
                    $out.Verified = $true
                    $out.Evidence = "$script:GuestSourceMarkerPath in the guest"
                }
            }
        } catch { Write-Verbose "framework-source marker read: $($_.Exception.Message)" }
    }

    # 2. The daemon's compiled-in stamp. Also consulted when the marker was
    #    read: the marker records the SOURCE tree, the binary records what was
    #    built from it, and a build that used a different tree than the fetch
    #    landed is exactly the disagreement worth catching.
    $served = ''
    try {
        $resp = Invoke-WebRequest -Uri "http://${Address}:${Port}/api/hostinfo" -Method Get -NoProxy -UseBasicParsing `
            -TimeoutSec 15 -ErrorAction Stop -Verbose:$false
        $info = [string]$resp.Content | ConvertFrom-Json -ErrorAction Stop
        if ($info.PSObject.Properties.Name -contains 'version') { $served = ([string]$info.version).Trim() }
    } catch { Write-Verbose "hostinfo version read: $($_.Exception.Message)" }
    if ($served) {
        $out.Version = $served
        if (-not $out.Verified) {
            $out.Verified = $true
            $out.Evidence = "the daemon's /api/hostinfo"
        } else {
            $out.Evidence = "$($out.Evidence) and the daemon's /api/hostinfo"
        }
    }

    if (-not $out.Verified) {
        $out.Summary = (Format-YurunaOperatorMessage -Key 'runner.operator_b6a05daec9085809')
        return $out
    }

    $mirrorSourced  = ($out.Source -and $out.Source -ne 'host')
    $versionMatches = ($out.Version -and $out.Version -eq [string]$Expected.Version)
    $out.Matches    = ($versionMatches -and -not $mirrorSourced)
    $out.Summary = if ($out.Matches) {
        (Format-YurunaOperatorMessage -Key 'runner.operator_10c4f692f254d7ce' -Arguments @{ version = "$($out.Version)" })
    } elseif ($mirrorSourced) {
        (Format-YurunaOperatorMessage -Key 'runner.operator_eeb3a277ba5bbd7e' -Arguments @{ version = "$($out.Version)"; version2 = "$([string]$Expected.Version)" })
    } else {
        (Format-YurunaOperatorMessage -Key 'runner.operator_90d9c911a863cfe3' -Arguments @{ version = "$($out.Version)"; version2 = "$([string]$Expected.Version)" })
    }
    return $out
}

<#
.SYNOPSIS
    Report what a freshly built service VM is running and decide whether the
    bring-up succeeded.
.DESCRIPTION
    The authoritative half. The pre-flight predicted; this observes, and it is
    the only check that can catch a guest that passed the prediction and fell
    back anyway -- the boot-order case, where the address the seed baked went
    stale between bake and boot and the guest reached for the mirror.

    A mismatch FAILS the bring-up. The VM is left running and serving, and the
    message says so: the fault is not that the service is broken but that it is
    the wrong build, and an operator who reads "complete" over an obsolete
    daemon has been told the opposite of what happened.

    An inconclusive check -- neither the marker nor the daemon answered -- is a
    WARNING, not a failure. The readiness probe has already established that
    the daemon serves, so silence here is about this host's reach into the
    guest rather than about the guest, and failing a verified-healthy bring-up
    over a probe that could not run reports a fault that does not exist.
.PARAMETER Address
    Address the daemon was observed serving at.
.PARAMETER Port
    Daemon HTTP port. Default 80.
.PARAMETER GuestKey
    Guest identifier for the SSH key lookup.
.PARAMETER User
    Login account the seed created.
.PARAMETER Expected
    The snapshot this bring-up intended to deploy.
.PARAMETER ServiceLabel
    Service name for the messages.
.PARAMETER AllowMirrorSource
    Accept a mirror-sourced or mismatched build instead of failing.
.OUTPUTS
    [bool] $true when the deployed build is acceptable.
#>
function Assert-ServiceVmFrameworkSource {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Empty is accepted rather than rejected at the binder: a daemon that
        # the readiness wait confirmed only from INSIDE the guest leaves this
        # host without an address for it, and that must degrade to "could not
        # verify" -- not to a parameter-binding error thrown over a healthy VM.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address,
        [int]$Port = 80,
        [string]$GuestKey = '',
        [string]$User = '',
        [Parameter(Mandatory)][hashtable]$Expected,
        [Parameter(Mandatory)][string]$ServiceLabel,
        [switch]$AllowMirrorSource
    )

    $result = Test-ServiceVmFrameworkSource -Address $Address -Port $Port -GuestKey $GuestKey -User $User -Expected $Expected
    $stamp  = if ($Expected.Revision) { "$($Expected.Version) ($($Expected.Revision))" } else { [string]$Expected.Version }

    Write-Information "" -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b45d8c5faff5d3c4') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_119791056d611140' -Arguments @{ stamp = "$stamp" }) -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_741bd48072b60960' -Arguments @{ answer = "$(if ($result.Version) { $result.Version } else { '<no answer>' })"; source = "$(if ($result.Source) { " (source: $($result.Source))" })" }) -InformationAction Continue

    if (-not $result.Verified) {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_ced4f05f3e081915' -Arguments @{ serviceLabel = "$ServiceLabel"; summary = "$($result.Summary)"; version = "$($Expected.Version)" }))
        return $true
    }
    if ($result.Matches) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_81ad4e00cee92026' -Arguments @{ summary = "$($result.Summary)"; evidence = "$($result.Evidence)" }) -InformationAction Continue
        return $true
    }

    $explanation = (Format-YurunaOperatorMessage -Key 'runner.operator_a597e77782020780' -Arguments @{ serviceLabel = "$ServiceLabel"; summary = "$($result.Summary)"; evidence = "$($result.Evidence)" })
    if ($AllowMirrorSource) {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_253c1b6189071233' -Arguments @{ trim = [string]($explanation.Trim()) }))
        return $true
    }
    Write-Information "" -InformationAction Continue
    Write-Information $explanation.Trim() -InformationAction Continue
    Write-Information "" -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c4e3ca9f69e0f402') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9c9332ea45a6d4d3') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_97543922121223f3') -InformationAction Continue
    return $false
}

Export-ModuleMember -Function Get-FrameworkSourceSnapshot, ConvertTo-YurunaBrandName, Get-YurunaBrandIdentity, `
    Test-FrameworkArchiveEndpoint, `
    Get-FrameworkSourceHostCandidate, Test-GuestFrameworkSourcePreflight, Assert-GuestFrameworkSource, `
    Test-ServiceVmFrameworkSource, Assert-ServiceVmFrameworkSource

# Copyright (c) 2019-2026 by Alisson Sol et al.
