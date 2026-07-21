<#PSScriptInfo
.VERSION 2026.07.21
.GUID 426b8d40-9c17-4e53-a1d8-4b7e0c3f5a29
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sentinel cross-language pester
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
    Drift guard for the cross-language fetch-and-execute failure sentinel. The
    guest bash wrapper PRINTS it and the pwsh fetchAndExecute verb MATCHES it;
    if either side changes the string the coupling silently breaks (a crashed
    fetch burns the full timeout). This asserts both sides still agree.
.DESCRIPTION
    Pure text/AST assertions -- no module import (Test.SequenceHandler pulls a
    heavy dep chain). Reads the declared pwsh constant and confirms the bash
    producer emits the identical literal, and that the pwsh consumer references
    the constant rather than re-inlining the bare string.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$shPath   = Join-Path $repoRoot 'automation/fetch-and-execute.sh'
$psm1Path = Join-Path $here 'Test.SequenceHandler.psm1'

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Actual, $Expected, [string]$Because = '') if ("$Actual" -ne "$Expected") { throw "Expected '$Expected', got '$Actual'. $Because" } }

$psm1 = Get-Content -Raw -LiteralPath $psm1Path
$decl = [regex]::Match($psm1, "\`$script:NonzeroScriptExitSentinel\s*=\s*'([^']+)'")

Describe 'NONZERO SCRIPT EXIT cross-language sentinel' {
    It 'declares the sentinel as a named pwsh constant' {
        Assert-True $decl.Success 'the $script:NonzeroScriptExitSentinel constant is declared'
        Assert-Equal -Actual $decl.Groups[1].Value -Expected 'NONZERO SCRIPT EXIT:' -Because 'the canonical sentinel value'
    }
    It 'the bash producer (fetch-and-execute.sh) emits the identical literal' {
        $sh = Get-Content -Raw -LiteralPath $shPath
        Assert-True ($sh -match [regex]::Escape($decl.Groups[1].Value)) 'the pwsh constant value appears verbatim in the bash producer'
    }
    It 'the pwsh consumer references the constant, not a re-inlined bare literal' {
        # The single-quoted CODE literal appears exactly once -- the constant
        # declaration -- so the fetchAndExecute failPattern uses the variable, not
        # a re-inlined string. (A double-quoted mention in a comment is excluded.)
        $hits = ([regex]::Matches($psm1, [regex]::Escape("'NONZERO SCRIPT EXIT:'"))).Count
        Assert-Equal -Actual $hits -Expected 1 -Because 'only the constant declaration holds the code literal; the consumer uses $script:NonzeroScriptExitSentinel'
    }
}
