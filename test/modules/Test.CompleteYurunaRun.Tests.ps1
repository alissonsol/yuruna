<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42c57683-d950-42e5-b4d6-4ab0ea4adc92
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation result pester
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
    Structural Pester guard: the failure-reporting tail of the Set-Resource /
    Set-Component / Set-Workload entrypoints is centralized in one
    Complete-YurunaRun helper, not copy-pasted.
.DESCRIPTION
    Structural Pester guard: the failure-reporting tail of the Set-Resource /
    Set-Component / Set-Workload entrypoints is centralized in one
    Complete-YurunaRun helper, not copy-pasted. These guards assert the helper exists +
    is exported, all three entrypoints delegate to it, none of them still
    open-codes the failure-report JSON, and the tail emits the transcript before the
    result JSON. Source-text only. Runs under Pester 4.10.1.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'
$script:resultMod = Join-Path $autoDir 'Yuruna.Result.psm1'
$script:entrypoints = 'Set-Component','Set-Resource','Set-Workload'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'complete-yuruna-run -- the entrypoint failure tail is shared by one helper' {
    It 'Yuruna.Result defines and exports Complete-YurunaRun' {
        $src = Get-Content -LiteralPath $script:resultMod -Raw
        Assert-True ($src -match '(?m)^function Complete-YurunaRun\b') 'Complete-YurunaRun must be defined'
        $exportText = ($src -split "`n" | Where-Object { $_ -match 'Export-ModuleMember' }) -join "`n"
        Assert-True ($exportText -match 'Complete-YurunaRun') 'Complete-YurunaRun must be exported'
    }
    It 'each of the three entrypoints delegates to Complete-YurunaRun exactly once' {
        foreach ($e in $script:entrypoints) {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            $n = ([regex]::Matches($src, [regex]::Escape('Complete-YurunaRun -Result $result -TranscriptFile $transcriptFileName'))).Count
            Assert-True ($n -eq 1) "$e must call Complete-YurunaRun once, found $n"
        }
    }
    It 'no entrypoint still open-codes the failure-report JSON (the tail moved to the helper)' {
        foreach ($e in $script:entrypoints) {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            $n = ([regex]::Matches($src, [regex]::Escape('ConvertTo-Json -Depth 4 -Compress'))).Count
            Assert-True ($n -eq 0) "$e should no longer inline the failure-report JSON, found $n"
        }
    }
    It 'the failure-report JSON is emitted from exactly one place (the helper)' {
        $src = Get-Content -LiteralPath $script:resultMod -Raw
        $n = ([regex]::Matches($src, [regex]::Escape('ConvertTo-Json -Depth 4 -Compress'))).Count
        Assert-True ($n -eq 1) "the helper must own the single failure-report JSON emit, found $n"
    }
    It 'the failure tail emits the transcript BEFORE the result JSON' {
        # The JSON is the one line that names the failure; the transcript that
        # accompanies it runs to thousands of lines. Not every consumer keeps all of
        # stdout -- a guest driven through its console is read back by OCR of the
        # final screenful -- so whatever is printed last is what survives. Emitting
        # the JSON first buries the reason and leaves an operator holding the tail of
        # a transcript that ends on a successful-looking step.
        $src = Get-Content -LiteralPath $script:resultMod -Raw
        $failBranch = [regex]::Match($src, '(?s)if \(-Not \(Test-YurunaResultManifestOk \$Result\)\).*?exit 1')
        Assert-True $failBranch.Success 'the failure branch must be present in the helper'
        $iTranscript = $failBranch.Value.IndexOf('Get-Content -Path $TranscriptFile')
        $iJson       = $failBranch.Value.IndexOf('ConvertTo-Json -Depth 4 -Compress')
        Assert-True ($iTranscript -ge 0) 'the failure tail must emit the transcript'
        Assert-True ($iJson -ge 0) 'the failure tail must emit the result JSON'
        Assert-True ($iTranscript -lt $iJson) 'the transcript must be emitted before the result JSON, so the reason is the last thing printed'
    }
}
