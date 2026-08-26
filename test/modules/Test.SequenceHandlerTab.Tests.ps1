<#PSScriptInfo
.VERSION 2026.08.25
.GUID 426e14b8-0b20-4669-be3f-a832ab317992
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence handler tab pester
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
    Structural Pester guard on test/modules/Test.SequenceHandler.psm1: the
    Tab-navigation prefix loop is shared by one Send-TabNavigation helper, not
    copy-pasted across the keyboard-input verbs.
.DESCRIPTION
    The byte-identical 'read tabCount, press Tab N times (300ms apart), 500ms
    settle' block appeared in both waitForAndEnter and passwdPrompt. These guards
    assert the block is now in one Send-TabNavigation helper, both handlers
    delegate to it, and the Tab-press loop appears exactly once. Source-text only.
    Runs under Pester 4.10.1 (script-scoped throw helper). (The divergent
    type/drain/Enter tails remain unshared and are out of scope for these guards.)
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$script:src  = Get-Content (Join-Path $here 'Test.SequenceHandler.psm1') -Raw

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'sequence-handler-tab -- the Tab-navigation prefix is shared by one helper' {
    It 'defines a Send-TabNavigation helper' {
        Assert-True ($script:src -match '(?m)^function Send-TabNavigation\b') `
            'the duplicated Tab-navigation loop must collapse into one helper'
    }
    It 'both keyboard-input handlers delegate to Send-TabNavigation' {
        $n = ([regex]::Matches($script:src, [regex]::Escape('Send-TabNavigation -Context $c'))).Count
        Assert-True ($n -eq 2) "expected both handlers to call Send-TabNavigation, found $n"
    }
    It 'the Tab-press debug/loop now appears exactly once (inside the helper)' {
        $n = ([regex]::Matches($script:src, [regex]::Escape('Sending $tabCount Tab'))).Count
        Assert-True ($n -eq 1) "expected exactly one Tab-navigation loop after dedup, found $n"
    }
}
