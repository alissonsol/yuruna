<#PSScriptInfo
.VERSION 2026.11.05
.GUID 420783b4-e34a-4b51-b88e-e01fa3738a91
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna diagnostics system health docker kubernetes
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
    Read-only system diagnostics dump: host metrics, Docker state, Kubernetes
    state, and a "problems detected" summary aggregating any signal that
    typically indicates trouble on a Yuruna test host.

.DESCRIPTION
    Sections (each gracefully skipped if its tool is unavailable):
      1. HOST    -- hostname, OS, kernel, uptime, PowerShell, time
     1b. BIOS    -- complete PowerShell BIOS inventory in a fixed field order;
                    on Linux the world-readable DMI identity (vendor, product,
                    board, BIOS version and date) and the CPU microcode revision
      2. CPU     -- model, core count, load average / busy %
      3. MEMORY  -- total / used / available / swap; on Windows the
                    commit charge and how much of it no process's private
                    bytes hold
      4. DISK    -- free space per filesystem; flag any > 90% full
      5. GPU     -- vendor + driver where detectable
      6. NETWORK -- interfaces, default route, DNS resolution sanity, and
                    (Windows) the Hyper-V virtual switch uplink fingerprint:
                    bound NIC link state, management-OS vNIC presence and
                    address, and a per-switch verdict
      7. TOP     -- top processes by CPU and by memory
      8. EVENTS  -- recent kernel/system errors; on Linux first whether the
                    system journal is readable here, and how to make it so
      9. DOCKER  -- daemon health, containers (all), images, disk usage
     10. KUBE    -- cluster info, nodes, all-namespaces inventory,
                    port-forwards (detected via host-process scan),
                    recent Warning events
     11. HOST DETAIL -- starts with the Yuruna runner process tree
                    (descendants of $YURUNA_RUNTIME_DIR/inner.pid or
                    runner.pid) so a stuck cycle's blocking child
                    (ssh.exe, virsh, vmconnect, ...) is visible. Then
                    per-platform:
                      * Windows: Hyper-V VMs, listening sockets
                        (Get-NetTCPConnection), firewall profiles,
                        recent System log errors.
                      * macOS:   netstat -nr, ifconfig, scutil DNS,
                        lsof listening sockets, UTM/utmctl state,
                        unified log errors.
                      * Linux:   netplan, /etc/resolv.conf, /etc/hosts,
                        resolvectl/systemd-resolve status, ip route
                        (full), ss listening sockets, ping connectivity
                        probe, iptables -S, dmesg -T (the current boot's
                        kernel journal when dmesg is restricted) with OOM
                        and hardware-error scans, the lockup and
                        crash-evidence settings, the deep diagnostics mode
                        state, lsmod (virtualization modules), journalctl -xe,
                        per-unit journals for docker/containerd/kubelet,
                        /opt/cni/bin/ + /etc/cni/net.d/ state.
     11b. INSTALL TIMELINE (Linux only) -- /var/log/installer/* (subiquity
                    server-debug + curtin-install logs, autoinstall-user-data
                    that actually shipped), /var/log/cloud-init.log tail,
                    cloud-init status --long + analyze blame, /run/cloud-init
                    result+status JSON, systemd-analyze time/blame, the
                    boot list and the install boot's journal, the
                    systemd-networkd journal and NetworkManager's dhcp4
                    lines, networkctl + ip -br link/addr, and a dmesg grep
                    for eth0/netvsc/accept_ra/carrier events. Diagnoses
                    install-time wedges (subiquity _send_update CHANGE eth0
                    loop, apt mirror retry storms, IPv6 RA-driven netplan
                    re-apply) that runtime sections cannot see.
     11c. GUEST PROVISIONING (Linux only) -- every file under
                    /var/log/yuruna/ (one per pwsh_retry-wrapped action,
                    e.g. pwsh-yaml-install.log) carrying per-attempt
                    pre-flight probes and Verbose streams, plus a slice
                    of systemd-resolved's journal and a current snapshot
                    of PSRepository / PackageProvider / module state.
                    Diagnoses transient PSGallery / NuGet / DNS flakes
                    that a one-shot Install-Module reduces to the same
                    low-information "No match was found" string whichever
                    leg actually failed.
     12. YURUNA PROJECT -- ../project tree scan for resources.output.yml
                    files (path + content + empty-block analysis) and a
                    grep across every .yuruna/ working folder for any
                    line mentioning error/fail/warning, so a stuck cycle
                    can be triaged from one diagnostic dump.
     13. GAP HEURISTICS -- four cross-section checks for silent failure
                    modes where one phase wrote artifacts but a downstream
                    phase produced nothing in the cluster (tofu-state-
                    without-helm-releases, declared-namespace-missing,
                    cluster-Ready-but-no-user-pods, registry-image-not-
                    referenced).
     14. SUMMARY -- list of problems detected

    Side-effect-free: nothing is started, stopped, or modified.

    Implementation details (what each section reports + helper contracts):
        https://yuruna.link/42fa6f45-0013
    Incident-driven design rationale (per-section "Why ..." entries):
        https://yuruna.link/42d69dfa-0029

.PARAMETER OutFile
    Optional: also tee output to this path.

.PARAMETER SkipKube
    Skip the Kubernetes section even if kubectl is available
    (useful when kubectl would block on a stale context).

.PARAMETER SkipDocker
    Skip the Docker section even if docker is available.

.PARAMETER SkipProjectGaps
    Skip the YURUNA PROJECT and GAP HEURISTICS sections. These recursively walk
    the entire ../project tree (resources.output.yml, .yuruna/ working folders,
    tofu state) and are the slowest part of a run; a host/guest-only collection
    that does not need deploy-gap analysis can bypass them. Omit it to get the
    full collection.

.PARAMETER CheckoutRoot
    Optional framework checkout containing VERSION and automation/. This is the
    evidence location, independent of where this standalone script was copied.
    When omitted, probe only the script's checkout and $HOME/yuruna. An invalid
    explicit path disables checkout-dependent collection.

.PARAMETER logLevel
    One of Error|Warning|Information|Verbose|Debug. Each level shows
    itself + all higher-priority streams (Error highest). Default
    'Information' so the section banners show by default.

.EXAMPLE
    pwsh automation/Get-SystemDiagnostic.ps1

.EXAMPLE
    pwsh automation/Get-SystemDiagnostic.ps1 -OutFile diag.txt

.EXAMPLE
    pwsh automation/Get-SystemDiagnostic.ps1 -SkipKube > diag.txt
#>

param(
    [string]$OutFile = $null,
    [switch]$SkipDocker,
    [switch]$SkipKube,
    [switch]$SkipProjectGaps,
    [string]$CheckoutRoot,
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel = 'Information'
)

# --- REGION: Standalone diagnostic dependencies
# See https://yuruna.link/42e220c4-0017
# DO NOT REFACTOR THIS SCRIPT INTO MODULES: it must run alone on a guest.
# Keep embedded helpers synchronized with their source modules.
$script:DiagnosticTextRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { '' }
$script:DiagnosticLocaleManifest = $null
$script:DiagnosticOperatorLocale = $null
$script:DiagnosticMessageTables = @{}
$script:DiagnosticEmbeddedMessages = $null

function Resolve-DiagnosticEvidenceRoot {
    <#
    .SYNOPSIS
        Find a checkout at known locations without walking an unrelated tree.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$CheckoutRoot,
        [AllowEmptyString()][string]$ScriptDirectory,
        [AllowEmptyString()][string]$HomeDirectory
    )
    $candidates = if ($CheckoutRoot) { @($CheckoutRoot) } else {
        @(
            if ($ScriptDirectory) { Split-Path -Parent $ScriptDirectory }
            if ($HomeDirectory) { Join-Path -Path $HomeDirectory -ChildPath 'yuruna' }
        )
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $directory = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if ($directory -isnot [IO.DirectoryInfo] -or
                ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $root = $directory.FullName
            if ($root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -eq
                [IO.Path]::GetPathRoot($root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) { continue }
            if ((Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'VERSION') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'automation') -PathType Container)) {
                return $root
            }
        } catch {
            Write-Verbose "Checkout evidence unavailable at '$candidate': $($_.Exception.Message)"
        }
    }
    return $null
}

$script:DiagnosticEvidenceRoot = Resolve-DiagnosticEvidenceRoot -CheckoutRoot $CheckoutRoot -ScriptDirectory $PSScriptRoot -HomeDirectory $HOME
$script:DiagnosticKubeRows = @{}
$script:DiagnosticHelmReleases = $null

# --- REGION: Get-DiagnosticSourceFile
function Get-DiagnosticSourceFile {
    <#
    .SYNOPSIS
        Select one bounded regular file without following checkout links.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [long]$MaximumBytes = 8388608
    )
    try {
        $item = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
        if ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
        $parts = @($RelativePath -split '[/\\]')
        foreach ($part in $parts) {
            if (-not $part -or $part -in @('.', '..')) { return $null }
            $item = Get-Item -LiteralPath (Join-Path $item.FullName $part) -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
        }
        if ($item -is [IO.FileInfo] -and $item.Length -le $MaximumBytes) {
            # Unix named pipes also appear as FileInfo with a zero length.
            if (-not $IsWindows -and [string]$item.UnixStat.ItemType -ne 'File') { return $null }
            return $item
        }
    } catch {
        Write-Verbose "Source evidence unavailable: $RelativePath"
    }
    return $null
}

# --- REGION: Get-DiagnosticSourceProvenance
function Get-DiagnosticSourceProvenance {
    <#
    .SYNOPSIS
        Report actual archive or Git revisions and bounded effective source hashes.
    .DESCRIPTION
        These are guest checkout facts, independent of the runner's recorded SHA.
        Only fixed source paths are hashed; repository URLs and file contents
        are omitted. Git probes have a deadline and cannot inherit a parent
        repository when a materialized project has no Git metadata of its own.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyString()][string]$CheckoutRoot)
    $result = @{ schemaVersion = 1 }
    foreach ($name in @('framework', 'project')) {
        $entry = @{ state = 'unavailable'; revision = $null; source = 'none'; hashes = @{} }
        $result[$name] = $entry
        if (-not $CheckoutRoot) { continue }
        $root = if ($name -eq 'framework') { $CheckoutRoot } else { Join-Path $CheckoutRoot 'project' }
        $directory = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
        if ($directory -isnot [IO.DirectoryInfo] -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $gitMetadata = Get-Item -LiteralPath (Join-Path $root '.git') -Force -ErrorAction SilentlyContinue
        if ($gitMetadata) {
            $entry.source = 'git'
            $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($git -and -not ($gitMetadata.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                try {
                    $probe = Invoke-DiagnosticBoundedCommand -FilePath $git.Source -TimeoutSeconds 2 -MaxCapturedChars 4096 `
                        -ArgumentList @('-C', $root, 'rev-parse', '--show-toplevel', '--verify', 'HEAD')
                    $lines = @(([string]$probe.StdOut).Trim() -split '\r?\n')
                    if ($probe.Started -and $probe.ExitCode -eq 0 -and -not $probe.TimedOut -and
                        -not $probe.DrainTimedOut -and -not $probe.OutputTruncated -and $lines.Count -eq 2 -and
                        [IO.Path]::GetFullPath($lines[0]) -eq [IO.Path]::GetFullPath($root) -and
                        $lines[1] -match '^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$') {
                        $entry.revision = $lines[1].ToLowerInvariant()
                        $entry.state = 'present'
                    }
                } catch { Write-Verbose 'Git revision evidence unavailable.' }
            }
        } else {
            $marker = Get-DiagnosticSourceFile -Root $root -RelativePath '.yuruna-revision' -MaximumBytes 256
            if ($marker) {
                $entry.source = 'archive'
                try {
                    $revision = [IO.File]::ReadAllText($marker.FullName).Trim()
                    if ($revision -match '^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$') {
                        $entry.revision = $revision.ToLowerInvariant()
                        $entry.state = 'present'
                    } else { $entry.state = 'invalid' }
                } catch { Write-Verbose 'Archive revision evidence unavailable.' }
            }
        }
        $paths = if ($name -eq 'framework') {
            @('automation/fetch-and-execute.sh', 'automation/yuruna-retry.sh', 'guest/shared/ubuntu.update.sh')
        } else {
            @('tools/example-workload.sh', 'tools/Example.Build.psm1',
                'example/website/components/frontend/website/Dockerfile',
                'example/text-to-sql/components/frontend/text-to-sql-ui/Dockerfile')
        }
        foreach ($relativePath in $paths) {
            $file = Get-DiagnosticSourceFile -Root $root -RelativePath $relativePath
            if (-not $file) { $entry.hashes[$relativePath] = @{ state = 'unavailable'; sha256 = $null }; continue }
            try {
                $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop
                $entry.hashes[$relativePath] = @{ state = 'present'; sha256 = $hash.Hash.ToLowerInvariant(); bytes = $file.Length }
            } catch { $entry.hashes[$relativePath] = @{ state = 'unavailable'; sha256 = $null } }
        }
    }
    return $result
}

function Set-YurunaLogLevel {
    <#
    .SYNOPSIS
        Apply the logLevel cascade: enable each preference stream at or above the
        selected level (Error highest), silence the rest.
    .DESCRIPTION
        The cascade of Set-YurunaLogLevel in Yuruna.LogLevel.psm1, which this
        script cannot import. Error < Warning < Information < Verbose < Debug by
        verbosity; a level shows itself and every higher-priority stream.
        $ErrorActionPreference keeps its inherited default so errors stay
        visible at every level.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets the session preference streams from one level name; a preference cascade, not a resource mutation.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'The $global:*Preference automatic variables are the cross-scope contract this helper exists to set.')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
        [string]$LogLevel
    )
    $rank = @{ Error = 1; Warning = 2; Information = 3; Verbose = 4; Debug = 5 }
    $eff  = $rank[$LogLevel]
    $global:WarningPreference     = if ($rank.Warning     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:InformationPreference = if ($rank.Information -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:VerbosePreference     = if ($rank.Verbose     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:DebugPreference       = if ($rank.Debug       -le $eff) { 'Continue' } else { 'SilentlyContinue' }
}

function Get-DiagnosticLocaleManifest {
    <#
    .SYNOPSIS
        The locale table: the checkout's locale manifest, or its en-US entry alone.
    .DESCRIPTION
        Reads globalization/locale-manifest.json as Get-LocaleManifest in
        Test.Locale.psm1 reads it. Without a checkout around this file only the
        embedded en-US text can be rendered, so the built-in table holds that
        one locale with the separators, plural rule and direction the manifest
        gives it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($script:DiagnosticLocaleManifest) { return $script:DiagnosticLocaleManifest }
    $manifest = @{
        Default      = 'en-US'
        Supported    = @('en-US')
        Aliases      = @{}
        Direction    = @{ 'en-US' = 'ltr' }
        NumberFormat = @{ 'en-US' = @{ Group = ','; Decimal = '.'; GroupSize = 3 } }
        PluralRule   = @{ 'en-US' = 'one-if-1' }
        MaxTagLength = 35
    }
    $path = if ($script:DiagnosticTextRoot) { Join-Path $script:DiagnosticTextRoot 'globalization/locale-manifest.json' } else { '' }
    if ($path -and [IO.File]::Exists($path)) {
        try {
            $raw = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)))
            $read = @{
                Default = [string]$raw.default; Supported = @(); Aliases = @{}; Direction = @{}; NumberFormat = @{}; PluralRule = @{}
                MaxTagLength = if ($raw.maxTagLength) { [int]$raw.maxTagLength } else { 35 }
            }
            foreach ($p in $raw.locales.PSObject.Properties) {
                if ($p.Value.status -eq 'supported') { $read.Supported += $p.Name }
                $read.Direction[$p.Name] = [string]$p.Value.direction
                $nf = $p.Value.numberFormat
                if ($nf) {
                    $read.NumberFormat[$p.Name] = @{
                        Group = [string]$nf.group; Decimal = [string]$nf.decimal
                        GroupSize = if ($nf.groupSize) { [int]$nf.groupSize } else { 3 }
                    }
                }
                if ($null -ne $p.Value.pluralRule) { $read.PluralRule[$p.Name] = [string]$p.Value.pluralRule }
            }
            if ($raw.aliases) {
                foreach ($p in $raw.aliases.PSObject.Properties) { $read.Aliases[$p.Name.ToLowerInvariant()] = [string]$p.Value }
            }
            if ($read.Default -and $read.Supported.Count -gt 0) { $manifest = $read }
        } catch {
            Write-Verbose "Get-SystemDiagnostic: the locale manifest is unreadable, so this run renders en-US: $($_.Exception.Message)"
        }
    }
    $script:DiagnosticLocaleManifest = $manifest
    return $manifest
}

function ConvertTo-DiagnosticLocaleTag {
    <#
    .SYNOPSIS
        A tag in the one spelling every comparison uses, or '' when it is not a tag.
    .DESCRIPTION
        The rule of ConvertTo-CanonicalLocaleTag in Test.Locale.psm1: underscores
        become hyphens, the language subtag lowercases, a two-letter region
        uppercases, a four-letter script is title-cased, and anything outside
        letters, digits and hyphens within the length bound is refused.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tag, [int]$MaxLength = 35)
    $t = "$Tag".Trim().Replace('_', '-')
    if (-not $t) { return '' }
    if ($t.Length -gt $MaxLength) { return '' }
    if ($t -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { return '' }
    $parts = $t.Split('-')
    $out = $parts[0].ToLowerInvariant()
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $p = $parts[$i]
        if ($p.Length -eq 2) { $out += '-' + $p.ToUpperInvariant() }
        elseif ($p.Length -eq 4) { $out += '-' + $p.Substring(0, 1).ToUpperInvariant() + $p.Substring(1).ToLowerInvariant() }
        else { $out += '-' + $p.ToLowerInvariant() }
    }
    return $out
}

function Resolve-DiagnosticSupportedLocale {
    <#
    .SYNOPSIS
        The supported tag one requested tag selects, or '' for none.
    .DESCRIPTION
        The rule of Resolve-SupportedLocale in Test.Locale.psm1: an exact match,
        then an alias the manifest declares, and no prefix fallback.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tag, [Parameter(Mandatory)][hashtable]$Manifest)
    $canonical = ConvertTo-DiagnosticLocaleTag -Tag $Tag -MaxLength $Manifest.MaxTagLength
    if (-not $canonical) { return '' }
    foreach ($s in $Manifest.Supported) {
        if ([string]::Equals($s, $canonical, [StringComparison]::OrdinalIgnoreCase)) { return $s }
    }
    $alias = $Manifest.Aliases[$canonical.ToLowerInvariant()]
    if ($alias) {
        foreach ($s in $Manifest.Supported) {
            if ([string]::Equals($s, $alias, [StringComparison]::OrdinalIgnoreCase)) { return $s }
        }
    }
    return ''
}

function Get-DiagnosticOperatorLocale {
    <#
    .SYNOPSIS
        The locale this run renders in, resolved once.
    .DESCRIPTION
        The command-line part of New-LocaleContext in Test.Locale.psm1, as
        Get-YurunaOperatorLocale applies it: the checkout's `language:` lock when
        it is not auto, otherwise the process UI culture, otherwise the default.
        A lock that names an unsupported locale resolves to the default; it does
        not fall through to the process culture.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($script:DiagnosticOperatorLocale) { return $script:DiagnosticOperatorLocale }
    $manifest = Get-DiagnosticLocaleManifest
    $language = 'auto'
    $configuration = if ($script:DiagnosticTextRoot) { Join-Path $script:DiagnosticTextRoot 'test/test.config.yml' } else { '' }
    if ($configuration -and [IO.File]::Exists($configuration)) {
        try {
            $match = [regex]::Match([IO.File]::ReadAllText($configuration), '(?m)^language:\s*["'']?([A-Za-z0-9-]+)["'']?\s*(?:#.*)?$')
            if ($match.Success) { $language = $match.Groups[1].Value }
        } catch {
            Write-Verbose "Get-SystemDiagnostic: test.config.yml is unreadable, so its language lock is ignored: $($_.Exception.Message)"
        }
    }
    $locked = $language.Trim() -and -not [string]::Equals($language.Trim(), 'auto', [StringComparison]::OrdinalIgnoreCase)
    $requested = if ($locked) { $language } else { [Globalization.CultureInfo]::CurrentUICulture.Name }
    $resolved = Resolve-DiagnosticSupportedLocale -Tag $requested -Manifest $manifest
    if (-not $resolved) { $resolved = $manifest.Default }
    $direction = $manifest.Direction[$resolved]
    if (-not $direction) { $direction = 'ltr' }
    $script:DiagnosticOperatorLocale = @{ ResolvedTag = $resolved; Direction = $direction }
    return $script:DiagnosticOperatorLocale
}

function Get-DiagnosticMessageTable {
    <#
    .SYNOPSIS
        The checkout's compiled catalog for one locale and domain, or an empty table.
    .DESCRIPTION
        Read with Import-PowerShellDataFile, as Get-CatalogDomain in
        Test.Catalog.psm1 reads it, so the file is data and cannot run. Loaded
        once per run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][string]$Domain)
    $cacheKey = "$Locale|$Domain"
    if ($script:DiagnosticMessageTables.ContainsKey($cacheKey)) { return $script:DiagnosticMessageTables[$cacheKey] }
    $table = @{}
    # Both values become part of a file name, so only their documented shapes pass.
    if ($script:DiagnosticTextRoot -and $Locale -match '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$' -and $Domain -match '^[a-z][a-z0-9]*$') {
        $path = Join-Path $script:DiagnosticTextRoot "globalization/generated/powershell/$Locale.$Domain.psd1"
        if ([IO.File]::Exists($path)) {
            try { $table = Import-PowerShellDataFile -LiteralPath $path -SkipLimitCheck }
            catch { Write-Verbose "Get-SystemDiagnostic: the $Locale.$Domain catalog is unreadable: $($_.Exception.Message)" }
        }
    }
    $script:DiagnosticMessageTables[$cacheKey] = $table
    return $table
}

function Get-DiagnosticEmbeddedMessage {
    <#
    .SYNOPSIS
        The en-US entry of every message this script prints, for a run with no catalog.
    .DESCRIPTION
        The compiled en-US catalog entries of exactly the keys this script passes
        to Format-YurunaOperatorMessage, as gzip-compressed JSON in base64. The
        copy is data rather than source text on purpose: the domain inventory and
        the catalog triage count string literals that read like prose, and a
        verbatim copy of messages the catalog already ships would count as
        hundreds of new untranslated literals. Regenerate it with
        tools/Update-SystemDiagnosticText.ps1 instead of editing it here.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($null -ne $script:DiagnosticEmbeddedMessages) { return $script:DiagnosticEmbeddedMessages }
    $encoded = @(
        # >>> embedded en-US messages -- generated by tools/Update-SystemDiagnosticText.ps1
        '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'
        '7fRevfjv/w1Qjc59wvsAAA=='
        # <<< embedded en-US messages
    ) -join ''
    $table = @{}
    try {
        $buffer = [IO.MemoryStream]::new([Convert]::FromBase64String($encoded))
        $zip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionMode]::Decompress)
        $reader = [IO.StreamReader]::new($zip, [Text.UTF8Encoding]::new($false))
        try { $table = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
        finally { $reader.Dispose() }
    } catch {
        Write-Verbose "Get-SystemDiagnostic: the embedded messages do not decode: $($_.Exception.Message)"
    }
    if ($null -eq $table) { $table = @{} }
    $script:DiagnosticEmbeddedMessages = $table
    return $table
}

function Get-DiagnosticPluralCategory {
    <#
    .SYNOPSIS
        The plural category a count takes in a locale.
    .DESCRIPTION
        The rules of Get-PluralCategory in Test.Catalog.psm1. That function
        refuses a locale whose rule it does not know; this one answers 'other',
        because a diagnostic that stopped over grammar would report nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][double]$Count)
    switch ((Get-DiagnosticLocaleManifest).PluralRule[$Locale]) {
        'one-if-1' { if ($Count -eq 1) { return 'one' } return 'other' }
        'pt-cardinal-cldr46' {
            $absolute = [Math]::Abs($Count)
            if ([Math]::Floor($absolute) -le 1) { return 'one' }
            if ($absolute -gt 0 -and $absolute % 1000000 -eq 0) { return 'many' }
            return 'other'
        }
        'zh-cardinal-cldr46' { return 'other' }
        'he-cardinal-cldr46' {
            $absolute = [Math]::Abs($Count)
            $integer = [Math]::Floor($absolute)
            $hasFraction = $absolute -ne $integer
            if (($integer -eq 1 -and -not $hasFraction) -or ($integer -eq 0 -and $hasFraction)) { return 'one' }
            if ($integer -eq 2 -and -not $hasFraction) { return 'two' }
            return 'other'
        }
        default { return 'other' }
    }
}

function Format-DiagnosticNumber {
    <#
    .SYNOPSIS
        A number written with the separators the locale manifest gives a locale.
    .DESCRIPTION
        The rule of Format-CatalogNumber in Test.Catalog.psm1: invariant digits,
        then the manifest's group and decimal separators, so this script writes
        a number the way every other Yuruna surface writes it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Locale, [int]$Decimals = 0)
    $manifest = Get-DiagnosticLocaleManifest
    $format = $manifest.NumberFormat[$Locale]
    if (-not $format) { $format = $manifest.NumberFormat[$manifest.Default] }
    if (-not $format) { $format = @{ Group = ','; Decimal = '.'; GroupSize = 3 } }
    $number = [double]$Value
    $negative = $number -lt 0
    $text = [Math]::Abs($number).ToString("F$Decimals", [Globalization.CultureInfo]::InvariantCulture)
    $parts = $text -split '\.'
    $whole = $parts[0]
    $size = if ($format.GroupSize -gt 0) { [int]$format.GroupSize } else { 3 }
    if ($format.Group -and $whole.Length -gt $size) {
        $grouped = ''
        $seen = 0
        for ($i = $whole.Length - 1; $i -ge 0; $i--) {
            $grouped = $whole[$i] + $grouped
            $seen++
            if (($seen % $size) -eq 0 -and $i -gt 0) { $grouped = $format.Group + $grouped }
        }
        $whole = $grouped
    }
    $out = if ($parts.Count -gt 1) { $whole + $format.Decimal + $parts[1] } else { $whole }
    if ($negative) { return "-$out" }
    return $out
}

function Format-DiagnosticArgument {
    <#
    .SYNOPSIS
        One typed message argument, rendered for a reader.
    .DESCRIPTION
        The rule of Format-CatalogArgument in Test.Catalog.psm1, including the
        bidi isolation every argument gets in a right-to-left locale.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Value, [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Locale)
    if ($null -eq $Value) { return '' }
    $text = switch ($Type) {
        'integer'  { Format-DiagnosticNumber -Value $Value -Locale $Locale -Decimals 0 }
        'decimal'  { Format-DiagnosticNumber -Value $Value -Locale $Locale -Decimals 2 }
        'duration' {
            $span = [TimeSpan]::FromSeconds([double]$Value)
            if ($span.TotalHours -ge 1) { '{0}h {1}m' -f [Math]::Floor($span.TotalHours), $span.Minutes }
            elseif ($span.TotalMinutes -ge 1) { '{0}m {1}s' -f [Math]::Floor($span.TotalMinutes), $span.Seconds }
            else { '{0}s' -f [Math]::Floor($span.TotalSeconds) }
        }
        'datetime' {
            ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + ' UTC'
        }
        default { [string]$Value }
    }
    $text = [string]$text
    $direction = (Get-DiagnosticLocaleManifest).Direction[$Locale]
    if ($direction -ne 'rtl' -or $text -eq '' -or $text -match '(?s)^[\u2066-\u2068].*\u2069$') { return $text }
    $open = if ($Type -in @('integer', 'decimal', 'duration', 'datetime')) { [char]0x2066 } else { [char]0x2068 }
    return "$open$text$([char]0x2069)"
}

function Format-DiagnosticSegment {
    <#
    .SYNOPSIS
        Walk one compiled message form: literal text, argument, literal text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Segments, [Parameter(Mandatory)][hashtable]$Arguments, [Parameter(Mandatory)][string]$Locale)
    if ($Segments -is [string]) { return $Segments }
    $sb = [Text.StringBuilder]::new()
    foreach ($piece in @($Segments)) {
        if ($piece -is [string]) { [void]$sb.Append($piece); continue }
        if ($piece -is [System.Collections.IDictionary] -and $piece.Contains('arg')) {
            $name = [string]$piece['arg']
            $value = if ($Arguments.ContainsKey($name)) { $Arguments[$name] } else { $null }
            [void]$sb.Append((Format-DiagnosticArgument -Value $value -Type ([string]$piece['type']) -Locale $Locale))
            continue
        }
        [void]$sb.Append([string]$piece)
    }
    return $sb.ToString()
}

function Format-YurunaOperatorMessage {
    <#
    .SYNOPSIS
        Render a stable message key with explicitly named argument values.
    .DESCRIPTION
        The contract of Format-YurunaOperatorMessage in Yuruna.Globalization.psm1,
        which this script cannot import. The entry comes from the checkout's
        compiled catalog for the run's locale, then for the default locale, then
        from the embedded en-US copy; with none of them the key itself is
        returned, so the line still says something identifiable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Arguments = @{},
        [AllowNull()][AllowEmptyCollection()][object[]]$FormatValues,
        [hashtable]$FormatBindings = @{})
    $context = Get-DiagnosticOperatorLocale
    $values = @{}
    if ($Arguments) { foreach ($name in $Arguments.Keys) { $values[$name] = $Arguments[$name] } }
    if ($FormatBindings.Count -gt 0) {
        # Composite formats can align or format one value in more than one way.
        # Evaluate them once, as the shared formatter does, and hand the
        # renderer named display arguments.
        $formatLocale = if ($context.ResolvedTag -like 'qps-*') { 'en-US' } else { $context.ResolvedTag }
        $culture = try { [Globalization.CultureInfo]::GetCultureInfo($formatLocale) } catch { [Globalization.CultureInfo]::InvariantCulture }
        foreach ($name in $FormatBindings.Keys) {
            $values[$name] = [string]::Format($culture, ('{' + [string]$FormatBindings[$name] + '}'), [object[]]$FormatValues)
        }
    }
    $domain = ($Key -split '\.')[0]
    $renderLocale = [string]$context.ResolvedTag
    $entry = (Get-DiagnosticMessageTable -Locale $renderLocale -Domain $domain)[$Key]
    $default = [string](Get-DiagnosticLocaleManifest).Default
    if ($null -eq $entry -and -not [string]::Equals($renderLocale, $default, [StringComparison]::Ordinal)) {
        $entry = (Get-DiagnosticMessageTable -Locale $default -Domain $domain)[$Key]
        if ($null -ne $entry) { $renderLocale = $default }
    }
    if ($null -eq $entry) {
        $entry = (Get-DiagnosticEmbeddedMessage)[$Key]
        if ($null -ne $entry) { $renderLocale = 'en-US' }
    }
    if ($null -eq $entry) { return $Key }
    if ($entry -is [string]) { return $entry }
    if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('kind')) {
        $selector = [string]$entry['selector']
        $chosen = $null
        if ($entry['kind'] -eq 'plural') {
            $count = 0.0
            if ($values.ContainsKey($selector)) { $count = [double]$values[$selector] }
            $chosen = $entry['variants'][(Get-DiagnosticPluralCategory -Locale $renderLocale -Count $count)]
            if ($null -eq $chosen) { $chosen = $entry['variants']['other'] }
        } else {
            $selected = if ($values.ContainsKey($selector)) { [string]$values[$selector] } else { '' }
            $chosen = $entry['variants'][$selected]
            if ($null -eq $chosen) { $chosen = $entry['variants']['other'] }
        }
        if ($null -eq $chosen) { return $Key }
        return (Format-DiagnosticSegment -Segments $chosen -Arguments $values -Locale $renderLocale)
    }
    return (Format-DiagnosticSegment -Segments $entry -Arguments $values -Locale $renderLocale)
}

Write-Debug "Get-SystemDiagnostic: skipDocker=$SkipDocker skipKube=$SkipKube skipProjectGaps=$SkipProjectGaps logLevel=$logLevel"
Set-YurunaLogLevel -LogLevel $logLevel

$script:Problems = [System.Collections.Generic.List[string]]::new()
# Parallel structured store: one @{ class; message } per Add-Problem call, in the
# same order as $script:Problems. The prose SUMMARY reads $script:Problems; the
# machine-readable sidecar (Write-ProblemJson) reads these so a consumer can select
# problems by class without regex-parsing prose lines.
$script:ProblemRecords = [System.Collections.Generic.List[hashtable]]::new()

function Write-Section {
    param([string]$Title)
    Write-Output ""
    Write-Output "========"
    Write-Output "  $Title"
    Write-Output "========"
}
function Write-Sub {
    param([string]$Title)
    Write-Output ""
    Write-Output "--- $Title ---"
}
function Add-Problem {
    param(
        [Parameter(Mandatory)][string]$Message,
        # Machine-readable classifier for the JSON sidecar. It is mandatory:
        # a class recovered from the capitalization or wording of Message
        # would make translated prose a protocol again.
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Class
    )
    $script:Problems.Add($Message) | Out-Null
    $script:ProblemRecords.Add(@{ class = $Class; message = $Message }) | Out-Null
}

# Sentinels bracket the machine-readable problem list inside the otherwise-prose
# stdout so a consumer parsing the captured .txt can slice out exactly the JSON
# body. Kept as constants because both the emitter and any downstream parser
# must agree on the exact literals.
$script:ProblemJsonBeginMarker = '===YURUNA-DIAG-JSON-BEGIN==='
$script:ProblemJsonEndMarker   = '===YURUNA-DIAG-JSON-END==='

# Build the machine-readable problem document (schema v1): an object with the
# total count, the per-class tallies, and the ordered records mirroring the
# prose SUMMARY. -Compress keeps it to a single line so a line-oriented reader
# can grab the one line between the sentinels; -Depth covers the nested arrays.
<#
.SYNOPSIS
    Readings from a Prometheus text exposition, by metric name.
.DESCRIPTION
    The caching proxy publishes the same measurements twice: this document and a
    human page beside it. Classification reads this one. The page is written for
    a person opening it during an incident, so its wording is free to change and
    to be translated; a check that recognized a sentence there would go quiet on
    the day someone improved it, and go quiet by reporting nothing wrong.
.OUTPUTS
    [hashtable] metric name -> array of @{ Labels = @{}; Value = [double] }.
#>
function Get-PrometheusReading {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $readings = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        # HELP and TYPE lines describe the series; they carry no reading.
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $match = [regex]::Match($trimmed, '^(?<name>[A-Za-z_:][A-Za-z0-9_:]*)(?:\{(?<labels>[^}]*)\})?\s+(?<value>[^\s]+)$')
        if (-not $match.Success) { continue }
        $value = 0.0
        if (-not [double]::TryParse($match.Groups['value'].Value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            continue
        }
        $labels = @{}
        foreach ($pair in [regex]::Matches($match.Groups['labels'].Value, '(?<k>[A-Za-z_][A-Za-z0-9_]*)="(?<v>[^"]*)"')) {
            $labels[$pair.Groups['k'].Value] = $pair.Groups['v'].Value
        }
        $name = $match.Groups['name'].Value
        if (-not $readings.ContainsKey($name)) { $readings[$name] = @() }
        $readings[$name] += @{ Labels = $labels; Value = $value }
    }
    return $readings
}

<#
.SYNOPSIS
    The single value of a metric, or $null when it was not published.
.DESCRIPTION
    $null is a distinct answer from zero. A cache that could not read the
    upstream budget publishes no budget reading, and treating that as "0 left"
    would report an exhausted budget on every cache that never asked.
.OUTPUTS
    [Nullable[double]]
#>
function Get-PrometheusValue {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][hashtable]$Reading, [Parameter(Mandatory)][string]$Name)
    if (-not $Reading.ContainsKey($Name)) { return $null }
    $rows = @($Reading[$Name])
    # More than one series means the metric is labeled and the caller has to
    # say which row it wants, rather than be handed an arbitrary one.
    if ($rows.Count -ne 1) { return $null }
    # Already a double from the reader; returned uncast so the declared object
    # type stays honest about the $null this can also answer.
    return $rows[0].Value
}

<#
.SYNOPSIS
    The image sets the cache holds incompletely, from its published readings.
.DESCRIPTION
    Residency is the only reading that can show a COLD cache. The manifest
    timings walk a tag the cache keeps resident, so they stay fast while an
    image a guest is about to pull is still being copied from upstream -- the
    state in which a provisioning run spends its whole step budget and then
    reports a bare timeout.

    Nothing is reported until a warm run has recorded residency. The exporter
    publishes that as its own gauge and says why: with it at 0 the counts are
    ABSENT, not zero, and reading them anyway reports a cache that has simply
    not warmed yet as one missing every image a guest needs.

    A missing image the cache REFUSED (answered with an HTTP error) is counted
    apart from one it still has to copy. A refusal is not a slow copy: every
    guest asking for that image gets the same answer, so describing it as a
    wait would send the reader after latency. The count comes from the per-image
    warm rows (state "failed"), which every exporter publishes; which statuses
    were answered comes from a series only a newer exporter adds, so Statuses
    can be empty while Refused is not.
.OUTPUTS
    [object[]] one @{ Set; Held; Total; Refused; Statuses; Copying } per set
    held short. Copying is the missing count less the refused one.
#>
function Get-ZotSelfTestProblem {
    <#
    .SYNOPSIS
        The problems the cache's zot sync self-test reports, as class, message
        key and message arguments.
    .DESCRIPTION
        The cache syncs one probe image per upstream through its own zot release
        and publishes the verdict. An incompatible release refuses images its
        upstream serves, so every guest pulling from that registry gets the same
        refusal and no wait or re-run changes it. A repaired configuration
        works, but only because the self-test added an http.compat mode the
        shipped configuration lacks, and every rebuild repeats that repair. A
        cache built before the self-test publishes none of this and raises
        nothing here.
    .OUTPUTS
        [object[]] one @{ Class; Key; Message } per problem.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable]$Reading, [Parameter(Mandatory)][string]$HealthUrl)

    $problems = @()
    if ((Get-PrometheusValue -Reading $Reading -Name 'yuruna_zot_selftest_available') -ne 1) { return , $problems }
    $verdictRow = @($Reading['yuruna_zot_selftest_verdict'] | Where-Object { $_ -and $_.Labels.ContainsKey('verdict') }) |
        Select-Object -First 1
    $verdict = if ($verdictRow) { $verdictRow.Labels['verdict'] } else { '' }
    $releaseRow = @($Reading['yuruna_zot_selftest_release_info'] | Where-Object { $_ }) | Select-Object -First 1
    $version = if ($releaseRow -and $releaseRow.Labels['version']) { $releaseRow.Labels['version'] } else { 'unrecorded' }
    if ($verdict -eq 'incompatible') {
        $refused = @($Reading['yuruna_zot_selftest_probe_failed'] | Where-Object { $_ -and $_.Labels['outcome'] -eq 'rejected' })
        $first = $refused | Select-Object -First 1
        $modes = @($refused | ForEach-Object { $_.Labels['compat'] } | Where-Object { $_ } | Sort-Object -Unique)
        $arguments = @{ version = $version; refused = "$($refused.Count)"
            image = $(if ($first) { $first.Labels['image'] } else { 'a probe image' })
            status = $(if ($first) { $first.Labels['status'] } else { 'error' })
            healthUrl = $HealthUrl }
        if ($modes.Count) {
            $arguments['modes'] = $modes -join ', '
            $problems += @{ Class = 'REGISTRY.zot-incompatible'; Key = 'automation.system_diagnostic_registry_zot_incompatible'
                Message = (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_registry_zot_incompatible' -Arguments $arguments) }
        } else {
            $problems += @{ Class = 'REGISTRY.zot-incompatible'; Key = 'automation.system_diagnostic_registry_zot_incompatible_unexplained'
                Message = (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_registry_zot_incompatible_unexplained' -Arguments $arguments) }
        }
    } elseif ($verdict -eq 'healed') {
        $modes = @($Reading['yuruna_zot_selftest_compat_added'] | Where-Object { $_ } | ForEach-Object { $_.Labels['mode'] } | Where-Object { $_ })
        $problems += @{ Class = 'REGISTRY.zot-compat-repaired'; Key = 'automation.system_diagnostic_registry_zot_compat_repaired'
            Message = (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_registry_zot_compat_repaired' -Arguments @{
                    version = $version; modes = ($modes -join ', '); healthUrl = $HealthUrl }) }
    }
    return , $problems
}

function Get-RegistryResidencyShortfall {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable]$Reading)

    $shortfall = @()
    if ((Get-PrometheusValue -Reading $Reading -Name 'yuruna_prewarm_state_available') -ne 1) {
        return $shortfall
    }
    $totalBySet = @{}
    foreach ($row in @($Reading['yuruna_prewarm_images_total'])) {
        if ($row.Labels.ContainsKey('set')) { $totalBySet[$row.Labels['set']] = [int]$row.Value }
    }
    $refusedBySet = @{}
    foreach ($row in @($Reading['yuruna_prewarm_manifest_seconds'] | Where-Object { $_ })) {
        if (-not $row.Labels.ContainsKey('set') -or $row.Labels['state'] -cne 'failed') { continue }
        $refusedBySet[$row.Labels['set']] = [int]$refusedBySet[$row.Labels['set']] + 1
    }
    # One series per set and HTTP status the cache answered with.
    $statusesBySet = @{}
    foreach ($row in @($Reading['yuruna_prewarm_images_refused'] | Where-Object { $_ })) {
        if (-not $row.Labels.ContainsKey('set') -or -not $row.Labels['status']) { continue }
        $statusesBySet[$row.Labels['set']] = @($statusesBySet[$row.Labels['set']]) + $row.Labels['status']
    }
    foreach ($row in @($Reading['yuruna_prewarm_images_resident'])) {
        if (-not $row.Labels.ContainsKey('set')) { continue }
        $set = $row.Labels['set']
        if (-not $totalBySet.ContainsKey($set)) { continue }
        $held = [int]$row.Value
        $total = $totalBySet[$set]
        if ($total -gt 0 -and $held -lt $total) {
            # Clamped to the shortfall: the two counts come from separate
            # series, and a refused count larger than what is missing cannot
            # turn the copies still owed into a negative number.
            $refused = [Math]::Min([int]$refusedBySet[$set], $total - $held)
            $statuses = (@($statusesBySet[$set]) | Where-Object { $_ } | Sort-Object -Unique) -join ', '
            $shortfall += @{ Set = $set; Held = $held; Total = $total; Refused = $refused; Statuses = $statuses
                Copying = $total - $held - $refused }
        }
    }
    # Comma-wrapped: a one-element array returned bare unrolls to the hashtable
    # itself, and a caller asking for .Count would then be told how many keys a
    # single shortfall has rather than that there is one.
    return , $shortfall
}

function Get-ProblemJson {
    [OutputType([string])]
    param()
    $byClass = [ordered]@{}
    foreach ($rec in $script:ProblemRecords) {
        $c = [string]$rec.class
        if ($byClass.Contains($c)) { $byClass[$c] = [int]$byClass[$c] + 1 } else { $byClass[$c] = 1 }
    }
    $doc = [ordered]@{
        schema   = 'yuruna.diagnostic.problems/v1'
        count    = $script:Problems.Count
        byClass  = $byClass
        problems = @($script:ProblemRecords | ForEach-Object {
            [ordered]@{ class = [string]$_.class; message = [string]$_.message }
        })
    }
    return ($doc | ConvertTo-Json -Depth 5 -Compress)
}

# Emit the JSON sidecar. Always writes the sentinel-bracketed block to stdout
# (the path an SSH/console capture takes into the .txt artifact). When -OutFile
# was supplied, ALSO drop a sibling <OutFile>.json so a local run has a file a
# consumer can read without slicing sentinels. Never touches the prose SUMMARY
# or the exit code.
function Write-ProblemJson {
    param([string]$SidecarBasePath)
    $json = Get-ProblemJson
    Write-Output $script:ProblemJsonBeginMarker
    Write-Output $json
    Write-Output $script:ProblemJsonEndMarker
    if (-not [string]::IsNullOrWhiteSpace($SidecarBasePath)) {
        $sidecar = "$SidecarBasePath.json"
        try {
            # BOM-less UTF-8 so a byte-exact JSON parser on any platform reads it
            # cleanly (a BOM trips strict JSON.parse in some runtimes).
            [System.IO.File]::WriteAllText($sidecar, $json, [System.Text.UTF8Encoding]::new($false))
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b02f124a17d21759' -FormatValues ($sidecar) -FormatBindings @{ sidecar = '0' })
        } catch {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_407a4077484dc534' -FormatValues ($sidecar, $_.Exception.Message) -FormatBindings @{ sidecar = '0'; message = '1' })
        }
    }
}

function Invoke-DiagnosticSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    Write-Section $Title
    try {
        & $Body
    } catch {
        Write-Output ""
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_300c080adc474c41' -FormatValues ($Title, $_.Exception.Message) -FormatBindings @{ title = '0'; message = '1' })
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $firstPosLine = ($_.InvocationInfo.PositionMessage -split "`r?`n" | Select-Object -First 1)
            if ($firstPosLine) { Write-Output ("   {0}" -f $firstPosLine.Trim()) }
        }
        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_b89ad48331af1923' -FormatValues ($Title, $_.Exception.Message) -FormatBindings @{ title = '0'; message = '1' }) -Class 'DIAG.section-aborted'
    }
}

# --- REGION: https://yuruna.link/423ef7f5-0003
function Invoke-WithDeadline {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 5,
        [object[]]$ArgumentList = @(),
        # Pure-PowerShell work (e.g. the recursive file-tree walks) can run in a far
        # cheaper in-process thread job instead of a new pwsh process per call.
        # Native-tool probes must NOT set this: an out-of-process Start-Job is
        # force-killable when a wedged daemon call hangs, whereas a native call
        # blocked inside an in-process runspace may not abort on Stop-Job. Falls
        # back to Start-Job when Start-ThreadJob (the ThreadJob module) is absent.
        [switch]$InProcess
    )
    $useThread = $InProcess -and [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
    $job = if ($useThread) {
        Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    } else {
        Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if ($null -eq $completed) {
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { $null = $_ }
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        return @{ TimedOut = $true; Output = $null }
    }
    $out = $null
    try {
        $out = Receive-Job -Job $job -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    } finally {
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
    # The native exit code is recovered by Invoke-Tool from the tail of Output
    # (its scriptblock appends $LASTEXITCODE), not from this result -- so there is
    # deliberately no ExitCode key here to imply a signal this never populated.
    # --- REGION: https://yuruna.link/423ef7f5-0003
    return @{ TimedOut = $false; Output = $out }
}

# Recursive project-tree walks can wedge for minutes on a huge or network-mounted
# checkout, so each runs behind Invoke-WithDeadline and degrades to a partial result.
# The caller, not this function, emits the timeout marker: a Write-Output from here
# would be captured into the caller's @(...) array.
# See https://yuruna.link/4213a0b3-0195
function Get-FileTreeWithDeadline {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$Label,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 30
    )
    $result = Invoke-WithDeadline -TimeoutSeconds $TimeoutSeconds -ArgumentList $ArgumentList -ScriptBlock $ScriptBlock -InProcess
    if ($result.TimedOut) {
        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_3a6d1507411d1aa5' -FormatValues ($Label, $TimeoutSeconds) -FormatBindings @{ label = '0'; timeoutSeconds = '1' }) -Class 'DIAG.walk-timeout'
        return @{ TimedOut = $true; TimeoutSeconds = $TimeoutSeconds; Label = $Label; Items = @() }
    }
    return @{ TimedOut = $false; TimeoutSeconds = $TimeoutSeconds; Label = $Label; Items = @($result.Output) }
}

function Protect-DiagnosticSecretText {
    <#
    .SYNOPSIS
        Redact secrets from collected text, one line at a time.
    .DESCRIPTION
        Embedded here because this script runs alone on a guest; the name rule
        for secret-bearing environment variables matches Get-YurunaSecretValue
        in automation/Yuruna.Retry.psm1. A line that assigns a secret-named key
        is replaced whole, environment secret values are replaced wherever they
        appear (tool logs written before redaction existed carry them), and
        GitHub token shapes are replaced last.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Line)
    $namePattern = '(?i)pass(word|wd|phrase)|secret|token|credential|api[_-]?key|private[_-]?key|access[_-]?key'
    $secretValues = @(foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $value = [string]$entry.Value
        if ([string]$entry.Key -match $namePattern -and $value.Length -ge 4 -and $value -notin @('true', 'false', 'null', 'none', 'yes', 'no')) { $value }
    }) | Select-Object -Unique | Sort-Object -Property Length -Descending
    foreach ($text in @($Line)) {
        if ($text -match '(?i)\b[A-Za-z0-9_]*(?:TOKEN|PASSWORD|SECRET|PRIVATE_KEY|CREDENTIAL)[A-Za-z0-9_]*\s*[:=]') { '[REDACTED SECRET ASSIGNMENT]'; continue }
        $safeLine = [string]$text
        foreach ($secretValue in $secretValues) { $safeLine = $safeLine.Replace($secretValue, '[REDACTED]') }
        [regex]::Replace($safeLine, '\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]+)', '[REDACTED]')
    }
}

function Get-DiagnosticFileTail {
    <#
    .SYNOPSIS
        Read a fixed byte range even when a live phase log keeps growing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 65536)][int]$MaximumBytes = 65536
    )
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite,Delete')
    try {
        $length = $stream.Length
        $count = [int][Math]::Min([long]$MaximumBytes, $length)
        $null = $stream.Seek($length - $count, [IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new($count)
        $read = 0
        while ($read -lt $count) {
            $received = $stream.Read($bytes, $read, $count - $read)
            if ($received -eq 0) { break }
            $read += $received
        }
        # Decode only the bounded snapshot. The reader keeps BOM detection for
        # small logs written by older PowerShell versions.
        $snapshot = [IO.MemoryStream]::new($bytes, 0, $read)
        $reader = [IO.StreamReader]::new($snapshot, [Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

# Emit the degradation marker (if any) at statement level so it lands in
# stdout/transcript next to the section that triggered it. Pure side effect:
# call this WITHOUT assigning its result, then read the walk's .Items
# separately, so the marker is never captured into a caller's @(...) array.
function Show-FileTreeWalkTimeout {
    param([Parameter(Mandatory)][hashtable]$Walk)
    if ($Walk.TimedOut) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_01cea68c33aef2ca' -FormatValues ($Walk.Label, $Walk.TimeoutSeconds) -FormatBindings @{ label = '0'; timeoutSeconds = '1' })
    }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$ToolArgs = @(),
        [string]$ProblemTag = $null,
        [int]$TimeoutSeconds = 0,
        [switch]$Privileged,
        [hashtable]$Snapshot
    )
    if ($null -ne $Snapshot) { $Snapshot.Success = $false; $Snapshot.Lines = @() }
    if ($Privileged -and $script:LinuxPriv -and $script:LinuxPriv.Count -gt 0) {
        $ToolArgs = @($script:LinuxPriv | Select-Object -Skip 1) + @($Tool) + $ToolArgs
        $Tool = $script:LinuxPriv[0]
    }
    # Runnable-target proof at the call site, mirroring Test-CommandAvailable's
    # section guards: a target that is missing, a dangling symlink, or lost its
    # execute bit would otherwise throw "Cannot run a document in the middle of
    # a pipeline" here and abort the section mid-dump.
    $resolved = @(Get-Command $Tool -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $resolved -or
        (($resolved.CommandType -eq 'Application') -and -not (Test-ExecutableFile -Path $resolved.Source))) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_38c78044744306af' -Arguments @{ tool = "$Tool" })
        if ($ProblemTag) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_9bcfa00b94f40a2a' -Arguments @{ problemTag = "$($ProblemTag)"; tool = "$Tool" }) -Class $ProblemTag }
        return
    }
    try {
        if ($TimeoutSeconds -gt 0) {
            # Windows batch shims need PowerShell's interpreter dispatch;
            # ProcessStartInfo with UseShellExecute=false accepts executables.
            $batchShim = $IsWindows -and [IO.Path]::GetExtension($resolved.Source) -in @('.cmd', '.bat')
            if ($resolved.CommandType -eq 'Application' -and -not $batchShim) {
                # Native probes need neither a PowerShell worker nor its full
                # module startup. Keep the same timeout and problem classes,
                # with both streams captured by this file's local runner.
                $native = Invoke-DiagnosticBoundedCommand -FilePath $resolved.Source -ArgumentList $ToolArgs `
                    -TimeoutSeconds $TimeoutSeconds -MaxCapturedChars 16777216
                foreach ($stream in @($native.StdOut, $native.StdErr)) {
                    if (-not [string]::IsNullOrEmpty($stream)) {
                        $text = [string]$stream -replace "`r`n|`r", "`n"
                        if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
                        $text -split "`n" | ForEach-Object { Write-Output $_ }
                    }
                }
                if ($native.TimedOut) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_966e9d1dffe3cee1' -FormatValues ($Tool, $TimeoutSeconds) -FormatBindings @{ tool = '0'; timeoutSeconds = '1' })
                    if ($ProblemTag) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_cd63c049294a2c32' -Arguments @{ problemTag = "$($ProblemTag)"; timeoutSeconds = "${TimeoutSeconds}"; tool = "$Tool"; join = "$($ToolArgs -join ' ')" }) -Class $ProblemTag }
                    return
                }
                if (-not $native.Started) { throw $native.StartError }
                if ($native.DrainTimedOut -or $native.OutputTruncated -or $native.KillFailed) {
                    throw "[DrainTimedOut=$($native.DrainTimedOut); OutputTruncated=$($native.OutputTruncated); KillFailed=$($native.KillFailed)]"
                }
                if ($null -ne $Snapshot -and $native.ExitCode -eq 0) {
                    $Snapshot.Success = $true
                    $text = [string]$native.StdOut -replace "`r`n|`r", "`n"
                    if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
                    $Snapshot.Lines = @(if ($text.Length -gt 0) { $text -split "`n" })
                }
                if ($native.ExitCode -ne 0 -and $ProblemTag) {
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_ba76b3f8b1fdb5b8' -Arguments @{ problemTag = "$($ProblemTag)"; exit = "$($native.ExitCode)"; tool = "$Tool"; join = "$($ToolArgs -join ' ')" }) -Class $ProblemTag
                }
                return
            }
            $result = Invoke-WithDeadline -TimeoutSeconds $TimeoutSeconds -ArgumentList @($Tool, $ToolArgs) -ScriptBlock {
                param($t, $a)
                & $t @a 2>&1 | ForEach-Object { $_.ToString() }
                $LASTEXITCODE
            }
            if ($result.TimedOut) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_966e9d1dffe3cee1' -FormatValues ($Tool, $TimeoutSeconds) -FormatBindings @{ tool = '0'; timeoutSeconds = '1' })
                if ($ProblemTag) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_cd63c049294a2c32' -Arguments @{ problemTag = "$($ProblemTag)"; timeoutSeconds = "${TimeoutSeconds}"; tool = "$Tool"; join = "$($ToolArgs -join ' ')" }) -Class $ProblemTag }
                return
            }
            $lines = @($result.Output)
            $exit = 0
            if ($lines.Count -gt 0) {
                $last = $lines[$lines.Count - 1]
                if ($last -is [int]) {
                    $exit = [int]$last
                    $lines = @(if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] })
                }
            }
            $lines | ForEach-Object { Write-Output ([string]$_) }
            # This compatibility worker merges both streams. Its text remains
            # evidence, but cannot safely become data for health classification.
            if ($exit -ne 0 -and $ProblemTag) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_ba76b3f8b1fdb5b8' -Arguments @{ problemTag = "$($ProblemTag)"; exit = "$exit"; tool = "$Tool"; join = "$($ToolArgs -join ' ')" }) -Class $ProblemTag
            }
            return
        }
        if ($null -ne $Snapshot) {
            $lines = @(& $Tool @ToolArgs 2>&1)
            $exit = $LASTEXITCODE
            $lines | ForEach-Object { Write-Output ($_.ToString()) }
            if ($exit -eq 0 -and @($lines | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count -eq 0) {
                $Snapshot.Success = $true
                $Snapshot.Lines = @($lines | ForEach-Object { $_.ToString() })
            }
        } else {
            & $Tool @ToolArgs 2>&1 | ForEach-Object { Write-Output ($_.ToString()) }
        }
        if ($LASTEXITCODE -ne 0 -and $ProblemTag) {
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_4788a5c9b68d9b0a' -Arguments @{ problemTag = "$($ProblemTag)"; lASTEXITCODE = "$LASTEXITCODE"; tool = "$Tool"; join = "$($ToolArgs -join ' ')" }) -Class $ProblemTag
        }
    } catch {
        if ($ProblemTag) { Add-Problem "$($ProblemTag): $($_.Exception.Message)" -Class $ProblemTag }
        Write-Output "  (error: $($_.Exception.Message))"
    }
}

function Get-DiagnosticDockerInfoProbe {
    <#
    .SYNOPSIS
        Probe the daemon and retain a complete, successful info snapshot.
    .DESCRIPTION
        A native docker executable can supply the liveness verdict and the
        later info fields in one response. Interpreter shims retain their
        original deadline worker; merged streams are never treated as JSON.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Snapshot)
    $Snapshot.Success = $false
    $Snapshot.Info = $null
    $resolved = @(Get-Command docker -ErrorAction SilentlyContinue) | Select-Object -First 1
    $batchShim = $IsWindows -and $null -ne $resolved -and [IO.Path]::GetExtension($resolved.Source) -in @('.cmd', '.bat')
    if ($null -eq $resolved -or $resolved.CommandType -ne 'Application' -or $batchShim -or
        -not (Test-ExecutableFile -Path $resolved.Source)) {
        $probe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
            $null = & docker info --format '{{.ServerVersion}}' 2>&1
            $LASTEXITCODE
        }
        $probe.Evidence = @()
        return $probe
    }
    try {
        $native = Invoke-DiagnosticBoundedCommand -FilePath $resolved.Source `
            -ArgumentList @('info', '--format', '{{json .}}') -TimeoutSeconds 5 -MaxCapturedChars 16777216
    } catch {
        return @{ TimedOut = $false; Output = @(-1); Evidence = @($_.Exception.Message) }
    }
    $complete = $native.Started -and -not ($native.TimedOut -or $native.DrainTimedOut -or
        $native.OutputTruncated -or $native.KillFailed)
    $exit = if ($complete) { $native.ExitCode } else { -1 }
    if ($complete -and $exit -eq 0) {
        try {
            $info = $native.StdOut | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
            $required = @('ServerVersion', 'Containers', 'ContainersRunning', 'ContainersPaused',
                'ContainersStopped', 'Images', 'Driver', 'CgroupDriver', 'KernelVersion', 'OperatingSystem', 'Warnings')
            if ($info -is [pscustomobject] -and $info.ServerVersion -is [string] -and
                -not [string]::IsNullOrWhiteSpace($info.ServerVersion) -and
                @($required | Where-Object { $_ -notin $info.PSObject.Properties.Name }).Count -eq 0) {
                $Snapshot.Success = $true
                $Snapshot.Info = $info
            }
        } catch { Write-Verbose $_.Exception.Message }
    }
    $evidence = @()
    if (-not $complete -or $exit -ne 0) {
        foreach ($text in @($native.StdOut, $native.StdErr)) {
            if (-not [string]::IsNullOrEmpty($text)) { $evidence += [string]$text }
        }
        if (-not $native.Started) { $evidence += [string]$native.StartError }
        if ($native.DrainTimedOut -or $native.OutputTruncated -or $native.KillFailed) {
            $evidence += ('[DrainTimedOut={0}; OutputTruncated={1}; KillFailed={2}]' -f $native.DrainTimedOut, $native.OutputTruncated, $native.KillFailed)
        }
    }
    return @{ TimedOut = $native.TimedOut; Output = @($exit); Evidence = $evidence }
}

function Get-DiagnosticDockerContainerSnapshot {
    <#
    .SYNOPSIS
        Read health data from the same Docker table printed in this report.
    .DESCRIPTION
        Docker's tabwriter aligns the status and ports columns across every
        row. Use those header offsets to retain a status containing spaces,
        excluding ports. Unknown or incomplete tables use a fresh quiet query.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Snapshot)
    $result = @{ Success = $false; Rows = @() }
    if (-not $Snapshot.Success) { return $result }
    $lines = @($Snapshot.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { $result.Success = $true; return $result }
    $header = [string]$lines[0]
    if ($header -cnotmatch '^NAMES\s+IMAGE\s+STATUS\s+PORTS\s*$') { return $result }
    $imageStart = $header.IndexOf('IMAGE', [StringComparison]::Ordinal)
    $statusStart = $header.IndexOf('STATUS', [StringComparison]::Ordinal)
    $portsStart = $header.IndexOf('PORTS', [StringComparison]::Ordinal)
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        $line = [string]$line
        if ($line.Length -le $statusStart -or
            -not [char]::IsWhiteSpace($line[$imageStart - 1]) -or
            -not [char]::IsWhiteSpace($line[$statusStart - 1]) -or
            ($line.Length -gt $portsStart -and -not [char]::IsWhiteSpace($line[$portsStart - 1]))) { return $result }
        $name = $line.Substring(0, $imageStart).Trim()
        $image = $line.Substring($imageStart, $statusStart - $imageStart).Trim()
        $status = $line.Substring($statusStart, [Math]::Min($line.Length, $portsStart) - $statusStart).TrimEnd()
        if ($name -notmatch '^\S+$' -or $image -notmatch '^\S+$' -or [string]::IsNullOrWhiteSpace($status)) { return $result }
        $rows.Add("$name|$status")
    }
    $result.Success = $true
    $result.Rows = $rows.ToArray()
    return $result
}

function Get-DiagnosticKubeSnapshot {
    <#
    .SYNOPSIS
        Reuse one successful Kubernetes table snapshot within this report.
    .DESCRIPTION
        Wide tables retain the leading columns the health checks consume.
        Validate their headers before sharing rows. Failed captures and unknown
        formats take the original quiet query path, so a transient failure is
        retried rather than remembered as an empty cluster.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('nodes','pods','ns','deploy')][string]$Resource,
        [hashtable]$Snapshot,
        [switch]$PrimeOnly
    )
    $minimumColumns = switch ($Resource) { 'nodes' { 5 } 'pods' { 6 } 'ns' { 3 } 'deploy' { 6 } }
    $rowPattern = '^\S+(?:\s+\S+){' + ($minimumColumns - 1) + '}(?:\s|$)'
    if ($null -ne $Snapshot -and $Snapshot.Success) {
        $lines = @($Snapshot.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $header = switch ($Resource) {
            'nodes' { '^NAME\s+STATUS\s+ROLES\s+AGE\s+VERSION(?:\s|$)' }
            'pods' { '^NAMESPACE\s+NAME\s+READY\s+STATUS\s+RESTARTS\s+AGE(?:\s|$)' }
            'ns' { '^NAME\s+STATUS\s+AGE(?:\s|$)' }
            'deploy' { '^NAMESPACE\s+NAME\s+READY\s+UP-TO-DATE\s+AVAILABLE\s+AGE(?:\s|$)' }
        }
        $rows = @($lines | Select-Object -Skip 1)
        if (($lines.Count -eq 0 -or $lines[0] -match $header) -and
            @($rows | Where-Object { $_ -notmatch $rowPattern }).Count -eq 0) {
            $script:DiagnosticKubeRows[$Resource] = $rows
        }
    }
    if ($PrimeOnly) { return }
    if ($script:DiagnosticKubeRows.ContainsKey($Resource)) { return $script:DiagnosticKubeRows[$Resource] }
    $arguments = @('get', $Resource)
    if ($Resource -in @('pods', 'deploy')) { $arguments += '-A' }
    $arguments += @('--no-headers', '--request-timeout=5s')
    $rows = @(& kubectl @arguments 2>$null)
    if ($LASTEXITCODE -eq 0 -and @($rows | Where-Object { $_ -notmatch $rowPattern }).Count -eq 0) {
        $script:DiagnosticKubeRows[$Resource] = $rows
    }
    return $rows
}

function Get-DiagnosticHelmSnapshot {
    <#
    .SYNOPSIS
        One valid Helm release list shared by the report's health checks.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($null -ne $script:DiagnosticHelmReleases) { return $script:DiagnosticHelmReleases }
    $json = @(& helm list -A -o json 2>$null)
    $exit = $LASTEXITCODE
    try {
        $releases = ConvertFrom-Json -InputObject ($json -join "`n") -NoEnumerate -ErrorAction Stop
        $invalid = @($releases | Where-Object {
            $null -eq $_ -or $_.name -isnot [string] -or [string]::IsNullOrWhiteSpace($_.name) -or
            $_.namespace -isnot [string] -or [string]::IsNullOrWhiteSpace($_.namespace) -or
            $_.status -isnot [string] -or [string]::IsNullOrWhiteSpace($_.status)
        })
        if ($exit -eq 0 -and $releases -is [array] -and $invalid.Count -eq 0) {
            $script:DiagnosticHelmReleases = @{ Available = $true; Releases = @($releases) }
            return $script:DiagnosticHelmReleases
        }
    } catch { Write-Verbose $_.Exception.Message }
    return @{ Available = $false; Releases = @() }
}

# Probe the localhost:5000 registry's /v2/_catalog once. Returns $null when the
# registry is unreachable, returns non-JSON, or omits/nulls the repositories
# field -- all of which callers report as "no registry" (normal on hosts that
# don't use the localhost flow) -- or the repository list, possibly empty (@())
# when the registry is reachable but nothing has been pushed. The DOCKER section
# and the GAP HEURISTICS cross-check both call this so the URL, timeout, and
# reachable-vs-empty handling live in one place.
function Get-LocalRegistryCatalog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([int]$TimeoutSeconds = 3)
    try {
        $probe = Invoke-WebRequest -Uri 'http://localhost:5000/v2/_catalog' -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Verbose ("local registry probe failed: {0}" -f $_.Exception.Message)
        return $null
    }
    if (-not ($probe -and $probe.Content)) { return $null }
    try {
        $catalog = ConvertFrom-Json -InputObject $probe.Content -ErrorAction Stop
    } catch {
        Write-Verbose ("local registry returned invalid JSON: {0}" -f $_.Exception.Message)
        return $null
    }
    if (-not $catalog -or -not ($catalog.PSObject.Properties.Name -contains 'repositories')) { return $null }
    $reposVal = $catalog.repositories
    if ($null -eq $reposVal) { return $null }   # "repositories": null -> treat as no catalog
    return , @($reposVal)
}

# $true only for an existing file (symlinks followed to their leaf) that the
# current user can execute. The leaf's own .Exists is the dangling-symlink
# test -- existence probes on the link path report the link, not the target
# -- and the Unix mode check catches a real file whose execute bits were
# stripped. Windows has no execute bit, so there existence is the whole test.
function Test-ExecutableFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if ($IsWindows) { return [System.IO.File]::Exists($Path) }
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $leaf = $item.ResolveLinkTarget($true)
        if ($leaf) { $item = $leaf }
        if (-not $item.Exists) { return $false }
        if ($item -isnot [System.IO.FileInfo]) { return $false }
        $execBits = [System.IO.UnixFileMode]::UserExecute -bor
                    [System.IO.UnixFileMode]::GroupExecute -bor
                    [System.IO.UnixFileMode]::OtherExecute
        return (($item.UnixFileMode -band $execBits) -ne 0)
    } catch {
        return $false
    }
}

# Get-Command alone is not proof a tool can run: it happily returns an
# Application entry for a dangling symlink or a mode-stripped file (a stale
# /usr/local/bin shim left behind by an uninstalled app is the classic
# shape), and invoking such a target throws "Cannot run a document in the
# middle of a pipeline" -- which aborts the whole diagnostic section, not
# just the one probe. For Application commands, prove the resolved target
# is a real, executable file before reporting it available. Cmdlets,
# functions, and aliases resolve to code, not files, so they pass as-is.
function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = @(Get-Command $Name -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $cmd) { return $false }
    if ($cmd.CommandType -ne 'Application') { return $true }
    return (Test-ExecutableFile -Path $cmd.Source)
}

function Invoke-DiagnosticBoundedCommand {
    <#
    .SYNOPSIS
        Run one native command under a wall-clock cap, without any module.
    .DESCRIPTION
        The runner for a run that has neither the macOS driver's
        Invoke-UtmctlProbe nor Yuruna.Common's Invoke-BoundedNativeCommand
        loaded -- every run of this script on its own. It returns the fields
        those return, so the caller reads one shape. A command still running at
        the cap is stopped with its process tree, and its streams are then
        drained for a short grace: a stream a surviving grandchild keeps open is
        reported as DrainTimedOut rather than waited on.
    .PARAMETER FilePath
        The executable to run.
    .PARAMETER ArgumentList
        Its arguments, passed one by one with no shell in between.
    .PARAMETER TimeoutSeconds
        The wall-clock cap for the command.
    .PARAMETER MaxCapturedChars
        Characters kept per stream; anything beyond is dropped and reported.
    .OUTPUTS
        [hashtable] Started, ExitCode, StdOut, StdErr, TimedOut, DrainTimedOut,
        OutputTruncated, KillFailed, StartError.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 20,
        [ValidateRange(4096, 67108864)][int]$MaxCapturedChars = 1048576
    )
    $result = @{
        Started = $false; ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false
        DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false; StartError = ''
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Console]::OutputEncoding
    $startInfo.StandardErrorEncoding = [Console]::OutputEncoding
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
    } catch {
        $result.StartError = $_.Exception.Message
        return $result
    }
    $result.Started = $true
    try {
        $process.StandardInput.Close()
        # Retain only the prefix budget while continuing to drain both pipes.
        # ReadToEndAsync would allocate the entire output before truncating it.
        $streams = @(
            @{ Name = 'StdOut'; Reader = $process.StandardOutput; Buffer = [char[]]::new(8192); Text = [Text.StringBuilder]::new(); Eof = $false; Task = $null },
            @{ Name = 'StdErr'; Reader = $process.StandardError; Buffer = [char[]]::new(8192); Text = [Text.StringBuilder]::new(); Eof = $false; Task = $null }
        )
        foreach ($stream in $streams) { $stream.Task = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length) }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $limitMs = [long]$TimeoutSeconds * 1000
        $draining = $false
        while ($true) {
            foreach ($stream in $streams) {
                if ($stream.Eof -or -not $stream.Task.IsCompleted) { continue }
                if (-not $stream.Task.IsCompletedSuccessfully) { $stream.Eof = $true; $result.DrainTimedOut = $true; continue }
                $count = $stream.Task.Result
                if ($count -eq 0) { $stream.Eof = $true; continue }
                $take = [Math]::Min($count, $MaxCapturedChars - $stream.Text.Length)
                if ($take -gt 0) { [void]$stream.Text.Append($stream.Buffer, 0, $take) }
                if ($take -lt $count) { $result.OutputTruncated = $true }
                $stream.Task = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
            }
            $exited = $process.HasExited
            if ($exited -and -not $result.TimedOut) { $result.ExitCode = $process.ExitCode }
            if ($exited -and $streams[0].Eof -and $streams[1].Eof) { break }
            if (-not $draining -and $exited) {
                $draining = $true
                $limitMs = $clock.ElapsedMilliseconds + 2000
            }
            if ($clock.ElapsedMilliseconds -ge $limitMs) {
                if ($draining) { break }
                $result.TimedOut = $true
                try { $process.Kill($true) } catch { Write-Verbose "Invoke-DiagnosticBoundedCommand: kill failed: $($_.Exception.Message)" }
                if (-not $process.WaitForExit(5000)) { $result.KillFailed = $true }
                $draining = $true
                $limitMs = $clock.ElapsedMilliseconds + 2000
                continue
            }
            $pending = [Threading.Tasks.Task[]]@($streams | Where-Object { -not $_.Eof } | ForEach-Object { $_.Task })
            $slice = [int][Math]::Min(20, [Math]::Max(1, $limitMs - $clock.ElapsedMilliseconds))
            if ($pending.Count) { [void][Threading.Tasks.Task]::WaitAny($pending, $slice) }
            else { [Threading.Thread]::Sleep($slice) }
        }
        $result.DrainTimedOut = $result.DrainTimedOut -or -not ($streams[0].Eof -and $streams[1].Eof)
        foreach ($stream in $streams) { $result[$stream.Name] = $stream.Text.ToString() }
    } finally {
        $process.Dispose()
    }
    return $result
}

# utmctl is an Apple Events client with no timeout of its own, and this report
# is most often wanted when UTM has stopped answering -- exactly when an
# unbounded `utmctl list` would hang the diagnostic that was meant to explain
# the hang. The call is bounded through the macOS driver's Invoke-UtmctlProbe
# when the driver is loaded, through Invoke-BoundedNativeCommand when a caller
# already loaded it, and through Invoke-DiagnosticBoundedCommand otherwise. It
# is never run unbounded.
function Get-DiagnosticUtmctlListing {
    <#
    .SYNOPSIS
        The `utmctl list` standard output lines, bounded, plus a note when the
        call did not return a complete answer.
    .PARAMETER TimeoutSeconds
        The wall-clock cap for the call.
    .OUTPUTS
        [string] one element per line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(1, 600)][int]$TimeoutSeconds = 20)
    $utmctl = @(Get-Command -Name utmctl -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $utmctl) { return }
    if (Get-Command -Name Invoke-UtmctlProbe -ErrorAction SilentlyContinue) {
        $result = Invoke-UtmctlProbe -Arguments @('list') -TimeoutSeconds $TimeoutSeconds -UtmctlPath $utmctl.Source -Quiet
    } elseif (Get-Command -Name Invoke-BoundedNativeCommand -ErrorAction SilentlyContinue) {
        $result = Invoke-BoundedNativeCommand -FilePath $utmctl.Source -ArgumentList @('list') -TimeoutSeconds $TimeoutSeconds
    } else {
        $result = Invoke-DiagnosticBoundedCommand -FilePath $utmctl.Source -ArgumentList @('list') -TimeoutSeconds $TimeoutSeconds
    }
    $text = "$($result.StdOut)".TrimEnd("`r", "`n")
    if ($text) { $text -split "`r?`n" }
    # Partial output is printed either way -- it may be all an operator gets --
    # but any result that is not a complete answer says so: a timeout, a
    # stream not read to the end, output cut at the capture cap, a child that
    # could not be stopped, or a call never started.
    $complete = if (Get-Command -Name Test-BoundedNativeResultComplete -ErrorAction SilentlyContinue) {
        Test-BoundedNativeResultComplete -Result $result
    } else {
        ($result -is [System.Collections.IDictionary]) -and [bool]$result['Started'] -and
            @(@('TimedOut', 'DrainTimedOut', 'OutputTruncated', 'KillFailed', 'DeadlineExhausted') | Where-Object { [bool]$result[$_] }).Count -eq 0
    }
    if (-not $complete) {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_utmctl_list_incomplete' -Arguments @{ seconds = "$TimeoutSeconds" }
    }
}

# See ../docs/host-hyperv.md#a-hyper-v-virtual-switch-that-looks-fine-but-is-not-bridging
# for what this fingerprint checks and why it fails open. -- Get-SystemDiagnostic.ps1
function Test-AdapterUp {
    <#
    .SYNOPSIS
        Whether an adapter is operationally up, read from the value rather than
        from the word Windows chose to display.
    .DESCRIPTION
        Get-NetAdapter's Status is translated with the install language, so
        comparing it against 'Up' calls a working uplink down on any host that
        was not installed in English. ifOperStatus is the IF-MIB value
        underneath, and is 1 for up in every language.

        This is deliberately the same predicate the Hyper-V host module applies,
        because the ladder below has to reach the same verdict the driver
        already acted on. A copy is what a script that runs on every host type
        can have -- it cannot import a Windows-only module -- and the suite
        holds the two answers together.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][object]$Adapter)

    if ($null -eq $Adapter) { return $false }
    foreach ($name in @('ifOperStatus', 'InterfaceOperationalStatus')) {
        $property = $Adapter.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value) {
            $value = 0
            if ([int]::TryParse([string]$property.Value, [ref]$value)) { return ($value -eq 1) }
        }
    }
    return ("$($Adapter.Status)" -eq 'Up')
}

function Write-VirtualSwitchFingerprint {
    [CmdletBinding()]
    param()
    if (-not (Test-CommandAvailable 'Get-VMSwitch')) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_886762e8e63ddc51')
        return
    }
    $switches = @()
    try {
        $switches = @(Get-VMSwitch -ErrorAction Stop)
    } catch {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bd923b6990ccc65e' -Arguments @{ message = "$($_.Exception.Message)" })
        return
    }
    if ($switches.Count -eq 0) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f8d085009c4c8200')
        return
    }
    foreach ($sw in $switches) {
        $switchName = [string]$sw.Name

        # A teamed uplink (Switch Embedded Teaming, LBFO) carries its members on
        # the PLURAL property and matches no single InterfaceDescription, so both
        # are read and a match on any member counts as bound.
        # The UNION of both properties, not the plural with the singular as a
        # fallback: a switch whose singular names an adapter absent from the
        # plural set would otherwise read as bound here and unbound in the
        # driver, and two different words for one host state is the second
        # opinion this section exists to avoid.
        $descriptions = @()
        if ($sw.PSObject.Properties.Name -contains 'NetAdapterInterfaceDescriptions' -and $sw.NetAdapterInterfaceDescriptions) {
            $descriptions += @($sw.NetAdapterInterfaceDescriptions | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
        if ($sw.NetAdapterInterfaceDescription) {
            $descriptions += [string]$sw.NetAdapterInterfaceDescription
        }
        $descriptions = @($descriptions | Select-Object -Unique)
        $uplinkText = if ($descriptions.Count -gt 0) { $descriptions -join '; ' } else { '(none bound)' }
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f12c03f2812948ec' -FormatValues ($switchName, $sw.SwitchType, $sw.AllowManagementOS) -FormatBindings @{ switchName = '0'; switchType = '1'; allowManagementOS = '2' })
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f7d06707f6830526' -FormatValues ($uplinkText) -FormatBindings @{ uplinkText = '0' })

        $bound = @()
        $adapterProbeOk = $false
        if ($descriptions.Count -gt 0 -and (Test-CommandAvailable 'Get-NetAdapter')) {
            try {
                $bound = @(Get-NetAdapter -ErrorAction Stop |
                    Where-Object { $descriptions -contains [string]$_.InterfaceDescription })
                $adapterProbeOk = $true
            } catch { $adapterProbeOk = $false }
        }
        foreach ($nic in $bound) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_63fd3d91f443af9b' -FormatValues ($nic.Name, $nic.Status, $nic.LinkSpeed) -FormatBindings @{ name = '0'; status = '1'; linkSpeed = '2' })
        }
        if ($adapterProbeOk -and $bound.Count -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e342099ae5f2fc9f')
        } elseif (-not $adapterProbeOk -and $descriptions.Count -gt 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ad5cd796383abcb2')
        }

        # Ask Hyper-V for the management-OS vNIC rather than matching the
        # "vEthernet (<switch>)" alias: an operator rename or a disambiguating
        # suffix leaves the alias wrong while the vNIC is present and working.
        $mgmt = @()
        $mgmtProbeOk = $false
        if (Test-CommandAvailable 'Get-VMNetworkAdapter') {
            try {
                $mgmt = @(Get-VMNetworkAdapter -ManagementOS -SwitchName $switchName -ErrorAction Stop)
                $mgmtProbeOk = $true
            } catch { $mgmtProbeOk = $false }
        }

        # A management vNIC clones the MAC of the NIC its switch bridges, so a MAC match
        # is never unique: only Hyper-V vEthernet adapters count, and several matches
        # are narrowed by alias (a set alias cannot single out resolves to no adapter,
        # read as 'unknown').
        # See https://yuruna.link/4213a0b3-0196
        $mgmtIps = @()
        $mgmtAddrOk = $false
        $mgmtSharedMac = @()
        if ($mgmt.Count -gt 0 -and (Test-CommandAvailable 'Get-NetAdapter') -and (Test-CommandAvailable 'Get-NetIPAddress')) {
            try {
                $macs = @($mgmt | ForEach-Object { ([string]$_.MacAddress) -replace '[^0-9A-Fa-f]', '' } | Where-Object { $_ })
                $hostNics = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
                    ($macs -contains (([string]$_.MacAddress) -replace '[^0-9A-Fa-f]', '')) -and
                    ([string]$_.InterfaceDescription -match 'Hyper-V Virtual Ethernet') })
                if ($hostNics.Count -gt 1) {
                    $mgmtSharedMac = @($hostNics | ForEach-Object { [string]$_.InterfaceAlias })
                    $aliases = @("vEthernet ({0})" -f $switchName) +
                        @($mgmt | ForEach-Object { "vEthernet ({0})" -f ([string]$_.Name) })
                    $hostNics = @($hostNics | Where-Object { $aliases -contains ([string]$_.InterfaceAlias) })
                }
                if ($hostNics.Count -eq 0) {
                    $hostNics = @(Get-NetAdapter -Name ("vEthernet ({0})" -f $switchName) -ErrorAction SilentlyContinue)
                }
                if ($hostNics.Count -gt 0) {
                    $indexes = @($hostNics | ForEach-Object { $_.InterfaceIndex })
                    $mgmtIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $indexes -contains $_.InterfaceIndex -and $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                        ForEach-Object { [string]$_.IPAddress })
                    $mgmtAddrOk = $true
                }
            } catch { $mgmtAddrOk = $false }
        }

        if (-not $mgmtProbeOk) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_daa53807f586eaba')
        } elseif ($mgmt.Count -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_04cb0b06ab0deedb')
        } else {
            $ipText = if ($mgmtIps.Count -gt 0) { $mgmtIps -join ', ' } elseif ($mgmtAddrOk) { '(none usable)' } else { '(not evaluable)' }
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9a85e0c370a533d9' -FormatValues ((($mgmt | ForEach-Object { [string]$_.Name }) -join ', '), $ipText) -FormatBindings @{ join = '0'; ipText = '1' })
            # Not a fault -- the clone is how Hyper-V builds a management vNIC.
            # It is reported because it is the one host shape where a leftover
            # adapter can answer for the live one, and an operator reading a
            # surprising verdict needs to see the candidates that were weighed.
            if ($mgmtSharedMac.Count -gt 1) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d6774599c4bb2aa3' -FormatValues (($mgmtSharedMac -join ', ')) -FormatBindings @{ join = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_06926d1d2c8038fd')
            }
        }

        # The ladder below must land on the same word as the Hyper-V driver's own
        # classifier for the same host state, rung for rung: an operator reads
        # this artifact to explain a verdict the driver already acted on, and two
        # ladders that disagree turn the diagnostic into a second opinion.
        $verdict = 'unknown'
        $verdictNote = $null
        if ($sw.SwitchType -ne 'External') {
            $verdict = 'not-external'
            $verdictNote = 'only an External switch bridges guests to the LAN'
        } elseif ($descriptions.Count -eq 0) {
            $verdict = 'uplink-missing'
        } elseif (-not $adapterProbeOk -or $bound.Count -eq 0) {
            # A description that resolves to no adapter is ambiguous rather than
            # broken -- a teamed member set can name adapters this enumeration
            # does not expose -- so it must not demote a working host.
            $verdict = 'unknown'
        } elseif (@($bound | Where-Object { Test-AdapterUp -Adapter $_ }).Count -eq 0) {
            $verdict = 'uplink-down'
        } elseif ($sw.AllowManagementOS -ne $true) {
            # A switch deliberately created without -AllowManagementOS has no
            # management vNIC by design; the host keeps its address on the
            # bridged NIC and the bridge is fine, so neither management-OS rung
            # below applies and its absence is not a fault.
            $verdict = 'healthy'
        } elseif (-not $mgmtProbeOk) {
            $verdict = 'unknown'
        } elseif ($mgmt.Count -eq 0) {
            $verdict = 'management-os-detached'
        } elseif (-not $mgmtAddrOk) {
            # The vNIC exists but its host adapter could not be resolved, so
            # there is no interface to look for an address on.
            $verdict = 'unknown'
        } elseif ($mgmtIps.Count -eq 0) {
            $verdict = 'management-os-unaddressed'
        } else {
            $verdict = 'healthy'
        }
        # The verdict line carries the bare word and nothing else, so a reader
        # scraping this artifact gets the same closed vocabulary for every
        # switch; any explanation goes on its own line underneath.
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_79fc4de78443f4b1' -FormatValues ($verdict) -FormatBindings @{ verdict = '0' })
        if ($verdictNote) {
            Write-Output ("      {0}" -f $verdictNote)
        }
        # 'not-external' names the kind of switch, not a fault: an Internal or
        # Private switch (the Default Switch among them) is doing exactly what it
        # was created to do, and only a broken External bridge is a problem.
        if ($verdict -notin @('healthy', 'unknown', 'not-external')) {
            Add-Problem -Class 'NETWORK.hyperv-switch-degraded' -Message (
                ("NETWORK: External virtual switch '{0}' is degraded ({1}); uplink {2}. " -f $switchName, $verdict, $uplinkText) +
                "Guests attached to it come up with no carrier while the host itself stays online and every other host check passes.")
        }
    }
}

# --- REGION: Linux privileged-probe support
# journalctl / dmesg / networkctl only expose system- and kernel-scope
# output when run with privilege. Over an unprivileged SSH session they
# silently degrade to the caller's own user journal and a restricted
# (usually empty) kernel ring buffer -- so a remote diagnostic that does
# not elevate comes back blank for exactly the boot / network / kernel
# evidence it exists to capture. Resolve a non-interactive sudo prefix
# once (-n never prompts, so a password-required sudo fails fast instead
# of hanging the whole capture) and reuse it for every privileged probe.
function Get-LinuxPrivPrefix {
    if (-not $IsLinux) { return @() }
    $uid = $null
    try { $uid = (& id -u 2>$null) } catch { $null = $_ }
    if ("$uid" -eq '0') { return @() }
    if (-not (Test-CommandAvailable 'sudo')) { return @() }
    & sudo -n true 2>$null
    if (0 -eq $LASTEXITCODE) { return @('sudo', '-n') }
    return @()
}
$script:LinuxPriv = @(Get-LinuxPrivPrefix)

# Run a privileged Linux probe with the resolved prefix and return its
# output as a string[]. Stderr is dropped by default (matches probes that
# only want clean stdout); -KeepStderr merges it (for probes that inspect
# warnings or detect a restricted ring buffer). $LASTEXITCODE is left
# reflecting the underlying tool so callers can still branch on it.
function Invoke-PrivProbe {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$ToolArgs = @(),
        [switch]$KeepStderr
    )
    $argv = @($script:LinuxPriv) + @($Tool) + $ToolArgs
    $exe  = $argv[0]
    $rest = @($argv | Select-Object -Skip 1)
    if ($KeepStderr) {
        return @(& $exe @rest 2>&1 | ForEach-Object { $_.ToString() })
    }
    return @(& $exe @rest 2>$null | ForEach-Object { $_.ToString() })
}

function Read-LinuxDiagnosticFile {
    <#
    .SYNOPSIS
        Reads bounded installer evidence through the resolved privilege prefix.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1,16777216)][int]$MaxBytes = 2097152,
        [switch]$MetadataOnly
    )
    $probe = @'
if [ ! -e "$1" ]; then
    if [ -x "${1%/*}" ]; then echo 'state=absent'; else echo 'state=denied-or-absent-parent'; fi
elif [ ! -r "$1" ]; then echo 'state=denied';
elif [ ! -s "$1" ]; then echo 'state=empty';
else
    echo 'state=read'
    size=$(wc -c < "$1")
    if [ "$3" = 'True' ]; then echo "bytes=$size (contents omitted: may contain seed credentials)"; exit 0; fi
    if [ "$size" -gt "$2" ]; then echo "(truncated: last $2 of $size bytes)"; fi
    tail -c "$2" -- "$1" || echo 'state=read-error'
fi
'@
    $lines = @(Invoke-PrivProbe -Tool 'sh' -ToolArgs @('-c',$probe,'sh',$Path,[string]$MaxBytes,[string][bool]$MetadataOnly) -KeepStderr)
    $state = if ($lines.Count -gt 0 -and $lines[0] -match '^state=(.+)$') { $Matches[1] } else { 'read-error' }
    # Installer logs can echo resolved seed commands even when the seed itself is omitted.
    $content = Protect-DiagnosticSecretText -Line @($lines | Select-Object -Skip 1)
    return @{ State=$state; Lines=@($content) }
}

# See ../docs/system-diagnostic.md#process-subtree-walk-breadth-first-bounded
# for why this walks breadth-first and how it stays bounded. -- Get-SystemDiagnostic.ps1
function Get-ProcessDescendantPid {
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)][int]$RootPid,
        [int]$MaxPids = 40
    )
    $ordered = [System.Collections.Generic.List[int]]::new()
    $seen    = [System.Collections.Generic.HashSet[int]]::new()
    $queue   = [System.Collections.Generic.Queue[int]]::new()
    $null = $seen.Add($RootPid)
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0 -and $ordered.Count -lt $MaxPids) {
        $current = $queue.Dequeue()
        $ordered.Add($current)
        foreach ($line in (Invoke-PrivProbe -Tool 'ps' -ToolArgs @('-o', 'pid=', '--ppid', "$current"))) {
            $childPid = 0
            if (-not [int]::TryParse($line.Trim(), [ref]$childPid)) { continue }
            if ($seen.Add($childPid)) { $queue.Enqueue($childPid) }
        }
    }
    return $ordered.ToArray()
}

# See ../docs/system-diagnostic.md#journal-windows-exclude-this-harnesss-own-polling
# for what these classes are and why they are tallied instead of printed. -- Get-SystemDiagnostic.ps1
function Get-JournalSelfNoiseClass {
    [OutputType([string])]
    param([string]$Line)
    if ($Line -match 'apparmor="STATUS"') { return 'apparmor profile reloads' }
    # libvirt reports an absent guest agent in more than one wording, and which
    # one dominates a window is an accident of when the probe lands relative to
    # the guest's lifecycle -- "not responding" once a domain is up, "not
    # connected" mid-teardown, "not configured" for an image that ships no
    # agent at all. Matching only one of them makes the counter depend on that
    # accident: two hosts with the same lab-normal journal can land on opposite
    # sides of the threshold purely because their guests died at different
    # points. All three are the same rung-1 address probe.
    if ($Line -match 'guest agent is not (responding|connected|configured)') { return 'guest-agent probes' }
    # The other half of the same teardown. libvirtd logs an EOF when a domain
    # it was talking to disappears, and networkctl reports the vnet tap that
    # went with it as missing; they arrive paired, in the same second, once per
    # guest the cycle destroys. Both are scoped narrowly -- libvirtd's own EOF,
    # and vnet interfaces specifically -- so a genuine I/O error from another
    # unit, or a missing interface that is not a libvirt tap, still counts.
    if ($Line -match 'libvirtd(\[\d+\])?:.*End of file while reading data') { return 'libvirt domain teardown' }
    if ($Line -match 'Interface "vnet\d+" not found') { return 'libvirt domain teardown' }
    if ($Line -match 'NamedPipeIPC_ServerListener(Error|Started)') { return 'PowerShell IPC listener records' }
    if ($Line -match 'Creating Scriptblock text \(\d+ of \d+\)') { return 'script-compile records' }
    return $null
}

# journalctl prints "-- Boot <id> --" and "-- Reboot --" markers between boots
# in the window it is asked for. They are structural separators, not entries,
# and counting them as errors adds one phantom error per boot -- enough on its
# own to push a quiet host over the threshold.
function Test-JournalSeparatorLine {
    [OutputType([bool])]
    param([string]$Line)
    return [bool]($Line -match '^\s*--\s*(Boot|Reboot)\b.*--\s*$')
}

# --- REGION: https://yuruna.link/423ef7f5-0015
# Unit names from `systemctl --failed --plain` rows, whose third column is the
# ACTIVE state; the header, legend and count lines never read "failed" there.
function Get-FailedUnitName {
    [OutputType([string[]])]
    param([string[]]$Line, [int]$MaxUnits = 8)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $Line) {
        if ($names.Count -ge $MaxUnits) { break }
        $m = [regex]::Match([string]$row, '^\s*(\S+)\s+\S+\s+failed\s')
        if ($m.Success -and -not $names.Contains($m.Groups[1].Value)) { $names.Add($m.Groups[1].Value) }
    }
    return $names.ToArray()
}

# Render the tally as one trailing line, or '' when nothing was suppressed.
function Format-JournalSelfNoiseNote {
    [OutputType([string])]
    param([System.Collections.Specialized.OrderedDictionary]$Tally)
    if (-not $Tally -or $Tally.Count -eq 0) { return '' }
    $parts = foreach ($k in $Tally.Keys) { "{0} {1}" -f $Tally[$k], $k }
    return ("({0} line(s) suppressed -- this harness's own polling: {1})" -f
        (($Tally.Keys | ForEach-Object { $Tally[$_] } | Measure-Object -Sum).Sum, ($parts -join ', ')))
}

function Format-ByteCount {
    param([Parameter(Mandatory)][double]$Bytes)
    $units = 'B','KB','MB','GB','TB','PB'
    $i = 0
    $v = $Bytes
    while ($v -ge 1024 -and $i -lt $units.Count - 1) { $v /= 1024; $i++ }
    return ('{0:N2} {1}' -f $v, $units[$i])
}

# A process's private bytes are its own commit charge, but shared memory
# sections, paged pool and other kernel allocations are charged against the
# same limit and appear in no process's private bytes. A leak held there raises
# the charge while every row of the private-bytes table stays flat, so that
# table cannot name it. The charge less the private bytes of every process is
# how much of the charge sits outside them.
function Get-CommitOutsideProcessLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][long]$ChargedBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Process
    )
    $privateSum = [long]0
    foreach ($entry in $Process) { $privateSum += [long]$entry.PrivateMemorySize64 }
    # The processes are listed a moment after the charge is read, so one that
    # started or grew in between can carry the sum past the charge.
    $outside = [math]::Max([long]0, $ChargedBytes - $privateSum)
    return (Format-YurunaOperatorMessage -Key 'automation.memory_commit_outside_processes' -Arguments @{
            outside = (Format-ByteCount $outside); charged = (Format-ByteCount $ChargedBytes)
            private = (Format-ByteCount $privateSum); processes = $Process.Count
        })
}

# Get-ComputerInfo's BIOS surface is a stable comparison contract, not a
# formatting-system dump. Keep every known field here even when a provider
# reports null, then let Get-BiosDiagnosticLine append future Bios* fields.
# This makes two artifacts directly diffable without Format-List reordering or
# truncating array values such as BiosCharacteristics.
function Get-BiosPropertyOrder {
    [OutputType([string[]])]
    param()
    return [string[]]@(
        'BiosCharacteristics'
        'BiosBIOSVersion'
        'BiosBuildNumber'
        'BiosCaption'
        'BiosCodeSet'
        'BiosCurrentLanguage'
        'BiosDescription'
        'BiosEmbeddedControllerMajorVersion'
        'BiosEmbeddedControllerMinorVersion'
        'BiosFirmwareType'
        'BiosIdentificationCode'
        'BiosInstallableLanguages'
        'BiosInstallDate'
        'BiosLanguageEdition'
        'BiosListOfLanguages'
        'BiosManufacturer'
        'BiosName'
        'BiosOtherTargetOS'
        'BiosPrimaryBIOS'
        'BiosReleaseDate'
        'BiosSerialNumber'
        'BiosSMBIOSBIOSVersion'
        'BiosSMBIOSMajorVersion'
        'BiosSMBIOSMinorVersion'
        'BiosSMBIOSPresent'
        'BiosSoftwareElementState'
        'BiosStatus'
        'BiosSystemBiosMajorVersion'
        'BiosSystemBiosMinorVersion'
        'BiosTargetOperatingSystem'
        'BiosVersion'
    )
}

function Format-BiosDiagnosticValue {
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '(not reported)' }

    if ($Value -is [datetimeoffset]) {
        return $Value.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [datetime]) {
        $utc = if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        } else {
            $Value.ToUniversalTime()
        }
        return $utc.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }

    if ($Value.GetType().IsEnum) {
        return ('{0} ({1})' -f $Value.ToString('D'), $Value.ToString('G'))
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @(foreach ($item in $Value) {
            Format-BiosDiagnosticValue -Value $item
        })
        return ('[{0}]' -f ($items -join ', '))
    }

    if ($Value -is [string] -or $Value -is [char]) {
        # JSON string escaping preserves embedded CR/LF/tab characters on one
        # line and distinguishes an empty string from a missing value.
        return (ConvertTo-Json -InputObject ([string]$Value) -Compress)
    }

    if ($Value -is [System.IFormattable]) {
        return $Value.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return (ConvertTo-Json -InputObject ([string]$Value) -Compress)
}

function Get-BiosDiagnosticLine {
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowNull()][object]$ComputerInfo)

    $properties = [System.Collections.Generic.Dictionary[string,object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $ComputerInfo) {
        foreach ($property in $ComputerInfo.PSObject.Properties) {
            if ($property.Name.StartsWith('Bios', [System.StringComparison]::OrdinalIgnoreCase)) {
                $properties[$property.Name] = $property.Value
            }
        }
    }

    $canonicalNames = @(Get-BiosPropertyOrder)
    $canonicalSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $canonicalNames) { [void]$canonicalSet.Add($name) }

    foreach ($name in $canonicalNames) {
        $value = if ($properties.ContainsKey($name)) { $properties[$name] } else { $null }
        '{0,-36} : {1}' -f $name, (Format-BiosDiagnosticValue -Value $value)
    }

    $additionalNames = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $properties.Keys) {
        if (-not $canonicalSet.Contains($name)) { $additionalNames.Add($name) }
    }
    $additionalNames.Sort([System.StringComparer]::Ordinal)
    foreach ($name in $additionalNames) {
        '{0,-36} : {1}' -f $name, (Format-BiosDiagnosticValue -Value $properties[$name])
    }
}

# One value of a sysfs or procfs attribute: its first line with runs of
# whitespace collapsed (kernel.printk separates its four levels with tabs), or
# $null when the file is absent or cannot be read. An attribute is one short
# line, and reading no further keeps the read bounded whatever the path holds.
# Absence is tested for, not caught: attributes are often absent (a virtual
# machine's firmware may publish no board fields), and a caught terminating
# error is still recorded in $Error and printed by the -OutFile transcript as a
# PS>TerminatingError line among the report's rows.
function Read-DiagnosticAttribute {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $line = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
    } catch {
        Write-Verbose "attribute unavailable: $Path ($($_.Exception.Message))"
        return $null
    }
    return ([regex]::Replace([string]$line, '\s+', ' ')).Trim()
}

# The machine identity a Linux kernel publishes world-readable under
# /sys/class/dmi/id, in a fixed order and rendered as the Windows BIOS rows are,
# so two hosts' reports compare line by line: a board or firmware release is
# what ties a freeze on one host to the same freeze on another. The serial
# numbers and UUIDs beside these fields identify one machine, are readable only
# by root, and are never read.
function Get-LinuxBiosDiagnosticLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$DmiDirectory = '/sys/class/dmi/id',
        [string]$CpuInfoPath = '/proc/cpuinfo'
    )
    foreach ($field in @('sys_vendor', 'product_name', 'product_version', 'board_vendor', 'board_name',
            'board_version', 'bios_vendor', 'bios_version', 'bios_date', 'bios_release')) {
        $path = Join-Path $DmiDirectory $field
        '{0,-36} : {1}' -f $path, (Format-BiosDiagnosticValue -Value (Read-DiagnosticAttribute -Path $path))
    }
    # The kernel reports a revision per logical CPU. A late load that reached
    # only some CPUs leaves them on different revisions, so every distinct
    # value is kept, in the order the CPUs are listed.
    $revisions = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($line in @(Get-Content -LiteralPath $CpuInfoPath -TotalCount 65536 -ErrorAction Stop)) {
            if ($line -match '^microcode\s*:\s*(\S+)' -and -not $revisions.Contains($Matches[1])) { $revisions.Add($Matches[1]) }
        }
    } catch {
        Write-Verbose "microcode revision unavailable: $($_.Exception.Message)"
    }
    $microcode = if ($revisions.Count -eq 0) { $null } elseif ($revisions.Count -eq 1) { $revisions[0] } else { $revisions.ToArray() }
    '{0,-36} : {1}' -f "$($CpuInfoPath):microcode", (Format-BiosDiagnosticValue -Value $microcode)
}

# Whether this report's journal reads reach the system journal. An account
# with neither root, sudo nor a group journald opens its files to gets its own
# user journal from journalctl, so every journal section of this report comes
# back short or empty with no error and the earlier boots are missing.
# journalctl --system exits non-zero when it can open no system journal file,
# which holds whatever groups a distribution grants access to; its exit code is
# the test, not a list of group names.
function Write-LinuxJournalAccess {
    [CmdletBinding()]
    param([string]$UserName = [Environment]::UserName)
    $answer = @(Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('--system', '-n', '1', '-q', '--no-pager') -KeepStderr)
    if ($LASTEXITCODE -eq 0) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_readable')
        return
    }
    $detail = "$(@($answer | Where-Object { "$_".Trim() }) | Select-Object -First 1)".Trim()
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_unreadable' -Arguments @{ user = "$UserName"; detail = "$detail" })
    # The group database, not this process's credentials: a membership added
    # after this process's login session began is listed there and grants
    # nothing until a new session starts.
    $groups = @("$(& id -nG $UserName 2>$null)" -split '\s+')
    if ($groups -contains 'systemd-journal') {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_session_stale' -Arguments @{ user = "$UserName" })
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_grant' -Arguments @{ user = "$UserName" })
    }
}

# The kernel log behind the ring-buffer tail and the OOM and hardware-error
# scans. kernel.dmesg_restrict closes the ring buffer to an account without
# privilege, such as a runner without passwordless sudo, while the system
# journal keeps the same kernel records and opens them to its readers. So the
# current boot's kernel journal stands in when dmesg is refused: its newest
# entries, more than a ring buffer usually holds, and a problem found there
# keeps the class it has when dmesg answers.
function Write-LinuxKernelLog {
    [CmdletBinding()]
    param()
    $journalEntries = 5000
    $source = ''
    $lines = @()
    if (Test-CommandAvailable 'dmesg') {
        $lines = @(Invoke-PrivProbe -Tool 'dmesg' -ToolArgs @('-T') -KeepStderr)
        $dmesgExit = $LASTEXITCODE
        if ($dmesgExit -eq 0) {
            $source = 'dmesg'
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_719107a91a9041cd' -FormatValues ($dmesgExit) -FormatBindings @{ dmesgExit = '0' })
        }
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_dce38997155da39d')
    }
    if (-not $source -and (Test-CommandAvailable 'journalctl')) {
        # -q keeps journalctl's own notices out of what is scanned: an account
        # that cannot read the system journal gets no lines, rather than a hint
        # and a "-- No entries --" marker printed as if they were kernel records.
        $lines = @(Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-k', '-b', '0', '-n', "$journalEntries", '-q', '--no-pager'))
        if ($LASTEXITCODE -eq 0 -and $lines.Count -gt 0) {
            $source = 'journal'
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_kernel_log_journal' -Arguments @{ count = "$journalEntries" })
        }
    }
    if (-not $source) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_kernel_log_unavailable')
        return
    }
    $lines | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
    $oomHits = @($lines | Where-Object { $_ -match 'Out of memory|oom-kill|killed process' })
    # Hardware and driver error reports: an "I/O error", which drivers spell
    # in either case; a "Hardware Error", the "[Hardware Error]" prefix of
    # every logged machine check and of APEI and boot-error records, or a SCSI
    # sense key; and an EDAC memory controller's count of corrected (CE) or
    # uncorrected (UE) errors. A bare "MCE:" or "EDAC" is no error: every boot
    # prints "MCE: In-kernel MCE decoding enabled." and "EDAC MC: Ver: 3.0.0",
    # and a device name or UUID can hold "edac", so EDAC is matched
    # case-sensitively and only with its count.
    $hwHits = @($lines | Where-Object { $_ -match 'I/O error|Hardware Error' -or $_ -cmatch '\bEDAC MC\d+: \d+ [CU]E\b' })
    if ($source -eq 'dmesg') {
        if ($oomHits.Count -gt 0) {
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_5f4da68a8a0470cb' -FormatValues ($oomHits.Count) -FormatBindings @{ count = '0' }) -Class 'LINUX.oom-events'
        }
        if ($hwHits.Count -gt 0) {
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_0052f7d7f687e07e' -FormatValues ($hwHits.Count) -FormatBindings @{ count = '0' }) -Class 'LINUX.hardware-errors'
        }
    } else {
        if ($oomHits.Count -gt 0) {
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_kernel_journal_oom' -Arguments @{ count = "$($oomHits.Count)" }) -Class 'LINUX.oom-events'
        }
        if ($hwHits.Count -gt 0) {
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_kernel_journal_hardware' -Arguments @{ count = "$($hwHits.Count)" }) -Class 'LINUX.hardware-errors'
        }
    }
}

# NetworkManager's DHCP client holds the bridge's lease where NetworkManager
# built the bridge. The DHCP4 lines under NETWORK show only the lease held now:
# its length and when it expires. These dhcp4 journal lines show what became of
# each lease this boot -- granted, extended at a renewal, or replaced once it
# ran out -- which is what tells a host whose renewals take effect from one that
# takes a new lease at every expiry. journalctl's own "-- No entries --" is
# kept; the catalog line stands in only when journalctl printed nothing at all.
function Get-LinuxNetworkManagerDhcpLine {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $lines = @(Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-b', '0', '-u', 'NetworkManager', '--grep', 'dhcp4', '-n', '100', '--no-pager'))
    if ($lines.Count -eq 0) { return (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_networkmanager_dhcp_none') }
    return $lines
}

# The settings that decide what a frozen or hung kernel leaves behind: whether
# the soft-lockup, hard-lockup and hung-task detectors run and whether they
# panic, whether a panic reboots, how much reaches the console, where a panic's
# log is kept (pstore), what reboots a host that stops answering (a hardware
# watchdog, which systemd arms when RuntimeWatchdogUSec is set), and whether the
# journal of the boot that froze survives the restart. Each value comes from a
# world-readable file or an unprivileged query, so the view is the same with or
# without sudo.
function Get-LinuxLockupSettingLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$ProcSysKernel = '/proc/sys/kernel',
        [string]$PstoreBackend = '/sys/module/pstore/parameters/backend',
        [string]$WatchdogClass = '/sys/class/watchdog',
        [string]$PersistentJournal = '/var/log/journal'
    )
    foreach ($name in @('watchdog', 'nmi_watchdog', 'softlockup_panic', 'hardlockup_panic', 'panic',
            'panic_on_oops', 'hung_task_timeout_secs', 'hung_task_panic', 'printk')) {
        '{0,-36} : {1}' -f "kernel.$name", (Format-BiosDiagnosticValue -Value (Read-DiagnosticAttribute -Path (Join-Path $ProcSysKernel $name)))
    }
    '{0,-36} : {1}' -f $PstoreBackend, (Format-BiosDiagnosticValue -Value (Read-DiagnosticAttribute -Path $PstoreBackend))
    $devices = @(Get-ChildItem -LiteralPath $WatchdogClass -Filter 'watchdog*' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name | Select-Object -First 8)
    if ($devices.Count -eq 0) {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_watchdog_none' -Arguments @{ path = "$WatchdogClass" }
    }
    foreach ($device in $devices) {
        foreach ($attribute in @('identity', 'timeout')) {
            $path = Join-Path $device.FullName $attribute
            '{0,-36} : {1}' -f $path, (Format-BiosDiagnosticValue -Value (Read-DiagnosticAttribute -Path $path))
        }
    }
    # Bounded: PID 1 answers this query, and PID 1 is what may not answer on a
    # host in trouble.
    $runtimeWatchdog = $null
    if (Test-CommandAvailable 'systemctl') {
        $probe = Invoke-DiagnosticBoundedCommand -FilePath 'systemctl' -TimeoutSeconds 5 -MaxCapturedChars 4096 `
            -ArgumentList @('show', '--property=RuntimeWatchdogUSec', '--value')
        if ($probe.Started -and -not $probe.TimedOut -and $probe.ExitCode -eq 0) { $runtimeWatchdog = ([string]$probe.StdOut).Trim() }
    }
    '{0,-36} : {1}' -f 'RuntimeWatchdogUSec', (Format-BiosDiagnosticValue -Value $runtimeWatchdog)
    # journald's Storage= overrides the directory: volatile and none keep
    # nothing on disk even where it exists, while auto and persistent write to
    # it whenever it exists (persistent creates it). cat-config prints the main
    # file and its drop-ins in the order journald reads them, so the last valid
    # assignment is the one in effect.
    $storage = $null
    if (Test-CommandAvailable 'systemd-analyze') {
        $config = Invoke-DiagnosticBoundedCommand -FilePath 'systemd-analyze' -TimeoutSeconds 5 -MaxCapturedChars 65536 `
            -ArgumentList @('--no-pager', 'cat-config', 'systemd/journald.conf')
        if ($config.Started -and -not $config.TimedOut -and -not $config.OutputTruncated -and $config.ExitCode -eq 0) {
            $storage = 'auto'
            foreach ($line in ([string]$config.StdOut -split '\r?\n')) {
                if ($line -cmatch '^\s*Storage\s*=\s*(volatile|persistent|auto|none)\s*$') { $storage = $Matches[1] }
            }
        }
    }
    '{0,-36} : {1}' -f 'systemd/journald.conf:Storage', (Format-BiosDiagnosticValue -Value $storage)
    if ($storage -in @('volatile', 'none')) {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_not_on_disk' -Arguments @{ storage = "$storage"; path = "$PersistentJournal" }
    } elseif (Test-Path -LiteralPath $PersistentJournal -PathType Container) {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_persistent' -Arguments @{ path = "$PersistentJournal" }
    } else {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_volatile' -Arguments @{ path = "$PersistentJournal" }
    }
}

# Deep diagnostics mode, which an operator turns on for a host whose operating
# system freezes, records what it applied in a state file, and a report taken in
# that mode says so: the netconsole target is where the last kernel lines of a
# freeze went, and a component that failed or was skipped names evidence that
# will be missing. The file is read as data under a size cap; one that cannot
# be read or parsed is reported, and nothing in it is trusted. Fields this
# reader does not know are left alone.
function Get-DeepDiagnosticStateLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Path = '/var/lib/yuruna/deep-diagnostics/state.json')
    if (-not (Test-Path -LiteralPath $Path)) {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_deep_mode_off' -Arguments @{ path = "$Path" }
        return
    }
    $file = Get-DiagnosticSourceFile -Root (Split-Path -Parent $Path) -RelativePath (Split-Path -Leaf $Path) -MaximumBytes 65536
    if (-not $file) {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_deep_mode_unreadable' -Arguments @{ path = "$Path" }
        return
    }
    try {
        # The timestamp is shown as written, not as this host's culture would
        # render a parsed date.
        $options = @{ AsHashtable = $true; ErrorAction = 'Stop' }
        if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
        $state = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName)) @options
    } catch {
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_deep_mode_malformed' -Arguments @{ path = "$Path"; message = "$($_.Exception.Message)" }
        return
    }
    if ($state -isnot [System.Collections.IDictionary]) {
        $found = ConvertTo-Json -InputObject $state -Compress -Depth 2 -WarningAction SilentlyContinue
        if ($found.Length -gt 80) { $found = $found.Substring(0, 80) + '...' }
        Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_deep_mode_malformed' -Arguments @{ path = "$Path"; message = "$found" }
        return
    }
    $since = $state['enabledAtUtc']
    if ($since -is [datetime]) { $since = $since.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    if ([string]::IsNullOrWhiteSpace("$since")) { $since = Format-BiosDiagnosticValue -Value $null }
    Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_deep_mode_on' -Arguments @{ enabledAtUtc = "$since" }
    # Each row names a field by its path in the document and shows its JSON
    # value, so nothing in the file is reworded on the way out.
    $row = {
        param([System.Collections.IDictionary]$Map, [string]$Name, [string]$Label)
        $value = if ($Map.Contains($Name)) {
            ConvertTo-Json -InputObject $Map[$Name] -Compress -Depth 4 -WarningAction SilentlyContinue
        } else {
            Format-BiosDiagnosticValue -Value $null
        }
        '{0,-36} : {1}' -f $Label, $value
    }
    foreach ($name in @('schema', 'enabledBy', 'hostType', 'netconsoleTarget')) { & $row $state $name $name }
    $components = $state['components']
    if ($components -isnot [System.Collections.IDictionary]) {
        & $row $state 'components' 'components'
        return
    }
    foreach ($name in @($components.Keys)) {
        if ($components[$name] -is [System.Collections.IDictionary]) {
            foreach ($field in @('status', 'reason')) { & $row $components[$name] $field "components.$name.$field" }
        } else {
            & $row $components $name "components.$name"
        }
    }
}

$transcriptStarted = $false
if ($OutFile) {
    try {
        $transcriptStarted = $true
        Start-Transcript -Path $OutFile -Force | Out-Null
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_10d27b9c79644210' -Arguments @{ outFile = "$OutFile"; message = "$($_.Exception.Message)" })
        $transcriptStarted = $false
    }
}

try {

    # --- REGION: 1. Host
    Invoke-DiagnosticSection "HOST" {
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_fddd431669f34dca' -FormatValues ([System.Net.Dns]::GetHostName()) -FormatBindings @{ getHostName = '0' })
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3d926ec2c9a14019' -FormatValues ([Environment]::UserName) -FormatBindings @{ userName = '0' })
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_56fa491fa25bce42' -FormatValues ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)) -FormatBindings @{ z = '0' })
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_13047337e502a109' -FormatValues ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK', [Globalization.CultureInfo]::InvariantCulture)) -FormatBindings @{ ssK = '0' })
    $sourceProvenance = Get-DiagnosticSourceProvenance -CheckoutRoot $script:DiagnosticEvidenceRoot
    Write-Output ('guestProvenance=' + ($sourceProvenance | ConvertTo-Json -Depth 6 -Compress))

    # --- REGION: https://yuruna.link/423ef7f5-0008
    Write-Sub "Software"
    function Get-VersionLine {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][scriptblock]$Probe
        )
        $value = $null
        try {
            $value = & $Probe
        } catch {
            $value = $null
        }
        if ($value -is [array]) { $value = $value | Where-Object { $_ } | Select-Object -First 1 }
        $text = if ($null -ne $value) { ([string]$value).Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($text)) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_caf9b81631b566c3' -FormatValues ($Name) -FormatBindings @{ name = '0,-20' })
        } else {
            Write-Output ("  {0,-20} : {1}" -f $Name, $text)
        }
    }
    # PowerShell -- always available since this script requires v7.
    Get-VersionLine 'PowerShell' {
        '{0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition
    }
    Get-VersionLine 'git' {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            ((& git --version 2>$null) -replace '^git version ','')
        }
    }
    Get-VersionLine 'python3' {
        if (Get-Command python3 -ErrorAction SilentlyContinue) {
            ((& python3 --version 2>$null) -replace '^Python ','')
        }
    }
    Get-VersionLine 'node' {
        if (Get-Command node -ErrorAction SilentlyContinue) { & node --version 2>$null }
    }
    Get-VersionLine 'npm' {
        if (Get-Command npm -ErrorAction SilentlyContinue) { & npm --version 2>$null }
    }
    # --- REGION: https://yuruna.link/423ef7f5-0004
    Get-VersionLine 'Docker' {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            ((& docker --version 2>$null) -replace '^Docker version ','' -replace ',\s*build.*$','')
        }
    }
    Get-VersionLine 'Docker buildx' {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            $bx = & docker buildx version 2>$null | Select-Object -First 1
            if ($bx) { ($bx -split '\s+')[1] }
        }
    }
    Get-VersionLine 'containerd' {
        if (Get-Command containerd -ErrorAction SilentlyContinue) {
            $cd = & containerd --version 2>$null | Select-Object -First 1
            if ($cd) {
                $parts = $cd -split '\s+' | Where-Object { $_ -match '^v?\d+\.' } | Select-Object -First 1
                if ($parts) { $parts } else { $cd }
            }
        }
    }
    Get-VersionLine 'Kubernetes' {
        if (Get-Command kubectl -ErrorAction SilentlyContinue) {
            # --- REGION: https://yuruna.link/423ef7f5-0004
            $j = & kubectl version --client -o json --request-timeout=5s 2>$null
            if ($LASTEXITCODE -eq 0 -and $j) {
                (($j -join "`n") | ConvertFrom-Json).clientVersion.gitVersion
            }
        }
    }
    Get-VersionLine 'Helm' {
        if (Get-Command helm -ErrorAction SilentlyContinue) {
            & helm version --short 2>$null | Select-Object -First 1
        }
    }
    Get-VersionLine 'OpenTofu' {
        if (Get-Command tofu -ErrorAction SilentlyContinue) {
            $j = & tofu version -json 2>$null
            if ($LASTEXITCODE -eq 0 -and $j) {
                (($j -join "`n") | ConvertFrom-Json).terraform_version
            }
        }
    }
    Get-VersionLine 'mkcert' {
        if (Get-Command mkcert -ErrorAction SilentlyContinue) {
            & mkcert -version 2>&1 | Select-Object -First 1
        }
    }
    Get-VersionLine 'curl' {
        if (Get-Command curl -ErrorAction SilentlyContinue) {
            # First line is `curl X.Y.Z (build/triplet) libcurl/X.Y.Z ...`;
            # everything after the opening paren is libcurl feature noise.
            (& curl --version 2>$null | Select-Object -First 1) -replace '\s*\(.*$',''
        }
    }
    Get-VersionLine 'wget' {
        if (Get-Command wget -ErrorAction SilentlyContinue) {
            & wget --version 2>$null | Select-Object -First 1
        }
    }
    Get-VersionLine 'tesseract' {
        # PATH alone under-reports tesseract: the OCR engine also checks the platform's
        # standard install directories, and the set below must match Find-Tesseract in
        # test/modules/Test.Tesseract.psm1.
        # See https://yuruna.link/4213a0b3-0197
        $exe = (Get-Command tesseract -ErrorAction SilentlyContinue).Source
        if (-not $exe) {
            $candidates = if ($IsWindows) {
                @(
                    "C:\Program Files\Tesseract-OCR\tesseract.exe"
                    "C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"
                    "$env:LOCALAPPDATA\Programs\Tesseract-OCR\tesseract.exe"
                )
            } elseif ($IsMacOS) {
                @('/usr/local/bin/tesseract', '/opt/homebrew/bin/tesseract')
            } else {
                @('/usr/bin/tesseract', '/usr/local/bin/tesseract', '/snap/bin/tesseract')
            }
            $exe = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        }
        if ($exe) {
            & $exe --version 2>&1 | Select-Object -First 1
        }
    }
    Get-VersionLine 'qemu-img' {
        # PATH alone under-reports qemu-img on Windows (its installer skips PATH)
        # and PATH order alone picks the wrong copy there, so this ranks the same
        # candidates Resolve-QemuImgCommand in host/modules/Yuruna.Image.psm1
        # ranks, the same way: the installer's locations, then every copy on
        # PATH, newest version wins, the earlier one on a tie.
        # See https://yuruna.link/4213a0b3-0197
        $namePath = (Get-Command qemu-img -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $exe = $namePath
        $nameLine = $null
        if ($IsWindows) {
            $best = $null; $bestVersion = $null
            $copies = @(@(
                    "$env:ProgramFiles\qemu\qemu-img.exe"
                    "${env:ProgramFiles(x86)}\qemu\qemu-img.exe"
                ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }) +
                @(Get-Command qemu-img -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
            foreach ($copy in $copies) {
                $line = & $copy --version 2>$null | Select-Object -First 1
                $copyVersion = if ("$line" -match 'version\s+(\d+(?:\.\d+){1,3})') { [version]$Matches[1] } else { $null }
                if (-not $best -or ($copyVersion -and (-not $bestVersion -or $copyVersion -gt $bestVersion))) { $best = $copy; $bestVersion = $copyVersion }
                if ($namePath -and $copy -eq $namePath) { $nameLine = "$line" -replace ',\s*Copyright.*$','' }
            }
            $exe = $best
        }
        if ($exe) {
            # First line is `qemu-img version X.Y.Z, Copyright (c) ... Fabrice Bellard`;
            # the Copyright tail is constant noise. The path is part of the
            # answer: a host can carry more than one copy, and which one runs is
            # the question this line is read for.
            $text = "$((& $exe --version 2>$null | Select-Object -First 1) -replace ',\s*Copyright.*$','') [$exe]"
            if ($namePath -and $namePath -ne $exe -and $nameLine) { $text += "; the name qemu-img resolves to $nameLine [$namePath]" }
            $text
        }
    }
    Get-VersionLine 'oscdimg' {
        # Windows-only, and never on PATH: the ADK registers nothing, shipping
        # DandISetEnv.bat to build an environment on demand instead. It lays
        # Oscdimg down once per architecture, and any copy answers the version
        # question -- which build actually runs is Resolve-OscdimgPath's
        # decision, in host/windows.hyper-v/modules/Yuruna.Host.psm1.
        if ($IsWindows) {
            $exe = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\*\Oscdimg\Oscdimg.exe" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($exe) {
                # No version flag (`-h` means "include hidden files"), so the
                # version comes off the banner oscdimg prints ahead of its usage
                # text. The missing source and target make it exit non-zero,
                # which is not a failure signal here.
                $PSNativeCommandUseErrorActionPreference = $false
                @(& $exe.FullName 2>&1 | ForEach-Object { "$_" }) |
                    Where-Object { $_ -match 'OSCDIMG' } | Select-Object -First 1
            }
        }
    }
    Get-VersionLine 'AWS cli' {
        if (Get-Command aws -ErrorAction SilentlyContinue) {
            # `aws-cli/X.Y.Z Python/X.Y.Z OS/build prompt/...`; everything
            # after the first whitespace is environment context, not version.
            (& aws --version 2>&1 | Select-Object -First 1) -replace '\s.*$',''
        }
    }
    Get-VersionLine 'Azure cli' {
        if (Get-Command az -ErrorAction SilentlyContinue) {
            $j = & az version 2>$null
            if ($LASTEXITCODE -eq 0 -and $j) {
                (($j -join "`n") | ConvertFrom-Json).'azure-cli'
            }
        }
    }
    Get-VersionLine 'Google Cloud' {
        if (Get-Command gcloud -ErrorAction SilentlyContinue) {
            # --- REGION: https://yuruna.link/423ef7f5-0004
            & gcloud -v 2>$null | Select-Object -First 1
        }
    }
    Get-VersionLine 'Visual Studio Code' {
        if (Get-Command code -ErrorAction SilentlyContinue) {
            & code -v 2>$null | Select-Object -First 1
        }
    }

    # --- REGION: OS details
    if ($IsWindows) {
        $osi = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($osi) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a4e0c8c241287bb7' -FormatValues ($osi.Caption, $osi.BuildNumber) -FormatBindings @{ caption = '0'; buildNumber = '1' })
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_30e5a9c36e444264' -FormatValues ($osi.LastBootUpTime) -FormatBindings @{ lastBootUpTime = '0' })
            $up = (Get-Date) - $osi.LastBootUpTime
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_890c2539295306b9' -FormatValues ($up.TotalHours) -FormatBindings @{ totalHours = '0:F1' })
        }
    } elseif ($IsMacOS) {
        Write-Sub "uname -a"
        Invoke-Tool -Tool '/usr/bin/uname' -ToolArgs @('-a')
        Write-Sub "sw_vers"
        Invoke-Tool -Tool '/usr/bin/sw_vers'
        Write-Sub "uptime"
        Invoke-Tool -Tool '/usr/bin/uptime'
    } elseif ($IsLinux) {
        Write-Sub "uname -a"
        Invoke-Tool -Tool 'uname' -ToolArgs @('-a')
        if (Test-Path '/etc/os-release') {
            Write-Sub "/etc/os-release"
            Get-Content '/etc/os-release' | Where-Object { $_ -match '^(NAME|VERSION|PRETTY_NAME)=' } | ForEach-Object { Write-Output $_ }
        }
        Write-Sub "uptime"
        Invoke-Tool -Tool 'uptime'
    }
    }

    # --- REGION: 1b. BIOS
    Invoke-DiagnosticSection "BIOS" {
    if ($IsLinux) {
        Get-LinuxBiosDiagnosticLine | ForEach-Object { Write-Output $_ }
    } elseif (-not $IsWindows) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_906db62350cd0764')
    } elseif (-not (Get-Command -Name Get-ComputerInfo -ErrorAction SilentlyContinue)) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a3aa7f35af447110')
    } else {
        try {
            # One wildcard query captures PowerShell's complete BIOS surface,
            # including BiosFirmwareType, while the renderer fixes row order.
            $biosInfo = Get-ComputerInfo -Property 'Bios*' -ErrorAction Stop
            if ($null -eq $biosInfo) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_49673525d6734038')
            } else {
                Get-BiosDiagnosticLine -ComputerInfo $biosInfo |
                    ForEach-Object { Write-Output $_ }
            }
        } catch {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a8ad0a1fc36b0005' -FormatValues ($_.Exception.Message) -FormatBindings @{ message = '0' })
        }
    }
    }

    # --- REGION: 2. CPU
    Invoke-DiagnosticSection "CPU" {
    if ($IsWindows) {
        $cpus = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
        if ($cpus) {
            foreach ($c in $cpus) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_10822e392d94ddaa' -FormatValues ($c.Name) -FormatBindings @{ name = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2ae3b324855cd5a6' -FormatValues ($c.NumberOfCores, $c.NumberOfLogicalProcessors) -FormatBindings @{ numberOfCores = '0'; numberOfLogicalProcessors = '1' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_87fbc44e5784e7ea' -FormatValues ($c.MaxClockSpeed) -FormatBindings @{ maxClockSpeed = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_99f43b55d16c10d9' -FormatValues ($c.LoadPercentage) -FormatBindings @{ loadPercentage = '0' })
                Write-Output ""
            }
            # --- REGION: Processor power policy
            # A capped maximum processor state throttles every guest on the host,
            # and nothing above reveals it: Win32_Processor reports the RATED
            # clock, not the permitted one. Recording it per cycle is what lets a
            # slow run be told apart from a throttled host without a rerun.
            $scheme = powercfg /getactivescheme 2>$null |
                Select-String '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+\((.+)\)' | Select-Object -First 1
            if ($scheme) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_4c47b23469f21be0' -FormatValues ($scheme.Matches[0].Groups[2].Value.Trim(), $scheme.Matches[0].Groups[1].Value) -FormatBindings @{ trim = '0'; value = '1' })
            }
            $throttleMaxAc = $null
            foreach ($setting in 'PROCTHROTTLEMAX', 'PROCTHROTTLEMIN') {
                $q = powercfg /query SCHEME_CURRENT SUB_PROCESSOR $setting 2>$null
                # Labels are localized; the final two hexadecimal fields are
                # the AC and DC values in the stable native output order.
                $indices = @(foreach ($line in $q) {
                    if ($line -match ':\s*0x([0-9a-fA-F]+)\s*$') { [Convert]::ToInt64($Matches[1], 16) }
                })
                $acText = 'n/a'
                $dcText = 'n/a'
                if ($LASTEXITCODE -eq 0 -and $indices.Count -ge 2) {
                    $acVal = $indices[-2]
                    $acText = "$acVal%"
                    $dcText = "$($indices[-1])%"
                    if ($setting -eq 'PROCTHROTTLEMAX') { $throttleMaxAc = $acVal }
                }
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_80a91c7136b5ea24' -FormatValues ($setting, $acText, $dcText) -FormatBindings @{ setting = '0,-16'; acText = '1'; dcText = '2' })
            }
            Write-Output ""
            # AC only. A machine with no battery never reaches its DC values, so
            # alarming on those reports a cap that cannot apply.
            if ($null -ne $throttleMaxAc -and $throttleMaxAc -lt 100) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_a0085d33a3129918' -Arguments @{ throttleMaxAc = "$throttleMaxAc" }) -Class 'CPU.power-limit'
            }

            $busy = ($cpus | Measure-Object LoadPercentage -Average).Average
            if ($busy -ge 90) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_3d642d2080f94214' -Arguments @{ busy = "$([math]::Round($busy,1))" }) -Class 'CPU.high-load' }
        }
    } elseif ($IsMacOS) {
        Write-Sub "sysctl -n machdep.cpu.brand_string / hw.ncpu"
        Invoke-Tool -Tool '/usr/sbin/sysctl' -ToolArgs @('-n','machdep.cpu.brand_string')
        Invoke-Tool -Tool '/usr/sbin/sysctl' -ToolArgs @('-n','hw.ncpu')
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_99c6f7bd7b0f53a1')
        & '/usr/bin/top' -l 1 -n 0 2>$null | Select-Object -First 12 | ForEach-Object { Write-Output $_ }
    } elseif ($IsLinux) {
        $cores = 0
        if (Test-Path '/proc/cpuinfo') {
            $modelLine = Get-Content '/proc/cpuinfo' | Where-Object { $_ -match '^model name' } | Select-Object -First 1
            $model = if ($modelLine) {
                ($modelLine -replace '^model name\s*:\s*', '').Trim()
            } else {
                '(unknown -- no "model name" line in /proc/cpuinfo)'
            }
            $cores = @(Get-Content '/proc/cpuinfo' | Where-Object { $_ -match '^processor' }).Count
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9378f57b64553a05' -Arguments @{ model = "$model" })
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_19207cb68304a0f3' -Arguments @{ cores = "$cores" })
        }
        if (Test-Path '/proc/loadavg') {
            $load = (Get-Content '/proc/loadavg').Trim()
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_43c9133034669a17' -Arguments @{ load = "$load" })
            $load1m = [double](($load -split '\s+')[0])
            if ($cores -gt 0 -and $load1m -gt ($cores * 1.5)) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_d91128cf43fe5efd' -Arguments @{ load1m = "$load1m"; cores = "$cores" }) -Class 'CPU.high-load'
            }
        }
    }
    }

    # --- REGION: 3. Memory
    Invoke-DiagnosticSection "MEMORY" {
    if ($IsWindows) {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $totalKb = [int64]$os.TotalVisibleMemorySize
            $freeKb  = [int64]$os.FreePhysicalMemory
            $used    = ($totalKb - $freeKb) * 1KB
            $total   = $totalKb * 1KB
            $free    = $freeKb * 1KB
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9e908d7d9bc23dd3' -FormatValues ((Format-ByteCount $total)) -FormatBindings @{ total = '0' })
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d3ead8947216ae55' -FormatValues ((Format-ByteCount $used)) -FormatBindings @{ used = '0' })
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_842502c243d9b6fe' -FormatValues ((Format-ByteCount $free)) -FormatBindings @{ free = '0' })
            $pct = ($used / $total) * 100
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b192afb689e5cf6d' -FormatValues ($pct) -FormatBindings @{ pct = '0:N1' })
            if ($pct -ge 90) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_38b2e61abf2a764b' -FormatValues ($pct) -FormatBindings @{ pct = '0:N1' }) -Class 'MEMORY.high-usage' }
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d5339462df16bcf8' -FormatValues ((Format-ByteCount ($os.SizeStoredInPagingFiles * 1KB))) -FormatBindings @{ kB = '0' })
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_befb68c3b5ba5317' -FormatValues ((Format-ByteCount ($os.FreeSpaceInPagingFiles * 1KB))) -FormatBindings @{ kB = '0' })
            # Commit, not free physical memory, is what admits a VM start: a
            # static guest's whole size is charged against the commit limit
            # (physical memory plus the page file), so a host refuses a 12 GB
            # start with 19 GB of physical memory free once a leaking parent
            # partition has charged the rest. TotalVirtualMemorySize is that
            # limit and FreeVirtualMemory the headroom under it, both in KB.
            $commitLimit = [int64]$os.TotalVirtualMemorySize * 1KB
            $commitFree  = [int64]$os.FreeVirtualMemory * 1KB
            if ($commitLimit -gt 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.memory_commit_charge' -Arguments @{ charged = (Format-ByteCount ($commitLimit - $commitFree)); limit = (Format-ByteCount $commitLimit); uncharged = (Format-ByteCount $commitFree) })
                Write-Output (Get-CommitOutsideProcessLine -ChargedBytes ($commitLimit - $commitFree) -Process @(Get-Process -ErrorAction SilentlyContinue))
            }
        }
    } elseif ($IsMacOS) {
        Write-Sub "vm_stat"
        Invoke-Tool -Tool '/usr/bin/vm_stat'
        Write-Sub "top -l 1 PhysMem"
        & '/usr/bin/top' -l 1 -n 0 2>$null | Select-String -Pattern 'PhysMem' | ForEach-Object { Write-Output $_ }
    } elseif ($IsLinux) {
        if (Test-Path '/proc/meminfo') {
            $mi = Get-Content '/proc/meminfo'
            $mi | Where-Object { $_ -match '^(MemTotal|MemAvailable|MemFree|SwapTotal|SwapFree|Buffers|Cached):' } | ForEach-Object { Write-Output $_ }
            $totalKb = 0
            $availKb = 0
            foreach ($line in $mi) {
                if ($line -match '^MemTotal:\s*(\d+)')         { $totalKb = [int64]$Matches[1] }
                elseif ($line -match '^MemAvailable:\s*(\d+)') { $availKb = [int64]$Matches[1] }
            }
            if ($totalKb -gt 0) {
                $usedPct = (1 - ($availKb / $totalKb)) * 100
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6036ef007d775983' -FormatValues ($usedPct) -FormatBindings @{ usedPct = '0:N1' })
                if ($usedPct -ge 90) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_3e92708420fcba11' -FormatValues ($usedPct) -FormatBindings @{ usedPct = '0:N1' }) -Class 'MEMORY.high-usage' }
            }
        }
    }
    }

    # --- REGION: 4. Disk
    Invoke-DiagnosticSection "DISK" {
    if ($IsWindows) {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        if ($disks) {
            $disks | ForEach-Object {
                $tot = [double]$_.Size
                $fre = [double]$_.FreeSpace
                $used = $tot - $fre
                $pct = if ($tot -gt 0) { ($used / $tot) * 100 } else { 0 }
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bd3dcda0a121faa1' -FormatValues ($_.DeviceID, (Format-ByteCount $tot), (Format-ByteCount $fre), $pct, $_.FileSystem) -FormatBindings @{ deviceID = '0'; tot = '1'; fre = '2'; pct = '3:N1'; fileSystem = '4' })
                if ($pct -ge 90) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_f4bc7d8c9f330da6' -FormatValues ($_.DeviceID, $pct) -FormatBindings @{ deviceID = '0'; pct = '1:N1' }) -Class 'DISK.high-usage' }
            }
        }
    } else {
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_5fda31960d8c149a')
        # One df snapshot serves both the rendered table and the >=90%-full parse. The
        # [string[]] cast holds the one-element macOS branch to an array: a bare String
        # would splat as characters.
        # See https://yuruna.link/4213a0b3-01b2
        [string[]]$dfArgs = if ($IsMacOS) { @('-Pl') } else { @('-Pl','-x','tmpfs','-x','devtmpfs','-x','squashfs','-x','overlay') }
        $dfBin = if ($IsMacOS) { '/bin/df' } else { 'df' }
        $dfOut = @(& $dfBin @dfArgs 2>$null | ForEach-Object { $_.ToString() })
        $dfOut | ForEach-Object { Write-Output $_ }
        foreach ($l in ($dfOut | Select-Object -Skip 1)) {
            $cols = $l -split '\s+'
            if ($cols.Count -ge 6) {
                $usePct = $cols[4] -replace '%',''
                if ($usePct -as [int] -and [int]$usePct -ge 90) {
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_392f4d20e6624910' -FormatValues ($cols[0], $usePct, $cols[5]) -FormatBindings @{ cols = '0'; usePct = '1'; cols2 = '2' }) -Class 'DISK.high-usage'
                }
            }
        }
    }
    }

    # --- REGION: 5. GPU
    Invoke-DiagnosticSection "GPU" {
    if (Test-CommandAvailable 'nvidia-smi') {
        Write-Sub "nvidia-smi"
        Invoke-Tool -Tool 'nvidia-smi' -ToolArgs @('--query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu', '--format=csv')
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6d8cf5a6c9945be5')
        if ($IsWindows) {
            $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
            if ($vc) {
                $vc | ForEach-Object {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5af1f9a8e9d365d6' -FormatValues ($_.Name) -FormatBindings @{ name = '0' })
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_0322fcdddd1a1ac9' -FormatValues ($_.DriverVersion) -FormatBindings @{ driverVersion = '0' })
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_fa51b7fe133151e7' -FormatValues ((Format-ByteCount ([double]$_.AdapterRAM))) -FormatBindings @{ adapterRAM = '0' })
                    Write-Output ""
                }
            }
        } elseif ($IsMacOS) {
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_86af45ab06fb8dac')
            $out = & '/usr/sbin/system_profiler' SPDisplaysDataType 2>$null
            $out | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
        } elseif ($IsLinux) {
            if (Test-CommandAvailable 'lspci') {
                Write-Sub "lspci -nnk | grep -A2 -E 'VGA|3D|Display'"
                $inGpu = $false
                foreach ($line in (& lspci -nnk 2>$null)) {
                    if ($line -match '^\S') { $inGpu = $line -match 'VGA|3D|Display' }
                    if ($inGpu) { Write-Output $line }
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_af3b08b6cf7fc2be')
            }
        }
    }
    }

    # --- REGION: 6. Network
    Invoke-DiagnosticSection "NETWORK" {
    if ($IsWindows) {
        Write-Sub "Get-NetIPAddress (IPv4)"
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Select-Object IPAddress, InterfaceAlias, PrefixLength, AddressState |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d9b96add0edcb040')
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1 | Format-List | Out-String | ForEach-Object { Write-Output $_ }
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_7cf438f650a43df4')
        Write-VirtualSwitchFingerprint
    } else {
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_622708460ec0912c')
        if ($IsMacOS) {
            & /sbin/ifconfig 2>$null | Out-String | ForEach-Object { Write-Output $_ }
        } else {
            Invoke-Tool -Tool 'ip' -ToolArgs @('-brief','addr')
        }
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d9b96add0edcb040')
        if ($IsMacOS) {
            Invoke-Tool -Tool '/sbin/route' -ToolArgs @('-n','get','default')
        } else {
            Invoke-Tool -Tool 'ip' -ToolArgs @('-4','route','show','default')
            # The lease behind the default route is what dates a host address
            # change: a move at the lease's expiry is a renewal that did not
            # take effect, a move anywhere else is a link event or a reboot. The
            # address log alone cannot tell the two apart, and nmcli states the
            # lease length, its expiry and the granting server unprivileged.
            if ((Test-CommandAvailable 'nmcli') -and (Test-CommandAvailable 'ip')) {
                $defaultRoute = (& ip -4 route show default 2>$null) -join ' '
                if ($defaultRoute -match '\bdev\s+(\S+)') {
                    $defaultDevice = $Matches[1]
                    Write-Sub (Format-YurunaOperatorMessage -Key 'automation.network_dhcp_lease' -Arguments @{ device = "$defaultDevice" })
                    Invoke-Tool -Tool 'nmcli' -ToolArgs @('-f','GENERAL.DEVICE,GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,DHCP4','device','show',$defaultDevice)
                }
            }
        }
    }
    # --- REGION: DHCP wire capture readiness
    # tcpdump opens a bridge only while it holds CAP_NET_RAW, a property of the binary
    # that a package upgrade silently removes. Checking here turns a silent gap into a
    # fix the operator can make before the post-mortem needs it.
    # See https://yuruna.link/4213a0b3-01b3
    if ($IsLinux) {
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_bd1f98629ef68eb5')
        $tcpdumpCmd = Get-Command 'tcpdump' -ErrorAction SilentlyContinue
        if (-not $tcpdumpCmd) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5240a16c69305911')
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_f7d6f1dda37c2a27') -Class 'NETWORK.dhcp-capture-unavailable'
        } else {
            # getcap ships in /usr/sbin, which is off the PATH of an ordinary
            # login on several distributions. Resolving it by name alone would
            # report "unknown" on hosts that have it, so the known location is
            # tried second -- the probe has to resolve the tool the same way
            # the tool's own package puts it there.
            $getcapPath = (Get-Command 'getcap' -ErrorAction SilentlyContinue)?.Source
            if (-not $getcapPath -and (Test-Path -LiteralPath '/usr/sbin/getcap')) { $getcapPath = '/usr/sbin/getcap' }
            $capText = ''
            if ($getcapPath) {
                try {
                    $capText = (& $getcapPath $tcpdumpCmd.Source 2>$null | Out-String).Trim()
                } catch { $capText = '' }
            }
            if ($capText -match 'cap_net_raw') {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_11a394b95b2cb142' -FormatValues ($capText) -FormatBindings @{ capText = '0' })
            } elseif (-not $getcapPath) {
                # No getcap means no verdict, not a failing one. Saying so
                # keeps a host with libcap absent from reading as a host that
                # was checked and found wanting.
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_1bc33fa48746dd65' -Arguments @{ source = "$($tcpdumpCmd.Source)" })
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_601b6a8a371d20bf' -Arguments @{ source = "$($tcpdumpCmd.Source)" })
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_72e2cb646e4c4115') -Class 'NETWORK.dhcp-capture-ungranted'
            }
        }
    }
    Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_4fbb64b5bef0972c')
    try {
        $r = [System.Net.Dns]::GetHostAddresses('one.one.one.one')
        if ($r) { $r | ForEach-Object { Write-Output ("  {0}" -f $_.IPAddressToString) } }
    } catch {
        Write-Output "  FAILED: $($_.Exception.Message)"
        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_77bedab7a23f0549') -Class 'NETWORK.dns-unavailable'
    }

    Write-Sub "Connectivity"

    # --- REGION: https://yuruna.link/423ef7f5-0005
    $proxyUrl  = $null
    $proxyHost = $null
    $proxyPort = 0
    foreach ($v in 'https_proxy','HTTPS_PROXY','http_proxy','HTTP_PROXY') {
        $val = [System.Environment]::GetEnvironmentVariable($v)
        if ($val) {
            try {
                $u = [Uri]$val
                if ($u.Host) {
                    $proxyUrl  = $val
                    $proxyHost = $u.Host
                    $proxyPort = if ($u.Port -gt 0) { $u.Port } else { 3128 }
                    break
                }
            } catch { $null = $_ }
        }
    }

    # Gate probe: prove we can reach the proxy (if set) or the public
    # internet (if not) before launching the full endpoint matrix.
    $gateHost = if ($proxyUrl) { $proxyHost } else { '8.8.8.8' }
    $gatePort = if ($proxyUrl) { $proxyPort } else { 443 }
    $gateOk = $false
    $gateRejected = $false
    $gateMsg = $null
    try {
        $gateClient = [System.Net.Sockets.TcpClient]::new()
        try {
            $gateAsync = $gateClient.BeginConnect($gateHost, $gatePort, $null, $null)
            if ($gateAsync.AsyncWaitHandle.WaitOne(1500)) {
                try {
                    $gateClient.EndConnect($gateAsync)
                    $gateOk = $true
                } catch [System.Net.Sockets.SocketException] {
                    if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) {
                        $gateRejected = $true
                    }
                    $gateMsg = $_.Exception.Message
                }
            } else {
                $gateMsg = "no response in 1500 ms"
            }
        } finally { $gateClient.Dispose() }
    } catch { $gateMsg = $_.Exception.Message }

    if (-not $gateOk) {
        if ($proxyUrl) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6e7a5d7d1bd2a516' -Arguments @{ proxyHost = "${proxyHost}"; proxyPort = "${proxyPort}"; gateMsg = "$gateMsg" })
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_8b61ddee871d0168' -Arguments @{ proxyHost = "${proxyHost}"; proxyPort = "${proxyPort}"; gateMsg = "$gateMsg" }) -Class 'NETWORK.egress-unavailable'
        } elseif ($gateRejected) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ac0d79bc35b11ca4')
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_fdfd8304afedfbc9') -Class 'NETWORK.egress-unavailable'
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3411f56fc66f3ed9')
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_16bb848a48f76f9d' -Arguments @{ gateMsg = "$gateMsg" }) -Class 'NETWORK.egress-unavailable'
        }
    } else {
        $connectivityEndpoints = @(
            # Sites Yuruna depends on
            '8.8.8.8',
            'ports.ubuntu.com',
            'archive.ubuntu.com',
            'registry.k8s.io',
            'mirror.gcr.io',
            'ghcr.io',
            'pkg.dev',
            'github.com',
            'security.ubuntu.com',
            'registry.opentofu.org',
            'download.docker.com',
            'pkgs.k8s.io',
            'packages.opentofu.org',
            'mcr.microsoft.com',

            # AWS EC2 regional service endpoints
            'ec2.us-east-1.amazonaws.com',
            'ec2.us-west-2.amazonaws.com',
            'ec2.eu-west-1.amazonaws.com',

            # Azure core infrastructure endpoints
            'eastus.blob.core.windows.net',
            'lgmsapewus2.blob.core.windows.net',
            'lgmsapeweu.blob.core.windows.net',

            # Google Cloud Storage locational endpoints
            'us-central1-storage.googleapis.com',
            'us-east1-storage.googleapis.com',
            'europe-west1-storage.googleapis.com'
        )

        if ($proxyUrl) {
            # --- REGION: https://yuruna.link/423ef7f5-0005
            Write-Output ((Format-YurunaOperatorMessage -Key 'automation.operator_886f4b1b1e46bc84' -Arguments @{ proxyHost = "${proxyHost}"; proxyPort = "${proxyPort}" } -FormatValues ($proxyUrl) -FormatBindings @{ proxyUrl = '0' }))
            $probeTimeoutMs = 4000
            $probeDeadline  = [System.Environment]::TickCount + $probeTimeoutMs

            # Phase 1: kick TCP connects to the proxy for every target.
            $probes = foreach ($t in $connectivityEndpoints) {
                $entry = [pscustomobject]@{
                    Target       = $t
                    RTT          = $null
                    Status       = $null
                    Client       = $null
                    ConnectAsync = $null
                    Stream       = $null
                    ReadBuf      = $null
                    ReadAsync    = $null
                    StartTick    = [System.Environment]::TickCount
                    Stage        = 'Connecting'
                }
                try {
                    $entry.Client = [System.Net.Sockets.TcpClient]::new()
                    $entry.ConnectAsync = $entry.Client.BeginConnect($proxyHost, $proxyPort, $null, $null)
                } catch {
                    $entry.Stage  = 'Failed'
                    $entry.Status = "proxy connect start failed: $($_.Exception.Message)"
                    if ($entry.Client) { try { $entry.Client.Dispose() } catch { $null = $_ } }
                    $entry.Client = $null
                }
                $entry
            }

            # Phase 2: as each proxy-TCP completes, send CONNECT and kick the read.
            foreach ($p in ($probes | Where-Object { $_.Stage -eq 'Connecting' })) {
                $remain = $probeDeadline - [System.Environment]::TickCount
                if ($remain -lt 0) { $remain = 0 }
                try {
                    if ($p.ConnectAsync.AsyncWaitHandle.WaitOne($remain)) {
                        $p.Client.EndConnect($p.ConnectAsync)
                        $p.Stream = $p.Client.GetStream()
                        $req = "CONNECT $($p.Target):443 HTTP/1.1`r`nHost: $($p.Target):443`r`nProxy-Connection: close`r`n`r`n"
                        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
                        $p.Stream.Write($bytes, 0, $bytes.Length)
                        $p.ReadBuf   = New-Object byte[] 1024
                        $p.ReadAsync = $p.Stream.BeginRead($p.ReadBuf, 0, $p.ReadBuf.Length, $null, $null)
                        $p.Stage     = 'Reading'
                    } else {
                        $p.Stage  = 'Failed'
                        $p.Status = "proxy TCP timeout (>${probeTimeoutMs} ms)"
                        try { $p.Client.Dispose() } catch { $null = $_ }
                    }
                } catch {
                    $p.Stage  = 'Failed'
                    $p.Status = "proxy TCP failed"
                    try { $p.Client.Dispose() } catch { $null = $_ }
                }
            }

            # Phase 3: collect proxy CONNECT responses.
            foreach ($p in ($probes | Where-Object { $_.Stage -eq 'Reading' })) {
                $remain = $probeDeadline - [System.Environment]::TickCount
                if ($remain -lt 0) { $remain = 0 }
                try {
                    if ($p.ReadAsync.AsyncWaitHandle.WaitOne($remain)) {
                        $n = $p.Stream.EndRead($p.ReadAsync)
                        if ($n -gt 0) {
                            $resp = [System.Text.Encoding]::ASCII.GetString($p.ReadBuf, 0, $n)
                            $firstLine = ($resp -split "`r`n", 2)[0]
                            $parts = $firstLine -split '\s+', 3
                            if ($parts.Count -ge 2 -and $parts[0] -match '^HTTP/\d\.\d$' -and $parts[1] -match '^\d{3}$') {
                                $code = $parts[1]
                                $reason = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                                if ($code -eq '200') {
                                    $p.RTT    = [System.Environment]::TickCount - $p.StartTick
                                    $p.Status = "$($p.RTT) ms"
                                } else {
                                    $p.Status = ("proxy $code $reason").Trim()
                                }
                            } else {
                                $p.Status = "proxy bad reply"
                            }
                        } else {
                            $p.Status = "proxy closed (no bytes)"
                        }
                    } else {
                        $p.Status = "proxy reply timeout (>${probeTimeoutMs} ms)"
                    }
                } catch {
                    $p.Status = "proxy read failed"
                } finally {
                    try { $p.Stream.Dispose() } catch { $null = $_ }
                    try { $p.Client.Dispose() } catch { $null = $_ }
                }
            }

            $connectResults = $probes | ForEach-Object {
                [pscustomobject]@{ Target = $_.Target; RTT = $_.RTT; Status = $_.Status }
            }
        } else {
            # No env proxy: hit each target directly on TCP/443 in parallel.
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a352a82ac44d9d01')
            $connectTimeoutMs = 2500
            $connectDeadline = [System.Environment]::TickCount + $connectTimeoutMs

            $connectProbes = foreach ($t in $connectivityEndpoints) {
                $client = $null
                $async  = $null
                $startErr = $null
                try {
                    $client = [System.Net.Sockets.TcpClient]::new()
                    $async  = $client.BeginConnect($t, 443, $null, $null)
                } catch {
                    $startErr = $_.Exception.Message
                    if ($client) { try { $client.Dispose() } catch { $null = $_ } }
                    $client = $null
                    $async  = $null
                }
                [pscustomobject]@{
                    Target     = $t
                    Client     = $client
                    Async      = $async
                    StartTick  = [System.Environment]::TickCount
                    StartError = $startErr
                }
            }

            $connectResults = foreach ($p in $connectProbes) {
                $status = $null
                $rttMs  = $null
                if ($p.StartError) {
                    $status = "start failed: $($p.StartError)"
                } elseif (-not $p.Async) {
                    $status = "couldn't connect"
                } else {
                    $remain = $connectDeadline - [System.Environment]::TickCount
                    if ($remain -lt 0) { $remain = 0 }
                    try {
                        if ($p.Async.AsyncWaitHandle.WaitOne($remain)) {
                            $p.Client.EndConnect($p.Async)
                            $rttMs  = [System.Environment]::TickCount - $p.StartTick
                            $status = "${rttMs} ms"
                        } else {
                            $status = "timeout (>${connectTimeoutMs} ms)"
                        }
                    } catch {
                        $status = "couldn't connect"
                    } finally {
                        try { $p.Client.Dispose() } catch { $null = $_ }
                    }
                }
                [pscustomobject]@{
                    Target = $p.Target
                    RTT    = $rttMs
                    Status = $status
                }
            }
        }

        $connectResults |
            Sort-Object @{ Expression = { if ($null -eq $_.RTT) { [int]::MaxValue } else { $_.RTT } } }, Target |
            Select-Object Target, Status |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }

        $connectFailures = @($connectResults | Where-Object { $null -eq $_.RTT })
        if ($connectFailures.Count -gt 0) {
            $failedTargets = (@($connectFailures | ForEach-Object { [string]$_.Target }) -join ', ')
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_b6be1dbdabe6cc70' -Arguments @{
                count = [string]$connectFailures.Count
                count2 = [string]$connectResults.Count
                join = $failedTargets
            }) -Class 'NETWORK.endpoint-unavailable'
        }

        # --- REGION: https://yuruna.link/423ef7f5-0005
        # Package managers use the http_proxy GET/cache path, which wedges
        # independently of CONNECT; forced revalidation exercises the
        # proxy's upstream fetch instead of a cache hit.
        $plainProxyUrl = $null
        foreach ($v in 'http_proxy','HTTP_PROXY') {
            $val = [System.Environment]::GetEnvironmentVariable($v)
            if ($val) {
                try {
                    if (([Uri]$val).Host) { $plainProxyUrl = $val; break }
                } catch { $null = $_ }
            }
        }
        # Runs with or without a proxy. Gating this on http_proxy made it a
        # guest-only probe, and a guest that dies during OS install never runs
        # this script at all -- the host capture is then the ONLY record of
        # mirror health for that cycle, and it recorded nothing beyond a bare
        # "endpoint unreachable" line among 22 unrelated targets. Probing the
        # origins here names the failing mirror at cycle start, which is what
        # separates a broken lab from an upstream outage when the only other
        # evidence is an installer frozen on the console.
        if ($true) {
            if ($plainProxyUrl) {
                Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_8e387ee6ac99f4e6')
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5b61d37259974d2f' -FormatValues ($plainProxyUrl) -FormatBindings @{ plainProxyUrl = '0' })
            } else {
                Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_6f0c94761254ca79')
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_7381c2ff7b092be4')
            }
            # Probe the exact objects apt fetches, not a directory index. An
            # index is small, rarely revalidated, and typically answered from
            # cache in single-digit milliseconds, so it stays green while the
            # InRelease object beside it stalls -- the probe then reports this
            # path healthy during the very outage it exists to catch. The
            # release codename is read from the guest so the URL is the one
            # this guest's own apt requests.
            $codename = $null
            foreach ($osRelease in '/etc/os-release', '/usr/lib/os-release') {
                if (-not (Test-Path -LiteralPath $osRelease)) { continue }
                try {
                    $line = Get-Content -LiteralPath $osRelease -ErrorAction Stop |
                        Where-Object { $_ -match '^\s*VERSION_CODENAME\s*=' } |
                        Select-Object -First 1
                    if ($line) { $codename = ($line -split '=', 2)[1].Trim().Trim('"') }
                } catch { $null = $_ }
                if ($codename) { break }
            }
            $plainTargets = if ($codename) {
                @(
                    "http://ports.ubuntu.com/ubuntu-ports/dists/$codename/InRelease",
                    "http://archive.ubuntu.com/ubuntu/dists/$codename/InRelease",
                    "http://security.ubuntu.com/ubuntu/dists/$codename-security/InRelease"
                )
            } else {
                # No codename to build an object URL from (non-Ubuntu host or
                # guest). The index still proves the origin answers, but it
                # cannot exercise the object path, so it is weaker evidence.
                @(
                    'http://ports.ubuntu.com/ubuntu-ports/dists/',
                    'http://archive.ubuntu.com/ubuntu/dists/',
                    'http://security.ubuntu.com/ubuntu/dists/'
                )
            }
            # Emitted AFTER the assignment, never inside it: a Write-Output in
            # either branch of an `if` used as an expression becomes part of the
            # assigned value, so the note itself would be added to the target
            # list and then probed as a URL -- reported as a failed origin.
            if (-not $codename) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e22147108d6ae87f')
            }
            # One SHARED 10s budget across all targets, like the CONNECT
            # matrix's shared deadline above: the diagnostic runs inside a
            # per-SSH-command wall cap, and three independent 10s timeouts
            # burning serially against a wedged proxy could push the whole
            # capture past that cap and lose the artifact in exactly the
            # scenario this probe exists to diagnose.
            $plainFailures = @()
            # Slow IS the failure mode here: apt blocks on this fetch, so an
            # origin answering in tens of seconds exhausts a step's timeout just
            # as surely as one that never answers. Printing "HTTP 200" for a
            # 22-second fetch and calling the path healthy hides the outage.
            $plainSlow      = @()
            $plainSlowMs    = 5000
            $plainDeadline  = [System.Environment]::TickCount + 10000
            # A per-target cap as well as the shared deadline: without it the
            # first stalled origin eats the whole budget and the rest report
            # SKIPPED, losing the healthy-vs-stalled comparison across origins
            # that separates one bad mirror from a wedged proxy.
            $plainPerTargetMs = 4000
            foreach ($t in $plainTargets) {
                $remainMs = $plainDeadline - [System.Environment]::TickCount
                if ($remainMs -lt 1000) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_7062ead52be3e83c' -FormatValues ($t) -FormatBindings @{ t = '0,-64' })
                    $plainFailures += $t
                    continue
                }
                $budgetMs = [math]::Min($remainMs, $plainPerTargetMs)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    # -Proxy only when one is configured: passing $null selects
                    # the system proxy rather than "no proxy", which would make
                    # the direct/proxied distinction this probe reports untrue.
                    $probeArgs = @{
                        Uri             = $t
                        UseBasicParsing = $true
                        TimeoutSec      = [int][math]::Ceiling($budgetMs / 1000)
                        Headers         = @{ 'Cache-Control' = 'no-cache' }
                        ErrorAction     = 'Stop'
                    }
                    if ($plainProxyUrl) { $probeArgs['Proxy'] = $plainProxyUrl }
                    $resp = Invoke-WebRequest @probeArgs
                    $sw.Stop()
                    # A cache HIT means the upstream was never contacted, so the
                    # elapsed time says nothing about origin health. Surface the
                    # header so a fast number is not read as proof the mirror is
                    # reachable -- that misreading is what makes this probe look
                    # green while package fetches hang.
                    $cacheNote = ''
                    foreach ($h in 'X-Cache', 'X-Cache-Lookup') {
                        $key = @($resp.Headers.Keys) | Where-Object { $_ -ieq $h } | Select-Object -First 1
                        if ($key) { $cacheNote = " [{0}: {1}]" -f $key, (@($resp.Headers[$key]) -join ','); break }
                    }
                    $slowNote = if ($sw.ElapsedMilliseconds -ge $plainSlowMs) { '  <-- SLOW' } else { '' }
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_dba4f2e3a437938b' -FormatValues ($t, [int]$resp.StatusCode, $resp.RawContentLength, $sw.ElapsedMilliseconds, $cacheNote, $slowNote) -FormatBindings @{ t = '0,-64'; statusCode = '1'; rawContentLength = '2'; elapsedMilliseconds = '3'; cacheNote = '4'; slowNote = '5' })
                    if ($sw.ElapsedMilliseconds -ge $plainSlowMs) { $plainSlow += $t }
                } catch {
                    $sw.Stop()
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f18af6f34851269c' -FormatValues ($t, $sw.ElapsedMilliseconds, $_.Exception.Message) -FormatBindings @{ t = '0,-64'; elapsedMilliseconds = '1'; message = '2' })
                    $plainFailures += $t
                }
            }
            # Name the path in the problem text. "mirror unreachable" means very
            # different things depending on whether the request went through the
            # cache or straight out, and the reader of a problems summary has no
            # other way to tell which was measured.
            $plainPathLabel = if ($plainProxyUrl) { "the caching proxy at $plainProxyUrl" } else { 'a direct connection (no http_proxy)' }
            if ($plainFailures.Count -gt 0) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_b5f48e0638856581' -FormatValues ($plainPathLabel, $plainFailures.Count, $plainTargets.Count, ($plainFailures -join ', ')) -FormatBindings @{ plainPathLabel = '0'; count = '1'; count2 = '2'; join = '3' }) -Class 'NETWORK.package-mirror-unavailable'
            }
            if ($plainSlow.Count -gt 0) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_d34d1a36cb2cfedc' -FormatValues ($plainPathLabel, [int]($plainSlowMs / 1000), $plainSlow.Count, $plainTargets.Count, ($plainSlow -join ', ')) -FormatBindings @{ plainPathLabel = '0'; plainSlowMs = '1'; count = '2'; count2 = '3'; join = '4' }) -Class 'NETWORK.package-mirror-slow'
            }
        }

        # --- REGION: https://yuruna.link/423ef7f5-0006
        # See ../docs/caching.md#probing-pull-through-liveness-needs-a-manifest-request-not-get-v2
        # for why a manifest request (not GET /v2/) is the liveness probe. -- Get-SystemDiagnostic.ps1
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d76c7f8316e11dcf')
        $cacheHost = $null
        if ($plainProxyUrl) {
            try { $cacheHost = ([Uri]$plainProxyUrl).Host } catch { $null = $_ }
        }
        # The runner host has no http_proxy of its own but knows the cache it
        # hands its guests, and a guest keeps the same address in host.env;
        # either names the registry this diagnostic should still probe.
        if (-not $cacheHost) {
            $envCacheHost = [string][System.Environment]::GetEnvironmentVariable('YURUNA_CACHING_PROXY_SERVICE_IP')
            if (-not $envCacheHost -and -not $IsWindows -and (Test-Path -LiteralPath '/etc/yuruna/host.env' -PathType Leaf)) {
                try {
                    $envLine = Get-Content -LiteralPath '/etc/yuruna/host.env' -ErrorAction Stop |
                        Where-Object { $_ -match '^YURUNA_CACHING_PROXY_SERVICE_IP=(\S+)' } | Select-Object -First 1
                    if ($envLine -match '^YURUNA_CACHING_PROXY_SERVICE_IP=(\S+)') { $envCacheHost = $Matches[1] }
                } catch { $null = $_ }
            }
            $envCacheHost = $envCacheHost.Trim().Trim('"', "'")
            if ($envCacheHost -and [Uri]::CheckHostName($envCacheHost) -ne [UriHostNameType]::Unknown) { $cacheHost = $envCacheHost }
        }
        if (-not $cacheHost) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d67ba5d3e55b2ade')
        } else {
            $registryBase   = "http://${cacheHost}:5000"
            $canaryRepo     = 'library/registry'
            $canaryTag      = '2'
            # A registry answers a manifest request that states no preference
            # with whatever it considers the default, which for a multi-arch tag
            # is not the index a pull resolves.
            $canaryAccept   = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
            $registryCapSec = 15
            # Well under the cap: a warm cache answers in well under a second, so
            # seconds already means the upstream leg is being walked.
            $registrySlowMs = 3000

            # -NoProxy on both: the runtime pulls straight at the cache, so a
            # probe routed through the proxy would time a path no pull takes --
            # and the proxy refuses CONNECT to this port anyway, which would read
            # as a dead cache.
            $livenessMs = $null
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $null = Invoke-WebRequest -Uri "$registryBase/v2/" -UseBasicParsing -NoProxy `
                    -TimeoutSec 10 -ErrorAction Stop
                $sw.Stop()
                $livenessMs = $sw.ElapsedMilliseconds
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_8b1cc72a282b2b00' -FormatValues ("$registryBase/v2/", $livenessMs) -FormatBindings @{ v2 = '0,-52'; livenessMs = '1' })
            } catch {
                $sw.Stop()
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3d4ee76ddb60efa9' -FormatValues ("$registryBase/v2/", $sw.ElapsedMilliseconds, $_.Exception.Message) -FormatBindings @{ v2 = '0,-52'; elapsedMilliseconds = '1'; message = '2' })
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_9504b598bf631fce' -FormatValues ($registryBase) -FormatBindings @{ registryBase = '0' }) -Class 'REGISTRY.unavailable'
            }

            # Prefer the cache's own published reading over measuring here: a manifest
            # request spends a pull from the per-egress-IP budget the whole lab shares.
            # See https://yuruna.link/423ef7f5-0006
            $healthUrl  = "http://${cacheHost}/cache-health"
            $healthText = $null
            try {
                # -SkipHttpErrorCheck because "no health page" is the EXPECTED
                # answer from a cache that predates one, and letting a 404 raise
                # would spill the server's error-page HTML and a terminating-error
                # record into a capture whose whole value is being readable.
                $healthResp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -NoProxy `
                    -SkipHttpErrorCheck -TimeoutSec 5 -ErrorAction Stop
                if ([int]$healthResp.StatusCode -eq 200) {
                    # Content comes back as a byte[] whenever the response carries
                    # no text/* content type, which is what a web server returns
                    # for an extensionless file. Casting that array to string
                    # yields its decimal byte values space-joined -- a page of
                    # numbers where the reading should be, and every match below
                    # silently fails against it, so the problems summary goes
                    # quiet exactly when the cache has something to report.
                    $healthText = if ($healthResp.Content -is [byte[]]) {
                        [System.Text.Encoding]::UTF8.GetString($healthResp.Content)
                    } else {
                        [string]$healthResp.Content
                    }
                }
            } catch { $null = $_ }

            # The same exporter publishes these readings twice, and this is the
            # machine copy. Classification reads it; the page above is printed
            # for a person and is free to be reworded or translated without
            # taking the problems summary quiet with it.
            $metaUrl = "http://${cacheHost}/zot-meta"
            $metaText = $null
            try {
                $metaResp = Invoke-WebRequest -Uri $metaUrl -UseBasicParsing -NoProxy `
                    -SkipHttpErrorCheck -TimeoutSec 5 -ErrorAction Stop
                if ([int]$metaResp.StatusCode -eq 200) {
                    $metaText = if ($metaResp.Content -is [byte[]]) {
                        [System.Text.Encoding]::UTF8.GetString($metaResp.Content)
                    } else {
                        [string]$metaResp.Content
                    }
                }
            } catch { $null = $_ }

            if ($healthText) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6adf8d997a5873b0' -Arguments @{ healthUrl = "$healthUrl" })
                foreach ($line in ($healthText -split "`r?`n")) { Write-Output "    $line" }

                if (-not $metaText) {
                    # Both documents come from one exporter, so a cache serving
                    # the page and not the metrics is a state worth naming
                    # rather than classifying from the prose anyway.
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_2ef2b00d42a09705' -FormatValues ($metaUrl) -FormatBindings @{ metaUrl = '0' }) `
                        -Class 'REGISTRY.metrics-unavailable'
                } else {
                    $reading = Get-PrometheusReading -Text $metaText
                    # First: an incompatible zot release explains every refusal
                    # and short warm set that the readings below report.
                    foreach ($zotProblem in (Get-ZotSelfTestProblem -Reading $reading -HealthUrl $healthUrl)) {
                        Add-Problem $zotProblem.Message -Class $zotProblem.Class
                    }
                    $manifestOk = Get-PrometheusValue -Reading $reading -Name 'yuruna_zot_manifest_ok'
                    $underPatience = Get-PrometheusValue -Reading $reading -Name 'yuruna_zot_manifest_ok_under_client_patience'
                    $probeCap = Get-PrometheusValue -Reading $reading -Name 'yuruna_zot_manifest_probe_timeout_seconds'
                    $patience = Get-PrometheusValue -Reading $reading -Name 'yuruna_zot_manifest_client_patience_seconds'
                    $latencyRows = @($reading['yuruna_zot_manifest_latency_seconds'])
                    $latency = if ($latencyRows.Count -eq 1) { [double]$latencyRows[0].Value } else { $null }

                    # A stall reads as a slow SUCCESS everywhere else in the
                    # stack, so the number has to be lifted into the problems
                    # summary or a reader has no reason to look at it.
                    if ($null -ne $manifestOk -and $manifestOk -eq 0) {
                        if ($null -ne $latency -and $null -ne $probeCap -and $latency -ge $probeCap) {
                            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_7547f4a3d66ac1fb' -FormatValues ($probeCap) -FormatBindings @{ probeCap = '0' }) `
                                -Class 'REGISTRY.manifest-unavailable'
                        } else {
                            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_bd5b8edfeeb6c8d5' -FormatValues ($(if ($null -ne $latency) { " (answered in ${latency}s)" } else { '' })) -FormatBindings @{ else = '0' }) `
                                -Class 'REGISTRY.manifest-unavailable'
                        }
                    } elseif ($null -ne $underPatience -and $underPatience -eq 0) {
                        # The exporter computes this verdict itself: the answer
                        # arrived, but later than a real pull waits. Deriving it
                        # here from a threshold of our own would be a second
                        # opinion about the cache's own measurement.
                        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_d7dcae6d696a3bf3' -FormatValues ($(if ($null -ne $latency) { $latency } else { 'an unrecorded number of' }),
                            $(if ($null -ne $patience) { $patience } else { 'the client patience' })) -FormatBindings @{ of = '0'; patience = '1' }) `
                            -Class 'REGISTRY.manifest-slow'
                    }

                    # Residency is the only reading here that can show a COLD
                    # cache. The manifest timings above walk a tag the cache
                    # keeps resident, so they stay fast while an image a guest
                    # is about to pull is still being copied from upstream --
                    # the state in which a provisioning run spends its whole
                    # step budget and then reports a bare timeout.
                    $residencyShortfalls = Get-RegistryResidencyShortfall -Reading $reading
                    foreach ($short in $residencyShortfalls) {
                        if ($short.Refused -gt 0 -and $short.Statuses) {
                            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_registry_images_refused' -Arguments @{
                                    refused = "$($short.Refused)"; total = "$($short.Total)"; set = "$($short.Set)"; statuses = "$($short.Statuses)" }) `
                                -Class 'REGISTRY.image-set-refused'
                        } elseif ($short.Refused -gt 0) {
                            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_registry_images_refused_status_unknown' -Arguments @{
                                    refused = "$($short.Refused)"; total = "$($short.Total)"; set = "$($short.Set)" }) `
                                -Class 'REGISTRY.image-set-refused'
                        }
                        if ($short.Copying -gt 0) {
                            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_5376c9efd7b38f35' -FormatValues ($short.Held, $short.Total, $short.Set, $short.Copying) -FormatBindings @{ held = '0'; total = '1'; set = '2'; cold = '3' }) -Class 'REGISTRY.image-set-incomplete'
                        }
                    }

                    # probe_ok separates "the budget is spent" from "we could not
                    # read the budget". The prose could not tell those apart, so
                    # a cache that never managed to ask looked identical to one
                    # with nothing left.
                    $budgetProbeOk = Get-PrometheusValue -Reading $reading -Name 'yuruna_dockerhub_ratelimit_probe_ok'
                    $budgetLeft = Get-PrometheusValue -Reading $reading -Name 'yuruna_dockerhub_ratelimit_remaining'
                    $budgetLimit = Get-PrometheusValue -Reading $reading -Name 'yuruna_dockerhub_ratelimit_limit'
                    if ($null -ne $budgetProbeOk -and $budgetProbeOk -eq 1 -and
                        $null -ne $budgetLeft -and $budgetLeft -le 0) {
                        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_b882a1d97c6d1e64' -FormatValues ($(if ($null -ne $budgetLimit) { [int]$budgetLimit } else { 'its limit' })) -FormatBindings @{ limit = '0' }) `
                            -Class 'REGISTRY.upstream-budget-exhausted'
                    }
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_1cdaae68f0f030a5' -Arguments @{ healthUrl = "$healthUrl" })
                $canaryUrl = "$registryBase/v2/$canaryRepo/manifests/$canaryTag"
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $null = Invoke-WebRequest -Uri $canaryUrl -Method Head -UseBasicParsing -NoProxy `
                        -Headers @{ Accept = $canaryAccept } -TimeoutSec $registryCapSec -ErrorAction Stop
                    $sw.Stop()
                    $slowNote = if ($sw.ElapsedMilliseconds -ge $registrySlowMs) { '  <-- SLOW' } else { '' }
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e043073e5c3e6d7a' -FormatValues ("manifest $canaryRepo`:$canaryTag", $sw.ElapsedMilliseconds, $slowNote) -FormatBindings @{ canaryTag = '0,-52'; elapsedMilliseconds = '1'; slowNote = '2' })
                    if ($sw.ElapsedMilliseconds -ge $registrySlowMs) {
                        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_7734067755bb03df' -FormatValues ($sw.ElapsedMilliseconds, $(if ($null -ne $livenessMs) { $livenessMs } else { 'n/a' })) -FormatBindings @{ elapsedMilliseconds = '0'; a = '1' }) -Class 'REGISTRY.manifest-slow'
                    }
                } catch {
                    $sw.Stop()
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6fc61f0366ccc45e' -FormatValues ("manifest $canaryRepo`:$canaryTag", $sw.ElapsedMilliseconds, $registryCapSec, $_.Exception.Message) -FormatBindings @{ canaryTag = '0,-52'; elapsedMilliseconds = '1'; registryCapSec = '2'; message = '3' })
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_0309d6a5040c85c6' -FormatValues ($registryCapSec, $(if ($null -ne $livenessMs) { "healthy at $livenessMs ms" } else { 'also failing' })) -FormatBindings @{ registryCapSec = '0'; failing = '1' }) -Class 'REGISTRY.manifest-unavailable'
                }
            }

            # Where pulls are POINTED, next to whether that target works. Read
            # from the machine rather than inferred from what provisioning
            # intended to write: a daemon that never reloaded, or a drop-in that
            # routes registry traffic through the proxy, looks identical from the
            # outside and changes the meaning of every timing above.
            $registryConfigFiles = @()
            foreach ($p in '/etc/docker/daemon.json') {
                if (Test-Path -LiteralPath $p) { $registryConfigFiles += $p }
            }
            foreach ($globPath in '/etc/containerd/certs.d/*/hosts.toml', '/etc/systemd/system/docker.service.d/*.conf') {
                try {
                    $registryConfigFiles += @(Get-ChildItem -Path $globPath -File -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty FullName)
                } catch { $null = $_ }
            }
            if ($registryConfigFiles.Count -eq 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f6c3acdbc6bb49a8')
            } else {
                foreach ($cf in $registryConfigFiles) {
                    Write-Output "  --- $cf ---"
                    try {
                        Get-Content -LiteralPath $cf -TotalCount 40 -ErrorAction Stop |
                            ForEach-Object { Write-Output "    $_" }
                    } catch {
                        Write-Output "    (unreadable: $($_.Exception.Message))"
                    }
                }
            }
        }

        # apt's effective Acquire settings decide how long a stalled mirror can
        # hold a step open, so they belong in the capture beside the mirror
        # timings above. Without them, a guest that hung in apt cannot be told
        # apart from one whose retry/timeout config never reached it -- the two
        # look identical in every other artifact and need opposite fixes.
        # apt-config reports the MERGED view across /etc/apt/apt.conf.d, which
        # is the only thing that answers "what will apt actually do here".
        if (Get-Command apt-config -ErrorAction SilentlyContinue) {
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_e7aa118c776ef4a7')
            $aptKeys = @('Acquire::Retries', 'Acquire::http::Timeout', 'Acquire::https::Timeout',
                         'Acquire::http::Proxy', 'Acquire::https::Proxy', 'Acquire::Languages')
            try {
                # 2>$null: apt-config writes locale/permission chatter to stderr
                # on some guests, which would otherwise land mid-table.
                $aptDump = @(& apt-config dump 2>$null)
                foreach ($k in $aptKeys) {
                    # Prefix match with the '::' boundary so Acquire::Languages
                    # also catches its list form (Acquire::Languages:: "en";).
                    $hits = @($aptDump | Where-Object { $_ -like "$k *" -or $_ -like "${k}:: *" })
                    if ($hits.Count -gt 0) {
                        foreach ($h in $hits) { Write-Output ("  {0}" -f $h) }
                    } else {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e6f4dbb4910837d1' -FormatValues ($k) -FormatBindings @{ k = '0,-28' })
                    }
                }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_92d670bc7925ddf3' -Arguments @{ message = "$($_.Exception.Message)" })
            }
        }
    }
    }

    # --- REGION: 7. Top processes
    Invoke-DiagnosticSection "TOP PROCESSES" {
    Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_1a3e3a5fa77346d0')
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CPU -ne $null } |
        Sort-Object CPU -Descending |
        Select-Object -First 10 |
        Select-Object @{n='PID';e={$_.Id}}, ProcessName, @{n='CPU(s)';e={[math]::Round($_.CPU,1)}}, @{n='WS(MB)';e={[math]::Round($_.WorkingSet64/1MB,1)}} |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }
    Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_f2c81ff0219bedfa')
    Get-Process -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 10 |
        Select-Object @{n='PID';e={$_.Id}}, ProcessName, @{n='WS(MB)';e={[math]::Round($_.WorkingSet64/1MB,1)}}, @{n='Threads';e={$_.Threads.Count}} |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }
    # Private bytes are a process's commit charge; the working set is only what
    # of it is resident. A process that leaks commit it never touches again
    # stays out of the working-set table while it drives the host toward
    # refusing VM starts, and this table names it. Commit held by shared memory
    # sections or kernel allocations is in no row; MEMORY prints how much of the
    # charge sits outside every process.
    Write-Sub (Format-YurunaOperatorMessage -Key 'automation.top_processes_private_bytes')
    Get-Process -ErrorAction SilentlyContinue |
        Sort-Object PrivateMemorySize64 -Descending |
        Select-Object -First 10 |
        Select-Object @{n='PID';e={$_.Id}}, ProcessName, @{n='Private(MB)';e={[math]::Round($_.PrivateMemorySize64/1MB,1)}}, @{n='WS(MB)';e={[math]::Round($_.WorkingSet64/1MB,1)}}, @{n='Threads';e={$_.Threads.Count}} |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }
    }

    # --- REGION: 8. Recent events
    Invoke-DiagnosticSection "RECENT SYSTEM EVENTS (errors / warnings)" {
    if ($IsWindows) {
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_17c3a371250a4683')
        try {
            $sysErr = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=2; StartTime=(Get-Date).AddHours(-1) } -ErrorAction Stop |
                Select-Object -First 15
            if ($sysErr) {
                $sysErr | Select-Object TimeCreated, Id, ProviderName, @{n='Message';e={$_.Message -replace "`r?`n",' '}} |
                    Format-Table -AutoSize -Wrap | Out-String | ForEach-Object { Write-Output $_ }
                if ($sysErr.Count -ge 5) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_d334c6088d89072e' -Arguments @{ count = "$($sysErr.Count)" }) -Class 'EVENTS.system-errors' }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6f2d0aef178bf1b3')
            }
        } catch {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b8d9c8f44a701dc0' -Arguments @{ message = "$($_.Exception.Message)" })
        }
    } elseif ($IsLinux) {
        if (Test-CommandAvailable 'journalctl') {
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_journal_access')
            Write-LinuxJournalAccess
            Write-Sub "journalctl -p err -n 20 --no-pager (since 1h ago)"
            $jc = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-p','err','-n','20','--since','1 hour ago','--no-pager')
            $count = ($jc | Measure-Object).Count
            if ($count -gt 0) {
                $jc | ForEach-Object { Write-Output $_ }
                # Every line is printed, but only lines this harness did not
                # write itself are counted. A host whose error journal is
                # nothing but its own guest-address probes is a host with no
                # problem, and reporting one there spends the operator's
                # attention on the thing that is working.
                $entries   = @($jc | Where-Object { -not (Test-JournalSeparatorLine -Line ([string]$_)) })
                $entryCount = $entries.Count
                $realCount = @($entries | Where-Object { -not (Get-JournalSelfNoiseClass -Line ([string]$_)) }).Count
                # The reconciliation line explains a number the operator can
                # see, so it is printed whenever anything was suppressed --
                # including when the problem fires. Tying it to the quiet case
                # withheld it exactly when the count is being questioned, and a
                # flagged host then showed a total with no way to tell how much
                # of it was the harness looking at itself.
                $suppressed = $entryCount - $realCount
                if ($suppressed -gt 0) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_7b7b0576c0414d06' -FormatValues ($suppressed, $entryCount) -FormatBindings @{ suppressed = '0'; entryCount = '1' })
                }
                if ($realCount -ge 10) { Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_825b1a81c52b4a7a' -Arguments @{ realCount = "$realCount" }) -Class 'EVENTS.journal-errors' }
            } else { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f06dbaaa4796a8b5') }
        } elseif (Test-Path '/var/log/syslog') {
            Write-Sub "tail /var/log/syslog (last 30 lines)"
            Get-Content '/var/log/syslog' -Tail 30 | ForEach-Object { Write-Output $_ }
        }
        # --- REGION: https://yuruna.link/423ef7f5-0015
        if ((Test-CommandAvailable 'systemctl') -and (Test-CommandAvailable 'journalctl')) {
            Write-Sub "systemctl --failed --plain, then journalctl -b -u <unit> -n 10 --no-pager for each"
            $failedRows = @(Invoke-PrivProbe -Tool 'systemctl' -ToolArgs @('--failed','--plain','--no-pager'))
            $failedRows | ForEach-Object { Write-Output $_ }
            foreach ($unit in @(Get-FailedUnitName -Line $failedRows)) {
                Write-Output "## $unit"
                Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-b','-u',$unit,'-n','10','--no-pager') |
                    ForEach-Object { Write-Output $_ }
            }
        }
    } elseif ($IsMacOS) {
        if (Test-CommandAvailable 'dmesg') {
            Write-Sub "dmesg | tail -n 30"
            try {
                $dm = & dmesg 2>$null | Select-Object -Last 30
                $dm | ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_c694f7571769d514')
            }
        }
    }

    Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_9a7a2b89b445e955')
    # Per-phase stderr.log + *.rc catalog and the -Force-required dot-dir
    # scan trap: https://yuruna.link/42e568c8
    $diagScanRoot = $script:DiagnosticEvidenceRoot
    if (-not $diagScanRoot) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.diagnostic_checkout_unavailable')
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.diagnostic_phase_log_limits')
        $phaseWalk = Get-FileTreeWithDeadline -Label 'phase log scan' -TimeoutSeconds 10 -ArgumentList @($diagScanRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -LiteralPath $root -Recurse -Depth 12 -File -Force -Filter '*.stderr.log' -ErrorAction SilentlyContinue |
                Select-Object -First 100
        }
        Show-FileTreeWalkTimeout -Walk $phaseWalk
        $phaseLogs = @($phaseWalk.Items)
        if ($phaseLogs.Count -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9cf3996f93916a8c' -Arguments @{ diagScanRoot = "$diagScanRoot" })
        } else {
            foreach ($tl in ($phaseLogs | Sort-Object FullName)) {
                $sizeNote = ''
                $content  = ''
                try {
                    if ($tl.Length -gt 64KB) {
                        $sizeNote = " (last 64 KB shown of $($tl.Length) bytes)"
                    }
                    # A tool log can hold an expanded command with its secrets.
                    $content = (Protect-DiagnosticSecretText -Line ((Get-DiagnosticFileTail -Path $tl.FullName) -split "`r?`n")) -join "`n"
                } catch {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a594feac6339b77c' -FormatValues ($tl.FullName, $_.Exception.Message) -FormatBindings @{ fullName = '0'; message = '1' })
                    continue
                }
                # Sidecar exit-code file (helm.stderr.log -> helm.rc, etc.)
                $rcSidecar = [System.IO.Path]::ChangeExtension($tl.FullName, $null).TrimEnd('.') -replace '\.stderr$', '.rc'
                $rcNote = ''
                if (Test-Path -LiteralPath $rcSidecar) {
                    $rcText = try { Get-DiagnosticFileTail -Path $rcSidecar -MaximumBytes 256 } catch { $null }
                    if ($null -ne $rcText) {
                        $rcNote = " (last rc={0})" -f $rcText.Trim()
                    }
                }
                $mtime = $tl.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
                Write-Output ''
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3a40a1163d5c3772' -FormatValues ($tl.FullName, $tl.Length, $mtime, $sizeNote, $rcNote) -FormatBindings @{ fullName = '0'; length = '1'; mtime = '2'; sizeNote = '3'; rcNote = '4' })
                if ([string]::IsNullOrWhiteSpace($content)) {
                    Write-Output '(empty)'
                } else {
                    Write-Output $content.TrimEnd()
                }
            }
        }
    }
    }

    # --- REGION: 9. Docker
    Invoke-DiagnosticSection "DOCKER" {
    if ($SkipDocker) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_57e9b1596ecdf272')
    } elseif (-not (Test-CommandAvailable 'docker')) {
        # Absence is reported, not flagged. A host that runs its container
        # workloads inside guests has no reason to carry a container runtime
        # itself, so on most of this fleet the tool is missing by design and
        # the problem fires on every cycle forever. A permanent entry is worse
        # than no entry: it costs the operator the "no problems reported"
        # branch below, which is the line that makes a real finding visible.
        # Other absent tools in this script are already reported this way.
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_92b000bbc8fbfa86')
    } else {
        # --- REGION: https://yuruna.link/423ef7f5-0002
        $dockerInfoSnapshot = @{}
        $probe = Get-DiagnosticDockerInfoProbe -Snapshot $dockerInfoSnapshot
        foreach ($line in $probe.Evidence) { Write-Output $line }
        if ($probe.TimedOut) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_883c24367a7311b4')
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_a2f93f5cc132a461') -Class 'DOCKER.probe-timeout'
        } elseif ((@($probe.Output) | Select-Object -Last 1) -ne 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e288495c99f6fc3b')
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_806ec1c40ae4b734') -Class 'DOCKER.daemon-unavailable'
        } else {
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_c31b9b429279d53c')
            Invoke-Tool -Tool 'docker' -ToolArgs @('version','--format',"Client: {{.Client.Version}} ({{.Client.Os}}/{{.Client.Arch}})`nServer: {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})") -TimeoutSeconds 5
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_bd1e95a93c4cad8e')
            $info = $dockerInfoSnapshot.Info
            if (-not $dockerInfoSnapshot.Success) {
                $infoProbe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
                    & docker info --format '{{json .}}' 2>$null
                }
                if ($infoProbe.TimedOut) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_883c24367a7311b4')
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_8e214cf40db4bf91') -Class 'DOCKER.probe-timeout'
                } else {
                    $info = ($infoProbe.Output -join "`n") | ConvertFrom-Json -ErrorAction SilentlyContinue
                }
            }
            if ($info) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_4d1c48e1fe3d437b' -FormatValues ($info.Containers, $info.ContainersRunning, $info.ContainersPaused, $info.ContainersStopped) -FormatBindings @{ containers = '0'; containersRunning = '1'; containersPaused = '2'; containersStopped = '3' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2a2ce15d34fbba77' -FormatValues ($info.Images) -FormatBindings @{ images = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_7756a95f3b0dc2f6' -FormatValues ($info.Driver) -FormatBindings @{ driver = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bbf65c9184e07ba9' -FormatValues ($info.ServerVersion) -FormatBindings @{ serverVersion = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_38b84356d9ef0785' -FormatValues ($info.CgroupDriver) -FormatBindings @{ cgroupDriver = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_4da5638570dedd1f' -FormatValues ($info.KernelVersion) -FormatBindings @{ kernelVersion = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_77fd267fe41256a8' -FormatValues ($info.OperatingSystem) -FormatBindings @{ operatingSystem = '0' })
                if ($info.Warnings -and $info.Warnings.Count -gt 0) {
                    Write-Output "Warnings:"
                    foreach ($w in $info.Warnings) { Write-Output "  - $w"; Add-Problem "DOCKER: warning -- $w" -Class 'DOCKER.warning' }
                }
            }
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d2c774924094e180')
            $dockerContainerTable = @{}
            Invoke-Tool -Tool 'docker' -ToolArgs @('ps','-a','--format','table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}') -TimeoutSeconds 5 -Snapshot $dockerContainerTable
            $dockerContainers = Get-DiagnosticDockerContainerSnapshot -Snapshot $dockerContainerTable
            $rows = @($dockerContainers.Rows)
            if (-not $dockerContainers.Success) {
                $psProbe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
                    & docker ps -a --format '{{.Names}}|{{.Status}}' 2>$null
                }
                if ($psProbe.TimedOut) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5ba0dbd55dfbc5f1')
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_078426d92d53cf65') -Class 'DOCKER.probe-timeout'
                } else {
                    $rows = @($psProbe.Output)
                }
            }
            foreach ($r in $rows) {
                $parts = $r -split '\|', 2
                if ($parts.Count -ne 2) { continue }
                $name = $parts[0]; $status = $parts[1]
                if ($status -match '^Restarting' -or $status -match 'unhealthy' -or $status -match 'Dead') {
                    Add-Problem "DOCKER: container '$name' status: $status" -Class 'DOCKER.container-unhealthy'
                }
            }
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_b191443e06072bac')
            $imgsProbe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
                & docker images --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}' 2>&1
                $LASTEXITCODE
            }
            $imgsRaw = @()
            $imgsExit = 0
            if ($imgsProbe.TimedOut) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bec7da8072d14157')
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_6bb2b40cf71cf7e1') -Class 'DOCKER.probe-timeout'
                $imgsExit = -1
            } else {
                $imgsOutput = @($imgsProbe.Output)
                if ($imgsOutput.Count -gt 0) {
                    $last = $imgsOutput[$imgsOutput.Count - 1]
                    if ($last -is [int]) {
                        $imgsExit = [int]$last
                        $imgsRaw = @(if ($imgsOutput.Count -gt 1) { $imgsOutput[0..($imgsOutput.Count - 2)] })
                    } else {
                        $imgsRaw = $imgsOutput
                    }
                }
            }
            if ($imgsExit -ne 0) {
                if (-not $imgsProbe.TimedOut) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_27c29d60062fde4f' -FormatValues ($imgsExit) -FormatBindings @{ imgsExit = '0' })
                }
            } else {
                $rows = @($imgsRaw | Where-Object { $_ -match '\|' } | ForEach-Object {
                    $parts = $_ -split '\|', 5
                    $bytes = 0
                    if ($parts[3] -match '^([\d.]+)\s*([kMGT]?B)$') {
                        $n = [double]$matches[1]
                        switch ($matches[2]) {
                            'B'  { $bytes = $n }
                            'kB' { $bytes = $n * 1KB }
                            'MB' { $bytes = $n * 1MB }
                            'GB' { $bytes = $n * 1GB }
                            'TB' { $bytes = $n * 1TB }
                        }
                    }
                    [PSCustomObject]@{
                        Repository = $parts[0]; Tag = $parts[1]; Id = $parts[2]
                        Size = $parts[3]; Bytes = $bytes; Created = $parts[4]
                    }
                })
                $sorted = $rows | Sort-Object Bytes -Descending | Select-Object -First 100
                Write-Output ("{0,-50} {1,-15} {2,-12} {3,10}  {4}" -f 'REPOSITORY','TAG','IMAGE ID','SIZE','CREATED')
                foreach ($r in $sorted) {
                    Write-Output ("{0,-50} {1,-15} {2,-12} {3,10}  {4}" -f $r.Repository, $r.Tag, $r.Id, $r.Size, $r.Created)
                }
                if ($rows.Count -gt 100) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2400619d87db958d' -FormatValues (($rows.Count - 100)) -FormatBindings @{ count = '0' })
                }
            }
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_6a25d0419bde0a78')
            Invoke-Tool -Tool 'docker' -ToolArgs @('stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}') -TimeoutSeconds 5
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_a864244a08aca6fd')
            Invoke-Tool -Tool 'docker' -ToolArgs @('system','df') -TimeoutSeconds 5

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_3c44577797e2dd05')
            $repos = Get-LocalRegistryCatalog
            if ($null -eq $repos) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b8a3a38bd4c24074')
            } else {
                Write-Output "Repositories ($($repos.Count)):"
                foreach ($repo in $repos) { Write-Output ("  {0}" -f $repo) }
                if ($repos.Count -eq 0) {
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_f36a3040f1c5e565') -Class 'REGISTRY.catalog-empty'
                }
            }
        }
    }
    }

    # --- REGION: 10. Kubernetes
    Invoke-DiagnosticSection "KUBERNETES" {
    if ($SkipKube) {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e1a9e5fe4f68be46')
    } elseif (-not (Test-CommandAvailable 'kubectl')) {
        # Reported, not flagged -- same reasoning as the docker probe above:
        # the clusters this fleet exercises live inside guests, and the host
        # is not expected to hold a client for them. HELM below keeps its
        # problem because it is only reached once kubectl HAS answered, where
        # a missing helm really does mean charts could not have deployed.
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ebc89a16d6b57e72')
    } else {
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_8f5850e67eb6453e')
        # --- REGION: https://yuruna.link/423ef7f5-0004
        $kv = & kubectl version --output=json --request-timeout=5s 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($kv) {
            if ($kv.clientVersion) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_282dc38f46468a29' -FormatValues ($kv.clientVersion.gitVersion) -FormatBindings @{ gitVersion = '0' }) }
            if ($kv.serverVersion) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_23355db5f693b7ef' -FormatValues ($kv.serverVersion.gitVersion) -FormatBindings @{ gitVersion = '0' }) }
            else { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d9c1fd0b30efa8fb') ; Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_75654a06afaa3cf5') -Class 'KUBE.server-unavailable' }
        }
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_70b856c7f2d86801')
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('config','current-context')

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d6e66216138554de')
        $nodeSnapshot = @{}
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','nodes','-o','wide','--request-timeout=5s') -TimeoutSeconds 5 -Snapshot $nodeSnapshot
        $nodes = @(Get-DiagnosticKubeSnapshot -Resource nodes -Snapshot $nodeSnapshot)
        foreach ($n in $nodes) {
            $cols = $n -split '\s+'
            if ($cols.Count -ge 2 -and $cols[1] -notmatch '^Ready') {
                Add-Problem "KUBE: node '$($cols[0])' status: $($cols[1])" -Class 'KUBE.node-unhealthy'
            }
        }

        Write-Sub "Namespaces"
        $namespaceSnapshot = @{}
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ns','--request-timeout=5s') -TimeoutSeconds 5 -Snapshot $namespaceSnapshot
        Get-DiagnosticKubeSnapshot -Resource ns -Snapshot $namespaceSnapshot -PrimeOnly

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_1309c3acc622dab5')
        $podSnapshot = @{}
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','pods','-A','-o','wide','--request-timeout=5s') -TimeoutSeconds 5 -Snapshot $podSnapshot
        $pods = @(Get-DiagnosticKubeSnapshot -Resource pods -Snapshot $podSnapshot)
        foreach ($p in $pods) {
            $cols = $p -split '\s+'
            if ($cols.Count -lt 6) { continue }
            $ns      = $cols[0]
            $name    = $cols[1]
            $ready   = $cols[2]
            $status  = $cols[3]
            $restarts = $cols[4] -replace '\(.*\)',''
            $restartCount = 0
            [int]::TryParse($restarts, [ref]$restartCount) | Out-Null
            if ($status -notin @('Running','Completed','Succeeded')) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_5b97d4a3f5ce357b' -Arguments @{ ns = "$ns"; name = "$name"; status = "$status"; ready = "$ready" }) -Class 'KUBE.pod-unhealthy'
            } elseif ($restartCount -ge 5) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_69b9722682b44fc4' -Arguments @{ ns = "$ns"; name = "$name"; restartCount = "$restartCount" }) -Class 'KUBE.pod-restarts'
            }
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_97598358f835a356')
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','svc','-A','--request-timeout=5s')

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_800be59d158c392f')
        $deploymentSnapshot = @{}
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','deploy','-A','--request-timeout=5s') -Snapshot $deploymentSnapshot
        Get-DiagnosticKubeSnapshot -Resource deploy -Snapshot $deploymentSnapshot -PrimeOnly

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d1479ec6f1e779bb')
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ds','-A','--request-timeout=5s')

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_05b17216b940ff6d')
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','sts','-A','--request-timeout=5s')

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_c897ef5902418efd')
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','jobs,cronjobs','-A','--request-timeout=5s')

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_0b45180c32513386')
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ingress','-A','--request-timeout=5s')

        Write-Sub "PersistentVolumes / PVCs"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','pv,pvc','-A','--request-timeout=5s')

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_f61604afb0d83e33')
        $cmCount = (& kubectl get cm  -A --no-headers --request-timeout=5s 2>$null | Measure-Object).Count
        $scCount = (& kubectl get secret -A --no-headers --request-timeout=5s 2>$null | Measure-Object).Count
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bbfe9b036024c873' -FormatValues ($cmCount) -FormatBindings @{ cmCount = '0' })
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ee81fd4c1b5a982c' -FormatValues ($scCount) -FormatBindings @{ scCount = '0' })

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_2a3f562a2200635a')
        $evts = @(& kubectl get events -A --field-selector type=Warning --sort-by .lastTimestamp --request-timeout=5s 2>&1)
        if ($evts.Count -gt 1) {
            Write-Output $evts[0]
            $rows = $evts | Select-Object -Skip 1
            $rows | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
            if ($rows.Count -gt 100) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_098fb3c06a9f2f65' -FormatValues (($rows.Count - 100)) -FormatBindings @{ count = '0' }) }
        } else {
            $evts | ForEach-Object { Write-Output $_ }
        }
        $warnings = & kubectl get events -A --field-selector type=Warning --no-headers --request-timeout=5s 2>$null
        if ($warnings -and $warnings.Count -gt 0) {
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_9e426b0a65404260' -Arguments @{ count = "$($warnings.Count)" }) -Class 'KUBE.warning-events'
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_cd9e1527d1f146c7')
        if (Test-CommandAvailable 'helm') {
            Invoke-Tool -Tool 'helm' -ToolArgs @('list','-A')
            $rels = (Get-DiagnosticHelmSnapshot).Releases
            if ($rels) {
                foreach ($r in $rels) {
                    if ($r.status -notin @('deployed','superseded')) {
                        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_a0594e5a22e6ed90' -FormatValues ($r.name, $r.namespace, $r.status) -FormatBindings @{ name = '0'; namespace = '1'; status = '2' }) -Class 'HELM.release-unhealthy'
                    }
                }
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_726f2fd533779220')
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_3c1dd62a526940d8') -Class 'HELM.command-unavailable'
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_0a78863ef3d20c87')
        $nsBuiltin = @('default','kube-system','kube-public','kube-node-lease','kube-flannel')
        $nsAll = @(Get-DiagnosticKubeSnapshot -Resource ns | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
        $nsWithPods = @(Get-DiagnosticKubeSnapshot -Resource pods | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique)
        $nsWithDeploys = @(Get-DiagnosticKubeSnapshot -Resource deploy | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique)
        $emptyNs = @($nsAll | Where-Object { $_ -and ($nsBuiltin -notcontains $_) -and ($nsWithPods -notcontains $_) -and ($nsWithDeploys -notcontains $_) })
        if ($emptyNs.Count -gt 0) {
            foreach ($n in $emptyNs) {
                Write-Output ("  $n")
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_4f49b26ecda1d965' -Arguments @{ n = "$n" }) -Class 'KUBE.namespace-empty'
            }
        } else {
            Write-Output "(none)"
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_6b1227d43bb8ae6b')
        if ($IsWindows) {
            $procs = Get-CimInstance Win32_Process -Filter "Name='kubectl.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'port-forward' }
            if ($procs) {
                $procs | ForEach-Object {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_19ca036c78f36c2b' -FormatValues ($_.ProcessId, $_.CommandLine) -FormatBindings @{ processId = '0'; commandLine = '1' })
                }
            } else { Write-Output "(none)" }
        } elseif ($IsMacOS -or $IsLinux) {
            $found = & /bin/ps -axo pid=,args= 2>$null | Where-Object { $_ -match 'kubectl[^/]*port-forward' }
            if ($found) {
                $found | ForEach-Object { Write-Output ("  $_") }
            } else { Write-Output "(none)" }
        }
    }
    }

    # --- REGION: 11. Host detail
    # See https://yuruna.link/423ef7f5-0009
    Invoke-DiagnosticSection "HOST DETAIL" {

        # --- REGION: Runner process tree (all platforms)
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_69ccbdc3edf66706')
        $runtimeDir = $env:YURUNA_RUNTIME_DIR
        if (-not $runtimeDir) {
            if ($script:DiagnosticEvidenceRoot) {
                $runtimeDir = Join-Path -Path $script:DiagnosticEvidenceRoot -ChildPath 'test' -AdditionalChildPath 'status', 'track'
            }
        }
        $rootPid = 0
        $rootSource = ''
        foreach ($candidate in @('inner.pid','runner.pid')) {
            if (-not $runtimeDir) { break }
            $candidateFile = Join-Path $runtimeDir $candidate
            if (Test-Path -LiteralPath $candidateFile) {
                try { $rootPid = [int]((Get-Content -LiteralPath $candidateFile -Raw -ErrorAction Stop).Trim()) } catch { $rootPid = 0 }
                if ($rootPid -gt 0) { $rootSource = $candidate; break }
            }
        }
        if (-not $runtimeDir) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.diagnostic_checkout_unavailable')
        } elseif ($rootPid -le 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_1b5c604fd0694be7' -Arguments @{ runtimeDir = "$runtimeDir" })
        } elseif (-not (Get-Process -Id $rootPid -ErrorAction SilentlyContinue)) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_fa511b523f557f63' -Arguments @{ rootPid = "$rootPid"; rootSource = "$rootSource" })
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_37ab2c9f0d8d6336' -Arguments @{ rootPid = "$rootPid"; rootSource = "$rootSource" })
            # Build (pid -> {ppid, etime, pcpu, cmd}) map per platform.
            $procMap = @{}
            if ($IsWindows) {
                try {
                    # Win32_Process has Handle (=pid), ParentProcessId, CommandLine,
                    # CreationDate. No wall-elapsed column -- compute it from
                    # CreationDate. No %CPU column at all, so that cell stays empty.
                    $allProcs = Get-CimInstance Win32_Process -ErrorAction Stop
                    foreach ($p in $allProcs) {
                        $etimeSeconds = $null
                        if ($p.CreationDate) {
                            try { $etimeSeconds = [int]((Get-Date) - $p.CreationDate).TotalSeconds } catch { $etimeSeconds = $null }
                        }
                        $procMap[[int]$p.ProcessId] = @{
                            ppid  = [int]$p.ParentProcessId
                            etime = $etimeSeconds
                            cpu   = $null    # CIM doesn't expose pcpu; row formatter just shows '-'
                            cmd   = [string]$p.CommandLine
                        }
                    }
                } catch {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_71e456ef5ba1bbde' -Arguments @{ message = "$($_.Exception.Message)" })
                }
            } elseif ($IsLinux -or $IsMacOS) {
                # --- REGION: https://yuruna.link/423ef7f5-000a
                try {
                    $psLines = & '/bin/ps' -ww -axo 'pid=,ppid=,etime=,pcpu=,args=' 2>$null
                    foreach ($line in $psLines) {
                        $trim = ([string]$line).Trim()
                        if (-not $trim) { continue }
                        # Split on first 4 whitespace runs; rest is args.
                        $parts = $trim -split '\s+', 5
                        if ($parts.Count -lt 5) { continue }
                        $procMap[[int]$parts[0]] = @{
                            ppid  = [int]$parts[1]
                            etime = $parts[2]
                            cpu   = $parts[3]
                            cmd   = $parts[4]
                        }
                    }
                } catch {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_dde796c9dd1d2e34' -Arguments @{ message = "$($_.Exception.Message)" })
                }
            }
            if ($procMap.Count -gt 0 -and $procMap.ContainsKey($rootPid)) {
                # Iterative depth-first walk with depth tracking. Children
                # by ppid index built once for O(N) walk.
                $childIdx = @{}
                foreach ($entry in $procMap.GetEnumerator()) {
                    $pp = $entry.Value.ppid
                    if (-not $childIdx.ContainsKey($pp)) { $childIdx[$pp] = New-Object System.Collections.Generic.List[int] }
                    $childIdx[$pp].Add([int]$entry.Key)
                }
                $stack   = [System.Collections.Generic.Stack[object]]::new()
                $stack.Push(@{ pid = $rootPid; depth = 0 })
                $visited = [System.Collections.Generic.HashSet[int]]::new()
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a3928565043bd38e' -FormatValues ('PID','PPID','ETIME','CPU') -FormatBindings @{ pID = '0,-6'; pPID = '1,-6'; eTIME = '2,-12'; cPU = '3,-6' })
                while ($stack.Count -gt 0) {
                    $cur = $stack.Pop()
                    $cpid = [int]$cur.pid
                    if (-not $visited.Add($cpid)) { continue }
                    if (-not $procMap.ContainsKey($cpid)) { continue }
                    $info  = $procMap[$cpid]
                    $indent = ('  ' * [int]$cur.depth)
                    $etimeStr = if ($null -ne $info.etime) { ('{0}' -f $info.etime) } else { '-' }
                    $cpuStr   = if ($null -ne $info.cpu)   { ('{0}' -f $info.cpu)   } else { '-' }
                    $cmdLine  = ([string]$info.cmd)
                    if ($cmdLine.Length -gt 240) { $cmdLine = $cmdLine.Substring(0, 240) + ' ...' }
                    Write-Output ("{0,-6} {1,-6} {2,-12} {3,-6}  {4}{5}" -f $cpid, $info.ppid, $etimeStr, $cpuStr, $indent, $cmdLine)
                    if ($childIdx.ContainsKey($cpid)) {
                        # Push in reverse so the first child is popped first.
                        $kids = $childIdx[$cpid]
                        for ($i = $kids.Count - 1; $i -ge 0; $i--) {
                            $stack.Push(@{ pid = $kids[$i]; depth = [int]$cur.depth + 1 })
                        }
                    }
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_40a0bcb292b4974b' -Arguments @{ rootPid = "$rootPid" })
            }
        }

        if (-not ($IsLinux -or $IsMacOS -or $IsWindows)) {
            Write-Output ""
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bf1c637eb978cee4')
            return
        }

        if ($IsWindows) {
            # --- REGION: Windows-specific facts
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_60bde44af83103ca')
            if (Test-CommandAvailable 'Get-VM') {
                try {
                    $vms = Get-VM -ErrorAction Stop | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime
                    if ($vms) {
                        $vms | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Output $_.TrimEnd() }
                    } else {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_27627383486fd63c')
                    }
                } catch {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_c08c4959cc86f9f1' -Arguments @{ message = "$($_.Exception.Message)" })
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d97c4ddb2e78c92c')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_4c41c3b887d1d8d9')
            try {
                $listen = Get-NetTCPConnection -State Listen -ErrorAction Stop |
                    Select-Object LocalAddress, LocalPort, OwningProcess |
                    Sort-Object LocalPort
                if ($listen) {
                    $listen | Select-Object -First 40 | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Output $_.TrimEnd() }
                    if (@($listen).Count -gt 40) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_96ad56a16e901bb7' -FormatValues ((@($listen).Count - 40)) -FormatBindings @{ count = '0' }) }
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e06cc5e640fcddaf')
                }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3205971a3ab9d377' -Arguments @{ message = "$($_.Exception.Message)" })
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_31d987c65f45d002')
            try {
                Get-NetFirewallProfile -ErrorAction Stop |
                    Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
                    Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_.TrimEnd() }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_502e7583e46dd166' -Arguments @{ message = "$($_.Exception.Message)" })
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_4e5c913a3ad57e31')
            try {
                $sinceStart = (Get-Date).AddHours(-1)
                $evts = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=@(1,2); StartTime=$sinceStart } -MaxEvents 25 -ErrorAction Stop
                if ($evts) {
                    $evts | Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
                        Format-Table -AutoSize -Wrap | Out-String -Width 240 | ForEach-Object { Write-Output $_.TrimEnd() }
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_231522de7ad0c540')
                }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_fcbd291003607027' -Arguments @{ message = "$($_.Exception.Message)" })
            }
            return
        }

        if ($IsMacOS) {
            # --- REGION: macOS-specific facts
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_a8f43a580cdc14d3')
            if (Test-CommandAvailable 'netstat') {
                & netstat -nrf inet 2>$null | Select-Object -First 12 | ForEach-Object { Write-Output $_ }
            }
            if (Test-CommandAvailable 'ifconfig') {
                & ifconfig 2>$null | Where-Object { $_ -match '^[a-z]|inet ' } | ForEach-Object { Write-Output $_ }
            }

            Write-Sub "DNS (scutil --dns | head -40)"
            if (Test-CommandAvailable 'scutil') {
                & scutil --dns 2>$null | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e13171542462cc83')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d57d57d8e669f184')
            if (Test-CommandAvailable 'lsof') {
                & lsof -nP -iTCP -sTCP:LISTEN 2>$null | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_aa4ec3163ff01d87')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_e36c08286c075185')
            foreach ($cmd in @('utmctl','qemu-img','virsh')) {
                if (Test-CommandAvailable $cmd) {
                    Write-Output ("  {0}: $(& which $cmd 2>$null)" -f $cmd)
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a4bbdffc9ba74919' -FormatValues ($cmd) -FormatBindings @{ cmd = '0' })
                }
            }
            if (Test-CommandAvailable 'utmctl') {
                Write-Output ""
                Get-DiagnosticUtmctlListing
            }

            # OCR rides Apple Vision through a swiftc-compiled helper; when the
            # compile breaks (Command Line Tools gone stale after an OS update,
            # xcode-select pointing at a removed developer dir) every cycle
            # emits ocr_vision_slowpath and OCR drops to the interpreter or
            # tesseract. Reproduce the compile here so this report carries the
            # actual compiler error next to the toolchain facts needed to fix it.
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_a024c74dba6acc59')
            foreach ($cmd in @('swiftc','swift','xcode-select','xcrun')) {
                if (Test-CommandAvailable $cmd) {
                    Write-Output ("  {0}: $(& which $cmd 2>$null)" -f $cmd)
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_cc08dcc24c89ccb5' -FormatValues ($cmd) -FormatBindings @{ cmd = '0' })
                }
            }
            if (Test-CommandAvailable 'xcode-select') {
                Write-Output ((Format-YurunaOperatorMessage -Key 'automation.operator_b2bc1409342474de' -Arguments @{ join = [string]((@(& xcode-select -p 2>&1 | ForEach-Object { $_.ToString() }) -join ' ')) }))
            }
            if (Test-CommandAvailable 'swiftc') {
                Invoke-Tool -Tool 'swiftc' -ToolArgs @('--version') -TimeoutSeconds 30 -ProblemTag 'SWIFT'
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6ddddbd8ec8625e1')
                $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-swiftc-probe-" + [guid]::NewGuid().ToString('N'))
                try {
                    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
                    $probeSrc = Join-Path $probeDir 'probe.swift'
                    $probeBin = Join-Path $probeDir 'probe'
                    Set-Content -LiteralPath $probeSrc -Value 'print("swiftc-probe-ok")'
                    Invoke-Tool -Tool 'swiftc' -ToolArgs @($probeSrc, '-o', $probeBin) -TimeoutSeconds 60 -ProblemTag 'SWIFT'
                    if (Test-Path -LiteralPath $probeBin) {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3ae794313d668573')
                    } else {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_38e06e9b805aee27')
                        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_8aa84a9f7af375bd') -Class 'SWIFT.compiler-unavailable'
                    }
                } finally {
                    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5462f41e8c0e63b5')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_7fcfb4c365b13187')
            if (Test-CommandAvailable 'log') {
                # macOS unified log: pull errors/warnings from the last hour.
                & log show --last 1h --predicate 'eventMessage contains[c] "error" OR eventMessage contains[c] "fail"' --info --debug 2>$null |
                    Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
            }
            return
        }

        # --- REGION: Linux-specific facts
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_0708e3afbc3562b5')
        $netplanFiles = @(Get-ChildItem -Path '/etc/netplan' -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
        if ($netplanFiles.Count -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b78f57491832bdf1')
        } else {
            foreach ($f in $netplanFiles) {
                Write-Output "# $($f.FullName)"
                Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
                Write-Output ""
            }
        }

        Write-Sub "/etc/resolv.conf"
        if (Test-Path '/etc/resolv.conf') {
            $resolvItem = Get-Item -LiteralPath '/etc/resolv.conf' -Force -ErrorAction SilentlyContinue
            if ($resolvItem -and $resolvItem.LinkType) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5bca1de1ae2456e7' -FormatValues (($resolvItem.Target -join ', ')) -FormatBindings @{ join = '0' })
            }
            Get-Content -LiteralPath '/etc/resolv.conf' -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
        } else {
            Write-Output "(missing)"
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_ac4b5b8a5b1fb746') -Class 'LINUX.resolver-missing'
        }

        Write-Sub "/etc/hosts"
        if (Test-Path '/etc/hosts') {
            Get-Content -LiteralPath '/etc/hosts' -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
        } else {
            Write-Output "(missing)"
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_48a01e8836cadcfb')
        if (Test-CommandAvailable 'resolvectl') {
            Invoke-Tool -Tool 'resolvectl' -ToolArgs @('status')
        } elseif (Test-CommandAvailable 'systemd-resolve') {
            Invoke-Tool -Tool 'systemd-resolve' -ToolArgs @('--status')
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2259884669944bfb')
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_3fceb1a4b1db4faa')
        Invoke-Tool -Tool 'ip' -ToolArgs @('route')

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_02f5964499aac6c9')
        if (Test-CommandAvailable 'ss') {
            Invoke-Tool -Tool 'ss' -ToolArgs @('-tulpn')
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_96f6823edc565c32')
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_fc543d57e6ae8eda')
        if (Test-CommandAvailable 'ss') {
            # Listening sockets alone cannot show a transfer wedged mid-body:
            # the evidence lives in the ESTABLISHED socket -- its send/recv
            # queues and the -o retransmission timer, which separate a fetch
            # stalled against a dead or trickling peer from an idle-but-
            # healthy connection (the stalled-transfer trap class).
            # Privileged so -p attributes sockets owned by other users;
            # package managers run under sudo, and their hung fetch worker
            # is exactly the socket this capture exists to catch.
            Invoke-Tool -Tool 'ss' -ToolArgs @('-tnpo') -Privileged
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_3b6105a4e3726e67')
        # A blocked package manager looks idle in every aggregate view; the evidence is
        # which fd it is blocked reading. Capture the whole subtree, reached by descent,
        # not by name.
        # See https://yuruna.link/4213a0b3-0198
        $pkgPids = @()
        foreach ($n in @('apt-get','apt','dpkg','dnf','yum','unattended-upgr')) {
            $found = & pgrep -x $n 2>$null
            if ($found) { $pkgPids += @($found | ForEach-Object { [int]$_ }) }
        }
        $pkgPids = @($pkgPids | Sort-Object -Unique)
        if ($pkgPids.Count -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_c1eddd578c2a9c04')
        } else {
            $treeCap = 40
            # A matched pid that already appeared inside an earlier root's
            # subtree (apt-get spawning dpkg, both matched by name) would
            # otherwise be reported twice -- once as a descendant and again
            # as a root of its own.
            $covered = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($pkgPid in $pkgPids) {
                if ($covered.Contains($pkgPid)) { continue }
                $tree = @(Get-ProcessDescendantPid -RootPid $pkgPid -MaxPids $treeCap)
                foreach ($t in $tree) { $null = $covered.Add($t) }
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d38b56750f65cb96' -FormatValues ($pkgPid, $tree.Count) -FormatBindings @{ pkgPid = '0'; count = '1' })
                Invoke-PrivProbe -Tool 'ps' -ToolArgs @('-o','pid,ppid,pgid,stat,wchan:30,etime,args','--pid',($tree -join ',')) |
                    ForEach-Object { Write-Output $_ }
                if ($tree.Count -ge $treeCap) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9afc6dc3fd49c033' -FormatValues ($treeCap) -FormatBindings @{ treeCap = '0' })
                }
                foreach ($t in $tree) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_09a44e349e64e4a2' -FormatValues ($t) -FormatBindings @{ t = '0' })
                    $fdLines = Invoke-PrivProbe -Tool 'ls' -ToolArgs @('-l',"/proc/$t/fd")
                    $fdLines | Select-Object -First 50 | ForEach-Object { Write-Output ("   " + $_) }
                    if ($fdLines.Count -gt 50) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_daf5c05adf2266a4' -FormatValues (($fdLines.Count - 50)) -FormatBindings @{ count = '0' }) }
                }
            }
            Write-Output ""
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ad4c01d36493a583')
            $forest = Invoke-PrivProbe -Tool 'ps' -ToolArgs @('-ef','--forest')
            $forest | Select-Object -First 250 | ForEach-Object { Write-Output $_ }
            if ($forest.Count -gt 250) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3e3c06d4edff4846' -FormatValues (($forest.Count - 250)) -FormatBindings @{ count = '0' }) }
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_485fb74637bada2f')
        if (Test-CommandAvailable 'ping') {
            $pingOut = & ping -c 3 -W 2 1.1.1.1 2>&1
            $pingExit = $LASTEXITCODE
            $pingOut | ForEach-Object { Write-Output $_ }
            if ($pingExit -ne 0) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_40089ed3a3e8b270' -Arguments @{ pingExit = "$pingExit" }) -Class 'LINUX.network-unavailable'
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_c7337ea5e2763690')
        }

        # Elevated, through the same prefix the process and journal probes use.
        # Unprivileged, iptables answers "Permission denied (you must be root)"
        # and nothing else, so the section costs a line and reports nothing --
        # on a host where the sibling probes in this same run are elevated.
        #
        # The nat table, not just filter: a NodePort or a NAT guest network is
        # DNAT, and `-S` alone shows the filter chains, which is the one table
        # those rules are never in.
        foreach ($iptTable in @('filter', 'nat')) {
            Write-Sub "Firewall (iptables -t $iptTable -S, first 200 lines)"
            if (Test-CommandAvailable 'iptables') {
                $ipt = @(Invoke-PrivProbe -Tool 'iptables' -ToolArgs @('-t', $iptTable, '-S') -KeepStderr)
                if (-not $ipt.Count) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_87bad0326d09536b')
                } elseif ($ipt[0] -match 'Permission denied|must be root|not permitted') {
                    Write-Output ("({0})" -f $ipt[0])
                } else {
                    $ipt | Select-Object -First 200 | ForEach-Object { Write-Output $_ }
                    if ($ipt.Count -gt 200) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_144a57b43107ed4c' -FormatValues (($ipt.Count - 200)) -FormatBindings @{ count = '0' }) }
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_94449206290537fc')
            }
        }
        if (Test-CommandAvailable 'ss') {
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_71acf9bf9963db93')
            $ssOut = & ss -tuln 2>&1
            $ssExit = $LASTEXITCODE
            if ($ssExit -ne 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_530e430042eaa997' -FormatValues ($ssExit, (($ssOut | Select-Object -First 1) -join ' ')) -FormatBindings @{ ssExit = '0'; join = '1' })
            } else {
                $ssOut | Select-Object -First 200 | ForEach-Object { Write-Output $_ }
                if ($ssOut.Count -gt 200) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e3804b3eb9e6aaab' -FormatValues (($ssOut.Count - 200)) -FormatBindings @{ count = '0' }) }
            }
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_c05e152dacede6aa')
        Write-LinuxKernelLog

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_lockup_settings')
        Get-LinuxLockupSettingLine | ForEach-Object { Write-Output $_ }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.system_diagnostic_deep_mode')
        Get-DeepDiagnosticStateLine | ForEach-Object { Write-Output $_ }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_ec0ef9d3e6ca9f44')
        if (Test-CommandAvailable 'lsmod') {
            $lsmodOut = @(& lsmod 2>$null)
            $virt = $lsmodOut | Where-Object { $_ -match '^(kvm|virtio|hv_|hyperv|vmw|vbox|xen)' }
            if ($virt) {
                if ($lsmodOut.Count -gt 0) { Write-Output $lsmodOut[0] }
                $virt | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_4330a0cd21a835c5')
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b5ed33d7f546a531')
        }

        # A dialed address can be one the guest already left; the neighbor state and the
        # bridge forwarding database tell them apart, and both are gone once the domain
        # is undefined.
        # See https://yuruna.link/4213a0b3-0199
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_c7e1634dbc149906')
        if (Test-CommandAvailable 'ip') {
            $neighLine = @(& ip -4 neigh show 2>&1 | ForEach-Object { "$_" })
            if ($LASTEXITCODE -ne 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_634f2762ed20d183' -FormatValues ($LASTEXITCODE, (($neighLine | Select-Object -First 1) -join ' ')) -FormatBindings @{ lASTEXITCODE = '0'; join = '1' })
            } elseif ($neighLine.Count -eq 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_c0d772dace958bda')
            } else {
                $neighLine | Select-Object -First 200 | ForEach-Object { Write-Output $_ }
                if ($neighLine.Count -gt 200) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_1d5a674e638004e7' -FormatValues (($neighLine.Count - 200)) -FormatBindings @{ count = '0' }) }
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_382787bb31d0ed63')
        }

        # Every bridge rather than a fixed name: libvirt numbers its NAT bridges
        # per network, and a host bridged onto the LAN carries its guests on an
        # operator-named device instead.
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_0086f1b5b2c1a09c')
        if (-not (Test-CommandAvailable 'bridge')) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9afcda1ae598ab10')
        } elseif (-not (Test-CommandAvailable 'ip')) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ac19e0a29d150ada')
        } else {
            $bridgeName = @()
            foreach ($linkLine in @(& ip -o link show type bridge 2>$null)) {
                if ("$linkLine" -match '^\s*\d+:\s+([^:@\s]+)') { $bridgeName += $Matches[1] }
            }
            if (-not $bridgeName.Count) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d7469332f7ce8f65')
            } else {
                foreach ($br in $bridgeName) {
                    Write-Output "--- $br ---"
                    $fdbLine = @(& bridge fdb show br $br 2>&1 | ForEach-Object { "$_" })
                    if ($LASTEXITCODE -ne 0) {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_1dbf1398dbcee3d7' -FormatValues ($br, $LASTEXITCODE, (($fdbLine | Select-Object -First 1) -join ' ')) -FormatBindings @{ br = '0'; lASTEXITCODE = '1'; join = '2' })
                    } elseif (-not $fdbLine.Count) {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2bc578a9fce34264')
                    } else {
                        $fdbLine | Select-Object -First 60 | ForEach-Object { Write-Output $_ }
                        if ($fdbLine.Count -gt 60) { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e7055db124290299' -FormatValues (($fdbLine.Count - 60)) -FormatBindings @{ count = '0' }) }
                    }
                }
            }
        }

        # --- REGION: https://yuruna.link/423ef7f5-000c
        # Where libvirt runs the guest network, this host IS the DHCP server its guests
        # talk to. Read-only throughout: nothing here defines, starts or edits anything.
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_74de2e28a089729b')
        if (Test-CommandAvailable 'virsh') {
            # qemu:///system needs libvirt group membership. Where the account
            # running this does not have it, the same question is asked again
            # through the non-interactive sudo prefix rather than reported as
            # "no libvirt on this host", which is the wrong answer and the one
            # that stops the reader looking.
            $virshRead = {
                param([string[]]$VirshArgs)
                $out = @(& virsh --connect qemu:///system @VirshArgs 2>$null | ForEach-Object { "$_" })
                if ($LASTEXITCODE -ne 0 -and $script:LinuxPriv.Count -gt 0) {
                    $out = @(Invoke-PrivProbe -Tool 'virsh' -ToolArgs (@('--connect', 'qemu:///system') + $VirshArgs))
                }
                return $out
            }
            $domainLine = @(& $virshRead @('list', '--all'))
            if ($domainLine.Count -eq 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2bd5e3cda8731457')
            } else {
                $domainLine | ForEach-Object { Write-Output $_ }
                # MAC and bridge per running domain. Both are what a reader
                # greps the dnsmasq window below with, and both are gone once
                # the domain is undefined -- which the failure path does within
                # minutes of this capture.
                foreach ($dom in @(& $virshRead @('list', '--name') | Where-Object { $_ -and $_.Trim() })) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_5b83af96edec0999' -Arguments @{ dom = "$dom" })
                    & $virshRead @('domiflist', $dom.Trim()) | ForEach-Object { Write-Output $_ }
                }
                foreach ($net in @(& $virshRead @('net-list', '--name') | Where-Object { $_ -and $_.Trim() })) {
                    $netName = $net.Trim()
                    Write-Output "## network $netName"
                    # The definition lines a lease depends on: which bridge the
                    # guests attach to, whether the network forwards or is
                    # isolated, the address range that can be handed out, and
                    # any fixed host reservations. The rest of the XML is
                    # device plumbing that never explains a missing lease.
                    & $virshRead @('net-dumpxml', $netName) |
                        Where-Object { $_ -match '<(bridge|forward|ip |ip>|range|host )' } |
                        ForEach-Object { Write-Output $_.Trim() }
                    & $virshRead @('net-dhcp-leases', $netName) | ForEach-Object { Write-Output $_ }
                }
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b2baf090b729cd3c')
        }

        # The server's own account of every transaction: which MAC asked, under
        # which client identity, and whether it was offered anything. It is the
        # half of a lease failure a guest can never see, and it separates "the
        # client never asked" from "the client asked and was not answered" --
        # which indict different machines.
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d4587f70644914bd')
        if ((Test-CommandAvailable 'journalctl') -and (Test-CommandAvailable 'virsh')) {
            $dnsmasqLine = @(Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @(
                '-t', 'dnsmasq-dhcp', '-t', 'dnsmasq', '--since', '30 min ago', '-n', '60', '--no-pager'))
            if ($dnsmasqLine.Count -gt 0 -and -not (($dnsmasqLine -join "`n") -match 'No entries')) {
                $dnsmasqLine | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_af544eaa07446367')
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f72a73ef3f898934')
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_1f97f627af7c6621')
        if (Test-CommandAvailable 'journalctl') {
            # Four times the window that gets printed is read, because the
            # suppressed classes arrive on a timer: on a host mid-cycle a
            # 100-line tail is entirely console-frame and address-lookup
            # bookkeeping, and the boot, network and unit lines a reader came
            # for aged out of it minutes earlier. Filter first, print the last
            # 100 of what survives.
            $jxe = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-xe','-n','400','--no-pager') -KeepStderr
            if ($jxe) {
                $kept = [System.Collections.Generic.List[string]]::new()
                $noiseTally = [ordered]@{}
                $inScriptBlock = $false
                foreach ($line in $jxe) {
                    $lineStr = [string]$line
                    $class = Get-JournalSelfNoiseClass -Line $lineStr
                    # A compile record's continuation lines are indented and
                    # belong to the same entry, so they follow it out.
                    if ($class -eq 'script-compile records') { $inScriptBlock = $true }
                    elseif ($inScriptBlock -and $lineStr -match '^\s') { $class = 'script-compile records' }
                    else { $inScriptBlock = $false }
                    if ($class) {
                        if ($noiseTally.Contains($class)) { $noiseTally[$class] = [int]$noiseTally[$class] + 1 }
                        else { $noiseTally[$class] = 1 }
                        continue
                    }
                    $kept.Add($lineStr)
                }
                $kept | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
                if ($kept.Count -eq 0) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_4ba3081aa0af2a76')
                }
                $note = Format-JournalSelfNoiseNote -Tally $noiseTally
                if ($note) { Write-Output $note }
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_88570e5c6483f2df')
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_a474a4f862597d0d')
        if (Test-CommandAvailable 'journalctl') {
            foreach ($svc in @('docker','containerd','kubelet')) {
                Write-Output "## $svc"
                $jOut = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-u',$svc,'--since','6 hours ago','-p','warning','-n','100','--no-pager') -KeepStderr
                if (-not $jOut -or (($jOut -join "`n") -match 'No entries')) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bdb8150b986b7b72')
                } else {
                    $jOut | ForEach-Object { Write-Output $_ }
                }
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_88570e5c6483f2df')
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_c9b26da18f4d0f59')
        if (Test-Path '/opt/cni/bin') {
            $cniBin = @(Get-ChildItem -Path '/opt/cni/bin' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($cniBin.Count -gt 0) {
                $cniBin | ForEach-Object { Write-Output ("  {0}" -f $_.Name) }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_77a6787d5a9b9be1')
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_3ce1f61bd83a82f5') -Class 'LINUX.cni-binaries-missing'
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_18152037a24112b7')
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_801a366c249222a2')
        if (Test-Path '/etc/cni/net.d') {
            $cniNet = @(Get-ChildItem -Path '/etc/cni/net.d' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($cniNet.Count -gt 0) {
                foreach ($cf in $cniNet) {
                    Write-Output "# $($cf.FullName)"
                    Get-Content -LiteralPath $cf.FullName -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
                    Write-Output ""
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f374af33972ebb69')
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_0a5f2ba73289b02b') -Class 'LINUX.cni-config-missing'
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_8c7476793d8974ca')
        }
    }

    # --- REGION: 11b. Install and early-boot timeline (Linux)
    # See https://yuruna.link/423ef7f5-000b
    if ($IsLinux) {
        Invoke-DiagnosticSection "INSTALL & EARLY-BOOT TIMELINE (Linux)" {
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_0e79617cabbe97da')
            $installerListing = @(Invoke-PrivProbe -Tool 'find' -ToolArgs @('/var/log/installer','-maxdepth','1','-type','f','-printf','%f\t%s bytes\n') -KeepStderr)
            $installerListing | ForEach-Object { Write-Output $_ }
            $installerNames = @($installerListing | ForEach-Object { ($_ -split "`t",2)[0] })

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_5f419145bd02451c')
            $data = Read-LinuxDiagnosticFile -Path '/var/log/installer/autoinstall-user-data' -MetadataOnly
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bc9fc9dd34fb6538' -Arguments @{ state = "$($data.State)" })
            $data.Lines | ForEach-Object { Write-Output $_ }

            Write-Sub "/var/log/installer/subiquity-server-debug.log (scan + tail 100)"
            $data = Read-LinuxDiagnosticFile -Path '/var/log/installer/subiquity-server-debug.log'
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bc9fc9dd34fb6538' -Arguments @{ state = "$($data.State)" })
            if ($data.State -eq 'read') {
                $sub = $data.Lines
                $sendUpdate = @($sub | Where-Object { $_ -match '_send_update' })
                $changeIfaces = @($sub | Where-Object { $_ -match 'CHANGE\s+(eth0|enp0s1|ens3|en0)' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_db2c708f71117181' -FormatValues ($sendUpdate.Count) -FormatBindings @{ count = '0' })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_8ea0ca42f7ecc9f7' -FormatValues ($changeIfaces.Count) -FormatBindings @{ count = '0' })
                if ($sendUpdate.Count -ge 200) {
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_9e80c4507aa91ce1' -FormatValues ($sendUpdate.Count) -FormatBindings @{ count = '0' }) -Class 'INSTALL.subiquity-change-loop'
                }
                $sub | Where-Object { $_ -match 'Retrying|mirror.*retry|elect.*mirror|geoip' } | Select-Object -First 20 | ForEach-Object { Write-Output $_ }
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_034d601f7f7cdb2e')
                $sub | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
            }

            $curtinNames = @($installerNames | Where-Object { $_ -in @('subiquity-curtin-install.log','curtin-install.log') })
            if ($curtinNames.Count -eq 0) { $curtinNames = @('subiquity-curtin-install.log','curtin-install.log') }
            foreach ($curtinName in $curtinNames) {
                Write-Sub "/var/log/installer/$curtinName (scan + tail 80)"
                $data = Read-LinuxDiagnosticFile -Path "/var/log/installer/$curtinName"
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bc9fc9dd34fb6538' -Arguments @{ state = "$($data.State)" })
                if ($data.State -eq 'read') {
                    $curtin = $data.Lines
                    $retries = @($curtin | Where-Object { $_ -match 'Retrying|retry|TimeoutError|ConnectionError|temporary failure' })
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_428373fe65b0a16b' -FormatValues ($retries.Count) -FormatBindings @{ count = '0' })
                    if ($retries.Count -ge 5) {
                        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_92e7c51c10f09b59' -FormatValues ($retries.Count) -FormatBindings @{ count = '0' }) -Class 'INSTALL.curtin-retries'
                        $retries | Select-Object -First 10 | ForEach-Object { Write-Output $_ }
                    }
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a09a0f237d2b144a')
                    $curtin | Select-Object -Last 80 | ForEach-Object { Write-Output $_ }
                }
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_be35048de6a6280c')
            if (Test-CommandAvailable 'cloud-init') {
                Invoke-Tool -Tool 'cloud-init' -ToolArgs @('status','--long')
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_189417db054e12ad')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_f779d2d738d724fe')
            if (Test-CommandAvailable 'cloud-init') {
                $analyzeOut = & cloud-init analyze blame 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $analyzeOut | Select-Object -First 25 | ForEach-Object { Write-Output $_ }
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b34ace96616eb2ca' -FormatValues ($LASTEXITCODE) -FormatBindings @{ lASTEXITCODE = '0' })
                }
            }

            foreach ($cloudPath in @('/run/cloud-init/result.json','/run/cloud-init/status.json','/var/log/cloud-init.log','/var/log/cloud-init-output.log')) {
                Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_9928c4ddab42f536' -Arguments @{ cloudPath = "$cloudPath" })
                $data = Read-LinuxDiagnosticFile -Path $cloudPath
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_bc9fc9dd34fb6538' -Arguments @{ state = "$($data.State)" })
                $data.Lines | Select-Object -Last 200 | ForEach-Object { Write-Output $_ }
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_691593f6f5a4fa03')
            if (Test-CommandAvailable 'systemd-analyze') {
                Invoke-Tool -Tool 'systemd-analyze' -ToolArgs @('time')
                Write-Output ""
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e2efc72fae64b6d2')
                $blame = & systemd-analyze blame 2>$null
                $blame | Select-Object -First 20 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_8e9c512867ac6ba2')
            }

            Write-Sub "journalctl --list-boots"
            if (Test-CommandAvailable 'journalctl') {
                Invoke-Tool -Tool 'journalctl' -ToolArgs @('--list-boots','--no-pager') -Privileged
            } else { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_88570e5c6483f2df') }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_fd2a582c09e3d15d')
            if (Test-CommandAvailable 'journalctl') {
                $prev = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-b','-1','-p','warning','--no-pager')
                if ($prev) {
                    $prev | Select-Object -First 60 | ForEach-Object { Write-Output $_ }
                    if ($prev.Count -gt 120) {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_80b291736892294d' -FormatValues (($prev.Count - 120)) -FormatBindings @{ count = '0' })
                        $prev | Select-Object -Last 60 | ForEach-Object { Write-Output $_ }
                    } elseif ($prev.Count -gt 60) {
                        $prev | Select-Object -Skip 60 | ForEach-Object { Write-Output $_ }
                    }
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ac55f29eb491874d')
                }
            }

            Write-Sub "journalctl -b 0 -u systemd-networkd --no-pager (last 100)"
            if (Test-CommandAvailable 'journalctl') {
                $nw = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-b','0','-u','systemd-networkd','--no-pager')
                if ($nw) {
                    $nw | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_06a1feb4b6be0aba')
                }
            }

            Write-Sub "journalctl -b 0 -u NetworkManager --grep dhcp4 -n 100 --no-pager"
            if (Test-CommandAvailable 'journalctl') {
                Get-LinuxNetworkManagerDhcpLine | ForEach-Object { Write-Output $_ }
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_91db0522b1d981fb')
            if (Test-CommandAvailable 'networkctl') {
                Invoke-Tool -Tool 'networkctl' -ToolArgs @('status','--all','--no-pager') -Privileged
            } else { Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_beb381d52a393ad5') }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_4a34878c962422f2')
            if (Test-CommandAvailable 'ip') {
                Invoke-Tool -Tool 'ip' -ToolArgs @('-br','link')
                Write-Output ""
                Invoke-Tool -Tool 'ip' -ToolArgs @('-br','addr')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_abe933a8d836ad06')
            if (Test-CommandAvailable 'dmesg') {
                $dm = Invoke-PrivProbe -Tool 'dmesg' -ToolArgs @('-T')
                if ($LASTEXITCODE -eq 0) {
                    $hits = @($dm | Where-Object { $_ -match '(?i)eth0|netvsc|hv_|carrier|link is|accept_ra|NEWLINK' })
                    if ($hits.Count -eq 0) {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2e15c2e53d3f7ff5')
                    } else {
                        $hits | Select-Object -Last 80 | ForEach-Object { Write-Output $_ }
                    }
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_641722ebda2acafc')
                }
            }
        }
    }

    # --- REGION: 11c. Guest provisioning (Linux)
    # See https://yuruna.link/42fa6f45-0013 (section 11c)
    if ($IsLinux) {
        Invoke-DiagnosticSection "GUEST PROVISIONING (Linux)" {
            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_d2b8e5f19799eb58')
            if (Test-Path '/var/log/yuruna') {
                $items = @(Get-ChildItem -Path '/var/log/yuruna' -Force -ErrorAction SilentlyContinue | Sort-Object Name)
                if ($items.Count -eq 0) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9911832dfc6a1a02')
                } else {
                    foreach ($it in $items) {
                        $size = if ($it.PSIsContainer) { '<DIR>' } else { ("{0,10}" -f $it.Length) }
                        Write-Output ("  {0}  {1}" -f $size, $it.Name)
                    }
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_94793b409f5adbb8')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_bc13de7101298f4c')
            if (Test-Path '/var/log/yuruna') {
                $logs = @(Get-ChildItem -Path '/var/log/yuruna' -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
                if ($logs.Count -eq 0) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6ba42815e2c0ef04')
                } else {
                    foreach ($log in $logs) {
                        Write-Output ""
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_43adba726850fef5' -FormatValues ($log.Name, $log.Length) -FormatBindings @{ name = '0'; length = '1' })
                        Get-Content -LiteralPath $log.FullName -ErrorAction SilentlyContinue |
                            ForEach-Object { Write-Output $_ }
                        # The verdict is the record the wrapper wrote, not a
                        # sentence recognized in the log. The wrapper's prose
                        # goes to the caller's stderr and never reaches this
                        # file at all, so matching it found nothing on any real
                        # run -- and would have followed the host's language
                        # even if it had.
                        foreach ($line in @(Get-Content -LiteralPath $log.FullName -ErrorAction SilentlyContinue |
                                Where-Object { $_ -like 'YURUNA_RETRY *' })) {
                            $record = $null
                            try { $record = ConvertFrom-Json -InputObject $line.Substring('YURUNA_RETRY '.Length) -ErrorAction Stop }
                            catch { $record = $null }
                            if (-not $record -or [string]$record.event -cne 'outcome') { continue }
                            switch ([string]$record.outcome) {
                                'exhausted' {
                                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_fb806fabc4ba34ba' -FormatValues ($log.Name, $record.label, $record.maxAttempts, $record.rc) -FormatBindings @{ name = '0'; label = '1'; maxAttempts = '2'; rc = '3' }) -Class 'PROVISIONING.retry-exhausted'
                                }
                                'permanent' {
                                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_6122beada92e6164' -FormatValues ($log.Name, $record.label, $record.attempt, $record.maxAttempts, $record.rc) -FormatBindings @{ name = '0'; label = '1'; attempt = '2'; maxAttempts = '3'; rc = '4' }) -Class 'PROVISIONING.retry-permanent'
                                }
                            }
                        }
                    }
                }
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_f92f81ef8113846a')
            if (Test-CommandAvailable 'journalctl') {
                $r = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-u','systemd-resolved','--since','15 min ago','--no-pager')
                if ($r) {
                    $r | Select-Object -Last 80 | ForEach-Object { Write-Output $_ }
                } else {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_07fabc30d24cd858')
                }
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_88570e5c6483f2df')
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_c2d1de94ff3d2321')
            try {
                Get-PSRepository -ErrorAction Stop |
                    Format-List Name,SourceLocation,InstallationPolicy,Trusted | Out-String |
                    ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_29759c8a58f5d70a' -FormatValues ($_.Exception.Message) -FormatBindings @{ message = '0' })
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_29e3b381e78aec31') -Class 'PROVISIONING.repository-unavailable'
            }
            Write-Output "--- PackageProvider -ListAvailable ---"
            try {
                Get-PackageProvider -ListAvailable -ErrorAction Stop |
                    Select-Object Name,Version | Format-Table -AutoSize | Out-String |
                    ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_c954ba96bb4cba77' -FormatValues ($_.Exception.Message) -FormatBindings @{ message = '0' })
            }
            Write-Output "--- Modules (PowerShellGet, PSResourceGet, powershell-yaml) ---"
            try {
                Get-Module PowerShellGet, Microsoft.PowerShell.PSResourceGet, powershell-yaml -ListAvailable |
                    Select-Object Name,Version | Format-Table -AutoSize | Out-String |
                    ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_1228b31b1ce78688' -FormatValues ($_.Exception.Message) -FormatBindings @{ message = '0' })
            }
        }
    }

    # --- REGION: 12. Yuruna project
    Invoke-DiagnosticSection "YURUNA PROJECT" {
        if ($SkipProjectGaps) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_0c0b6c2779c42621')
            return
        }
        if (-not $script:DiagnosticEvidenceRoot) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.diagnostic_checkout_unavailable')
            return
        }
        $candidate   = Join-Path -Path $script:DiagnosticEvidenceRoot -ChildPath 'project'
        $projectRoot = $null
        $projectDirectory = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($projectDirectory -is [IO.DirectoryInfo] -and
            -not ($projectDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $projectRoot = $projectDirectory.FullName
        }
        if (-not $projectRoot) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_aa6b37528c8d7be2' -Arguments @{ candidate = "$candidate" })
            return
        }
        $yurunaRoot     = $script:DiagnosticEvidenceRoot
        $yurunaVerFile  = Join-Path -Path $yurunaRoot  -ChildPath 'VERSION'
        $projectVerFile = Join-Path -Path $projectRoot -ChildPath 'VERSION'

        function Get-RemoteOriginUrl {
            param([Parameter(Mandatory)][string]$RepoPath)
            if (Test-CommandAvailable 'git') {
                try {
                    $url = & git -C $RepoPath config --get remote.origin.url 2>$null
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($url)) {
                        return ([string]$url).Trim()
                    }
                } catch {
                    Write-Verbose "Get-RemoteOriginUrl: git config failed for '$RepoPath' ($($_.Exception.Message)); trying sidecar."
                }
            }
            # Tarball-extracted trees have no .git/, so fall back to the
            # sidecar the status service's archive route injects via `git archive --add-file`.
            $marker = Join-Path -Path $RepoPath -ChildPath '.yuruna-origin'
            if (Test-Path -LiteralPath $marker) {
                $line = Get-Content -LiteralPath $marker -TotalCount 1 -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    return ([string]$line).Trim()
                }
            }
            return $null
        }

        $yurunaVersion  = $null
        if (Test-Path -LiteralPath $yurunaVerFile) {
            $firstLine = Get-Content -LiteralPath $yurunaVerFile -TotalCount 1 -ErrorAction SilentlyContinue
            if ($null -ne $firstLine) { $yurunaVersion = ([string]$firstLine).Trim() }
        }
        if ([string]::IsNullOrWhiteSpace($yurunaVersion)) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_90d269f47f52341e' -Arguments @{ yurunaVerFile = "$yurunaVerFile" })
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_ea67c1a52bd67b37' -Arguments @{ yurunaVerFile = "$yurunaVerFile" }) -Class 'YURUNA.version-missing'
        } else {
            $yurunaOrigin = Get-RemoteOriginUrl -RepoPath $yurunaRoot
            if ([string]::IsNullOrWhiteSpace($yurunaOrigin)) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_54bb3bd3dc906778' -Arguments @{ yurunaVersion = "$yurunaVersion" })
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_75f1073141152b04' -Arguments @{ yurunaVersion = "$yurunaVersion"; yurunaOrigin = "$yurunaOrigin" })
            }
        }
        $projectVersion = $null
        if (Test-Path -LiteralPath $projectVerFile) {
            $firstLine = Get-Content -LiteralPath $projectVerFile -TotalCount 1 -ErrorAction SilentlyContinue
            if ($null -ne $firstLine) { $projectVersion = ([string]$firstLine).Trim() }
        }
        if ([string]::IsNullOrWhiteSpace($projectVersion)) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_76bd42e13cff8e8c' -Arguments @{ projectVerFile = "$projectVerFile" })
            Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_b67daf1100c845ef' -Arguments @{ projectVerFile = "$projectVerFile" }) -Class 'YURUNA.project-version-missing'
        } else {
            $projectOrigin = Get-RemoteOriginUrl -RepoPath $projectRoot
            if ([string]::IsNullOrWhiteSpace($projectOrigin)) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f623437c4d70cbb4' -Arguments @{ projectVersion = "$projectVersion" })
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f4880cadf6480c92' -Arguments @{ projectVersion = "$projectVersion"; projectOrigin = "$projectOrigin" })
            }
        }
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b4aa23b7a1644d14' -Arguments @{ projectRoot = "$projectRoot" })

        $outputWalk = Get-FileTreeWithDeadline -Label 'resources.output.yml scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Filter 'resources.output.yml' -File -ErrorAction SilentlyContinue
        }
        Show-FileTreeWalkTimeout -Walk $outputWalk
        $outputFiles = @($outputWalk.Items)
        if ($outputFiles.Count -eq 0) {
            Write-Sub "resources.output.yml"
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b97395da00cd6199' -Arguments @{ projectRoot = "$projectRoot" })
        } else {
            foreach ($of in $outputFiles) {
                Write-Sub $of.FullName
                $content = $null
                try {
                    $content = Get-Content -LiteralPath $of.FullName -Raw -ErrorAction Stop
                } catch {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e89fa5be525e6ab3' -Arguments @{ message = "$($_.Exception.Message)" })
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($content)) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9dcd9b109c2d9e64')
                    Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_add466496962fbf6' -FormatValues ($of.FullName) -FormatBindings @{ fullName = '0' }) -Class 'YURUNA.output-empty'
                    continue
                }
                Write-Output $content

                $lines  = $content -split "`r?`n"
                $issues = [System.Collections.Generic.List[string]]::new()
                $pendingKey         = $null
                $pendingKeyLine     = -1
                $pendingHasContent  = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $raw = $lines[$i]
                    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                    $trimmedStart = $raw.TrimStart()
                    if ($trimmedStart.StartsWith('#')) { continue }
                    if ($trimmedStart.StartsWith('---')) { continue }
                    if ($raw -match '^([A-Za-z_][A-Za-z0-9_.-]*):\s*(.*?)\s*$') {
                        if ($null -ne $pendingKey -and -not $pendingHasContent) {
                            $issues.Add(("top-level resource block '{0}' (line {1}) is present but empty -- a downstream chart that does `index .Values `"{0}.<output>`"` will render an empty string and silently produce a malformed value (e.g. an InvalidImageName pod). Run 'yuruna resources <project> <env>' to (re)capture this resource's tofu output." -f $pendingKey, ($pendingKeyLine + 1)))
                        }
                        $pendingKey        = $Matches[1]
                        $pendingKeyLine    = $i
                        $sameLineVal       = $Matches[2]
                        $pendingHasContent = (-not [string]::IsNullOrWhiteSpace($sameLineVal)) -and ($sameLineVal -notmatch '^(null|~|\{\}|\[\])$')
                    } elseif ($raw -match '^\s+\S') {
                        $pendingHasContent = $true
                    }
                }
                if ($null -ne $pendingKey -and -not $pendingHasContent) {
                    $issues.Add(("top-level resource block '{0}' (line {1}) is present but empty" -f $pendingKey, ($pendingKeyLine + 1)))
                }
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^\s+value:\s*$') {
                        $parent = '?'
                        for ($j = $i - 1; $j -ge 0; $j--) {
                            if ($lines[$j] -match '^\s+([A-Za-z_][A-Za-z0-9_.-]*):\s*$') { $parent = $Matches[1]; break }
                        }
                        $issues.Add(("empty 'value:' for nested field '{0}' (line {1}) -- tofu captured the output name but its value was empty/null" -f $parent, ($i + 1)))
                    }
                }

                if ($issues.Count -gt 0) {
                    Write-Output ""
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a5f5181e50794260')
                    foreach ($iss in $issues) {
                        Write-Output ("    * {0}" -f $iss)
                        Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_d700912928a3d5ac' -FormatValues ($of.FullName, $iss) -FormatBindings @{ fullName = '0'; iss = '1' }) -Class 'YURUNA.output-problem'
                    }
                }
            }
        }

        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_dff7d59ece61e081')
        $yurunaWalk = Get-FileTreeWithDeadline -Label '.yuruna/ directory scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq '.yuruna' }
        }
        Show-FileTreeWalkTimeout -Walk $yurunaWalk
        $yurunaDirs = @($yurunaWalk.Items)
        if ($yurunaDirs.Count -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_6647068482edb16a' -Arguments @{ projectRoot = "$projectRoot" })
        } else {
            $skipPathFragments = @(
                [IO.Path]::DirectorySeparatorChar + '.terraform' + [IO.Path]::DirectorySeparatorChar + 'providers' + [IO.Path]::DirectorySeparatorChar
            )
            $skipExtensions = @('.exe','.dll','.so','.dylib','.zip','.tar','.gz','.tgz','.bz2','.xz','.7z','.rar','.iso','.img','.qcow2','.vhd','.vhdx','.png','.jpg','.jpeg','.gif','.ico','.pdf','.class','.pyc')

            $denyTerms = @(
                'failureThreshold',
                'ErrorAction',
                'WarningLevel'
            )
            $denyPattern = $null
            if ($denyTerms.Count -gt 0) {
                $escaped = $denyTerms | ForEach-Object { [regex]::Escape($_) }
                $denyPattern = '(?i)\b(?:' + ($escaped -join '|') + ')\w*\b'
            }
            $totalMatches = 0
            $filesScanned = 0
            $filesSkipped = 0
            $linesFiltered = 0
            foreach ($yd in $yurunaDirs) {
                $fileWalk = Get-FileTreeWithDeadline -Label ("file scan of {0}" -f $yd.FullName) -ArgumentList @($yd.FullName) -ScriptBlock {
                    param($dir)
                    Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue
                }
                Show-FileTreeWalkTimeout -Walk $fileWalk
                $files = @($fileWalk.Items)
                foreach ($fi in $files) {
                    if ($fi.Length -gt 5MB)             { $filesSkipped++; continue }
                    if ($skipExtensions -contains $fi.Extension.ToLowerInvariant()) { $filesSkipped++; continue }
                    $skipByPath = $false
                    foreach ($frag in $skipPathFragments) {
                        if ($fi.FullName -like ('*' + $frag + '*')) { $skipByPath = $true; break }
                    }
                    if ($skipByPath) { $filesSkipped++; continue }
                    $filesScanned++
                    $hits = $null
                    try {
                        $hits = @(Select-String -LiteralPath $fi.FullName -Pattern '\b(error|fail|warning)' -CaseSensitive:$false -ErrorAction SilentlyContinue)
                    } catch {
                        continue
                    }
                    if (-not $hits -or $hits.Count -eq 0) { continue }
                    $keptHits = New-Object System.Collections.Generic.List[object]
                    foreach ($h in $hits) {
                        $line = $h.Line
                        if ($null -eq $line) { continue }
                        if ($denyPattern) {
                            $stripped = [regex]::Replace($line, $denyPattern, '')
                            if ($stripped -notmatch '(?i)\b(error|fail|warning)') {
                                $linesFiltered++
                                continue
                            }
                        }
                        $keptHits.Add($h)
                    }
                    if ($keptHits.Count -eq 0) { continue }
                    Write-Output ""
                    Write-Output $fi.FullName
                    foreach ($h in $keptHits) {
                        $line = $h.Line
                        if ($null -eq $line) { continue }
                        $line = $line.TrimEnd()
                        if ($line.Length -gt 64) { $line = $line.Substring(0, 64) }
                        Write-Output ("    {0}" -f $line)
                        $totalMatches++
                    }
                }
            }
            Write-Output ""
            Write-Output ((Format-YurunaOperatorMessage -Key 'automation.operator_8833009c9a699b81' -Arguments @{ filesScanned = "$filesScanned"; filesSkipped = "$filesSkipped"; totalMatches = "$totalMatches"; linesFiltered = "$linesFiltered" }))
            if ($totalMatches -gt 0) {
                Add-Problem (Format-YurunaOperatorMessage -Key 'automation.operator_ac1256277a04aa2e' -FormatValues ($totalMatches) -FormatBindings @{ totalMatches = '0' }) -Class 'YURUNA.project-problems'
            }

            Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_55c150c8e52ed5c6')
            $allFiles = New-Object System.Collections.Generic.List[object]
            foreach ($yd in $yurunaDirs) {
                $mtimeWalk = Get-FileTreeWithDeadline -Label ("mtime scan of {0}" -f $yd.FullName) -ArgumentList @($yd.FullName) -ScriptBlock {
                    param($dir)
                    Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue
                }
                Show-FileTreeWalkTimeout -Walk $mtimeWalk
                foreach ($f in @($mtimeWalk.Items)) { $allFiles.Add($f) }
            }
            if ($allFiles.Count -eq 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a96e14d3e499c9a0')
            } else {
                $recent = $allFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 100
                foreach ($f in $recent) {
                    $rel = $f.FullName
                    if ($rel.StartsWith($projectRoot)) { $rel = $rel.Substring($projectRoot.Length).TrimStart('\','/') }
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_97aa0bbd89aefd9a' -FormatValues ($f.LastWriteTime, $f.Length, $rel) -FormatBindings @{ lastWriteTime = '0:yyyy-MM-dd HH:mm:ss'; length = '1,10'; rel = '2' })
                }
                $newest = $recent | Select-Object -First 1
                $ageMinutes = [int]((Get-Date) - $newest.LastWriteTime).TotalMinutes
                Write-Output ""
                Write-Output ((Format-YurunaOperatorMessage -Key 'automation.operator_bfcbf1a3d4f19f5d' -Arguments @{ ss = "$($newest.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture))" } -FormatValues ($ageMinutes) -FormatBindings @{ ageMinutes = '0' }))
            }
        }
    }

    # --- REGION: 13. Gap heuristics
    # See https://yuruna.link/423ef7f5-000e
    Invoke-DiagnosticSection "GAP HEURISTICS" {
        if ($SkipProjectGaps) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_0c0b6c2779c42621')
            return
        }
        if (-not $script:DiagnosticEvidenceRoot) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.diagnostic_checkout_unavailable')
            return
        }
        $candidate   = Join-Path -Path $script:DiagnosticEvidenceRoot -ChildPath 'project'
        $projectRoot = $null
        $projectDirectory = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($projectDirectory -is [IO.DirectoryInfo] -and
            -not ($projectDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $projectRoot = $projectDirectory.FullName
        }
        if (-not $projectRoot) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_7d384e5a632109dd' -Arguments @{ candidate = "$candidate" })
            return
        }

        $kubectlReady = ($null -ne (Get-Command 'kubectl' -ErrorAction SilentlyContinue)) -and (-not $SkipKube)
        $helmReady    = $null -ne (Get-Command 'helm'    -ErrorAction SilentlyContinue)

        # --- REGION: Heuristic 1: tofu.tfstate exists but helm has zero releases
        # See https://yuruna.link/423ef7f5-000f
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_5e0cc0356ca62c91')
        $tfStateWalk = Get-FileTreeWithDeadline -Label 'tofu.tfstate scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Filter 'tofu.tfstate' -File -ErrorAction SilentlyContinue
        }
        Show-FileTreeWalkTimeout -Walk $tfStateWalk
        $tfStateFiles = @($tfStateWalk.Items)
        $tfStateCount = $tfStateFiles.Count
        if ($tfStateCount -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_4221b57b738104bc' -Arguments @{ projectRoot = "$projectRoot" })
        } elseif (-not $helmReady) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_39b5280c08d21d32' -Arguments @{ tfStateCount = "$tfStateCount" })
        } else {
            $helmCount = 0
            try {
                $helmCount = (Get-DiagnosticHelmSnapshot).Releases.Count
            } catch {
                Write-Verbose ("helm list failed: {0}" -f $_.Exception.Message)
            }
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_3263dfddfd59f8af' -FormatValues ($tfStateCount, $helmCount) -FormatBindings @{ tfStateCount = '0'; helmCount = '1' })
            if ($helmCount -eq 0) {
                Add-Problem -Class 'GAP.tofu-state-without-helm-releases' -Message ((Format-YurunaOperatorMessage -Key 'automation.operator_72c1075973a89231' -Arguments @{ tfStateCount = "$tfStateCount" }))
            }
        }

        # --- REGION: Heuristic 2: resources.output.yml declares a namespace that doesn't exist in the cluster
        # See https://yuruna.link/423ef7f5-0010
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_4272d9bd74626ac9')
        $nsOutputWalk = Get-FileTreeWithDeadline -Label 'resources.output.yml scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Filter 'resources.output.yml' -File -ErrorAction SilentlyContinue
        }
        Show-FileTreeWalkTimeout -Walk $nsOutputWalk
        $outputFiles = @($nsOutputWalk.Items)
        if ($outputFiles.Count -eq 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_f95d3804292ed206' -Arguments @{ projectRoot = "$projectRoot" })
        } elseif (-not $kubectlReady) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_d27a1042e1f11ccd' -Arguments @{ count = "$($outputFiles.Count)" })
        } else {
            $declaredNs = New-Object System.Collections.Generic.List[object]
            foreach ($of in $outputFiles) {
                try {
                    $content = Get-Content -LiteralPath $of.FullName -Raw -ErrorAction Stop
                } catch { continue }
                # --- REGION: https://yuruna.link/423ef7f5-0010
                $inGlobals = $false
                foreach ($raw in ($content -split "`r?`n")) {
                    if ($raw -match '^globalVariables:\s*$') { $inGlobals = $true; continue }
                    if ($inGlobals -and $raw -match '^\S') { $inGlobals = $false; continue }
                    if ($inGlobals -and $raw -match '^\s+namespace:\s*[''"]?([^''"\s]+)[''"]?\s*$') {
                        $declaredNs.Add(@{ Name = $Matches[1]; File = $of.FullName })
                    }
                }
            }
            if ($declaredNs.Count -eq 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_007dba8c891ef14e')
            } else {
                $clusterNs = @(Get-DiagnosticKubeSnapshot -Resource ns | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
                foreach ($d in $declaredNs) {
                    if ($clusterNs -contains $d.Name) {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_13444d1232596727' -FormatValues ($d.Name, $d.File) -FormatBindings @{ name = '0'; file = '1' })
                    } else {
                        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_ea04ff3f63fe8b95' -FormatValues ($d.Name, $d.File) -FormatBindings @{ name = '0'; file = '1' })
                        Add-Problem -Class 'GAP.declared-namespace-missing' -Message ((Format-YurunaOperatorMessage -Key 'automation.operator_6026e7f1ae4f2ef0' -Arguments @{ name = "$($d.Name)"; file = "$($d.File)" }))
                    }
                }
            }
        }

        # --- REGION: Heuristic 3: nodes Ready but zero user-namespace pods
        # See https://yuruna.link/423ef7f5-0011
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_94cff3770e209f03')
        if (-not $kubectlReady) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a393cb03dba55e4a')
        } else {
            $readyNodes = @(Get-DiagnosticKubeSnapshot -Resource nodes |
                Where-Object { ($_ -split '\s+')[1] -match '^Ready' })
            if ($readyNodes.Count -eq 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_47229a44b80ae93b')
            } else {
                $systemNs = @('default','kube-system','kube-public','kube-node-lease','kube-flannel','kube-proxy')
                $userPods = @(Get-DiagnosticKubeSnapshot -Resource pods |
                    ForEach-Object {
                        $cols = $_ -split '\s+'
                        if ($cols.Count -ge 2 -and $systemNs -notcontains $cols[0]) { $_ }
                    })
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e6aeb3342245f36c' -FormatValues ($readyNodes.Count, $userPods.Count) -FormatBindings @{ count = '0'; count2 = '1' })
                if ($userPods.Count -eq 0) {
                    Add-Problem -Class 'GAP.cluster-ready-but-no-user-pods' -Message ((Format-YurunaOperatorMessage -Key 'automation.operator_b2e83136c96ad810' -Arguments @{ count = "$($readyNodes.Count)" }))
                }
            }
        }

        # --- REGION: Heuristic 4: image in local registry but no pod references it
        # See https://yuruna.link/423ef7f5-0012
        Write-Sub (Format-YurunaOperatorMessage -Key 'automation.operator_45ac4b861def17e9')
        if (-not $kubectlReady) {
            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_a393cb03dba55e4a')
        } else {
            $registryRepos = Get-LocalRegistryCatalog
            if ($null -eq $registryRepos) { $registryRepos = @() }
            if ($registryRepos.Count -eq 0) {
                Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b78019a8c5b4d334')
            } else {
                # Containers + initContainers + ephemeralContainers, all namespaces.
                # Keep the invocation and the transformation as separate statements, and
                # use jsonpath's own \n escape as the separator: otherwise the image
                # list comes back empty or unsplit, and every registry repo looks
                # unreferenced.
                # See https://yuruna.link/4213a0b3-019a
                $imageJsonPath = '{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.ephemeralContainers[*]}{.image}{"\n"}{end}{end}'
                $imagesRaw = & kubectl get pods -A --request-timeout=5s -o jsonpath=$imageJsonPath 2>$null
                if ($LASTEXITCODE -ne 0) {
                    # A probe that failed is not evidence of an orphan. Say the
                    # cross-check could not run and stop, rather than reporting
                    # the empty result as a finding.
                    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_78d2e6388bf62f89')
                    $allImages = $null
                } else {
                    $allImages = @($imagesRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
                if ($null -ne $allImages) {
                    $orphans = @()
                    foreach ($repo in $registryRepos) {
                        # --- REGION: https://yuruna.link/423ef7f5-0012
                        $needle = "/$repo`:"
                        $matched = @($allImages | Where-Object { $_ -like "*$needle*" })
                        if ($matched.Count -eq 0) {
                            $orphans += $repo
                            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_e06453a569393d9a' -FormatValues ($repo) -FormatBindings @{ repo = '0' })
                        } else {
                            Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_892002ebf63081aa' -FormatValues ($repo, $matched.Count) -FormatBindings @{ repo = '0'; count = '1' })
                        }
                    }
                    if ($orphans.Count -gt 0) {
                        Add-Problem -Class 'GAP.registry-image-not-referenced' -Message ((Format-YurunaOperatorMessage -Key 'automation.operator_4b5000e2da8b0a45' -Arguments @{ count = "$($orphans.Count)"; join = "$($orphans -join ', ')" }))
                    }
                }
            }
        }
    }

    # --- REGION: 14. Summary
    Write-Section (Format-YurunaOperatorMessage -Key 'automation.operator_d06b949771ace46b')
    if ($script:Problems.Count -eq 0) {
        Write-Output "(none)"
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2c1747899df468d4' -FormatValues ($script:Problems.Count) -FormatBindings @{ count = '0' })
        $i = 0
        foreach ($p in $script:Problems) {
            $i++
            Write-Output ("  {0,3}. {1}" -f $i, $p)
        }
    }

    # Machine-readable mirror of the prose list above. Emitted after (never instead
    # of) the human summary; a consumer parses the sentinel-bracketed line to select
    # problems by class.
    Write-ProblemJson -SidecarBasePath $OutFile

    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_926bc2ef75b29511')

} finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null }
        catch { Write-Verbose "Stop-Transcript on cleanup raised: $($_.Exception.Message)" }
    }
}
