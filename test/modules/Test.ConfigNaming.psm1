<#PSScriptInfo
.VERSION 2026.09.01
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

<#
.SYNOPSIS
    The retired test.config.yml key table: old dotted path -> new dotted path,
    plus the factor that converts the old value's unit to the new one.
.DESCRIPTION
    One table, two consumers, so an operator can never meet a rejection that
    has no migration behind it (or a migration the validator still rejects):

      * Test-Config.ps1 rejects a config that still carries any old key and
        names the replacement in the failure line.
      * tools/Update-TestConfigNaming.ps1 rewrites an old config into the new
        form, multiplying values by Factor.

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
# Test-RetiredConfigKeyLine answers "does this FILE still say it the old way",
# which is what a local reconcile needs. A config fetched from another host
# arrives already parsed, and the question there is different: rewrite the
# retired spellings onto the current paths so the consumer -- which only ever
# looks for current names -- sees the values instead of nothing.
#
# Nothing did that rewrite, and "sees nothing" is not inert: the networkStorage
# converter reads a missing poolStorageNetworkPath as "the reference has no pool
# storage" and CLEARS the tier, taking the user names with it and leaving the
# credential sync with an empty user list. A reference host one rename behind
# therefore erased the section it was supposed to supply.

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
    if (-not $PSCmdlet.ShouldProcess(($Segment -join '.'), 'Set config value')) { return $false }
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
        if (-not $PSCmdlet.ShouldProcess("$old -> $($entry.New)", 'Migrate retired config key')) { continue }
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
            $n = 0.0
            if ([double]::TryParse("$value", [ref]$n)) { $value = [int][math]::Round($n * [int]$entry.Factor) }
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

Export-ModuleMember -Function Get-RetiredConfigKeyMap, Test-RetiredConfigKeyLine, Get-RetiredConfigKeyPresent, Update-RetiredConfigKey
