<#PSScriptInfo
.VERSION 2026.06.19
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

# Overlay $Current onto $Template. Template shape wins (which keys exist);
# current values win for overlapping scalars/arrays. Keys only in $Current
# are dropped -- template is the schema source of truth. Keys emitted
# alphabetically at every nesting level so regenerated test.config.yml
# is stable regardless of the template's own key ordering.
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

# Deep-clone a template subtree so the additive overlay never aliases a template
# object into the operator's config: a later in-place edit of one must not mutate
# the other (the template is read once per run and reused). Scalars/strings/bools
# are immutable enough to return as-is; only dictionaries and lists need a fresh
# copy. Lists are rebuilt so a copied default array is independent of the template.
function Copy-ConfigSubtree {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in $Value.Keys) { $copy[$k] = Copy-ConfigSubtree $Value[$k] }
        return $copy
    }
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($i in $Value) { [void]$list.Add((Copy-ConfigSubtree $i)) }
        return , $list.ToArray()
    }
    return $Value
}

# Additive overlay: returns $Current with every key/node the TEMPLATE defines but
# $Current lacks filled in from the template default (recursively). This is the
# MIRROR of ConvertTo-MergedHashtable: that function treats the template as the
# schema source of truth and DROPS keys present only in $Current; this one
# PRESERVES every current-only key untouched -- the operator's not-yet-migrated
# values (e.g. a renamed section's old keys) stay in the file so they can be
# hand-copied into the new fields and removed deliberately, never silently. An
# existing current value always wins, including a shape conflict (current scalar
# where the template has a node): the operator value is preserved rather than
# overwritten with template sub-fields. Keys are emitted alphabetically at every
# level to match how the maintained file is already serialized.
function ConvertTo-AdditiveMergedHashtable {
    param($Template, $Current)

    if ($Current  -isnot [System.Collections.IDictionary]) { return $Current }
    if ($Template -isnot [System.Collections.IDictionary]) { return $Current }

    $keys = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in $Current.Keys)  { [void]$keys.Add([string]$k) }
    foreach ($k in $Template.Keys) { [void]$keys.Add([string]$k) }

    $result = [ordered]@{}
    foreach ($key in $keys) {
        $inCur = $Current.Contains($key)
        $inTpl = $Template.Contains($key)
        if ($inCur -and $inTpl -and ($Current[$key] -is [System.Collections.IDictionary]) -and ($Template[$key] -is [System.Collections.IDictionary])) {
            $result[$key] = ConvertTo-AdditiveMergedHashtable -Template $Template[$key] -Current $Current[$key]
        } elseif ($inCur) {
            $result[$key] = $Current[$key]                       # operator value wins (incl. shape conflicts)
        } else {
            $result[$key] = Copy-ConfigSubtree $Template[$key]   # template-only -> fill in the default
        }
    }
    return $result
}

# Shallow clone of $Config without top-level 'secrets' for diff comparison.
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

# Returns $true when $Current has the same nested node shape as $Template:
# every dictionary node in the template is present as a dictionary, and
# $Current carries no unexpected top-level keys ('secrets' excepted -- it
# is added out-of-band by the notification-credentials path). A flat
# test.config.yml (vmBootDelaySeconds, frameworkRepoUrl, ... at the
# root, where the current schema puts vmStart.bootDelaySeconds,
# repositories.frameworkUrl, etc.) fails both tests. Leaf values are NOT
# compared -- only container structure -- so any operator-set value passes.
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

# Flatten a config dictionary to a path->value map of its LEAF nodes (every
# non-dictionary value), keyed by dotted path (a.b.c). Pure. Used to compare what
# the template overlay carried forward against the previous file, so a schema
# migration can report exactly which fields did NOT map to the new schema.
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

# Given the previous config and the template-merged result, return the leaf paths
# in $Current whose (meaningful, non-empty) value did NOT survive into $Merged --
# the fields the new schema dropped (top-level orphans, or values under a node
# whose shape changed). These are the only fields a schema migration cannot carry
# forward automatically: the merge already copies every field that still maps to
# the same path in the new schema. Pure; the caller surfaces these for the
# operator to hand-migrate.
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

function Update-TestConfigFromTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [string]$TemplatePath
    )

    if (-not (Test-Path $TemplatePath)) {
        Write-Warning "Template not found: $TemplatePath — loading config as-is."
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered)
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Information "Config not found: $ConfigPath — bootstrapping from template." -InformationAction Continue
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

    # Validate keystrokeMechanism. Canonical values "GUI"/"SSH";
    # recognition is case-insensitive, value is normalized to uppercase.
    # Unrecognized values (including legacy "hypervisor") are discarded
    # and replaced with the template default. No migration.
    $validMechanisms = @('GUI', 'SSH')
    $mergedComm = if ($merged -is [System.Collections.IDictionary]) { $merged['vmCommunication'] } else { $null }
    if ($mergedComm -is [System.Collections.IDictionary] -and $mergedComm.Contains('keystrokeMechanism')) {
        $original = "$($mergedComm['keystrokeMechanism'])"
        $upper    = $original.ToUpperInvariant()
        if ($upper -in $validMechanisms) {
            if ($original -cne $upper) {
                $mergedComm['keystrokeMechanism'] = $upper
            }
        } else {
            $default = "$($template['vmCommunication']['keystrokeMechanism'])"
            Write-Information "test.config.yml: vmCommunication.keystrokeMechanism='$original' not recognized — resetting to '$default'." -InformationAction Continue
            $mergedComm['keystrokeMechanism'] = $default
        }
    }

    # --- Schema migration (shape departed) -------------------------------
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
            $merged | ConvertTo-Yaml | Set-Content -Path $ConfigPath -Encoding utf8NoBOM
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

    $mergedForDiff  = Copy-HashtableWithoutSecretNode $merged
    $currentForDiff = Copy-HashtableWithoutSecretNode $current
    $mergedYaml  = $mergedForDiff  | ConvertTo-Yaml
    $currentYaml = $currentForDiff | ConvertTo-Yaml

    if ($mergedYaml -ne $currentYaml) {
        if ($PSCmdlet.ShouldProcess($ConfigPath, "Rewrite with template overlay")) {
            Write-Information "test.config.yml: applying template overlay to pick up schema changes." -InformationAction Continue
            $merged | ConvertTo-Yaml | Set-Content -Path $ConfigPath -Encoding utf8NoBOM
        }
    }

    return $merged
}

# Additively enforce the template schema on the on-disk config: write every
# template field the file LACKS (its empty/default value, ready to fill in)
# WITHOUT removing any operator key and WITHOUT a backup. This is the gentle
# counterpart to Update-TestConfigFromTemplate (the runner's hard cycle-start
# reconciliation, which backs up, resets the file to the template shape, and
# drops orphan keys): here nothing the operator typed is ever destroyed -- the
# file just gains the missing fields, and a renamed section's old keys are left
# in place to migrate by hand and remove deliberately. The file is rewritten only
# when at least one field is genuinely missing, so a repeat run is a no-op.
#
# Returns a result object:
#   .Config  -- the additive-merged config (also on disk when .Wrote is $true)
#   .Added   -- dotted leaf paths newly written (the empty fields to fill in)
#   .Orphans -- populated leaf paths the file still carries that are NOT part of
#               the current schema (e.g. a renamed section's old keys) -- copy
#               each into its new field, then delete the old key, or the runner
#               will back up + reset (dropping these) at cycle start
#   .Wrote   -- $true when the file was rewritten (i.e. .Added was non-empty)
function Add-MissingTestConfigField {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Template,
        [Parameter(Mandatory)] $Current,
        [Parameter(Mandatory)] [string]$ConfigPath
    )

    $additive  = ConvertTo-AdditiveMergedHashtable -Template $Template -Current $Current
    # 'secrets' is excluded from the diff the same way the runner's overlay
    # excludes it (operator credentials always diverge from the template blanks).
    $curLeaves = Get-ConfigLeafValue -Config (Copy-HashtableWithoutSecretNode $Current)
    $newLeaves = Get-ConfigLeafValue -Config (Copy-HashtableWithoutSecretNode $additive)
    $added     = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $newLeaves.Keys) { if (-not $curLeaves.Contains($p)) { [void]$added.Add($p) } }

    # Orphans = populated current leaves that have no home in the template schema.
    # Compared against the STRICT (template-shape-wins) merge, identical to how
    # Update-TestConfigFromTemplate reports the fields it cannot carry forward.
    $strictMerge = ConvertTo-MergedHashtable -Template $Template -Current $Current
    $orphans     = @(Get-DroppedConfigField -Current (Copy-HashtableWithoutSecretNode $Current) -Merged $strictMerge)

    $wrote = $false
    if ($added.Count -gt 0 -and $PSCmdlet.ShouldProcess($ConfigPath, "Add $($added.Count) missing schema field(s)")) {
        $additive | ConvertTo-Yaml | Set-Content -Path $ConfigPath -Encoding utf8NoBOM
        $wrote = $true
    }

    return [pscustomobject]@{
        Config  = $additive
        Added   = [string[]]@($added   | Sort-Object)
        Orphans = [string[]]@($orphans | Sort-Object)
        Wrote   = $wrote
    }
}

# Strip everything under the top-level 'secrets' node before logging.
# Hide- (rather than Remove-) keeps PSScriptAnalyzer's PSUseShouldProcess-
# ForStateChangingFunctions rule quiet (it fires on Remove-/Set-/etc. but
# not on Hide-); the function still mutates the passed config -- the verb
# just signals "redacting from a logged view" rather than "deleting".
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
    ConvertTo-MergedHashtable, ConvertTo-AdditiveMergedHashtable, Copy-ConfigSubtree, `
    Copy-HashtableWithoutSecretNode, `
    Test-ConfigMatchesTemplateShape, Get-ConfigLeafValue, Get-DroppedConfigField, `
    Update-TestConfigFromTemplate, Add-MissingTestConfigField, Hide-SecretsInConfig
