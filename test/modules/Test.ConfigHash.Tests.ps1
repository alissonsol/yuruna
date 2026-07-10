<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42e4a5b6-7c81-4d92-a3b4-5c6d7e8f9a0b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config hash pester
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
    Structural Pester guard: the SHA-256 -> lowercase-hex conversion is defined
    ONCE, in the leaf Test.Hash module, and every hashing caller delegates to it.
.DESCRIPTION
    ConvertTo-LowerHex lives in test/modules/Test.Hash.psm1 (a stateless leaf so a
    -Force re-import is a no-op). Test.Config (content-hash cache key + snapshot-slot
    filename), Test.Perf (sidecar tag), and Test.OcrEngine (source-hash key) each
    import Test.Hash and delegate the byte[] -> hex encode instead of open-coding the
    BitConverter::ToString -> replace '-' -> ToLowerInvariant idiom. These AST/source
    guards assert: the helper is defined + exported once in Test.Hash with a single
    raw BitConverter::ToString; Test.Config no longer defines it, imports Test.Hash,
    and both its hash sites delegate the right bytes; and Test.Perf / Test.OcrEngine
    import Test.Hash and call the shared converter. AST/source-only -- no module
    import, no filesystem. The throw-based Assert-True helper is script-scoped so this
    runs under Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulesDir = Join-Path $repoRoot 'test/modules'
$hashPath   = Join-Path $modulesDir 'Test.Hash.psm1'
$configPath = Join-Path $modulesDir 'Test.Config.psm1'
$perfPath   = Join-Path $modulesDir 'Test.Perf.psm1'
$ocrPath    = Join-Path $modulesDir 'Test.OcrEngine.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Module not found: $Path" }
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
}

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    return ($RootAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1)
}

# True iff the AST subtree invokes a command named $CommandName.
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

# Count of static [System.BitConverter]::ToString(...) invocations (not the ubiquitous
# instance .ToString()): filter on Static + member name + a BitConverter type expression.
function Get-BitConverterToStringCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Ast)
    $hits = $Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Static -and
        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $n.Member.Value -eq 'ToString' -and
        $n.Expression.Extent.Text -match 'BitConverter'
    }, $true)
    return @($hits).Count
}

Describe 'config-hash -- the SHA-256->hex converter lives once in the Test.Hash leaf' {
    It 'Test.Hash defines ConvertTo-LowerHex with a single raw BitConverter::ToString' {
        $hashAst = Get-ModuleAst -Path $hashPath
        Assert-True ([bool](Get-FunctionAst -RootAst $hashAst -FunctionName 'ConvertTo-LowerHex')) `
            'the byte[] -> lowercase-hex idiom must live in the shared Test.Hash helper'
        Assert-True ((Get-BitConverterToStringCount -Ast $hashAst) -eq 1) `
            'the raw BitConverter::ToString must appear exactly once, inside the helper'
    }
    It 'Test.Hash EXPORTS ConvertTo-LowerHex so cross-module callers resolve it' {
        $hashAst = Get-ModuleAst -Path $hashPath
        $exportText = ($hashAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
        }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
        Assert-True ($exportText -match 'ConvertTo-LowerHex') 'ConvertTo-LowerHex must be exported from Test.Hash'
    }
}

Describe 'config-hash -- Test.Config delegates to the shared converter' {
    $rootAst = Get-ModuleAst -Path $configPath
    It 'Test.Config no longer defines ConvertTo-LowerHex (it moved to Test.Hash)' {
        Assert-True ($null -eq (Get-FunctionAst -RootAst $rootAst -FunctionName 'ConvertTo-LowerHex')) `
            'the converter must not be re-defined in Test.Config'
        Assert-True ((Get-BitConverterToStringCount -Ast $rootAst) -eq 0) `
            'no raw BitConverter::ToString should remain in Test.Config'
    }
    It 'Test.Config imports the Test.Hash leaf' {
        $src = Get-Content -LiteralPath $configPath -Raw
        Assert-True ($src -match 'Import-Module[^\n]*Test\.Hash\.psm1') 'Test.Config must import Test.Hash'
    }
    It 'the content-hash and snapshot-path functions both convert via ConvertTo-LowerHex' {
        $content = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-TestConfigContentHash'
        $snap    = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-TestConfigSnapshotPath'
        Assert-True (Test-AstCallsCommand -Ast $content -CommandName 'ConvertTo-LowerHex') 'Get-TestConfigContentHash must use the shared converter'
        Assert-True (Test-AstCallsCommand -Ast $snap -CommandName 'ConvertTo-LowerHex') 'Get-TestConfigSnapshotPath must use the shared converter'
    }
    It 'each hash site delegates the RIGHT bytes to ConvertTo-LowerHex (guards a wrong-argument delegation)' {
        $content = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-TestConfigContentHash'
        $snap    = Get-FunctionAst -RootAst $rootAst -FunctionName 'Get-TestConfigSnapshotPath'
        $cCall = $content.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertTo-LowerHex' }, $true) | Select-Object -First 1
        $sCall = $snap.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertTo-LowerHex' }, $true) | Select-Object -First 1
        Assert-True ($null -ne $cCall -and $cCall.CommandElements[1].Extent.Text -eq '$hash') 'content-hash must convert the computed $hash'
        Assert-True ($null -ne $sCall -and $sCall.Extent.Text -match 'ComputeHash') 'snapshot-path must convert a freshly-computed hash (ComputeHash), not a stray value'
    }
}

Describe 'config-hash -- Test.Perf and Test.OcrEngine delegate to the shared converter' {
    It 'Test.Perf imports Test.Hash and its sidecar tag converts via ConvertTo-LowerHex' {
        $src = Get-Content -LiteralPath $perfPath -Raw
        Assert-True ($src -match 'Import-Module[^\n]*Test\.Hash\.psm1') 'Test.Perf must import Test.Hash'
        $perfAst = Get-ModuleAst -Path $perfPath
        Assert-True (Test-AstCallsCommand -Ast $perfAst -CommandName 'ConvertTo-LowerHex') 'Test.Perf must use the shared converter'
        Assert-True ((Get-BitConverterToStringCount -Ast $perfAst) -eq 0) 'Test.Perf should not open-code the encode'
    }
    It 'Test.OcrEngine imports Test.Hash and Get-OcrSourceHashKey converts via ConvertTo-LowerHex' {
        $src = Get-Content -LiteralPath $ocrPath -Raw
        Assert-True ($src -match 'Import-Module[^\n]*Test\.Hash\.psm1') 'Test.OcrEngine must import Test.Hash'
        $ocrAst = Get-ModuleAst -Path $ocrPath
        $fn = Get-FunctionAst -RootAst $ocrAst -FunctionName 'Get-OcrSourceHashKey'
        Assert-True ($null -ne $fn) 'Get-OcrSourceHashKey must exist'
        Assert-True (Test-AstCallsCommand -Ast $fn -CommandName 'ConvertTo-LowerHex') 'Get-OcrSourceHashKey must convert via the shared helper'
    }
}
