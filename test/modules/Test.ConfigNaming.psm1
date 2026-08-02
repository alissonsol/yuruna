<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42e7b90c-3d51-4a8e-9c22-7f6b1d3e5a04
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

Export-ModuleMember -Function Get-RetiredConfigKeyMap, Test-RetiredConfigKeyLine, Get-RetiredConfigKeyPresent
