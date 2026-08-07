<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42f3c1d8-7a52-4b09-9e64-08c5b7d1e230
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna extension service manifest marker registration
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

# The host side of the extension interface: what an area DECLARES about itself,
# and the runtime marker that says this host is running it.
#
# The declaration -- which VM, which health port, which start script, which
# label -- belongs in the area's own <area>.config.yml `service:` block
# (schema: test/schemas/extension-config.schema.yml), and every marker is
# written through one function, which always emits the uniform base-URL key
# whatever else an area declares. Neither may be spread across per-service
# Start scripts, a hardcoded host roster, or a per-service block in the
# registration writer: that shape makes the services unenumerable and puts a
# framework edit in the path of every new one. A new extension service is
# discovered by existing.
#
# Every read here is best-effort and file-only: a malformed manifest or an
# unreadable marker reports nothing rather than throwing, because a discovery
# nicety must never be able to fail a bring-up, a teardown, or a registration
# write.

$script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ExtensionDir = Join-Path $script:RepoRoot 'test/extension'

# Mtime-keyed cache for parsed manifests, mirroring Test.Extension's config
# cache: the registration writer reads every area's manifest on every write.
$script:ManifestCache = @{}

<#
.SYNOPSIS
    The `service:` manifest an extension area declares, or $null when the area
    declares none.
.DESCRIPTION
    An area without a `service:` block is code the cycle loads (authentication,
    notification) or a sidecar inside another VM -- not something the pool can
    locate, restart, or paint a dashboard row for. Returning $null for those is
    the answer, not a failure.

    Never throws: an unreadable or malformed config reports $null and logs to
    the verbose stream, so one broken area cannot take a bring-up down.
.PARAMETER Area
    Extension area name (the directory basename).
.OUTPUTS
    [hashtable] with Area, DisplayName, VMName, HostedIn, HealthPort,
    HealthPath, StartScript, StopScript, MarkerBaseUrlKey, BeaconInterval,
    WriteGate -- or $null.
#>
function Get-ExtensionServiceManifest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Area)

    $file = Join-Path $script:ExtensionDir $Area -AdditionalChildPath "$Area.config.yml"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $resolved = (Resolve-Path -LiteralPath $file).Path
        $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
        if ($script:ManifestCache.ContainsKey($resolved)) {
            $entry = $script:ManifestCache[$resolved]
            if ($entry.Mtime -eq $mtime) { return $entry.Manifest }
        }
        $svc = Read-ExtensionServiceBlock -Path $resolved
        $manifest = $null
        if ($svc -and $svc.Count -gt 0) {
            $manifest = @{
                Area             = $Area
                DisplayName      = [string]$svc['displayName']
                VMName           = [string]$svc['vmName']
                HostedIn         = [string]$svc['hostedIn']
                HealthPort       = if ($svc['healthPort']) { [int]$svc['healthPort'] } else { 0 }
                HealthPath       = if ($svc['healthPath']) { [string]$svc['healthPath'] } else { '/healthz' }
                StartScript      = [string]$svc['startScript']
                StopScript       = [string]$svc['stopScript']
                MarkerBaseUrlKey = [string]$svc['markerBaseUrlKey']
                BeaconInterval   = [string]$svc['beaconInterval']
                WriteGate        = if ($svc['writeGate']) { [string]$svc['writeGate'] } else { 'lab-token' }
            }
        }
        $script:ManifestCache[$resolved] = @{ Mtime = $mtime; Manifest = $manifest }
        return $manifest
    } catch {
        Write-Verbose "Get-ExtensionServiceManifest '$Area': $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    The `service:` mapping from an <area>.config.yml, as an ordered dictionary.
.DESCRIPTION
    Read by lines, deliberately, and never through a YAML parser.

    Not because a parser would be wrong, but because it would not always be
    THERE. This module's callers include the service-VM roster, which is
    imported on its own -- by the reboot sweep and by cleanup paths -- with
    nothing loaded. A reader that answers only when a parser happens to be in
    scope would return nothing there, and an empty roster means a rebooted host
    never restarts its service VMs and a prefix-matching cleanup can no longer
    prove it will skip them. One path that always works beats two where the one
    that runs in production is the one no test exercises.

    This is not a general YAML reader and does not pretend to be. The block is
    schema-constrained to a flat mapping of scalars
    (test/schemas/extension-config.schema.yml, additionalProperties: false), so
    "key: value at exactly two spaces of indent" is the whole grammar it has to
    handle.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary], possibly empty.
#>
function Read-ExtensionServiceBlock {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $out = [ordered]@{}
    $inBlock = $false
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -match '^service:\s*$') { $inBlock = $true; continue }
        if (-not $inBlock) { continue }
        # A line back at column 0 ends the block: the next top-level key.
        if ($line -notmatch '^  \S') { break }
        if ($line -notmatch '^  ([A-Za-z][A-Za-z0-9]*):\s*(.*)$') { continue }
        $key   = $Matches[1]
        $value = $Matches[2].Trim()
        # Trailing comment, then quotes. A value in this block never contains a
        # '#' of its own, so the split is unambiguous.
        if ($value -match '^(.*?)\s+#') { $value = $Matches[1].Trim() }
        $value = $value.Trim("'", '"')
        $out[$key] = $value
    }
    return $out
}

<#
.SYNOPSIS
    The extension services this host builds a VM for, as roster rows.
.DESCRIPTION
    The shape Test.ServiceVm's roster consumes, derived from the manifests so a
    new extension service joins the reboot sweep and the cleanup guard by
    existing. Key is the area slug with its '-service' suffix dropped, which is
    the short name the roster has always used.
.OUTPUTS
    pscustomobject[] -- Key, VMName, DisplayName, StartScript, HealthPort.
#>
function Get-ExtensionServiceVmRoster {
    [CmdletBinding()]
    [OutputType([pscustomobject[]], [object[]])]
    param()

    $rows = @()
    foreach ($manifest in (Get-ExtensionServiceManifestAll -WithVMOnly)) {
        $key = [string]$manifest.Area -replace '-service$', ''
        $rows += [pscustomobject]@{
            Key         = $key
            VMName      = [string]$manifest.VMName
            DisplayName = [string]$manifest.DisplayName
            StartScript = [string]$manifest.StartScript
            HealthPort  = [int]$manifest.HealthPort
        }
    }
    return [pscustomobject[]]$rows
}

<#
.SYNOPSIS
    Every extension area that declares a `service:` manifest, area-sorted.
.DESCRIPTION
    Discovery by directory, the same rule Get-ExtensionAreaName follows: an area
    joins by existing, not by being added to a list somewhere else.
.PARAMETER WithVMOnly
    Return only services this host builds a VM for -- what a roster of
    startable, stoppable VMs means. A service hosted inside another area's VM
    (the pool aggregator, inside the caching-proxy VM) declares no vmName and is
    excluded.
.OUTPUTS
    [hashtable[]] manifests, possibly empty.
#>
function Get-ExtensionServiceManifestAll {
    [CmdletBinding()]
    [OutputType([hashtable[]], [object[]])]
    param([switch]$WithVMOnly)

    if (-not (Test-Path -LiteralPath $script:ExtensionDir)) { return @() }
    $out = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $script:ExtensionDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $manifest = Get-ExtensionServiceManifest -Area $dir.Name
        if (-not $manifest) { continue }
        if ($WithVMOnly -and [string]::IsNullOrWhiteSpace($manifest.VMName)) { continue }
        $out += $manifest
    }
    return [hashtable[]]$out
}

<#
.SYNOPSIS
    Absolute path of an extension service's runtime marker
    (runtime/<area>.json), or '' when no runtime dir is known.
.PARAMETER Area
    Extension area name.
.PARAMETER RuntimeDir
    Runtime directory holding the marker. Defaults to $env:YURUNA_RUNTIME_DIR.
#>
function Get-ExtensionServiceMarkerPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return '' }
    return (Join-Path -Path $RuntimeDir -ChildPath "$Area.json")
}

<#
.SYNOPSIS
    Write runtime/<area>.json, this host's claim that it runs the service.
.DESCRIPTION
    Key order is fixed so the file is byte-stable across re-runs that change
    nothing: a marker rewritten with reshuffled keys looks like a change to
    every consumer that diffs or hashes it.

    -Active is the readiness verdict, not "the bring-up script ran". The
    aggregator paints the Extension-hosts row and its deep-link from this value;
    publishing $true for a daemon that never bound its port sends operators to a
    dead URL and hides the actual failure.

    The base URL is written under the uniform `baseUrl` AND under the area's own
    `markerBaseUrlKey` when it declares one. Both, because a consumer built
    before the uniform key exists reads only the per-service one, and a host can
    be running a framework newer than the aggregator it reports to.

    Written whole with WriteAllText (UTF-8, no BOM) because the aggregator polls
    the file: a partial write would be parsed as corrupt rather than retried.
.PARAMETER Area
    Extension area name.
.PARAMETER RuntimeDir
    Runtime directory to write into. Defaults to $env:YURUNA_RUNTIME_DIR.
.PARAMETER Active
    The readiness verdict.
.PARAMETER VMName
    Name of the VM running the daemon. Defaults to the manifest's vmName.
.PARAMETER HostType
    Host type that built the VM (host.windows.hyper-v, host.ubuntu.kvm,
    host.macos.utm).
.PARAMETER BaseUrl
    Base URL peers should use for the service UI/API. '' when this host could
    not resolve one.
.PARAMETER StartedAtUtc
    Timestamp to record. Defaults to now, in Zulu form.
.PARAMETER Extra
    Additional service-specific fields, appended in the order given. For the
    facts only one service has -- a host-side launcher's pid and port -- rather
    than a union of every service's fields in the common shape.
.OUTPUTS
    [string] the path written, or '' when there was no runtime dir.
#>
function Write-ExtensionServiceMarker {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [bool]$Active = $false,
        [AllowEmptyString()][string]$VMName = '',
        [AllowEmptyString()][string]$HostType = '',
        [AllowEmptyString()][string]$BaseUrl = '',
        [AllowEmptyString()][string]$StartedAtUtc = '',
        [System.Collections.IDictionary]$Extra
    )
    $path = Get-ExtensionServiceMarkerPath -Area $Area -RuntimeDir $RuntimeDir
    if (-not $path) { return '' }
    $manifest = Get-ExtensionServiceManifest -Area $Area
    if ([string]::IsNullOrWhiteSpace($VMName) -and $manifest) { $VMName = [string]$manifest.VMName }
    if ([string]::IsNullOrWhiteSpace($StartedAtUtc)) {
        $StartedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    $marker = [ordered]@{
        active       = $Active
        area         = $Area
        vmName       = $VMName
        hostType     = $HostType
        startedAtUtc = $StartedAtUtc
        baseUrl      = $BaseUrl
    }
    if ($manifest -and -not [string]::IsNullOrWhiteSpace($manifest.MarkerBaseUrlKey)) {
        $marker[$manifest.MarkerBaseUrlKey] = $BaseUrl
    }
    if ($Extra) {
        foreach ($key in $Extra.Keys) { $marker[[string]$key] = $Extra[$key] }
    }
    [System.IO.File]::WriteAllText($path, ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    return $path
}

<#
.SYNOPSIS
    Read runtime/<area>.json.
.DESCRIPTION
    Never throws: an absent, unreadable, or malformed marker is
    indistinguishable from "this host does not run the service" as far as every
    caller is concerned, and a discovery read must not be able to fail a
    bring-up or a teardown.
.OUTPUTS
    [pscustomobject] the parsed marker, or $null.
#>
function Read-ExtensionServiceMarker {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    $path = Get-ExtensionServiceMarkerPath -Area $Area -RuntimeDir $RuntimeDir
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Verbose "extension marker read '$path': $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    The base URL a marker advertises, honouring both the uniform key and the
    area's own.
.DESCRIPTION
    A marker written by an older framework carries only the per-service key
    (stashBaseUrl, poolControlServiceBaseUrl, downloadAgentServiceBaseUrl); one
    written now carries `baseUrl` as well. Readers ask here rather than each
    picking a key, which is what let three services drift apart in the first
    place.
.OUTPUTS
    [string] the advertised base URL, or ''.
#>
function Get-ExtensionServiceMarkerBaseUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][psobject]$Marker,
        [Parameter(Mandatory)][string]$Area
    )
    if (-not $Marker) { return '' }
    $uniform = [string]$Marker.baseUrl
    if (-not [string]::IsNullOrWhiteSpace($uniform)) { return $uniform.Trim() }

    $manifest = Get-ExtensionServiceManifest -Area $Area
    if ($manifest -and -not [string]::IsNullOrWhiteSpace($manifest.MarkerBaseUrlKey)) {
        $declared = [string]$Marker.($manifest.MarkerBaseUrlKey)
        if (-not [string]::IsNullOrWhiteSpace($declared)) { return $declared.Trim() }
    }
    # Last resort, for a marker written before the uniform key on a host with no
    # YAML parser loaded to read the manifest: the per-service keys all end in
    # BaseUrl, and a marker carries exactly one of them.
    foreach ($property in $Marker.PSObject.Properties) {
        if ($property.Name -notlike '*BaseUrl') { continue }
        $value = [string]$property.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return ''
}

<#
.SYNOPSIS
    Remove runtime/<area>.json so this host stops claiming the area.
.DESCRIPTION
    Runs BEFORE the VM teardown it accompanies. Between the two there is a
    window where the aggregator can poll, and a marker that still says active
    while the VM is being destroyed advertises a service that is already gone --
    the deep-link fails and hosts that trust the row waste a request budget on
    it. Removing first makes the worst case a host that looks service-less
    slightly early.
.OUTPUTS
    [bool] $true when a marker was present and is now gone.
#>
function Remove-ExtensionServiceMarker {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    $path = Get-ExtensionServiceMarkerPath -Area $Area -RuntimeDir $RuntimeDir
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($path, "Remove the $Area marker")) { return $false }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path -LiteralPath $path))
}

<#
.SYNOPSIS
    The areas this host is ACTIVELY running, and the deep-link it advertises for
    each -- what host.registration.json publishes as activeExtensions /
    extensionTargets.
.DESCRIPTION
    Marker presence is the claim; an explicit active:false clears it.

    Driven by the MARKERS on disk, cross-checked against the extension
    directory, rather than by the manifests: this runs inside the registration
    write, which is deliberately file-I/O only and cannot assume a YAML parser
    is loaded. A host whose parser is absent still reports every service it runs
    -- the manifest only enriches the answer, it is not required for it. Every
    failure is a logged skip, because a discovery nicety must never fail a
    registration write.
.OUTPUTS
    [hashtable] @{ Areas = [string[]]; Targets = [ordered] area -> baseUrl }
#>
function Get-ActiveExtensionService {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)

    $areas   = @()
    $targets = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($RuntimeDir) -or -not (Test-Path -LiteralPath $RuntimeDir)) {
        return @{ Areas = [string[]]$areas; Targets = $targets }
    }
    foreach ($file in (Get-ChildItem -LiteralPath $RuntimeDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $area = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        # An extension marker is named for its area. The directory check is what
        # keeps an unrelated runtime file (project.access.json, host-network.json)
        # from being read as one.
        if (-not (Test-Path -LiteralPath (Join-Path $script:ExtensionDir $area) -PathType Container)) { continue }
        try {
            $marker = Read-ExtensionServiceMarker -Area $area -RuntimeDir $RuntimeDir
            if (-not $marker) { continue }
            if ($null -ne $marker.active -and -not [bool]$marker.active) { continue }
            $areas += $area
            $baseUrl = Get-ExtensionServiceMarkerBaseUrl -Marker $marker -Area $area
            if ($baseUrl) { $targets[$area] = $baseUrl }
        } catch {
            Write-Verbose "activeExtensions ($area): $($_.Exception.Message)"
        }
    }
    return @{ Areas = [string[]]$areas; Targets = $targets }
}

Export-ModuleMember -Function Get-ExtensionServiceManifest, Get-ExtensionServiceManifestAll, `
    Get-ExtensionServiceVmRoster, Get-ExtensionServiceMarkerPath, Write-ExtensionServiceMarker, `
    Read-ExtensionServiceMarker, Get-ExtensionServiceMarkerBaseUrl, Remove-ExtensionServiceMarker, `
    Get-ActiveExtensionService
