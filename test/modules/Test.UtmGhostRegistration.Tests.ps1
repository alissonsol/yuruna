<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42d7c5e9-1b83-4a06-9e5f-7c24b81d3fa0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test utm registration ghost delete pester
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
    Coverage for clearing a UTM registration whose bundle is gone from disk:
    the probe that decides whether a name is still registered, the bundle
    restore that lets the deregistration finish, and the ordering rule that
    keeps a surviving registration from being stripped of its bundle.
.DESCRIPTION
    UTM deletes a VM by moving its bundle to the trash, so a registration
    whose bundle is missing cannot be deleted -- and `utmctl delete` reports
    that failure by printing it while still exiting 0. The pair strands the
    name in UTM: it keeps answering `utmctl status`, so the sequence engine
    reads it as an existing VM, skips creation, and starts a VM with no disk.

    The behavioural cases put a fake `utmctl` on PATH (a registry of marker
    files plus the same exits-0-on-failure delete) and point $HOME at a
    throwaway tree, so nothing here touches UTM or a real VM. The structural
    cases parse the module instead, for the ordering that only matters when a
    delete genuinely fails.

    Every fixture is built inside BeforeAll and every assertion throws, so the
    file behaves the same under the OS-bundled Pester 3.4 and Pester 5+. File-
    scope state is deliberately avoided: Pester 5+ runs an It block in a scope
    that cannot see variables or functions declared at file level, so a guard
    written there ("skip unless macOS") reads as $null at run time and turns
    every case into a silent pass.
    Run: Invoke-Pester -Path test/modules/Test.UtmGhostRegistration.Tests.ps1
#>

Describe 'A UTM registration whose bundle is gone (host.macos.utm)' {

    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:GhostModule = Join-Path $repoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        # These cases drive the module's own utmctl calls, so they run where
        # that module is the host driver.
        $script:GhostIsMac = [bool]$IsMacOS
        if ($script:GhostIsMac) {
            Import-Module $script:GhostModule -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
        }

        # $PID keeps the paths distinct between concurrent runs.
        $script:GhostRoot   = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-ghost-$PID"
        $script:GhostBinDir = Join-Path $script:GhostRoot 'bin'
        $script:GhostHome   = Join-Path $script:GhostRoot 'home'
        $script:GhostRegDir = Join-Path $script:GhostRoot 'registry'
        $script:GhostStore  = Join-Path $script:GhostHome 'yuruna/guest.nosync'

        function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
        function Assert-Equal {
            param($Expected, $Actual, [string]$Because = '')
            if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
        }

        # The fake reproduces the two behaviours of the real tool that the code
        # under test exists for: `status` is the only trustworthy answer to "is
        # this name registered", and `delete` exits 0 whether or not it deleted
        # anything, printing the OSStatus -2700 notice when the bundle it wants
        # to trash is not there. YRN_FAKE_DELETE_FAILS makes every delete fail,
        # standing in for a bundle UTM cannot move (open file handles, a
        # permissions fault).
        function Initialize-GhostFake {
            Remove-Item -LiteralPath $script:GhostRegDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:GhostHome -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item -ItemType Directory -Force -Path $script:GhostBinDir, $script:GhostRegDir, $script:GhostStore
            $shim = Join-Path $script:GhostBinDir 'utmctl'
            # Joined with LF so /bin/sh accepts the shebang on any checkout.
            $body = @(
                '#!/bin/sh'
                'REG="$YRN_FAKE_REG"'
                'STORE="$YRN_FAKE_STORE"'
                'case "$1" in'
                '  status)'
                '    if [ -f "$REG/$2" ]; then echo stopped; exit 0; fi'
                '    echo "Error: Virtual machine not found."; exit 1 ;;'
                '  delete)'
                '    if [ -d "$STORE/$2.utm" ] && [ -z "$YRN_FAKE_DELETE_FAILS" ]; then'
                '      rm -rf "$STORE/$2.utm"; rm -f "$REG/$2"; exit 0'
                '    fi'
                '    echo "Error from event: The operation could not be completed. (OSStatus error -2700.)"'
                '    echo "bundle could not be removed."'
                '    exit 0 ;;'
                'esac'
                'exit 0'
            ) -join "`n"
            Set-Content -LiteralPath $shim -Value $body -NoNewline -Encoding ascii
            & chmod +x $shim
            $env:YRN_FAKE_REG          = $script:GhostRegDir
            $env:YRN_FAKE_STORE        = $script:GhostStore
            $env:YRN_FAKE_DELETE_FAILS = ''
        }

        function New-GhostRegistration {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes only into the suite-owned temp root that AfterAll removes.')]
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$VMName, [switch]$WithBundle)
            Set-Content -LiteralPath (Join-Path $script:GhostRegDir $VMName) -Value 'registered' -Encoding ascii
            if ($WithBundle) {
                $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:GhostStore "$VMName.utm")
            }
        }

        # Run $Body with the fake utmctl first on PATH and $HOME on the fake
        # tree. $HOME is set globally because the module resolves it in its own
        # scope, where a caller-scope assignment is invisible.
        function Invoke-WithGhostEnvironment {
            param([Parameter(Mandatory)][scriptblock]$Body)
            $prevHome = $HOME
            $prevPath = $env:PATH
            try {
                $env:PATH = $script:GhostBinDir + [IO.Path]::PathSeparator + $env:PATH
                Set-Variable -Name HOME -Value $script:GhostHome -Scope Global -Force
                return & $Body
            } finally {
                Set-Variable -Name HOME -Value $prevHome -Scope Global -Force
                $env:PATH = $prevPath
            }
        }

        function Get-GhostStoreCount {
            return @(Get-ChildItem -LiteralPath $script:GhostStore -ErrorAction SilentlyContinue).Count
        }
    }

    AfterAll {
        if ($script:GhostRoot -and (Test-Path -LiteralPath $script:GhostRoot)) {
            Remove-Item -LiteralPath $script:GhostRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports registration from the status probe, not from a bundle on disk' {
        if (-not $script:GhostIsMac) { return }
        # The two can disagree in both directions, and it is the registration
        # that decides whether a name can be created again.
        Initialize-GhostFake
        New-GhostRegistration -VMName 'probe-ghost'
        Invoke-WithGhostEnvironment {
            Assert-True (Test-UtmVMRegistered -VMName 'probe-ghost') 'a bundle-less name still registered reads as registered'
            Assert-True (-not (Test-UtmVMRegistered -VMName 'never-existed')) 'an unknown name reads as absent'
        }
    }

    It 'clears a registration whose bundle is missing by restoring one to delete' {
        if (-not $script:GhostIsMac) { return }
        # Without the restore this delete fails identically forever: UTM has
        # nothing at the recorded path to move to the trash, so the name stays
        # registered and every later cycle reuses a VM that has no disk.
        Initialize-GhostFake
        New-GhostRegistration -VMName 'stranded-vm'
        Invoke-WithGhostEnvironment {
            $ok = Remove-UtmVMRegistration -VMName 'stranded-vm' -Confirm:$false -InformationAction SilentlyContinue
            Assert-True $ok 'the deregistration reports success'
            Assert-True (-not (Test-UtmVMRegistered -VMName 'stranded-vm')) 'and UTM no longer lists the name'
        }
        Assert-Equal 0 (Get-GhostStoreCount) -Because 'the restored bundle went with the delete, leaving no residue'
    }

    It 'reports failure and leaves no placeholder when the delete never takes' {
        if (-not $script:GhostIsMac) { return }
        # A placeholder is only justified while it is about to become the
        # deleted VM's trashed bundle. One left behind under a live
        # registration would be read as a real VM by anything inventorying the
        # store.
        Initialize-GhostFake
        New-GhostRegistration -VMName 'immovable-vm'
        $env:YRN_FAKE_DELETE_FAILS = '1'
        try {
            Invoke-WithGhostEnvironment {
                $ok = Remove-UtmVMRegistration -VMName 'immovable-vm' -Confirm:$false -InformationAction SilentlyContinue
                Assert-True (-not $ok) 'a delete that never took is reported as a failure'
                Assert-True (Test-UtmVMRegistered -VMName 'immovable-vm') 'the name is still registered'
            }
        } finally { $env:YRN_FAKE_DELETE_FAILS = '' }
        Assert-Equal 0 (Get-GhostStoreCount) -Because 'the placeholder is removed once it is clear the delete will not use it'
    }

    It 'leaves a bundle alone when its registration survives the delete' {
        if (-not $script:GhostIsMac) { return }
        # Removing the files under a registration that survived is what strands
        # the name to begin with, and a stranded name is the worse state: it
        # still answers `utmctl status`, so it reads as a reusable VM.
        Initialize-GhostFake
        New-GhostRegistration -VMName 'locked-vm' -WithBundle
        $env:YRN_FAKE_DELETE_FAILS = '1'
        try {
            Invoke-WithGhostEnvironment {
                $ok = Remove-UtmVMRegistration -VMName 'locked-vm' -Confirm:$false -InformationAction SilentlyContinue
                Assert-True (-not $ok) 'the failure is reported'
            }
        } finally { $env:YRN_FAKE_DELETE_FAILS = '' }
        Assert-Equal 1 (Get-GhostStoreCount) -Because 'the bundle stays, so the registration stays removable'
    }

    It 'reports success without a delete when the name was never registered' {
        if (-not $script:GhostIsMac) { return }
        Initialize-GhostFake
        Invoke-WithGhostEnvironment {
            Assert-True (Remove-UtmVMRegistration -VMName 'absent-vm' -Confirm:$false) 'nothing to remove is not a failure'
        }
    }
}

Describe 'The removal path never trusts a utmctl delete exit code' {

    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ModuleFile = Join-Path $repoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        $script:ModuleText = Get-Content -Raw -LiteralPath $script:ModuleFile
        $script:ModuleAst  = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ModuleFile, [ref]$null, [ref]$null)
        function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
        function Get-FunctionBody {
            param([Parameter(Mandatory)][string]$Name)
            return [regex]::Match($script:ModuleText, "(?ms)^function $Name\b.*?\n\}").Value
        }
        # Command names actually invoked by a function. Reading the AST rather
        # than the text keeps these assertions from being satisfied -- or
        # broken -- by a comment that merely mentions the command.
        # The utmctl subcommands a function actually invokes ('stop', 'delete',
        # ...). Reading the AST rather than the text keeps these assertions from
        # being satisfied -- or broken -- by a comment that merely names one.
        function Get-InvokedUtmctlVerb {
            param([Parameter(Mandatory)][string]$Name)
            $fn = @($script:ModuleAst.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq $Name }, $true))
            if ($fn.Count -ne 1) { throw "Expected exactly one definition of $Name, found $($fn.Count)." }
            return @($fn[0].Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $_.CommandElements[0].Extent.Text -eq 'utmctl' -and $_.CommandElements.Count -gt 1 } |
                ForEach-Object { $_.CommandElements[1].Extent.Text })
        }
    }

    It 'Remove-UtmTestVM confirms deregistration before it touches the bundle' {
        $body = Get-FunctionBody -Name 'Remove-UtmTestVM'
        Assert-True ($body.Length -gt 0) 'Remove-UtmTestVM is defined'
        Assert-True ($body -match 'Remove-UtmVMRegistration') 'the delete goes through the verifying helper'
        $deregisterAt = $body.IndexOf('Remove-UtmVMRegistration')
        $bundleAt     = $body.IndexOf('Remove-UtmBundleWithRetry')
        Assert-True ($bundleAt -ge 0) 'the bundle removal is still there'
        Assert-True ($deregisterAt -lt $bundleAt) 'the registration is confirmed gone BEFORE the bundle is removed'
        $verbs = Get-InvokedUtmctlVerb -Name 'Remove-UtmTestVM'
        Assert-True ($verbs -notcontains 'delete') 'no unverified delete remains in the removal path'
    }

    It 'decides the delete outcome by re-probing, not from $LASTEXITCODE' {
        # `utmctl delete` exits 0 while printing the reason it deleted nothing,
        # so an exit-code check reads a total failure as a clean delete.
        $body = Get-FunctionBody -Name 'Remove-UtmVMRegistration'
        Assert-True ($body.Length -gt 0) 'Remove-UtmVMRegistration is defined'
        $deleteAt = $body.IndexOf('utmctl delete')
        Assert-True ($deleteAt -ge 0) 'it is the function that issues the delete'
        $tail    = $body.Substring($deleteAt)
        $probeAt = $tail.IndexOf('Test-UtmVMRegistered')
        $exitAt  = $tail.IndexOf('LASTEXITCODE')
        Assert-True ($probeAt -ge 0) 'the registration is re-probed after the delete'
        Assert-True ($exitAt -lt 0 -or $probeAt -lt $exitAt) 'and the outcome is not gated on the exit code'
    }

    It 'Start-UtmVM names the registration when the bundle is the thing missing' {
        # The caller only reached a start because the name answered the reuse
        # check, so pointing at the absent path alone sends the reader looking
        # for a VM that was never created rather than for the registration
        # standing in the way of creating one.
        $body = Get-FunctionBody -Name 'Start-UtmVM'
        Assert-True ($body.Length -gt 0) 'Start-UtmVM is defined'
        Assert-True ($body -match 'Test-UtmVMRegistered') 'the two ways the bundle can be missing are distinguished'
        $probeAt = $body.IndexOf('Test-UtmVMRegistered')
        $startAt = $body.IndexOf('utmctl start')
        Assert-True ($startAt -ge 0) 'the start is still there'
        Assert-True ($probeAt -ge 0 -and $probeAt -lt $startAt) 'and the probe happens before any start is attempted'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
