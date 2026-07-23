<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42a3b4c5-d6e7-4f89-8a01-2b3c4d5e6f70
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cachingproxy deadline lastexitcode pester
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
    Structural (AST) guards on Start-CachingProxy.ps1's UTM wait loops and its
    child-script ($GetImageScript / $NewVMScript) exit-code gates.
.DESCRIPTION
    Start-CachingProxy.ps1 builds a VM and exits, so it is not invoked in-process
    here; the tests parse it and assert the required SHAPE via AST nodes rather
    than raw source text, so a code comment cannot satisfy a guard.

    Pinned invariants:
      * The UTM register (30 s) and start-transition (15 s) waits loop on a
        [DateTime]::UtcNow deadline rather than an iteration counter (an $i-bounded
        for loop drifts past the stated timeout by the per-call utmctl latency).
        The bounded start-RETRY loop ($attempt -le 3) is a count, not a timer, and
        is intentionally left as a for loop.
      * The exit-code gates after & $GetImageScript / & $NewVMScript reset
        $global:LASTEXITCODE to $null before the call and test
        $null -ne $LASTEXITCODE, so a child .ps1 that ends on a cmdlet (no native
        command) does not false-fail on stale/absent $LASTEXITCODE. The reset must
        be $global:-qualified -- a bare assignment creates a script-scoped shadow
        that freezes every later read (here and in child scopes) at $null while
        the engine writes real exit codes to the global.
      * The New-VM call forwards -MacAddress via HASHTABLE (by-name) splatting.
        Array splatting binds every element positionally -- a literal
        '-MacAddress' string element is never re-parsed as a parameter name, so
        the child rejects it ("A positional parameter cannot be found") and
        never runs. A live-binding test splats the harness's exact hashtable
        shape against each platform New-VM.ps1's REAL param block (extracted by
        AST), so all three hosts' signatures are exercised on any dev machine.
      * Both child invocations capture $? on the immediately-following statement
        and gate on it. $LASTEXITCODE cannot see a child that never RAN
        (parameter-binding or parse failure leaves it $null); without the $?
        gate the run sails on and prints a false "READY" banner.
      * ConvertTo-YurunaMacAddress (Yuruna.Common) normalizes the accepted
        notations to canonical colon form and rejects multicast / all-zero /
        mixed-separator / wrong-length values with $null.

    The throw-based Assert-* helpers live at script scope and are referenced from
    It blocks, so this runs under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here
$startCp = Join-Path $testDir 'Start-CachingProxy.ps1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-Ast {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}

function Get-WhileConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

function Get-ForConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

# Text of every if-statement condition (AST nodes only -- comments excluded).
function Get-IfConditionText {
    param($Ast)
    $texts = @()
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) { $texts += $clause.Item1.Extent.Text }
    }
    $texts
}

# Count of `$global:LASTEXITCODE = $null` resets (AssignmentStatementAst). The
# $global: qualifier is load-bearing: a bare `$LASTEXITCODE = $null` creates a
# script-scoped copy that shadows the engine's global for the rest of the script
# and inside every child scope, so successful natives read back as failures.
function Get-LastExitResetCount {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$global:LASTEXITCODE' -and
        $n.Right.Extent.Text -eq '$null'
    }, $true)).Count
}

# Count of bare (unqualified) `$LASTEXITCODE = ...` assignments -- the scope-shadow
# trap above. Must stay zero.
function Get-LastExitShadowCount {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$LASTEXITCODE'
    }, $true)).Count
}

Describe 'Start-CachingProxy.ps1 bounds the UTM waits by wall-clock' {
    It 'loops the register + start waits on a UtcNow deadline, not an $i iteration counter' {
        $ast = Get-Ast $startCp
        $utcWhiles = @(Get-WhileConditionText -Ast $ast | Where-Object { $_ -match 'UtcNow' })
        Assert-True ($utcWhiles.Count -ge 2) "the register + start waits both gate on [DateTime]::UtcNow; found $($utcWhiles.Count)"
        # Scoped to a timeout literal (-lt 30 / -lt 15) so this catches a reverted
        # iteration-counted TIME wait specifically, without false-failing a
        # legitimate fixed-count for loop (e.g. `for ($i -lt 3)`) or the retained
        # `$attempt -le 3` retry.
        $timeWaitFor = @(Get-ForConditionText -Ast $ast | Where-Object { $_ -match '-lt\s+(30|15)\b' })
        Assert-True ($timeWaitFor.Count -eq 0) "no UTM time wait is left as an iteration-counted for loop (a -lt 30/15 bound); found: $($timeWaitFor -join ' | ')"
    }
}

Describe 'Start-CachingProxy.ps1 gates child scripts on a reset $LASTEXITCODE' {
    It 'resets $global:LASTEXITCODE to $null before the child call and tests it null-safely' {
        $ast = Get-Ast $startCp
        Assert-True ((Get-LastExitResetCount -Ast $ast) -ge 2) 'both & $GetImageScript / & $NewVMScript are preceded by $global:LASTEXITCODE = $null'
        $nullSafe = @(Get-IfConditionText -Ast $ast | Where-Object { $_ -match '\$null -ne \$LASTEXITCODE' })
        Assert-True ($nullSafe.Count -ge 2) "both child-script gates use a null-safe `$null -ne `$LASTEXITCODE test; found $($nullSafe.Count)"
    }
    It 'has no bare $LASTEXITCODE assignment (script-scope shadow of the engine global)' {
        $ast = Get-Ast $startCp
        Assert-True ((Get-LastExitShadowCount -Ast $ast) -eq 0) 'a bare $LASTEXITCODE assignment shadows the engine global; qualify with $global:'
    }
}

$repoRoot = Split-Path -Parent $testDir
$newVmScripts = @(
    (Join-Path $repoRoot 'host/windows.hyper-v/guest.caching-proxy/New-VM.ps1'),
    (Join-Path $repoRoot 'host/ubuntu.kvm/guest.caching-proxy/New-VM.ps1'),
    (Join-Path $repoRoot 'host/macos.utm/guest.caching-proxy/New-VM.ps1')
)

# Named parameters declared by a script's param() block.
function Get-ScriptParameterName {
    param($Ast)
    if (-not $Ast.ParamBlock) { return @() }
    @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

# Every assignment whose right-hand side is exactly `$?`, with the pipeline
# statement that immediately precedes it in the same statement block. The
# pairing matters: any statement between the child call and the capture
# overwrites $?, silently disabling the did-it-even-run gate.
function Get-HookCapture {
    param($Ast)
    $captures = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Right.Extent.Text -eq '$?'
    }, $true))
    foreach ($cap in $captures) {
        $block = $cap.Parent
        while ($block -and $block -isnot [System.Management.Automation.Language.NamedBlockAst] -and
               $block -isnot [System.Management.Automation.Language.StatementBlockAst]) {
            $block = $block.Parent
        }
        $stmts = @($block.Statements)
        $idx = $stmts.IndexOf($cap)
        [pscustomobject]@{
            Name     = $cap.Left.Extent.Text
            Previous = if ($idx -gt 0) { $stmts[$idx - 1].Extent.Text } else { '' }
        }
    }
}

Describe 'Every platform New-VM.ps1 accepts -MacAddress (cross-host param contract)' {
    It 'declares a MacAddress parameter on Hyper-V, KVM, and UTM' {
        foreach ($script in $newVmScripts) {
            $names = Get-ScriptParameterName -Ast (Get-Ast $script)
            Assert-True ($names -contains 'MacAddress') "$script declares -MacAddress; found: $($names -join ', ')"
            Assert-True ($names -contains 'VMName') "$script declares -VMName; found: $($names -join ', ')"
        }
    }
    It 'binds the harness call shape against each platform''s real param block (live splat)' {
        # Extract each script's ACTUAL param block into a stub that echoes what
        # bound, then invoke it exactly the way Start-CachingProxy.ps1 does.
        # This exercises real parameter binding for all three platforms on any
        # dev host -- no hypervisor needed -- and fails if a platform's param
        # block drifts away from the harness's call shape.
        foreach ($script in $newVmScripts) {
            $ast = Get-Ast $script
            Assert-True ($null -ne $ast.ParamBlock) "$script has a param() block"
            $stubPath = Join-Path $TestDrive ((Split-Path -Leaf (Split-Path -Parent $script)) + '.' + (Split-Path -Leaf $script) + '.stub.ps1')
            Set-Content -LiteralPath $stubPath -Value ($ast.ParamBlock.Extent.Text + "`nWrite-Output `"BOUND:`$VMName|`$MacAddress`"")
            # Mirror of the Step 3 call shape in Start-CachingProxy.ps1.
            $newVmParams = @{ VMName = 'stub-vm' }
            $newVmParams.MacAddress = '02:42:42:42:42:42'
            $out = & $stubPath @newVmParams
            $invokeOk = $?
            Assert-True $invokeOk "& stub for $script binds without error"
            Assert-True (@($out) -contains 'BOUND:stub-vm|02:42:42:42:42:42') "stub for $script bound both values; got: $out"
        }
    }
}

Describe 'Start-CachingProxy.ps1 forwards -MacAddress by name and fails fast when a child never runs' {
    It 'splats the New-VM call from a hashtable, with no literal ''-MacAddress'' argument string' {
        $ast = Get-Ast $startCp
        # The broken shape is an array element '-MacAddress': array splatting
        # binds it positionally, never as a parameter name.
        $dashLiterals = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Value -eq '-MacAddress'
        }, $true))
        Assert-True ($dashLiterals.Count -eq 0) "no '-MacAddress' string literal (array-splat shape binds it positionally); found $($dashLiterals.Count)"
        # The New-VM invocation must splat a variable that is assigned a hashtable.
        $newVmCalls = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.CommandElements[0].Extent.Text -eq '$NewVMScript'
        }, $true))
        Assert-True ($newVmCalls.Count -ge 1) 'found the & $NewVMScript invocation'
        $splatted = @($newVmCalls[0].CommandElements | Where-Object { $_.Splatted })
        Assert-True ($splatted.Count -eq 1) 'the & $NewVMScript invocation splats exactly one variable'
        $splatName = $splatted[0].VariablePath.UserPath
        $htAssigned = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq ('$' + $splatName) -and
            $n.Right.Find({ param($m) $m -is [System.Management.Automation.Language.HashtableAst] }, $true)
        }, $true))
        Assert-True ($htAssigned.Count -ge 1) "splatted variable `$$splatName is assigned a hashtable (by-name binding)"
    }
    It 'captures $? on the statement immediately after each child call and gates on it' {
        $ast = Get-Ast $startCp
        $hooks = @(Get-HookCapture -Ast $ast)
        $childHooks = @($hooks | Where-Object { $_.Previous -match '^&\s+\$(GetImageScript|NewVMScript)\b' })
        Assert-True ($childHooks.Count -ge 2) "both & `$GetImageScript / & `$NewVMScript are immediately followed by a `$? capture; found $($childHooks.Count) (any statement in between overwrites `$?)"
        $gated = @(Get-IfConditionText -Ast $ast | Where-Object { $_ -match '-not \$(getImageInvokeOk|newVmInvokeOk)\b' })
        Assert-True ($gated.Count -ge 2) "both invocation-ok flags are tested with -not (child that never RAN leaves `$LASTEXITCODE null); found $($gated.Count)"
    }
}

Describe 'ConvertTo-YurunaMacAddress normalizes and validates (Yuruna.Common)' {
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

    It 'normalizes dash, bare-hex, and colon notations to canonical colon form' {
        Assert-True ((ConvertTo-YurunaMacAddress '02-11-22-33-44-55') -eq '02:11:22:33:44:55') 'dash notation'
        Assert-True ((ConvertTo-YurunaMacAddress 'aabbccddeeff' -WarningAction SilentlyContinue) -eq 'AA:BB:CC:DD:EE:FF') 'bare hex, uppercased'
        Assert-True ((ConvertTo-YurunaMacAddress '02:11:22:33:44:55') -eq '02:11:22:33:44:55') 'colon passthrough'
    }
    It 'rejects multicast, all-zero, mixed-separator, and wrong-length values' {
        foreach ($bad in @('01:00:5E:00:00:01', '000000000000', '02:11-22:33:44:55', '0211223344', 'zz:11:22:33:44:55')) {
            $out = ConvertTo-YurunaMacAddress $bad -WarningAction SilentlyContinue
            Assert-True ($null -eq $out) "'$bad' is rejected with `$null; got '$out'"
        }
    }
    It 'accepts a globally-unique OUI but warns about hardware collision risk' {
        $out = ConvertTo-YurunaMacAddress '08:00:27:AA:BB:CC' -WarningAction SilentlyContinue -WarningVariable macWarn
        Assert-True ($out -eq '08:00:27:AA:BB:CC') 'value still accepted'
        Assert-True (@($macWarn).Count -ge 1) 'a locally-administered-bit warning is emitted'
    }
}
