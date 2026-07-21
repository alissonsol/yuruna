<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42d1e2f3-a4b5-4c67-89ab-cd0e1f2a3b52
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic console tty pester
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
    Guards the tty hygiene around the console diagnostics rung: the line
    buffer is cleared before the one-liner is typed, and a failed rung
    leaves the guest on a clean prompt.
.DESCRIPTION
    The console rung types a ~240-character command into the guest's tty.
    Anything already on that line concatenates with it, and anything left
    on the line after a failed rung concatenates with the NEXT sequence
    step -- which is how a following 'clear; sudo reboot now' can be
    swallowed as arguments to a command still sitting unsubmitted.

    Keystroke injection and the status service are stubbed, so these run
    with no host, no VM and no network: Send-Text / Send-Key record into a
    file-scope log, and the module-private endpoint resolver is replaced in
    module scope. The rung's failure paths are then driven for real
    (injection throw, upload timeout) and the recorded key order asserted.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.DiagnosticTtyHygiene.Tests.ps1
#>

$here    = Split-Path -Parent $PSCommandPath
$modPath = Join-Path $here 'Test.Diagnostic.psm1'
Import-Module $modPath -Force

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures live at FILE scope, above the first Describe: a Describe body runs
# during discovery and its variables are thrown away before any It executes.
# The temp folder is named from $PID rather than a fresh GUID -- the file body
# executes once per Pester pass, and a per-pass GUID would point the module at
# one folder while the assertions read another.
$TtyTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-ttyhygiene-$PID"
Remove-Item -LiteralPath $TtyTestRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $TtyTestRoot 'cyclebase/vm1') | Out-Null
$TtyFolder = Join-Path $TtyTestRoot 'cyclebase/vm1'

# All mutable stub state hangs off ONE object held in an unqualified
# file-scope variable. Both parts matter: an It block gets a fresh scope, so
# it can read a file-scope variable but cannot assign to one, and mutating a
# shared object's properties needs no assignment at all. The stubs read the
# same variable from their own scope chain, which reaches this script scope
# because that is where they are defined.
$TtyStub = [pscustomobject]@{
    Log         = [System.Collections.Generic.List[string]]::new()
    ThrowOnKey  = $false
    ThrowOnText = $false
    # When set, the Enter that submits the one-liner writes this path,
    # standing in for the guest running the command and POSTing its capture
    # back. The file has to appear DURING the wait, not before it: the rung
    # snapshots the target's mtime before typing and ignores a file that has
    # not advanced past that baseline, so a pre-created file is correctly
    # treated as a stale leftover rather than this attempt's upload.
    UploadPath  = $null
}

# Stubs stand in for the Yuruna.Host facade, which the diagnostics module
# resolves through the global command table. They assert the call shape the
# rung is contractually required to use -- a hygiene key sent over anything
# but the gui mechanism would never reach the guest console.
function global:Send-Key {
    param([string]$VMName, [string]$Key, [string]$Mechanism = 'gui')
    if (-not $VMName) { throw 'Send-Key stub: called without -VMName' }
    if ($Mechanism -ne 'gui') { throw "Send-Key stub: tty hygiene must use the gui mechanism, got '$Mechanism'" }
    $TtyStub.Log.Add("key:$Key")
    if ($TtyStub.ThrowOnKey) { throw 'simulated keystroke failure' }
    if ($Key -eq 'Enter' -and $TtyStub.UploadPath) {
        Set-Content -LiteralPath $TtyStub.UploadPath -Value 'captured' -Encoding utf8
    }
    return $true
}
function global:Send-Text {
    param([string]$VMName, [string]$Text, [string]$Mechanism = 'gui')
    if (-not $VMName) { throw 'Send-Text stub: called without -VMName' }
    if ($Mechanism -ne 'gui') { throw "Send-Text stub: expected the gui mechanism, got '$Mechanism'" }
    if ($Text -notmatch 'curl') { throw 'Send-Text stub: expected the diagnostics one-liner' }
    $TtyStub.Log.Add('text')
    if ($TtyStub.ThrowOnText) { throw 'simulated keystroke injection failure' }
    return $true
}

# The endpoint resolver reads test.config.yml and needs a discoverable guest
# IP; replace it inside the module's own session state so the rung runs
# without a host. `script:` is required: a bare `function` inside an invoked
# scriptblock lands in a CHILD scope and is discarded the moment the block
# returns, leaving the real resolver in place.
& (Get-Module Test.Diagnostic) {
    function script:Resolve-StatusServiceEndpoint {
        param([string]$VMName)
        if (-not $VMName) { throw 'endpoint stub: called without -VMName' }
        return @{ ip = '127.0.0.1'; port = 8080; url = 'http://127.0.0.1:8080' }
    }
}

function Invoke-ConsoleRung {
    # Drives the module-private console rung in module scope so the helper
    # stays private, clearing the keystroke log first.
    param([string]$FolderPath, [string]$FileName, [int]$TimeoutSeconds = 1)
    $TtyStub.Log.Clear()
    & (Get-Module Test.Diagnostic) {
        param($f, $n, $t)
        Invoke-RemoteDiagnosticsConsole -VMName 'vm1' -FailureFolderPath $f `
            -DiagnosticsFileName $n -TimeoutSeconds $t
    } $FolderPath $FileName $TimeoutSeconds
}

function Invoke-TtyHelper {
    # Invokes one of the module-private hygiene helpers in module scope.
    param([string]$Name)
    $TtyStub.Log.Clear()
    & (Get-Module Test.Diagnostic) {
        param($n)
        & $n -VMName 'vm1'
    } $Name
}

Describe 'Clear-GuestTtyLine' {
    It 'sends exactly one Ctrl-U' {
        Invoke-TtyHelper -Name 'Clear-GuestTtyLine'
        Assert-Equal -Expected 'key:CtrlU' -Actual ($TtyStub.Log -join ',') `
            -Because 'Ctrl-U is VKILL: it discards the pending line without signalling any process'
    }
    It 'swallows a keystroke failure instead of throwing' {
        # A failed clear must not stop the payload from being typed, and must
        # not turn the soft-failing diagnostics path into a thrown exception.
        $TtyStub.ThrowOnKey = $true
        try {
            $err = $null
            try { Invoke-TtyHelper -Name 'Clear-GuestTtyLine' } catch { $err = $_ }
            Assert-True ($null -eq $err) "Clear-GuestTtyLine must not rethrow: $err"
        } finally {
            $TtyStub.ThrowOnKey = $false
        }
    }
}

Describe 'Reset-GuestTtyPrompt' {
    It 'sends Ctrl-C before Enter' {
        # Order is load-bearing: an Enter sent first would EXECUTE whatever
        # corrupted line is pending instead of discarding it.
        Invoke-TtyHelper -Name 'Reset-GuestTtyPrompt'
        Assert-Equal -Expected 'key:CtrlC,key:Enter' -Actual ($TtyStub.Log -join ',')
    }
    It 'swallows a keystroke failure instead of throwing' {
        $TtyStub.ThrowOnKey = $true
        try {
            $err = $null
            try { Invoke-TtyHelper -Name 'Reset-GuestTtyPrompt' } catch { $err = $_ }
            Assert-True ($null -eq $err) "Reset-GuestTtyPrompt must not rethrow: $err"
        } finally {
            $TtyStub.ThrowOnKey = $false
        }
    }
}

Describe 'Console rung tty bracket' {
    It 'clears the line buffer before typing the one-liner' {
        $r = Invoke-ConsoleRung -FolderPath $TtyFolder -FileName 'never.arrives.txt'
        Assert-Equal -Expected $false -Actual $r.success -Because 'no file lands, so the rung fails'
        $log = @($TtyStub.Log)
        Assert-Equal -Expected 'key:CtrlU' -Actual $log[0] `
            -Because 'residue on the line would otherwise concatenate with the command'
        Assert-Equal -Expected 'text' -Actual $log[1]
    }
    It 'restores the prompt after an upload timeout' {
        $r = Invoke-ConsoleRung -FolderPath $TtyFolder -FileName 'never.arrives.txt'
        Assert-Equal -Expected $false -Actual $r.success
        Assert-Equal -Expected 'key:CtrlU,text,key:Enter,key:CtrlC,key:Enter' `
            -Actual ($TtyStub.Log -join ',') `
            -Because 'the timeout path must leave the guest on a clean prompt'
    }
    It 'restores the prompt when keystroke injection throws' {
        # The throw happens part-way through Send-Text, so characters may
        # already have reached the tty -- that half-line is exactly what has
        # to be cleared.
        $TtyStub.ThrowOnText = $true
        try {
            $r = Invoke-ConsoleRung -FolderPath $TtyFolder -FileName 'never.arrives.txt'
            Assert-Equal -Expected $false -Actual $r.success
            Assert-Equal -Expected 'key:CtrlU,text,key:CtrlC,key:Enter' `
                -Actual ($TtyStub.Log -join ',')
        } finally {
            $TtyStub.ThrowOnText = $false
        }
    }
    It 'does not interrupt the guest when the rung succeeds' {
        # On success the guest ran the command and returned to its own
        # prompt; a Ctrl-C there could kill whatever the next step started.
        $fileName = 'landed.system.diagnostic.ok.txt'
        $TtyStub.UploadPath = Join-Path $TtyFolder $fileName
        try {
            $r = Invoke-ConsoleRung -FolderPath $TtyFolder -FileName $fileName -TimeoutSeconds 5
            Assert-Equal -Expected $true -Actual $r.success
            Assert-Equal -Expected 'key:CtrlU,text,key:Enter' -Actual ($TtyStub.Log -join ',') `
                -Because 'no Ctrl-C on the success path'
        } finally {
            $TtyStub.UploadPath = $null
        }
    }
}

Describe 'Console rung structure' {
    It 'brackets the typing in a finally so no failure path can skip the restore' {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors in $($modPath): $($errs[0].Message)" }
        $fn = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Invoke-RemoteDiagnosticsConsole'
        }, $true))[0]
        Assert-True ($null -ne $fn) 'Invoke-RemoteDiagnosticsConsole must exist'
        $finallyBlocks = @($fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally
        }, $true))
        Assert-True ($finallyBlocks.Count -ge 1) 'the rung must wrap its typing in try/finally'
        $restoreInFinally = @($finallyBlocks | Where-Object {
            $_.Finally.Extent.Text -match 'Reset-GuestTtyPrompt'
        })
        Assert-True ($restoreInFinally.Count -ge 1) `
            'the tty restore must run from a finally, not from a single failure branch'
    }
    It 'never signals the guest from a guard that runs before any typing' {
        # A Ctrl-C into a guest we never touched could interrupt a healthy
        # foreground command. Every Reset-GuestTtyPrompt call site must
        # therefore sit inside a finally, not on an early-return path.
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors in $($modPath): $($errs[0].Message)" }
        $calls = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Reset-GuestTtyPrompt'
        }, $true))
        Assert-Equal -Expected 1 -Actual $calls.Count -Because 'one restore site, in the finally'
        $inFinally = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] -and
            $n.Finally -and $n.Finally.Extent.Text -match 'Reset-GuestTtyPrompt'
        }, $true))
        Assert-True ($inFinally.Count -ge 1) 'the only restore site must be inside a finally block'
    }
}

AfterAll {
    # Cleanup belongs here, not at end of file: file-level code runs during
    # discovery, before any It, so a trailing Remove-Item would delete the
    # folder the tests are about to use.
    Remove-Item -LiteralPath $TtyTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\global:Send-Key  -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\global:Send-Text -ErrorAction SilentlyContinue
}
