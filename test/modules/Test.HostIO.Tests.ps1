<#PSScriptInfo
.VERSION 2026.07.07
.GUID 422f3b8c-4e95-4a72-9b16-7f8e3c0d5a29
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostio dispatch pester
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
    Behavioral + structural guards on Test.HostIO.psm1's Invoke-HostIOAction
    dispatch.
.DESCRIPTION
    Invoke-HostIOAction runs on the hot send path (every Send-Key / Send-Text /
    Send-Click). It must do a SINGLE registry lookup and branch on the local
    reference, not call Test-HostIOActionAvailable (its own lookup) and then look
    the host map up again. The behavioral tests pin the observable contract that
    must survive that optimisation:
      * a registered (HostType, Action) dispatches to its scriptblock, forwarding
        the arguments hashtable, and returns the block's value;
      * an unregistered Action on a known host throws, listing the available
        actions;
      * an unknown host throws with the '<host not registered>' marker.
    The AST guards pin the optimisation itself (exactly one registry Get; no
    Test-HostIOActionAvailable call) -- both fail against the pre-fix module.

    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split
    hides top-level helpers from It blocks).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.HostIO.psm1'

function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

# A test-only provider on a namespaced host type so a live registry (if this runs
# in-session) is not disturbed. The block echoes an argument so the test can also
# prove the arguments hashtable is forwarded.
Register-HostIOProvider -HostType 'test.hostio.unit' -Action 'Send-Probe' -Implementation {
    param([hashtable]$a)
    return [bool]$a.ok
}

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FunctionName)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    $func = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $func) { throw "Function '$FunctionName' not found in $Path" }
    return $func
}

# Count `<var>.<Member>` accesses inside a function -- e.g. $script:HostIORegistry.Get.
function Get-MemberAccessCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$BaseVar, [Parameter(Mandatory)][string]$Member)
    Write-Verbose "Counting '$BaseVar.$Member' accesses"
    $hits = $FuncAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $n.Member.Value -eq $Member -and
        $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
        ($n.Expression.VariablePath.UserPath -match ("(^|:)" + [regex]::Escape($BaseVar) + "$"))
    }, $true)
    return @($hits).Count
}

function Test-AstCallsCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$CommandName)
    Write-Verbose "Searching for a call to '$CommandName'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName
    }, $true)
    return (@($hits).Count -gt 0)
}

Describe 'Invoke-HostIOAction dispatch contract (behavioral)' {
    # Drop the namespaced test provider on the way out so the suite leaves the
    # ambient $global:YurunaHostIOProviders registry as it found it.
    AfterAll { Clear-HostIOProvider }

    It 'dispatches to the registered scriptblock and forwards the arguments hashtable' {
        Assert-True  (Invoke-HostIOAction -HostType 'test.hostio.unit' -Action 'Send-Probe' -Arguments @{ ok = $true })  'a truthy arg returns the block value'
        Assert-Equal -Expected $false -Actual (Invoke-HostIOAction -HostType 'test.hostio.unit' -Action 'Send-Probe' -Arguments @{ ok = $false }) -Because 'the arguments hashtable reaches the block'
    }
    It 'throws listing the available actions when the action is unregistered on a known host' {
        $threw = $false
        try { Invoke-HostIOAction -HostType 'test.hostio.unit' -Action 'No-Such' }
        catch { $threw = $true; $msg = $_.Exception.Message }
        Assert-True $threw 'an unavailable action must throw'
        Assert-True ($msg -match "not available on 'test\.hostio\.unit'") 'the message names the host'
        Assert-True ($msg -match 'available actions: Send-Probe') 'the message lists the known actions from the single lookup'
    }
    It 'throws with the <host not registered> marker when the host is unknown' {
        $threw = $false
        try { Invoke-HostIOAction -HostType 'test.hostio.absent-xyz' -Action 'Send-Probe' }
        catch { $threw = $true; $msg = $_.Exception.Message }
        Assert-True $threw 'an unknown host must throw'
        Assert-True ($msg -match 'host not registered') 'the null host map yields the not-registered marker'
    }
}

Describe 'Invoke-HostIOAction does a single hot-path registry lookup' {
    $invokeAst = Get-FunctionAst -Path $modulePath -FunctionName 'Invoke-HostIOAction'

    It 'performs exactly one registry Get (no redundant re-lookup on the send path)' {
        Assert-Equal -Expected 1 -Actual (Get-MemberAccessCount -FuncAst $invokeAst -BaseVar 'HostIORegistry' -Member 'Get') -Because `
            'the availability decision and the invoke both derive from one $hostMap reference'
    }
    It 'no longer calls Test-HostIOActionAvailable from the dispatch path' {
        Assert-True (-not (Test-AstCallsCommand -Ast $invokeAst -CommandName 'Test-HostIOActionAvailable')) `
            'the duplicate availability check (its own registry Get) is inlined as a local Contains branch'
    }
}
