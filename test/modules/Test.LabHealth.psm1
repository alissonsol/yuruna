<#PSScriptInfo
.VERSION 2026.09.18
.GUID 420e9e53-94d9-42df-aca1-6b21310676a8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab health gate hold service availability
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

# The lab-health gate: before a chain entry and before each sequence step, check
# the services this lab declares, and hold the cycle while one that WAS
# answering has stopped answering.
#
# The probe set is DERIVED, never configured: every extension area already
# declares healthPort/healthPath in its <area>.config.yml `service:` block, and
# Get-ExtensionServiceManifestAll walks them. An area that ships tomorrow is
# gated the day it lands; an area that declares no health surface is out of
# scope. A per-service list here would have to be edited for each one and would
# be wrong the first time it was not.
#
# The gate arms on a CHANGE of condition, not on absolute state. A service this
# host has never reached is not a change -- holding for it would park a fresh
# host forever, where the caller's own pre-flight gives a fast, accurate "there
# is no stash here". So a hold needs a lastOkUtc inside the arming window, and
# that record is kept ACROSS cycles: a service stopped for a rebuild is already
# gone when the next cycle starts, so a baseline captured at cycle start would
# never see the transition it exists to catch.
#
# Leaf module. Every cross-module dependency (Get-PollDelay, the extension
# readers, Send-CycleEventSafely, Write-YurunaStateFileJson) is resolved at CALL
# time and Get-Command-guarded, so a probe degrades to "cannot tell" rather than
# throwing inside a step gate.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:LabHealthRecordFileName = 'lab-health.json'
$script:LabHoldFlagFileName     = 'control.lab-hold'
$script:LabHoldSidecarFileName  = 'lab-hold.json'
$script:LabHoldReleaseFileName  = 'control.lab-hold-release'

# Ceiling on hold re-probes, deliberately compiled in rather than only
# configurable. At up to 59 s per attempt (Get-PollDelay's cap) 999 attempts is
# about sixteen hours: longer than any plausible service rebuild, host reboot or
# overnight network repair, and short enough that a lab abandoned on a Friday
# has produced a failure record by Saturday instead of a host that looks alive
# all weekend. A hold is unbounded by intent; this is what stops "unbounded"
# from meaning "silent forever".
$script:MaxHoldAttemptsCeiling = 999

$script:DefaultMinIntervalSeconds       = 30
$script:DefaultDiscoveryIntervalSeconds = 600
$script:DefaultArmWindowHours           = 24

# Per-attempt probe budget. Deliberately thinner than the extension areas' own
# Test-<Area>Host defaults (3 attempts / 10 s / 500 ms backoff, sized for a
# Wi-Fi connect tail on a one-shot pre-flight): this runs at every step
# boundary, so a slow probe taxes the whole cycle, and a false negative costs
# only the confirmation probe below before the hold loop re-asks anyway.
$script:ProbeAttempts       = 1
$script:ProbeTimeoutSeconds = 3

# In-process verdict cache: area -> @{ Verdict; Address; Detail; CheckedUtc }.
# What keeps the per-step gate free on a fast sequence.
$script:VerdictCache = @{}

function Get-LabHealthHoldCeiling {
    <#
    .SYNOPSIS
        The compiled ceiling on hold re-probes.
    .OUTPUTS
        [int] 999.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$script:MaxHoldAttemptsCeiling
}

function Get-LabHealthConfig {
    <#
    .SYNOPSIS
        Resolve the testCycle.labHealth knobs from a parsed test.config.yml,
        applying the defaults for anything absent.
    .DESCRIPTION
        An absent block reads as ENABLED. The gate is a safety net, and a host
        whose config predates it should get the net rather than have to opt in;
        `enabled: false` is the opt-out.

        MaxHoldAttempts is clamped to the compiled ceiling in BOTH directions:
        a config asking for more than 999 gets 999, and one asking for less than
        1 gets 1. A knob that could raise the ceiling would make the comment on
        $script:MaxHoldAttemptsCeiling a lie.
    .PARAMETER Config
        Parsed test.config.yml, or $null to take every default.
    .OUTPUTS
        [hashtable] Enabled, MinIntervalSeconds, DiscoveryIntervalSeconds,
        ArmWindowHours, MaxHoldAttempts, Require.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Config)

    $tc = if ($Config -is [System.Collections.IDictionary]) { $Config['testCycle'] } else { $null }
    $lh = if ($tc -is [System.Collections.IDictionary] -and $tc.Contains('labHealth')) { $tc['labHealth'] } else { $null }
    $isMap = ($lh -is [System.Collections.IDictionary])

    $maxHold = if ($isMap -and $lh['maxHoldAttempts']) { [int]$lh['maxHoldAttempts'] } else { $script:MaxHoldAttemptsCeiling }
    if ($maxHold -gt $script:MaxHoldAttemptsCeiling) { $maxHold = $script:MaxHoldAttemptsCeiling }
    if ($maxHold -lt 1) { $maxHold = 1 }

    # A bare string is accepted alongside a list: a single-entry YAML sequence
    # is easy to write as a scalar, and silently requiring nothing would be a
    # worse answer than accepting both.
    $require = @()
    if ($isMap -and $lh['require']) {
        $require = @($lh['require']) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }
    }

    return @{
        Enabled                  = if ($isMap -and $lh.Contains('enabled')) { [bool]$lh['enabled'] } else { $true }
        MinIntervalSeconds       = if ($isMap -and $lh['minIntervalSeconds']) { [int]$lh['minIntervalSeconds'] } else { $script:DefaultMinIntervalSeconds }
        DiscoveryIntervalSeconds = if ($isMap -and $lh['discoveryIntervalSeconds']) { [int]$lh['discoveryIntervalSeconds'] } else { $script:DefaultDiscoveryIntervalSeconds }
        ArmWindowHours           = if ($isMap -and $lh['armWindowHours']) { [int]$lh['armWindowHours'] } else { $script:DefaultArmWindowHours }
        MaxHoldAttempts          = $maxHold
        Require                  = [string[]]$require
    }
}

function Resolve-LabHealthConfigDocument {
    <#
    .SYNOPSIS
        The parsed test.config.yml this gate reads its knobs from, or $null.
    .DESCRIPTION
        The two gate sites differ in what they already hold: the orchestrator is
        handed a parsed config, the sequence engine is not. Resolving here means
        `enabled: false` is honored at BOTH -- a host that opted out through the
        engine's gate but not the orchestrator's would hold anyway and read as
        the knob not working.

        Read-TestConfig is mtime+hash cached, so the repeat reads this makes at
        every step boundary re-parse nothing.
    .OUTPUTS
        [System.Collections.IDictionary] or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()
    try {
        $configPath = $env:YURUNA_CONFIG_PATH
        if ([string]::IsNullOrWhiteSpace($configPath)) {
            $configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml'
        }
        if (-not (Test-Path -LiteralPath $configPath)) { return $null }
        if (-not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force -DisableNameChecking -Verbose:$false
        }
        return (Read-TestConfig -Path $configPath)
    } catch {
        Write-Verbose "Resolve-LabHealthConfigDocument: $($_.Exception.Message)"
        return $null
    }
}

function Get-LabHealthRuntimeDir {
    <#
    .SYNOPSIS
        The runtime directory holding the health record and the hold flags, or
        '' when none can be resolved.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue) {
        try { return [string](Initialize-YurunaRuntimeDir) }
        catch { Write-Verbose "Get-LabHealthRuntimeDir: Initialize-YurunaRuntimeDir failed: $($_.Exception.Message)" }
    }
    return [string]$env:YURUNA_RUNTIME_DIR
}

function Read-LabHealthRecord {
    <#
    .SYNOPSIS
        The per-area last-known-good record, as a hashtable of
        area -> @{ lastOkUtc; lastAddress; verdict }.
    .DESCRIPTION
        Never throws: a missing or malformed record reads as empty, which
        disarms the gate rather than failing a step. Losing the record costs a
        cycle of protection; throwing inside a step gate costs the cycle.
    .PARAMETER RuntimeDir
        Directory holding lab-health.json. Defaults to the resolved runtime dir.
    .OUTPUTS
        [hashtable] area -> entry. Empty when nothing is on record.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = (Get-LabHealthRuntimeDir))

    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return @{} }
    $path = Join-Path $RuntimeDir $script:LabHealthRecordFileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $doc = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "Read-LabHealthRecord: $path unreadable: $($_.Exception.Message)"
        return @{}
    }
    if ($doc -isnot [System.Collections.IDictionary] -or -not $doc.Contains('areas')) { return @{} }
    $areas = $doc['areas']
    if ($areas -isnot [System.Collections.IDictionary]) { return @{} }
    $out = @{}
    foreach ($key in $areas.Keys) {
        $entry = $areas[$key]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $out[[string]$key] = @{
            lastOkUtc   = [string]$entry['lastOkUtc']
            lastAddress = [string]$entry['lastAddress']
            verdict     = [string]$entry['verdict']
        }
    }
    return $out
}

function Save-LabHealthRecord {
    <#
    .SYNOPSIS
        Persist the per-area last-known-good record.
    .PARAMETER Record
        area -> @{ lastOkUtc; lastAddress; verdict }.
    .PARAMETER RuntimeDir
        Directory to write lab-health.json into.
    .OUTPUTS
        [bool] $true when the file was written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [string]$RuntimeDir = (Get-LabHealthRuntimeDir)
    )
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $false }
    $path = Join-Path $RuntimeDir $script:LabHealthRecordFileName
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_69313d3714ef798c'))) { return $false }
    $areas = [ordered]@{}
    foreach ($key in ($Record.Keys | Sort-Object)) { $areas[[string]$key] = $Record[$key] }
    $doc = [ordered]@{ schemaVersion = 1; areas = $areas }
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return [bool](Write-YurunaStateFileJson -Path $path -InputObject $doc -Confirm:$false)
    }
    try {
        $tmp = "$path.$PID.tmp"
        $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM -NoNewline
        Move-Item -LiteralPath $tmp -Destination $path -Force
        return $true
    } catch {
        Write-Verbose "Save-LabHealthRecord: $path not written: $($_.Exception.Message)"
        return $false
    }
}

function Test-LabHealthArmed {
    <#
    .SYNOPSIS
        $true when this area's record is recent enough to arm a hold.
    .DESCRIPTION
        A service gone for longer than the window is the lab's new normal, not a
        change of condition. Holding every cycle for it would hide the fact that
        it is gone behind a host that never reports anything at all.
    .PARAMETER Entry
        The area's record entry, or $null.
    .PARAMETER ArmWindowHours
        Age limit on lastOkUtc.
    .PARAMETER NowUtc
        Reference time; defaults to now. Supplied by tests.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]$Entry,
        [int]$ArmWindowHours = $script:DefaultArmWindowHours,
        [datetime]$NowUtc = ([datetime]::UtcNow)
    )
    if ($Entry -isnot [System.Collections.IDictionary]) { return $false }
    $stamp = [string]$Entry['lastOkUtc']
    if ([string]::IsNullOrWhiteSpace($stamp)) { return $false }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($stamp, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed)) {
        return $false
    }
    # A stamp in the FUTURE arms too. Clock skew between this host and whatever
    # wrote the record is not evidence that the service is absent, and reading a
    # future stamp as "not armed" would silently disable the gate on exactly the
    # host whose clock needs looking at.
    if ($parsed -gt $NowUtc) { return $true }
    return (($NowUtc - $parsed).TotalHours -le $ArmWindowHours)
}

function Resolve-LabHealthAddress {
    <#
    .SYNOPSIS
        Candidate addresses for an extension area, most-likely first.
    .DESCRIPTION
        Wraps Get-ExtensionHostAddress with the warning stream suppressed. That
        lookup warns when the pool cannot be asked -- correct for a one-shot
        pre-flight, noise at every step boundary -- and the gate reports the
        condition once, when the verdict actually changes, instead.
    .PARAMETER Area
        Extension area name.
    .OUTPUTS
        [string[]] possibly empty.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Area)
    if (-not (Get-Command Get-ExtensionHostAddress -ErrorAction SilentlyContinue)) { return [string[]]@() }
    try {
        return [string[]]@(Get-ExtensionHostAddress -HostType $Area -WarningAction SilentlyContinue)
    } catch {
        Write-Verbose "Resolve-LabHealthAddress: discovery for '$Area' failed: $($_.Exception.Message)"
        return [string[]]@()
    }
}

function Invoke-LabHealthProbe {
    <#
    .SYNOPSIS
        $true when this address answers for this area.
    .DESCRIPTION
        Prefers the area's contract verb Test-<Area>Host: the four areas that
        export one know things the manifest cannot say -- the caching proxy's
        healthPort is squid's 3128 while its daemon answers /healthz on 9310, so
        a manifest-driven probe there would report a dead daemon on every
        healthy proxy in the lab.

        Falls back to the manifest's healthPort/healthPath for an area that
        declares a health surface but exports no verb, which is what keeps the
        mechanism generic rather than a list of four services.
    .PARAMETER Area
        Extension area name.
    .PARAMETER Address
        Candidate address.
    .PARAMETER Manifest
        The area's service manifest, for the fallback probe.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Address,
        [AllowNull()]$Manifest
    )
    $verb = 'Test-' + (($Area -split '-' | ForEach-Object {
        if ($_.Length -gt 0) { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) } else { $_ }
    }) -join '') + 'Host'
    if (-not (Get-Command $verb -ErrorAction SilentlyContinue)) {
        if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
            try { $null = Import-Extension -Area $Area }
            catch { Write-Verbose "Invoke-LabHealthProbe: Import-Extension '$Area' failed: $($_.Exception.Message)" }
        }
    }
    if (Get-Command $verb -ErrorAction SilentlyContinue) {
        try {
            return [bool](& $verb -Address $Address -Attempts $script:ProbeAttempts `
                -TimeoutSeconds $script:ProbeTimeoutSeconds -BackoffMs 0)
        } catch {
            Write-Verbose "Invoke-LabHealthProbe: $verb '$Address' threw: $($_.Exception.Message)"
            return $false
        }
    }

    $port = if ($Manifest -and $Manifest.HealthPort) { [int]$Manifest.HealthPort } else { 0 }
    if ($port -le 0) { return $false }
    $path = if ($Manifest -and $Manifest.HealthPath) { [string]$Manifest.HealthPath } else { '/healthz' }
    $target = "$Address".Trim()
    if (-not $target) { return $false }
    # An IPv6 literal has to be bracketed to be a legal URL authority. A name or
    # IPv4 literal never contains a colon, and an already-bracketed authority is
    # left alone, so this only fires on a bare IPv6 literal.
    if ($target.Contains(':') -and -not $target.StartsWith('[') -and ($target -split ':').Count -gt 2) {
        $target = "[$target]"
    }
    if (($target -split ':').Count -eq 1 -or $target -match '^\[[^\]]+\]$') { $target = "${target}:$port" }
    try {
        # -NoProxy: these services sit on the lab LAN and the host may have a
        # caching-proxy service in its environment that would neither reach them
        # nor be meant to.
        $resp = Invoke-WebRequest -Uri "http://$target$path" -NoProxy `
            -TimeoutSec $script:ProbeTimeoutSeconds -ErrorAction Stop
        return ([int]$resp.StatusCode -eq 200)
    } catch {
        Write-Verbose "Invoke-LabHealthProbe: http://$target$path failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-LabHealthProbeSet {
    <#
    .SYNOPSIS
        The areas this gate probes, as their service manifests.
    .DESCRIPTION
        Every area declaring a healthPort, which is the whole registry -- an
        area that ships tomorrow is covered without an edit here.
    .OUTPUTS
        [hashtable[]] service manifests.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]], [object[]])]
    param()
    if (-not (Get-Command Get-ExtensionServiceManifestAll -ErrorAction SilentlyContinue)) { return @() }
    try {
        return @(Get-ExtensionServiceManifestAll | Where-Object { $_ -and [int]$_.HealthPort -gt 0 })
    } catch {
        Write-Verbose "Get-LabHealthProbeSet: manifest walk failed: $($_.Exception.Message)"
        return @()
    }
}

function Test-LabHealth {
    <#
    .SYNOPSIS
        Evaluate every probed area and return the lab's verdict.
    .DESCRIPTION
        Per area, in order:

          1. An ARMED area is probed at its last known address FIRST, with no
             discovery at all. That is the steady state -- one HTTP call per
             armed area, no pool round-trip -- and it is why the gate can afford
             to run at every step boundary.
          2. Only when that fails (or the area has no address on record) is
             discovery re-asked. A rebuilt service normally returns on a
             DIFFERENT address, so a cached candidate list would keep probing
             the corpse.
          3. Nothing answered: 'down' for an armed area, 'unknown' otherwise.

        An area that has never answered is deliberately never 'down'. It is not
        a change of condition, and the caller's own pre-flight gives a faster
        and more accurate answer about a service that was never there.

        Areas are probed on two cadences. An armed area is re-probed after
        MinIntervalSeconds; an unarmed one after DiscoveryIntervalSeconds,
        because its lookup is the expensive one (a pool round-trip that has to
        time out) and its answer is the one that almost never changes.
    .PARAMETER Config
        Parsed test.config.yml, or $null for defaults.
    .PARAMETER Force
        Bypass the freshness cache. The hold loop passes this.
    .PARAMETER NowUtc
        Reference time; supplied by tests.
    .OUTPUTS
        [hashtable] Verdict ('ok' | 'down'), Down (area detail array),
        Checked (area names actually probed this call).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Config,
        [switch]$Force,
        [datetime]$NowUtc = ([datetime]::UtcNow)
    )
    $knobs   = Get-LabHealthConfig -Config $Config
    $record  = Read-LabHealthRecord
    $down    = [System.Collections.Generic.List[hashtable]]::new()
    $checked = [System.Collections.Generic.List[string]]::new()
    $dirty   = $false

    foreach ($manifest in (Get-LabHealthProbeSet)) {
        $area     = [string]$manifest.Area
        $entry    = if ($record.ContainsKey($area)) { $record[$area] } else { $null }
        $armed    = Test-LabHealthArmed -Entry $entry -ArmWindowHours $knobs.ArmWindowHours -NowUtc $NowUtc
        $required = ($knobs.Require -contains $area)

        if (-not $Force) {
            $cached = if ($script:VerdictCache.ContainsKey($area)) { $script:VerdictCache[$area] } else { $null }
            if ($cached) {
                $maxAge = if ($armed -or $required) { $knobs.MinIntervalSeconds } else { $knobs.DiscoveryIntervalSeconds }
                if (($NowUtc - [datetime]$cached.CheckedUtc).TotalSeconds -lt $maxAge) {
                    if ($cached.Verdict -eq 'down') {
                        [void]$down.Add(@{
                            area        = $area
                            displayName = [string]$manifest.DisplayName
                            lastAddress = if ($entry) { [string]$entry['lastAddress'] } else { '' }
                            lastOkUtc   = if ($entry) { [string]$entry['lastOkUtc'] } else { '' }
                            detail      = [string]$cached.Detail
                        })
                    }
                    continue
                }
            }
        }

        [void]$checked.Add($area)
        $ok      = $false
        $winner  = ''
        $tried   = [System.Collections.Generic.List[string]]::new()

        $lastAddress = if ($entry) { [string]$entry['lastAddress'] } else { '' }
        if ($armed -and -not [string]::IsNullOrWhiteSpace($lastAddress)) {
            [void]$tried.Add($lastAddress)
            if (Invoke-LabHealthProbe -Area $area -Address $lastAddress -Manifest $manifest) {
                $ok = $true; $winner = $lastAddress
            }
        }
        if (-not $ok) {
            foreach ($address in (Resolve-LabHealthAddress -Area $area)) {
                if ($tried -contains $address) { continue }
                [void]$tried.Add($address)
                if (Invoke-LabHealthProbe -Area $area -Address $address -Manifest $manifest) {
                    $ok = $true; $winner = $address; break
                }
            }
        }

        $verdict = if ($ok) { 'ok' } elseif ($armed -or $required) { 'down' } else { 'unknown' }
        $detail  = if ($ok) {
            ''
        } elseif ($tried.Count -eq 0) {
            'nothing pinned, and discovery found no candidate'
        } else {
            "no answer from $($tried -join ', ')"
        }
        $script:VerdictCache[$area] = @{ Verdict = $verdict; Address = $winner; Detail = $detail; CheckedUtc = $NowUtc }

        if ($ok) {
            $record[$area] = @{
                lastOkUtc   = $NowUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                lastAddress = $winner
                verdict     = 'ok'
            }
            $dirty = $true
        } elseif ($verdict -eq 'down') {
            [void]$down.Add(@{
                area        = $area
                displayName = [string]$manifest.DisplayName
                lastAddress = $lastAddress
                lastOkUtc   = if ($entry) { [string]$entry['lastOkUtc'] } else { '' }
                detail      = $detail
            })
        }
    }

    # A bad verdict never clears the record: doing so would disarm the gate at
    # exactly the moment it is needed, and the next cycle would see "never seen
    # healthy" for a service this lab has been using all week.
    if ($dirty) { $null = Save-LabHealthRecord -Record $record -Confirm:$false }

    return @{
        Verdict = if ($down.Count -gt 0) { 'down' } else { 'ok' }
        Down    = [hashtable[]]$down.ToArray()
        Checked = [string[]]$checked.ToArray()
    }
}

function Clear-LabHealthVerdictCache {
    <#
    .SYNOPSIS
        Drop the in-process verdict cache so the next evaluation re-probes.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_7ae10c2dbfdfdadd'), 'Clear')) { $script:VerdictCache = @{} }
}

function Get-LabHoldPath {
    <#
    .SYNOPSIS
        Absolute paths of the hold flag, its sidecar, and the release flag.
    .PARAMETER RuntimeDir
        Directory holding them.
    .OUTPUTS
        [hashtable] Flag, Sidecar, Release -- each '' when no runtime dir exists.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = (Get-LabHealthRuntimeDir))
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return @{ Flag = ''; Sidecar = ''; Release = '' } }
    return @{
        Flag    = Join-Path $RuntimeDir $script:LabHoldFlagFileName
        Sidecar = Join-Path $RuntimeDir $script:LabHoldSidecarFileName
        Release = Join-Path $RuntimeDir $script:LabHoldReleaseFileName
    }
}

function Set-LabHold {
    <#
    .SYNOPSIS
        Raise the hold: write control.lab-hold and its lab-hold.json sidecar.
    .PARAMETER Down
        The area detail records that are down.
    .PARAMETER SinceUtc
        When the hold began.
    .PARAMETER Attempt
        Re-probe attempt count so far.
    .PARAMETER RuntimeDir
        Directory to write into.
    .OUTPUTS
        [bool] $true when the flag is in place.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Down,
        [Parameter(Mandatory)][datetime]$SinceUtc,
        [int]$Attempt = 0,
        [string]$RuntimeDir = (Get-LabHealthRuntimeDir)
    )
    $paths = Get-LabHoldPath -RuntimeDir $RuntimeDir
    if (-not $paths.Flag) { return $false }
    if (-not $PSCmdlet.ShouldProcess($paths.Flag, (Format-YurunaOperatorMessage -Key 'runner.operator_19eebac71a00a10a'))) { return $false }
    try {
        # The flag is the gate that every reader tests for; the sidecar is only
        # ever detail about it. Write the sidecar FIRST so no reader can see a
        # raised hold with no explanation beside it.
        $doc = [ordered]@{
            schemaVersion = 1
            since         = $SinceUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            attempt       = [int]$Attempt
            areas         = @($Down)
        }
        if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
            $null = Write-YurunaStateFileJson -Path $paths.Sidecar -InputObject $doc -Confirm:$false
        } else {
            $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $paths.Sidecar -Encoding utf8NoBOM -NoNewline
        }
        Set-Content -LiteralPath $paths.Flag -Value ($Down.area -join ',') -Encoding ascii -NoNewline
        return $true
    } catch {
        Write-Verbose "Set-LabHold: could not raise the hold: $($_.Exception.Message)"
        return $false
    }
}

function Clear-LabHold {
    <#
    .SYNOPSIS
        Drop the hold flag and its sidecar.
    .DESCRIPTION
        Leaves lab-health.json alone: that is knowledge, not parked state, and
        clearing it would disarm the gate for the next cycle.
    .PARAMETER RuntimeDir
        Directory holding the flags.
    .OUTPUTS
        [bool] $true when nothing is left behind.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$RuntimeDir = (Get-LabHealthRuntimeDir))
    $paths = Get-LabHoldPath -RuntimeDir $RuntimeDir
    if (-not $paths.Flag) { return $false }
    if (-not $PSCmdlet.ShouldProcess($paths.Flag, (Format-YurunaOperatorMessage -Key 'runner.operator_92f3da73bdbf3747'))) { return $false }
    $ok = $true
    foreach ($path in @($paths.Flag, $paths.Sidecar, $paths.Release)) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        catch { $ok = $false; Write-Verbose "Clear-LabHold: $path not removed: $($_.Exception.Message)" }
    }
    return $ok
}

function Test-LabHoldReleaseRequested {
    <#
    .SYNOPSIS
        $true when the operator asked to stop waiting.
    .PARAMETER RuntimeDir
        Directory holding the release flag.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$RuntimeDir = (Get-LabHealthRuntimeDir))
    $paths = Get-LabHoldPath -RuntimeDir $RuntimeDir
    if (-not $paths.Release) { return $false }
    return (Test-Path -LiteralPath $paths.Release)
}

function New-LabHealthEvent {
    <#
    .SYNOPSIS
        Build one lab-health NDJSON record.
    .PARAMETER EventName
        Event name.
    .PARAMETER Down
        Area detail records the event is about.
    .PARAMETER FromVerdict
        Verdict before the transition.
    .PARAMETER ToVerdict
        Verdict after it.
    .PARAMETER Attempts
        Re-probes spent.
    .PARAMETER HeldSeconds
        Wall-clock seconds held.
    .PARAMETER Armed
        Whether the areas were armed.
    .PARAMETER ReleasedBy
        Who ended the hold, for lab_health_released.
    .OUTPUTS
        [hashtable] ready for Send-CycleEventSafely.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory builder: returns a fresh event hashtable; changes no externally observable state.')]
    param(
        [Parameter(Mandatory)][string]$EventName,
        [AllowEmptyCollection()][hashtable[]]$Down = @(),
        [string]$FromVerdict = '',
        [string]$ToVerdict = '',
        [int]$Attempts = 0,
        [int]$HeldSeconds = 0,
        [bool]$Armed = $true,
        [string]$ReleasedBy = ''
    )
    $record = @{
        timestamp   = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        event       = $EventName
        areas       = [string[]]@($Down | ForEach-Object { [string]$_.area })
        attempts    = [int]$Attempts
        heldSeconds = [int]$HeldSeconds
        armed       = [bool]$Armed
    }
    if ($FromVerdict) { $record['fromVerdict'] = $FromVerdict }
    if ($ToVerdict)   { $record['toVerdict']   = $ToVerdict }
    if ($ReleasedBy)  { $record['releasedBy']  = $ReleasedBy }
    return $record
}

function Format-LabHoldSummary {
    <#
    .SYNOPSIS
        One human line naming what is down and where it was last seen.
    .PARAMETER Down
        Area detail records.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Down)
    if ($Down.Count -eq 0) { return '' }
    return (($Down | ForEach-Object {
        $name = if ($_.displayName) { [string]$_.displayName } else { [string]$_.area }
        $seen = if ($_.lastAddress) { " (last seen at $($_.lastAddress))" } else { '' }
        "$name$seen"
    }) -join '; ')
}

function Wait-LabHealthy {
    <#
    .SYNOPSIS
        Hold the cycle while an armed lab service is away; return when it is
        back, when the operator releases the hold, or when the ceiling is hit.
    .DESCRIPTION
        Entered only on a verdict of 'down', which by construction means an area
        this host reached inside the arming window has stopped answering.

        The loop re-probes with Force so the freshness cache cannot answer for
        it, and re-asks DISCOVERY each attempt rather than replaying a candidate
        list: a rebuilt service normally comes back on a different address.

        It stays interruptible. Every iteration runs the caller's abort check
        (the cycle-restart gate) so Restart aborts a held cycle exactly as it
        aborts a running one, and yields to the caller's pause wait so an
        operator pausing on top of a hold stops the re-probing rather than
        racing it.
    .PARAMETER Label
        Step label for the log and the current-action line.
    .PARAMETER Config
        Parsed test.config.yml.
    .PARAMETER WriteAction
        Optional scriptblock taking one line of current-action text.
    .PARAMETER CheckAbort
        Optional scriptblock run each iteration; may throw to abort the cycle.
    .PARAMETER WaitWhilePaused
        Optional scriptblock that blocks while the operator's pause is set.
    .PARAMETER NoSleep
        Skip the backoff sleep. For tests only.
    .OUTPUTS
        [hashtable] Held (bool), Outcome ('none'|'recovered'|'released'|'exhausted'),
        Attempts, HeldSeconds, Down (the areas that were down).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()]$Config,
        [scriptblock]$WriteAction,
        [scriptblock]$CheckAbort,
        [scriptblock]$WaitWhilePaused,
        [switch]$NoSleep
    )
    $idle = @{ Held = $false; Outcome = 'none'; Attempts = 0; HeldSeconds = 0; Down = [hashtable[]]@(); Summary = '' }
    if (-not $PSBoundParameters.ContainsKey('Config')) { $Config = Resolve-LabHealthConfigDocument }
    $knobs = Get-LabHealthConfig -Config $Config
    if (-not $knobs.Enabled) { return $idle }

    $verdict = Test-LabHealth -Config $Config
    if ($verdict.Verdict -ne 'down') { return $idle }

    # Confirmation probe before parking the cycle. This gate runs on a thin
    # single-attempt probe, so one dropped packet is enough to produce a 'down'
    # on a service that is up -- and parking a cycle on a dropped packet is a
    # worse failure than the one being prevented.
    Clear-LabHealthVerdictCache -Confirm:$false
    $verdict = Test-LabHealth -Config $Config -Force
    if ($verdict.Verdict -ne 'down') { return $idle }

    $down    = [hashtable[]]$verdict.Down
    $summary = Format-LabHoldSummary -Down $down
    $since   = [datetime]::UtcNow
    $attempt = 0

    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_21b2b234d88a618c' -Arguments @{ label = "$Label"; summary = "$summary"; maxHoldAttempts = "$($knobs.MaxHoldAttempts)" })
    if ($WriteAction) { & $WriteAction "$Label Lab hold: $summary (waiting for it to return)" }
    $null = Set-LabHold -Down $down -SinceUtc $since -Attempt 0 -Confirm:$false
    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
        Send-CycleEventSafely -EventRecord (New-LabHealthEvent -EventName 'lab_health_change' `
            -Down $down -FromVerdict 'ok' -ToVerdict 'down' -Armed $true)
    }

    $outcome = 'exhausted'
    while ($attempt -lt $knobs.MaxHoldAttempts) {
        if ($CheckAbort) { & $CheckAbort $Label }
        if ($WaitWhilePaused) { & $WaitWhilePaused "$Label lab hold" }
        if (Test-LabHoldReleaseRequested) { $outcome = 'released'; break }

        $attempt++
        if (-not $NoSleep) { Start-Sleep -Milliseconds (Get-LabHoldPollDelay -Attempt $attempt) }

        Clear-LabHealthVerdictCache -Confirm:$false
        $verdict = Test-LabHealth -Config $Config -Force
        if ($verdict.Verdict -ne 'down') { $outcome = 'recovered'; break }
        $down = [hashtable[]]$verdict.Down
        $null = Set-LabHold -Down $down -SinceUtc $since -Attempt $attempt -Confirm:$false
    }

    $held = [int][Math]::Round(([datetime]::UtcNow - $since).TotalSeconds)
    $null = Clear-LabHold -Confirm:$false

    switch ($outcome) {
        'recovered' {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b44c2949a079f8ca' -Arguments @{ label = "$Label"; attempt = "$attempt"; held = "$held" }) -InformationAction Continue
            if ($WriteAction) { & $WriteAction "$Label Lab recovered after $held s; resuming" }
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord (New-LabHealthEvent -EventName 'lab_health_change' `
                    -Down $down -FromVerdict 'down' -ToVerdict 'ok' -Attempts $attempt -HeldSeconds $held -Armed $true)
            }
        }
        'released' {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d848709e929a7539' -Arguments @{ label = "$Label"; attempt = "$attempt"; held = "$held" })
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord (New-LabHealthEvent -EventName 'lab_health_released' `
                    -Down $down -Attempts $attempt -HeldSeconds $held -Armed $true -ReleasedBy 'operator')
            }
        }
        default {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2dfaa8b21e51d904' -Arguments @{ label = "$Label"; attempt = "$attempt"; held = "$held"; summary = "$summary" })
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord (New-LabHealthEvent -EventName 'lab_health_exhausted' `
                    -Down $down -Attempts $attempt -HeldSeconds $held -Armed $true)
            }
        }
    }

    return @{
        Held        = $true
        Outcome     = $outcome
        Attempts    = $attempt
        HeldSeconds = $held
        Down        = $down
        Summary     = $summary
    }
}

function Get-LabHoldPollDelay {
    <#
    .SYNOPSIS
        Milliseconds to wait before the next hold re-probe.
    .DESCRIPTION
        Get-PollDelay when it is loaded -- the same 59 s-capped exponential with
        proportional jitter the step-pause loop already polls with, so a hold
        wakes to see a recovered service within a minute however long it has
        been waiting. Falls back to a flat 5 s only where that module is absent,
        which keeps this callable from a test fixture that loaded nothing else.
    .PARAMETER Attempt
        1-indexed attempt number.
    .OUTPUTS
        [int] milliseconds.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([int]$Attempt = 1)
    if (Get-Command Get-PollDelay -ErrorAction SilentlyContinue) { return [int](Get-PollDelay -Attempt $Attempt) }
    return 5000
}

function Invoke-LabHealthGate {
    <#
    .SYNOPSIS
        The call site's whole interaction with the gate: hold if needed, and
        throw when the hold gave up.
    .DESCRIPTION
        Wraps Wait-LabHealthy with the give-up path so the gate sites stay one
        line each. On exhaustion it records a classified infra failure and
        throws -- the runner needs a last_failure.json to route on, and a gate
        that merely returned would let the step run and report whatever
        unrelated symptom the missing service produced downstream.

        The throw carries Exception.Data['YurunaLabDependencyDown'] and the
        matching message prefix so a caller can recognize it. Recognizing it
        matters twice: an exhausted hold must not be counted as a crash (the
        condition is already described in full, so a stack dump adds nothing),
        and the caller's generic crash handler must not overwrite the
        classified record this just wrote.
    .PARAMETER Label
        Step label.
    .PARAMETER Config
        Parsed test.config.yml.
    .PARAMETER HostType
        Host type, for the failure record.
    .PARAMETER Stage
        Stage name recorded on the failure.
    .PARAMETER WriteAction
        Optional current-action writer.
    .PARAMETER CheckAbort
        Optional per-iteration abort check.
    .PARAMETER WaitWhilePaused
        Optional operator-pause wait.
    .OUTPUTS
        [hashtable] the Wait-LabHealthy result.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()]$Config,
        [string]$HostType = '',
        [string]$Stage = 'lab-health',
        [scriptblock]$WriteAction,
        [scriptblock]$CheckAbort,
        [scriptblock]$WaitWhilePaused
    )
    if (-not $PSBoundParameters.ContainsKey('Config')) { $Config = Resolve-LabHealthConfigDocument }
    $callArgs = @{ Label = $Label; Config = $Config }
    if ($WriteAction)     { $callArgs['WriteAction']     = $WriteAction }
    if ($CheckAbort)      { $callArgs['CheckAbort']      = $CheckAbort }
    if ($WaitWhilePaused) { $callArgs['WaitWhilePaused'] = $WaitWhilePaused }
    $result = Wait-LabHealthy @callArgs

    if ($result.Outcome -eq 'exhausted') {
        $held    = [int]$result.HeldSeconds
        $minutes = [int][Math]::Round($held / 60)
        $lastOk  = (($result.Down | ForEach-Object {
            $when = if ($_.lastOkUtc) { [string]$_.lastOkUtc } else { 'never' }
            "$($_.area) at $when"
        }) -join '; ')
        $message = (Format-YurunaOperatorMessage -Key 'runner.operator_aeb09da91185e650' -Arguments @{ attempts = "$($result.Attempts)"; minutes = "$minutes"; summary = "$($result.Summary)"; lastOk = "$lastOk" })
        # Record BEFORE throwing. Write-CycleInfraFailure writes last_failure.json
        # only when none exists, so this is the record downstream routing reads --
        # and every call site below is written to leave it standing rather than
        # overwrite it with the generic shape its own catch would produce.
        if (Get-Command Write-CycleInfraFailure -ErrorAction SilentlyContinue) {
            try {
                Write-CycleInfraFailure -Stage $Stage -FailureClass 'lab_dependency_down' -Severity 'hard' `
                    -GuestKey '(orchestration)' -VMName '' -ErrorMessage $message -HostType $HostType
            } catch {
                Write-Verbose "Invoke-LabHealthGate: no failure record written -- $($_.Exception.Message)"
            }
        }
        # Carried as a tagged control-flow marker, the same shape the cycle-restart
        # gate uses: an exhausted hold is not a code crash, and the callers that
        # catch it have to tell it apart from one to avoid a postmortem banner over
        # a condition already described in full, and to leave the classified record
        # in place. The Exception.Data tag survives a rewrap that would strip the
        # message prefix; the prefix stays as the fallback.
        $stop = [System.Management.Automation.RuntimeException]::new("YurunaLabDependencyDown: $message")
        $stop.Data['YurunaLabDependencyDown'] = $true
        throw $stop
    }
    return $result
}

Export-ModuleMember -Function `
    Get-LabHealthHoldCeiling, Get-LabHealthConfig, Get-LabHealthRuntimeDir, `
    Resolve-LabHealthConfigDocument, `
    Read-LabHealthRecord, Save-LabHealthRecord, Test-LabHealthArmed, `
    Get-LabHealthProbeSet, Test-LabHealth, Clear-LabHealthVerdictCache, `
    Get-LabHoldPath, Set-LabHold, Clear-LabHold, Test-LabHoldReleaseRequested, `
    New-LabHealthEvent, Format-LabHoldSummary, Wait-LabHealthy, `
    Get-LabHoldPollDelay, Invoke-LabHealthGate
