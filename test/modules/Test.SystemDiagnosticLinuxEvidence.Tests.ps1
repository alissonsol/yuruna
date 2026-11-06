<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42af9da1-899e-4918-9353-3045a08accdf
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test system diagnostic linux journal dmesg watchdog pester
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
    Guards the Linux crash evidence in Get-SystemDiagnostic.ps1: whether the
    system journal is readable, the kernel log when dmesg is restricted, the
    lockup and crash-evidence settings, and the deep diagnostics mode state;
    and NetworkManager's dhcp4 journal lines.
.DESCRIPTION
    A host whose operating system froze is diagnosed after its restart, from
    what the runner account could read. The helpers that collect that evidence
    are lifted out of the shipped script and driven against fixture files and
    stand-ins for the commands they call, so nothing is read from the machine
    running the suite. The message renderer answers with its key and
    arguments, so no assertion depends on catalog wording.

    One run of the whole script, on Linux only, proves the helpers are wired
    into the report: with dmesg refused and the system journal readable, the
    kernel lines and the problem they raise reach the report.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $PSScriptRoot
    $script:DiagPath = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'

    # Get-SystemDiagnostic is a top-to-bottom script, so dot-sourcing it would
    # run every probe. Each Describe dot-sources only the helpers it drives,
    # in its own scope, from the definitions this returns.
    function Get-DiagnosticHelperDefinition {
        param([string[]]$Name)
        foreach ($helper in $Name) {
            $definition = Get-YurunaTestFunctionAst -Path $script:DiagPath -Name $helper
            if (-not $definition) { throw "Get-SystemDiagnostic.ps1 no longer defines $helper." }
            [scriptblock]::Create($definition.Extent.Text)
        }
    }

    function Format-YurunaOperatorMessage {
        param([string]$Key, [hashtable]$Arguments = @{}, $FormatValues, $FormatBindings)
        $null = $FormatBindings
        $pairs = @($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" })
        if ($null -ne $FormatValues) { $pairs += @($FormatValues | ForEach-Object { "$_" }) }
        return ((@('MSG', $Key) + $pairs) -join '|')
    }
    function Add-Problem {
        param([string]$Message, [string]$Class)
        $script:Problems.Add(@{ Message = $Message; Class = $Class })
    }
    # Answers from the table a test fills, records the call, and leaves the
    # exit code where the helpers read it.
    function Invoke-PrivProbe {
        param([string]$Tool, [string[]]$ToolArgs = @(), [switch]$KeepStderr)
        $script:ProbeCalls.Add(@{ Tool = $Tool; Args = @($ToolArgs); KeepStderr = [bool]$KeepStderr })
        $answer = $script:ProbeAnswer[$Tool]
        if (-not $answer) { throw "unexpected probe: $Tool $($ToolArgs -join ' ')" }
        $global:LASTEXITCODE = $answer.Exit
        return @($answer.Lines)
    }
    function Test-CommandAvailable {
        param([string]$Name)
        return ($Name -notin $script:MissingCommand)
    }
}

Describe 'Linux crash evidence helpers' {
    BeforeEach {
        $script:Problems = [System.Collections.Generic.List[object]]::new()
        $script:ProbeCalls = [System.Collections.Generic.List[object]]::new()
        $script:ProbeAnswer = @{}
        $script:MissingCommand = @()
    }

    Describe 'the kernel log when dmesg is restricted' {
        BeforeAll {
            foreach ($helper in Get-DiagnosticHelperDefinition -Name 'Write-LinuxKernelLog') { . $helper }
            $script:Refused = @{ Exit = 1; Lines = @('dmesg: read kernel buffer failed: Operation not permitted') }
            $script:KernelJournal = @(
                'Nov 02 08:00:01 host kernel: Linux version 7.2.7'
                'Nov 02 08:00:02 host kernel: mce: [Hardware Error]: Machine check events logged'
                'Nov 02 08:00:03 host kernel: Out of memory: Killed process 4242 (qemu-system-x86)'
            )
        }

        It 'prints the current boot''s kernel journal and raises its OOM and hardware problems under their classes' {
            $script:ProbeAnswer['dmesg'] = $script:Refused
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = $script:KernelJournal }
            $out = @(Write-LinuxKernelLog)
            $out | Should -Contain 'MSG|automation.operator_719107a91a9041cd|1'
            $out | Should -Contain 'MSG|automation.system_diagnostic_kernel_log_journal|count=5000'
            foreach ($line in $script:KernelJournal) { $out | Should -Contain $line }
            @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('LINUX.oom-events', 'LINUX.hardware-errors')
            $script:Problems[0].Message | Should -Be 'MSG|automation.system_diagnostic_kernel_journal_oom|count=1'
            $script:Problems[1].Message | Should -Be 'MSG|automation.system_diagnostic_kernel_journal_hardware|count=1'
        }

        It 'asks the journal quietly for the newest kernel entries of the current boot' {
            $script:ProbeAnswer['dmesg'] = $script:Refused
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = $script:KernelJournal }
            $null = Write-LinuxKernelLog
            $journal = @($script:ProbeCalls | Where-Object { $_.Tool -eq 'journalctl' })
            $journal.Count | Should -Be 1
            ($journal[0].Args -join ' ') | Should -BeExactly '-k -b 0 -n 5000 -q --no-pager' -Because 'without -q a hint and an empty-journal marker would be read as kernel records'
        }

        It 'keeps dmesg, with its own problem messages, when dmesg answers' {
            $script:ProbeAnswer['dmesg'] = @{ Exit = 0; Lines = @('[Mon Nov  2 08:00:01 2026] EDAC MC0: 1 CE memory read error') }
            $out = @(Write-LinuxKernelLog)
            $out | Should -Contain '[Mon Nov  2 08:00:01 2026] EDAC MC0: 1 CE memory read error'
            @($script:ProbeCalls | Where-Object { $_.Tool -eq 'journalctl' }) | Should -BeNullOrEmpty
            @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('LINUX.hardware-errors')
            $script:Problems[0].Message | Should -Be 'MSG|automation.operator_0052f7d7f687e07e|1'
        }

        It 'reads the journal when dmesg is not installed' {
            $script:MissingCommand = @('dmesg')
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = $script:KernelJournal }
            $out = @(Write-LinuxKernelLog)
            $out[0] | Should -Be 'MSG|automation.operator_dce38997155da39d'
            $out | Should -Contain 'MSG|automation.system_diagnostic_kernel_log_journal|count=5000'
            $out | Should -Contain $script:KernelJournal[0]
        }

        It 'says there is no kernel log, and raises nothing, when the journal cannot be read either' {
            $script:ProbeAnswer['dmesg'] = $script:Refused
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = @() }
            $out = @(Write-LinuxKernelLog)
            $out | Should -Be @('MSG|automation.operator_719107a91a9041cd|1', 'MSG|automation.system_diagnostic_kernel_log_unavailable')
            $script:Problems.Count | Should -Be 0
        }

        It 'prints the newest 100 lines but scans every line it read' {
            $script:ProbeAnswer['dmesg'] = $script:Refused
            $lines = @('Nov 02 08:00:00 host kernel: mce: [Hardware Error]: CPU 3: Machine Check: 0 Bank 5') +
                @(1..299 | ForEach-Object { "Nov 02 08:00:00 host kernel: line $_" })
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = $lines }
            $out = @(Write-LinuxKernelLog)
            @($out | Where-Object { $_ -like 'Nov 02*' }) | Should -Be @($lines | Select-Object -Last 100)
            @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('LINUX.hardware-errors')
        }

        It 'raises no hardware problem for the banners every boot prints, or for edac inside a name, read from <Source>' -TestCases @(
            @{ Source = 'dmesg'; Prefix = '[Mon Nov  2 08:00:01 2026] ' }
            @{ Source = 'journalctl'; Prefix = 'Nov 02 08:00:01 edac-lab kernel: ' }
        ) {
            param($Source, $Prefix)
            $lines = @(
                'EDAC MC: Ver: 3.0.0'
                'MCE: In-kernel MCE decoding enabled.'
                'mce: [Firmware Bug]: Ignoring request to disable invalid MCA bank 7.'
                'EDAC MC0: Giving out device to module amd64_edac controller F19h: DEV 0000:00:18.3 (INTERRUPT)'
                'EXT4-fs (nvme0n1p2): mounted filesystem a1d3e943-0145-4279-a89f-51edac6af667 r/w with ordered data mode.'
                'cni0: port 4(vethdedac31b) entered blocking state'
            ) | ForEach-Object { "$Prefix$_" }
            $script:ProbeAnswer['dmesg'] = if ($Source -eq 'dmesg') { @{ Exit = 0; Lines = $lines } } else { $script:Refused }
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = $lines }
            $out = @(Write-LinuxKernelLog)
            foreach ($line in $lines) { $out | Should -Contain $line }
            $script:Problems.Count | Should -Be 0 -Because 'a clean boot is not a hardware fault'
        }

        It 'counts each hardware error report, and nothing beside them' {
            $script:ProbeAnswer['dmesg'] = $script:Refused
            $reports = @(
                'mce: [Hardware Error]: CPU 3: Machine Check: 0 Bank 5: bea0000000000108'
                '{1}[Hardware Error]: Hardware error from APEI Generic Hardware Error Source: 0'
                'sd 0:0:0:0: [sda] tag#7 Sense Key : Hardware Error [current]'
                'I/O error, dev nvme0n1, sector 2048 op 0x0:(READ) flags 0x80700 phys_seg 1 prio class 2'
                'XFS (dm-0): Metadata I/O Error (0x1) detected at xfs_trans_read_buf_map+0x1d0/0x2f0 [xfs]'
                'EDAC MC0: 1 CE memory read error on CPU_SrcID#0_Ha#0_Chan#0_DIMM#0 (channel:0 slot:0 page:0x1234 offset:0x0 grain:32 syndrome:0x0)'
                'EDAC MC1: 2 UE memory read error on unknown memory (page:0x0 offset:0x0 grain:32)'
            )
            $banners = @('EDAC MC: Ver: 3.0.0', 'MCE: In-kernel MCE decoding enabled.', 'cni0: port 4(vethdedac31b) entered forwarding state')
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = @($banners + $reports | ForEach-Object { "Nov 02 08:00:01 host kernel: $_" }) }
            $null = Write-LinuxKernelLog
            @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('LINUX.hardware-errors')
            $script:Problems[0].Message | Should -Be "MSG|automation.system_diagnostic_kernel_journal_hardware|count=$($reports.Count)"
        }
    }

    Describe 'whether the system journal is readable' {
        BeforeAll {
            foreach ($helper in Get-DiagnosticHelperDefinition -Name 'Write-LinuxJournalAccess') { . $helper }
            # Stands in for id; a test sets the group database's answer.
            function id {
                $script:IdCalls.Add(@($args))
                return $script:IdAnswer
            }
        }
        BeforeEach {
            $script:IdCalls = [System.Collections.Generic.List[object]]::new()
            $script:IdAnswer = 'runner'
        }

        It 'says so when journalctl --system answers' {
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = @('Nov 02 08:00:01 host systemd[1]: Started fixture.service.') }
            @(Write-LinuxJournalAccess -UserName 'runner') | Should -Be @('MSG|automation.system_diagnostic_journal_readable')
            $script:IdCalls.Count | Should -Be 0
        }

        It 'names the account, journalctl''s reason and the fix when it does not' {
            $script:ProbeAnswer['journalctl'] = @{ Exit = 1; Lines = @('', 'No journal files were opened due to insufficient permissions.') }
            $script:IdAnswer = 'runner sudo kvm libvirt'
            @(Write-LinuxJournalAccess -UserName 'runner') | Should -Be @(
                'MSG|automation.system_diagnostic_journal_unreadable|detail=No journal files were opened due to insufficient permissions.|user=runner'
                'MSG|automation.system_diagnostic_journal_grant|user=runner'
            )
        }

        It 'asks for a new login session when the group database already lists the membership' {
            $script:ProbeAnswer['journalctl'] = @{ Exit = 1; Lines = @('No journal files were opened due to insufficient permissions.') }
            $script:IdAnswer = 'runner kvm systemd-journal'
            $out = @(Write-LinuxJournalAccess -UserName 'runner')
            $out[1] | Should -Be 'MSG|automation.system_diagnostic_journal_session_stale|user=runner'
            $script:IdCalls[0] | Should -Be @('-nG', 'runner') -Because 'the process''s own group set is what is stale; the database is what a new login gets'
        }

        It 'asks journalctl about the system journal alone, without its notices' {
            $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = @() }
            $null = Write-LinuxJournalAccess -UserName 'runner'
            ($script:ProbeCalls[0].Args -join ' ') | Should -BeExactly '--system -n 1 -q --no-pager'
            $script:ProbeCalls[0].KeepStderr | Should -BeTrue -Because 'the reason journalctl gives is printed with the verdict'
        }
    }

    Describe 'the lockup and crash-evidence settings' {
        BeforeAll {
            foreach ($helper in Get-DiagnosticHelperDefinition -Name 'Read-DiagnosticAttribute', 'Format-BiosDiagnosticValue',
                    'Get-LinuxLockupSettingLine') { . $helper }
            # Stands in for the bounded runner; a test sets what systemctl and
            # systemd-analyze answer.
            function Invoke-DiagnosticBoundedCommand {
                param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds, [int]$MaxCapturedChars)
                $null = $MaxCapturedChars
                $script:BoundedCalls.Add(@{ FilePath = $FilePath; Args = @($ArgumentList); TimeoutSeconds = $TimeoutSeconds })
                $answer = $script:BoundedAnswer[$FilePath]
                if (-not $answer) { throw "unexpected bounded command: $FilePath $($ArgumentList -join ' ')" }
                return $answer
            }
            function Get-CatConfigAnswer {
                param([string]$Text)
                return @{ Started = $true; ExitCode = 0; StdOut = $Text; StdErr = ''; TimedOut = $false; OutputTruncated = $false }
            }

            function New-SettingFixture {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test fixture: writes files under TestDrive, which Pester removes.')]
                param([hashtable]$Sysctl, [hashtable]$Watchdog = @{}, [switch]$PersistentJournal)
                $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                $fixture = @{
                    ProcSysKernel = Join-Path $root 'proc/sys/kernel'
                    PstoreBackend = Join-Path $root 'pstore/backend'
                    WatchdogClass = Join-Path $root 'class/watchdog'
                    PersistentJournal = Join-Path $root 'var/log/journal'
                }
                $null = New-Item -ItemType Directory -Path $fixture.ProcSysKernel, $fixture.WatchdogClass, (Split-Path -Parent $fixture.PstoreBackend)
                foreach ($name in $Sysctl.Keys) { [IO.File]::WriteAllText((Join-Path $fixture.ProcSysKernel $name), $Sysctl[$name]) }
                [IO.File]::WriteAllText($fixture.PstoreBackend, "efi_pstore`n")
                foreach ($device in $Watchdog.Keys) {
                    $dir = New-Item -ItemType Directory -Path (Join-Path $fixture.WatchdogClass $device)
                    [IO.File]::WriteAllText((Join-Path $dir.FullName 'identity'), "$($Watchdog[$device].Identity)`n")
                    [IO.File]::WriteAllText((Join-Path $dir.FullName 'timeout'), "$($Watchdog[$device].Timeout)`n")
                }
                if ($PersistentJournal) { $null = New-Item -ItemType Directory -Path $fixture.PersistentJournal }
                return $fixture
            }

            function Format-SettingRow { param([string]$Label, [string]$Value) '{0,-36} : {1}' -f $Label, $Value }

            $script:Sysctl = @{
                watchdog = "1`n"; nmi_watchdog = "0`n"; softlockup_panic = "1`n"; hardlockup_panic = "0`n"; panic = "10`n"
                panic_on_oops = "1`n"; hung_task_timeout_secs = "120`n"; hung_task_panic = "0`n"; printk = "4`t4`t1`t7`n"
            }
        }
        BeforeEach {
            $script:BoundedCalls = [System.Collections.Generic.List[object]]::new()
            $script:BoundedAnswer = @{
                'systemctl' = @{ Started = $true; ExitCode = 0; StdOut = "30s`n"; StdErr = ''; TimedOut = $false }
                'systemd-analyze' = Get-CatConfigAnswer -Text "# /etc/systemd/journald.conf`n[Journal]`n#Storage=auto`n"
            }
        }

        It 'reads each lockup setting, the pstore backend, every watchdog device and whether the journal persists' {
            $fixture = New-SettingFixture -Sysctl $script:Sysctl -PersistentJournal -Watchdog @{
                watchdog1 = @{ Identity = 'iTCO_wdt'; Timeout = 30 }
                watchdog0 = @{ Identity = 'SP5100 TCO timer'; Timeout = 60 }
            }
            $lines = @(Get-LinuxLockupSettingLine @fixture)
            $names = @('watchdog', 'nmi_watchdog', 'softlockup_panic', 'hardlockup_panic', 'panic', 'panic_on_oops',
                'hung_task_timeout_secs', 'hung_task_panic', 'printk')
            $expected = @(foreach ($name in $names) {
                    $value = if ($name -eq 'printk') { '"4 4 1 7"' } else { ConvertTo-Json -InputObject $script:Sysctl[$name].Trim() -Compress }
                    Format-SettingRow -Label "kernel.$name" -Value $value
                }) + @(
                Format-SettingRow -Label $fixture.PstoreBackend -Value '"efi_pstore"'
                Format-SettingRow -Label (Join-Path (Join-Path $fixture.WatchdogClass 'watchdog0') 'identity') -Value '"SP5100 TCO timer"'
                Format-SettingRow -Label (Join-Path (Join-Path $fixture.WatchdogClass 'watchdog0') 'timeout') -Value '"60"'
                Format-SettingRow -Label (Join-Path (Join-Path $fixture.WatchdogClass 'watchdog1') 'identity') -Value '"iTCO_wdt"'
                Format-SettingRow -Label (Join-Path (Join-Path $fixture.WatchdogClass 'watchdog1') 'timeout') -Value '"30"'
                Format-SettingRow -Label 'RuntimeWatchdogUSec' -Value '"30s"'
                Format-SettingRow -Label 'systemd/journald.conf:Storage' -Value '"auto"'
                "MSG|automation.system_diagnostic_journal_persistent|path=$($fixture.PersistentJournal)"
            )
            ($lines -join "`n") | Should -BeExactly ($expected -join "`n")
            ($script:BoundedCalls[0].Args -join ' ') | Should -BeExactly 'show --property=RuntimeWatchdogUSec --value'
            $script:BoundedCalls[0].TimeoutSeconds | Should -BeGreaterThan 0 -Because 'PID 1 answers this query, and may not on a host in trouble'
            $script:BoundedCalls[1].FilePath | Should -Be 'systemd-analyze'
            ($script:BoundedCalls[1].Args -join ' ') | Should -BeExactly '--no-pager cat-config systemd/journald.conf'
            $script:BoundedCalls[1].TimeoutSeconds | Should -BeGreaterThan 0
        }

        It 'marks a setting this kernel lacks, says when there is no watchdog device, and when the journal is volatile' {
            $partial = @{} + $script:Sysctl
            $partial.Remove('hardlockup_panic')
            $fixture = New-SettingFixture -Sysctl $partial
            $lines = @(Get-LinuxLockupSettingLine @fixture)
            $lines | Should -Contain (Format-SettingRow -Label 'kernel.hardlockup_panic' -Value '(not reported)')
            $lines | Should -Contain "MSG|automation.system_diagnostic_watchdog_none|path=$($fixture.WatchdogClass)"
            $lines | Should -Contain "MSG|automation.system_diagnostic_journal_volatile|path=$($fixture.PersistentJournal)"
            @($lines | Where-Object { $_ -like '*identity*' }) | Should -BeNullOrEmpty
        }

        It 'reports RuntimeWatchdogUSec as not reported when systemd does not answer in time' {
            $script:BoundedAnswer['systemctl'] = @{ Started = $true; ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true }
            $fixture = New-SettingFixture -Sysctl $script:Sysctl
            $lines = @(Get-LinuxLockupSettingLine @fixture)
            $lines | Should -Contain (Format-SettingRow -Label 'RuntimeWatchdogUSec' -Value '(not reported)')
        }

        It 'does not ask systemd where systemctl is missing' {
            $script:MissingCommand = @('systemctl')
            $fixture = New-SettingFixture -Sysctl $script:Sysctl
            $lines = @(Get-LinuxLockupSettingLine @fixture)
            @($script:BoundedCalls | Where-Object { $_.FilePath -eq 'systemctl' }) | Should -BeNullOrEmpty
            $lines | Should -Contain (Format-SettingRow -Label 'RuntimeWatchdogUSec' -Value '(not reported)')
        }

        It 'says the journal survives a freeze only when journald''s Storage= keeps it on disk: <Case>' -TestCases @(
            @{ Case = 'volatile in a later drop-in, the directory present'; Directory = $true; Storage = 'volatile'; Verdict = 'not_on_disk'
                Config = "# /etc/systemd/journald.conf`n[Journal]`nStorage=persistent`n`n# /etc/systemd/journald.conf.d/50-ram.conf`n[Journal]`nStorage = volatile`n" }
            @{ Case = 'none, the directory present'; Directory = $true; Storage = 'none'; Verdict = 'not_on_disk'; Config = "[Journal]`nStorage=none`n" }
            @{ Case = 'an invalid value, which journald ignores'; Directory = $true; Storage = 'volatile'; Verdict = 'not_on_disk'; Config = "[Journal]`nStorage=volatile`nStorage=disk`n" }
            @{ Case = 'persistent, the directory present'; Directory = $true; Storage = 'persistent'; Verdict = 'persistent'; Config = "[Journal]`nStorage=persistent`n" }
            @{ Case = 'not set, so auto, the directory absent'; Directory = $false; Storage = 'auto'; Verdict = 'volatile'; Config = "[Journal]`n#Storage=persistent`n" }
        ) {
            param($Case, $Directory, $Storage, $Verdict, $Config)
            $null = $Case
            $script:BoundedAnswer['systemd-analyze'] = Get-CatConfigAnswer -Text $Config
            $fixture = New-SettingFixture -Sysctl $script:Sysctl -PersistentJournal:$Directory
            $lines = @(Get-LinuxLockupSettingLine @fixture)
            $lines | Should -Contain (Format-SettingRow -Label 'systemd/journald.conf:Storage' -Value "`"$Storage`"")
            $lines[-1] | Should -BeExactly $(if ($Verdict -eq 'not_on_disk') {
                    "MSG|automation.system_diagnostic_journal_not_on_disk|path=$($fixture.PersistentJournal)|storage=$Storage"
                } else {
                    "MSG|automation.system_diagnostic_journal_$Verdict|path=$($fixture.PersistentJournal)"
                })
        }

        It 'reports Storage= as not reported, and judges by the directory alone, when systemd-analyze <Case>' -TestCases @(
            @{ Case = 'is missing'; Answer = $null }
            @{ Case = 'does not answer in time'; Answer = @{ Started = $true; ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true; OutputTruncated = $false } }
            @{ Case = 'fails'; Answer = @{ Started = $true; ExitCode = 1; StdOut = ''; StdErr = 'Unknown command verb cat-config.'; TimedOut = $false; OutputTruncated = $false } }
            @{ Case = 'answers more than is kept'; Answer = @{ Started = $true; ExitCode = 0; StdOut = "[Journal]`nStorage=persistent`n"; StdErr = ''; TimedOut = $false; OutputTruncated = $true } }
        ) {
            param($Case, $Answer)
            $null = $Case
            if ($Answer) { $script:BoundedAnswer['systemd-analyze'] = $Answer } else { $script:MissingCommand = @('systemd-analyze') }
            $fixture = New-SettingFixture -Sysctl $script:Sysctl -PersistentJournal
            $lines = @(Get-LinuxLockupSettingLine @fixture)
            $lines | Should -Contain (Format-SettingRow -Label 'systemd/journald.conf:Storage' -Value '(not reported)')
            $lines[-1] | Should -BeExactly "MSG|automation.system_diagnostic_journal_persistent|path=$($fixture.PersistentJournal)"
            if (-not $Answer) { @($script:BoundedCalls | Where-Object { $_.FilePath -eq 'systemd-analyze' }) | Should -BeNullOrEmpty }
        }
    }

    Describe 'the deep diagnostics mode state' {
        BeforeAll {
            foreach ($helper in Get-DiagnosticHelperDefinition -Name 'Format-BiosDiagnosticValue', 'Get-DiagnosticSourceFile',
                    'Get-DeepDiagnosticStateLine') { . $helper }

            function New-StateFile {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test fixture: writes a file under TestDrive, which Pester removes.')]
                param([string]$Text)
                $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                $null = New-Item -ItemType Directory -Path $dir
                $path = Join-Path $dir 'state.json'
                [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
                return $path
            }

            function Format-StateRow { param([string]$Label, [string]$Value) '{0,-36} : {1}' -f $Label, $Value }

            $script:ValidState = [ordered]@{
                schema = 'yuruna.deep-diagnostics-state/v1'
                enabledAtUtc = '2026-11-02T10:00:00Z'
                enabledBy = 'operator'
                hostType = 'host.ubuntu.kvm'
                netconsoleTarget = '192.168.7.10:6666'
                components = [ordered]@{
                    netconsole = [ordered]@{ status = 'applied'; reason = '' }
                    pstore = [ordered]@{ status = 'skipped'; reason = 'efi_pstore already registered' }
                    kdump = [ordered]@{ status = 'failed'; reason = 'no crashkernel= reservation' }
                }
                futureField = @{ nested = 1 }
            }
        }

        It 'says the mode is off when no state file exists' {
            $path = Join-Path $TestDrive 'absent/state.json'
            @(Get-DeepDiagnosticStateLine -Path $path) | Should -Be @("MSG|automation.system_diagnostic_deep_mode_off|path=$path")
        }

        It 'prints since when the mode is on, its netconsole target and every component''s status in file order' {
            $path = New-StateFile -Text ($script:ValidState | ConvertTo-Json -Depth 4)
            $lines = @(Get-DeepDiagnosticStateLine -Path $path)
            ($lines -join "`n") | Should -BeExactly (@(
                    'MSG|automation.system_diagnostic_deep_mode_on|enabledAtUtc=2026-11-02T10:00:00Z'
                    Format-StateRow -Label 'schema' -Value '"yuruna.deep-diagnostics-state/v1"'
                    Format-StateRow -Label 'enabledBy' -Value '"operator"'
                    Format-StateRow -Label 'hostType' -Value '"host.ubuntu.kvm"'
                    Format-StateRow -Label 'netconsoleTarget' -Value '"192.168.7.10:6666"'
                    Format-StateRow -Label 'components.netconsole.status' -Value '"applied"'
                    Format-StateRow -Label 'components.netconsole.reason' -Value '""'
                    Format-StateRow -Label 'components.pstore.status' -Value '"skipped"'
                    Format-StateRow -Label 'components.pstore.reason' -Value '"efi_pstore already registered"'
                    Format-StateRow -Label 'components.kdump.status' -Value '"failed"'
                    Format-StateRow -Label 'components.kdump.reason' -Value '"no crashkernel= reservation"'
                ) -join "`n") -Because 'an unknown field is normal and is left alone'
        }

        It 'tells an empty netconsole target from a missing one' {
            $state = [ordered]@{} + $script:ValidState
            $state['netconsoleTarget'] = ''
            $state.Remove('enabledBy')
            $lines = @(Get-DeepDiagnosticStateLine -Path (New-StateFile -Text ($state | ConvertTo-Json -Depth 4)))
            $lines | Should -Contain (Format-StateRow -Label 'netconsoleTarget' -Value '""')
            $lines | Should -Contain (Format-StateRow -Label 'enabledBy' -Value '(not reported)')
        }

        It 'reports a state file that is not JSON instead of failing' {
            $path = New-StateFile -Text '{"schema": "yuruna.deep-diagnostics-state/v1", "enabledAtUtc": '
            $lines = @(Get-DeepDiagnosticStateLine -Path $path)
            $lines.Count | Should -Be 1
            $lines[0] | Should -BeLike "MSG|automation.system_diagnostic_deep_mode_malformed|message=*|path=$path"
        }

        It 'reports a document that is not a JSON object, an empty file included' -TestCases @(
            @{ Text = '[1,2]'; Found = '[1,2]' }
            @{ Text = '"enabled"'; Found = '"enabled"' }
            @{ Text = ''; Found = 'null' }
        ) {
            param($Text, $Found)
            $path = New-StateFile -Text $Text
            @(Get-DeepDiagnosticStateLine -Path $path) | Should -Be @("MSG|automation.system_diagnostic_deep_mode_malformed|message=$Found|path=$path")
        }

        It 'does not read a state file that is not a regular file of at most 64 KiB' {
            $large = New-StateFile -Text ('{"pad": "' + ('x' * 70000) + '"}')
            @(Get-DeepDiagnosticStateLine -Path $large) | Should -Be @("MSG|automation.system_diagnostic_deep_mode_unreadable|path=$large")
            $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/state.json')
            $null = New-Item -ItemType Directory -Path $folder
            @(Get-DeepDiagnosticStateLine -Path $folder) | Should -Be @("MSG|automation.system_diagnostic_deep_mode_unreadable|path=$folder")
        }

        It 'renders a value of an unexpected shape as JSON instead of failing' {
            $state = [ordered]@{
                enabledAtUtc = 5
                netconsoleTarget = [ordered]@{ ip = '192.168.7.10'; port = 6666 }
                components = 'none'
            }
            $lines = @(Get-DeepDiagnosticStateLine -Path (New-StateFile -Text ($state | ConvertTo-Json -Depth 4)))
            $lines[0] | Should -Be 'MSG|automation.system_diagnostic_deep_mode_on|enabledAtUtc=5'
            $lines | Should -Contain (Format-StateRow -Label 'netconsoleTarget' -Value '{"ip":"192.168.7.10","port":6666}')
            $lines | Should -Contain (Format-StateRow -Label 'components' -Value '"none"')
            $lines | Should -Contain (Format-StateRow -Label 'schema' -Value '(not reported)')
        }
    }
}

Describe 'NetworkManager''s dhcp4 journal' {
    BeforeAll {
        foreach ($helper in Get-DiagnosticHelperDefinition -Name 'Get-LinuxNetworkManagerDhcpLine') { . $helper }
    }
    BeforeEach {
        $script:Problems = [System.Collections.Generic.List[object]]::new()
        $script:ProbeCalls = [System.Collections.Generic.List[object]]::new()
        $script:ProbeAnswer = @{}
        $script:MissingCommand = @()
    }

    It 'asks the current boot''s NetworkManager journal for its newest 100 dhcp4 lines and prints them as they are' {
        $lines = @(
            'Nov 03 09:12:01 alien01 NetworkManager[812]: <info>  [1793697121.1234] dhcp4 (yuruna-br0): activation: beginning transaction (timeout in 45 seconds)'
            'Nov 03 09:12:02 alien01 NetworkManager[812]: <info>  [1793697122.2345] dhcp4 (yuruna-br0): state changed new lease, address=192.0.2.95'
        )
        $script:ProbeAnswer['journalctl'] = @{ Exit = 0; Lines = $lines }
        @(Get-LinuxNetworkManagerDhcpLine) | Should -Be $lines
        $script:ProbeCalls.Count | Should -Be 1
        $script:ProbeCalls[0].Tool | Should -Be 'journalctl'
        ($script:ProbeCalls[0].Args -join ' ') | Should -BeExactly '-b 0 -u NetworkManager --grep dhcp4 -n 100 --no-pager'
        $script:Problems.Count | Should -Be 0 -Because 'the lines are evidence for a reader, not a fault'
    }

    It 'says there are no entries when the journal gives none' {
        $script:ProbeAnswer['journalctl'] = @{ Exit = 1; Lines = @() }
        @(Get-LinuxNetworkManagerDhcpLine) | Should -Be @('MSG|automation.system_diagnostic_networkmanager_dhcp_none')
    }

    It 'prints journalctl''s own word when it found nothing to show' {
        $script:ProbeAnswer['journalctl'] = @{ Exit = 1; Lines = @('-- No entries --') }
        @(Get-LinuxNetworkManagerDhcpLine) | Should -Be @('-- No entries --')
    }
}

Describe 'the Linux crash evidence is wired into the report' {
    BeforeAll {
        $script:DiagAst = Get-YurunaTestFileAst -Path $script:DiagPath
        function Get-SectionBody {
            param([string]$Title)
            $wanted = $Title
            $call = $script:DiagAst.Find({ param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Invoke-DiagnosticSection' -and
                    $node.CommandElements[1].Value -eq $wanted }.GetNewClosure(), $true)
            if (-not $call) { throw "no '$Title' section" }
            return $call.CommandElements[2].Extent.Text
        }
    }

    It 'says whether the journal is readable before RECENT SYSTEM EVENTS reads it' {
        $body = Get-SectionBody -Title 'RECENT SYSTEM EVENTS (errors / warnings)'
        $access = $body.IndexOf('Write-LinuxJournalAccess', [StringComparison]::Ordinal)
        $access | Should -BeGreaterThan -1
        $access | Should -BeLessThan $body.IndexOf("'-p','err'", [StringComparison]::Ordinal)
    }

    It 'prints the kernel log, the settings and the deep diagnostics state in HOST DETAIL' {
        $body = Get-SectionBody -Title 'HOST DETAIL'
        foreach ($helper in 'Write-LinuxKernelLog', 'Get-LinuxLockupSettingLine', 'Get-DeepDiagnosticStateLine') {
            $body | Should -Match "\b$helper\b"
        }
    }

    It 'reads NetworkManager''s dhcp4 journal right after systemd-networkd''s in the early-boot timeline' {
        $body = Get-SectionBody -Title 'INSTALL & EARLY-BOOT TIMELINE (Linux)'
        $networkd = $body.IndexOf("'-u','systemd-networkd'", [StringComparison]::Ordinal)
        $networkd | Should -BeGreaterThan -1
        $dhcp4 = $body.IndexOf('Get-LinuxNetworkManagerDhcpLine', [StringComparison]::Ordinal)
        $dhcp4 | Should -BeGreaterThan $networkd
        $dhcp4 | Should -BeLessThan $body.IndexOf("'automation.operator_91db0522b1d981fb'", [StringComparison]::Ordinal)
    }

    It 'carries the kernel journal into the report when dmesg is refused' -Skip:(-not $IsLinux) {
        # The bounded runner is lifted under its own name: this Describe runs
        # the script for real, with stand-ins on PATH for sudo, dmesg and
        # journalctl only.
        $definition = Get-YurunaTestFunctionAst -Path $script:DiagPath -Name 'Invoke-DiagnosticBoundedCommand'
        . ([scriptblock]::Create($definition.Extent.Text))
        $solo = Join-Path $TestDrive 'solo'
        $bin = Join-Path $TestDrive 'bin'
        $null = New-Item -ItemType Directory -Path $solo, $bin
        $copy = Join-Path $solo 'Get-SystemDiagnostic.ps1'
        Copy-Item -LiteralPath $script:DiagPath -Destination $copy
        $stub = @{
            # No passwordless sudo, as on a runner without a sudoers rule.
            'sudo' = "#!/bin/sh`nexit 1`n"
            # No container engine: the report asks docker for its version even
            # with -SkipDocker, and docker can be podman, whose first use leaves
            # a pause process running after the test.
            'docker' = "#!/bin/sh`nexit 1`n"
            'dmesg' = "#!/bin/sh`necho 'dmesg: read kernel buffer failed: Operation not permitted' >&2`nexit 1`n"
            # Kernel records for -k, one system record for --system, and an
            # empty journal for every other query the report makes.
            'journalctl' = @'
#!/bin/sh
case " $* " in
  *" -k "*) printf '%s\n' 'Nov 02 08:00:01 fixture kernel: fixture kernel journal line' 'Nov 02 08:00:02 fixture kernel: mce: [Hardware Error]: Machine check events logged' ;;
  *" --system "*) printf '%s\n' 'Nov 02 08:00:03 fixture systemd[1]: fixture system journal line' ;;
esac
exit 0
'@
        }
        foreach ($name in $stub.Keys) {
            $path = Join-Path $bin $name
            [IO.File]::WriteAllText($path, $stub[$name].Replace("`r`n", "`n"))
            & chmod +x $path
        }
        $saved = Save-YurunaTestEnvironment -Name 'PATH'
        try {
            $env:PATH = $bin + [IO.Path]::PathSeparator + $saved.PATH
            $run = Invoke-DiagnosticBoundedCommand -FilePath (Get-Process -Id $PID).Path -TimeoutSeconds 300 -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-File', $copy, '-SkipDocker', '-SkipKube', '-SkipProjectGaps',
                '-CheckoutRoot', (Join-Path $TestDrive 'no-checkout'))
        } finally { Restore-YurunaTestEnvironment -Saved $saved }

        $run.TimedOut | Should -BeFalse
        $run.ExitCode | Should -Be 0 -Because $run.StdErr
        $run.StdOut | Should -Match 'fixture kernel journal line'
        $run.StdOut | Should -Match ([regex]::Escape('mce: [Hardware Error]: Machine check events logged'))
        $run.StdOut | Should -Match '(?m)^/sys/class/dmi/id/sys_vendor\s+: '
        $run.StdOut | Should -Match '(?m)^kernel\.softlockup_panic\s+: '
        $summary = [regex]::Match($run.StdOut, '(?ms)^===YURUNA-DIAG-JSON-BEGIN===\r?\n(.*?)\r?\n===YURUNA-DIAG-JSON-END===')
        $summary.Success | Should -BeTrue
        $problems = $summary.Groups[1].Value | ConvertFrom-Json -AsHashtable
        $problems.byClass['LINUX.hardware-errors'] | Should -Be 1
        $problems.byClass.Keys | Should -Not -Contain 'DIAG.section-aborted'
    }
}
