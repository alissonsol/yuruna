<#PSScriptInfo
.VERSION 2026.09.12
.GUID 424533be-1c51-4584-9728-27ea5064d2b7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cleanup ocr pester
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
    Structural (AST) guards on two maintenance entry-point scripts:
    Remove-TestVMFiles.ps1 and Test-WinRtOcr.ps1.
.DESCRIPTION
    These scripts run top-to-bottom with `exit` and heavy I/O (host contract
    imports, virsh/utmctl, process control), so they are not invoked in-process
    here; the tests parse each file and assert the required SHAPE via AST nodes
    (loop conditions, method invocations, string literals, variable references)
    rather than raw source text, so a code comment cannot satisfy a guard.

    Pinned invariants:
      * The UTM stop-wait loops on a [DateTime]::UtcNow deadline with no
        iteration accumulator (no += / ++ in the loop body, and no variable
        named $waited), and surfaces an unconfirmed stop before the delete.
        The wait lives in Wait-UtmVMPoweredOff, which the host driver's
        Remove-VM runs before deleting a bundle; the guard is scoped to that
        one function so unrelated loops elsewhere in the driver -- some of
        which legitimately count iterations -- cannot satisfy or trip it.
      * Test-WinRtOcr.ps1 names its temp OCR script with a per-run GUID, so
        concurrent runs cannot collide on a fixed shared name.

    These are structural guards: they verify the required nodes are present and
    correctly shaped, not that the scripts execute correctly end to end.

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

Describe 'service VM operation dry runs' {
    It 'returns before any side effects for every VM start and stop' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $serviceDir = Join-Path $repoRoot 'test/service'
        $scripts = @(Get-ChildItem -LiteralPath $serviceDir -Filter '*-?*ServiceVM.ps1' -File)
        Assert-Equal -Expected 8 -Actual $scripts.Count -Because 'all four VM service pairs must participate'
        foreach ($script in $scripts) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$errors)
            Assert-Equal -Expected 0 -Actual @($errors).Count -Because "$($script.Name) must parse"
            $first = $ast.EndBlock.Statements[0]
            Assert-True ($first -is [System.Management.Automation.Language.IfStatementAst]) `
                "$($script.Name) must gate before imports or any other operation"
            Assert-True ($first.Extent.Text -match '\$PSCmdlet\.ShouldProcess\(') "$($script.Name) must honor WhatIf"
            # Execute only the real parameter block and first guard. A broken
            # guard reaches this throw, never the launcher's external operations.
            $attributes = @($ast.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join "`n"
            $guard = [scriptblock]::Create($attributes + "`n" + $ast.ParamBlock.Extent.Text + "`n" + $first.Extent.Text + "`nthrow 'dry run reached side effects'")
            & $guard -WhatIf
            if ($script.Name -eq 'Start-PoolControlServiceVM.ps1') { & $guard -HostSideProof -WhatIf }
        }
    }
}

Describe 'caching proxy stop state across hosts' {
    It 'withdraws the cached address before <Platform> teardown and preserves the password' -TestCases @(
        @{ Platform = 'Windows' }, @{ Platform = 'MacOS' }, @{ Platform = 'Linux' }
    ) {
        param($Platform)
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $path = Join-Path $repoRoot 'test/service/Stop-CachingProxyServiceVM.ps1'
        # A separate runspace executes the real entry point with host effects
        # stubbed, so its platform branches and preferences stay isolated.
        $driver = {
            param($Path, $Platform)
            Set-Variable IsWindows -Value ($Platform -eq 'Windows') -Force
            Set-Variable IsMacOS -Value ($Platform -eq 'MacOS') -Force
            Set-Variable IsLinux -Value ($Platform -eq 'Linux') -Force
            $fixture = @{
                CacheState = @{ ipAddress = '192.0.2.10'; password = 'retained-password' }
                AddressAtRemoval = $null
                ClearCount = 0
            }
            function Import-Module {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                    Justification = 'Isolated test stub blocks real module loading and filesystem access.')]
                param()
            }
            function Use-LogLevelFromEnv {}
            function Initialize-YurunaEntryPoint { @{ ModulesDir = '/unused/modules' } }
            function Initialize-YurunaEntryPointModuleSet {}
            function Invoke-LibvirtGroupReExecIfNeeded {}
            function Get-HostType { 'test.host' }
            function Initialize-SudoCache { $true }
            function Clear-CachingProxyServiceLock { @{ Reason = 'no-lock' } }
            function Initialize-YurunaHost { $true }
            function Remove-HostProxy {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Isolated host-operation stub has no external effects.')]
                param()
                $true
            }
            function Remove-PortMap {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Isolated host-operation stub has no external effects.')]
                param()
                $true
            }
            function Test-Path {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                    Justification = 'Isolated test stub blocks real module loading and filesystem access.')]
                param()
                $false
            }
            function Get-VMHost { @{ VirtualHardDiskPath = '/unused/disks' } }
            function Get-VMState { 'running' }
            function Stop-VM {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Isolated host-operation stub has no external effects.')]
                param()
                $true
            }
            function Remove-VM {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Records fixture state without touching a VM.')]
                param()
                $fixture.AddressAtRemoval = $fixture.CacheState.ipAddress
                $true
            }
            function Remove-Item {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'A rejecting fixture prevents every attempted deletion.')]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                    Justification = 'The isolated test must never delete real files.')]
                param()
                throw 'The stop fixture must never delete files'
            }
            function Get-UbuntuExtensionImageInfo { @{ BaseImageFile = '/unused/base-image' } }
            function Save-CachingProxyServiceState {
                param([string]$IpAddress)
                $fixture.CacheState.ipAddress = $IpAddress
                $fixture.ClearCount++
                $true
            }
            & $Path -Confirm:$false 1>$null 3>$null 4>$null 5>$null 6>$null
            [pscustomobject]@{
                AddressAtRemoval = $fixture.AddressAtRemoval
                Password = $fixture.CacheState.password
                ClearCount = $fixture.ClearCount
            }
        }
        $shell = [PowerShell]::Create()
        try {
            [void]$shell.AddScript($driver.ToString()).AddArgument($path).AddArgument($Platform)
            $result = @($shell.Invoke())
            Assert-Equal -Expected 0 -Actual $shell.Streams.Error.Count -Because "the isolated $Platform stop script must execute cleanly"
            Assert-Equal -Expected 1 -Actual $result.Count -Because 'the real stop script must return to the fixture'
            Assert-Equal -Expected 1 -Actual $result[0].ClearCount -Because 'each host withdraws the persisted address exactly once'
            Assert-StringEqual -Expected '' -Actual $result[0].AddressAtRemoval -Because 'VM removal must not leave a reusable stale proxy address'
            Assert-StringEqual -Expected 'retained-password' -Actual $result[0].Password -Because 'stopping the VM must preserve the persistent credential'
        } finally {
            $shell.Dispose()
        }
    }
}

BeforeAll {
$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here   # .../test

$script:removeVmFiles = Join-Path $testDir 'Remove-TestVMFiles.ps1'
$script:winRtOcr      = Join-Path $testDir 'check/Test-WinRtOcr.ps1'
$script:utmDriver     = Join-Path (Split-Path -Parent $testDir) 'host/macos.utm/modules/Yuruna.Host.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-ScriptAst {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}

# Names of every .Method(...) / [Type]::Method(...) invocation in the tree (AST
# InvokeMemberExpressionAst). Comments are not AST nodes, so a phrase inside a
# comment cannot satisfy a membership test against this list.
function Get-InvokedMember {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
        ForEach-Object { $_.Member.Extent.Text })
}

# Condition text of every while-loop in the tree.
function Get-WhileConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

# String LITERAL nodes only (excludes comments).
function Get-StringLiteralExtent {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true) | ForEach-Object { $_.Extent.Text })
}

# True when the tree references a variable by name (AST VariableExpressionAst) --
# a name-specific regression pin.
function Test-UsesVariable {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $wanted
    }, $true)).Count -ge 1
}

# True when any while-loop body accumulates an iteration counter (a compound
# assignment += / -= ... or a ++ / -- increment). A wall-clock-bounded wait must
# not also count iterations: a fixed iteration bound in the body could break out
# before the deadline, so the real timeout would drift with per-call cost. This
# catches the defect class regardless of the counter's variable name.
function Test-WhileBodyAccumulator {
    param($Ast)
    foreach ($w in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true))) {
        $compound = @($w.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals
        }, $true))
        if ($compound.Count -ge 1) { return $true }
        $incr = @($w.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            @('PostfixPlusPlus', 'PrefixPlusPlus', 'PostfixMinusMinus', 'PrefixMinusMinus') -contains "$($n.TokenKind)"
        }, $true))
        if ($incr.Count -ge 1) { return $true }
    }
    return $false
}

}

Describe 'The UTM stop-wait is bounded by wall-clock' {
    It 'waits on a UtcNow deadline with no iteration accumulator, and warns when never confirmed stopped' {
        $driverAst = Get-ScriptAst $script:utmDriver
        $wait = @($driverAst.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Wait-UtmVMPoweredOff'
        }, $true))
        Assert-True ($wait.Count -eq 1) 'Wait-UtmVMPoweredOff is defined once in the UTM driver'
        $ast = $wait[0]
        $whileConds = Get-WhileConditionText -Ast $ast
        Assert-True (@($whileConds | Where-Object { $_ -match 'UtcNow' }).Count -ge 1) 'a while loop gates on [DateTime]::UtcNow'
        Assert-True (-not (Test-WhileBodyAccumulator -Ast $ast)) 'no while-loop body accumulates an iteration counter (+= / ++), which would short-circuit the deadline'
        Assert-True (-not (Test-UsesVariable -Ast $ast -Name 'waited')) 'the specific $waited counter is gone'
        $warn = @(Get-StringLiteralExtent -Ast $driverAst | Where-Object { $_ -match 'did not confirm powered-off|did not confirm stopped' })
        Assert-True ($warn.Count -ge 1) 'an unconfirmed-stop warning is emitted before delete'
    }

    It 'routes the prefix sweep through the host contract rather than utmctl' {
        # The sweep must not re-grow its own hypervisor branch: the stop-wait
        # guarantee above is only reached when removal goes through the
        # driver's Remove-VM.
        $ast = Get-ScriptAst $script:removeVmFiles
        $commands = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        Assert-True ($commands -notcontains 'utmctl') 'the sweep calls no utmctl directly'
        Assert-True ($commands -notcontains 'virsh') 'the sweep calls no virsh directly'
        Assert-True ($commands -contains 'Get-VMName') 'the sweep enumerates through the contract'
        Assert-True ($commands -contains 'Remove-VM') 'the sweep removes through the contract'
    }
}

Describe 'Test-WinRtOcr.ps1 uses a unique temp script name' {
    It 'names the temp OCR script with a per-run GUID, not a fixed shared name' {
        $ast = Get-ScriptAst $script:winRtOcr
        Assert-True ((Get-InvokedMember -Ast $ast) -contains 'NewGuid') 'the temp script name includes a NewGuid'
        $fixed = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -eq "'Test-WinRtOcr-run.ps1'" })
        Assert-True ($fixed.Count -eq 0) 'the fixed shared temp name is gone'
    }
}
