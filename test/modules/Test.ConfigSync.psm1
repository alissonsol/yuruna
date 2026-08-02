<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42c04f16-a1b2-4c3d-8e4f-5a6b7c8d9e0f
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
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Global -Force -DisableNameChecking

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
        # serializes as `[]`. See [[pwsh-typed-array-cast-if-empty-null]].
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
    $aYaml = (Copy-HashtableWithoutSecretNode $A) | ConvertTo-Yaml
    $bYaml = (Copy-HashtableWithoutSecretNode $B) | ConvertTo-Yaml
    return ($aYaml -ne $bYaml)
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
        Write-Warning "Template not found: $TemplatePath -- loading config as-is."
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered)
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Information "Config not found: $ConfigPath -- bootstrapping from template." -InformationAction Continue
        Copy-Item -Path $TemplatePath -Destination $ConfigPath
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered)
    }

    $template = Get-Content -Raw $TemplatePath | ConvertFrom-Yaml -Ordered
    $current  = Get-Content -Raw $ConfigPath   | ConvertFrom-Yaml -Ordered

    # Silently drop deprecated top-level keys before the shape check below.
    # Without this, removing a key from the template would make the
    # structure-departure guard fire on every existing test.config.yml that
    # still carries it, backing the file up and resetting the operator's
    # values to template defaults. Targeted drops belong here; whole-layout
    # migrations (e.g. flat -> nested) should still trip the backup path.
    $deprecatedTopKeys = @('hostSshServer')
    if ($current -is [System.Collections.IDictionary]) {
        foreach ($k in $deprecatedTopKeys) {
            if ($current.Contains($k)) { $current.Remove($k) }
        }
    }

    # Whether the on-disk file still matches the template's nested SHAPE. A
    # mismatch (the template gained a node the file lacks, a node was removed or
    # renamed, or a legacy flat layout) is handled AFTER the merge below by the
    # schema-migration block: rather than reset the file to template defaults, the
    # merge carries every field that still maps to the same path in the new schema
    # forward from the previous file, and only fields that genuinely no longer map
    # are surfaced for hand-migration.
    $shapeMatchesTemplate = Test-ConfigMatchesTemplateShape -Template $template -Current $current

    # Notification config (including secrets) lives at
    # test/status/extension/notification/transports.yml. The template
    # ships in-tree at test/extension/notification/transports.yml.template.
    # The legacy keys secrets.resend and notification.toEmailAddress in
    # test.config.yml are no longer schema-valid. The merge
    # (ConvertTo-MergedHashtable) drops template-orphan keys, so any
    # populated legacy values would vanish silently -- warn the operator
    # to move them by hand. Soft migration: do NOT auto-move credentials
    # across files.
    $statusExtNotif  = Join-Path -Path (Split-Path -Parent $ConfigPath) `
                          -ChildPath 'status' `
                          -AdditionalChildPath 'extension', 'notification'
    $notifConfigPath = Join-Path $statusExtNotif 'transports.yml'
    $hasNotifLive    = Test-Path $notifConfigPath
    if ($current -is [System.Collections.IDictionary]) {
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
            Write-Warning "test.config.yml contains legacy notification settings (secrets.resend / notification.toEmailAddress) that have moved to test/status/extension/notification/transports.yml. Copy test/extension/notification/transports.yml.template to test/status/extension/notification/transports.yml and populate transports.resend + subscribers BEFORE the next cycle, otherwise notifications will silently no-op."
        }
    }

    $merged = ConvertTo-MergedHashtable -Template $template -Current $current

    # keystrokeMechanism is no longer a machine-global config knob (it is a
    # per-sequence attribute), so there is nothing to validate here. A stale key
    # left in an operator's test.config.yml is inert and merges out against the
    # template on the next canonicalizing write.

    # Canonicalise ordering before any write/diff: every map key and scalar-array
    # element alphabetically, so a regenerated test.config.yml is byte-stable and
    # diff-friendly regardless of the order keys/elements were authored or merged
    # in (and a file that only differs by ordering converges to canonical on the
    # next run instead of churning forever).
    $merged = ConvertTo-SortedConfig $merged

    # --- REGION: Schema migration (shape departed)
    # The on-disk file no longer matches the template's nested shape (the schema
    # changed). Back the previous file up, then write the value-preserving merge
    # (NOT a bare template reset): every field that still maps to the same path in
    # the new schema has its value carried forward from the previous file, and
    # template-only nodes are filled with their defaults. Fields that genuinely no
    # longer map (top-level orphans, or values under a node whose shape changed)
    # cannot be carried -- if any carried a real value, stop the run so the
    # operator can hand-migrate them from the .backup; otherwise (a purely
    # additive schema change -- a new node the file simply lacked) continue, since
    # nothing was lost and the unattended loop must not halt on a benign bump.
    if (-not $shapeMatchesTemplate) {
        $backupPath = "$ConfigPath.backup"
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        $dropped = @(Get-DroppedConfigField -Current (Copy-HashtableWithoutSecretNode $current) -Merged $merged)
        if ($PSCmdlet.ShouldProcess($ConfigPath, "Migrate to new schema (carry matching values forward)")) {
            # Atomic temp+rename: the status service serves this working tree, so a
            # non-atomic write would let a concurrent reader catch a torn file.
            if (-not (Write-YurunaStateFile -Path $ConfigPath -Content ($merged | ConvertTo-Yaml) -Confirm:$false)) {
                Write-Warning "test.config.yml: atomic rewrite failed; the on-disk config was not updated this cycle."
            }
        }
        if ($dropped.Count -gt 0) {
            $list = ($dropped | ForEach-Object { "      - $_" }) -join "`n"
            Write-Warning @"
test.config.yml: the schema changed and some previous fields no longer map to it.
  - Previous file backed up to: $backupPath
  - Every field that still maps to the new schema was carried forward into the
    new test.config.yml automatically.
  - These previous values did NOT map and were NOT carried -- copy them across by
    hand from the .backup if still needed, then restart:
$list
The run is stopping so you can review. Restarting will then proceed normally.
"@
            # Canonical failure exit code from Test.Prelude so a future change to
            # the entry-point exit contract lands in one place.
            exit (Get-EntryPointExitCode -Outcome Failure)
        }
        Write-Information "test.config.yml: schema changed; carried every previous value forward to the new layout (previous file backed up to $backupPath)." -InformationAction Continue
        return $merged
    }

    if (Test-ConfigDiffersOutsideSecretNode -A $merged -B $current) {
        if ($PSCmdlet.ShouldProcess($ConfigPath, "Rewrite with template overlay")) {
            Write-Information "test.config.yml: applying template overlay to pick up schema changes." -InformationAction Continue
            # Atomic temp+rename: the status service serves this working tree, so a
            # non-atomic write would let a concurrent reader catch a torn file.
            if (-not (Write-YurunaStateFile -Path $ConfigPath -Content ($merged | ConvertTo-Yaml) -Confirm:$false)) {
                Write-Warning "test.config.yml: atomic rewrite failed; the on-disk config was not updated this cycle."
            }
        }
    }

    return $merged
}

# --- REGION: https://yuruna.link/test-config#template-reconciliation
# Rendering the live config from the TEMPLATE TEXT, not from ConvertTo-Yaml.
# YAML was chosen for this file so each knob could carry its explanation, but a
# ConvertFrom-Yaml/ConvertTo-Yaml round-trip drops every comment -- an operator's
# test.config.yml ended up with none of the template's 29 comment lines. The
# template is already the schema source of truth AND canonically ordered, so it
# doubles as the rendering skeleton: walk its lines, keep comments/blank
# lines/order verbatim, and substitute the operator's value wherever the file has
# one. Keys the template no longer defines are written back as commented-out
# `#   path: value` entries instead of vanishing, so a rename leaves its old value
# in view for hand-migration (Test.ConfigNaming's scanner skips comment lines, so a
# key parked there stops failing the retired-key check).

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
function Format-YamlScalarValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Value)

    if ($null -eq $Value)  { return '""' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]$Value
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
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^#\s{3}(?<path>[A-Za-z_][A-Za-z0-9_.-]*(?:\.[A-Za-z0-9_.-]+)*):\s(?<val>.*)$') {
            if (-not $entries.Contains($Matches['path'])) { $entries[$Matches['path']] = $Matches['val'] }
        }
    }
    return $entries
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

    if ($ObsoleteEntry -and $ObsoleteEntry.Count -gt 0) {
        [void]$out.Add('')
        [void]$out.Add('# --- Obsolete keys -------------------------------------------------------')
        [void]$out.Add('# Not defined by test.config.yml.template, so the runner ignores them. Kept')
        [void]$out.Add('# here (commented) so no value is lost: move anything still needed into the')
        [void]$out.Add('# keys above, then delete these lines.')
        foreach ($p in $ObsoleteEntry.Keys) { [void]$out.Add("#   ${p}: $($ObsoleteEntry[$p])") }
    }

    return (($out -join "`n") + "`n")
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
      BackupPath -- <config>.backup when a populated key was dropped, else $null
#>
function Sync-TestConfigToTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Template,
        [Parameter(Mandatory)] $Current,
        [Parameter(Mandatory)] [string]$ConfigPath,
        # Optional: when supplied, the file is rendered from the template TEXT so
        # it keeps the template's per-knob comments and parks obsolete keys as
        # comments. Without it the writer falls back to the plain ConvertTo-Yaml
        # form (no comments), which is what every pre-existing caller got.
        [Parameter()] [string]$TemplatePath
    )

    # Strict merge: template shape wins (orphan keys dropped, missing fields filled,
    # operator values kept), then re-attach the out-of-band 'secrets' node so the
    # validator never strips credentials, then canonicalize key + array ordering.
    $strict = ConvertTo-MergedHashtable -Template $Template -Current $Current
    if (($Current -is [System.Collections.IDictionary]) -and $Current.Contains('secrets')) {
        $strict['secrets'] = $Current['secrets']
    }
    $canonical = ConvertTo-SortedConfig $strict

    # Added / Removed both exclude 'secrets' (operator credentials always diverge
    # from the template blanks). Removed counts only populated leaves with no home
    # in the schema -- the values worth backing up before they are dropped.
    $curLeaves = Get-ConfigLeafValue -Config (Copy-HashtableWithoutSecretNode $Current)
    $newLeaves = Get-ConfigLeafValue -Config (Copy-HashtableWithoutSecretNode $canonical)
    $added     = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $newLeaves.Keys) { if (-not $curLeaves.Contains($p)) { [void]$added.Add($p) } }
    $removed   = @(Get-DroppedConfigField -Current (Copy-HashtableWithoutSecretNode $Current) -Merged $canonical)

    # Obsolete keys are parked in the file as comments rather than only living in
    # the .backup: entries an earlier run parked are carried forward (they are
    # comments, so the YAML parse above cannot see them), then this run's newly
    # dropped leaves are added with their values.
    $existingText = if (Test-Path -LiteralPath $ConfigPath) { [string](Get-Content -Raw -LiteralPath $ConfigPath) } else { '' }
    $obsolete = [ordered]@{}
    foreach ($kv in (Get-ObsoleteConfigEntry -Text $existingText).GetEnumerator()) { $obsolete[$kv.Key] = $kv.Value }
    foreach ($p in ($removed | Sort-Object)) { $obsolete[$p] = Format-YamlScalarValue $curLeaves[$p] }

    # Render the documented form when a template path was supplied. Comparing the
    # RENDERED TEXT to disk (not just the parsed objects) is what lets a file whose
    # values already match pick up newly-added template comments or a new obsolete
    # entry -- both invisible to an object-level diff. Rendering is deterministic,
    # so a second run produces identical text and writes nothing.
    $rendered = $null
    if ($TemplatePath -and (Test-Path -LiteralPath $TemplatePath)) {
        $rendered = ConvertTo-DocumentedConfigYaml `
            -TemplateText ([string](Get-Content -Raw -LiteralPath $TemplatePath)) `
            -Config $canonical -ObsoleteEntry $obsolete
    }

    # Rewrite when the canonical form differs from disk outside 'secrets', or when
    # the documented rendering differs from what is on disk.
    $changed = Test-ConfigDiffersOutsideSecretNode -A $canonical -B $Current
    if ($null -ne $rendered -and $rendered -ne $existingText) { $changed = $true }
    $wrote      = $false
    $backupPath = $null
    if ($changed -and $PSCmdlet.ShouldProcess($ConfigPath, "Reconcile to template (add missing, park obsolete, sort)")) {
        if ($removed.Count -gt 0) {
            $backupPath = "$ConfigPath.backup"
            Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        }
        # Atomic temp+rename: the status service serves this working tree, so a
        # non-atomic write would let a concurrent reader catch a torn file. Report Wrote
        # from the actual result so the operator summary never claims a reconcile that
        # did not land.
        $content = if ($null -ne $rendered) { $rendered } else { $canonical | ConvertTo-Yaml }
        $wrote = [bool](Write-YurunaStateFile -Path $ConfigPath -Content $content -Confirm:$false)
        if (-not $wrote) {
            Write-Warning "test.config.yml: atomic rewrite failed; the on-disk config was not updated this cycle."
        }
    }

    return [pscustomobject]@{
        Config     = $canonical
        Added      = [string[]]@($added   | Sort-Object)
        Removed    = [string[]]@($removed | Sort-Object)
        Obsolete   = [string[]]@($obsolete.Keys | Sort-Object)
        Wrote      = $wrote
        BackupPath = $backupPath
    }
}

<#
.SYNOPSIS
    Strip everything under the top-level 'secrets' node before a config is logged.
.DESCRIPTION
    The Hide- verb (rather than Remove-) keeps PSScriptAnalyzer's
    PSUseShouldProcessForStateChangingFunctions rule quiet (it fires on
    Remove-/Set-/etc. but not on Hide-); the function still mutates the passed
    config -- the verb signals "redacting from a logged view" rather than
    "deleting".
#>
function Hide-SecretsInConfig {
    param($Config)
    if ($Config -is [System.Collections.IDictionary] -and $Config.Contains('secrets')) {
        $node = $Config['secrets']
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in @($node.Keys)) { $node.Remove($key) }
        }
    }
}

Export-ModuleMember -Function `
    ConvertTo-MergedHashtable, ConvertTo-SortedConfig, `
    Copy-HashtableWithoutSecretNode, `
    Test-ConfigMatchesTemplateShape, Get-ConfigLeafValue, Get-DroppedConfigField, `
    Format-YamlScalarValue, Get-ConfigValueAtPath, Get-ObsoleteConfigEntry, `
    ConvertTo-DocumentedConfigYaml, `
    Update-TestConfigFromTemplate, Sync-TestConfigToTemplate, Hide-SecretsInConfig
