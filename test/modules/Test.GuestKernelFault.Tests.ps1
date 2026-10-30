<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42b6c1f4-8e37-4d2a-9a51-7f0c3e6d2b84
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic kernel serial lockup pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    The guest kernel's own reports reach the failure record: the serial
    console and the recorder's frozen first stall are read for lockups,
    stalls, hung tasks, oopses and panics, and nothing else is; the console's
    timestamps are read for a clock that jumped past the VM's age.
.DESCRIPTION
    A guest whose kernel wedges stops answering everything the harness asks,
    so the step that waits on it fails as a plain timeout. The kernel said why
    on its serial console, which also carries every journal line journald
    forwards there -- script text included -- so the reader has to tell a
    kernel report from text that merely quotes one. A clock that jumps by days
    and stays there can break the guest with no kernel report at all, and then
    only the timestamps show it.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

    $script:GluedTwoBoots = @(
        '[    6.774553] systemd[1]: Queued start job for default target graphical.target.'
        '[    7.385305] systemd[1]: Starting systemd-journal-flush.service - Flush Journal to Persistent Storage...[    7.395512] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
        "[    7.401008] rcu: `tTasks blocked on level-0 rcu_node (CPUs 0-0): P565/1:b..l"
        "[    7.407190] rcu: `t(detected by 0, t=225240047 jiffies, g=10125, q=42 ncpus=1)"
        "[    7.413608] rcu: rcu_preempt kthread timer wakeup didn't happen for 225240044 jiffies! g10125 f0x0 RCU_GP_WAIT_FQS(5) ->state=0x402"
        '[    7.429656] rcu: rcu_preempt kthread starved for 225240047 jiffies! g10125 f0x0 RCU_GP_WAIT_FQS(5) ->state=0x402 ->cpu=0'
        '[  275.387810] multipathd[568]: _check_bindings_file: failed to read header from /etc/multipath/bindings'
        '[    7.079999] systemd[1]: Queued start job for default target graphical.target.'
        '[    7.802490] systemd[1]: Finished systemd-random-seed.service - Load/Save OS Random Seed.'
    ) -join "`r`n"

    $script:StallWithoutJump = @(
        '[ 1024.695000] sudo[42501]: pam_unix(sudo:session): session closed for user root'
        '[ 1048.406652] watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [.NET TP Worker:42440]'
        '[ 1072.406560] watchdog: BUG: soft lockup - CPU#1 stuck for 44s! [.NET TP Worker:42440]'
        '[ 1084.679511] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
        "[ 1084.699812] rcu: `t0-...!: (1 GPs behind) idle=e2b4/1/0x4000000000000000 softirq=148313/148321 fqs=4"
        "[ 1084.708643] rcu: `t(detected by 1, t=60003 jiffies, g=305189, q=142 ncpus=2)"
        '[ 1094.709679] rcu: rcu_preempt kthread starved for 59983 jiffies! g305189 f0x0 RCU_GP_WAIT_FQS(5) ->state=0x0 ->cpu=1'
        '[ 1120.406374] watchdog: BUG: soft lockup - CPU#1 stuck for 89s! [.NET TP Worker:42440]'
    ) -join "`n"

    $script:JumpAndGrowingLockup = @(
        '[  973.787444] sudo[41196]: pam_unix(sudo:session): session closed for user root'
        '[  993.037944] watchdog: BUG: soft lockup - CPU#0 stuck for 26s! [swapper/0:0]'
        '[  996.237888] rcu: INFO: rcu_preempt self-detected stall on CPU'
        "[  996.250306] rcu: `t0-...!: (100416457 ticks this GP) idle=49ac/1/0x4000000000000002 softirq=138502/138504 fqs=2682"
        "[  996.260949] rcu: `t(t=263625318 jiffies g=285757 q=3185 ncpus=2)"
        '[  996.267271] rcu: rcu_preempt kthread starved for 263614533 jiffies! g285757 f0x0 RCU_GP_WAIT_FQS(5) ->state=0x0 ->cpu=1'
        '[ 1001.044882] watchdog: BUG: soft lockup - CPU#1 stuck for 23s! [kworker/1:2:69]'
        '[ 1029.042092] watchdog: BUG: soft lockup - CPU#1 stuck for 23s! [etcd:33180]'
        '[ 1053.041906] watchdog: BUG: soft lockup - CPU#1 stuck for 45s! [etcd:33180]'
    ) -join "`n"

    # A jump that stays: journald's console lines leap by days and run on from
    # there, systemd's watchdogs fire at once, lines arrive out of order, and
    # the kernel itself reports nothing.
    $script:PersistentJump = @(
        '[  272.914121] sudo[20799]: pam_unix(sudo:session): session opened for user root(uid=0) by yuuser26(uid=1000)'
        '[  272.970974] systemd[1]: systemd-networkd.service: Watchdog timeout (limit 3min)!'
        '[303719.831129] systemd[1386]: launchpadlib-cache-clean.service - Clean up old files in the Launchpadlib cache skipped'
        "[303719.889270] systemd[1]: `e[0;1;31msystemd-logind.service: Watchdog timeout (limit 3min)!`e[0m"
        "[303720.141667] systemd[1]: `e[0;1;31msystemd-journald.service: Watchdog timeout (limit 3min)!`e[0m"
        '[303916.212511] systemd[1]: packagekit.service: Processes still around after SIGKILL. Ignoring.'
        '[304746.606512] systemd[1]: Finished yuruna-host-locate.service - Refresh Yuruna host coordinates if the host has changed address.'
        '[304228.106631] sshd-session[22574]: Connection closed by 192.168.7.49 port 54874'
        '[304473.149784] sudo[3318]: pam_unix(sudo:session): session closed for user root'
    ) -join "`r`n"

    # Forwarded journal lines and a kernel record that only look like reports.
    $script:QuotedReports = @(
        '[  120.000001] powershell[40780]: foreach ($item in $loops) { ''Oops'' }'
        '[  120.000002] powershell[40780]: watchdog: BUG: soft lockup - CPU#0 stuck for 22s! [etcd:1]'
        '[  120.000003] dockerd[13134]: level=info msg="rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:"'
        '[  120.000004] kernel-tests[77]: Kernel panic - not syncing: quoted by a test'
        '[  120.000005] systemd[1]: Started oops-reporter.service - Oops Reporter.'
        '[  120.000006] Oopsie: an unrelated kernel driver name'
        'a line with no timestamp: watchdog: BUG: soft lockup - CPU#3 stuck for 99s! [x:1]'
    ) -join "`n"

    # journalctl -o short-monotonic samples that overlap, as the recorder keeps them.
    $script:RecorderSection = @(
        '--- first observed kernel stall ---'
        'kernelFirstStallAdvisoryOnly=true'
        'kernelFirstStallUtc=2026-10-27T10:00:00.000000000Z'
        '[  899.000001] yuhost26 kernel: hv_balloon: Received INFO_TYPE_MAX_PAGE_CNT'
        '[  900.100000] yuhost26 kernel: watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [etcd:33180]'
        '[  900.200000] yuhost26 kernel: rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
        ''
        '--- following kernel sample ---'
        '[  899.000001] yuhost26 kernel: hv_balloon: Received INFO_TYPE_MAX_PAGE_CNT'
        '[  900.100000] yuhost26 kernel: watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [etcd:33180]'
        '[  900.200000] yuhost26 kernel: rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
        '[  924.100000] yuhost26 kernel: watchdog: BUG: soft lockup - CPU#1 stuck for 44s! [etcd:33180]'
    ) -join "`n"
}

Describe 'Kernel reports read from serial console text' {
    It 'splits a journal line and a kernel report that share a line, and attributes faults to their boot' {
        $reading = ConvertFrom-GuestKernelFaultText -Text $script:GluedTwoBoots -Source serial
        $reading.boots | Should -Be 2
        $reading.faultRecords | Should -Be 3
        @($reading.kinds) | Should -Be @('rcu-kthread-starved', 'rcu-stall', 'rcu-timer-wakeup-missed')
        $reading.firstFault.boot | Should -Be 1
        $reading.firstFault.kind | Should -Be 'rcu-stall'
        $reading.firstFault.uptimeSeconds | Should -Be 7.396
        $reading.lastNormalRecordUptimeSeconds | Should -Be 7.385 -Because 'the journal record glued before the report is the last normal one'
        $reading.newestRecordUptimeSeconds | Should -Be 7.802 -Because 'the newest record is read in the newest boot'
        $reading.largestStallJiffies | Should -Be 225240047
        @($reading.rcuStalledCpus).Count | Should -Be 0 -Because 'a blocked-tasks line names no stalled CPU'
    }

    It 'reads a stall without a clock jump and a lockup that keeps growing on one CPU' {
        $reading = ConvertFrom-GuestKernelFaultText -Text $script:StallWithoutJump
        $reading.boots | Should -Be 1
        @($reading.kinds) | Should -Be @('rcu-kthread-starved', 'rcu-stall', 'soft-lockup')
        @($reading.softLockups).Count | Should -Be 1
        $lockup = $reading.softLockups[0]
        $lockup.cpu | Should -Be 1
        $lockup.reports | Should -Be 3
        $lockup.longestStuckSeconds | Should -Be 89
        $lockup.task | Should -Be '.NET TP Worker'
        $lockup.pid | Should -Be 42440
        @($reading.rcuStalledCpus) | Should -Be @(0)
        $reading.largestStallJiffies | Should -Be 60003
        $reading.lastNormalRecordUptimeSeconds | Should -Be 1024.695
    }

    It 'keeps a jiffies count far beyond the uptime and names the task each CPU was stuck in last' {
        $reading = ConvertFrom-GuestKernelFaultText -Text $script:JumpAndGrowingLockup
        $reading.firstFault.kind | Should -Be 'soft-lockup'
        $reading.firstFault.uptimeSeconds | Should -Be 993.038
        $reading.lastNormalRecordUptimeSeconds | Should -Be 973.787
        $reading.largestStallJiffies | Should -Be 263625318 -Because 'the reading keeps the raw count; the clock jump is the reader''s inference'
        $cpu0 = $reading.softLockups | Where-Object cpu -EQ 0
        $cpu1 = $reading.softLockups | Where-Object cpu -EQ 1
        $cpu0.task | Should -Be 'swapper/0'
        $cpu1.reports | Should -Be 3
        $cpu1.longestStuckSeconds | Should -Be 45
        $cpu1.task | Should -Be 'etcd' -Because 'the newest report names the task the CPU was stuck in last'
        $cpu1.pid | Should -Be 33180
        $cpu1.lastStuckSeconds | Should -Be 45
        $reading.lastFault.uptimeSeconds | Should -Be 1053.042
    }

    It 'keeps the longest count apart from the newest report when one CPU locks up twice' {
        $text = @(
            '[  400.000000] watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [dockerd:5]'
            '[  500.000000] watchdog: BUG: soft lockup - CPU#1 stuck for 120s! [dockerd:5]'
            '[  900.000000] watchdog: BUG: soft lockup - CPU#1 stuck for 23s! [etcd:7]'
        ) -join "`n"
        $lockup = (ConvertFrom-GuestKernelFaultText -Text $text).softLockups[0]
        $lockup.longestStuckSeconds | Should -Be 120
        $lockup.lastStuckSeconds | Should -Be 23 -Because 'task, pid and the last count all come from the newest report'
        $lockup.task | Should -Be 'etcd'
    }

    It 'reads quoted journalctl output in console text as a quote, and the same line as a record in journal text' {
        $quoted = @(
            '[  993.000000] yuhost26 kernel: watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [etcd:1]'
            '[  994.000000] sudo[1]: pam_unix(sudo:session): session closed for user root'
        ) -join "`n"
        (ConvertFrom-GuestKernelFaultText -Text $quoted -Source serial).faultRecords | Should -Be 0 -Because 'journald never forwards kernel records to the console'
        @((ConvertFrom-GuestKernelFaultText -Text $quoted -Source recorder).kinds) | Should -Be @('soft-lockup')
    }

    It 'starts a new boot after a reboot or panic record, however short the boot was' {
        $rebooted = @(
            '[    3.000000] systemd[1]: Started journald.'
            '[   20.000000] reboot: Restarting system'
            '[    5.000000] systemd[1]: Started journald.'
        ) -join "`n"
        (ConvertFrom-GuestKernelFaultText -Text $rebooted).boots | Should -Be 2
        $panicked = @(
            '[   19.000000] systemd[1]: Started journald.'
            '[   20.000000] Kernel panic - not syncing: Fatal exception'
            '[   10.000000] systemd[1]: Started journald.'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $panicked
        $reading.boots | Should -Be 2
        $reading.lastNormalRecordUptimeSeconds | Should -Be 19 -Because 'the next boot''s records are not the panicking boot''s'
        $reading.newestRecordUptimeSeconds | Should -Be 10
    }

    It 'never reads forwarded journal text or a lookalike kernel record as a fault' {
        $reading = ConvertFrom-GuestKernelFaultText -Text $script:QuotedReports
        $reading.records | Should -Be 6 -Because 'a line without a timestamp is no record'
        $reading.kernelRecords | Should -Be 1
        $reading.faultRecords | Should -Be 0
        @($reading.kinds).Count | Should -Be 0
        $reading.firstFault | Should -BeNullOrEmpty
        $reading.lastNormalRecordUptimeSeconds | Should -BeNullOrEmpty
    }

    It 'keeps a stuck count past any 32-bit integer, which a clock stepping back makes the kernel print' {
        $text = @(
            '[  272.970974] systemd[1]: systemd-networkd.service: Watchdog timeout (limit 3min)!'
            '[  280.000000] watchdog: BUG: soft lockup - CPU#1 stuck for 4294967282s! [kworker/1:2:69]'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text
        @($reading.kinds) | Should -Be @('soft-lockup') -Because 'a wrapped count must not lose the whole reading'
        $reading.softLockups[0].longestStuckSeconds | Should -Be 4294967282
    }

    It 'opens a new boot where a reset leaves no reboot record and the next boot speaks first in kernel records' {
        $text = @(
            '[  272.914121] sudo[20799]: pam_unix(sudo:session): session opened for user root(uid=0) by yuuser26(uid=1000)'
            '[  300.000000] systemd[1]: Started cron.service.'
            '[    6.512000] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
            '[    7.079999] systemd[1]: Queued start job for default target graphical.target.'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text
        $reading.boots | Should -Be 2
        $reading.firstFault.boot | Should -Be 2 -Because 'the first kernel record of a boot that falls to an early timestamp belongs to the next boot'
    }

    It 'keeps a panic''s own trailer in its boot when the journal''s clock leapt past it' {
        $text = @(
            '[  537.070054] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
            '[548013.818189] chronyd[1132]: Forward time jump detected!'
            '[548014.048480] systemd[1]: systemd-udevd.service: Watchdog timeout (limit 3min)!'
            '[  610.000000] Kernel panic - not syncing: Fatal exception'
            '[  610.000500] SMP: stopping secondary CPUs'
            '[  610.001000] ---[ end Kernel panic - not syncing: Fatal exception ]---'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text
        $reading.boots | Should -Be 1 -Because 'only a timestamp earlier than the panic record itself starts the next boot'
        $reading.newestRecordUptimeSeconds | Should -Be 548014.048
    }

    It 'recognizes hung tasks, oopses, panics and hard lockups' {
        $text = @(
            '[  500.000001] INFO: task kworker/0:1:123 blocked for more than 122 seconds.'
            '[  500.000002] Internal error: Oops: 0000000096000005 [#1] PREEMPT SMP'
            '[  500.000003] Kernel panic - not syncing: Fatal exception'
            '[  500.000004] watchdog: CPU1: Watchdog detected hard LOCKUP on cpu 0'
        ) -join "`n"
        @((ConvertFrom-GuestKernelFaultText -Text $text).kinds) | Should -Be @('hard-lockup', 'hung-task', 'oops', 'panic')
    }

    It 'answers not measured for text with no timestamped record' {
        ConvertFrom-GuestKernelFaultText -Text '' | Should -BeNullOrEmpty
        ConvertFrom-GuestKernelFaultText -Text 'no records here' | Should -BeNullOrEmpty
    }
}

Describe 'A guest clock that jumped, read from the console''s timestamps' {
    It 'measures the newest boot''s largest leap and judges no clock without a limit' {
        $reading = ConvertFrom-GuestKernelFaultText -Text $script:PersistentJump
        $reading.kernelRecords | Should -Be 0 -Because 'this console held journal lines only'
        @($reading.kinds).Count | Should -Be 0
        $reading.largestForwardLeap.boot | Should -Be 1
        $reading.largestForwardLeap.recordKind | Should -Be 'forwarded'
        $reading.largestForwardLeap.fromUptimeSeconds | Should -Be 272.971
        $reading.largestForwardLeap.toUptimeSeconds | Should -Be 303719.831
        $reading.largestForwardLeap.seconds | Should -Be 303446.86
        $reading.newestRecordUptimeSeconds | Should -Be 304746.607
        $reading.uptimeLimitSeconds | Should -BeNullOrEmpty
        $reading.clockJump | Should -BeNullOrEmpty
    }

    It 'names a clock jump when a timestamp runs past the longest any boot can have run' {
        $reading = ConvertFrom-GuestKernelFaultText -Text $script:PersistentJump -UptimeLimitSeconds 2694
        @($reading.kinds) | Should -Be @('clock-jump')
        $reading.faultRecords | Should -Be 0 -Because 'the jump is read from the timestamps, not from a report'
        $reading.firstFault | Should -BeNullOrEmpty
        $reading.uptimeLimitSeconds | Should -Be 2694
        $reading.clockJump.boot | Should -Be 1
        $reading.clockJump.uptimeSeconds | Should -Be 304746.607
        $reading.clockJump.minimumJumpSeconds | Should -Be 302052.607 -Because 'the least the clock jumped is how far it ran past the limit'
    }

    It 'judges the largest timestamp against the limit and a minute more: <Case>' -ForEach @(
        @{ Case = 'a long console silence that fits the boot'; Limit = 1400; Jump = $false }
        @{ Case = 'fifty seconds past, inside the margin'; Limit = 1250; Jump = $false }
        @{ Case = 'a hundred seconds past'; Limit = 1200; Jump = $true }
        @{ Case = 'no positive limit'; Limit = 0; Jump = $false }
    ) {
        $text = "[  100.000000] systemd[1]: Started journald.`n[ 1300.000000] sudo[7]: pam_unix(sudo:session): session closed for user root"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text -UptimeLimitSeconds $Limit
        $reading.largestForwardLeap.seconds | Should -Be 1200
        (@($reading.kinds) -contains 'clock-jump') | Should -Be $Jump
        if ($Limit -le 0) { $reading.uptimeLimitSeconds | Should -BeNullOrEmpty -Because 'no clock was judged' }
    }

    It 'measures a leap from the largest timestamp before it, so a record flushed late starts none' {
        $text = @(
            '[  100.000000] systemd[1]: Started journald.'
            '[  500.000000] systemd[1]: Started cron.service.'
            '[  300.000000] sshd[9]: a line the console flushed late'
            '[  750.000000] systemd[1]: Started polkit.service.'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text
        $reading.boots | Should -Be 1
        $reading.largestForwardLeap.fromUptimeSeconds | Should -Be 100
        $reading.largestForwardLeap.toUptimeSeconds | Should -Be 500
        $reading.largestForwardLeap.seconds | Should -Be 400 -Because 'the late line at 300 s starts no leap to the line at 750 s'
    }

    It 'reads kernel records and forwarded journal lines on their own clocks when a jump moves only one' {
        # journald's clock leapt and stayed there; the kernel's RCU reports
        # kept printk's timestamps, glued to and between the leapt lines.
        $text = @(
            '[  533.395556] sudo[21923]: pam_unix(sudo:session): session opened for user root(uid=0) by yuuser26(uid=1000)'
            '[  533.450456] sudo[21923]: pam_unix(sudo:session): session closed for user root'
            '[  537.070054] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
            "[  537.076343] rcu: `t(detected by 1, t=546479175 jiffies, g=146989, q=37 ncpus=2)"
            '[548013.818189] chronyd[1132]: Forward time jump detected![  537.113620] rcu: rcu_preempt kthread starved for 546479174 jiffies! g146989 f0x2 RCU_GP_WAIT_FQS(5) ->state=0x200 ->cpu=1'
            '[  537.136308] rcu: RCU grace-period kthread stack dump:'
            '[548014.048480] systemd[1]: systemd-udevd.service: Watchdog timeout (limit 3min)!'
            '[548014.070146] systemd[1]: systemd-networkd.service: Watchdog timeout (limit 3min)!'
            '[  604.289652] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text -UptimeLimitSeconds 3030
        $reading.boots | Should -Be 1 -Because 'a kernel record behind a leapt journal line is the same boot'
        $reading.faultRecords | Should -Be 3
        $reading.firstFault.boot | Should -Be 1
        $reading.lastFault.uptimeSeconds | Should -Be 604.29
        $reading.largestStallJiffies | Should -Be 546479175
        $reading.largestForwardLeap.recordKind | Should -Be 'forwarded'
        $reading.largestForwardLeap.fromUptimeSeconds | Should -Be 533.45
        $reading.largestForwardLeap.seconds | Should -Be 547480.368
        @($reading.kinds) | Should -Contain 'clock-jump'
        $reading.clockJump.uptimeSeconds | Should -Be 548014.07
    }

    It 'measures a jump into the first kernel record of a boot from the journal line before it' {
        # One processor's printk clock leapt and the journal's did not, and
        # that processor's report is the boot's first kernel record.
        $text = @(
            '[  238.385210] systemd[1]: Starting sysstat-collect.service - system activity accounting tool...'
            '[  270.012041] chronyd[1123]: Backward time jump detected!'
            '[12023.455204] watchdog: BUG: soft lockup - CPU#1 stuck for 10948s! [khugepaged:38]'
            '[  272.798243] rsyslogd[1091]: rsyslogd: get tty for session ''4'' failed with [61]:No data available'
            '[12031.047120] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text -UptimeLimitSeconds 3600
        $reading.boots | Should -Be 1
        $reading.largestForwardLeap.recordKind | Should -Be 'kernel'
        $reading.largestForwardLeap.fromUptimeSeconds | Should -Be 270.012
        $reading.largestForwardLeap.seconds | Should -Be 11753.443
        @($reading.kinds) | Should -Contain 'clock-jump'
    }

    It 'judges every boot in the text against the limit, and measures the leap in the newest boot' {
        $text = @(
            '[   50.000000] systemd[1]: Started journald.'
            '[90050.000000] systemd[1]: systemd-journald.service: Watchdog timeout (limit 3min)!'
            '[90060.000000] reboot: Restarting system'
            '[    5.000000] systemd[1]: Started journald.'
            '[   30.000000] systemd[1]: Started cron.service.'
        ) -join "`n"
        $reading = ConvertFrom-GuestKernelFaultText -Text $text -UptimeLimitSeconds 600
        $reading.boots | Should -Be 2
        @($reading.kinds) | Should -Be @('clock-jump')
        $reading.clockJump.boot | Should -Be 1 -Because 'the VM''s age bounds every boot it had, not only the newest'
        $reading.clockJump.uptimeSeconds | Should -Be 90060
        $reading.largestForwardLeap.boot | Should -Be 2
        $reading.largestForwardLeap.seconds | Should -Be 25
    }
}

Describe 'Kernel reports read from the recorder''s journal samples' {
    It 'reads overlapping short-monotonic samples once each, as one boot' {
        $reading = ConvertFrom-GuestKernelFaultText -Text $script:RecorderSection -Source recorder
        $reading.source | Should -Be 'recorder'
        $reading.boots | Should -Be 1 -Because 'the samples overlap, which is not a reboot'
        $reading.faultRecords | Should -Be 3
        $reading.softLockups[0].reports | Should -Be 2
        $reading.softLockups[0].longestStuckSeconds | Should -Be 44
        $reading.lastNormalRecordUptimeSeconds | Should -Be 899.0
    }

    It 'finds the frozen first stall in a retained upload, and nothing in one without it' {
        $upload = Join-Path $TestDrive 'execution.system.diagnostic.step.txt'
        Set-Content -LiteralPath $upload -Encoding utf8NoBOM -Value @(
            'kernelUploadSchema=1'
            '--- independent kernel evidence ---'
            '[  880.000000] yuhost26 kernel: watchdog: BUG: soft lockup - CPU#0 stuck for 22s! [ring:1]'
            ''
            $script:RecorderSection
        )
        $reading = Get-GuestRecorderKernelStall -Path $upload
        $reading.source | Should -Be 'recorder'
        $reading.firstFault.uptimeSeconds | Should -Be 900.1 -Because 'only the frozen section is read, not the rotating ring'
        $reading.firstStallSampleIndex | Should -BeNullOrEmpty
        $reading.mayPredateStep | Should -BeTrue -Because 'an unnamed sample may be the first one'

        $plain = Join-Path $TestDrive 'execution.system.diagnostic.other.txt'
        Set-Content -LiteralPath $plain -Encoding utf8NoBOM -Value @('kernelUploadSchema=1', '--- independent kernel evidence ---')
        Get-GuestRecorderKernelStall -Path $plain | Should -BeNullOrEmpty
        Get-GuestRecorderKernelStall -Path (Join-Path $TestDrive 'absent.txt') | Should -BeNullOrEmpty
    }

    It 'says a stall frozen from the recorder''s first sample may predate the step, and one from a later sample does not' -ForEach @(
        @{ Index = 0; MayPredate = $true }
        @{ Index = 3; MayPredate = $false }
    ) {
        $upload = Join-Path $TestDrive "execution.system.diagnostic.index$Index.txt"
        Set-Content -LiteralPath $upload -Encoding utf8NoBOM -Value @(
            'kernelUploadSchema=1'
            '--- first observed kernel stall ---'
            'kernelFirstStallAdvisoryOnly=true'
            "kernelFirstStallSampleIndex=$Index"
            '[  900.100000] yuhost26 kernel: watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [etcd:33180]'
        )
        $reading = Get-GuestRecorderKernelStall -Path $upload
        $reading.firstStallSampleIndex | Should -Be $Index
        $reading.mayPredateStep | Should -Be $MayPredate
    }
}

Describe 'A failed step reads the kernel''s reports from its own start' {
    BeforeAll {
        # The Hyper-V driver's accessor, scripted per example inside the engine.
        . (Get-Module Test.SequenceEngine) {
            function Read-VMSerialCapture {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                param([string]$VMName, [long]$FromOffset = 0, [int]$MaxBytes = 4194304)
                $script:SerialProbe.Calls += @(,@{ FromOffset = $FromOffset; MaxBytes = $MaxBytes })
                if ($script:SerialProbe.Throw) { throw 'pipe gone' }
                return $script:SerialProbe.Capture
            }
            function Set-SerialProbe {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory probe; no external state.')]
                param($Capture, [switch]$Throw)
                $script:SerialProbe = @{ Capture = $Capture; Throw = [bool]$Throw; Calls = @() }
            }
            function Get-SerialProbeCall { return $script:SerialProbe.Calls }
            # The driver's creation time, $null unless an example scripts one.
            function Get-VMCreationTime {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                param([string]$VMName)
                if ($script:CreationProbe.Throw) { throw 'VMMS unreachable' }
                return $script:CreationProbe.Created
            }
            function Set-CreationProbe {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory probe; no external state.')]
                param($Created, [switch]$Throw)
                $script:CreationProbe = @{ Created = $Created; Throw = [bool]$Throw }
            }
            Set-CreationProbe -Created $null
        }
    }
    AfterAll {
        . (Get-Module Test.SequenceEngine) {
            Remove-Item -LiteralPath function:\Read-VMSerialCapture, function:\Set-SerialProbe, function:\Get-SerialProbeCall,
                function:\Get-VMCreationTime, function:\Set-CreationProbe -ErrorAction SilentlyContinue
        }
    }

    It 'marks where the console ends as the step starts' {
        & (Get-Module Test.SequenceEngine) { Set-SerialProbe -Capture ([pscustomobject]@{ Length = 1234L; Offset = 1234L; Text = ''; Truncated = $false }) }
        $mark = & (Get-Module Test.SequenceEngine) { Get-StepSerialLogMark -VMName 'vm-01' }
        $mark | Should -Be 1234
        $calls = @(& (Get-Module Test.SequenceEngine) { Get-SerialProbeCall })
        $calls[0].MaxBytes | Should -Be 0 -Because 'the mark reads the length only'
    }

    It 'reads the console from the mark and keeps how much it read' {
        $capture = [pscustomobject]@{ Length = 9000L; Offset = 5000L; Text = $script:JumpAndGrowingLockup; Truncated = $true; Replaced = $false }
        & (Get-Module Test.SequenceEngine) { param($c) Set-SerialProbe -Capture $c } $capture
        $reading = & (Get-Module Test.SequenceEngine) { Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark 4000 -StepInvocationId 'leaf' }
        $reading.stepInvocationId | Should -Be 'leaf'
        $reading.serial.faultRecords | Should -BeGreaterThan 0
        $reading.serial.bytesRead | Should -Be 4000
        $reading.serial.truncated | Should -BeTrue
        $reading.serial.replaced | Should -BeFalse
        $reading.recorder | Should -BeNullOrEmpty
        @(& (Get-Module Test.SequenceEngine) { Get-SerialProbeCall })[0].FromOffset | Should -Be 4000
    }

    It 'says when the capture was replaced after the mark, so a clean reading does not clear the step' {
        $capture = [pscustomobject]@{ Length = 120L; Offset = 0L; Text = '[    1.000000] systemd[1]: Started journald.'; Truncated = $false; Replaced = $true }
        & (Get-Module Test.SequenceEngine) { param($c) Set-SerialProbe -Capture $c } $capture
        $reading = & (Get-Module Test.SequenceEngine) { Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark 9000 -StepInvocationId 'wrapper' }
        $reading.serial.faultRecords | Should -Be 0
        $reading.serial.replaced | Should -BeTrue
    }

    It 'keeps a console that was read and held no report, apart from one never read' {
        & (Get-Module Test.SequenceEngine) { Set-SerialProbe -Capture ([pscustomobject]@{ Length = 10L; Offset = 10L; Text = ''; Truncated = $false }) }
        $reading = & (Get-Module Test.SequenceEngine) { Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark 10 -StepInvocationId 's' }
        $reading.serial.faultRecords | Should -Be 0
        $reading.serial.records | Should -Be 0
        @($reading.serial.kinds).Count | Should -Be 0
    }

    It 'takes the recorder''s frozen stall without a console, and answers $null with neither' {
        $recorderReading = ConvertFrom-GuestKernelFaultText -Text $script:RecorderSection -Source recorder
        $executionProfile = @{ recorder = @{ kernelStall = $recorderReading } }
        $reading = & (Get-Module Test.SequenceEngine) { param($p) Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark $null -ExecutionProfile $p -StepInvocationId 's' } $executionProfile
        $reading.serial | Should -BeNullOrEmpty
        $reading.recorder.source | Should -Be 'recorder'
        & (Get-Module Test.SequenceEngine) { Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark $null -StepInvocationId 's' } | Should -BeNullOrEmpty
    }

    It 'never lets an unreadable console fail the step it describes' {
        & (Get-Module Test.SequenceEngine) { Set-SerialProbe -Capture $null -Throw }
        { & (Get-Module Test.SequenceEngine) { Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark 0 -StepInvocationId 's' } } | Should -Not -Throw
        & (Get-Module Test.SequenceEngine) { Get-StepSerialLogMark -VMName 'vm-01' } | Should -BeNullOrEmpty
    }

    It 'names a clock jump when the console runs past the time since the VM was created' {
        $capture = [pscustomobject]@{ Length = 2000L; Offset = 100L; Text = $script:PersistentJump; Truncated = $false; Replaced = $false }
        & (Get-Module Test.SequenceEngine) { param($c) Set-SerialProbe -Capture $c; Set-CreationProbe -Created ([DateTime]::UtcNow.AddSeconds(-2694)) } $capture
        try {
            $reading = & (Get-Module Test.SequenceEngine) { Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark 100 -StepInvocationId 'leaf' }
        } finally { & (Get-Module Test.SequenceEngine) { Set-CreationProbe -Created $null } }
        @($reading.serial.kinds) | Should -Be @('clock-jump')
        $reading.serial.uptimeLimitSeconds | Should -BeGreaterOrEqual 2694
        $reading.serial.uptimeLimitSeconds | Should -BeLessThan 2754 -Because 'the VM''s age is taken as the console is read'
        $reading.serial.clockJump.minimumJumpSeconds | Should -BeGreaterThan 301990
        $reading.serial.largestForwardLeap.seconds | Should -Be 303446.86
    }

    It 'judges no clock when the host names no creation time it could have: <Case>' -ForEach @(
        @{ Case = 'none'; Created = 'none'; Throw = $false }
        @{ Case = 'one in the future'; Created = 'future'; Throw = $false }
        @{ Case = 'an unreadable host'; Created = 'none'; Throw = $true }
    ) {
        $capture = [pscustomobject]@{ Length = 2000L; Offset = 100L; Text = $script:PersistentJump; Truncated = $false; Replaced = $false }
        $when = if ($Created -eq 'future') { [DateTime]::UtcNow.AddHours(1) } else { $null }
        & (Get-Module Test.SequenceEngine) { param($c, $t, $fail) Set-SerialProbe -Capture $c; Set-CreationProbe -Created $t -Throw:$fail } $capture $when $Throw
        try {
            $reading = & (Get-Module Test.SequenceEngine) { Get-StepGuestKernelFault -VMName 'vm-01' -SerialMark 100 -StepInvocationId 'leaf' }
        } finally { & (Get-Module Test.SequenceEngine) { Set-CreationProbe -Created $null } }
        @($reading.serial.kinds).Count | Should -Be 0
        $reading.serial.uptimeLimitSeconds | Should -BeNullOrEmpty
        $reading.serial.largestForwardLeap.seconds | Should -Be 303446.86 -Because 'the leap is a fact of the text, judged or not'
    }
}

Describe 'The saved serial log is read again once the capture closes' {
    BeforeAll {
        $runnerPath = Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-SerialConsoleKernelFault' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    It 'writes the reading of every boot beside the saved log' {
        $folder = Join-Path $TestDrive 'failure'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Set-Content -LiteralPath (Join-Path $folder 'serial-console.log') -Value $script:GluedTwoBoots -Encoding utf8NoBOM -NoNewline
        Save-SerialConsoleKernelFault -OutputDirectory $folder
        $reading = Get-Content -LiteralPath (Join-Path $folder 'serial-console.kernel.json') -Raw | ConvertFrom-Json
        $reading.boots | Should -Be 2
        $reading.firstFault.boot | Should -Be 1
        $reading.truncated | Should -BeFalse
    }

    It 'keeps the newest boot''s largest leap beside the saved log, without judging the clock' {
        $folder = Join-Path $TestDrive 'jump'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Set-Content -LiteralPath (Join-Path $folder 'serial-console.log') -Value $script:PersistentJump -Encoding utf8NoBOM -NoNewline
        Save-SerialConsoleKernelFault -OutputDirectory $folder
        $reading = Get-Content -LiteralPath (Join-Path $folder 'serial-console.kernel.json') -Raw | ConvertFrom-Json
        $reading.largestForwardLeap.seconds | Should -Be 303446.86
        $reading.clockJump | Should -BeNullOrEmpty -Because 'a saved log can hold boots this VM''s creation time does not bound'
        @($reading.kinds).Count | Should -Be 0
    }

    It 'writes nothing when no log was saved' {
        $folder = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $folder -Force
        { Save-SerialConsoleKernelFault -OutputDirectory $folder } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $folder 'serial-console.kernel.json') | Should -BeFalse
    }
}
