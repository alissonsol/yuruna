<#PSScriptInfo
.VERSION 2026.08.19
.GUID 4240031a-e567-4a6d-aba2-bb96dd5753f8
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

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$script:shPath   = Join-Path $repoRoot 'automation/fetch-and-execute.sh'
$psm1Path = Join-Path $here 'Test.SequenceHandler.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$psm1 = Get-Content -Raw -LiteralPath $psm1Path
$script:decl = [regex]::Match($psm1, "\`$script:NonzeroScriptExitSentinel\s*=\s*'([^']+)'")

}

Describe 'NONZERO SCRIPT EXIT cross-language sentinel' {
    It 'declares the sentinel as a named pwsh constant' {
        Assert-True $script:decl.Success 'the $script:NonzeroScriptExitSentinel constant is declared'
        Assert-StringEqual -Actual $script:decl.Groups[1].Value -Expected 'NONZERO SCRIPT EXIT:' -Because 'the canonical sentinel value'
    }
    It 'the bash producer (fetch-and-execute.sh) emits the identical literal' {
        $sh = Get-Content -Raw -LiteralPath $script:shPath
        Assert-True ($sh -match [regex]::Escape($script:decl.Groups[1].Value)) 'the pwsh constant value appears verbatim in the bash producer'
    }
    It 'the pwsh consumer references the constant, not a re-inlined bare literal' {
        # The single-quoted CODE literal appears exactly once -- the constant
        # declaration -- so the fetchAndExecute failPattern uses the variable, not
        # a re-inlined string. (A double-quoted mention in a comment is excluded.)
        $hits = ([regex]::Matches($psm1, [regex]::Escape("'NONZERO SCRIPT EXIT:'"))).Count
        Assert-StringEqual -Actual $hits -Expected 1 -Because 'only the constant declaration holds the code literal; the consumer uses $script:NonzeroScriptExitSentinel'
    }
}

Describe 'payload-unavailable reasons (cross-language)' {

    # The sentinel above says a step failed; these say WHICH failure it was, and
    # that distinction is the whole classification. The wrapper prints the reason
    # and the handler reads it, so the two lists have to agree across languages
    # exactly as the sentinel does -- a reason reworded on one side alone silently
    # stops matching, and the failure lands back on script_error.
    BeforeAll {
        # Line-walked, not regex-spanned: the reasons themselves contain
        # parentheses, so a lazy @\((.*?)\) stops inside the first one and reads
        # back an empty list -- a guard that then asserts nothing about anything.
        $psm1Lines = Get-Content -LiteralPath (Join-Path $here 'Test.SequenceHandler.psm1')
        $script:reasons = @()
        $inBlock = $false
        foreach ($line in $psm1Lines) {
            if (-not $inBlock) {
                if ($line -match '^\s*\$script:PayloadUnavailableReason\s*=\s*@\(') { $inBlock = $true }
                continue
            }
            if ($line -match '^\s*\)') { break }
            foreach ($m in [regex]::Matches($line, "'([^']+)'")) { $script:reasons += $m.Groups[1].Value }
        }
        $script:shSrc = Get-Content -Raw -LiteralPath $script:shPath
    }

    It 'declares the reasons the handler matches' {
        Assert-True ($script:reasons.Count -ge 3) "expected the reason list to be declared; found $($script:reasons.Count)"
    }

    It 'emits every one of them verbatim from the bash producer' {
        foreach ($r in $script:reasons) {
            Assert-True ($script:shSrc.Contains($r)) "fetch-and-execute.sh must print '$r' for the handler to recognize it"
        }
    }

    It 'leaves out the reason that means the script actually ran' {
        # "(exit N)" is the payload's own status: it ran and failed, which is what
        # script_error is for. Matching it here would reclassify every genuine
        # guest-script failure as a transient shortage and hand it to a retry.
        Assert-True ($script:shSrc -match '\(exit %d\)') 'the producer still reports a real non-zero script exit'
        foreach ($r in $script:reasons) {
            Assert-True ($r -ne '(exit ') 'a real script exit must not be treated as a missing payload'
        }
    }

    It 'leaves out the integrity refusal, which never ran but must not be retried' {
        # A digest mismatch means the bytes served did not match what the host
        # published. Nothing ran, but the answer is not "try again" -- a retry is
        # precisely what a tampered source wants, and the wrapper refuses on purpose.
        Assert-True ($script:shSrc -match 'integrity mismatch') 'the producer still refuses on a digest mismatch'
        foreach ($r in $script:reasons) {
            Assert-True (-not $r.Contains('integrity')) 'an integrity refusal must not be classified as a retryable shortage'
        }
    }
}
