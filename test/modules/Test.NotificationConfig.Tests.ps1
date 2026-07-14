<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42e8f9a0-b1c2-4d34-9e56-7a8b9c0d1e2f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test notification config pester
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
    Behavioral guards on the notification extension's Read-NotificationConfig
    shape normalization (test/extension/notification/default.psm1).
.DESCRIPTION
    Read-NotificationConfig must return one stable shape -- an IDictionary that
    has both transports and subscribers -- regardless of how transports.yml is
    shaped, so a valid-but-oddly-shaped file cannot reach Send-Notification's
    $cfg.Contains('subscribers') and throw. These tests drive the internal
    function (invoked in the module's own scope via `& $module { ... }`) against
    a temp transports.yml holding each degenerate shape:
      * empty file            -> ConvertFrom-Yaml returns $null
      * top-level scalar/list -> a non-dictionary
      * mapping missing a key
      * a well-formed mapping  (data must survive normalization)

    The empty/scalar/missing-key cases assert normalization that a raw
    ConvertFrom-Yaml result (respectively $null, a string, and a mapping without
    the key) does not supply; the well-formed case guards against normalization
    dropping real data.

    The throw-based Assert-* helpers live at script scope and are referenced from
    It blocks, so this runs under Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$testDir    = Split-Path -Parent $here   # .../test
$modulePath = Join-Path $testDir 'extension/notification/default.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# ConvertFrom-Yaml (powershell-yaml) is resolved from the global scope by the
# module, exactly as the production notifier arranges before calling in.
Import-Module powershell-yaml -Force -ErrorAction SilentlyContinue

# Unqualified (not $script:-qualified): an It block runs in a fresh script scope,
# so `$script:NotifModule` read from a test would resolve to that new scope and
# come back $null even though the file assigned it. Only an unqualified name
# walks the scope chain out to the file's variables.
$NotifModule = Import-Module $modulePath -Force -DisableNameChecking -PassThru

# Invoke the internal Read-NotificationConfig in the module's session state with
# $script:ConfigPath pointed at a temp file holding $Content, and report the
# shape of the result. `& $module { }` runs the block in module scope (no reliance
# on a Pester-version-specific InModuleScope signature).
function Get-NotificationConfigShape {
    param([string]$Content)
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $Content)
    try {
        $r = & $NotifModule {
            param($Path)
            $saved = $script:ConfigPath
            $script:ConfigPath = $Path
            try { Read-NotificationConfig } finally { $script:ConfigPath = $saved }
        } $tmp
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $isDict = $r -is [System.Collections.IDictionary]
    [pscustomobject]@{
        IsDict           = $isDict
        HasTransports    = ($isDict -and $r.Contains('transports'))
        HasSubs          = ($isDict -and $r.Contains('subscribers'))
        SubsIsDict       = ($isDict -and $r.Contains('subscribers') -and $r['subscribers'] -is [System.Collections.IDictionary])
        TransportsIsDict = ($isDict -and $r.Contains('transports') -and $r['transports'] -is [System.Collections.IDictionary])
        SubKeys          = if ($isDict -and $r.Contains('subscribers') -and ($r['subscribers'] -is [System.Collections.IDictionary])) { @($r['subscribers'].Keys) } else { @() }
    }
}

Describe 'Read-NotificationConfig normalizes every transports.yml shape' {
    It 'an empty file yields an IDictionary with both keys (never $null)' {
        $s = Get-NotificationConfigShape -Content ''
        Assert-True $s.IsDict 'an empty transports.yml must normalize to a mapping, not $null'
        Assert-True $s.HasTransports 'transports key present'
        Assert-True $s.HasSubs 'subscribers key present'
    }

    It 'a top-level scalar yields a normalized empty mapping (not a bare string)' {
        $s = Get-NotificationConfigShape -Content 'just-a-scalar'
        Assert-True $s.IsDict 'a scalar transports.yml must normalize to a mapping'
        Assert-True $s.HasTransports 'transports key present'
        Assert-True $s.HasSubs 'subscribers key present'
    }

    It 'a mapping missing subscribers gets the key coalesced (transports preserved)' {
        $s = Get-NotificationConfigShape -Content "transports:`n  resend:`n    apiKey: x"
        Assert-True $s.IsDict 'still a mapping'
        Assert-True $s.HasTransports 'the present transports key is preserved'
        Assert-True $s.HasSubs 'missing subscribers is coalesced to an empty dict'
        Assert-True $s.SubsIsDict 'the coalesced subscribers is a dict'
    }

    It 'a subscribers key whose value is not a mapping is coalesced to an empty dict' {
        $s = Get-NotificationConfigShape -Content 'subscribers: not-a-mapping'
        Assert-True $s.IsDict 'still a mapping'
        Assert-True $s.SubsIsDict 'a non-dict subscribers value is replaced with an empty dict, not left as a scalar'
        Assert-True (@($s.SubKeys).Count -eq 0) 'the coalesced subscribers dict is empty'
    }

    It 'a transports key whose value is not a mapping is coalesced to an empty dict' {
        $s = Get-NotificationConfigShape -Content "transports:`n  - a`n  - b"
        Assert-True $s.IsDict 'still a mapping'
        Assert-True $s.TransportsIsDict 'a non-dict (list) transports value is replaced with an empty dict'
    }

    It 'a well-formed config passes through with its subscriber data intact' {
        $s = Get-NotificationConfigShape -Content "subscribers:`n  pool_host_down:`n    - transport: email`n      address: a@b.com"
        Assert-True $s.IsDict 'a mapping'
        Assert-True $s.HasSubs 'subscribers preserved'
        Assert-True (@($s.SubKeys) -contains 'pool_host_down') 'the real subscriber event key survives normalization'
    }
}
