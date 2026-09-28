<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42caf871-b327-4fe1-9fdb-2ee70289ee2b
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

    The behavioral cases put a fake `utmctl` on PATH (a registry of marker
    files plus the same exits-0-on-failure delete) and point $HOME at a
    throwaway tree, so nothing here touches UTM or a real VM. The fake is a
    /bin/sh script, so the cases run on every POSIX host and are skipped,
    visibly, only where there is no /bin/sh. The structural cases parse the
    module instead, for the ordering that only matters when a delete
    genuinely fails.

    Every fixture is built inside BeforeAll and every assertion throws. File-
    scope state is deliberately avoided: Pester 5+ runs an It block in a scope
    that cannot see variables or functions declared at file level, so a guard
    written there reads as $null at run time and turns every case into a
    silent pass.
    Run: Invoke-Pester -Path test/modules/Test.UtmGhostRegistration.Tests.ps1
#>

Describe 'A UTM registration whose bundle is gone (host.macos.utm)' {

    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:GhostModule = Join-Path $repoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        $script:GhostCanShim = -not $IsWindows
        $script:GhostSkip = 'the fake utmctl is a /bin/sh script'
        # Three drivers publish a module named Yuruna.Host; only this one may
        # be resident while the cases repoint its knobs.
        Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $script:GhostModule -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
        $script:GhostDriver = Get-Module -Name 'Yuruna.Host' | Select-Object -First 1
        # No pause between delete attempts: the fake answers at once.
        $script:GhostRetryDelay = & $script:GhostDriver { $prior = $script:UtmDeleteRetryDelaySeconds; $script:UtmDeleteRetryDelaySeconds = 0; $prior }

        # $PID keeps the paths distinct between concurrent runs.
        $script:GhostRoot   = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-ghost-$PID"
        $script:GhostBinDir = Join-Path $script:GhostRoot 'bin'
        $script:GhostHome   = Join-Path $script:GhostRoot 'home'
        $script:GhostRegDir = Join-Path $script:GhostRoot 'registry'
        $script:GhostStore  = Join-Path $script:GhostHome 'yuruna/guest.nosync'
        $script:GhostLog    = Join-Path $script:GhostRoot 'calls.log'

        Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

        # The fake reproduces the behaviors of the real tool that the code
        # under test exists for: `status` is the only trustworthy answer to "is
        # this name registered", and `delete` exits 0 whether or not it deleted
        # anything, printing the OSStatus -2700 notice when the bundle it wants
        # to trash is not there. YRN_FAKE_DELETE_FAILS makes every delete fail,
        # standing in for a bundle UTM cannot move (open file handles, a
        # permissions fault). YRN_FAKE_STATUS_MODE turns `status` into a denial
        # at exit 0 (deny0), an OSStatus failure at exit 1 (oserr) or a call
        # that never returns (hang); YRN_FAKE_DENY_AFTER_DELETE makes every
        # status after the first delete a denial. Every call is logged. The
        # fake refuses to run at all without its directories, so no removal it
        # performs can reach outside them.
        function Initialize-GhostFake {
            Remove-Item -LiteralPath $script:GhostRegDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:GhostHome -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item -ItemType Directory -Force -Path $script:GhostBinDir, $script:GhostRegDir, $script:GhostStore
            Set-Content -LiteralPath $script:GhostLog -Value '' -NoNewline -Encoding ascii
            $shim = Join-Path $script:GhostBinDir 'utmctl'
            # Joined with LF so /bin/sh accepts the shebang on any checkout.
            $body = @(
                '#!/bin/sh'
                'REG="$YRN_FAKE_REG"'
                'STORE="$YRN_FAKE_STORE"'
                'if [ -z "$REG" ] || [ -z "$STORE" ] || [ -z "$2" ]; then echo "fake utmctl: missing fixture directory or VM name" >&2; exit 97; fi'
                'echo "utmctl $*" >> "$YRN_FAKE_LOG"'
                'DENY="Error from event: The operation could not be completed. (OSStatus error -1743.)"'
                'case "$1" in'
                '  status)'
                '    if [ -f "$REG/.deny" ]; then echo "$DENY" >&2; exit 0; fi'
                '    case "$YRN_FAKE_STATUS_MODE" in'
                '      deny0) echo "$DENY" >&2; exit 0 ;;'
                '      oserr) echo "Error from event: The operation could not be completed. (OSStatus error -2700.)" >&2; exit 1 ;;'
                '      hang) exec sleep 300 ;;'
                '    esac'
                '    if [ -f "$REG/$2" ]; then echo stopped; exit 0; fi'
                '    echo "Error: Virtual machine not found."; exit 1 ;;'
                '  delete)'
                '    if [ -n "$YRN_FAKE_DENY_AFTER_DELETE" ]; then : > "$REG/.deny"; fi'
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
            $env:YRN_FAKE_REG               = $script:GhostRegDir
            $env:YRN_FAKE_STORE             = $script:GhostStore
            $env:YRN_FAKE_LOG               = $script:GhostLog
            $env:YRN_FAKE_DELETE_FAILS      = ''
            $env:YRN_FAKE_STATUS_MODE       = ''
            $env:YRN_FAKE_DENY_AFTER_DELETE = ''
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

        function Get-GhostCall {
            param([string]$Verb)
            return @(Get-Content -LiteralPath $script:GhostLog -ErrorAction SilentlyContinue | Where-Object { $_ -like "utmctl $Verb*" })
        }
    }

    AfterAll {
        if ($script:GhostDriver) { & $script:GhostDriver { param($d) $script:UtmDeleteRetryDelaySeconds = $d } $script:GhostRetryDelay }
        foreach ($name in 'YRN_FAKE_REG', 'YRN_FAKE_STORE', 'YRN_FAKE_LOG', 'YRN_FAKE_DELETE_FAILS', 'YRN_FAKE_STATUS_MODE', 'YRN_FAKE_DENY_AFTER_DELETE') {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
        if ($script:GhostRoot -and (Test-Path -LiteralPath $script:GhostRoot)) {
            Remove-Item -LiteralPath $script:GhostRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports registration from the status probe, not from a bundle on disk' {
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
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
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
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
        Assert-StringEqual 0 (Get-GhostStoreCount) -Because 'the restored bundle went with the delete, leaving no residue'
    }

    It 'reports failure and leaves no placeholder when the delete never takes' {
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
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
        Assert-StringEqual 0 (Get-GhostStoreCount) -Because 'the placeholder is removed once it is clear the delete will not use it'
    }

    It 'leaves a bundle alone when its registration survives the delete' {
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
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
        Assert-StringEqual 1 (Get-GhostStoreCount) -Because 'the bundle stays, so the registration stays removable'
    }

    It 'reports success without a delete when the name was never registered' {
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
        Initialize-GhostFake
        Invoke-WithGhostEnvironment {
            Assert-True (Remove-UtmVMRegistration -VMName 'absent-vm' -Confirm:$false) 'nothing to remove is not a failure'
        }
        Assert-Equal 0 (Get-GhostCall 'delete').Count -Because 'no delete for a name that is not there'
    }

    It 'refuses without a delete or a placeholder when the pre-delete probe is denied' {
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
        # A denial at exit 0 says nothing about registration; reading it as
        # absent would report a registration gone that nobody could see.
        Initialize-GhostFake
        New-GhostRegistration -VMName 'denied-vm'
        $env:YRN_FAKE_STATUS_MODE = 'deny0'
        try {
            Invoke-WithGhostEnvironment {
                $ok = Remove-UtmVMRegistration -VMName 'denied-vm' -Confirm:$false -WarningAction SilentlyContinue
                Assert-True (-not $ok) 'an unreadable registration is not a removed one'
            }
        } finally { $env:YRN_FAKE_STATUS_MODE = '' }
        Assert-Equal 0 (Get-GhostCall 'delete').Count -Because 'nothing is deleted on an unknown state'
        Assert-StringEqual 0 (Get-GhostStoreCount) -Because 'no placeholder is created'
    }

    It 'keeps the bundle when the probe after the delete is denied' {
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
        # Only a positive Absent authorizes removing the files; a denial after
        # the delete leaves the registration unknown, so the bundle must stay.
        Initialize-GhostFake
        New-GhostRegistration -VMName 'late-denied-vm' -WithBundle
        $env:YRN_FAKE_DELETE_FAILS = '1'
        $env:YRN_FAKE_DENY_AFTER_DELETE = '1'
        try {
            Invoke-WithGhostEnvironment {
                Assert-True (-not (Remove-UtmVMRegistration -VMName 'late-denied-vm' -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue)) 'the registration is not reported gone'
            }
            Remove-Item -LiteralPath (Join-Path $script:GhostRegDir '.deny') -Force -ErrorAction SilentlyContinue
            Invoke-WithGhostEnvironment {
                $removed = Remove-UtmTestVM -VMName 'late-denied-vm' -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
                Assert-True (-not @($removed)[-1]) 'the removal reports failure'
            }
        } finally {
            $env:YRN_FAKE_DELETE_FAILS = ''
            $env:YRN_FAKE_DENY_AFTER_DELETE = ''
        }
        Assert-StringEqual 1 (Get-GhostStoreCount) -Because 'the bundle is kept under a registration that may still exist'
    }

    It 'reads <Case> as <Expected> through Get-VMState' -TestCases @(
        @{ Case = 'a completed not-found answer';  Registered = $false; Mode = '';      Expected = 'absent' }
        @{ Case = 'an OSStatus failure at exit 1'; Registered = $true;  Mode = 'oserr'; Expected = 'unknown' }
        @{ Case = 'a stopped VM at exit 0';        Registered = $true;  Mode = '';      Expected = 'stopped' }
        @{ Case = 'a denial at exit 0';            Registered = $true;  Mode = 'deny0'; Expected = 'unknown' }
    ) {
        param($Case, $Registered, $Mode, $Expected)
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
        # The same fake that decides registration also answers for state, so
        # the two readings of one answer are pinned together.
        Initialize-GhostFake
        if ($Registered) { New-GhostRegistration -VMName 'state-vm' }
        $env:YRN_FAKE_STATUS_MODE = $Mode
        try {
            $state = Invoke-WithGhostEnvironment { Get-VMState -VMName 'state-vm' }
        } finally { $env:YRN_FAKE_STATUS_MODE = '' }
        Assert-StringEqual $Expected $state -Because $Case
    }

    It 'reads a status call that never returns as unknown, within its cap' {
        if (-not $script:GhostCanShim) { Set-ItResult -Skipped -Because $script:GhostSkip; return }
        Initialize-GhostFake
        New-GhostRegistration -VMName 'state-vm'
        $env:YRN_FAKE_STATUS_MODE = 'hang'
        try {
            Invoke-WithGhostEnvironment {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $record = Get-VMStateRecord -VMName 'state-vm' -Deadline (New-YurunaDeadline -TotalMilliseconds 2500) -WarningAction SilentlyContinue
                Assert-True ($sw.Elapsed.TotalSeconds -lt 6) "bounded ($($sw.Elapsed.TotalSeconds) s)"
                Assert-StringEqual 'unknown' $record.State
                Assert-StringEqual 'timeout' $record.Reason
            }
        } finally { $env:YRN_FAKE_STATUS_MODE = '' }
    }
}

Describe 'The removal path never trusts a utmctl delete exit code' {

    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ModuleFile = Join-Path $repoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        $script:ModuleText = Get-Content -Raw -LiteralPath $script:ModuleFile
        $script:ModuleAst  = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ModuleFile, [ref]$null, [ref]$null)
        function Get-FunctionBody {
            param([Parameter(Mandatory)][string]$Name)
            return [regex]::Match($script:ModuleText, "(?ms)^function $Name\b.*?\n\}").Value
        }
        # The utmctl subcommands a function actually invokes ('stop', 'delete',
        # ...), whether bare or through the bounded lifecycle wrapper. Reading
        # the AST rather than the text keeps these assertions from being
        # satisfied -- or broken -- by a comment that merely names one.
        function Get-InvokedUtmctlVerb {
            param([Parameter(Mandatory)][string]$Name)
            $fn = @($script:ModuleAst.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq $Name }, $true))
            if ($fn.Count -ne 1) { throw "Expected exactly one definition of $Name, found $($fn.Count)." }
            $commands = @($fn[0].Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] }, $true))
            $bare = @($commands |
                Where-Object { $_.CommandElements[0].Extent.Text -eq 'utmctl' -and $_.CommandElements.Count -gt 1 } |
                ForEach-Object { $_.CommandElements[1].Extent.Text })
            $wrapped = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-UtmctlLifecycle' } | ForEach-Object {
                $elements = @($_.CommandElements)
                for ($i = 1; $i -lt $elements.Count - 1; $i++) {
                    if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Verb') {
                        "$($elements[$i + 1].Extent.Text)".Trim("'", '"')
                    }
                }
            })
            return @($bare + $wrapped)
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
        Assert-True ($verbs -contains 'stop') 'the removal still stops the VM first'
        Assert-True ($verbs -notcontains 'delete') 'no unverified delete remains in the removal path'
    }

    It 'decides the delete outcome by re-probing, not from $LASTEXITCODE' {
        # `utmctl delete` exits 0 while printing the reason it deleted nothing,
        # so an exit-code check reads a total failure as a clean delete. The
        # re-probe goes through the structured Get-UtmVMRegistrationState
        # rather than the throwing Test-UtmVMRegistered wrapper: 'Unknown'
        # (a denied or timed-out re-probe) must retry, not be coerced into
        # either registered or absent.
        $body = Get-FunctionBody -Name 'Remove-UtmVMRegistration'
        Assert-True ($body.Length -gt 0) 'Remove-UtmVMRegistration is defined'
        Assert-True ((Get-InvokedUtmctlVerb -Name 'Remove-UtmVMRegistration') -contains 'delete') 'it is the function that issues the delete'
        $deleteAt = $body.IndexOf("Invoke-UtmctlLifecycle -Verb 'delete'")
        Assert-True ($deleteAt -ge 0) 'through the bounded lifecycle wrapper'
        $tail    = $body.Substring($deleteAt)
        $probeAt = $tail.IndexOf('Get-UtmVMRegistrationState')
        $exitAt  = $tail.IndexOf('LASTEXITCODE')
        Assert-True ($probeAt -ge 0) 'the registration is re-probed after the delete'
        Assert-True ($exitAt -lt 0 -or $probeAt -lt $exitAt) 'and the outcome is not gated on the exit code'
    }

    It 'Start-UtmVM names the registration when the bundle is the thing missing' {
        # The caller only reached a start because the name answered the reuse
        # check, so pointing at the absent path alone sends the reader looking
        # for a VM that was never created rather than for the registration
        # standing in the way of creating one. Reads the structured
        # Get-UtmVMRegistrationState directly (Registered/Absent/Unknown) so
        # an unconfirmed probe gets its own message instead of being folded
        # into either "create a VM" or "clear a registration" advice.
        $body = Get-FunctionBody -Name 'Start-UtmVM'
        Assert-True ($body.Length -gt 0) 'Start-UtmVM is defined'
        Assert-True ($body -match 'Get-UtmVMRegistrationState') 'the two ways the bundle can be missing are distinguished'
        $probeAt = $body.IndexOf('Get-UtmVMRegistrationState')
        # Anchored on however the start is ISSUED, not on the utmctl verb: the
        # start is delegated to a retrying helper, and pinning the literal verb
        # here would make this guard fail for a refactor that preserves exactly
        # the ordering it exists to protect.
        $startMatch = [regex]::Match($body, 'Invoke-UtmVMStartWithRetry|utmctl start')
        Assert-True ($startMatch.Success) 'the start is still there'
        Assert-True ($probeAt -ge 0 -and $probeAt -lt $startMatch.Index) 'and the probe happens before any start is attempted'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
