<#PSScriptInfo
.VERSION 2026.11.16
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

# A boot that ran for weeks holds more warnings than the report could ever
# read in its budget. These stand-ins for journalctl run as real processes, so
# what is checked is that each read ends on its own, or at its deadline.
Describe 'the previous boot''s warning journal' -Skip:(-not $IsLinux) {
    BeforeAll {
        foreach ($helper in Get-DiagnosticHelperDefinition -Name 'Invoke-DiagnosticBoundedCommand', 'Write-LinuxPreviousBootWarning') { . $helper }
        # A journalctl stand-in in a folder of its own. It logs each call with
        # its pid, answers `-n 60` with $Newest and any other read with
        # $Oldest, both shell fragments.
        function New-JournalStub {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a stand-in script under TestDrive.')]
            [CmdletBinding()]
            param([string]$Newest, [string]$Oldest)
            $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $bin
            $stub = @'
#!/bin/sh
echo "$$ $*" >> "$(dirname "$0")/calls"
case " $* " in
  *" -n 60 "*) __NEWEST__ ;;
  *) __OLDEST__ ;;
esac
'@
            $path = Join-Path $bin 'journalctl'
            [IO.File]::WriteAllText($path, $stub.Replace('__NEWEST__', $Newest).Replace('__OLDEST__', $Oldest).Replace("`r`n", "`n"))
            & chmod +x $path
            return $bin
        }
        function Get-BootLineCommand {
            param([int]$First, [int]$Last)
            return ('i={0}; while [ "$i" -le {1} ]; do echo "Nov 01 00:00:00 fixture kernel: warning $i"; i=$((i + 1)); done' -f $First, $Last)
        }
        function Get-BootLine {
            param([int]$First, [int]$Last)
            return @($First..$Last | ForEach-Object { "Nov 01 00:00:00 fixture kernel: warning $_" })
        }
        # Ignoring SIGPIPE, as every child of this process does, the endless
        # stand-in keeps writing into a closed pipe until something stops it.
        $script:EndlessBoot = 'i=1; while :; do echo "Nov 01 00:00:00 fixture kernel: warning $i"; i=$((i + 1)); done'
    }
    BeforeEach {
        $script:Problems = [System.Collections.Generic.List[object]]::new()
        $script:LinuxPriv = @()
        $script:SavedPath = Save-YurunaTestEnvironment -Name 'PATH'
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedPath }

    It 'prints the oldest and newest 60 lines of a boot whose warnings never end, and stops journalctl once it has them' {
        $bin = New-JournalStub -Newest (Get-BootLineCommand 99941 100000) -Oldest $script:EndlessBoot
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $out = @(Write-LinuxPreviousBootWarning -TimeoutSeconds 30)
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'both reads end on their own, long before their deadline'
        $out.Count | Should -Be 121
        $out[0..59] | Should -Be (Get-BootLine 1 60)
        $out[60] | Should -Be 'MSG|automation.system_diagnostic_previous_boot_middle_omitted'
        $out[61..120] | Should -Be (Get-BootLine 99941 100000)
        $script:Problems.Count | Should -Be 0
        $calls = @(Get-Content -LiteralPath (Join-Path $bin 'calls'))
        $calls.Count | Should -Be 2
        foreach ($call in $calls) {
            $stubPid = [int]($call -split ' ')[0]
            $wait = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-Process -Id $stubPid -ErrorAction SilentlyContinue) -and $wait.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            Get-Process -Id $stubPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "journalctl ($call) must not keep reading after the report has its lines"
        }
    }

    It 'prints a boot whose warnings fit in both ends once, in order' {
        $bin = New-JournalStub -Newest (Get-BootLineCommand 31 90) -Oldest (Get-BootLineCommand 1 90)
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        @(Write-LinuxPreviousBootWarning -TimeoutSeconds 30) | Should -Be (Get-BootLine 1 90)
        $script:Problems.Count | Should -Be 0
    }

    It 'reads only the newest end of a boot with fewer warnings than that end holds' {
        $bin = New-JournalStub -Newest (Get-BootLineCommand 1 30) -Oldest 'echo "the oldest end is read"'
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        @(Write-LinuxPreviousBootWarning -TimeoutSeconds 30) | Should -Be (Get-BootLine 1 30)
        $calls = @(Get-Content -LiteralPath (Join-Path $bin 'calls'))
        $calls.Count | Should -Be 1
        $calls[0] | Should -Match ' -b -1 -p warning --no-pager -n 60$'
    }

    It 'says there is no previous boot when journalctl prints nothing' {
        $bin = New-JournalStub -Newest 'echo "Data from the specified boot (-1) is not available" >&2; exit 1' -Oldest 'exit 1'
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        @(Write-LinuxPreviousBootWarning -TimeoutSeconds 30) | Should -Be @('MSG|automation.operator_ac55f29eb491874d')
        $script:Problems.Count | Should -Be 0
    }

    It 'returns at its deadline when the oldest end stalls, keeps the lines it read, names that read and raises DIAG.probe-timeout, and still prints the newest end' {
        $bin = New-JournalStub -Newest (Get-BootLineCommand 99941 100000) -Oldest ((Get-BootLineCommand 1 10) + '; sleep 60')
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $out = @(Write-LinuxPreviousBootWarning -TimeoutSeconds 2)
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 12 -Because 'the stalled read is stopped at its two-second deadline'
        $out.Count | Should -Be 72
        $out[0..9] | Should -Be (Get-BootLine 1 10) -Because 'the lines read before the deadline survive the stop'
        $out[10] | Should -Be 'MSG|automation.system_diagnostic_probe_stopped|label=journalctl -b -1 -p warning --no-pager | sed -u 121q|seconds=2'
        $out[11] | Should -Be 'MSG|automation.system_diagnostic_previous_boot_middle_omitted'
        $out[-60..-1] | Should -Be (Get-BootLine 99941 100000)
        @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('DIAG.probe-timeout')
        $script:Problems[0].Message | Should -Be 'MSG|automation.operator_cd63c049294a2c32|join=-b -1 -p warning --no-pager | sed -u 121q|problemTag=DIAG.probe-timeout|timeoutSeconds=2|tool=journalctl'
    }

    It 'keeps the oldest lines a stalled journalctl had already formatted, though writing into a pipe holds them in a block' {
        # sed without -u holds its output in a block when writing into a pipe,
        # as journalctl does; only line buffering gets these lines out before
        # the stop.
        $bin = New-JournalStub -Newest (Get-BootLineCommand 99941 100000) -Oldest ('{ ' + (Get-BootLineCommand 1 10) + '; sleep 60; } | sed -n p')
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        $out = @(Write-LinuxPreviousBootWarning -TimeoutSeconds 2)
        $out.Count | Should -Be 72
        $out[0..9] | Should -Be (Get-BootLine 1 10)
        $out[10] | Should -BeLike 'MSG|automation.system_diagnostic_probe_stopped|*'
        $out[11] | Should -Be 'MSG|automation.system_diagnostic_previous_boot_middle_omitted'
        $out[-60..-1] | Should -Be (Get-BootLine 99941 100000)
    }

    It 'prints only whole lines from an oldest end stopped in the middle of a line' {
        # One 4 KiB block, as a block-buffered journalctl writes it, ending 5
        # bytes into the twenty-sixth line, then nothing more.
        $block = 'i=1; while [ "$i" -le 40 ]; do printf "Nov 01 00:00:00 fixture kernel: warning %d %0120d\n" "$i" 0; i=$((i + 1)); done | dd bs=4096 count=1 iflag=fullblock status=none; exec sleep 60'
        $bin = New-JournalStub -Newest (Get-BootLineCommand 99941 100000) -Oldest $block
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        $out = @(Write-LinuxPreviousBootWarning -TimeoutSeconds 2)
        $out.Count | Should -Be 87
        $out[0..24] | Should -Be @(1..25 | ForEach-Object { 'Nov 01 00:00:00 fixture kernel: warning {0} {1}' -f $_, ('0' * 120) })
        $out[25] | Should -BeLike 'MSG|automation.system_diagnostic_probe_stopped|*'
    }

    It 'drops the fragment a stopped reader flushed because its writer ended first' {
        # At the deadline both ends of the pipe are stopped in no fixed order.
        # When journalctl goes first, sed reads the end of its input and
        # writes out the unfinished line it was holding, with no newline.
        function Invoke-DiagnosticBoundedCommand {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stand-in: the signature has to match the real helper so the caller binds.')]
            param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds, [int]$MaxCapturedChars)
            if ($FilePath -eq 'journalctl') {
                return @{ StdOut = ((Get-BootLine 99941 100000) -join "`n") + "`n"; TimedOut = $false }
            }
            return @{ StdOut = ((Get-BootLine 1 25) -join "`n") + "`nNov 0"; TimedOut = $true }
        }
        $out = @(Write-LinuxPreviousBootWarning -TimeoutSeconds 2)
        $out.Count | Should -Be 87
        $out[0..24] | Should -Be (Get-BootLine 1 25)
        $out[25] | Should -BeLike 'MSG|automation.system_diagnostic_probe_stopped|*'
        $out[-60..-1] | Should -Be (Get-BootLine 99941 100000)
    }

    It 'stops reading the oldest end at the line it needs, without waiting for another' {
        $bin = New-JournalStub -Newest (Get-BootLineCommand 99941 100000) -Oldest ((Get-BootLineCommand 1 121) + '; exec sleep 60')
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $out = @(Write-LinuxPreviousBootWarning -TimeoutSeconds 30)
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'the read has its 121 lines before journalctl stalls'
        $out.Count | Should -Be 121
        $out[0..59] | Should -Be (Get-BootLine 1 60)
        $out[60] | Should -Be 'MSG|automation.system_diagnostic_previous_boot_middle_omitted'
        $out[61..120] | Should -Be (Get-BootLine 99941 100000)
        $script:Problems.Count | Should -Be 0
    }

    It 'returns at its deadline when the newest end stalls, without reading the oldest end' {
        $bin = New-JournalStub -Newest 'sleep 60' -Oldest 'echo "the oldest end is read"'
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $out = @(Write-LinuxPreviousBootWarning -TimeoutSeconds 2)
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 12
        $out | Should -Be @('MSG|automation.system_diagnostic_probe_stopped|label=journalctl -b -1 -p warning --no-pager -n 60|seconds=2')
        @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('DIAG.probe-timeout')
        @(Get-Content -LiteralPath (Join-Path $bin 'calls')).Count | Should -Be 1
    }

    It 'runs both reads under the privilege prefix' {
        $bin = New-JournalStub -Newest (Get-BootLineCommand 99941 100000) -Oldest $script:EndlessBoot
        $sudo = Join-Path $bin 'sudo'
        [IO.File]::WriteAllText($sudo, "#!/bin/sh`necho `"`$*`" >> `"`$(dirname `"`$0`")/sudo-calls`"`n[ `"`$1`" = -n ] && shift`nexec `"`$@`"`n")
        & chmod +x $sudo
        $env:PATH = $bin + [IO.Path]::PathSeparator + $script:SavedPath.PATH
        $script:LinuxPriv = @('sudo', '-n')
        @(Write-LinuxPreviousBootWarning -TimeoutSeconds 30).Count | Should -Be 121
        $calls = @(Get-Content -LiteralPath (Join-Path $bin 'sudo-calls'))
        $calls.Count | Should -Be 2
        $calls[0] | Should -BeExactly '-n journalctl -b -1 -p warning --no-pager -n 60'
        $calls[1] | Should -BeLike '-n bash -c * bash 121 -b -1 -p warning --no-pager'
    }
}

# The snapshot's repository and provider parts run in a child PowerShell. Its
# user module folder comes first in the child's module path and, on Linux,
# follows XDG_DATA_HOME, so a PowerShellGet written there stands in for the
# real one in the child alone. The module versions are read in this process,
# from PSModulePath, which the stand-in's folder is put in front of as well.
Describe 'the PowerShell module snapshot' -Skip:(-not $IsLinux) {
    BeforeAll {
        foreach ($helper in Get-DiagnosticHelperDefinition -Name 'Invoke-DiagnosticBoundedCommand', 'Write-DiagnosticModuleSnapshot') { . $helper }
        function Set-PowerShellGetStandIn {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a stand-in module under TestDrive and points this test''s XDG_DATA_HOME and PSModulePath at it.')]
            [CmdletBinding()]
            param([string]$Body, [string]$ProviderBody)
            $data = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $modules = Join-Path $data 'powershell/Modules'
            $module = Join-Path $modules 'PowerShellGet'
            $null = New-Item -ItemType Directory -Path $module
            # A function the stand-in exports answers before the real
            # Get-PackageProvider cmdlet once Get-PSRepository has loaded it.
            $text = "function Get-PSRepository { $Body }`nExport-ModuleMember -Function Get-PSRepository`n"
            if ($ProviderBody) { $text += "function Get-PackageProvider { $ProviderBody }`nExport-ModuleMember -Function Get-PackageProvider`n" }
            [IO.File]::WriteAllText((Join-Path $module 'PowerShellGet.psm1'), $text)
            $env:XDG_DATA_HOME = $data
            $env:PSModulePath = $modules + [IO.Path]::PathSeparator + $env:PSModulePath
        }
        $timeout = (Get-YurunaTestFunctionAst -Path $script:DiagPath -Name 'Write-DiagnosticModuleSnapshot').Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutSeconds' }
        $script:SnapshotDefaultSeconds = [int]$timeout.DefaultValue.SafeGetValue()
        # A module without a manifest is listed as version 0.0.
        $script:StandInModuleRow = '(?m)^PowerShellGet\s+0\.0\s*$'
    }
    BeforeEach {
        $script:Problems = [System.Collections.Generic.List[object]]::new()
        $script:SavedData = Save-YurunaTestEnvironment -Name 'XDG_DATA_HOME', 'PSModulePath'
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedData }

    It 'prints the repository, provider and module tables, each under its heading' {
        Set-PowerShellGetStandIn -Body '[pscustomobject]@{ Name = ''FixtureGallery''; SourceLocation = ''https://gallery.invalid/api/v2''; InstallationPolicy = ''Trusted''; Trusted = $true }'
        $out = @(Write-DiagnosticModuleSnapshot -TimeoutSeconds 60)
        $repository = [array]::FindIndex([string[]]$out, [Predicate[string]] { param($line) $line -match 'Name\s+: FixtureGallery' })
        $providers = [array]::IndexOf([string[]]$out, '--- PackageProvider -ListAvailable ---')
        $modules = [array]::IndexOf([string[]]$out, '--- Modules (PowerShellGet, PSResourceGet, powershell-yaml) ---')
        $repository | Should -Be 0
        $providers | Should -BeGreaterThan $repository
        $modules | Should -BeGreaterThan $providers
        $out[$modules + 1] | Should -Match $script:StandInModuleRow
        $script:Problems.Count | Should -Be 0
    }

    It 'keeps Get-PSRepository''s own error, and its problem class, and still lists the rest' {
        Set-PowerShellGetStandIn -Body 'throw ''fixture repository registration is unreadable'''
        $out = @(Write-DiagnosticModuleSnapshot -TimeoutSeconds 60)
        $out[0] | Should -Be 'MSG|automation.operator_29759c8a58f5d70a|fixture repository registration is unreadable'
        $out | Should -Contain '--- PackageProvider -ListAvailable ---'
        $out | Should -Contain '--- Modules (PowerShellGet, PSResourceGet, powershell-yaml) ---'
        @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('PROVISIONING.repository-unavailable')
        $script:Problems[0].Message | Should -Be 'MSG|automation.operator_29e3b381e78aec31'
    }

    It 'stops a snapshot that does not answer at its default deadline, says so, raises DIAG.probe-timeout and still lists the module versions' {
        # Blocked inside .NET, where a stop request inside the same process
        # would wait until the call returned.
        Set-PowerShellGetStandIn -Body '[Threading.Thread]::Sleep(600000)'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $out = @(Write-DiagnosticModuleSnapshot)
        $clock.Elapsed.TotalSeconds | Should -BeLessThan ($script:SnapshotDefaultSeconds + 3) -Because 'the child is stopped at its deadline'
        $out.Count | Should -Be 3
        $out[0] | Should -Be "MSG|automation.system_diagnostic_probe_stopped|label=pwsh Get-PSRepository; Get-PackageProvider -ListAvailable|seconds=$($script:SnapshotDefaultSeconds)"
        $out[1] | Should -Be '--- Modules (PowerShellGet, PSResourceGet, powershell-yaml) ---'
        $out[2] | Should -Match $script:StandInModuleRow
        @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('DIAG.probe-timeout')
        $script:Problems[0].Message | Should -Be "MSG|automation.operator_cd63c049294a2c32|join=Get-PSRepository; Get-PackageProvider -ListAvailable|problemTag=DIAG.probe-timeout|timeoutSeconds=$($script:SnapshotDefaultSeconds)|tool=pwsh"
    }

    It 'prints the repository part that finished before the deadline, and the stopped note in place of the provider part' {
        Set-PowerShellGetStandIn -Body '[pscustomobject]@{ Name = ''FixtureGallery''; SourceLocation = ''https://gallery.invalid/api/v2''; InstallationPolicy = ''Trusted''; Trusted = $true }' `
            -ProviderBody '[Threading.Thread]::Sleep(600000)'
        $out = @(Write-DiagnosticModuleSnapshot -TimeoutSeconds 10)
        $out.Count | Should -Be 5
        $out[0] | Should -Match 'Name\s+: FixtureGallery'
        $out[1] | Should -Be '--- PackageProvider -ListAvailable ---'
        $out[2] | Should -Be 'MSG|automation.system_diagnostic_probe_stopped|label=pwsh Get-PSRepository; Get-PackageProvider -ListAvailable|seconds=10'
        $out[3] | Should -Be '--- Modules (PowerShellGet, PSResourceGet, powershell-yaml) ---'
        $out[4] | Should -Match $script:StandInModuleRow
        @($script:Problems | ForEach-Object { $_.Class }) | Should -Be @('DIAG.probe-timeout')
    }

    It 'aborts the section with the child''s exit status when the child ends before its deadline' {
        Set-PowerShellGetStandIn -Body '[Environment]::Exit(3)'
        { $null = Write-DiagnosticModuleSnapshot -TimeoutSeconds 60 } | Should -Throw '*exit 3*'
    }

    It 'keeps its default deadline short enough for the sections after it' {
        # A guest's report runs inside the guest diagnostic's per-command SSH
        # budget of 60 seconds ($script:SaveGuestDiagnosticPerCommandTimeoutSeconds
        # in Test.Diagnostic.psm1). A slow guest has reached this section more
        # than 45 seconds into that budget, and the project section, the problem
        # list and its JSON summary still have to print after it, so the child
        # gets at most five seconds.
        $script:SnapshotDefaultSeconds | Should -BeGreaterThan 0
        $script:SnapshotDefaultSeconds | Should -BeLessOrEqual 5
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

    It 'reads the previous boot through its bounded reader, never whole' {
        $body = Get-SectionBody -Title 'INSTALL & EARLY-BOOT TIMELINE (Linux)'
        $body | Should -Match '\bWrite-LinuxPreviousBootWarning\b'
        $body | Should -Not -Match "'-b',\s*'-1'"
    }

    It 'takes the module snapshot through its bounded child process' {
        $body = Get-SectionBody -Title 'GUEST PROVISIONING (Linux)'
        $body | Should -Match '\bWrite-DiagnosticModuleSnapshot\b'
        $body | Should -Not -Match '\bGet-PSRepository\b|\bGet-PackageProvider\b'
    }

    It 'finishes the report when the previous boot''s journal is huge and the module snapshot hangs' -Skip:(-not $IsLinux) {
        $definition = Get-YurunaTestFunctionAst -Path $script:DiagPath -Name 'Invoke-DiagnosticBoundedCommand'
        . ([scriptblock]::Create($definition.Extent.Text))
        $solo = Join-Path $TestDrive 'huge-solo'
        $bin = Join-Path $TestDrive 'huge-bin'
        $data = Join-Path $TestDrive 'huge-data'
        $module = Join-Path $data 'powershell/Modules/PowerShellGet'
        $null = New-Item -ItemType Directory -Path $solo, $bin, $module
        $copy = Join-Path $solo 'Get-SystemDiagnostic.ps1'
        Copy-Item -LiteralPath $script:DiagPath -Destination $copy
        # The child the snapshot starts finds this PowerShellGet first; the
        # report's own process never loads it.
        [IO.File]::WriteAllText((Join-Path $module 'PowerShellGet.psm1'),
            "function Get-PSRepository { [Threading.Thread]::Sleep(600000) }`nExport-ModuleMember -Function Get-PSRepository`n")
        $stub = @{
            'sudo' = "#!/bin/sh`nexit 1`n"
            'docker' = "#!/bin/sh`nexit 1`n"
            # A previous boot of two million warnings, the newest 60 of it
            # for -n 60, and an empty journal for every other query. Finite,
            # so a report that read the whole boot would finish, slowly, and
            # fail on its content rather than run the host out of memory.
            'journalctl' = @'
#!/bin/sh
case " $* " in
  *" -b -1 "*" -n 60 "*) seq -f 'Nov 01 00:00:00 fixture kernel: huge warning %.0f' 1999941 2000000 ;;
  *" -b -1 "*) seq -f 'Nov 01 00:00:00 fixture kernel: huge warning %.0f' 1 2000000 ;;
esac
exit 0
'@
        }
        foreach ($name in $stub.Keys) {
            $path = Join-Path $bin $name
            [IO.File]::WriteAllText($path, $stub[$name].Replace("`r`n", "`n"))
            & chmod +x $path
        }
        $saved = Save-YurunaTestEnvironment -Name 'PATH', 'XDG_DATA_HOME'
        try {
            $env:PATH = $bin + [IO.Path]::PathSeparator + $saved.PATH
            $env:XDG_DATA_HOME = $data
            $run = Invoke-DiagnosticBoundedCommand -FilePath (Get-Process -Id $PID).Path -TimeoutSeconds 300 -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-File', $copy, '-SkipDocker', '-SkipKube', '-SkipProjectGaps',
                '-CheckoutRoot', (Join-Path $TestDrive 'no-checkout'))
        } finally { Restore-YurunaTestEnvironment -Saved $saved }

        $run.TimedOut | Should -BeFalse
        $run.ExitCode | Should -Be 0 -Because $run.StdErr
        $run.StdOut | Should -Match '(?m)^Nov 01 00:00:00 fixture kernel: huge warning 1$'
        $run.StdOut | Should -Match '(?m)^Nov 01 00:00:00 fixture kernel: huge warning 2000000$'
        $run.StdOut | Should -Not -Match '(?m)huge warning 61$'
        $run.StdOut | Should -Match ([regex]::Escape('middle lines skipped without counting them'))
        $stopped = '(pwsh Get-PSRepository; Get-PackageProvider -ListAvailable did not finish within 5s and was stopped'
        $run.StdOut | Should -Match ([regex]::Escape($stopped) + '.*\r?\n--- Modules \(PowerShellGet, PSResourceGet, powershell-yaml\) ---\r?\n')
        $run.StdOut | Should -Match '(?m)^Diagnostics complete\.\s*$'
        $summary = [regex]::Match($run.StdOut, '(?ms)^===YURUNA-DIAG-JSON-BEGIN===\r?\n(.*?)\r?\n===YURUNA-DIAG-JSON-END===')
        $summary.Success | Should -BeTrue
        $problems = $summary.Groups[1].Value | ConvertFrom-Json -AsHashtable
        $problems.byClass['DIAG.probe-timeout'] | Should -Be 1
        $problems.byClass.Keys | Should -Not -Contain 'DIAG.section-aborted'
    }
}
