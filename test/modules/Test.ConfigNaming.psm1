<#PSScriptInfo
.VERSION 2026.10.14
.GUID 424e6b7b-ee0a-4ebd-a491-d47db10eedbc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config naming retired keys
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


<#
.SYNOPSIS
    The retired test.config.yml key table: old dotted path -> new dotted path,
    plus the factor that converts the old value's unit to the new one.
.DESCRIPTION
    One table for validation and migration, so an operator never meets a rejection that
    has no migration behind it (or a migration the validator still rejects):

      * Test-Config.ps1 rejects a config that still carries any old key and
        names the replacement in the failure line.
      * Local template reconciliation and tools/Update-TestConfigNaming.ps1
        translate active and parked keys before merging, multiplying by Factor.
      * Reference-host configuration sync translates retired active keys before
        judging freshness or adopting the reference values.

    Detection is deliberately TEXT-based (Test-RetiredConfigKeyLine). The YAML
    parser hands back case-INSENSITIVE dictionaries, so a parsed lookup cannot
    tell `cachingProxyIP` from `cachingProxyIp` -- the pair that differs only in
    the acronym's casing would then be undetectable and unmigratable.
#>

function Get-RetiredConfigKeyMap {
    <#
    .SYNOPSIS
        Ordered map of retired config keys. Key = old dotted path; value =
        @{ New = <new dotted path>; Factor = <multiply old value by this> }.
        Factor 1 means a pure rename.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $map = [ordered]@{}
    $map['pool.intentGitUrl']                            = @{ New = 'pool.configurationGitUrl';                     Factor = 1 }
    # Durations: two units only -- Ms below a second, Seconds for everything else.
    $map['testCycle.stepTimeoutMinutes']                 = @{ New = 'testCycle.stepTimeoutSeconds';                  Factor = 60 }
    $map['vmImage.refreshHours']                         = @{ New = 'vmImage.refreshSeconds';                        Factor = 3600 }
    $map['vmCommunication.characterDelayMs']             = @{ New = 'vmCommunication.charDelayMs';                   Factor = 1 }
    # Booleans: bare adjective or verb phrase, no is/should prefix, no Enabled suffix.
    $map['configService.isEnabled']                      = @{ New = 'configService.enabled';                         Factor = 1 }
    $map['statusService.isEnabled']                      = @{ New = 'statusService.enabled';                         Factor = 1 }
    $map['testCycle.shouldStopOnFailure']                = @{ New = 'testCycle.stopOnFailure';                       Factor = 1 }
    $map['testCycle.autoRemediationEnabled']             = @{ New = 'testCycle.autoRemediation.enabled';             Factor = 1 }
    $map['testCycle.autoRemediationMaxAttemptsPerCycle'] = @{ New = 'testCycle.autoRemediation.maxAttemptsPerCycle'; Factor = 1 }
    # Acronyms are words in camelCase; SCREAMING_SNAKE is for environment
    # variables, which a YAML key is not.
    $map['vmStart.cachingProxyIP']                       = @{ New = 'vmStart.cachingProxyIp';                        Factor = 1 }
    $map['repositories.GH_TOKEN']                        = @{ New = 'repositories.ghToken';                          Factor = 1 }
    # "pool" unqualified names the host fleet; the NAS the fleet shares is
    # pool STORAGE, which is what the code calls it everywhere else.
    $map['networkStorage.poolLocalPath']                 = @{ New = 'networkStorage.poolStorageLocalPath';           Factor = 1 }
    $map['networkStorage.poolNetworkPath']               = @{ New = 'networkStorage.poolStorageNetworkPath';         Factor = 1 }
    $map['networkStorage.poolNetworkUser']               = @{ New = 'networkStorage.poolStorageNetworkUser';         Factor = 1 }
    $map['networkStorage.stashLocalPath']                = @{ New = 'networkStorage.stashStorageLocalPath';          Factor = 1 }
    $map['networkStorage.stashNetworkPath']              = @{ New = 'networkStorage.stashStorageNetworkPath';        Factor = 1 }
    $map['networkStorage.stashNetworkUser']              = @{ New = 'networkStorage.stashStorageNetworkUser';        Factor = 1 }
    return $map
}

function Test-RetiredConfigKeyLine {
    <#
    .SYNOPSIS
        $true when the raw YAML text carries the retired leaf of $DottedPath at
        the nesting depth that path implies. Case-SENSITIVE, which is what makes
        an acronym-only rename (cachingProxyIP -> cachingProxyIp) detectable.
    .PARAMETER Text
        Raw test.config.yml content.
    .PARAMETER DottedPath
        A key from Get-RetiredConfigKeyMap, e.g. 'testCycle.stepTimeoutMinutes'.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$DottedPath
    )
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    # The full path has to be matched, not just the leaf: `enabled` alone lives
    # under half a dozen blocks, so a leaf-only match would read `pool.enabled`
    # as `statusService.enabled`. Walk the file keeping a stack of the enclosing
    # keys, indent by indent, and compare the composed path.
    $stack = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -notmatch '^(?<indent>\s*)(?<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*:') { continue }
        $depth = [int]([math]::Floor($Matches['indent'].Length / 2))
        while ($stack.Count -gt $depth) { $stack.RemoveAt($stack.Count - 1) }
        if ($stack.Count -lt $depth) { continue }   # inside a block sequence / folded scalar
        $stack.Add($Matches['key'])
        if (($stack -join '.') -ceq $DottedPath) { return $true }
    }
    return $false
}

function Get-RetiredConfigKeyPresent {
    <#
    .SYNOPSIS
        Every retired key the raw config text still carries, as
        @{ Old = <dotted>; New = <dotted>; Factor = <int> } records. Empty array
        when the config is already in the new form.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $found = @()
    $map = Get-RetiredConfigKeyMap
    foreach ($old in $map.Keys) {
        if (Test-RetiredConfigKeyLine -Text $Text -DottedPath $old) {
            $found += @{ Old = [string]$old; New = [string]$map[$old].New; Factor = [int]$map[$old].Factor }
        }
    }
    return @($found)
}


# --- REGION: Structural migration (parsed config, not raw text)
# See https://yuruna.link/4213a0b3-0034

function Get-ConfigNamingOrdinalKey {
    <#
    .SYNOPSIS
    The key of $Container whose name matches $Name CASE-SENSITIVELY, or $null.
    .DESCRIPTION
    Ordinal on purpose. PowerShell dictionaries compare keys case-insensitively,
    so `$c.Contains('cachingProxyIP')` is true for a config that spells it the
    CURRENT way, `cachingProxyIp` -- and a migration built on that would "find" a
    retired key in every clean config, then Remove() the current one on its way
    to rewriting it. The acronym renames are precisely the ones where case is the
    only difference between old and new.
    .OUTPUTS
    [string] the actual key as stored, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Container, [Parameter(Mandatory)][string]$Name)
    if ($Container -isnot [System.Collections.IDictionary]) { return $null }
    foreach ($k in @($Container.Keys)) {
        if ([string]$k -ceq $Name) { return [string]$k }
    }
    return $null
}

function Resolve-ConfigNamingContainer {
    <#
    .SYNOPSIS
    The dictionary holding the leaf of a dotted path, or $null when the path does
    not lead to one.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Segment)
    $cur = $Config
    foreach ($s in $Segment) {
        $k = Get-ConfigNamingOrdinalKey -Container $cur -Name $s
        if (-not $k) { return $null }
        $cur = $cur[$k]
    }
    if ($cur -is [System.Collections.IDictionary]) { return $cur }
    return $null
}

function Set-ConfigNamingValueAtPath {
    <#
    .SYNOPSIS
    Write $Value at a dotted path, creating intermediate maps. $false when a
    scalar already occupies a position the path needs as a map.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Segment,
        [Parameter(Mandatory)][AllowNull()]$Value
    )
    if (-not $PSCmdlet.ShouldProcess(($Segment -join '.'), (Format-YurunaOperatorMessage -Key 'runner.operator_4d9b7a82ece07c12'))) { return $false }
    $cur = $Config
    for ($i = 0; $i -lt $Segment.Count - 1; $i++) {
        $name = $Segment[$i]
        $k = Get-ConfigNamingOrdinalKey -Container $cur -Name $name
        if (-not $k) {
            $cur[$name] = [ordered]@{}
            $k = $name
        } elseif ($cur[$k] -isnot [System.Collections.IDictionary]) {
            return $false
        }
        $cur = $cur[$k]
    }
    $leaf = $Segment[$Segment.Count - 1]
    # Remove a case-variant of the leaf FIRST. Assigning through a
    # case-insensitive dictionary updates the value under the key name already
    # stored, so writing 'cachingProxyIp' onto a config holding 'cachingProxyIP'
    # would leave the retired spelling in place with a new value in it.
    if (-not (Get-ConfigNamingOrdinalKey -Container $cur -Name $leaf) -and $cur.Contains($leaf)) {
        $cur.Remove($leaf)
    }
    $cur[$leaf] = $Value
    return $true
}

function Update-RetiredConfigKey {
    <#
    .SYNOPSIS
    Rewrite every retired key spelling in a PARSED config onto its current path,
    in place, applying each rename's unit Factor. Returns one record per change.
    .DESCRIPTION
    For a config fetched from another host this is the difference between
    adopting its values and silently discarding them: every consumer looks up the
    current names only, so a retired spelling is indistinguishable from an absent
    key -- and for networkStorage, an absent key means "this tier is not
    configured", which clears it.

    A path already spelled the current way is left alone, and a config carrying
    BOTH spellings keeps the current value: the new name is what the host has
    been maintaining, and the retired one is what it stopped reading.
    .PARAMETER Config
    Parsed config (IDictionary). Mutated in place.
    .OUTPUTS
    [pscustomobject[]] @{ Old; New; Factor; Value; Action } where Action is
    'migrated' or 'superseded' (the current spelling was already present).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowNull()]$Config)

    if ($Config -isnot [System.Collections.IDictionary]) { return [object[]]@() }
    $done = [System.Collections.Generic.List[object]]::new()
    $map  = Get-RetiredConfigKeyMap

    foreach ($old in @($map.Keys)) {
        $entry  = $map[$old]
        $oldSeg = [string]$old -split '\.'
        $parentSeg = if ($oldSeg.Count -gt 1) { $oldSeg[0..($oldSeg.Count - 2)] } else { @() }
        $parent = Resolve-ConfigNamingContainer -Config $Config -Segment $parentSeg
        if (-not $parent) { continue }
        $actual = Get-ConfigNamingOrdinalKey -Container $parent -Name $oldSeg[-1]
        if (-not $actual) { continue }

        $value = $parent[$actual]
        if (-not $PSCmdlet.ShouldProcess("$old -> $($entry.New)", (Format-YurunaOperatorMessage -Key 'runner.operator_ee4aeeca3723b96a'))) { continue }
        [void]$parent.Remove($actual)

        $newSeg    = [string]$entry.New -split '\.'
        $newParent = Resolve-ConfigNamingContainer -Config $Config `
            -Segment $(if ($newSeg.Count -gt 1) { $newSeg[0..($newSeg.Count - 2)] } else { @() })
        if ($newParent -and (Get-ConfigNamingOrdinalKey -Container $newParent -Name $newSeg[-1])) {
            [void]$done.Add([pscustomobject]@{
                Old = [string]$old; New = [string]$entry.New; Factor = [int]$entry.Factor
                Value = $newParent[$newSeg[-1]]; Action = 'superseded'
            })
            continue
        }

        if ([int]$entry.Factor -ne 1) {
            # Invariant, explicitly. The value comes out of a config FILE, so
            # it is machine input and its decimal point is a dot wherever the
            # file was written. A bare parse reads it through the host's own
            # culture instead: on a host that writes decimals with a comma,
            # "1.5" parses as 15, and this line then multiplies that by the
            # factor and writes the result back -- a migration that silently
            # scales a setting by ten, in a file the operator will not re-read.
            $n = 0.0
            if ([double]::TryParse("$value", [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
                $value = [int][math]::Round($n * [int]$entry.Factor)
            }
        }
        if (Set-ConfigNamingValueAtPath -Config $Config -Segment $newSeg -Value $value -Confirm:$false) {
            [void]$done.Add([pscustomobject]@{
                Old = [string]$old; New = [string]$entry.New; Factor = [int]$entry.Factor
                Value = $value; Action = 'migrated'
            })
        }
    }
    return [object[]]@($done)
}

# --- REGION: Local configuration migration
function Copy-ConfigNamingTree {
    <# .SYNOPSIS
        Clone a parsed config so a rejected migration cannot mutate its caller. #>
    param([AllowNull()]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[$key] = Copy-ConfigNamingTree -Value $Value[$key] }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $copy = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { [void]$copy.Add((Copy-ConfigNamingTree -Value $item)) }
        return ,$copy
    }
    return $Value
}

function Test-ConfigNamingValuePopulated {
    <# .SYNOPSIS
        Blank strings and null are unset; false and zero are operator values. #>
    [OutputType([bool])]
    param([AllowNull()]$Value)
    return $null -ne $Value -and -not ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))
}

function ConvertTo-ConfigNamingMigration {
    <#
    .SYNOPSIS
        Prepare registered key migrations without changing the input config or file.
    .DESCRIPTION
        Local reconciliation must translate registered keys before its strict
        template merge. Values parked in the generated obsolete block are eligible
        for the same translation. A blank replacement is unset; conflicting
        populated values stop the migration instead of silently choosing one.
        Obsolete entries are removed only from the returned rendering, so the
        caller can back up and atomically replace the original file together.
    .OUTPUTS
        Config, Obsolete, and Changes. No input object is mutated.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Config,
        [Parameter()][AllowNull()]$ObsoleteEntry
    )

    $copy = Copy-ConfigNamingTree -Value $Config
    $obsolete = [ordered]@{}
    if ($ObsoleteEntry) {
        foreach ($key in $ObsoleteEntry.Keys) { $obsolete[$key] = $ObsoleteEntry[$key] }
    }
    $changes = [System.Collections.Generic.List[object]]::new()
    if ($copy -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{ Config = $copy; Obsolete = $obsolete; Changes = [object[]]@() }
    }
    $map = Get-RetiredConfigKeyMap
    foreach ($old in $map.Keys) {
        $entry = $map[$old]
        $oldSegment = [string]$old -split '\.'
        $newSegment = [string]$entry.New -split '\.'
        $oldParent = Resolve-ConfigNamingContainer -Config $copy -Segment $oldSegment[0..($oldSegment.Count - 2)]
        $oldKey = Get-ConfigNamingOrdinalKey -Container $oldParent -Name $oldSegment[-1]
        $parkedKey = Get-ConfigNamingOrdinalKey -Container $obsolete -Name $old
        if (-not $oldKey -and -not $parkedKey) { continue }

        $candidates = [System.Collections.Generic.List[object]]::new()
        if ($oldKey) { [void]$candidates.Add($oldParent[$oldKey]) }
        if ($parkedKey) {
            try {
                $parsed = ConvertFrom-Yaml -Yaml ("value: " + $obsolete[$parkedKey]) -Ordered -ErrorAction Stop
                if ($parsed -isnot [System.Collections.IDictionary] -or $parsed.Count -ne 1 -or
                    $parsed['value'] -is [System.Collections.IDictionary] -or
                    ($parsed['value'] -is [System.Collections.IEnumerable] -and $parsed['value'] -isnot [string])) {
                    throw 'Expected one scalar value.'
                }
                [void]$candidates.Add($parsed['value'])
            } catch {
                throw (Format-YurunaOperatorMessage -Key 'exceptions.config_naming_invalid_parked_scalar' -Arguments @{ old = $old })
            }
        }
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            if ([int]$entry.Factor -eq 1 -or -not (Test-ConfigNamingValuePopulated $candidates[$i])) { continue }
            $number = 0.0
            if (-not [double]::TryParse([string]$candidates[$i], [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                throw (Format-YurunaOperatorMessage -Key 'exceptions.config_naming_invalid_duration' -Arguments @{ old = $old })
            }
            $candidates[$i] = [int][math]::Round($number * [int]$entry.Factor)
        }

        $newParent = Resolve-ConfigNamingContainer -Config $copy -Segment $newSegment[0..($newSegment.Count - 2)]
        $newKey = Get-ConfigNamingOrdinalKey -Container $newParent -Name $newSegment[-1]
        $value = if ($newKey) { $newParent[$newKey] } else { $candidates[0] }
        foreach ($candidate in $candidates) {
            if (-not (Test-ConfigNamingValuePopulated $candidate)) { continue }
            if ((Test-ConfigNamingValuePopulated $value) -and
                (ConvertTo-Json -InputObject $value -Compress -Depth 100) -cne
                (ConvertTo-Json -InputObject $candidate -Compress -Depth 100)) {
                throw (Format-YurunaOperatorMessage -Key 'exceptions.config_naming_conflict' -Arguments @{ old = $old; replacement = $entry.New })
            }
            $value = $candidate
        }
        # Remove before setting for acronym-only renames: dictionaries otherwise
        # retain the old key's spelling when an assignment changes only its case.
        if ($oldKey) { [void]$oldParent.Remove($oldKey) }
        if (-not (Set-ConfigNamingValueAtPath -Config $copy -Segment $newSegment -Value $value -Confirm:$false)) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.config_naming_blocked_path' -Arguments @{ old = $old; replacement = $entry.New })
        }
        if ($parkedKey) { [void]$obsolete.Remove($parkedKey) }
        [void]$changes.Add([pscustomobject]@{
            Old = [string]$old; New = [string]$entry.New; Factor = [int]$entry.Factor
            Value = $value; Action = $(if ($parkedKey) { 'recovered' } else { 'migrated' })
        })
    }
    return [pscustomobject]@{ Config = $copy; Obsolete = $obsolete; Changes = [object[]]@($changes) }
}

function New-ConfigNamingBackup {
    <# .SYNOPSIS
        Preserve the exact migration input without overwriting an earlier backup. #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $backupPath = "$ConfigPath.pre-renaming"
    if (Test-Path -LiteralPath $backupPath) { $backupPath += '.' + [guid]::NewGuid().ToString('N') }
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, (Format-YurunaOperatorMessage -Key 'runner.config_naming_backup' -Arguments @{ backupPath = $backupPath }))) { return $null }
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -ErrorAction Stop
    return $backupPath
}

Export-ModuleMember -Function Get-RetiredConfigKeyMap, Test-RetiredConfigKeyLine, Get-RetiredConfigKeyPresent, Update-RetiredConfigKey, ConvertTo-ConfigNamingMigration, New-ConfigNamingBackup
