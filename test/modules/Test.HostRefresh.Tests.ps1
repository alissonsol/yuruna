<#PSScriptInfo
.VERSION 2026.09.27
.GUID 4253a1e0-9103-4f16-8461-710adf91da65
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh rung declaration pester
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
    Test.HostRefresh's pure and near-pure surface: the ladder declaration and
    its executor honesty, ceilings, the protocol file, the capability summary,
    the budget, the verdict table and exit codes, wire codes, relaunch and
    worker argument vectors, the command closure and module set, context and
    identity resolution, the refresh-safe listener start, and source guards
    over the refresh files. No driver is imported; nothing here touches the
    operator's private state.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module Test.HostRefresh, Test.HostRefreshIntent, Yuruna.Host, default | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRefreshIntent.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRefresh.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostDetection.psm1') -Global -DisableNameChecking
    $script:ModulePath = Join-Path $here 'Test.HostRefresh.psm1'
    $script:IntentPath = Join-Path $here 'Test.HostRefreshIntent.psm1'
    $script:EntryPath = Join-Path $script:RepoRoot 'test/lab/Invoke-HostRefresh.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:AllHostTypes = @('host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v')
    $script:ExpectedNames = @('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')
    $script:Created = [System.Collections.Generic.List[string]]::new()
    # One temp directory per run (TMPDIR decides where), removed in AfterAll.
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'yuruna-host-refresh'
    # macOS exposes its temp directory through /var -> /private/var. The
    # context resolver returns canonical paths, including the fixture root.
    $script:ScratchBase = (Resolve-YurunaCanonicalPath -Path $script:ScratchBase).Path
    $script:Created.Add($script:ScratchBase)

    function New-ScratchDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch directory under the private test area.')]
        param([string]$Prefix = 'hr')
        $dir = Join-Path $script:ScratchBase ($Prefix + '-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $script:Created.Add($dir)
        $dir
    }

    function Set-IntentHome {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: points the journal module at a scratch home.')]
        param([string]$Path)
        & (Get-Module Test.HostRefreshIntent) { param($h) $script:HostRefreshHomePath = $h } $Path
    }

    function Get-ExportedFunctionName {
        param([Parameter(Mandatory)][string]$Path)
        $ast = Get-YurunaTestFileAst -Path $Path
        $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $exported = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember'
                }, $true) | ForEach-Object { $_.Extent.Text })
        $exportText = $exported -join ' '
        @($defined | Where-Object { $exportText -match ('(?<![A-Za-z0-9-])' + [regex]::Escape($_) + '(?![A-Za-z0-9-])') })
    }

    function Get-TestBudget {
        param([long]$Now = 5000000000000)
        $tick = $Now
        New-HostRefreshBudget -ClockTicks { $tick }.GetNewClosure()
    }
}

AfterAll {
    foreach ($dir in $script:Created) { Remove-YurunaTestTempDir $dir }
}

Describe 'Get-VirtualizationRepairRung: shape and completeness' {
    It 'returns all eight rungs, in order, for every supported host type' {
        foreach ($hostType in $script:AllHostTypes) {
            $rungs = @(Get-VirtualizationRepairRung -HostType $hostType)
            Assert-Equal 8 $rungs.Count "$hostType declares every rung, unavailable ones included"
            Assert-Equal ($script:ExpectedNames -join ',') (@($rungs.Name) -join ',')
            Assert-Equal '0,1,2,3,4,5,6,7' (@($rungs.Order) -join ',')
        }
    }

    It 'never unrolls to a scalar for a single-element filter' {
        $probeOnly = @(Get-VirtualizationRepairRung -HostType 'host.macos.utm' | Where-Object { $_.Name -eq 'probe' })
        Assert-Equal 1 $probeOnly.Count
        Assert-Equal 'probe' $probeOnly[0].Name
    }

    It 'refuses an unrecognized host type rather than silently returning nothing' {
        Assert-Throw { Get-VirtualizationRepairRung -HostType 'host.not-a-real-platform' }
    }

    It 'carries every field with its type, and a code and rendered reason exactly when unavailable' {
        $known = @('runner-restart-unqualified', 'gui-launch-unqualified', 'vmms-start-unqualified', 'utm-restart-unqualified', 'daemon-layout-unqualified',
            'provider-recipe-missing', 'broker-recipe-missing', 'modular-daemon-recipe-missing', 'settings-recipe-unsafe', 'package-recovery-unqualified',
            'unsupported-on-platform', 'no-reboot-supervision', 'not-implemented', 'lock-unqualified')
        foreach ($hostType in $script:AllHostTypes) {
            foreach ($rung in @(Get-VirtualizationRepairRung -HostType $hostType)) {
                Assert-True ($rung.Name -is [string] -and $rung.Order -is [int] -and $rung.Destructive -is [bool])
                Assert-True ($rung.RequiresElevation -is [bool] -and $rung.RequiresSession -is [bool] -and $rung.EstimatedSeconds -is [int] -and $rung.Available -is [bool])
                if ($rung.Available) {
                    Assert-Null $rung.UnavailableCode "$hostType/$($rung.Name)"
                    Assert-Null $rung.UnavailableReason "$hostType/$($rung.Name)"
                } else {
                    Assert-True ($rung.UnavailableCode -in $known) "$hostType/$($rung.Name) code $($rung.UnavailableCode)"
                    Assert-True ([bool]$rung.UnavailableReason) "$hostType/$($rung.Name) must say why"
                }
            }
        }
    }

    It 'has a catalog message for every unavailable code and every operator action' {
        $catalog = (Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'globalization/catalogs/en-US/runner.json') | ConvertFrom-Json -AsHashtable)['messages']
        $reasonKeys = & (Get-Module Test.HostRefresh) { $script:HostRefreshRungReasonKey }
        $actionKeys = & (Get-Module Test.HostRefresh) { $script:HostRefreshActionKey }
        foreach ($key in @($reasonKeys.Values) + @($actionKeys.Values)) { Assert-True $catalog.ContainsKey($key) "missing catalog key $key" }
        Assert-Equal 14 $reasonKeys.Count
        Assert-Equal 7 $actionKeys.Count
    }
}

Describe 'Get-VirtualizationRepairRung: the declaration and its executor honesty' {
    It 'declares the table this release ships, with every qualification granted' {
        Mock -ModuleName Test.HostRefresh Get-YurunaSingleFlightLockQualification { [pscustomobject]@{ PlatformQualified = $true } }
        Mock -ModuleName Test.HostRefresh Get-YurunaRunnerProtocolCapability { [pscustomobject]@{ Available = $true } }
        $expected = @{
            'host.macos.utm'       = 'available,available,gui-launch-unqualified,utm-restart-unqualified,broker-recipe-missing,settings-recipe-unsafe,package-recovery-unqualified,no-reboot-supervision'
            'host.ubuntu.kvm'      = 'available,available,available,daemon-layout-unqualified,modular-daemon-recipe-missing,settings-recipe-unsafe,unsupported-on-platform,no-reboot-supervision'
            'host.windows.hyper-v' = 'available,available,available,provider-recipe-missing,unsupported-on-platform,settings-recipe-unsafe,unsupported-on-platform,no-reboot-supervision'
        }
        foreach ($hostType in $script:AllHostTypes) {
            $codes = @(Get-VirtualizationRepairRung -HostType $hostType | ForEach-Object { if ($_.Available) { 'available' } else { $_.UnavailableCode } })
            Assert-Equal $expected[$hostType] ($codes -join ',') $hostType
        }
        $kvm = @(Get-VirtualizationRepairRung -HostType host.ubuntu.kvm)
        Assert-True $kvm[2].RequiresElevation 'the KVM start rung runs sudo -n'
        Assert-Equal 60 $kvm[2].EstimatedSeconds
        Assert-True (@(Get-VirtualizationRepairRung -HostType host.macos.utm)[1].RequiresSession) 'a restarted macOS runner drives UTM from the desktop session'
    }

    It 'makes every rung above the probe unavailable where the repair lock is unqualified' {
        Mock -ModuleName Test.HostRefresh Get-YurunaSingleFlightLockQualification { [pscustomobject]@{ PlatformQualified = $false } }
        Mock -ModuleName Test.HostRefresh Get-YurunaRunnerProtocolCapability { [pscustomobject]@{ Available = $true } }
        $kvm = @(Get-VirtualizationRepairRung -HostType host.ubuntu.kvm)
        Assert-True $kvm[0].Available 'the probe mutates nothing'
        Assert-Equal 'lock-unqualified' $kvm[1].UnavailableCode
        Assert-Equal 'lock-unqualified' $kvm[2].UnavailableCode
    }

    It 'makes reclaim unavailable where the runner protocol is unqualified or not loaded' {
        Mock -ModuleName Test.HostRefresh Get-YurunaSingleFlightLockQualification { [pscustomobject]@{ PlatformQualified = $true } }
        Mock -ModuleName Test.HostRefresh Get-YurunaRunnerProtocolCapability { [pscustomobject]@{ Available = $false } }
        Assert-Equal 'runner-restart-unqualified' (@(Get-VirtualizationRepairRung -HostType host.ubuntu.kvm)[1]).UnavailableCode
        Mock -ModuleName Test.HostRefresh Get-HostRefreshCommand { $null } -ParameterFilter { $Name -eq 'Get-YurunaRunnerProtocolCapability' }
        Assert-Equal 'runner-restart-unqualified' (@(Get-VirtualizationRepairRung -HostType host.ubuntu.kvm)[1]).UnavailableCode
    }

    It 'gives every available rung an executor defined in the module and every command it needs defined and exported in its source' {
        $moduleFunctions = @((Get-YurunaTestFileAst -Path $script:ModulePath).FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $executors = & (Get-Module Test.HostRefresh) { $script:HostRefreshRungExecutor }
        $findings = [System.Collections.Generic.List[string]]::new()
        foreach ($hostType in $script:AllHostTypes) {
            foreach ($rung in @(Get-VirtualizationRepairRung -HostType $hostType | Where-Object { $_.Available })) {
                $executor = $executors[$rung.Name]
                if (-not $executor -or $executor -notin $moduleFunctions) { $findings.Add("$hostType/$($rung.Name): no executor"); continue }
                foreach ($row in @(Get-HostRefreshRequiredCommand -HostType $hostType -Rung $rung.Name | Where-Object { $_.Rung -eq $rung.Name })) {
                    $source = Join-Path $script:RepoRoot $row.Source
                    if (-not (Test-Path -LiteralPath $source)) { $findings.Add("$hostType/$($rung.Name): $($row.Source) missing"); continue }
                    if ($row.Name -notin @(Get-ExportedFunctionName -Path $source)) { $findings.Add("$hostType/$($rung.Name): $($row.Name) not exported by $($row.Source)") }
                }
            }
        }
        Assert-NoFinding $findings.ToArray() 'an available rung must be executable'
    }

    It 'builds the macOS restart executor although the rung stays unavailable, so enabling it is a declaration change' {
        $executors = & (Get-Module Test.HostRefresh) { $script:HostRefreshRungExecutor }
        Assert-Equal 'Invoke-HostRefreshRestartIfHungRung' $executors['restart-if-hung']
        Assert-NotNull (& (Get-Module Test.HostRefresh) { Get-Command Invoke-HostRefreshRestartIfHungRung -CommandType Function })
        $row = @(Get-VirtualizationRepairRung -HostType host.macos.utm | Where-Object { $_.Name -eq 'restart-if-hung' })[0]
        Assert-False $row.Available
        Assert-Equal 'utm-restart-unqualified' $row.UnavailableCode
        foreach ($name in @('Restart-UtmApplication', 'Resume-YurunaServiceVM', 'Resolve-UtmctlExecutable')) {
            Assert-True ($name -in @(Get-ExportedFunctionName -Path (Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'))) "the macOS driver exports $name"
        }
    }
}

Describe 'Get-HostRefreshRungCeiling' {
    It 'maps restart to order 4 and full to 6, and MaxRung only lowers it' {
        $restart = Get-HostRefreshRungCeiling -HostType host.ubuntu.kvm -Tier restart
        Assert-True $restart.Valid
        Assert-Equal 4 $restart.CeilingOrder
        Assert-Equal 'restart-broker' $restart.CeilingName
        Assert-Equal 6 (Get-HostRefreshRungCeiling -HostType host.ubuntu.kvm -Tier full).CeilingOrder
        Assert-Equal 2 (Get-HostRefreshRungCeiling -HostType host.ubuntu.kvm -Tier restart -MaxRung start-if-stopped).CeilingOrder
        $reboot = Get-HostRefreshRungCeiling -HostType host.ubuntu.kvm -Tier restart -MaxRung reboot
        Assert-Equal 4 $reboot.CeilingOrder 'a ceiling above the tier clamps to the tier'
        Assert-Equal 6 (Get-HostRefreshRungCeiling -HostType host.ubuntu.kvm -Tier full -MaxRung reboot).CeilingOrder 'reboot belongs to no tier'
    }

    It 'refuses an unknown rung, tier or host' {
        Assert-Equal 'unknown-rung' (Get-HostRefreshRungCeiling -HostType host.ubuntu.kvm -Tier restart -MaxRung everything).Reason
        Assert-Equal 'unknown-tier' (Get-HostRefreshRungCeiling -HostType host.ubuntu.kvm -Tier forever).Reason
        Assert-Equal 'unsupported-host' (Get-HostRefreshRungCeiling -HostType host.nope -Tier restart).Reason
    }

    It 'matches the entry script: its -MaxRung set is the declared ladder' {
        $param = @((Get-YurunaTestFileAst -Path $script:EntryPath).FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'MaxRung' }, $true))[0]
        $set = @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0]
        $values = @($set.PositionalArguments | ForEach-Object { $_.Value })
        Assert-Equal ($script:ExpectedNames -join ',') ($values -join ',')
    }
}

Describe 'Get-HostRefreshProtocolVersion' {
    It 'reads version 1 from the checkout' {
        $version = Get-HostRefreshProtocolVersion -RepoRoot $script:RepoRoot
        Assert-True $version.Valid
        Assert-Equal 1 $version.Version
        Assert-Equal '1' ([IO.File]::ReadAllText((Join-Path $script:RepoRoot 'test/host-refresh.protocol-version')).Trim())
    }

    It 'reports missing, malformed and mismatched declarations' {
        $root = New-ScratchDir -Prefix 'proto'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'test')
        Assert-Equal 'missing' (Get-HostRefreshProtocolVersion -RepoRoot $root).Reason
        [IO.File]::WriteAllText((Join-Path $root 'test/host-refresh.protocol-version'), 'one')
        Assert-Equal 'malformed' (Get-HostRefreshProtocolVersion -RepoRoot $root).Reason
        [IO.File]::WriteAllText((Join-Path $root 'test/host-refresh.protocol-version'), "2`n")
        $mismatch = Get-HostRefreshProtocolVersion -RepoRoot $root
        Assert-Equal 'mismatch' $mismatch.Reason
        Assert-Equal 2 $mismatch.Version
    }
}

Describe 'Get-HostRefreshCapability' {
    BeforeAll {
        function New-JournalFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates scratch files under the private test area.')]
            param([object[]]$Request = @())
            $dir = New-ScratchDir -Prefix 'cap'
            $path = Join-Path $dir 'host-refresh.journal'
            $payload = [ordered]@{ schemaVersion = 2; writtenUtc = ''; owner = $null; requests = [object[]]$Request; reservations = @(); tombstones = @() }
            $null = Write-YurunaCriticalRecord -Path $path -Kind 'host-refresh.request-journal' -Payload $payload -ExpectedGeneration 0 -Confirm:$false
            $path
        }
    }

    It 'has exactly the five wire keys and stays small' {
        $summary = Get-HostRefreshCapability -HostType host.ubuntu.kvm -RepoRoot $script:RepoRoot -JournalPath (Join-Path (New-ScratchDir -Prefix 'cap') 'absent.journal')
        Assert-Equal 'protocol,availability,ceiling,reason,state' (@($summary.Keys) -join ',')
        Assert-True ((ConvertTo-Json -InputObject $summary -Compress).Length -le 256)
        Assert-Equal 'idle' $summary.state
    }

    It 'advertises only the qualified repair ceiling for each platform' {
        Mock -ModuleName Test.HostRefresh Get-YurunaSingleFlightLockQualification { [pscustomobject]@{ PlatformQualified = $true } }
        Mock -ModuleName Test.HostRefresh Get-YurunaRunnerProtocolCapability { [pscustomobject]@{ Available = $true } }
        $journal = Join-Path (New-ScratchDir -Prefix 'cap') 'absent.journal'
        foreach ($hostType in @('host.ubuntu.kvm', 'host.windows.hyper-v')) {
            $qualified = Get-HostRefreshCapability -HostType $hostType -RepoRoot $script:RepoRoot -JournalPath $journal
            Assert-Equal 'available' $qualified.availability
            Assert-Equal 'start-if-stopped' $qualified.ceiling
            Assert-Equal '' $qualified.reason
        }
        $other = Get-HostRefreshCapability -HostType host.macos.utm -RepoRoot $script:RepoRoot -JournalPath $journal
        Assert-Equal 'available' $other.availability
        Assert-Equal '' $other.reason
        Assert-Equal 'reclaim' $other.ceiling
        Assert-Equal 'unsupported_host' (Get-HostRefreshCapability -HostType host.other -RepoRoot $script:RepoRoot -JournalPath $journal).reason
    }

    It 'reports an unreadable protocol file and an unreadable journal' {
        $root = New-ScratchDir -Prefix 'cap'
        Assert-Equal 'protocol_unreadable' (Get-HostRefreshCapability -HostType host.ubuntu.kvm -RepoRoot $root -JournalPath (Join-Path $root 'j')).reason
        $bad = Join-Path $root 'bad.journal'
        [IO.File]::WriteAllText($bad, 'garbage')
        $summary = Get-HostRefreshCapability -HostType host.ubuntu.kvm -RepoRoot $script:RepoRoot -JournalPath $bad
        Assert-Equal 'journal_unreadable' $summary.reason
        Assert-Equal 'unknown' $summary.state
    }

    It 'reports active and recovery-pending state from the journal' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $running = New-JournalFixture -Request @([ordered]@{ requestId = 'a'; state = 'running'; createdUnixMs = $now; obligations = @() })
        Assert-Equal 'active' (Get-HostRefreshCapability -HostType host.ubuntu.kvm -RepoRoot $script:RepoRoot -JournalPath $running).state
        $pending = New-JournalFixture -Request @([ordered]@{ requestId = 'b'; state = 'recovery-pending'; createdUnixMs = $now; obligations = @(@{ id = 'runner'; status = 'armed' }) })
        Assert-Equal 'recovery_pending' (Get-HostRefreshCapability -HostType host.ubuntu.kvm -RepoRoot $script:RepoRoot -JournalPath $pending).state
        $old = New-JournalFixture -Request @([ordered]@{ requestId = 'c'; state = 'queued'; createdUnixMs = $now - 3600000; obligations = @() })
        Assert-Equal 'idle' (Get-HostRefreshCapability -HostType host.ubuntu.kvm -RepoRoot $script:RepoRoot -JournalPath $old).state 'an expired queued request holds nothing'
    }

    It 'imports with the journal module into a plain runspace with no driver and resolves what the listener calls' {
        $script = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($script:IntentPath)' -DisableNameChecking
Import-Module '$($script:ModulePath)' -DisableNameChecking
foreach (`$name in 'Get-HostRefreshCapability','Request-HostRefreshAdmission','Publish-HostRefreshQueuedState','New-HostRefreshWorkerArgumentList','Get-VirtualizationRepairRung') {
    if (-not (Get-Command `$name -ErrorAction SilentlyContinue)) { 'MISSING ' + `$name }
}
if (Get-Module Yuruna.Host) { 'DRIVER LOADED' }
'DONE'
"@
        $output = @(& $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $script 2>&1 | ForEach-Object { ([string]$_) -replace '\x1b\[[0-9;]*m', '' } |
                Where-Object { $_ -match '^(MISSING|DRIVER|DONE)' })
        Assert-Equal 'DONE' ($output -join '|')
    }
}

Describe 'budget' {
    It 'gives 60/600/240/15 s phases inside a 915 s total, with ticks above the Int32 range' {
        $budget = Get-TestBudget -Now 5000000000000
        Assert-Equal 5000000915000 $budget.TotalExpiryTick
        Assert-Equal 5000000060000 $budget.PreAdmissionExpiryTick
        Assert-Equal 5000000060000 (Get-HostRefreshPhaseDeadline -Budget $budget -Phase PreAdmission).ExpiryTick
        $admitted = Set-HostRefreshBudgetAdmitted -Budget $budget
        Assert-Equal 5000000000000 $admitted.AdmittedTick
        Assert-Equal 5000000600000 (Get-HostRefreshPhaseDeadline -Budget $admitted -Phase Ladder).ExpiryTick
        Assert-Equal 5000000240000 (Get-HostRefreshPhaseDeadline -Budget $admitted -Phase Convergence -StartTick 5000000000000).ExpiryTick
        Assert-Equal 5000000015000 (Get-HostRefreshPhaseDeadline -Budget $admitted -Phase Reporting -StartTick 5000000000000).ExpiryTick
    }

    It 'keeps a smaller supplied expiry, clamps a larger one, and never lets pre-admission outlive the total' {
        $tick = [long]5000000000000
        $clock = { $tick }.GetNewClosure()
        $smaller = New-HostRefreshBudget -ExpiryTick ($tick + 100000) -PreAdmissionExpiryTick ($tick + 200000) -ClockTicks $clock
        Assert-Equal ($tick + 100000) $smaller.TotalExpiryTick
        Assert-Equal ($tick + 60000) $smaller.PreAdmissionExpiryTick
        Assert-True $smaller.Clamped
        $larger = New-HostRefreshBudget -ExpiryTick ($tick + 9999999) -ClockTicks $clock
        Assert-Equal ($tick + 915000) $larger.TotalExpiryTick
        Assert-True $larger.Clamped
        $tiny = New-HostRefreshBudget -ExpiryTick ($tick + 10000) -ClockTicks $clock
        Assert-Equal ($tick + 10000) $tiny.PreAdmissionExpiryTick
    }

    It 'never lets a slow admission eat the convergence or reporting reserve' {
        $start = [long]5000000000000
        $current = @{ Now = $start }
        $clock = { $current.Now }.GetNewClosure()
        $budget = New-HostRefreshBudget -ClockTicks $clock
        $current.Now = $start + 59000
        $admitted = Set-HostRefreshBudgetAdmitted -Budget $budget
        $ladder = (Get-HostRefreshPhaseDeadline -Budget $admitted -Phase Ladder).ExpiryTick
        Assert-True ($ladder -le $budget.TotalExpiryTick - 255000) 'the ladder never runs into the reserves'
        $convergence = (Get-HostRefreshPhaseDeadline -Budget $admitted -Phase Convergence -StartTick ($start + 700000)).ExpiryTick
        Assert-Equal ($budget.TotalExpiryTick - 15000) $convergence
        Assert-Equal $budget.TotalExpiryTick (Get-HostRefreshPhaseDeadline -Budget $admitted -Phase Reporting -StartTick ($start + 910000)).ExpiryTick
    }
}

Describe 'verdict and exit adapter' {
    It 'applies the verdict table in order, first match wins' -ForEach @(
        @{ Name = 'preview'; Facts = @{ Preview = $true; Refused = $true }; Want = 'preview'; Exit = 0 }
        @{ Name = 'disposed'; Facts = @{ Disposed = $true; Refused = $true }; Want = 'disposed'; Exit = 0 }
        @{ Name = 'refused'; Facts = @{ Refused = $true; ExecutionError = $true }; Want = 'refused'; Exit = 1 }
        @{ Name = 'abandoned'; Facts = @{ AttemptsExhausted = $true; ExecutionError = $true }; Want = 'abandoned'; Exit = 2 }
        @{ Name = 'failed'; Facts = @{ ExecutionError = $true; FinalProbeState = 'Unresponsive' }; Want = 'failed'; Exit = 1 }
        @{ Name = 'operator-fixable denial'; Facts = @{ FinalProbeState = 'Undetermined'; FinalProbeReason = 'permission-denied' }; Want = 'refused'; Exit = 1 }
        @{ Name = 'operator-fixable session'; Facts = @{ FinalProbeState = 'Undetermined'; FinalProbeReason = 'no-session' }; Want = 'refused'; Exit = 1 }
        @{ Name = 'operator-fixable client'; Facts = @{ FinalProbeState = 'Undetermined'; FinalProbeReason = 'missing-client' }; Want = 'refused'; Exit = 1 }
        @{ Name = 'undetermined after mutation'; Facts = @{ Mutated = $true; FinalProbeState = 'Undetermined'; FinalProbeReason = 'permission-denied' }; Want = 'still-unresponsive'; Exit = 2 }
        @{ Name = 'still-unresponsive'; Facts = @{ FinalProbeState = 'Unresponsive'; FinalProbeReason = 'timeout' }; Want = 'still-unresponsive'; Exit = 2 }
        @{ Name = 'partial armed'; Facts = @{ Mutated = $true; FinalProbeState = 'Responsive'; ArmedOutstanding = 1 }; Want = 'partial'; Exit = 2 }
        @{ Name = 'partial unconverged'; Facts = @{ FinalProbeState = 'Responsive'; UnconvergedExpectation = 1 }; Want = 'partial'; Exit = 2 }
        @{ Name = 'partial deadline'; Facts = @{ FinalProbeState = 'Responsive'; DeadlineExpired = $true }; Want = 'partial'; Exit = 2 }
        @{ Name = 'partial error after mutation'; Facts = @{ Mutated = $true; ExecutionError = $true; FinalProbeState = 'Responsive' }; Want = 'partial'; Exit = 2 }
        @{ Name = 'repaired'; Facts = @{ Mutated = $true; FinalProbeState = 'Responsive' }; Want = 'repaired'; Exit = 0 }
        @{ Name = 'already-healthy'; Facts = @{ FinalProbeState = 'Responsive' }; Want = 'already-healthy'; Exit = 0 }
    ) {
        $verdict = Get-HostRefreshVerdict -Facts $Facts
        Assert-Equal $Want $verdict.Verdict $Name
        Assert-Equal $Exit $verdict.ExitCode $Name
    }

    It 'maps every verdict to 0, 1 or 2 and an unknown verdict to 1' {
        foreach ($pair in @(@('repaired', 0), @('already-healthy', 0), @('preview', 0), @('disposed', 0), @('refused', 1), @('failed', 1), @('partial', 2), @('still-unresponsive', 2), @('abandoned', 2), @('mystery', 1), @('', 1))) {
            Assert-Equal $pair[1] (Get-HostRefreshExitCode -Verdict $pair[0]) $pair[0]
        }
    }

    It 'never reports already-healthy after a forced mutation, and derives recovery-pending from armed obligations' {
        Assert-Equal 'repaired' (Get-HostRefreshVerdict -Facts @{ Mutated = $true; FinalProbeState = 'Responsive' }).Verdict
        Assert-Equal 'recovery-pending' (Get-HostRefreshVerdict -Facts @{ Mutated = $true; FinalProbeState = 'Responsive'; ArmedOutstanding = 2 }).State
        Assert-Equal 'refused' (Get-HostRefreshVerdict -Facts @{ Refused = $true }).State
    }
}

Describe 'wire codes and the relaunch and worker vectors' {
    It 'converts private tokens to their wire spelling' {
        Assert-Equal 'already_healthy' (ConvertTo-HostRefreshWireCode -Value 'already-healthy')
        Assert-Equal 'network_state_unknown' (ConvertTo-HostRefreshWireCode -Value 'network-state-unknown')
        Assert-Equal 'helpers_without_app' (ConvertTo-HostRefreshWireCode -Value 'helpers-without-app')
        Assert-Equal 'preview' (ConvertTo-HostRefreshWireCode -Value 'Preview')
        Assert-Equal '' (ConvertTo-HostRefreshWireCode -Value $null)
    }

    It 'forwards scalars, switches, string arrays and ticks above Int32, and refuses objects' {
        $budget = Get-TestBudget -Now 5000000000000
        $copy = New-HostRefreshRelaunchParameter -Budget $budget -BoundParameters @{
            Tier = 'restart'; Force = [System.Management.Automation.SwitchParameter]::new($true); RestoreServiceVmName = [string[]]@('a', 'b')
            DeadlineTickMs = [long]1; ErrorAction = [System.Management.Automation.ActionPreference]::Stop
        }
        Assert-Equal 'restart' $copy.Tier
        Assert-True $copy.Force.IsPresent
        Assert-Equal 2 $copy.RestoreServiceVmName.Count
        Assert-Equal ([long]5000000915000) $copy.DeadlineTickMs 'the budget tick replaces a bound one'
        Assert-Equal ([long]5000000060000) $copy.PreAdmissionDeadlineTickMs
        Assert-True ($copy.DeadlineTickMs -is [long])
        $text = @(ConvertTo-LibvirtRelaunchArgument -BoundParameters $copy)
        Assert-True (@($text | Where-Object { $_ -eq "-DeadlineTickMs '5000000915000'" }).Count -eq 1) 'the tick survives the command-text form'
        Assert-Throw { New-HostRefreshRelaunchParameter -Budget $budget -BoundParameters @{ Policy = @{ a = 1 } } }
        Assert-Throw { New-HostRefreshRelaunchParameter -Budget $budget -BoundParameters @{ Names = @('a', @{ b = 1 }) } }
    }

    It 'builds script arguments only by default, the interpreter prefix on request, and checks every name against the entry script' {
        $budget = Get-TestBudget -Now 5000000000000
        $id = '4242aaaa-0000-4000-8000-000000000001'
        $default = @(New-HostRefreshWorkerArgumentList -RepoRoot $script:RepoRoot -RequestId $id -Budget $budget)
        Assert-Equal "-RequestId|$id|-DeadlineTickMs|5000000915000|-PreAdmissionDeadlineTickMs|5000000060000" ($default -join '|')
        $explicit = @(New-HostRefreshWorkerArgumentList -RepoRoot $script:RepoRoot -RequestId $id -Budget $budget -ScriptArgumentOnly)
        Assert-Equal ($default -join '|') ($explicit -join '|')
        $full = @(New-HostRefreshWorkerArgumentList -RepoRoot $script:RepoRoot -RequestId $id -Budget $budget -IncludeInterpreterArgument)
        Assert-Equal '-NoLogo|-NoProfile|-NonInteractive|-File' (($full | Select-Object -First 4) -join '|')
        Assert-Equal $script:EntryPath $full[4]
        Assert-Throw { New-HostRefreshWorkerArgumentList -RepoRoot $script:RepoRoot -RequestId ([Guid]::NewGuid().ToString('N')) -Budget $budget }
        Assert-Throw { New-HostRefreshWorkerArgumentList -RepoRoot $script:RepoRoot -RequestId $id -Budget $budget -IncludeInterpreterArgument -ScriptArgumentOnly }
    }

    It 'refuses a vector the entry script would not accept, and keeps an awkward path as one token' {
        $budget = Get-TestBudget
        $id = '4242aaaa-0000-4000-8000-000000000001'
        $old = New-ScratchDir -Prefix 'argv'
        $null = New-Item -ItemType Directory -Path (Join-Path $old 'test/lab') -Force
        [IO.File]::WriteAllText((Join-Path $old 'test/lab/Invoke-HostRefresh.ps1'), "[CmdletBinding()] param([string]`$RequestId, [long]`$DeadlineTickMs)`n")
        Assert-Throw { New-HostRefreshWorkerArgumentList -RepoRoot $old -RequestId $id -Budget $budget }
        $odd = Join-Path (New-ScratchDir -Prefix 'argv') "with space's dir"
        $null = New-Item -ItemType Directory -Path (Join-Path $odd 'test/lab') -Force
        Copy-Item -LiteralPath $script:EntryPath -Destination (Join-Path $odd 'test/lab/Invoke-HostRefresh.ps1')
        $vector = @(New-HostRefreshWorkerArgumentList -RepoRoot $odd -RequestId $id -Budget $budget -IncludeInterpreterArgument)
        Assert-Equal (Join-Path $odd 'test/lab/Invoke-HostRefresh.ps1') $vector[4]
        Assert-Equal 11 $vector.Count
    }
}

Describe 'command closure and the module set' {
    It 'records the set the prelude imports for Refresh, dependencies first, and what it leaves out' {
        $set = @(Get-HostRefreshModuleSet)
        $excluded = @(Get-HostRefreshModuleSet -Excluded)
        Assert-Equal 'Test.HostRefresh.psm1' $set[-1]
        Assert-True ([array]::IndexOf($set, 'Test.OuterLog.psm1') -lt [array]::IndexOf($set, 'Test.HostRefresh.psm1'))
        Assert-True ([array]::IndexOf($set, 'Test.SingleFlightLock.psm1') -lt [array]::IndexOf($set, 'Test.SingleInstance.psm1'))
        foreach ($name in $set) { Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoRoot "test/modules/$name")) "$name exists" }
        foreach ($row in $excluded) { Assert-False ($row.Name -in $set) "$($row.Name) is excluded" }
        Assert-True ('Test.RunnerOuterLoop.psm1' -in @($excluded.Name)) 'the outer loop brings an unpruned tree kill'
        $prelude = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/modules/Test.Prelude.psm1')
        $refresh = @($prelude.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
                ForEach-Object { $_.KeyValuePairs } | Where-Object { $_.Item1.Extent.Text -eq 'Refresh' } | Select-Object -First 1)
        Assert-Equal 1 $refresh.Count 'the prelude declares the Refresh set'
        $listed = @($refresh[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
        Assert-Equal ($set -join ',') ($listed -join ',') 'the prelude and the recorded dependency graph agree'
    }

    It 'reports every missing command and its module, and leaves out executing-only rows in preview' {
        $rows = @(Get-HostRefreshRequiredCommand -Stage Startup)
        Assert-True ('Read-TestConfig' -in @($rows.Name))
        Assert-False ('Read-TestConfig' -in @(Get-HostRefreshRequiredCommand -Stage Startup -Preview).Name)
        Assert-Equal 'powershell-yaml' (@($rows | Where-Object { $_.Name -eq 'ConvertFrom-Yaml' })[0].Module)
        $script = @"
Import-Module '$($script:ModulePath)' -DisableNameChecking
`$r = Assert-HostRefreshCommandSet -Stage Startup -Preview
'COMPLETE=' + `$r.Complete
'MISSING=' + ((`$r.Missing | Sort-Object) -join ',')
"@
        $output = @(& $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $script 2>&1 | ForEach-Object { ([string]$_) -replace '\x1b\[[0-9;]*m', '' })
        Assert-True ($output -contains 'COMPLETE=False')
        $missing = (@($output | Where-Object { $_ -like 'MISSING=*' })[0]) -replace '^MISSING=', ''
        Assert-True ($missing -split ',' -contains 'Get-HostType')
        Assert-True ($missing -split ',' -contains 'Write-OuterLog')
        Assert-False ($missing -split ',' -contains 'Invoke-HostRefreshWorker') 'the module itself resolves'
    }

    It 'names the driver source for driver commands and each rung''s commands' {
        $row = @(Get-HostRefreshRequiredCommand -HostType host.ubuntu.kvm -Stage Driver | Where-Object { $_.Name -eq 'Test-VirtualizationResponsive' })[0]
        Assert-Equal 'host/ubuntu.kvm/modules/Yuruna.Host.psm1' $row.Source
        $rung = @(Get-HostRefreshRequiredCommand -HostType host.ubuntu.kvm -Rung start-if-stopped | Where-Object { $_.Rung -eq 'start-if-stopped' })
        Assert-True ('Start-VirtualizationServiceIfStopped' -in @($rung.Name))
    }
}

Describe 'Resolve-HostRefreshContext' {
    BeforeAll {
        function New-ContextFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates scratch files under the private test area.')]
            param()
            $root = New-ScratchDir -Prefix 'ctx'
            $test = Join-Path $root 'repo/test'
            $null = New-Item -ItemType Directory -Path (Join-Path $test 'modules') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $test 'status/runtime') -Force
            $config = Join-Path $test 'test.config.yml'
            [IO.File]::WriteAllText($config, "testCycle: {}`n")
            $homeDir = Join-Path $root 'home'
            $null = New-Item -ItemType Directory -Path $homeDir
            Set-IntentHome -Path $homeDir
            [pscustomobject]@{
                Root = $root; Home = $homeDir; Config = $config; Runtime = (Join-Path $test 'status/runtime')
                Paths = [ordered]@{ RepoRoot = (Join-Path $root 'repo'); TestRoot = $test; ModulesDir = (Join-Path $test 'modules') }
            }
        }
        function Add-Envelope {
            param([string]$Runtime, [string]$Source, [int]$PublisherPid = 1)
            $name = '.test.config.snapshot.' + [Guid]::NewGuid().ToString('N').Substring(0, 12) + '.json'
            $body = @{ sourcePath = $Source; publisherPid = $PublisherPid; config = @{ testCycle = @{}; statusService = @{ enabled = $false } } } | ConvertTo-Json -Depth 5 -Compress
            [IO.File]::WriteAllText((Join-Path $Runtime $name), $body)
        }
        $script:SavedRuntimeDir = @{ Present = (Test-Path Env:YURUNA_RUNTIME_DIR); Value = $env:YURUNA_RUNTIME_DIR }
        Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue
        $script:Deadline = New-YurunaDeadline -TotalMilliseconds 60000
    }
    AfterAll {
        if ($script:SavedRuntimeDir.Present) { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntimeDir.Value } else { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    }

    It 'falls back to the default runtime and configuration, creating nothing in preview' {
        $fixture = New-ContextFixture
        $context = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Preview -Deadline $script:Deadline
        Assert-True $context.Resolved $context.Reason
        Assert-Equal 'default' $context.RuntimeSource
        Assert-Equal 'default' $context.ConfigSource
        Assert-Equal $fixture.Config $context.ConfigPath
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Home '.yuruna')) 'a preview creates no private root'
        Assert-True (@($context.Observation) -contains 'private-root-absent')
    }

    It 'canonicalizes an explicit configuration reached through a link' {
        $fixture = New-ContextFixture
        $alias = Join-Path $fixture.Root 'alias'
        $null = New-Item -ItemType SymbolicLink -Path $alias -Target (Split-Path -Parent $fixture.Config)
        $context = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -ConfigPath (Join-Path $alias 'test.config.yml') -Preview -Deadline $script:Deadline
        Assert-Equal 'explicit' $context.ConfigSource
        Assert-Equal $fixture.Config $context.ConfigPath
    }

    It 'uses one snapshot envelope, refuses several distinct sources and a recorded source that is gone' {
        $fixture = New-ContextFixture
        $env:YURUNA_RUNTIME_DIR = $fixture.Runtime
        try {
            $other = Join-Path $fixture.Root 'other.yml'
            [IO.File]::WriteAllText($other, "testCycle: {}`n")
            Add-Envelope -Runtime $fixture.Runtime -Source $other
            Add-Envelope -Runtime $fixture.Runtime -Source (Join-Path $fixture.Root 'repo/test/extension/x/x.config.yml')
            $one = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Preview -Deadline $script:Deadline
            Assert-Equal 'snapshot-envelope' $one.ConfigSource
            Assert-Equal $other $one.ConfigPath
            Assert-Equal 'environment' $one.RuntimeSource
            Add-Envelope -Runtime $fixture.Runtime -Source $fixture.Config
            $two = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Preview -Deadline $script:Deadline
            Assert-False $two.Resolved
            Assert-Equal 'config-ambiguous' $two.Reason
            Assert-Equal 2 $two.ConfigCandidateCount
            Get-ChildItem -LiteralPath $fixture.Runtime -Force -Filter '.test.config.snapshot.*' | Remove-Item -Force
            Add-Envelope -Runtime $fixture.Runtime -Source (Join-Path $fixture.Root 'gone.yml')
            Assert-Equal 'config-missing' (Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Preview -Deadline $script:Deadline).Reason
        } finally { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    }

    It 'refuses a missing runtime, a runtime other than the request''s, and one other than the registered owner' {
        $fixture = New-ContextFixture
        $env:YURUNA_RUNTIME_DIR = Join-Path $fixture.Root 'nope'
        try {
            Assert-Equal 'runtime-missing' (Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Preview -Deadline $script:Deadline).Reason
            $env:YURUNA_RUNTIME_DIR = $fixture.Runtime
            Assert-Equal 'runtime-mismatch' (Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -RequestRuntimeDir (Join-Path $fixture.Root 'home') -Preview -Deadline $script:Deadline).Reason
        } finally { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
        $journal = Get-YurunaHostRefreshRequestPath
        $payload = [ordered]@{ schemaVersion = 2; writtenUtc = ''; owner = @{ runtimeDir = (Join-Path $fixture.Root 'home') }; requests = @(); reservations = @(); tombstones = @() }
        $null = Write-YurunaCriticalRecord -Path $journal -Kind 'host-refresh.request-journal' -Payload $payload -ExpectedGeneration 0 -Confirm:$false
        $env:YURUNA_RUNTIME_DIR = $fixture.Runtime
        try {
            $mismatch = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Preview -Deadline $script:Deadline
            Assert-Equal 'runtime-owner-mismatch' $mismatch.Reason
            Assert-Equal (Join-Path $fixture.Root 'home') $mismatch.RegisteredRuntimeDir
        } finally { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue
        $registered = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Preview -Deadline $script:Deadline
        Assert-Equal 'owner-registration' $registered.RuntimeSource
    }

    It 'creates the private root when executing, and marks a HOME other than the account''s as unverified' {
        $fixture = New-ContextFixture
        $context = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Deadline $script:Deadline
        Assert-True $context.Resolved $context.Reason
        Assert-True ([IO.Directory]::Exists((Join-Path $fixture.Home '.yuruna/host-refresh')))
        Assert-Equal (Join-Path $fixture.Home '.yuruna/host-refresh/host-refresh.lock') $context.LifetimeLockPath
        Assert-Equal (Join-Path $fixture.Runtime 'host-refresh.state.json') $context.PublicStatePath
        Assert-Equal 'mismatch' $context.HomeVerified 'a scratch HOME is not the account home, which disables disruptive rungs'
    }

    It 'creates no private root for root or an identity it cannot name, so the operator''s own runs are never locked out' {
        foreach ($case in @(
                if (-not $IsWindows) {
                    @{ Owner = [pscustomobject]@{ Resolved = $true; OwnerId = '0'; UserName = 'root'; IsRoot = $true; Elevated = $true }; Code = 'root-refused' }
                }
                @{ Owner = [pscustomobject]@{ Resolved = $false }; Code = 'identity-unknown' }
            )) {
            $fixture = New-ContextFixture
            $script:ContextOwner = $case.Owner
            Mock -ModuleName Test.HostRefresh Get-YurunaCurrentOwnerId { $script:ContextOwner }
            $context = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Deadline $script:Deadline
            Assert-False $context.Resolved $case.Code
            Assert-Equal 'identity-refused' $context.Reason
            Assert-True (@($context.Observation) -contains "identity-$($case.Code)")
            Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Home '.yuruna')) "$($case.Code): nothing was created under HOME"
            Assert-Equal $case.Code (Get-HostRefreshOperatorIdentity -HostType host.ubuntu.kvm -RuntimeDir $fixture.Runtime -Deadline $script:Deadline).Reason
        }
    }

    It 'resolves the runtime and private state without any configuration for a disposition' {
        $fixture = New-ContextFixture
        $env:YURUNA_RUNTIME_DIR = $fixture.Runtime
        try {
            $other = Join-Path $fixture.Root 'other.yml'
            [IO.File]::WriteAllText($other, "testCycle: {}`n")
            Add-Envelope -Runtime $fixture.Runtime -Source $other
            Add-Envelope -Runtime $fixture.Runtime -Source $fixture.Config
            Assert-Equal 'config-ambiguous' (Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -Deadline $script:Deadline).Reason
            $dispose = Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -NoConfig -Deadline $script:Deadline
            Assert-True $dispose.Resolved $dispose.Reason
            Assert-Null $dispose.ConfigPath
            Assert-Equal $fixture.Runtime $dispose.RuntimeDir
            Assert-Equal (Join-Path $fixture.Home '.yuruna/host-refresh/host-refresh.lock') $dispose.LifetimeLockPath
            Get-ChildItem -LiteralPath $fixture.Runtime -Force -Filter '.test.config.snapshot.*' | Remove-Item -Force
            Add-Envelope -Runtime $fixture.Runtime -Source (Join-Path $fixture.Root 'gone.yml')
            Assert-True (Resolve-HostRefreshContext -Paths $fixture.Paths -HostType host.ubuntu.kvm -NoConfig -Deadline $script:Deadline).Resolved 'a deleted configuration does not block it either'
        } finally { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-HostRefreshOperatorIdentity' {
    It 'refuses root, an unknown identity and a runtime owned by another account' {
        $deadline = New-YurunaDeadline -TotalMilliseconds 30000
        $runtime = New-ScratchDir -Prefix 'id'
        if (-not $IsWindows) {
            Mock -ModuleName Test.HostRefresh Get-YurunaCurrentOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '0'; UserName = 'root'; IsRoot = $true; Elevated = $true } }
            Assert-Equal 'root-refused' (Get-HostRefreshOperatorIdentity -HostType host.ubuntu.kvm -RuntimeDir $runtime -Deadline $deadline).Reason
        }
        Mock -ModuleName Test.HostRefresh Get-YurunaCurrentOwnerId { [pscustomobject]@{ Resolved = $false } }
        Assert-Equal 'identity-unknown' (Get-HostRefreshOperatorIdentity -HostType host.ubuntu.kvm -RuntimeDir $runtime -Deadline $deadline).Reason
        Mock -ModuleName Test.HostRefresh Get-YurunaCurrentOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '1001'; UserName = 'ytest'; IsRoot = $false; Elevated = $false } }
        Mock -ModuleName Test.HostRefresh Get-YurunaPathOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '2002'; Reason = 'ok' } }
        Assert-Equal 'runtime-owner-mismatch' (Get-HostRefreshOperatorIdentity -HostType host.ubuntu.kvm -RuntimeDir $runtime -Deadline $deadline).Reason
        Mock -ModuleName Test.HostRefresh Get-YurunaPathOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '1001'; Reason = 'ok' } }
        $ok = Get-HostRefreshOperatorIdentity -HostType host.ubuntu.kvm -RuntimeDir $runtime -Deadline $deadline
        Assert-True $ok.Allowed
        Assert-False $ok.GuiAllowed
    }

    It 'allows the desktop session on macOS only when it is Aqua' {
        $deadline = New-YurunaDeadline -TotalMilliseconds 30000
        $runtime = New-ScratchDir -Prefix 'id'
        Mock -ModuleName Test.HostRefresh Get-YurunaCurrentOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '501'; UserName = 'u'; IsRoot = $false; Elevated = $false } }
        Mock -ModuleName Test.HostRefresh Get-YurunaPathOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '501'; Reason = 'ok' } }
        function global:Get-MacSessionKind { param([int]$TimeoutSeconds) $null = $TimeoutSeconds; 'Remote' }
        try {
            $remote = Get-HostRefreshOperatorIdentity -HostType host.macos.utm -RuntimeDir $runtime -Deadline $deadline
            Assert-True $remote.Allowed 'a remote shell may still observe'
            Assert-Equal 'Remote' $remote.SessionKind
            Assert-False $remote.GuiAllowed
            Mock -ModuleName Test.HostRefresh Get-MacSessionKind { 'Aqua' }
            Assert-True (Get-HostRefreshOperatorIdentity -HostType host.macos.utm -RuntimeDir $runtime -Deadline $deadline).GuiAllowed
        } finally { Remove-Item -LiteralPath Function:\Get-MacSessionKind -ErrorAction SilentlyContinue }
    }
}

Describe 'Start-HostRefreshStatusService' {
    BeforeAll {
        function New-FakeListenerRepo {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates scratch files under the private test area.')]
            param([string]$Body)
            $root = New-ScratchDir -Prefix 'svc'
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'test/service') -Force
            [IO.File]::WriteAllText((Join-Path $root 'test/service/Start-StatusService.ps1'), $Body)
            $root
        }
    }

    It 'reports disabled for port 0, unavailable without a refresh-safe mode, and a deadline with no time left' {
        $deadline = New-YurunaDeadline -TotalMilliseconds 60000
        Assert-Equal 'disabled' (Start-HostRefreshStatusService -RepoRoot $script:RepoRoot -RuntimeDir '/tmp' -Port 0 -ResultPath '/tmp/x' -Deadline $deadline -Confirm:$false).Outcome
        $plain = New-FakeListenerRepo -Body "param([int]`$Port)`n"
        $missing = Start-HostRefreshStatusService -RepoRoot $plain -RuntimeDir '/tmp' -Port 8080 -ResultPath (Join-Path $plain 'r.json') -Deadline $deadline -Confirm:$false
        Assert-Equal 'unavailable' $missing.Outcome
        Assert-Equal 'refresh-safe-mode-missing' $missing.Reason
        $safe = New-FakeListenerRepo -Body "param([switch]`$RefreshSafe, [int]`$Port, [string]`$ResultPath, [long]`$DeadlineTickMs)`n"
        $spent = New-YurunaDeadline -TotalMilliseconds 0
        Assert-Equal 'deadline-exhausted' (Start-HostRefreshStatusService -RepoRoot $safe -RuntimeDir '/tmp' -Port 8080 -ResultPath (Join-Path $safe 'r.json') -Deadline $spent -Confirm:$false).Outcome
    }

    It 'runs the refresh-safe mode as a bounded child and reads only its result file' {
        $body = @'
param([switch]$RefreshSafe, [int]$Port, [string]$ResultPath, [long]$DeadlineTickMs)
'stdout is never parsed: {"outcome":"started"}'
$doc = @{ schemaVersion = 1; outcome = 'existing-ready'; port = $Port; pid = 4242; startTimeUnixMs = 1; sha = 'abc'; shaMatches = $false; reason = $env:YURUNA_RUNTIME_DIR }
[IO.File]::WriteAllText($ResultPath, ($doc | ConvertTo-Json -Compress))
exit 0
'@
        $root = New-FakeListenerRepo -Body $body
        $runtime = New-ScratchDir -Prefix 'svc'
        $result = Start-HostRefreshStatusService -RepoRoot $root -RuntimeDir $runtime -Port 8123 -ResultPath (Join-Path $root 'result.json') -Deadline (New-YurunaDeadline -TotalMilliseconds 60000) -Confirm:$false
        Assert-Equal 'existing-ready' $result.Outcome
        Assert-Equal $runtime $result.Reason 'the child received the owning runtime directory'
        Assert-Equal 4242 $result.Pid
        Assert-False $result.ShaMatches
        $garbage = New-FakeListenerRepo -Body "param([switch]`$RefreshSafe, [int]`$Port, [string]`$ResultPath, [long]`$DeadlineTickMs)`n[IO.File]::WriteAllText(`$ResultPath, 'nope')`n"
        $unreadable = Start-HostRefreshStatusService -RepoRoot $garbage -RuntimeDir $runtime -Port 8123 -ResultPath (Join-Path $garbage 'result.json') -Deadline (New-YurunaDeadline -TotalMilliseconds 60000) -Confirm:$false
        Assert-Equal 'unavailable' $unreadable.Outcome
        Assert-Equal 'result-unreadable' $unreadable.Reason
    }
}

Describe 'Write-HostRefreshLog' {
    It 'writes outer.log when executing, and not for a preview or a console-only line' {
        $runtime = New-ScratchDir -Prefix 'log'
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.OuterLog.psm1') -Global -DisableNameChecking
        $saved = @{ Present = (Test-Path Env:YURUNA_RUNTIME_DIR); Value = $env:YURUNA_RUNTIME_DIR }
        $env:YURUNA_RUNTIME_DIR = $runtime
        try {
            Write-HostRefreshLog -Key 'runner.host_refresh_verified_noop' -InformationAction SilentlyContinue
            Write-HostRefreshLog -Key 'runner.host_refresh_preview_notice' -Preview -InformationAction SilentlyContinue
            Write-HostRefreshLog -Key 'runner.host_refresh_manual_command' -Arguments @{ command = 'systemctl start x' } -ConsoleOnly -Level Warning -WarningAction SilentlyContinue
            $lines = @(Get-Content -LiteralPath (Join-Path $runtime 'outer.log'))
            Assert-Equal 1 $lines.Count
        } finally {
            if ($saved.Present) { $env:YURUNA_RUNTIME_DIR = $saved.Value } else { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'source guards over the refresh files' {
    BeforeAll {
        $script:GuardFiles = @(
            (Join-Path $script:RepoRoot 'test/lab/Invoke-HostRefresh.ps1'),
            (Join-Path $script:RepoRoot 'test/modules/Test.HostRefresh.psm1'),
            (Join-Path $script:RepoRoot 'test/modules/Test.HostRefreshIntent.psm1')
        )
    }

    It 'calls none of the forbidden commands' {
        $forbidden = @('Stop-StaleRunner', 'Stop-YurunaProcessTree', 'Stop-ProcessTree', 'Remove-TestVMFiles', 'taskkill', 'Read-Host', 'Confirm-Step',
            'Send-YurunaDegradation', 'Initialize-YurunaRuntimeDir', 'Get-EntryPointExitCode', 'Resolve-PortOrphan', 'Update-RunnerFaultStatus',
            'Start-Process', 'Set-Content', 'Out-File', 'killall', 'pkill', 'kill', 'Stop-Process')
        $findings = foreach ($file in $script:GuardFiles) {
            $ast = Get-YurunaTestFileAst -Path $file
            foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $command.GetCommandName()
                if ($name -and $name -in $forbidden) { "$file`:$($command.Extent.StartLineNumber) calls $name" }
                if ($command.InvocationOperator -eq 'Ampersand' -and $command.CommandElements[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    "$file`:$($command.Extent.StartLineNumber) runs a bare native command"
                }
            }
            foreach ($member in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                if ($member.Member.Extent.Text -in @('ShouldContinue', 'Kill')) { "$file`:$($member.Extent.StartLineNumber) calls .$($member.Member.Extent.Text)" }
            }
        }
        Assert-NoFinding @($findings) 'the refresh path never prompts, never tree-kills and never runs an unbounded native'
    }

    It 'writes no failure record, no cycle status and cites no process history' {
        $findings = foreach ($file in $script:GuardFiles) {
            $text = [IO.File]::ReadAllText($file)
            if ($text -match 'last_failure') { "$file names last_failure" }
            if ($text -match '(?<![-.\w])status\.json') { "$file names status.json" }
            # Assembled from parts so this guard never carries the phrases it
            # looks for.
            $phrases = @(@('section', '\d'), @('package', '\d'), @('this', 'slice'), @('the', 'plan\b'), @('prior', 'plan'), @('this', 'session'), @('cycle', '0\d'))
            $patterns = @($phrases | ForEach-Object { '(?i)\b' + ($_ -join ' ') }) + @('20' + '26-09')
            foreach ($pattern in $patterns) {
                if ($text -match $pattern) { "$file matches $pattern" }
            }
        }
        Assert-NoFinding @($findings)
    }

    It 'names no scratch area of the session that wrote a file, in the refresh files or their suites' {
        $suites = @('Test.HostRefresh', 'Test.HostRefreshIntent', 'Test.HostRefreshWorker', 'Test.HostRefreshEntryPoint', 'Test.HostRefreshProgress') |
            ForEach-Object { Join-Path $script:RepoRoot "test/modules/$_.Tests.ps1" }
        # Assembled from parts so this guard never carries the text it looks for.
        $patterns = @(('/tmp/' + 'claude-'), ('scratch' + 'pad'), ('[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/' + 'scratch'))
        $findings = foreach ($file in @($script:GuardFiles) + @($suites)) {
            $text = [IO.File]::ReadAllText($file)
            foreach ($pattern in $patterns) {
                if ($text -match $pattern) { "$file matches $pattern" }
            }
        }
        Assert-NoFinding @($findings) 'a private per-session path must never ship; tests take their temp directories from New-YurunaTestTempDir'
    }

    It 'documents every parameter and declares an output type on every public function' {
        $findings = foreach ($file in @($script:GuardFiles | Where-Object { $_ -like '*.psm1' })) {
            $ast = Get-YurunaTestFileAst -Path $file
            $exported = @(Get-ExportedFunctionName -Path $file)
            foreach ($function in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                if ($function.Name -notin $exported) { continue }
                $help = $function.GetHelpContent()
                $documented = if ($help) { @($help.Parameters.Keys | ForEach-Object { $_.ToUpperInvariant() }) } else { @() }
                foreach ($parameter in @($function.Body.ParamBlock.Parameters)) {
                    $name = $parameter.Name.VariablePath.UserPath
                    if ($name.ToUpperInvariant() -notin $documented) { "$($function.Name) has no .PARAMETER $name" }
                }
                if ('OutputType' -notin @($function.Body.ParamBlock.Attributes | ForEach-Object { $_.TypeName.Name })) { "$($function.Name) declares no [OutputType()]" }
            }
        }
        Assert-NoFinding @($findings)
    }

    It 'lets every public journal writer be previewed' {
        $file = Join-Path $script:RepoRoot 'test/modules/Test.HostRefreshIntent.psm1'
        $ast = Get-YurunaTestFileAst -Path $file
        $exported = @(Get-ExportedFunctionName -Path $file)
        $findings = foreach ($function in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            if ($function.Name -notin $exported -or $function.Name -like 'Get-*') { continue }
            $writes = @($function.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Invoke-HostRefreshJournalTransaction', 'Write-YurunaCriticalRecord') }, $true)).Count -gt 0
            if (-not $writes) { continue }
            $binding = @($function.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })
            $supports = $binding.Count -gt 0 -and @($binding[0].NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }).Count -gt 0
            if (-not $supports) { "$($function.Name) writes the journal without SupportsShouldProcess" }
        }
        Assert-NoFinding @($findings)
    }
}
