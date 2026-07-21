<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42e2607c-3d4e-4f50-8a61-7c8d9e0f1a2b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner inner-loop pester
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
    Pester smoke harness for the inner runner's config-reload seam and the
    cycle helpers in Test.RunnerInnerLoop.psm1 / Test.ConfigSync.psm1.
.DESCRIPTION
    Guards the regression-prone mechanics the inner runner depends on:
      * the reloadable-knob resolution rules (defaults, int coercion, the
        0/absent-falls-back-to-default behavior, the -CycleDelaySeconds fallback);
      * Sync-RunnerCycleConfig's mtime parse-cache, its keep-previous-on-failure
        contract, and the by-reference $State mutation the wrapped cycle body
        will rely on (the scope-collapse risk);
      * the pure config-merge / template-shape / secret-hiding contracts.

    Assertions are throw-based inside It blocks so the file runs under the
    OS-bundled Pester 3.4 (no Install-Module needed) and under Pester 5+.
    Run with:  Invoke-Pester -Path test/modules/Test.RunnerInnerLoop.Tests.ps1
#>

# The $global: scope is the load-bearing channel this suite tests through, not a
# shorthand for $script:. The runner resolves its collaborators (New-VM, Set-StepStatus,
# Send-CycleFailureNotification, the infra-record builders) from the GLOBAL command table,
# because the real cycle imports them -Global; the stubs below must therefore be defined
# there or the module function under test would not see them at all. The counters and
# state bags those stubs write are read back across an InModuleScope boundary, where
# $script: resolves to the MODULE's script scope rather than this file's -- so a global is
# the only scope both sides of that boundary can name. $global:__YurunaCycleFolder is the
# runner's own published global, saved and restored here.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The global scope IS the cross-module contract under test: the runner resolves -Global-imported collaborators and its own __YurunaCycleFolder there, and the stub/assertion pair straddles an InModuleScope boundary that $script: cannot span.')]
param()

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Prelude.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.RunnerInnerLoop.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.ConfigSync.psm1')      -Force -DisableNameChecking
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning "powershell-yaml unavailable; YAML-dependent tests will fail." }

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) { throw "Expected [$Expected] but got [$Actual]. $Because" }
}
function Assert-True {
    param($Condition, [string]$Because = '')
    if (-not $Condition) { throw "Expected condition to be true. $Because" }
}
function New-TempConfigFile {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: writes a throwaway temp config file the calling It block deletes in its finally.')]
    param([string]$Content)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-cfg-" + [guid]::NewGuid().ToString('N') + ".yml")
    [System.IO.File]::WriteAllText($p, $Content, [System.Text.UTF8Encoding]::new($false))
    return $p
}

# --- REGION: fixtures reachable from It blocks -------------------------------------
# Every helper an It block calls has to be defined here, at file scope and above the
# FIRST Describe. Two separate rules force that placement, and each one turns a real
# assertion into a CommandNotFoundException that reads like a passing-but-empty test:
#   * a Describe body is executed during the discovery pass, and everything it declares
#     -- functions included -- is discarded before the first It runs; and
#   * when this file is invoked directly, the run is bootstrapped from the first Describe
#     it encounters, so declarations that sit BELOW that point never make it into the
#     session state the It blocks are bound to.

# --- AST helpers for the control-flow golden below (walk the real .psm1, not a mirror) ---
function Get-AstNearestLoop {
    # The innermost loop that a break/continue targets: the first loop-statement
    # ancestor. A break/continue inside the guest foreach targets the foreach, NOT
    # the enclosing do/while -- that distinction is the whole point of the golden.
    param($Node)
    $loopNames = @('ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst')
    $p = $Node.Parent
    while ($null -ne $p) {
        if ($loopNames -contains $p.GetType().Name) { return $p }
        $p = $p.Parent
    }
    return $null
}
function Get-AstEnclosingBlock {
    param($Node)
    $p = $Node.Parent
    while ($null -ne $p -and $p -isnot [System.Management.Automation.Language.StatementBlockAst]) { $p = $p.Parent }
    return $p
}
function Get-InnerCycleControlFlow {
    # Control-flow shape of the guest-provision path, from parsed source, as a facts
    # bag the It blocks assert against. The per-guest work is a named helper
    # (Invoke-GuestProvisionIteration) dispatched from a thin foreach in
    # Invoke-RunnerInnerCycle. A structural change -- helper renamed or re-inlined, an
    # escape that no longer routes through $IterState.Control, a dropped carry-back --
    # lands here as a loud, deliberate golden failure rather than a silent drift.
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Psm1Path)

    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($Psm1Path, [ref]$null, [ref]$null)
    $cyc = @($fileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-RunnerInnerCycle' }, $true))[0]
    if (-not $cyc) { throw 'Invoke-RunnerInnerCycle not found in the psm1' }
    $helper = @($fileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GuestProvisionIteration' }, $true))[0]
    if (-not $helper) { throw 'Invoke-GuestProvisionIteration helper not found (the guest iteration must be extracted)' }

    $dwFalse = @($cyc.FindAll({ param($n) $n -is [System.Management.Automation.Language.DoWhileStatementAst] -and ($n.Condition.Extent.Text -match '\$false') }, $true))
    if ($dwFalse.Count -ne 1) { throw "expected exactly 1 do{...}while(`$false), found $($dwFalse.Count)" }
    $dw = $dwFalse[0]

    $dispatch = @($cyc.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | Where-Object {
            @($_.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Invoke-GuestProvisionIteration' }, $true)).Count -gt 0
        })
    if ($dispatch.Count -ne 1) { throw "expected exactly 1 guest-dispatch foreach, found $($dispatch.Count)" }
    $disp = $dispatch[0]

    $cycBreaks = @($cyc.FindAll({ param($n) $n -is [System.Management.Automation.Language.BreakStatementAst] }, $true))
    $cycContinues = @($cyc.FindAll({ param($n) $n -is [System.Management.Automation.Language.ContinueStatementAst] }, $true))
    $labeled = @(@($cycBreaks + $cycContinues) | Where-Object { $_.Label })
    $dwBreaks = @($cycBreaks | Where-Object { (Get-AstNearestLoop $_) -eq $dw })
    $dwContinues = @($cycContinues | Where-Object { (Get-AstNearestLoop $_) -eq $dw })
    $dispBreaks = @($cycBreaks | Where-Object { (Get-AstNearestLoop $_) -eq $disp })
    $dispContinues = @($cycContinues | Where-Object { (Get-AstNearestLoop $_) -eq $disp })

    # The extracted iteration must signal via $IterState.Control, never a loop escape.
    $helperBreaks = @($helper.FindAll({ param($n) $n -is [System.Management.Automation.Language.BreakStatementAst] }, $true))
    $helperContinues = @($helper.FindAll({ param($n) $n -is [System.Management.Automation.Language.ContinueStatementAst] }, $true))
    $helperReturns = @($helper.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true))
    $helperAssigns = @($helper.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    $helperControlSets = @($helperAssigns | Where-Object { $_.Left.Extent.Text -eq '$IterState.Control' })

    # Carry-back mirror lives in the helper now: the entry init line + one re-read per Sync.
    $helperSyncs = @($helper.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Sync-RunnerStepConfig' }, $true))
    $helperConfigReads = @($helperAssigns | Where-Object { $_.Left.Extent.Text -eq '$Config' -and $_.Right.Extent.Text -match '\$cfg\.Config' })
    $helperStopReads = @($helperAssigns | Where-Object { $_.Left.Extent.Text -eq '$StopOnFailure' -and $_.Right.Extent.Text -match '\$cfg\.StopOnFailure' })

    $stopIfs = @($helper.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
            $_.Clauses[0].Item1.Extent.Text -match '^\$StopOnFailure$' -and
            @($_.Clauses[0].Item2.FindAll({ param($b) $b -is [System.Management.Automation.Language.ReturnStatementAst] }, $false)).Count -gt 0
        })
    $stopIfsWithCopy = 0
    foreach ($sif in $stopIfs) {
        $blk = Get-AstEnclosingBlock $sif
        if ($blk -and @($blk.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Copy-FailureArtifactsToStatusLog' -and $x.Extent.EndOffset -le $sif.Extent.StartOffset }, $true)).Count -gt 0) { $stopIfsWithCopy++ }
    }

    # The thin dispatcher re-reads $Config from the shared $cfg bag and the four failure
    # fields from the iteration bag after the call (in a finally, so a throw carries back).
    $dispAssigns = @($disp.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    $callerConfigRehydrate = @($dispAssigns | Where-Object { $_.Left.Extent.Text -eq '$Config' -and $_.Right.Extent.Text -match '\$cfg\.Config' })
    $callerFailureRehydrate = @($dispAssigns | Where-Object { ($_.Left.Extent.Text -in '$OverallPassed', '$FailedGuest', '$FailedStep', '$FailureMessage') -and $_.Right.Extent.Text -match '\$guestIterState\.' })

    return @{
        DoWhileBreaks             = $dwBreaks.Count
        DoWhileContinues          = $dwContinues.Count
        LabeledFlow               = $labeled.Count
        DispatchBreaks            = $dispBreaks.Count
        DispatchContinues         = $dispContinues.Count
        HelperLoopBreaks          = $helperBreaks.Count
        HelperLoopContinues       = $helperContinues.Count
        HelperReturns             = $helperReturns.Count
        HelperControlSets         = $helperControlSets.Count
        HelperSyncCount           = $helperSyncs.Count
        HelperConfigReads         = $helperConfigReads.Count
        HelperStopReads           = $helperStopReads.Count
        HelperStopReturns         = $stopIfs.Count
        HelperStopReturnsWithCopy = $stopIfsWithCopy
        CallerConfigRehydrate     = $callerConfigRehydrate.Count
        CallerFailureRehydrate    = $callerFailureRehydrate.Count
    }
}

# Drives a New-VM failure through the real Invoke-GuestProvisionIteration with its
# collaborators stubbed (host-contract commands are unresolved in a unit run, so global
# stubs resolve; the two module-internal collaborators that do real I/O are Mocked).
# Returns the carried-back iteration bag plus the teardown call count.
function Invoke-NewVmFailureIteration {
    param([bool]$StopOnFailure)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("yrn-gpi-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $oldLogDir = $env:YURUNA_LOG_DIR; $env:YURUNA_LOG_DIR = $tmp
    $global:__gpiRm = 0
    $global:__gpiIter = @{ OverallPassed = $true; FailedGuest = $null; FailedStep = $null; FailureMessage = $null; Control = 'proceed' }
    $global:__gpiStop = $StopOnFailure
    # Each stub mirrors the signature of the host-contract command the iteration calls by
    # name; PowerShell binds those named arguments at the call site, so a parameter cannot
    # be dropped just because this stub body has no use for its value.
    function global:New-VM {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub mirrors the host-contract New-VM signature the iteration binds by name; dropping a parameter breaks the call.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
            Justification = '-Confirm is a plain pass-through switch in the real host-contract signature being mirrored; SupportsShouldProcess would add a real confirmation prompt and hang the unattended run.')]
        param($GuestKey, $RepoRoot, $VMName, $Username, $CachingProxyUrl, [switch]$Confirm)
        @{ success = $false; errorMessage = 'boom' }
    }
    function global:Remove-GuestVMQuietly {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub mirrors the teardown signature the iteration binds by name; the test asserts on the call COUNT, not the arguments.')]
        param($VMName, [switch]$SkipStop)
        $global:__gpiRm++
    }
    function global:Get-CycleGuestDataFolder {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub mirrors the host-contract signature the iteration binds by name; it deliberately returns $null regardless of the VM.')]
        param($VMName)
        $null
    }
    function global:Set-GuestVMName {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Status-sink stub: mirrors the signature the iteration binds by name and swallows the call so no status file is written.')]
        param($GuestKey, $VMName)
    }
    function global:Set-GuestStatus {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Status-sink stub: mirrors the signature the iteration binds by name and swallows the call so no status file is written.')]
        param($GuestKey, $Status)
    }
    function global:Set-StepStatus {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Status-sink stub: mirrors the signature the iteration binds by name and swallows the call so no status file is written.')]
        param($GuestKey, $StepName, $Status, $ErrorMessage, [switch]$Skipped)
    }
    function global:Get-GuestProvenance {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub mirrors the host-contract signature the iteration binds by name; it returns a fixed provenance record for any guest.')]
        param($GuestKey)
        @{ Filename = '' }
    }
    try {
        InModuleScope Test.RunnerInnerLoop {
            Mock Copy-FailureArtifactsToStatusLog {}
            Mock Sync-RunnerStepConfig {}
            $script:PoolCycle = $false; $script:CyclePlan = $null
            $cfg = @{ Config = @{}; StopOnFailure = $global:__gpiStop; VmStartTimeout = 1; VmBootDelay = 0; GetImageRefreshHours = 1; CycleDelay = 0 }
            Invoke-GuestProvisionIteration -GuestKey 'g1' -IterState $global:__gpiIter -VMNames @{ g1 = 'vm1' } `
                -RepoRoot 'r' -HostType 'h' -ModulesDir 'm' -LogFile 'l' -SequencesDir 's' -ScreenshotsDir 'sc' `
                -hasScreenshots $false -hasExtensions $false -cachingProxyUrl '' -cfg $cfg -ConfigPath 'c' `
                -FailedGuests ([System.Collections.Generic.HashSet[string]]::new()) -ShutdownState @{ Requested = $false } | Out-Null
        }
        return @{ Iter = $global:__gpiIter; Rm = $global:__gpiRm }
    } finally {
        Remove-Item function:global:New-VM, function:global:Remove-GuestVMQuietly, function:global:Get-CycleGuestDataFolder, function:global:Set-GuestVMName, function:global:Set-GuestStatus, function:global:Set-StepStatus, function:global:Get-GuestProvenance -ErrorAction SilentlyContinue
        Remove-Variable __gpiRm, __gpiIter, __gpiStop -Scope Global -ErrorAction SilentlyContinue
        if ($null -eq $oldLogDir) { Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_LOG_DIR = $oldLogDir }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
# --- END REGION -------------------------------------------------------------------

Describe 'Get-RunnerReloadableConfig' {
    It 'applies defaults when the parsed config is null' {
        $r = Get-RunnerReloadableConfig -Config $null -CycleDelayFallback 30
        Assert-Equal -Expected $false -Actual $r.StopOnFailure -Because 'default StopOnFailure'
        Assert-Equal -Expected 120    -Actual $r.VmStartTimeout -Because 'default VmStartTimeout'
        Assert-Equal -Expected 15     -Actual $r.VmBootDelay -Because 'default VmBootDelay'
        Assert-Equal -Expected 24     -Actual $r.GetImageRefreshHours -Because 'default GetImageRefreshHours'
        Assert-Equal -Expected 30     -Actual $r.CycleDelay -Because 'CycleDelay falls back to -CycleDelayFallback'
    }
    It 'reads operator values and coerces strings to int' {
        $cfg = @{
            testCycle = @{ shouldStopOnFailure = $true; cycleDelaySeconds = '45' }
            vmStart   = @{ startTimeoutSeconds = '200'; bootDelaySeconds = 9 }
            vmImage   = @{ refreshHours = 6 }
        }
        $r = Get-RunnerReloadableConfig -Config $cfg -CycleDelayFallback 30
        Assert-Equal -Expected $true -Actual $r.StopOnFailure -Because 'operator StopOnFailure'
        Assert-Equal -Expected 200   -Actual $r.VmStartTimeout -Because 'operator VmStartTimeout'
        Assert-Equal -Expected 9     -Actual $r.VmBootDelay -Because 'operator VmBootDelay'
        Assert-Equal -Expected 6     -Actual $r.GetImageRefreshHours -Because 'operator GetImageRefreshHours'
        Assert-Equal -Expected 45    -Actual $r.CycleDelay -Because 'config cycleDelaySeconds wins over fallback'
        Assert-True ($r.VmStartTimeout -is [int]) 'VmStartTimeout coerced to int'
    }
    It 'treats a 0/absent value as falling back to the default' {
        $r = Get-RunnerReloadableConfig -Config @{ vmStart = @{ startTimeoutSeconds = 0 } } -CycleDelayFallback 30
        Assert-Equal -Expected 120 -Actual $r.VmStartTimeout -Because '0 is falsy -> default 120'
    }
    It 'defaults guest quarantine ON with a 3-failure / 5-cycle threshold' {
        $r = Get-RunnerReloadableConfig -Config $null -CycleDelayFallback 30
        Assert-Equal -Expected $true -Actual $r.GuestQuarantineEnabled -Because 'quarantine default ON'
        Assert-Equal -Expected 3     -Actual $r.GuestQuarantineFailures -Because 'default failuresToQuarantine'
        Assert-Equal -Expected 5     -Actual $r.GuestQuarantineSkipCycles -Because 'default skipCycles'
    }
    It 'honors an operator-disabled quarantine block and coerces its thresholds' {
        $cfg = @{ testCycle = @{ guestQuarantine = @{ enabled = $false; failuresToQuarantine = '2'; skipCycles = '10' } } }
        $r = Get-RunnerReloadableConfig -Config $cfg -CycleDelayFallback 30
        Assert-Equal -Expected $false -Actual $r.GuestQuarantineEnabled -Because 'operator disabled quarantine'
        Assert-Equal -Expected 2      -Actual $r.GuestQuarantineFailures -Because 'operator failuresToQuarantine (int-coerced)'
        Assert-Equal -Expected 10     -Actual $r.GuestQuarantineSkipCycles -Because 'operator skipCycles (int-coerced)'
    }
    It 'defaults warm-resume ON with a 2-attempt budget' {
        $r = Get-RunnerReloadableConfig -Config $null -CycleDelayFallback 30
        Assert-Equal -Expected $true -Actual $r.WarmResumeEnabled -Because 'warm-resume default ON'
        Assert-Equal -Expected 2     -Actual $r.WarmResumeMaxAttempts -Because 'default maxAttempts'
    }
    It 'honors an operator-disabled warm-resume block and coerces maxAttempts' {
        $cfg = @{ testCycle = @{ warmResume = @{ enabled = $false; maxAttempts = '3' } } }
        $r = Get-RunnerReloadableConfig -Config $cfg -CycleDelayFallback 30
        Assert-Equal -Expected $false -Actual $r.WarmResumeEnabled -Because 'operator disabled warm-resume'
        Assert-Equal -Expected 3      -Actual $r.WarmResumeMaxAttempts -Because 'operator maxAttempts (int-coerced)'
    }
}

Describe 'New-RunnerConfigState' {
    It 'seeds cache slots null and knobs to defaults' {
        $s = New-RunnerConfigState -CmdLineLogLevel 'Debug' -CycleDelayFallback 42
        Assert-Equal -Expected 'Debug' -Actual $s.CmdLineLogLevel -Because 'cmdline level captured'
        Assert-Equal -Expected 42      -Actual $s.CycleDelayFallback -Because 'fallback captured'
        Assert-True ($null -eq $s.CachedConfigMtime) 'mtime cache empty'
        Assert-True ($null -eq $s.CachedConfigValue) 'value cache empty'
        Assert-True ($null -eq $s.Config) 'config empty'
        Assert-Equal -Expected 120 -Actual $s.VmStartTimeout -Because 'knob default seeded'
        Assert-Equal -Expected 42  -Actual $s.CycleDelay -Because 'CycleDelay seeded to fallback'
    }
}

Describe 'Sync-RunnerCycleConfig' {
    It 'resolves knobs from a real file and mutates $State by reference' {
        $yaml = "testCycle:`n  shouldStopOnFailure: true`n  cycleDelaySeconds: 55`nvmStart:`n  startTimeoutSeconds: 300`n  bootDelaySeconds: 20`nvmImage:`n  refreshHours: 12`n"
        $p = New-TempConfigFile -Content $yaml
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $alias = $s   # second reference to prove by-reference mutation (the scope-collapse guard)
            $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p
            Assert-Equal -Expected 'resolved' -Actual $status -Because 'parsed + dict -> resolved'
            Assert-Equal -Expected $true -Actual $s.StopOnFailure -Because 'StopOnFailure mirrored'
            Assert-Equal -Expected 300   -Actual $s.VmStartTimeout -Because 'VmStartTimeout mirrored'
            Assert-Equal -Expected 20    -Actual $s.VmBootDelay -Because 'VmBootDelay mirrored'
            Assert-Equal -Expected 12    -Actual $s.GetImageRefreshHours -Because 'GetImageRefreshHours mirrored'
            Assert-Equal -Expected 55    -Actual $s.CycleDelay -Because 'CycleDelay mirrored'
            Assert-Equal -Expected 300   -Actual $alias.VmStartTimeout -Because 'the other reference sees the same mutation'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
    It 'returns the cached Config object on an unchanged file (no re-parse)' {
        $yaml = "vmStart:`n  startTimeoutSeconds: 150`n"
        $p = New-TempConfigFile -Content $yaml
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $null = Sync-RunnerCycleConfig -State $s -ConfigPath $p
            $first = $s.Config
            $null = Sync-RunnerCycleConfig -State $s -ConfigPath $p   # unchanged mtime -> cache hit
            $second = $s.Config
            Assert-True ([object]::ReferenceEquals($first, $second)) 'unchanged file returns the same cached parse object'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps previously resolved values and returns failed when a later read fails' {
        $yaml = "vmStart:`n  startTimeoutSeconds: 175`n"
        $p = New-TempConfigFile -Content $yaml
        $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
        $null = Sync-RunnerCycleConfig -State $s -ConfigPath $p
        Assert-Equal -Expected 175 -Actual $s.VmStartTimeout -Because 'resolved good value first'
        $prevConfig = $s.Config
        Remove-Item $p -Force -ErrorAction SilentlyContinue   # force a read failure on the next sync
        $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p
        Assert-Equal -Expected 'failed' -Actual $status -Because 'read failure -> failed'
        Assert-Equal -Expected 175 -Actual $s.VmStartTimeout -Because 'knob kept at last-known-good'
        Assert-True ([object]::ReferenceEquals($prevConfig, $s.Config)) 'Config kept (not wiped) on failure'
    }
    It 'returns failed on malformed YAML without throwing' {
        $p = New-TempConfigFile -Content "vmStart: [unterminated"
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p -WarningAction SilentlyContinue
            Assert-Equal -Expected 'failed' -Actual $status -Because 'malformed yaml -> failed'
            Assert-True ($null -eq $s.Config) 'Config stays null when first parse fails'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
    It 'returns nondict when the parsed value is a scalar' {
        $p = New-TempConfigFile -Content "just-a-scalar-string"
        try {
            $s = New-RunnerConfigState -CmdLineLogLevel $null -CycleDelayFallback 30
            $status = Sync-RunnerCycleConfig -State $s -ConfigPath $p
            Assert-Equal -Expected 'nondict' -Actual $status -Because 'scalar config -> nondict'
        } finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Convert-LocalRepoUrlToPath' {
    It 'maps file:// URLs and bare drive paths, rejects remote/empty' {
        Assert-Equal -Expected 'c:/git/yuruna-project' -Actual (Convert-LocalRepoUrlToPath -Url 'file:///c:/git/yuruna-project') -Because 'file:// stripped'
        Assert-Equal -Expected 'c:\git\yuruna' -Actual (Convert-LocalRepoUrlToPath -Url 'c:\git\yuruna') -Because 'drive path passes through'
        Assert-True ($null -eq (Convert-LocalRepoUrlToPath -Url 'https://github.com/x/y')) 'remote url -> null'
        Assert-True ($null -eq (Convert-LocalRepoUrlToPath -Url '')) 'empty -> null'
    }
}

Describe 'Assert-CachingProxyStillReachable' {
    It 'no-ops without warning on an empty or non-http URL' {
        $out = @()
        $out += Assert-CachingProxyStillReachable -ProxyUrl '' -StepName 'New-VM' -GuestKey 'g' 3>&1
        $out += Assert-CachingProxyStillReachable -ProxyUrl 'not-a-url' -StepName 'New-VM' -GuestKey 'g' 3>&1
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal -Expected 0 -Actual $warnings.Count -Because 'no warnings on the no-op paths'
    }
    It 'warns when the proxy URL does not answer (1s probe to TEST-NET-1)' {
        $out = Assert-CachingProxyStillReachable -ProxyUrl 'http://192.0.2.1:3128' -StepName 'New-VM' -GuestKey 'g' 3>&1
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-True ($warnings.Count -ge 1) 'unreachable proxy surfaces a warning'
    }
}

Describe 'Write-InnerLog' {
    It 'appends an [inner]-tagged line to outer.log under YURUNA_RUNTIME_DIR' {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-il-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d
        $old = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $d
        try {
            Write-InnerLog 'hello-innerlog-test'
            $log = Join-Path $d 'outer.log'
            Assert-True (Test-Path $log) 'outer.log created'
            Assert-True ([bool]((Get-Content $log -Raw) -match '\[inner\] hello-innerlog-test')) 'line is [inner]-tagged and present'
        } finally {
            $env:YURUNA_RUNTIME_DIR = $old
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Inner-cycle child-script import discipline' {
    # Regression guard for the eviction class: scripts the inner cycle &-invokes
    # from inside the Test.RunnerInnerLoop module must import the host contract /
    # driver with -Global, or a -Force import pulls it out of the global table
    # and a later contract call from a foreign module (Invoke-Sequence) fails.
    # AST-based so here-string content (the detached status-service child) is not
    # mis-scanned -- only real Import-Module calls are checked.
    It 'host-contract/driver -Force imports in the &-invoked cycle scripts use -Global' {
        $testRoot = Split-Path -Parent $here
        foreach ($name in @('Remove-TestVMFiles.ps1', 'Start-StatusService.ps1')) {
            $path = Join-Path $testRoot $name
            Assert-True (Test-Path $path) "cycle script exists: $name"
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $imports = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true)
            foreach ($imp in $imports) {
                $text = $imp.Extent.Text
                if (($text -match 'Test\.HostContract|Yuruna\.Host') -and ($text -match '-Force')) {
                    Assert-True ($text -match '-Global') "$name : host-contract/driver -Force import must use -Global -> $text"
                }
            }
        }
    }
}

Describe 'gitCommits array-shape (double-wrap regression guard)' {
    # New-CycleGitCommitList returns its list via a unary comma (`return ,$list`)
    # so a one-element list does not unroll -- the helper already hands back an
    # array. The status doc's gitCommits must be a FLAT array of {sha,repoUrl}
    # ([{...},{...}]); a nested array ([[{...}]]) is rejected by the status schema
    # reader and by the pool aggregator (json: cannot unmarshal array into the
    # gitCommits struct), which then cannot parse the whole status.json and drops
    # the host from the pool view. Guards the array-double-wrap trap class.
    It 'New-CycleGitCommitList assigned directly yields a flat array of {sha,repoUrl}' {
        InModuleScope Test.RunnerInnerLoop {
            $list = New-CycleGitCommitList -GitCommit 'aaaa111' -FrameworkUrl 'https://f/x' `
                -ProjectGitCommit 'bbbb222' -ProjectUrl 'https://p/y'
            if (@($list).Count -ne 2) { throw "expected 2 commits, got $(@($list).Count)" }
            if ($null -eq $list[0].sha) { throw 'element 0 is not a {sha,...} object (nested/double-wrapped)' }
            if ($list[0].sha -ne 'aaaa111') { throw "framework sha wrong: $($list[0].sha)" }
        }
    }
    It 'one-element list (framework only) stays an array, not a bare dict' {
        InModuleScope Test.RunnerInnerLoop {
            $list = New-CycleGitCommitList -GitCommit 'aaaa111' -FrameworkUrl 'https://f/x' `
                -ProjectGitCommit $null -ProjectUrl $null
            if (@($list).Count -ne 1) { throw "expected 1 commit, got $(@($list).Count)" }
            if ($null -eq $list[0].sha) { throw 'element 0 is not a {sha,...} object' }
        }
    }
    It 'the call site assigns the helper directly, never wrapped in @() (the trap)' {
        $src = Get-Content -LiteralPath (Join-Path $here 'Test.RunnerInnerLoop.psm1') -Raw
        Assert-True ($src -match '\$GitCommitsList\s*=\s*New-CycleGitCommitList') `
            'the call site must assign New-CycleGitCommitList directly'
        Assert-True (-not ($src -match '=\s*@\(\s*New-CycleGitCommitList')) `
            'New-CycleGitCommitList must NOT be wrapped in @() -- that double-wraps gitCommits to [[...]]'
    }
    It 'the call site passes the web-resolved project URL, not the raw configured value' {
        # repositories.projectUrl may be a local clone path or an ssh remote --
        # valid clone sources a browser cannot open. The status page and pool
        # dashboard only link http(s) repoUrl values, so the call site must hand
        # New-CycleGitCommitList the Resolve-GitRepositoryWebUrl output (which
        # falls back to the raw value when nothing resolves) or the project
        # commit renders unlinked on every status surface.
        $src = Get-Content -LiteralPath (Join-Path $here 'Test.RunnerInnerLoop.psm1') -Raw
        Assert-True ($src -match 'Resolve-GitRepositoryWebUrl\s+-Url\s+\$projUrl') `
            'the runner must resolve repositories.projectUrl to a web URL for the commit link'
        Assert-True ($src -match '-ProjectUrl\s+\$projLinkUrl') `
            'New-CycleGitCommitList must receive the resolved $projLinkUrl'
        Assert-True (-not ($src -match '-ProjectGitCommit\s+\$ProjectGitCommit\s+-ProjectUrl\s+\$projUrl\b')) `
            'the raw $projUrl must not reach New-CycleGitCommitList directly'
    }
}

Describe 'Get-GitHubConnectivityDiagnostic' {
    # The DNS/TCP probe lifted out of the git-pull-failure path. It does real
    # network I/O, so the guard is on the STABLE contract shape (three typed
    # keys) -- true both online (DnsOk/TcpOk true, empty Message) and offline
    # (false + a message), so the assertion is network-independent.
    It 'returns a hashtable with typed DnsOk/TcpOk/Message' {
        InModuleScope Test.RunnerInnerLoop {
            $r = Get-GitHubConnectivityDiagnostic
            if ($r -isnot [hashtable]) { throw "expected hashtable, got $($r.GetType().Name)" }
            foreach ($k in 'DnsOk', 'TcpOk', 'Message') {
                if (-not $r.ContainsKey($k)) { throw "missing key: $k" }
            }
            if ($r.DnsOk -isnot [bool]) { throw 'DnsOk not [bool]' }
            if ($r.TcpOk -isnot [bool]) { throw 'TcpOk not [bool]' }
            if ($null -eq $r.Message) { throw 'Message is null' }
            # Message is empty only when both probes pass; non-empty otherwise.
            if (($r.DnsOk -and $r.TcpOk) -and $r.Message -ne '') { throw "Message should be empty on success: '$($r.Message)'" }
            if ((-not ($r.DnsOk -and $r.TcpOk)) -and $r.Message -eq '') { throw 'Message should describe the failing probe' }
        }
    }
}

Describe 'Write-CycleInfraFailure' {
    # Write-CycleInfraFailure is a module function; its builders
    # (New-InfraFailureRecord/Write-YurunaStateFile/Send-CycleEventSafely/
    # Set-LastFailureSummary) are imported -Global by the runner and must resolve
    # from the module function's scope (module -> global). The closure no-ops when
    # a builder is unresolvable, so a resolution break would SILENTLY stop every
    # infra record. This test provides the builders in the GLOBAL scope (mirroring
    # the -Global imports) and asserts the record IS written, turning that silent
    # failure into a loud one. The .psm1 does not import the real builders, so the
    # stubs are the only resolvable implementations.
    It 'resolves the -Global builders from module scope and writes last_failure.json' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("yrn-infra-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $oldLogDir = $env:YURUNA_LOG_DIR
        $env:YURUNA_LOG_DIR = $tmp
        $global:__yrnInfraEventSent = $false
        # Each stub mirrors the signature of the -Global builder Write-CycleInfraFailure
        # binds by name; a parameter cannot be dropped just because this body ignores it.
        function global:New-InfraFailureRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub mirrors the -Global builder signature Write-CycleInfraFailure binds by name; the test asserts only on the fields it does thread through.')]
            param($Stage, $FailureClass, $Severity, $GuestKey, $VMName, $HostType, $ErrorMessage)
            @{ File  = [ordered]@{ stage = $Stage; failureClass = $FailureClass; hostType = $HostType; errorMessage = $ErrorMessage }
               Event = [ordered]@{ stage = $Stage } }
        }
        function global:Write-YurunaStateFile {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub mirrors the -Global writer signature bound by name; -Confirm is part of that contract even though this stub writes unconditionally.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
                Justification = '-Confirm is a plain pass-through switch in the real builder signature being mirrored; SupportsShouldProcess would add a real confirmation prompt and hang the unattended run.')]
            param($Path, $Content, [switch]$Confirm)
            [System.IO.File]::WriteAllText($Path, $Content); $Path
        }
        function global:Send-CycleEventSafely {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub mirrors the -Global event-sink signature bound by name; the test asserts the call HAPPENED, not the record contents.')]
            param($EventRecord)
            $global:__yrnInfraEventSent = $true
        }
        function global:Set-LastFailureSummary {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub mirrors the -Global summary-sink signature bound by name; it deliberately swallows the call so no summary file is written.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
                Justification = '-Confirm is a plain pass-through switch in the real builder signature being mirrored; SupportsShouldProcess would add a real confirmation prompt and hang the unattended run.')]
            param($FailureClass, $Severity, $SequenceName, $GuestKey, $StepName, $ErrorMessage, $VmName, [switch]$Confirm)
        }
        try {
            InModuleScope Test.RunnerInnerLoop {
                Write-CycleInfraFailure -Stage 'TestStage' -FailureClass 'test_class' -Severity 'hard' `
                    -GuestKey '(gk)' -VMName '(vm)' -ErrorMessage 'boom' -HostType 'host.test'
            }
            $failFile = Join-Path $tmp 'last_failure.json'
            if (-not (Test-Path -LiteralPath $failFile)) {
                throw 'last_failure.json was NOT written: Write-CycleInfraFailure could not resolve the -Global builders (silent-failure regression).'
            }
            $doc = Get-Content -LiteralPath $failFile -Raw | ConvertFrom-Json
            if ($doc.failureClass -ne 'test_class') { throw "failureClass not recorded: '$($doc.failureClass)'" }
            if ($doc.hostType -ne 'host.test') { throw "HostType not threaded into the record: '$($doc.hostType)'" }
            if (-not $global:__yrnInfraEventSent) { throw 'Send-CycleEventSafely was not invoked.' }
        } finally {
            Remove-Item function:global:New-InfraFailureRecord, function:global:Write-YurunaStateFile, function:global:Send-CycleEventSafely, function:global:Set-LastFailureSummary -ErrorAction SilentlyContinue
            Remove-Variable -Name __yrnInfraEventSent -Scope Global -ErrorAction SilentlyContinue
            if ($null -eq $oldLogDir) { Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_LOG_DIR = $oldLogDir }
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'is a no-op (never throws) when no record dir is resolvable' {
        $oldLogDir = $env:YURUNA_LOG_DIR
        Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue
        $oldCycleFolder = $global:__YurunaCycleFolder
        $global:__YurunaCycleFolder = $null
        try {
            InModuleScope Test.RunnerInnerLoop {
                Write-CycleInfraFailure -Stage 'S' -FailureClass 'C' -HostType 'H'
            }
            # reaching here == did not throw
        } finally {
            if ($null -ne $oldLogDir) { $env:YURUNA_LOG_DIR = $oldLogDir }
            $global:__YurunaCycleFolder = $oldCycleFolder
        }
    }
    It 'every call site threads -HostType $HostType and the closure is gone' {
        $src = Get-Content -LiteralPath (Join-Path $here 'Test.RunnerInnerLoop.psm1') -Raw
        Assert-True (-not ($src -match '\$writeInfraFailure')) 'the $writeInfraFailure closure must be fully removed'
        $calls = [regex]::Matches($src, 'Write-CycleInfraFailure\s+-Stage[^\r\n]*')
        Assert-True ($calls.Count -ge 10) "expected >=10 Write-CycleInfraFailure call sites, found $($calls.Count)"
        foreach ($c in $calls) {
            Assert-True ($c.Value -match '-HostType \$HostType') "call site missing -HostType `$HostType: $($c.Value)"
        }
    }
}

Describe 'Invoke-RunnerBootstrapFailureGate (shared bootstrap-failure gating)' {
    # The GitPull + ProjectClone failure paths shared this consecutive-failure
    # notification gating verbatim. It is the operator-facing alert path, so these
    # tests stub Send-CycleFailureNotification (no real email) and assert the counter
    # math + the armed/threshold/disarm rule across every branch -- a regression in
    # WHEN alerts fire would fail loudly here. The helper mutates the passed gating
    # bag in place; | Out-Null discards its console lines (the mutation is the contract).
    It 'sends one notification when armed and the count reaches the threshold, then disarms' {
        $global:__gateNotifyCount = 0; $global:__gateNotifyArgs = $null
        # Mirrors the operator-alert signature the gate binds by name; the stub records the
        # subset the assertions read, but every parameter must stay for the call to bind.
        function global:Send-CycleFailureNotification {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub mirrors the Send-CycleFailureNotification signature the gate binds by name; only the recorded subset is asserted, but dropping a parameter breaks the call.')]
            param($HostType, $SubjectSuffix, $GuestKey, $StepName, $ErrorMessage, $CycleId, $GitCommit, $DefaultFailureClass, $DefaultSeverity)
            $global:__gateNotifyCount++
            $global:__gateNotifyArgs = @{ SubjectSuffix = $SubjectSuffix; FailureClass = $DefaultFailureClass; ErrorMessage = $ErrorMessage; GitCommit = $GitCommit }
        }
        try {
            InModuleScope Test.RunnerInnerLoop {
                $bag = @{ ConsecutiveFailures = 2; ConsecutiveSuccesses = 5; AlertArmed = $true; FailuresBeforeAlert = 3; SuccessesBeforeRearm = 2 }
                Invoke-RunnerBootstrapFailureGate -GatingState $bag -Stage 'GitPull' -ErrorMessage 'boom' -GitCommit 'abc123' -FailureClass 'network_timeout' -HostType 'host.test' | Out-Null
                if ($bag.ConsecutiveFailures -ne 3) { throw "ConsecutiveFailures not bumped: $($bag.ConsecutiveFailures)" }
                if ($bag.ConsecutiveSuccesses -ne 0) { throw "ConsecutiveSuccesses not reset: $($bag.ConsecutiveSuccesses)" }
                if ($bag.AlertArmed -ne $false) { throw 'AlertArmed must disarm after sending' }
            }
            if ($global:__gateNotifyCount -ne 1) { throw "expected 1 notification, got $($global:__gateNotifyCount)" }
            if ($global:__gateNotifyArgs.SubjectSuffix -ne 'GitPull') { throw "wrong SubjectSuffix: $($global:__gateNotifyArgs.SubjectSuffix)" }
            if ($global:__gateNotifyArgs.FailureClass -ne 'network_timeout') { throw "wrong FailureClass: $($global:__gateNotifyArgs.FailureClass)" }
        } finally {
            Remove-Item function:global:Send-CycleFailureNotification -ErrorAction SilentlyContinue
            Remove-Variable __gateNotifyCount, __gateNotifyArgs -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'suppresses the notification below the threshold but still bumps counters' {
        $global:__gateNotifyCount = 0
        function global:Send-CycleFailureNotification {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub mirrors the Send-CycleFailureNotification signature the gate binds by name; this case asserts only the call COUNT, but dropping a parameter breaks the call.')]
            param($HostType, $SubjectSuffix, $GuestKey, $StepName, $ErrorMessage, $CycleId, $GitCommit, $DefaultFailureClass, $DefaultSeverity)
            $global:__gateNotifyCount++
        }
        try {
            InModuleScope Test.RunnerInnerLoop {
                $bag = @{ ConsecutiveFailures = 0; ConsecutiveSuccesses = 3; AlertArmed = $true; FailuresBeforeAlert = 3; SuccessesBeforeRearm = 2 }
                Invoke-RunnerBootstrapFailureGate -GatingState $bag -Stage 'ProjectClone' -ErrorMessage 'x' -GitCommit $null -FailureClass 'bootstrap_sync' -HostType 'h' | Out-Null
                if ($bag.ConsecutiveFailures -ne 1) { throw "ConsecutiveFailures: $($bag.ConsecutiveFailures)" }
                if ($bag.ConsecutiveSuccesses -ne 0) { throw "ConsecutiveSuccesses: $($bag.ConsecutiveSuccesses)" }
                if ($bag.AlertArmed -ne $true) { throw 'AlertArmed must stay armed below threshold' }
            }
            if ($global:__gateNotifyCount -ne 0) { throw "expected 0 notifications below threshold, got $($global:__gateNotifyCount)" }
        } finally {
            Remove-Item function:global:Send-CycleFailureNotification -ErrorAction SilentlyContinue
            Remove-Variable __gateNotifyCount -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'does not notify when disarmed even at/above threshold' {
        $global:__gateNotifyCount = 0
        function global:Send-CycleFailureNotification {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub mirrors the Send-CycleFailureNotification signature the gate binds by name; this case asserts only the call COUNT, but dropping a parameter breaks the call.')]
            param($HostType, $SubjectSuffix, $GuestKey, $StepName, $ErrorMessage, $CycleId, $GitCommit, $DefaultFailureClass, $DefaultSeverity)
            $global:__gateNotifyCount++
        }
        try {
            InModuleScope Test.RunnerInnerLoop {
                $bag = @{ ConsecutiveFailures = 9; ConsecutiveSuccesses = 0; AlertArmed = $false; FailuresBeforeAlert = 3; SuccessesBeforeRearm = 2 }
                Invoke-RunnerBootstrapFailureGate -GatingState $bag -Stage 'GitPull' -ErrorMessage 'y' -GitCommit 'c' -FailureClass 'network_timeout' -HostType 'h' | Out-Null
                if ($bag.ConsecutiveFailures -ne 10) { throw "ConsecutiveFailures: $($bag.ConsecutiveFailures)" }
                if ($bag.AlertArmed -ne $false) { throw 'AlertArmed must stay disarmed' }
            }
            if ($global:__gateNotifyCount -ne 0) { throw "expected 0 notifications when disarmed, got $($global:__gateNotifyCount)" }
        } finally {
            Remove-Item function:global:Send-CycleFailureNotification -ErrorAction SilentlyContinue
            Remove-Variable __gateNotifyCount -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'both bootstrap sites use the shared helper; the inline gating blocks are gone' {
        $src = Get-Content -LiteralPath (Join-Path $here 'Test.RunnerInnerLoop.psm1') -Raw
        $callCount = ([regex]::Matches($src, 'Invoke-RunnerBootstrapFailureGate\s+-GatingState')).Count
        Assert-True ($callCount -eq 2) "expected 2 Invoke-RunnerBootstrapFailureGate call sites, found $callCount"
        Assert-True (-not ($src -match "-SubjectSuffix\s+'GitPull'")) 'inline GitPull notification block must be gone (helper uses -SubjectSuffix $Stage)'
        Assert-True (-not ($src -match "-SubjectSuffix\s+'ProjectClone'")) 'inline ProjectClone notification block must be gone'
    }
}

Describe 'Inner-cycle control-flow shape (guest dispatch + single-pass invariant)' {
    # The cycle body runs once via do{...}while($false); the per-guest work is a named
    # helper (Invoke-GuestProvisionIteration) dispatched from a thin foreach. These
    # counts are a deliberate golden -- bump them CONSCIOUSLY when adding/removing an
    # early exit or a step-failure arm. The helper signals the caller through
    # $IterState.Control instead of a break/continue that would (wrongly) return from
    # the whole cycle; these assertions pin that discipline.
    It 'runs the cycle body once via do{...}while($false): 12 unlabeled breaks, 0 continues' {
        $f = Get-InnerCycleControlFlow -Psm1Path (Join-Path $here 'Test.RunnerInnerLoop.psm1')
        Assert-True ($f.DoWhileBreaks -eq 12) "do/while must have 12 break arms, found $($f.DoWhileBreaks)"
        Assert-True ($f.DoWhileContinues -eq 0) "do/while must have 0 continue arms (a continue would re-run the single-pass body), found $($f.DoWhileContinues)"
        Assert-True ($f.LabeledFlow -eq 0) "inner cycle must have 0 labeled break/continue, found $($f.LabeledFlow)"
    }
    It 'guest work dispatches to Invoke-GuestProvisionIteration via a 1-break + 2-continue foreach' {
        $f = Get-InnerCycleControlFlow -Psm1Path (Join-Path $here 'Test.RunnerInnerLoop.psm1')
        Assert-True ($f.DispatchBreaks -eq 1) "dispatch foreach must have exactly 1 break, found $($f.DispatchBreaks)"
        # Two continues: the quarantine circuit-breaker skip-gate at the top of the
        # foreach, and the $IterState.Control -eq 'continue' relay after the iteration.
        Assert-True ($f.DispatchContinues -eq 2) "dispatch foreach must have exactly 2 continue, found $($f.DispatchContinues)"
    }
    It 'the extracted iteration signals via $IterState.Control, never a loop escape' {
        $f = Get-InnerCycleControlFlow -Psm1Path (Join-Path $here 'Test.RunnerInnerLoop.psm1')
        Assert-True ($f.HelperLoopBreaks -eq 0) "iteration must contain 0 break statements (escapes route through `$IterState.Control), found $($f.HelperLoopBreaks)"
        Assert-True ($f.HelperLoopContinues -eq 0) "iteration must contain 0 continue statements, found $($f.HelperLoopContinues)"
        Assert-True ($f.HelperReturns -eq 15) "iteration must have 15 signalled returns (1 shutdown + 6 stop + 1 skip + 6 teardown + 1 cleanup-hazard), found $($f.HelperReturns)"
        Assert-True ($f.HelperControlSets -eq 16) "iteration must set `$IterState.Control 16 times (1 init + 8 break + 7 continue), found $($f.HelperControlSets)"
    }
}

Describe 'Inner-cycle guest-iteration failure-path invariants (carry-back + artifact copy)' {
    # Properties the extraction must preserve -- each invisible to a byte-diff and to a
    # green pool cycle (which never fails a step):
    #  (1) config carry-back: the iteration re-reads $Config/$StopOnFailure after every
    #      per-step Sync, and the caller re-reads the mirrors from the shared $cfg bag
    #      after the call (in a finally, covering a mid-iteration throw) plus the four
    #      failure fields from the iteration bag -- because Complete-CycleRun and the
    #      outer catch read the caller-local $Config; dropping either re-read silently
    #      trims run history with a stale display count.
    #  (2) failure artifacts are copied BEFORE the shouldStopOnFailure return, so the
    #      debug folder exists on both the stop and the continue paths.
    It 'the iteration re-reads $StopOnFailure after every per-step Sync (fresh stop-guard)' {
        $f = Get-InnerCycleControlFlow -Psm1Path (Join-Path $here 'Test.RunnerInnerLoop.psm1')
        Assert-True ($f.HelperSyncCount -ge 6) "expected >=6 per-step Sync-RunnerStepConfig in the iteration, found $($f.HelperSyncCount)"
        Assert-True ($f.HelperStopReads -eq ($f.HelperSyncCount + 1)) "iteration must re-read `$StopOnFailure once per Sync plus the entry init (Sync=$($f.HelperSyncCount), reads=$($f.HelperStopReads))"
        Assert-True ($f.HelperConfigReads -eq 0) "iteration must NOT keep a `$Config mirror -- `$Config carries back to the caller via the shared `$cfg (found $($f.HelperConfigReads))"
    }
    It 'cycle state carries back to caller scope after the iteration (pass + throw paths)' {
        $f = Get-InnerCycleControlFlow -Psm1Path (Join-Path $here 'Test.RunnerInnerLoop.psm1')
        Assert-True ($f.CallerConfigRehydrate -ge 1) "dispatcher must re-read `$Config from `$cfg after the iteration, found $($f.CallerConfigRehydrate)"
        Assert-True ($f.CallerFailureRehydrate -eq 4) "dispatcher must carry back the 4 failure fields from the iteration bag, found $($f.CallerFailureRehydrate)"
    }
    It 'failure artifacts are copied before every shouldStopOnFailure return (both paths)' {
        $f = Get-InnerCycleControlFlow -Psm1Path (Join-Path $here 'Test.RunnerInnerLoop.psm1')
        Assert-True ($f.HelperStopReturns -eq 6) "expected 6 if(`$StopOnFailure){...return} guards, found $($f.HelperStopReturns)"
        Assert-True ($f.HelperStopReturnsWithCopy -eq $f.HelperStopReturns) "each stop-guard must be preceded by Copy-FailureArtifactsToStatusLog ($($f.HelperStopReturnsWithCopy)/$($f.HelperStopReturns))"
    }
}

Describe 'Invoke-GuestProvisionIteration failure dispatch (runtime -- the paths a green cycle never hits)' {
    # A green pool cycle never fails a step, so the break-vs-continue dispatch on a
    # step failure runs ONLY here. This drives a New-VM failure through the real helper
    # with its collaborators stubbed (host-contract commands are unresolved in a unit
    # run, so global stubs resolve; the two module-internal collaborators that do real
    # I/O are Mocked). It asserts the control signal, the carried-back failure fields,
    # and the teardown asymmetry: shouldStopOnFailure=true leaves the VM for
    # investigation (pre-cleanup only), false tears it down before the next guest.
    # The driver itself is Invoke-NewVmFailureIteration, defined at file scope above.
    It 'New-VM failure + shouldStopOnFailure=true signals break, carries the failure back, leaves the VM' {
        $o = Invoke-NewVmFailureIteration -StopOnFailure $true
        Assert-True ($o.Iter.Control -eq 'break') "expected Control=break, got $($o.Iter.Control)"
        Assert-True ($o.Iter.OverallPassed -eq $false) 'OverallPassed must carry back false'
        Assert-True ($o.Iter.FailedStep -eq 'New-VM') "FailedStep must be New-VM, got $($o.Iter.FailedStep)"
        Assert-True ($o.Iter.FailedGuest -eq 'g1') "FailedGuest must be g1, got $($o.Iter.FailedGuest)"
        Assert-True ($o.Rm -eq 1) "shouldStopOnFailure=true must NOT tear down (pre-cleanup only); Remove-GuestVMQuietly calls=$($o.Rm)"
    }
    It 'New-VM failure + shouldStopOnFailure=false signals continue and tears the VM down' {
        $o = Invoke-NewVmFailureIteration -StopOnFailure $false
        Assert-True ($o.Iter.Control -eq 'continue') "expected Control=continue, got $($o.Iter.Control)"
        Assert-True ($o.Iter.OverallPassed -eq $false) 'OverallPassed must carry back false'
        Assert-True ($o.Iter.FailedStep -eq 'New-VM') "FailedStep must be New-VM, got $($o.Iter.FailedStep)"
        Assert-True ($o.Rm -eq 2) "shouldStopOnFailure=false must tear down (pre-cleanup + post-fail); Remove-GuestVMQuietly calls=$($o.Rm)"
    }
}
