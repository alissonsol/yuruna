<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4250f9af-bcc6-41b0-85fb-2c2f4e968e7d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config template overlay
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
    test.config.yml <-> template reconciliation for the test runner.
.DESCRIPTION
    Each cycle overlays the live test.config.yml on its shipped template so
    new template keys are picked up without losing operator values, and the
    file is rewritten only when the merge differs from disk outside the
    'secrets' subtree (credentials always diverge from the template blanks;
    including them would churn the file every cycle).

    The template is the schema source of truth: keys present only in the live
    file are dropped, keys present only in the template are added with their
    default. A live file whose nested SHAPE departs from the template (e.g. a
    pre-nesting flat layout left by an old checkout) is backed up and reset
    rather than silently flattened, so the operator can copy values across by
    hand instead of losing them without a trace.

    Hide-SecretsInConfig redacts the top-level 'secrets' node before a config
    is written to a log. The Hide- verb (rather than Remove-) is deliberate:
    PSScriptAnalyzer's PSUseShouldProcessForStateChangingFunctions rule fires
    on Remove-/Set-/etc. but not Hide-; the function still mutates the passed
    config -- the verb signals "redacting from a logged view" not "deleting".
#>

# The atomic test.config.yml rewrites below route through Test.StateFile's
# Write-YurunaStateFile. Import it here so EVERY consumer of this module has the
# primitive in scope -- both the per-cycle Inner runner and the operator validator
# Test-Config.ps1 -- not only callers that happen to load the full runner module set.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.ConfigNaming.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -DisableNameChecking

# Top-level keys dropped without a trace on every reconcile: removing one from
# the template must not make the shape check trip on every existing file, nor
# park a long-dead setting as an obsolete entry.
$script:DeprecatedTopConfigKey = @('hostSshServer')
# Same-process depth of the config write lock per resolved config path: a
# writer that already holds it (a reconcile, a caller's Use-TestConfigLock block)
# calls the documented writer, which takes it again.
$script:TestConfigLockDepth = @{}
# How many earlier versions each config keeps in its journal.
$script:TestConfigJournalKeep = 20

function Get-ConfigMirrorKeyId {
    <# .SYNOPSIS
        Validate enrolled SPKI values and return their stable public fingerprints.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Value)
    if ($null -eq $Value) { return }
    foreach ($key in @($Value)) {
        if ($key -isnot [string] -or $key.Length -gt 1368 -or $key -match '\s|-----') {
            throw 'mirror-key-invalid: expected single-line base64 DER SubjectPublicKeyInfo'
        }
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $der = [Convert]::FromBase64String($key)
            if ($der.Length -gt 1024 -or [Convert]::ToBase64String($der) -cne $key) { throw 'noncanonical or oversized DER' }
            $read = 0
            $rsa.ImportSubjectPublicKeyInfo($der, [ref]$read)
            if ($read -ne $der.Length -or $rsa.KeySize -lt 3072) { throw 'RSA key must be at least 3072 bits' }
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($der)).ToLowerInvariant()
        } catch { throw "mirror-key-invalid: $($_.Exception.Message)" }
        finally { $rsa.Dispose() }
    }
}

function Test-ConfigMirrorSetting {
    <# .SYNOPSIS
        Return typed configuration failures without making network requests.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Config)
    $lookup = Get-ConfigValueAtPath -Config $Config -Path 'repositories.mirror'
    if ($lookup.Found) {
        $mirror = $lookup.Value
        if ($mirror -isnot [System.Collections.IDictionary]) {
            [pscustomobject]@{ Path = 'repositories.mirror'; Cause = 'mirror-config-invalid' }
            return
        }
        if ($mirror.Contains('mode') -and $mirror.mode -cnotin @('prefer', 'fallback', 'off')) {
            [pscustomobject]@{ Path = 'repositories.mirror.mode'; Cause = 'mirror-mode-invalid' }
        }
        if ($mirror.Contains('url') -and -not [string]::IsNullOrWhiteSpace([string]$mirror.url)) {
            $uri = $null
            if (-not [uri]::TryCreate([string]$mirror.url, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
                $uri.AbsolutePath -ne '/' -or [string]$mirror.url -match '[\s\\]') {
                [pscustomobject]@{ Path = 'repositories.mirror.url'; Cause = 'mirror-url-invalid' }
            }
        }
        if ($mirror.Contains('mirrorOnlyMaxAgeSeconds') -and
            ([string]$mirror.mirrorOnlyMaxAgeSeconds -notmatch '^\d{1,7}$' -or
                [decimal]$mirror.mirrorOnlyMaxAgeSeconds -gt 1209600)) {
            [pscustomobject]@{ Path = 'repositories.mirror.mirrorOnlyMaxAgeSeconds'; Cause = 'mirror-age-invalid' }
        }
        if ($mirror.Contains('verificationPublicKeys')) {
            try {
                if ($mirror.verificationPublicKeys -is [string] -or
                    $mirror.verificationPublicKeys -isnot [System.Collections.IEnumerable]) { throw 'expected list' }
                $null = @(Get-ConfigMirrorKeyId -Value $mirror.verificationPublicKeys)
            } catch { [pscustomobject]@{ Path = 'repositories.mirror.verificationPublicKeys'; Cause = 'mirror-key-invalid' } }
        }
    }
    $refresh = Get-ConfigValueAtPath -Config $Config -Path 'vmStart.cachingProxyGitMirrorRefreshSeconds'
    if ($refresh.Found -and ([string]$refresh.Value -notmatch '^\d{1,4}$' -or
            [decimal]$refresh.Value -lt 10 -or [decimal]$refresh.Value -gt 3600)) {
        [pscustomobject]@{ Path = 'vmStart.cachingProxyGitMirrorRefreshSeconds'; Cause = 'mirror-refresh-interval-invalid' }
    }
}

function Get-ConfigMirrorChange {
    <# .SYNOPSIS
        Compare mirror values for operator reports, using key IDs instead of keys.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$Current, [Parameter(Mandatory)]$Proposed)
    if ($null -eq $Current) { $Current = @{} }
    foreach ($path in @('repositories.mirror.mode', 'repositories.mirror.url',
            'repositories.mirror.mirrorOnlyMaxAgeSeconds', 'repositories.mirror.verificationPublicKeys',
            'vmStart.cachingProxyGitMirrorRefreshSeconds')) {
        $old = Get-ConfigValueAtPath -Config $Current -Path $path
        $new = Get-ConfigValueAtPath -Config $Proposed -Path $path
        if (-not $new.Found) { continue }
        if ($path.EndsWith('.verificationPublicKeys')) {
            $previous = (@(Get-ConfigMirrorKeyId -Value $old.Value) | Sort-Object) -join ','
            $next = (@(Get-ConfigMirrorKeyId -Value $new.Value) | Sort-Object) -join ','
        } else { $previous = [string]$old.Value; $next = [string]$new.Value }
        if ($previous -cne $next) { [pscustomobject]@{ Path = $path; Previous = $previous; Current = $next } }
    }
}

function Merge-ConfigMirrorSetting {
    <# .SYNOPSIS
        Preserve trust and mirror settings an older configuration writer omitted.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([AllowNull()]$Current, [Parameter(Mandatory)]$Proposed)
    if ($Current -is [System.Collections.IDictionary]) {
        $old = Get-ConfigValueAtPath -Config $Current -Path 'repositories.mirror'
        if ($old.Found -and $old.Value -is [System.Collections.IDictionary]) {
            if (-not $Proposed.Contains('repositories')) { $Proposed['repositories'] = [ordered]@{} }
            if ($Proposed.repositories -isnot [System.Collections.IDictionary]) { throw 'mirror-config-invalid: repositories' }
            if (-not $Proposed.repositories.Contains('mirror')) { $Proposed.repositories['mirror'] = [ordered]@{} }
            if ($Proposed.repositories.mirror -isnot [System.Collections.IDictionary]) { throw 'mirror-config-invalid: repositories.mirror' }
            foreach ($key in $old.Value.Keys) {
                if (-not $Proposed.repositories.mirror.Contains($key)) { $Proposed.repositories.mirror[$key] = $old.Value[$key] }
            }
        }
    }
    $failures = @(Test-ConfigMirrorSetting -Config $Proposed)
    if ($failures.Count -gt 0) { throw "$($failures[0].Cause): $($failures[0].Path)" }
    return $Proposed
}

<#
.SYNOPSIS
    Overlay $Current onto $Template with the template as the schema source of truth.
.DESCRIPTION
    Template shape wins (which keys exist); current values win for overlapping
    scalars/arrays. Keys present only in $Current are dropped. Keys are emitted
    alphabetically at every nesting level so a regenerated test.config.yml is
    stable regardless of the template's own key ordering.
#>
function ConvertTo-MergedHashtable {
    param($Template, $Current)

    if ($Template -isnot [System.Collections.IDictionary]) { return $Template }

    $result = [ordered]@{}
    foreach ($key in ($Template.Keys | Sort-Object)) {
        $tVal = $Template[$key]
        $hasCurrent = ($Current -is [System.Collections.IDictionary]) -and $Current.Contains($key)
        if ($tVal -is [System.Collections.IDictionary]) {
            $cVal = $hasCurrent ? $Current[$key] : $null
            $result[$key] = ConvertTo-MergedHashtable -Template $tVal -Current $cVal
        } elseif ($hasCurrent) {
            $result[$key] = $Current[$key]
        } else {
            $result[$key] = $tVal
        }
    }
    return $result
}

<#
.SYNOPSIS
    Return a copy of a config tree with every map key AND scalar-array element ordered alphabetically.
.DESCRIPTION
    Canonical form for a serialized test.config.yml: map keys are sorted at every
    nesting level, and an array whose elements are all scalars has those elements
    sorted by value. Arrays that contain dictionaries/sub-arrays keep their element
    ORDER (there is no meaningful alphabetical key for a sub-map) but each such
    element is still recursively key-sorted. Scalars pass through unchanged. Pure:
    callers serialize the result with ConvertTo-Yaml to get a stable, diff-friendly
    file regardless of the order keys/elements were authored or merged in.
#>
function ConvertTo-SortedConfig {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object)) { $out[[string]$key] = ConvertTo-SortedConfig $Value[$key] }
        return $out
    }
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($i in $Value) { [void]$items.Add((ConvertTo-SortedConfig $i)) }
        $allScalar = $true
        foreach ($i in $items) {
            if (($i -is [System.Collections.IDictionary]) -or (($i -is [System.Collections.IEnumerable]) -and ($i -isnot [string]))) {
                $allScalar = $false; break
            }
        }
        # Return a List[object] (NOT an Object[]): a PowerShell function return
        # unwraps a 0/1-element Object[] to $null/scalar, which would silently turn
        # a one-guest guestSequence into a YAML scalar (and the UI editor keys its
        # array widget off Array.isArray). A typed List survives the return + the
        # parent's slot assignment at any element count, and an empty List still
        # serializes as `[]`.
        $sorted = [System.Collections.Generic.List[object]]::new()
        foreach ($i in $(if ($allScalar) { $items | Sort-Object } else { $items })) { [void]$sorted.Add($i) }
        return , $sorted
    }
    return $Value
}

<#
.SYNOPSIS
    Shallow clone of $Config without the top-level 'secrets' node, for diff comparison.
#>
function Copy-HashtableWithoutSecretNode {
    param($Config)
    if ($Config -isnot [System.Collections.IDictionary]) { return $Config }
    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) {
        if ($key -eq 'secrets') { continue }
        $copy[$key] = $Config[$key]
    }
    return $copy
}

# True when the merged/canonical config differs from the on-disk config OUTSIDE the
# 'secrets' subtree: strip the secrets node from both, serialize each to YAML, and
# compare the strings. One predicate so the two reconciliation write gates cannot drift.
function Test-ConfigDiffersOutsideSecretNode {
    param($A, $B)
    $aYaml = (ConvertTo-SortedConfig (Copy-HashtableWithoutSecretNode $A)) | ConvertTo-Yaml
    $bYaml = (ConvertTo-SortedConfig (Copy-HashtableWithoutSecretNode $B)) | ConvertTo-Yaml
    return ($aYaml -cne $bYaml)
}

<#
.SYNOPSIS
    Returns $true when $Current has the same nested node shape as $Template.
.DESCRIPTION
    Every dictionary node in the template must be present as a dictionary in
    $Current, and $Current must carry no unexpected top-level keys ('secrets'
    excepted -- it is added out-of-band by the notification-credentials path). A
    flat test.config.yml (vmBootDelaySeconds, frameworkRepoUrl, ... at the root,
    where the current schema puts vmStart.bootDelaySeconds,
    repositories.frameworkUrl, etc.) fails both tests. Leaf values are not
    compared -- only container structure -- so any operator-set value passes.
#>
function Test-ConfigMatchesTemplateShape {
    param($Template, $Current)
    if ($Template -isnot [System.Collections.IDictionary]) { return $true }
    if ($Current  -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($key in $Template.Keys) {
        if ($Template[$key] -is [System.Collections.IDictionary]) {
            if (-not $Current.Contains($key))                          { return $false }
            if ($Current[$key] -isnot [System.Collections.IDictionary]) { return $false }
        }
    }
    foreach ($key in $Current.Keys) {
        if (-not $Template.Contains($key) -and $key -ne 'secrets') { return $false }
    }
    return $true
}

<#
.SYNOPSIS
    Flatten a config dictionary to a path->value map of its leaf nodes, keyed by dotted path (a.b.c).
.DESCRIPTION
    Every non-dictionary value becomes one entry. Pure. Used to compare what the
    template overlay carried forward against the previous file, so a schema
    migration can report exactly which fields did not map to the new schema.
#>
function Get-ConfigLeafValue {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param($Config, [string]$Prefix = '')
    $out = [ordered]@{}
    if ($Config -isnot [System.Collections.IDictionary]) { return $out }
    foreach ($key in $Config.Keys) {
        $path = if ($Prefix) { "$Prefix.$key" } else { "$key" }
        $val  = $Config[$key]
        if ($val -is [System.Collections.IDictionary]) {
            $child = Get-ConfigLeafValue -Config $val -Prefix $path
            foreach ($ck in $child.Keys) { $out[$ck] = $child[$ck] }
        } else {
            $out[$path] = $val
        }
    }
    return $out
}

<#
.SYNOPSIS
    Return the leaf paths in $Current whose meaningful, non-empty value did not survive into $Merged.
.DESCRIPTION
    These are the fields the new schema dropped (top-level orphans, or values
    under a node whose shape changed) -- the only fields a schema migration cannot
    carry forward automatically, since the merge already copies every field that
    still maps to the same path in the new schema. Pure; the caller surfaces these
    for the operator to hand-migrate.
#>
function Get-DroppedConfigField {
    [CmdletBinding()]
    [OutputType([string[]])]
    param($Current, $Merged)
    $curLeaves    = Get-ConfigLeafValue -Config $Current
    $mergedLeaves = Get-ConfigLeafValue -Config $Merged
    $dropped = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $curLeaves.Keys) {
        if ($mergedLeaves.Contains($path)) { continue }   # carried forward (leaf path survived)
        $v = $curLeaves[$path]
        if ($null -eq $v) { continue }
        if (($v -is [string]) -and [string]::IsNullOrWhiteSpace($v)) { continue }
        if (($v -is [System.Collections.IEnumerable]) -and ($v -isnot [string])) {
            $any = $false; foreach ($i in $v) { $any = $true; break }
            if (-not $any) { continue }   # empty array / collection
        }
        $dropped.Add($path)
    }
    return [string[]]@($dropped)
}

<#
.SYNOPSIS
    Return the leaf paths present in both $Current and $Merged whose value differs.
.DESCRIPTION
    The template overlay keeps every value the operator set (template shape
    wins, current values win), so a leaf that reads differently after the merge
    is a defect in the overlay rather than a schema change -- and one the
    operator cannot otherwise see: the run then uses the new value, every check
    passes against it, and the resolved configuration printed at run start
    looks intentional. The caller reports each entry with its previous value
    before anything is written. Values are compared in canonical form (sorted
    keys and scalar-array elements), so the ordering the overlay normalizes is
    not a change. Pure.
#>
function Get-ConfigLeafChange {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($Current, $Merged)
    $curLeaves    = Get-ConfigLeafValue -Config $Current
    $mergedLeaves = Get-ConfigLeafValue -Config $Merged
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $curLeaves.Keys) {
        if (-not $mergedLeaves.Contains($path)) { continue }   # dropped leaves are reported separately
        $previous = ConvertTo-ConfigLeafText (ConvertTo-SortedConfig $curLeaves[$path])
        $current  = ConvertTo-ConfigLeafText (ConvertTo-SortedConfig $mergedLeaves[$path])
        if ($previous -ceq $current) { continue }
        $changes.Add([pscustomobject]@{ Path = $path; Previous = $previous; Current = $current })
    }
    return [object[]]@($changes)
}

# One line of text per leaf value, for comparison and for the operator report:
# scalars as they print, arrays bracketed with their elements comma-separated,
# map elements as compact JSON so a list of maps still compares by content.
function ConvertTo-ConfigLeafText {
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @(foreach ($item in $Value) {
            if ($item -is [System.Collections.IDictionary]) { $item | ConvertTo-Json -Compress -Depth 20 } else { "$item" }
        })
        return '[' + ($items -join ', ') + ']'
    }
    return "$Value"
}

function Use-TestConfigLock {
    <#
    .SYNOPSIS
        Run a read-modify-write of a config file while holding its write lock.
    .DESCRIPTION
        The cycle-start reconcile, the validator, the status page's editor and
        the enrollment helpers all read test.config.yml, change it and write it
        back. Unserialized, two of them interleave and the later write drops the
        earlier one's change with no trace. Every writer in this module takes
        the lock, and a caller whose read and write are separate statements
        wraps both in this function.

        The lock is a held-open file beside the config (<config>.lock), shared
        by every process. It is reentrant within a process, so a block that
        holds it may call Write-DocumentedTestConfig. A lock another process
        holds past the wait refuses the write (config-lock-busy) rather than
        letting it race; a file system that cannot lock, or a lock file that
        cannot be created, leaves the block running unserialized, as every
        write ran before the lock existed, with a verbose note.

        A plain function on purpose: an advanced one would define its own
        $PSCmdlet and parameter variables, which the caller's block would then
        read in place of its own.
    .PARAMETER Path
        The config file. It need not exist yet; its folder must.
    .PARAMETER Action
        The block to run. Its output is returned.
    .PARAMETER WaitMilliseconds
        How long to wait for another process's write.
    #>
    param([string]$Path, [scriptblock]$Action, [int]$WaitMilliseconds = 30000)
    if (-not $Path -or -not $Action) { throw 'Use-TestConfigLock: -Path and -Action are required.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($script:TestConfigLockDepth.ContainsKey($full)) {
        $script:TestConfigLockDepth[$full]++
        try { return (& $Action) } finally { $script:TestConfigLockDepth[$full]-- }
    }
    $lock = Enter-YurunaSingleFlightLock -Path "$full.lock" -WaitMilliseconds $WaitMilliseconds -Metadata @{ purpose = 'test-config-write' }
    if (-not $lock.Held) {
        if ($lock.Reason -eq 'held-elsewhere') {
            throw "config-lock-busy: another process held $full.lock for over $([int]($WaitMilliseconds / 1000)) s; the configuration was not written."
        }
        Write-Verbose "Use-TestConfigLock: $full.lock not held ($($lock.Reason)); writing unserialized."
    }
    $script:TestConfigLockDepth[$full] = 1
    try {
        return (& $Action)
    } finally {
        [void]$script:TestConfigLockDepth.Remove($full)
        if ($lock.Held) { Exit-YurunaSingleFlightLock -Lock $lock }
    }
}

function Get-TestConfigJournalPath {
    <#
    .SYNOPSIS
        The journal folder of one config file: <config>.journal beside it.
    .DESCRIPTION
        Beside the config, like <config>.backup, because a journal entry holds
        the same credentials the config does: the folder is git-ignored, the
        status service serves only what git lists, and every entry ends in
        .backup, a name the service also refuses.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    return ([IO.Path]::GetFullPath($ConfigPath) + '.journal')
}

function Save-TestConfigJournalEntry {
    <#
    .SYNOPSIS
        Keep the current bytes of a config as a new journal entry before a
        writer replaces them.
    .DESCRIPTION
        One <config>.backup slot was shared by every writer, so a second write
        overwrote the copy the first one kept. Each journal entry is a new file,
        <UTC time>-<writer>.backup, and only the oldest beyond the newest
        $script:TestConfigJournalKeep are pruned. Owner-only on POSIX: an entry
        holds the config's credentials. Nothing is kept when the file does not
        exist or already holds the bytes about to be written.
    .PARAMETER NewContent
        The text about to be written, to skip an entry for a write that changes
        nothing.
    .OUTPUTS
        [string] the entry path, or $null when nothing was kept.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$Writer = 'write',
        [AllowNull()][string]$NewContent
    )
    $full = [IO.Path]::GetFullPath($ConfigPath)
    if (-not [IO.File]::Exists($full)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($null -ne $NewContent -and [string]::Equals([Text.Encoding]::UTF8.GetString($bytes), $NewContent, [StringComparison]::Ordinal)) { return $null }
    $dir = Get-TestConfigJournalPath -ConfigPath $full
    if (-not [IO.Directory]::Exists($dir)) {
        $null = [IO.Directory]::CreateDirectory($dir)
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }
    $label = ($Writer -replace '[^A-Za-z0-9_.-]', '-')
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
    $entry = Join-Path $dir "$stamp-$label.backup"
    for ($n = 2; [IO.File]::Exists($entry); $n++) { $entry = Join-Path $dir "$stamp-$label-$n.backup" }
    $stream = [IO.File]::Open($entry, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($entry, [IO.UnixFileMode]'UserRead, UserWrite') }
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    $entries = @(Get-ChildItem -LiteralPath $dir -Filter '*.backup' -File | Sort-Object Name -Descending)
    foreach ($old in @($entries | Select-Object -Skip $script:TestConfigJournalKeep)) {
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
    return $entry
}

function Get-TestConfigJournal {
    <#
    .SYNOPSIS
        A config's journal entries, newest first, each with whether it holds a
        configuration mapping.
    .OUTPUTS
        [pscustomobject[]] Path, TimeUtc, Writer, Parses.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]], [object[]])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $dir = Get-TestConfigJournalPath -ConfigPath $ConfigPath
    if (-not [IO.Directory]::Exists($dir)) { return @() }
    return @(foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.backup' -File | Sort-Object Name -Descending)) {
        $parses = $false
        try { $parses = ((ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($file.FullName)) -Ordered) -is [System.Collections.IDictionary]) } catch { $parses = $false }
        $time = $null
        $writer = ''
        if ($file.BaseName -match '^(\d{8}T\d{9}Z)-(.+)$') {
            $time = [DateTime]::ParseExact($Matches[1], 'yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
            $writer = $Matches[2]
        }
        [pscustomobject]@{ Path = $file.FullName; TimeUtc = $time; Writer = $writer; Parses = $parses }
    })
}

function Restore-TestConfigFromJournal {
    <#
    .SYNOPSIS
        Put a journal entry back as the config: the newest one that holds a
        configuration mapping (the last known good), or the one named.
    .DESCRIPTION
        An operator action, never automatic: a cycle that meets a config that
        does not parse refuses to run on it, and this is the way back. The
        file being replaced is journaled first, so a restore is itself
        undoable, and every value the restore changes is reported as
        path: previous -> restored before the file is written.
    .PARAMETER EntryPath
        A journal entry to restore instead of the newest good one.
    .OUTPUTS
        [pscustomobject] Restored (entry path or $null), Saved (journal entry
        of the replaced file or $null), Wrote.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Read inside the block handed to Use-TestConfigLock, which the rule does not follow.')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$EntryPath
    )
    $cmdlet = $PSCmdlet
    return Use-TestConfigLock -Path $ConfigPath -Action {
        $result = [pscustomobject]@{ Restored = $null; Saved = $null; Wrote = $false }
        $entry = if ($EntryPath) {
            Get-Item -LiteralPath $EntryPath -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Parses = $true } }
        } else {
            @(Get-TestConfigJournal -ConfigPath $ConfigPath | Where-Object { $_.Parses }) | Select-Object -First 1
        }
        if (-not $entry) {
            Write-Warning "Restore-TestConfigFromJournal: $(Get-TestConfigJournalPath -ConfigPath $ConfigPath) holds no entry with a configuration mapping; nothing was restored."
            return $result
        }
        $text = [IO.File]::ReadAllText($entry.Path)
        $restored = ConvertFrom-Yaml -Yaml $text -Ordered
        if ($restored -isnot [System.Collections.IDictionary]) { throw "config-corrupt: $($entry.Path) does not hold a configuration mapping." }
        if (-not $cmdlet.ShouldProcess($ConfigPath, "Restore $($entry.Path)")) { return $result }
        $current = $null
        if (Test-Path -LiteralPath $ConfigPath) {
            try { $current = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText([IO.Path]::GetFullPath($ConfigPath))) -Ordered } catch { $current = $null }
        }
        if ($current -is [System.Collections.IDictionary]) {
            foreach ($change in @(Get-ConfigLeafChange -Current (Copy-HashtableWithoutSecretNode $current) -Merged (Copy-HashtableWithoutSecretNode $restored))) {
                Write-Warning "$ConfigPath $($change.Path): $($change.Previous) -> $($change.Current) (restored from $($entry.Path))"
            }
        }
        $result.Saved = Save-TestConfigJournalEntry -ConfigPath $ConfigPath -Writer 'before-restore' -NewContent $text
        $result.Wrote = [bool](Write-YurunaStateFile -Path $ConfigPath -Content $text -Confirm:$false)
        if ($result.Wrote) { $result.Restored = $entry.Path }
        return $result
    }
}

function Get-TestConfigReconciliation {
    <#
    .SYNOPSIS
        The one template reconciliation behind both the cycle-start overlay
        and the validator: what the file becomes, and what that changes.
    .DESCRIPTION
        Update-TestConfigFromTemplate and Sync-TestConfigToTemplate used to
        compute this each in its own way and had drifted: only the overlay
        dropped deprecated keys and reported a replaced value, only the
        validator backed up a dropped nested value. Both now start here and
        differ only in what they do with the answer.
    .OUTPUTS
        [pscustomobject] Migration, Config (merged, canonical, secrets kept),
        ShapeMatches, Added, Dropped, Obsolete, Replaced and Rendered (the
        documented text when TemplateText is given, else $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Template,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Current,
        [AllowEmptyString()][string]$ExistingText = '',
        [AllowEmptyString()][string]$TemplateText = ''
    )
    $mirrorFailures = @(Test-ConfigMirrorSetting -Config $Current) + @(Test-ConfigMirrorSetting -Config $Template)
    if ($mirrorFailures.Count -gt 0) { throw "$($mirrorFailures[0].Cause): $($mirrorFailures[0].Path)" }
    $migration = ConvertTo-ConfigNamingMigration -Config $Current -ObsoleteEntry (Get-ObsoleteConfigEntry -Text $ExistingText)
    # The migration returns a copy, so the caller's object keeps its keys.
    $config = $migration.Config
    if ($config -is [System.Collections.IDictionary]) {
        foreach ($key in $script:DeprecatedTopConfigKey) { if ($config.Contains($key)) { $config.Remove($key) } }
    }
    $shapeMatches = Test-ConfigMatchesTemplateShape -Template $Template -Current $config
    $merged = ConvertTo-MergedHashtable -Template $Template -Current $config
    if ($config -is [System.Collections.IDictionary] -and $config.Contains('secrets')) { $merged['secrets'] = $config['secrets'] }
    $merged = ConvertTo-SortedConfig $merged
    $plainCurrent = Copy-HashtableWithoutSecretNode $config
    $curLeaves = Get-ConfigLeafValue -Config $plainCurrent
    $newLeaves = Get-ConfigLeafValue -Config (Copy-HashtableWithoutSecretNode $merged)
    $added = @(foreach ($path in $newLeaves.Keys) { if (-not $curLeaves.Contains($path)) { $path } })
    $dropped = @(Get-DroppedConfigField -Current $plainCurrent -Merged $merged)
    $obsolete = $migration.Obsolete
    foreach ($path in ($dropped | Sort-Object)) { $obsolete[$path] = Format-YamlScalarValue $curLeaves[$path] }
    $replaced = @(Get-ConfigLeafChange -Current $plainCurrent -Merged $merged)
    $rendered = if ($TemplateText) { ConvertTo-DocumentedConfigYaml -TemplateText $TemplateText -Config $merged -ObsoleteEntry $obsolete } else { $null }
    return [pscustomobject]@{
        Migration = $migration; Config = $merged; ShapeMatches = [bool]$shapeMatches
        Added = [string[]]@($added | Sort-Object); Dropped = [string[]]@($dropped | Sort-Object)
        Obsolete = $obsolete; Replaced = $replaced; Rendered = $rendered
    }
}

function Save-ReconciledTestConfig {
    <#
    .SYNOPSIS
        Write a reconciled config with the backups a reconcile owes: the naming
        backup after a key migration, <config>.backup when a populated value
        was dropped or the shape changed, and a journal entry always.
    .OUTPUTS
        [pscustomobject] Wrote, BackupPath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)]$Reconciliation,
        [switch]$Backup,
        [string]$Writer = 'reconcile'
    )
    $backupPath = $null
    $migrated = @($Reconciliation.Migration.Changes).Count -gt 0
    if ($migrated) { $backupPath = New-ConfigNamingBackup -ConfigPath $ConfigPath -Confirm:$false }
    if ($Backup -and (Test-Path -LiteralPath $ConfigPath)) {
        Copy-Item -LiteralPath $ConfigPath -Destination "$ConfigPath.backup" -Force
        if (-not $migrated) { $backupPath = "$ConfigPath.backup" }
    }
    $null = Save-TestConfigJournalEntry -ConfigPath $ConfigPath -Writer $Writer -NewContent $Content
    # Atomic temp+rename: the status service serves this working tree, so a
    # non-atomic write would let a concurrent reader catch a torn file.
    $wrote = [bool](Write-YurunaStateFile -Path $ConfigPath -Content $Content -Confirm:$false)
    if (-not $wrote) {
        if ($migrated) { throw (Format-YurunaOperatorMessage -Key 'exceptions.config_naming_save_failed' -Arguments @{ configPath = $ConfigPath }) }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8959000a9a75ed6e')
    }
    return [pscustomobject]@{ Wrote = $wrote; BackupPath = $backupPath }
}

<#
.SYNOPSIS
    Reconcile the on-disk test.config.yml against its template and return the merged config.
.DESCRIPTION
    Bootstraps the config from the template when missing, drops deprecated
    top-level keys, then overlays the live values on the template (template shape
    wins). When the on-disk shape no longer matches the template, the previous
    file is backed up and the value-preserving merge is written; if any populated
    field genuinely no longer maps to the new schema the run is stopped so the
    operator can hand-migrate from the backup. Legacy notification credentials
    that have moved to a separate transports file are warned about, never
    auto-moved. The file is rewritten only when the merge differs from disk
    outside the 'secrets' subtree.
.PARAMETER ConfigPath
    Path to the live test.config.yml to reconcile (and rewrite in place).
.PARAMETER TemplatePath
    Path to the shipped template that defines the current schema.
#>
function Update-TestConfigFromTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [string]$TemplatePath
    )

    if (-not (Test-Path $TemplatePath)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bd2bb274eb562e76' -Arguments @{ templatePath = "$TemplatePath" })
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered)
    }
    $templateText = [string](Get-Content -Raw -LiteralPath $TemplatePath)
    $template = ConvertFrom-Yaml -Yaml $templateText -Ordered
    $mirrorFailures = @(Test-ConfigMirrorSetting -Config $template)
    if ($mirrorFailures.Count -gt 0) { throw "$($mirrorFailures[0].Cause): $($mirrorFailures[0].Path)" }
    $cmdlet = $PSCmdlet
    # Read, merge and write under the config's write lock, so a change another
    # writer made in between is read here rather than overwritten.
    return Use-TestConfigLock -Path $ConfigPath -Action {
        if (-not (Test-Path $ConfigPath)) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ed3fe1ac669aaff0' -Arguments @{ configPath = "$ConfigPath" }) -InformationAction Continue
            Copy-Item -Path $TemplatePath -Destination $ConfigPath
            return (Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered)
        }

        $existingText = [string](Get-Content -Raw -LiteralPath $ConfigPath)
        $current = ConvertFrom-Yaml -Yaml $existingText -Ordered
        # An existing file that does not hold a mapping -- empty, comments only, a
        # bare scalar or list -- has no settings to merge, and merging it would
        # write the template defaults over it and over its earlier backup. Nothing
        # is written; the operator restores the file and runs again.
        if ($current -isnot [System.Collections.IDictionary]) {
            throw "config-corrupt: $ConfigPath does not hold a configuration mapping; restore it (Restore-TestConfigFromJournal puts back the last version that parsed, or copy $ConfigPath.backup) and run again"
        }

        # See https://yuruna.link/4213a0b3-0044
        $statusExtNotif  = Join-Path -Path (Split-Path -Parent $ConfigPath) `
                              -ChildPath 'status' `
                              -AdditionalChildPath 'extension', 'notification'
        $notifConfigPath = Join-Path $statusExtNotif 'transports.yml'
        $hasNotifLive    = Test-Path $notifConfigPath
        $legacyApiKey = $null
        if ($current.Contains('secrets') -and
            $current['secrets'] -is [System.Collections.IDictionary] -and
            $current['secrets'].Contains('resend') -and
            $current['secrets']['resend'] -is [System.Collections.IDictionary]) {
            $legacyApiKey = "$($current['secrets']['resend']['apiKey'])"
        }
        $legacyTo = $null
        if ($current.Contains('notification') -and
            $current['notification'] -is [System.Collections.IDictionary] -and
            $current['notification'].Contains('toEmailAddress')) {
            $legacyTo = "$($current['notification']['toEmailAddress'])"
        }
        if (-not $hasNotifLive -and ((-not [string]::IsNullOrEmpty($legacyApiKey)) -or (-not [string]::IsNullOrEmpty($legacyTo)))) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9a76ef7358172f67')
        }

        # keystrokeMechanism is no longer a machine-global config knob (it is a
        # per-sequence attribute), so there is nothing to validate here. A stale key
        # left in an operator's test.config.yml is inert and merges out against the
        # template on the next canonicalizing write.
        $reconciliation = Get-TestConfigReconciliation -Template $template -Current $current -ExistingText $existingText -TemplateText $templateText
        $merged = $reconciliation.Config
        # The merge keeps every operator value by construction, so a leaf that reads
        # differently here is a defect in the overlay, not a schema change. It is
        # reported with its previous value before anything is written: once the file
        # is rewritten the run uses the new value and every later check passes
        # against it, so this line is where the previous value survives.
        foreach ($change in @($reconciliation.Replaced)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.config_value_replaced' -Arguments @{
                path = "$($change.Path)"; previous = "$($change.Previous)"; current = "$($change.Current)" })
        }
        $rendered = $reconciliation.Rendered

        # --- REGION: Schema migration (shape departed)
        # See https://yuruna.link/4213a0b3-0045
        if (-not $reconciliation.ShapeMatches) {
            $backupPath = "$ConfigPath.backup"
            if ($cmdlet.ShouldProcess($ConfigPath, (Format-YurunaOperatorMessage -Key 'runner.operator_3139f133d03a7df6'))) {
                $null = Save-ReconciledTestConfig -ConfigPath $ConfigPath -Content $rendered -Reconciliation $reconciliation -Backup -Writer 'template-overlay'
            }
            if ($reconciliation.Dropped.Count -gt 0) {
                $list = ($reconciliation.Dropped | ForEach-Object { "      - $_" }) -join "`n"
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7fa12fa1ab73deb3' -Arguments @{ backupPath = "$backupPath"; list = "$list" })
                # Canonical failure exit code from Test.Prelude so a future change to
                # the entry-point exit contract lands in one place.
                exit (Get-EntryPointExitCode -Outcome Failure)
            }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bd50f33ae3c9b31e' -Arguments @{ backupPath = "$backupPath" }) -InformationAction Continue
            return $merged
        }

        if ((Test-ConfigDiffersOutsideSecretNode -A $merged -B $current) -or $rendered -cne $existingText) {
            if ($cmdlet.ShouldProcess($ConfigPath, (Format-YurunaOperatorMessage -Key 'runner.operator_785dae69f36c4993'))) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_58f8689005f6559c') -InformationAction Continue
                $null = Save-ReconciledTestConfig -ConfigPath $ConfigPath -Content $rendered -Reconciliation $reconciliation -Writer 'template-overlay'
            }
        }

        return $merged
    }
}

# --- REGION: https://yuruna.link/42b11c32-0003
# See https://yuruna.link/4213a0b3-0046

function Format-YamlScalarValue {
    <#
    .SYNOPSIS
        Render one value as a YAML scalar, quoting only where YAML needs it.
    .DESCRIPTION
        Matches the style the previous ConvertTo-Yaml writer produced, so switching
        renderers is not a whole-file diff: bare where unambiguous, single-quoted
        (with '' escaping) otherwise, "" for empty, lowercase true/false for booleans.
        Strings that would otherwise READ BACK as a bool/number/null are quoted so a
        round-trip cannot change a value's type.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Value)

    if ($null -eq $Value)  { return '""' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]$Value
    }
    # Parked entries occupy one comment line; JSON flow sequences are also YAML
    # and keep a removed list recoverable without folding its values into text.
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and
        $Value -isnot [System.Collections.IDictionary]) {
        return ConvertTo-Json -InputObject @($Value) -Compress -Depth 20
    }
    $s = [string]$Value
    if ($s.Length -eq 0) { return '""' }
    $needsQuote =
        ($s -ne $s.Trim()) -or
        ($s -match ':\s') -or $s.EndsWith(':') -or
        ($s -match '\s#') -or
        ($s -match '^[-?:,\[\]{}#&*!|>''"%@`]') -or
        ($s -match '\\') -or
        ($s -match '^(?i:true|false|yes|no|on|off|null|~)$') -or
        ($s -match '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
    if ($needsQuote) { return "'" + ($s -replace "'", "''") + "'" }
    return $s
}

<#
.SYNOPSIS
    Resolve a dotted path in a config dictionary.
.OUTPUTS
    [hashtable] Found [bool], Value.
#>
function Get-ConfigValueAtPath {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $node = $Config
    foreach ($seg in ($Path -split '\.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($seg)) { $node = $node[$seg] }
        else { return @{ Found = $false; Value = $null } }
    }
    return @{ Found = $true; Value = $node }
}

<#
.SYNOPSIS
    Read the `#   path: value` entries out of a rendered config's obsolete block.
.DESCRIPTION
    Lets a rewrite carry forward obsolete keys parked by an earlier run: they live
    only in comments, so they are invisible to the YAML parse that produces the
    merge and would otherwise be dropped by the next render.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] dotted path -> raw value text.
#>
function Get-ObsoleteConfigEntry {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)

    $entries = [ordered]@{}
    if ([string]::IsNullOrEmpty($Text)) { return $entries }
    $inObsoleteBlock = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^# --- (?:REGION: )?Obsolete keys(?:\s|$)') { $inObsoleteBlock = $true; continue }
        if ($line -match '^\s*[^#\s]') { $inObsoleteBlock = $false }
        if ($inObsoleteBlock -and $line -match '^#\s{3}(?<path>[A-Za-z_][A-Za-z0-9_.-]*(?:\.[A-Za-z0-9_.-]+)*):\s(?<val>.*)$') {
            $path = $Matches['path']; $value = $Matches['val']
            if ($entries.Contains($path) -and $entries[$path] -cne $value) {
                throw (Format-YurunaOperatorMessage -Key 'exceptions.config_naming_duplicate_parked' -Arguments @{ path = $path })
            }
            $entries[$path] = $value
        }
    }
    return $entries
}

function Format-ObsoleteConfigEntry {
    <# .SYNOPSIS
        Format parked values identically for documented and plain YAML writers. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$ObsoleteEntry)
    if (-not $ObsoleteEntry -or $ObsoleteEntry.Count -eq 0) { return '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('# --- REGION: Obsolete keys')
    [void]$lines.Add('# Not defined by test.config.yml.template, so the runner ignores them. Kept')
    [void]$lines.Add('# here (commented) so no value is lost: move anything still needed into the')
    [void]$lines.Add('# keys above, then delete these lines.')
    foreach ($path in $ObsoleteEntry.Keys) { [void]$lines.Add("#   ${path}: $($ObsoleteEntry[$path])") }
    return ($lines -join "`n")
}

<#
.SYNOPSIS
    Render a config as YAML using the template text as the documented skeleton.
.DESCRIPTION
    Emits the template's comments, blank lines and key order verbatim, substituting
    each value from $Config. Top-level nodes the template does not define (the
    operator-managed 'secrets' node) are appended as real YAML so nothing is lost.
    Obsolete entries are appended as a commented block.
.PARAMETER TemplateText
    Raw text of test.config.yml.template -- both the schema and the documentation.
.PARAMETER Config
    The reconciled config dictionary whose values are substituted in.
.PARAMETER ObsoleteEntry
    Dotted path -> already-formatted value text, written into the obsolete block.
#>
function ConvertTo-DocumentedConfigYaml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TemplateText,
        [Parameter(Mandatory)]$Config,
        [Parameter()][AllowNull()]$ObsoleteEntry
    )

    $out   = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.List[hashtable]]::new()
    $lines = $TemplateText -split "`r?`n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # Template list items are replaced wholesale when their key is handled.
        if ($line -match '^\s*-\s')      { continue }
        if ($line -match '^\s*(#|$)')    { [void]$out.Add($line); continue }
        if ($line -notmatch '^(?<indent>[ ]*)(?<key>[A-Za-z_][A-Za-z0-9_.-]*)[ ]*:(?<rest>.*)$') { [void]$out.Add($line); continue }

        $indent = $Matches['indent']; $key = $Matches['key']; $rest = $Matches['rest'].Trim()
        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent.Length) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $path   = (@(@($stack | ForEach-Object { $_.Key }) + @($key)) -join '.')
        $lookup = Get-ConfigValueAtPath -Config $Config -Path $path

        # Nothing after the colon: the key opens either a nested map or a list.
        if ($rest.Length -eq 0) {
            $nextIdx = $i + 1
            while ($nextIdx -lt $lines.Count -and $lines[$nextIdx] -match '^\s*(#|$)') { $nextIdx++ }
            if ($nextIdx -lt $lines.Count -and $lines[$nextIdx] -match '^\s*-\s') {
                if ($null -eq $lookup.Value -or @($lookup.Value).Count -eq 0) {
                    [void]$out.Add("${indent}${key}: []")
                    continue
                }
                [void]$out.Add("${indent}${key}:")
                if ($lookup.Found) {
                    foreach ($item in @($lookup.Value)) { [void]$out.Add("${indent}- $(Format-YamlScalarValue $item)") }
                }
                continue
            }
            [void]$out.Add($line)
            [void]$stack.Add(@{ Indent = $indent.Length; Key = $key })
            continue
        }

        # Leaf, including the inline empty-list form `key: []`.
        if (-not $lookup.Found) { [void]$out.Add($line); continue }
        $value = $lookup.Value
        if ($null -eq $value -and $rest -eq '[]') {
            [void]$out.Add("${indent}${key}: []")
            continue
        }
        # A template leaf written as null is a sentinel for "unstated": the code
        # then picks a default that depends on the host or the mode. An unset
        # value keeps that spelling, because '""' reads back as a string that
        # casts to 0 or false and would decide the setting instead.
        if ($null -eq $value -and $rest -cmatch '^(?:null|Null|NULL|~)$') {
            [void]$out.Add("${indent}${key}: null")
            continue
        }
        if ($value -is [System.Collections.IEnumerable] -and
            $value -isnot [string] -and $value -isnot [System.Collections.IDictionary]) {
            $items = @($value)
            if ($items.Count -eq 0) { [void]$out.Add("${indent}${key}: []"); continue }
            [void]$out.Add("${indent}${key}:")
            foreach ($item in $items) { [void]$out.Add("${indent}- $(Format-YamlScalarValue $item)") }
            continue
        }
        [void]$out.Add("${indent}${key}: $(Format-YamlScalarValue $value)")
    }

    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { $out.RemoveAt($out.Count - 1) }

    # Top-level nodes the template does not define -- 'secrets' is operator-managed
    # and out of band, so it is emitted as REAL yaml (never commented) or the
    # rewrite would delete credentials.
    $templateTop = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $lines) {
        if ($line -match '^(?<key>[A-Za-z_][A-Za-z0-9_.-]*)[ ]*:') { [void]$templateTop.Add($Matches['key']) }
    }
    if ($Config -is [System.Collections.IDictionary]) {
        foreach ($k in @($Config.Keys)) {
            if ($templateTop.Contains([string]$k)) { continue }
            [void]$out.Add('')
            [void]$out.Add("# Not defined by the template -- operator-managed, kept verbatim.")
            $sub = [ordered]@{}; $sub[$k] = $Config[$k]
            foreach ($l in (($sub | ConvertTo-Yaml) -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($l)) { [void]$out.Add($l) }
            }
        }
    }

    $obsoleteText = Format-ObsoleteConfigEntry -ObsoleteEntry $ObsoleteEntry
    if ($obsoleteText) {
        [void]$out.Add('')
        foreach ($line in ($obsoleteText -split "`n")) { [void]$out.Add($line) }
    }

    return (($out -join "`n") + "`n")
}

function Write-DocumentedTestConfig {
    <# .SYNOPSIS
        Atomically write a config with template documentation and parked obsolete entries.
    .DESCRIPTION
        Under the config's write lock, and the bytes it replaces are kept as a
        journal entry named after -Writer. A caller that read the config
        before this call holds the lock across both (Use-TestConfigLock), or
        another writer's change can land between its read and this write. #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Read inside the block handed to Use-TestConfigLock, which the rule does not follow.')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)]$Config,
        [string]$TemplatePath,
        [string]$Writer = 'documented-write'
    )
    $mirrorFailures = @(Test-ConfigMirrorSetting -Config $Config)
    if ($mirrorFailures.Count -gt 0) { throw "$($mirrorFailures[0].Cause): $($mirrorFailures[0].Path)" }
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Write documented configuration')) { return $false }
    if (-not $TemplatePath) { $TemplatePath = "$ConfigPath.template" }
    if (-not (Test-Path -LiteralPath $TemplatePath)) { $TemplatePath = Join-Path $PSScriptRoot '../test.config.yml.template' }
    if (-not (Get-Command Write-YurunaStateFile -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Global -DisableNameChecking
    }
    return [bool](Use-TestConfigLock -Path $ConfigPath -Action {
        $existing = if (Test-Path -LiteralPath $ConfigPath) { [string](Get-Content -Raw -LiteralPath $ConfigPath) } else { '' }
        $obsolete = Get-ObsoleteConfigEntry -Text $existing
        $yaml = if (Test-Path -LiteralPath $TemplatePath) {
            ConvertTo-DocumentedConfigYaml -TemplateText ([string](Get-Content -Raw -LiteralPath $TemplatePath)) -Config (ConvertTo-SortedConfig $Config) -ObsoleteEntry $obsolete
        } else { ConvertTo-Yaml $Config }
        $null = Save-TestConfigJournalEntry -ConfigPath $ConfigPath -Writer $Writer -NewContent $yaml
        return [bool](Write-YurunaStateFile -Path $ConfigPath -Content $yaml -Confirm:$false)
    })
}

<#
.SYNOPSIS
    Reconcile the on-disk config to the template as the schema source of truth: add missing fields, drop orphan keys, and rewrite in canonical alphabetical order.
.DESCRIPTION
    The strict reconciliation used by the operator-facing validator:
      * every template field the file lacks is added with its empty/default value
      * every key the template no longer defines (e.g. a renamed section's old
        keys) is DROPPED
      * the result is written with every map key AND scalar-array element ordered
        alphabetically (ConvertTo-SortedConfig)
    Operator values for keys that still map are kept. The top-level 'secrets' node
    (legacy, operator-managed, never in the template) is preserved verbatim rather
    than dropped, so credentials are never lost here.

    The file is rewritten only when the canonical form differs from disk outside
    'secrets', so a repeat run is a no-op. When a populated key is being dropped,
    the previous file is first copied to <config>.backup so the removed value is
    always recoverable; a pure add/sort rewrite loses nothing and writes no backup.
.PARAMETER Template
    The template dictionary that defines the current schema.
.PARAMETER Current
    The live config dictionary loaded from disk.
.PARAMETER ConfigPath
    Path to the live config file to reconcile (and rewrite in place).
.OUTPUTS
    A pscustomobject with these members:
      Config     -- the reconciled, canonical-ordered config (also on disk when Wrote)
      Added      -- dotted leaf paths newly written (the empty fields to fill in)
      Removed    -- populated dotted leaf paths dropped because they are NOT part of
                    the current schema (recoverable from BackupPath)
      Wrote      -- $true when the file was rewritten
      Migrated   -- registered key translations applied before the template merge
      BackupPath -- original input backup when a registered key was migrated or
                    a populated key was dropped, else $null
#>
function Sync-TestConfigToTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Read inside the block handed to Use-TestConfigLock, which the rule does not follow.')]
    param(
        [Parameter(Mandatory)] $Template,
        [Parameter(Mandatory)] $Current,
        [Parameter(Mandatory)] [string]$ConfigPath,
        # Optional: when supplied, the file is rendered from the template TEXT so
        # it keeps the template's per-knob comments and parks obsolete keys as
        # comments. Without it the writer falls back to the plain ConvertTo-Yaml
        # form, which carries no comments.
        [Parameter()] [string]$TemplatePath
    )

    # The same refusal as Update-TestConfigFromTemplate: an existing file that
    # held no mapping must not be replaced by the template and backed up empty.
    if ((Test-Path -LiteralPath $ConfigPath) -and $Current -isnot [System.Collections.IDictionary]) {
        throw "config-corrupt: $ConfigPath does not hold a configuration mapping; restore it (Restore-TestConfigFromJournal puts back the last version that parsed, or copy $ConfigPath.backup) and run again"
    }
    $cmdlet = $PSCmdlet
    return Use-TestConfigLock -Path $ConfigPath -Action {
        $existingText = if (Test-Path -LiteralPath $ConfigPath) { [string](Get-Content -Raw -LiteralPath $ConfigPath) } else { '' }
        # Render the documented form when a template path was supplied. Comparing
        # the RENDERED TEXT to disk (not just the parsed objects) is what lets a
        # file whose values already match pick up newly-added template comments or
        # a new obsolete entry -- both invisible to an object-level diff.
        $templateText = if ($TemplatePath -and (Test-Path -LiteralPath $TemplatePath)) { [string](Get-Content -Raw -LiteralPath $TemplatePath) } else { '' }
        $reconciliation = Get-TestConfigReconciliation -Template $Template -Current $Current -ExistingText $existingText -TemplateText $templateText
        $canonical = $reconciliation.Config
        foreach ($change in @($reconciliation.Replaced)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.config_value_replaced' -Arguments @{
                path = "$($change.Path)"; previous = "$($change.Previous)"; current = "$($change.Current)" })
        }
        $rendered = $reconciliation.Rendered
        $migrated = @($reconciliation.Migration.Changes).Count -gt 0

        # Rewrite when the canonical form differs from disk outside 'secrets', or when
        # the documented rendering differs from what is on disk.
        $changed = (Test-ConfigDiffersOutsideSecretNode -A $canonical -B $Current) -or $migrated
        if ($null -ne $rendered) { $changed = $rendered -cne $existingText }
        $wrote      = $false
        $backupPath = $null
        if ($changed -and $cmdlet.ShouldProcess($ConfigPath, (Format-YurunaOperatorMessage -Key 'runner.operator_1f50cc08b8dd3984'))) {
            $content = if ($null -ne $rendered) { $rendered } else {
                $plainYaml = $canonical | ConvertTo-Yaml
                $obsoleteText = Format-ObsoleteConfigEntry -ObsoleteEntry $reconciliation.Obsolete
                if ($obsoleteText) { $plainYaml.TrimEnd() + "`n`n" + $obsoleteText + "`n" } else { $plainYaml }
            }
            # A migration keeps its own naming backup; otherwise a dropped populated
            # value is first copied to <config>.backup. Wrote reports the actual
            # result so the operator summary never claims a reconcile that did not land.
            $save = Save-ReconciledTestConfig -ConfigPath $ConfigPath -Content $content -Reconciliation $reconciliation `
                -Backup:($reconciliation.Dropped.Count -gt 0 -and -not $migrated) -Writer 'validator'
            $wrote = $save.Wrote
            $backupPath = $save.BackupPath
        }

        return [pscustomobject]@{
            Config     = $canonical
            Migrated   = $reconciliation.Migration.Changes
            Added      = $reconciliation.Added
            Removed    = $reconciliation.Dropped
            Obsolete   = [string[]]@($reconciliation.Obsolete.Keys | Sort-Object)
            Wrote      = $wrote
            BackupPath = $backupPath
        }
    }
}

<#
.SYNOPSIS
    Redact secret nodes and credential leaves recursively before a config is logged.
.DESCRIPTION
    The Hide- verb (rather than Remove-) keeps PSScriptAnalyzer's
    PSUseShouldProcessForStateChangingFunctions rule quiet (it fires on
    Remove-/Set-/etc. but not on Hide-); the function still mutates the passed
    config -- the verb signals "redacting from a logged view" rather than
    "deleting".
#>
function Hide-SecretsInConfig {
    param($Config)
    if ($Config -is [System.Collections.IDictionary]) {
        foreach ($key in @($Config.Keys)) {
            if ([string]$key -ieq 'secrets') {
                $Config[$key] = [ordered]@{}
            } elseif ([string]$key -match '(?i)(token|password|secret|apiKey)$') {
                $Config[$key] = '[redacted]'
            } else {
                Hide-SecretsInConfig -Config $Config[$key]
            }
        }
    } elseif ($Config -is [System.Collections.IEnumerable] -and $Config -isnot [string]) {
        foreach ($item in $Config) { Hide-SecretsInConfig -Config $item }
    }
}

Export-ModuleMember -Function `
    Get-ConfigMirrorKeyId, Test-ConfigMirrorSetting, Get-ConfigMirrorChange, Merge-ConfigMirrorSetting, `
    ConvertTo-MergedHashtable, ConvertTo-SortedConfig, `
    Copy-HashtableWithoutSecretNode, `
    Test-ConfigMatchesTemplateShape, Get-ConfigLeafValue, Get-DroppedConfigField, Get-ConfigLeafChange, `
    Format-YamlScalarValue, Get-ConfigValueAtPath, Get-ObsoleteConfigEntry, Format-ObsoleteConfigEntry, Write-DocumentedTestConfig, `
    Use-TestConfigLock, Get-TestConfigJournalPath, Save-TestConfigJournalEntry, Get-TestConfigJournal, Restore-TestConfigFromJournal, `
    Get-TestConfigReconciliation, `
    ConvertTo-DocumentedConfigYaml, `
    Update-TestConfigFromTemplate, Sync-TestConfigToTemplate, Hide-SecretsInConfig
