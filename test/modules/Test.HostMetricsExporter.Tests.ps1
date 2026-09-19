<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42b0e5d4-7c31-4e9a-8f06-3ad2716be5c1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host metrics prometheus exporter pester
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
    Pester coverage for Test.HostMetricsExporter.psm1: the per-host Prometheus
    endpoint that records memory commit, CPU, disk and Hyper-V VM state.
.DESCRIPTION
    Throw-based Assert-* helpers. The decisions worth covering are the ones a
    host cannot be asked to reproduce: what the service command line has to
    become, when it is already equivalent and must NOT be rewritten (a rewrite
    restarts the service and loses samples), what the firewall scope collapses
    to when the monitoring address is unusable, and that an exposition missing
    the commit pair is reported rather than accepted. Every host mutation is
    mocked in module scope, so no test touches a real service or firewall.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.HostMetricsExporter.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:Exe = '"C:\Program Files\windows_exporter\windows_exporter.exe"'
}

Describe 'the exporter contract the scrape side has to match' {
    It 'names one port for every host' {
        Assert-Equal -Expected 9182 -Actual (Get-YurunaHostMetricsPort)
    }
    It 'asks for the collectors that answer a refused allocation' {
        $collectors = @(Get-YurunaHostMetricsCollector)
        foreach ($name in 'memory', 'os', 'cpu', 'logical_disk', 'hyperv') {
            Assert-True ($collectors -contains $name) "the collector set must include $name"
        }
    }
    It 'builds a port-specific firewall rule name' {
        Assert-Equal -Expected 'Yuruna: Allow inbound TCP :9182 (Host metrics)' `
            -Actual (Get-YurunaHostMetricsFirewallRuleName -Port 9182)
    }
}

Describe 'Get-YurunaHostMetricsScrapeSource' {
    It 'scopes to the configured monitoring address' {
        Assert-Equal -Expected '192.0.2.42' -Actual ((Get-YurunaHostMetricsScrapeSource -ConfigIp '192.0.2.42' -EnvIp '') -join ',')
    }
    It 'admits both the configured address and the session override' {
        $scope = @(Get-YurunaHostMetricsScrapeSource -ConfigIp '192.0.2.42' -EnvIp '192.0.2.99')
        Assert-Equal -Expected 2 -Actual $scope.Count
    }
    It 'does not repeat one address named twice' {
        $scope = @(Get-YurunaHostMetricsScrapeSource -ConfigIp '192.0.2.42' -EnvIp ' 192.0.2.42 ')
        Assert-Equal -Expected 1 -Actual $scope.Count
    }
    It 'discards a value that is not an address rather than widening the rule' {
        Assert-Equal -Expected 'LocalSubnet' -Actual ((Get-YurunaHostMetricsScrapeSource -ConfigIp 'cache.example' -EnvIp '') -join ',')
    }
    It 'falls back to LocalSubnet, never to Any, when nothing is configured' {
        Assert-Equal -Expected 'LocalSubnet' -Actual ((Get-YurunaHostMetricsScrapeSource -ConfigIp '' -EnvIp '') -join ',')
    }
}

Describe 'Split-YurunaServiceCommandLine' {
    It 'keeps a quoted executable path with spaces whole' {
        $tokens = @(Split-YurunaServiceCommandLine -CommandLine "$script:Exe --flag=1")
        Assert-Equal -Expected 2 -Actual $tokens.Count
        Assert-Equal -Expected $script:Exe -Actual $tokens[0]
    }
    It 'keeps a quoted flag VALUE with spaces attached to its flag' {
        $tokens = @(Split-YurunaServiceCommandLine -CommandLine "$script:Exe --config.file=`"C:\Program Files\w\config.yaml`"")
        Assert-Equal -Expected 2 -Actual $tokens.Count
        Assert-Equal -Expected '--config.file="C:\Program Files\w\config.yaml"' -Actual $tokens[1]
    }
    It 'returns nothing for an empty command line' {
        Assert-Equal -Expected 0 -Actual (@(Split-YurunaServiceCommandLine -CommandLine '  ')).Count
    }
}

Describe 'Resolve-YurunaHostMetricsCommandLine' {
    It 'adds both owned flags to a command line that carries neither' {
        $plan = Resolve-YurunaHostMetricsCommandLine -CurrentCommandLine $script:Exe `
            -Collector @('cpu', 'memory') -Port 9182
        Assert-False $plan.Matches 'a line without the collector flag cannot already agree'
        Assert-Equal -Expected "$script:Exe --collectors.enabled=cpu,memory --web.listen-address=:9182" -Actual $plan.Desired
    }
    It 'reports the collectors the service does not publish' {
        $plan = Resolve-YurunaHostMetricsCommandLine `
            -CurrentCommandLine "$script:Exe --collectors.enabled=cpu,os --web.listen-address=:9182" `
            -Collector @('cpu', 'memory', 'os') -Port 9182
        Assert-Match 'memory' $plan.Reason 'the reason names the missing collector'
    }
    It 'does not rewrite a service whose collector list is the same set in another order' {
        $plan = Resolve-YurunaHostMetricsCommandLine `
            -CurrentCommandLine "$script:Exe --collectors.enabled=os,memory,cpu --web.listen-address=:9182" `
            -Collector @('cpu', 'memory', 'os') -Port 9182
        Assert-True $plan.Matches 'the same set in another order is the same instrumentation'
    }
    It 'accepts the explicit-any listen form as the same port' {
        $plan = Resolve-YurunaHostMetricsCommandLine `
            -CurrentCommandLine "$script:Exe --collectors.enabled=cpu --web.listen-address=0.0.0.0:9182" `
            -Collector @('cpu') -Port 9182
        Assert-True $plan.Matches '0.0.0.0:9182 and :9182 bind the same socket'
    }
    It 'rewrites when the service listens on another port' {
        $plan = Resolve-YurunaHostMetricsCommandLine `
            -CurrentCommandLine "$script:Exe --collectors.enabled=cpu --web.listen-address=:9100" `
            -Collector @('cpu') -Port 9182
        Assert-False $plan.Matches 'a different port is a target that never scrapes'
        Assert-Match '9182' $plan.Reason 'the reason names the port it must listen on'
    }
    It 'reads the space-separated flag form the installer may have written' {
        $plan = Resolve-YurunaHostMetricsCommandLine `
            -CurrentCommandLine "$script:Exe --collectors.enabled cpu,memory --web.listen-address :9182" `
            -Collector @('cpu', 'memory') -Port 9182
        Assert-True $plan.Matches 'the two flag spellings say the same thing'
    }
    It 'preserves every flag it does not own' {
        $plan = Resolve-YurunaHostMetricsCommandLine `
            -CurrentCommandLine "$script:Exe --log.format logger:eventlog?name=windows_exporter --collectors.enabled=cpu" `
            -Collector @('cpu', 'memory') -Port 9182
        Assert-Match 'log.format' $plan.Desired 'event-log routing survives the rewrite'
        Assert-Match 'logger:eventlog' $plan.Desired 'and so does its value'
    }
    It 'does not swallow the following flag when its own flag carries no value' {
        $plan = Resolve-YurunaHostMetricsCommandLine `
            -CurrentCommandLine "$script:Exe --collectors.enabled --log.level=debug" `
            -Collector @('cpu') -Port 9182
        Assert-Match 'log.level=debug' $plan.Desired 'a value-less flag must not consume the next flag'
    }
    It 'quotes the executable it rebuilds around, so a path with spaces survives' {
        $plan = Resolve-YurunaHostMetricsCommandLine -CurrentCommandLine $script:Exe `
            -Collector @('cpu') -Port 9182
        Assert-Equal -Expected 'C:\Program Files\windows_exporter\windows_exporter.exe' -Actual $plan.Executable
        Assert-True ($plan.Desired.StartsWith('"')) 'the rebuilt line re-quotes the executable'
    }
    It 'reports rather than acts when the service has no command line to read' {
        $plan = Resolve-YurunaHostMetricsCommandLine -CurrentCommandLine '' -Collector @('cpu') -Port 9182
        Assert-False $plan.Matches 'nothing to compare against'
        Assert-Equal -Expected '' -Actual $plan.Executable
        Assert-Equal -Expected '' -Actual $plan.Desired
    }
}

Describe 'Test-YurunaHostMetricsPayload' {
    It 'accepts an exposition carrying every instrumented family' {
        $payload = @(
            'windows_memory_commit_limit 1.234e+10'
            'windows_memory_committed_bytes 5.6e+09'
            'windows_cpu_time_total{core="0,0",mode="idle"} 12'
            'windows_logical_disk_free_bytes{volume="C:"} 42'
            'windows_os_info{version="10.0"} 1'
            'windows_hyperv_health_ok 1'
        ) -join "`n"
        Assert-True (Test-YurunaHostMetricsPayload -Payload $payload).Ok 'every required family is present'
    }
    It 'names the commit pair when the memory collector never ran' {
        $payload = "windows_cpu_time_total 1`nwindows_logical_disk_free_bytes 2`nwindows_os_info 1`nwindows_hyperv_health_ok 1"
        $check = Test-YurunaHostMetricsPayload -Payload $payload
        Assert-False $check.Ok 'a payload without commit metrics is not what this host was instrumented for'
        Assert-Equal -Expected 2 -Actual (@($check.Missing)).Count
    }
    It 'is not satisfied by a metric name that merely contains the family' {
        $check = Test-YurunaHostMetricsPayload -Payload 'x_windows_memory_commit_limit 1'
        Assert-False $check.Ok 'the family has to start the line, not appear in it'
    }
    It 'reports everything missing for an empty scrape' {
        $check = Test-YurunaHostMetricsPayload -Payload ''
        Assert-False $check.Ok 'nothing scraped is nothing recorded'
        Assert-Equal -Expected 6 -Actual (@($check.Missing)).Count
    }
}

if ($IsWindows) {
    Describe 'Set-YurunaHostMetricsExporter (Windows)' {
        It 'warns and does nothing when the exporter is not installed' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            # An absent exporter now tries to stop being absent, so this arm
            # reaches the acquisition. Stub it: a suite that installs software
            # on the machine running it is not a test, and an elevated run on a
            # real pool host is exactly where that would happen.
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostMetricsExporter {
                [pscustomobject]@{ Installed = $false; Changed = $false; Outcome = 'unavailable'; Reason = 'stubbed for the suite'; ExitCode = $null }
            }
            Mock Set-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter { 0 }
            Mock Set-YurunaHostMetricsFirewallRule -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Ensured = $true; Changed = $true; Message = '' } }
            $r = Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42' 3>$null
            Assert-False $r.Installed 'no service -> nothing installed'
            Assert-False $r.Ensured 'and nothing ensured'
            Assert-Match 'winget install' $r.Message 'the warning carries the command that fixes it'
            Assert-MockCalled -CommandName Set-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
            Assert-MockCalled -CommandName Set-YurunaHostMetricsFirewallRule -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
        }
        It 'leaves a correctly configured, running exporter untouched' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Get-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter {
                '"C:\w\windows_exporter.exe" --collectors.enabled=os,memory,logical_disk,hyperv,cpu --web.listen-address=:9182'
            }
            Mock Set-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter { 0 }
            Mock Restart-Service -ModuleName Test.HostMetricsExporter {}
            Mock Start-Service -ModuleName Test.HostMetricsExporter {}
            Mock Set-Service -ModuleName Test.HostMetricsExporter {}
            Mock Set-YurunaHostMetricsFirewallRule -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Ensured = $true; Changed = $false; Message = '' } }
            Mock Invoke-YurunaHostMetricsProbe -ModuleName Test.HostMetricsExporter {
                "windows_memory_commit_limit 1`nwindows_memory_committed_bytes 1`nwindows_cpu_time_total 1`nwindows_logical_disk_free_bytes 1`nwindows_os_info 1`nwindows_hyperv_health_ok 1"
            }
            $r = Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42' 6>$null
            Assert-True  $r.Ensured 'the exposition carries every family'
            Assert-False $r.Changed 'a converged host is not restarted for nothing'
            Assert-MockCalled -CommandName Set-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
            Assert-MockCalled -CommandName Restart-Service -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
        }
        It 'restores the command line it replaced when the rewritten one does not answer' {
            $script:Written = [System.Collections.Generic.List[string]]::new()
            Mock Get-Service -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Get-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter { '"C:\w\windows_exporter.exe" --collectors.enabled=cpu' }
            Mock Set-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter { $script:Written.Add($CommandLine); 0 }
            Mock Restart-Service -ModuleName Test.HostMetricsExporter {}
            Mock Start-Service -ModuleName Test.HostMetricsExporter {}
            Mock Set-Service -ModuleName Test.HostMetricsExporter {}
            Mock Test-YurunaHostMetricsAnswering -ModuleName Test.HostMetricsExporter { $false }
            Mock Set-YurunaHostMetricsFirewallRule -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Ensured = $true; Changed = $false; Message = '' } }
            Mock Invoke-YurunaHostMetricsProbe -ModuleName Test.HostMetricsExporter { '' }
            $r = Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42' 3>$null 6>$null
            Assert-Equal -Expected 2 -Actual $script:Written.Count
            Assert-Equal -Expected '"C:\w\windows_exporter.exe" --collectors.enabled=cpu' -Actual $script:Written[1]
            Assert-False $r.Ensured 'an endpoint that does not answer is not ensured'
        }
        It 'reports a live endpoint that is missing the commit metrics' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Get-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter {
                '"C:\w\windows_exporter.exe" --collectors.enabled=os,memory,logical_disk,hyperv,cpu --web.listen-address=:9182'
            }
            Mock Set-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter { 0 }
            Mock Restart-Service -ModuleName Test.HostMetricsExporter {}
            Mock Start-Service -ModuleName Test.HostMetricsExporter {}
            Mock Set-Service -ModuleName Test.HostMetricsExporter {}
            Mock Set-YurunaHostMetricsFirewallRule -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Ensured = $true; Changed = $false; Message = '' } }
            Mock Invoke-YurunaHostMetricsProbe -ModuleName Test.HostMetricsExporter { 'windows_cpu_time_total 1' }
            $r = Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42' 3>$null 6>$null
            Assert-False $r.Ensured 'a partial exposition is not the instrumentation asked for'
            Assert-Match 'memory' $r.Message 'the message names what is missing'
        }
    }

    Describe 'Set-YurunaHostMetricsFirewallRule (Windows)' {
        It 'creates a rule scoped to the monitoring host' {
            Mock Get-NetFirewallRule -ModuleName Test.HostMetricsExporter { $null }
            Mock New-NetFirewallRule -ModuleName Test.HostMetricsExporter { }
            $r = Set-YurunaHostMetricsFirewallRule -Port 9182 -RemoteAddress @('192.0.2.42') 6>$null
            Assert-True $r.Changed 'a rule was created'
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It `
                -ParameterFilter { $RemoteAddress -contains '192.0.2.42' -and $LocalPort -eq 9182 }
        }
        It 'leaves a correct, scoped, enabled rule alone' {
            Mock Get-NetFirewallRule -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow' } }
            Mock Get-YurunaMetricsRulePortFilter -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '9182' } }
            Mock Get-YurunaMetricsRuleAddressFilter -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ RemoteAddress = @('192.0.2.42') } }
            Mock New-NetFirewallRule -ModuleName Test.HostMetricsExporter { }
            Mock Remove-NetFirewallRule -ModuleName Test.HostMetricsExporter { }
            $r = Set-YurunaHostMetricsFirewallRule -Port 9182 -RemoteAddress @('192.0.2.42') 6>$null
            Assert-True  $r.Ensured 'already reachable from the scraper'
            Assert-False $r.Changed 'nothing to change'
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
        }
        It 'rebuilds a rule that has drifted to a wider scope' {
            Mock Get-NetFirewallRule -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow' } }
            Mock Get-YurunaMetricsRulePortFilter -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '9182' } }
            Mock Get-YurunaMetricsRuleAddressFilter -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ RemoteAddress = @('Any') } }
            Mock New-NetFirewallRule -ModuleName Test.HostMetricsExporter { }
            Mock Remove-NetFirewallRule -ModuleName Test.HostMetricsExporter { }
            $r = Set-YurunaHostMetricsFirewallRule -Port 9182 -RemoteAddress @('192.0.2.42') 6>$null
            Assert-True $r.Changed 'a rule open to the world is rebuilt, not accepted'
            Assert-MockCalled -CommandName Remove-NetFirewallRule -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It
        }
    }
}

Describe 'the argument list the package manager is handed' {
    # Pure, so the one property that makes an unattended install safe at all --
    # that nothing in it can stop and ask a question -- is asserted rather than
    # re-derived by a reader from a spawn call.
    BeforeAll {
        $script:InstallArgument = @(Get-YurunaHostMetricsInstallArgument -PackageId (Get-YurunaHostMetricsPackageId) -LogPath 'C:\logs\winget.log')
    }
    It 'names the one package, exactly, from the one source' {
        Assert-Equal -Expected 'install' -Actual $script:InstallArgument[0]
        Assert-True ($script:InstallArgument -contains '--id') 'the package is named by id'
        Assert-True ($script:InstallArgument -contains 'Prometheus.WindowsExporter') 'and that id is the exporter'
        Assert-True ($script:InstallArgument -contains '--exact') 'an inexact query can resolve to a different package'
        Assert-True ($script:InstallArgument -contains 'winget') 'the source is pinned to the public catalog'
    }
    It 'answers every agreement and prompt in advance' {
        foreach ($flag in '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') {
            Assert-True ($script:InstallArgument -contains $flag) "an unattended install must pass $flag; a prompt with no console to answer it is a hang"
        }
    }
    It 'never asks for an interactive install or for a keypress on the way out' {
        Assert-False ($script:InstallArgument -contains '--interactive') 'nobody is at this console'
        Assert-False ($script:InstallArgument -contains '-i') 'nor in its short spelling'
        Assert-False ($script:InstallArgument -contains '--wait') 'that one waits for a keypress before exiting'
    }
    It 'can only create the package, and creates it machine-wide' {
        Assert-True ($script:InstallArgument -contains '--no-upgrade') 'an upgrade would replace a running service underneath a cycle using it'
        $scopeAt = [array]::IndexOf($script:InstallArgument, '--scope')
        Assert-True ($scopeAt -ge 0) 'the scope is stated rather than left to an installer default'
        Assert-Equal -Expected 'machine' -Actual $script:InstallArgument[$scopeAt + 1] 'a per-profile install registers no service at all'
    }
    It 'asks for a log only when there is somewhere to write one' {
        Assert-True ($script:InstallArgument -contains '--log') 'the log is the only capture, since no stream is redirected'
        $none = @(Get-YurunaHostMetricsInstallArgument -PackageId 'Prometheus.WindowsExporter' -LogPath '')
        Assert-False ($none -contains '--log') 'a --log with no path is a command that fails for the wrong reason'
    }
}

Describe 'Test-YurunaHostMetricsInstallDue' {
    BeforeAll {
        $script:NowUtc = [datetime]::SpecifyKind([datetime]'2026-01-01T12:00:00', 'Utc')
    }
    It 'allows the first attempt on a host that has never tried' {
        $due = Test-YurunaHostMetricsInstallDue -LastAttemptUtc $null -BootTimeUtc $null -NowUtc $script:NowUtc -RetryHours 6
        Assert-True $due.Due 'a host with no attempt on record has to be allowed one'
    }
    It 'suppresses a second attempt inside the interval, and says how long is left' {
        $due = Test-YurunaHostMetricsInstallDue -LastAttemptUtc $script:NowUtc.AddHours(-2) -BootTimeUtc $null -NowUtc $script:NowUtc -RetryHours 6
        Assert-False $due.Due 'an install that just failed must not be retried by the next cycle'
        Assert-Match 'hours away' $due.Reason 'a suppressed attempt says when the next one is'
    }
    It 'permits one again once the interval has passed' {
        $due = Test-YurunaHostMetricsInstallDue -LastAttemptUtc $script:NowUtc.AddHours(-7) -BootTimeUtc $null -NowUtc $script:NowUtc -RetryHours 6
        Assert-True $due.Due 'the interval delays the retry, it does not cancel it'
    }
    It 'ends the interval when the host has started since the attempt' {
        $due = Test-YurunaHostMetricsInstallDue -LastAttemptUtc $script:NowUtc.AddHours(-2) `
            -BootTimeUtc $script:NowUtc.AddHours(-1) -NowUtc $script:NowUtc -RetryHours 6
        Assert-True $due.Due 'a restart is where an operator fix lands, so it is where the retry belongs'
        Assert-Match 'started since' $due.Reason 'and the record says that is why'
    }
    It 'does not read an unknown boot time as "has not rebooted"' {
        $due = Test-YurunaHostMetricsInstallDue -LastAttemptUtc $script:NowUtc.AddHours(-2) -BootTimeUtc $null -NowUtc $script:NowUtc -RetryHours 6
        Assert-False $due.Due 'a host whose boot time cannot be read would otherwise retry every cycle forever'
    }
    It 'treats a record stamped in the future as unusable rather than as a permanent block' {
        $due = Test-YurunaHostMetricsInstallDue -LastAttemptUtc $script:NowUtc.AddHours(5) -BootTimeUtc $null -NowUtc $script:NowUtc -RetryHours 6
        Assert-True $due.Due 'a clock that moved must not silence the install until it catches up'
    }
}

if ($IsWindows) {
    Describe 'Install-YurunaHostMetricsExporter (Windows)' {
        BeforeEach {
            # Every seam that would touch the machine is stubbed. Nothing in
            # this Describe may resolve a real package manager, read or write a
            # real record, or start a process.
            Mock Test-YurunaHostMetricsElevated -ModuleName Test.HostMetricsExporter { $true }
            Mock Get-YurunaWingetPath -ModuleName Test.HostMetricsExporter { 'C:\stub\winget.exe' }
            Mock Get-YurunaHostLastBootTime -ModuleName Test.HostMetricsExporter { $null }
            Mock Get-YurunaHostMetricsInstallStatePath -ModuleName Test.HostMetricsExporter { 'C:\stub\host-metrics.install.json' }
            Mock Get-YurunaHostMetricsInstallLogPath -ModuleName Test.HostMetricsExporter { 'C:\stub\winget.log' }
            Mock Get-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter { $null }
            Mock Set-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter { $true }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter {
                [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; Message = 'winget exited 0' }
            }
        }
        It 'asks the host before it asks anything expensive' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
            $r = Install-YurunaHostMetricsExporter
            Assert-Equal -Expected 'already-present' -Actual $r.Outcome
            Assert-False $r.Changed 'an installed exporter is not reinstalled'
            Assert-MockCalled -CommandName Get-YurunaWingetPath -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
            Assert-MockCalled -CommandName Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
        }
        It 'cannot reach the package manager on a converged host at all' {
            # Not "was not called" but "could not have been": every seam past the
            # service lookup is armed to fail the test if it is reached. This is
            # the per-cycle cost guarantee, asserted rather than asserted about.
            Mock Get-Service -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Test-YurunaHostMetricsElevated -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN on a converged host' }
            Mock Get-YurunaWingetPath -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN on a converged host' }
            Mock Get-YurunaHostMetricsInstallStatePath -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN on a converged host' }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN on a converged host' }
            $r = Install-YurunaHostMetricsExporter
            Assert-Equal -Expected 'already-present' -Actual $r.Outcome 'a reached seam would have turned this into failed'
        }
        It 'records no attempt when there was nothing to attempt' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
            $null = Install-YurunaHostMetricsExporter
            Assert-MockCalled -CommandName Set-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
        }
        It 'reports a session that cannot register a service, and spends no attempt on it' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Test-YurunaHostMetricsElevated -ModuleName Test.HostMetricsExporter { $false }
            $r = Install-YurunaHostMetricsExporter
            Assert-Equal -Expected 'unavailable' -Actual $r.Outcome
            Assert-Match 'Administrator' $r.Reason 'the reason names what is missing'
            Assert-MockCalled -CommandName Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
            Assert-MockCalled -CommandName Set-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
        }
        It 'reports a host with no package manager, and spends no attempt on it either' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Get-YurunaWingetPath -ModuleName Test.HostMetricsExporter { '' }
            $r = Install-YurunaHostMetricsExporter
            Assert-Equal -Expected 'unavailable' -Actual $r.Outcome
            Assert-Match 'winget' $r.Reason 'the reason names what is missing'
            # A free check that fails must not buy a quiet interval: the next
            # cycle re-asks, and the answer is still free.
            Assert-MockCalled -CommandName Set-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter -Times 0 -Exactly -Scope It
        }
        It 'skips the attempt the interval has not released yet' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Get-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter { [datetime]::UtcNow.AddMinutes(-5) }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN inside the interval' }
            $r = Install-YurunaHostMetricsExporter
            Assert-Equal -Expected 'skipped-throttled' -Actual $r.Outcome 'a reached package manager would have turned this into failed'
            Assert-Match 'hours away' $r.Reason 'the skip says when the next attempt is'
        }
        It 'attempts again once the recorded attempt has aged out' {
            $script:ServiceQueries = 0
            Mock Get-Service -ModuleName Test.HostMetricsExporter {
                $script:ServiceQueries++
                if ($script:ServiceQueries -gt 1) { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } } else { $null }
            }
            Mock Get-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter { [datetime]::UtcNow.AddDays(-3) }
            $null = Install-YurunaHostMetricsExporter 6>$null
            Assert-MockCalled -CommandName Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It
        }
        It 'reports the install that worked, and clears the record it was holding' {
            $script:ServiceQueries = 0
            Mock Get-Service -ModuleName Test.HostMetricsExporter {
                $script:ServiceQueries++
                if ($script:ServiceQueries -gt 1) { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } } else { $null }
            }
            Mock Test-Path -ModuleName Test.HostMetricsExporter { $true }
            Mock Remove-Item -ModuleName Test.HostMetricsExporter { }
            $r = Install-YurunaHostMetricsExporter 6>$null
            Assert-Equal -Expected 'installed' -Actual $r.Outcome
            Assert-True $r.Installed 'the host has the service now'
            Assert-True $r.Changed 'and this call is why'
            Assert-MockCalled -CommandName Remove-Item -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It
        }
        It 'decides by the service, not by the exit code' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter {
                [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; Message = 'winget exited 0' }
            }
            $r = Install-YurunaHostMetricsExporter 6>$null
            Assert-Equal -Expected 'failed' -Actual $r.Outcome 'exit 0 is what the installer claims; the service is what the host has'
            Assert-Match 'no windows_exporter service was registered' $r.Reason
            Assert-Match 'winget.log' $r.Reason 'and it says where to read what happened'
            Assert-MockCalled -CommandName Set-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It
        }
        It 'reports a non-zero exit by its number' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter {
                [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = -1978335212; Message = 'winget exited -1978335212' }
            }
            $r = Install-YurunaHostMetricsExporter 6>$null
            Assert-Equal -Expected 'failed' -Actual $r.Outcome
            Assert-Equal -Expected -1978335212 -Actual $r.ExitCode 'the exit code is what an operator searches for'
            Assert-Match '1978335212' $r.Reason
        }
        It 'abandons an install that outlasts its bound without failing anything' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter {
                [pscustomobject]@{ Started = $true; TimedOut = $true; ExitCode = $null; Message = "winget did not finish within $TimeoutSec seconds and was stopped" }
            }
            $r = Install-YurunaHostMetricsExporter -TimeoutSec 45 6>$null
            Assert-Equal -Expected 'failed' -Actual $r.Outcome
            Assert-False $r.Installed 'a stopped install left nothing behind'
            Assert-Match '45 seconds' $r.Reason 'the bound is reported, not merely applied'
            Assert-Match 'next pass finds it' $r.Reason 'an install that lands late is found rather than lost'
            Assert-MockCalled -CommandName Set-YurunaHostMetricsInstallAttempt -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It
        }
        It 'hands the package manager a bound even when the caller names none' {
            $script:SeenTimeout = 0
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter {
                $script:SeenTimeout = $TimeoutSec
                [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 1; Message = 'winget exited 1' }
            }
            $null = Install-YurunaHostMetricsExporter 6>$null
            Assert-True ($script:SeenTimeout -gt 0) 'an unbounded install is a cycle that never ends'
            Assert-True ($script:SeenTimeout -le 600) "the default bound must stay well inside a cycle; it is $script:SeenTimeout seconds"
        }
        It 'does not let a throwing package manager out of the function' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter { throw 'the package manager died' }
            $r = Install-YurunaHostMetricsExporter 6>$null
            Assert-Equal -Expected 'failed' -Actual $r.Outcome
            Assert-Match 'the package manager died' $r.Reason 'the exception is reported, not raised'
        }
        It 'does not let a throwing host query out of the function either' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { throw 'the service database is unavailable' }
            $r = Install-YurunaHostMetricsExporter
            Assert-Equal -Expected 'failed' -Actual $r.Outcome
            Assert-Match 'service database' $r.Reason 'even the cheap check reports rather than raises'
        }
        It 'runs nothing under -WhatIf' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN under -WhatIf' }
            $r = Install-YurunaHostMetricsExporter -WhatIf
            Assert-Equal -Expected 'skipped-whatif' -Actual $r.Outcome
        }
        It 'is a no-op on a PowerShell host that is not Windows' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN off Windows' }
            try {
                InModuleScope Test.HostMetricsExporter { Set-Variable -Name IsWindows -Value $false -Scope Script }
                $r = Install-YurunaHostMetricsExporter
                Assert-Equal -Expected 'not-applicable' -Actual $r.Outcome
            } finally {
                InModuleScope Test.HostMetricsExporter { Remove-Variable -Name IsWindows -Scope Script -ErrorAction SilentlyContinue }
            }
        }
    }

    Describe 'the attempt record survives the process (Windows)' {
        # The real reader and writer over a throwaway file. Each cycle is a new
        # process, so only something on disk can space the cycle after this one
        # -- which is exactly what a mocked record would hide.
        It 'reads back the instant it wrote, in UTC' {
            $dir = New-YurunaTestTempDir -Prefix 'yuruna-hostmetrics'
            try {
                $stamp = Join-Path $dir 'host-metrics.install.json'
                $before = [datetime]::UtcNow
                InModuleScope Test.HostMetricsExporter -Parameters @{ Stamp = $stamp } {
                    param($Stamp)
                    $null = Set-YurunaHostMetricsInstallAttempt -Path $Stamp -Reason 'probe' -ExitCode 1 -Confirm:$false
                }
                $read = InModuleScope Test.HostMetricsExporter -Parameters @{ Stamp = $stamp } {
                    param($Stamp)
                    Get-YurunaHostMetricsInstallAttempt -Path $Stamp
                }
                Assert-NotNull $read 'the record is readable'
                Assert-Equal -Expected 'Utc' -Actual "$($read.Kind)" 'a record read back as local time is one UTC offset wrong'
                $drift = [math]::Abs((New-TimeSpan -Start $before -End $read).TotalMinutes)
                Assert-True ($drift -lt 5) "the record read back $drift minutes from when it was written"
            } finally {
                Remove-YurunaTestTempDir $dir
            }
        }
        It 'spaces the next attempt after a failure, and treats an unreadable record as none' {
            $dir = New-YurunaTestTempDir -Prefix 'yuruna-hostmetrics'
            try {
                $stamp = Join-Path $dir 'host-metrics.install.json'
                Mock Get-YurunaHostMetricsInstallStatePath -ModuleName Test.HostMetricsExporter { $stamp }.GetNewClosure()
                Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
                Mock Test-YurunaHostMetricsElevated -ModuleName Test.HostMetricsExporter { $true }
                Mock Get-YurunaWingetPath -ModuleName Test.HostMetricsExporter { 'C:\stub\winget.exe' }
                Mock Get-YurunaHostLastBootTime -ModuleName Test.HostMetricsExporter { $null }
                Mock Get-YurunaHostMetricsInstallLogPath -ModuleName Test.HostMetricsExporter { 'C:\stub\winget.log' }
                Mock Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter {
                    [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 1; Message = 'winget exited 1' }
                }
                $first = Install-YurunaHostMetricsExporter 6>$null
                $second = Install-YurunaHostMetricsExporter 6>$null
                Assert-Equal -Expected 'failed' -Actual $first.Outcome
                Assert-Equal -Expected 'skipped-throttled' -Actual $second.Outcome 'the next process must not repeat the attempt'
                Assert-True (Test-Path -LiteralPath $stamp) 'the attempt is recorded where the next process can read it'
                Assert-MockCalled -CommandName Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It

                # A torn or hand-edited record must fail toward trying again:
                # one extra attempt is the benign direction for a mechanism
                # whose only job is to suppress work.
                Set-Content -LiteralPath $stamp -Value 'not json at all' -Encoding utf8
                $third = Install-YurunaHostMetricsExporter 6>$null
                Assert-Equal -Expected 'failed' -Actual $third.Outcome 'an unreadable record reads as no record'
                Assert-MockCalled -CommandName Invoke-YurunaWingetInstall -ModuleName Test.HostMetricsExporter -Times 2 -Exactly -Scope It
            } finally {
                Remove-YurunaTestTempDir $dir
            }
        }
    }

    Describe 'Set-YurunaHostMetricsExporter acquires what it cannot converge (Windows)' {
        BeforeEach {
            Mock Set-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter { 0 }
            Mock Get-YurunaHostMetricsServiceCommandLine -ModuleName Test.HostMetricsExporter {
                '"C:\w\windows_exporter.exe" --collectors.enabled=os,memory,logical_disk,hyperv,cpu --web.listen-address=:9182'
            }
            Mock Restart-Service -ModuleName Test.HostMetricsExporter {}
            Mock Start-Service -ModuleName Test.HostMetricsExporter {}
            Mock Set-Service -ModuleName Test.HostMetricsExporter {}
            Mock Set-YurunaHostMetricsFirewallRule -ModuleName Test.HostMetricsExporter { [pscustomobject]@{ Ensured = $true; Changed = $false; Message = '' } }
            Mock Invoke-YurunaHostMetricsProbe -ModuleName Test.HostMetricsExporter {
                "windows_memory_commit_limit 1`nwindows_memory_committed_bytes 1`nwindows_cpu_time_total 1`nwindows_logical_disk_free_bytes 1`nwindows_os_info 1`nwindows_hyperv_health_ok 1"
            }
        }
        It 'tries to install an exporter it does not find, and says why that did not work' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostMetricsExporter {
                [pscustomobject]@{ Installed = $false; Changed = $false; Outcome = 'unavailable'; Reason = 'winget is not available to this account'; ExitCode = $null }
            }
            $r = Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42' 3>$null
            Assert-False $r.Installed 'no service -> nothing installed'
            Assert-Match 'winget is not available to this account' $r.Message 'the warning carries why, not only what'
            Assert-Match 'winget install --id Prometheus.WindowsExporter' $r.Message 'and still the command that fixes it by hand'
            Assert-MockCalled -CommandName Install-YurunaHostMetricsExporter -ModuleName Test.HostMetricsExporter -Times 1 -Exactly -Scope It
        }
        It 'configures an exporter it has just installed, on the same pass' {
            $script:ServiceQueries = 0
            Mock Get-Service -ModuleName Test.HostMetricsExporter {
                $script:ServiceQueries++
                if ($script:ServiceQueries -gt 1) { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } } else { $null }
            }
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostMetricsExporter {
                [pscustomobject]@{ Installed = $true; Changed = $true; Outcome = 'installed'; Reason = 'installed it'; ExitCode = 0 }
            }
            $r = Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42' 6>$null
            Assert-True $r.Installed 'the pass that installs also converges'
            Assert-True $r.Ensured 'and goes all the way to a scraped endpoint'
            Assert-True $r.Changed 'a fresh install is a change'
        }
        It 'never acquires anything under -SkipInstall' {
            Mock Get-Service -ModuleName Test.HostMetricsExporter { $null }
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostMetricsExporter { throw 'MUST NOT RUN under -SkipInstall' }
            $r = Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42' -SkipInstall 3>$null
            Assert-False $r.Installed
            Assert-Match 'was not attempted' $r.Message 'a reading of the host says it did not change one'
        }
    }

    Describe 'Initialize-WindowsHostMetricsExporter, the per-cycle provider (Windows)' {
        BeforeAll {
            Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.HostCondition.psm1') -Force -DisableNameChecking
        }
        It 'returns exactly one record, so the dispatcher can read it' {
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows {
                [pscustomobject]@{ Installed = $true; Changed = $false; Outcome = 'already-present'; Reason = 'already registered'; ExitCode = $null }
            }
            $emitted = @(Initialize-WindowsHostMetricsExporter)
            Assert-Equal -Expected 1 -Actual $emitted.Count 'a second value on the success stream is what silences the dispatcher'
            Assert-Equal -Expected 'Present' -Actual $emitted[0].Status
        }
        It 'maps every outcome the installer can report onto a status' {
            $map = @{
                'already-present'   = 'Present'
                'skipped-throttled' = 'Throttled'
                'skipped-whatif'    = 'Skipped'
                'not-applicable'    = 'Skipped'
                'unavailable'       = 'Unavailable'
                'failed'            = 'Failed'
            }
            foreach ($outcome in $map.Keys) {
                $arm = $outcome
                Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows {
                    [pscustomobject]@{ Installed = $false; Changed = $false; Outcome = $arm; Reason = "reason for $arm"; ExitCode = $null }
                }.GetNewClosure()
                $r = Initialize-WindowsHostMetricsExporter
                Assert-Equal -Expected $map[$outcome] -Actual $r.Status "the '$outcome' outcome"
                Assert-Match 'reason for' $r.Reason "the '$outcome' outcome carries its reason forward"
            }
        }
        It 'configures the exporter only on the cycle that installed it' {
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows {
                [pscustomobject]@{ Installed = $true; Changed = $false; Outcome = 'already-present'; Reason = 'already registered'; ExitCode = $null }
            }
            Mock Set-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows { [pscustomobject]@{ Ensured = $true } }
            $null = Initialize-WindowsHostMetricsExporter
            Assert-MockCalled -CommandName Set-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows -Times 0 -Exactly -Scope It
        }
        It 'does configure the one it just installed' {
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows {
                [pscustomobject]@{ Installed = $true; Changed = $true; Outcome = 'installed'; Reason = 'installed it'; ExitCode = 0 }
            }
            Mock Set-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows { [pscustomobject]@{ Ensured = $true } }
            $r = Initialize-WindowsHostMetricsExporter -ConfigPath 'C:\does\not\exist\test.config.yml'
            Assert-Equal -Expected 'Installed' -Actual $r.Status
            Assert-MockCalled -CommandName Set-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows -Times 1 -Exactly -Scope It
        }
        It 'reports, never raises, whatever the installer does' {
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows { throw 'the installer exploded' }
            $r = Initialize-WindowsHostMetricsExporter
            Assert-Equal -Expected 'Failed' -Actual $r.Status 'an exception out of here would reach the cycle'
            Assert-Match 'the installer exploded' $r.Reason
        }
        It 'reports, never raises, when configuring the fresh install throws' {
            Mock Install-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows {
                [pscustomobject]@{ Installed = $true; Changed = $true; Outcome = 'installed'; Reason = 'installed it'; ExitCode = 0 }
            }
            Mock Set-YurunaHostMetricsExporter -ModuleName Test.HostCondition.Windows { throw 'the firewall service is not running' }
            $r = Initialize-WindowsHostMetricsExporter -ConfigPath 'C:\does\not\exist\test.config.yml'
            Assert-Equal -Expected 'Failed' -Actual $r.Status
            Assert-Match 'firewall service' $r.Reason
        }
    }

    Describe 'Initialize-HostMetricsExporter, the dispatcher (Windows)' {
        BeforeAll {
            Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.HostCondition.psm1') -Force -DisableNameChecking
        }
        # Each test registers its own provider under the same key, which
        # overwrites the previous one. Clearing between them is not an option:
        # the registry's Clear drops every platform's registration, including
        # the real ones the rest of this process relies on.
        It 'does nothing at all for a host type that registers no provider' {
            Initialize-HostMetricsExporter -HostType 'host.test.absent' 3>$null
            Assert-True $true 'a host with no provider returns before touching anything'
        }
        It 'does nothing for a provider that registers no metrics-exporter slot' {
            Register-HostConditionProvider -HostType 'host.test.metrics' -Assert { $true } -AssertMinimum { $true }
            Initialize-HostMetricsExporter -HostType 'host.test.metrics' 3>$null
            Assert-True $true 'an empty slot returns before invoking anything'
        }
        It 'announces an install where somebody can see it, and not on the value it returns' {
            Register-HostConditionProvider -HostType 'host.test.metrics' -Assert { $true } -AssertMinimum { $true } `
                -MetricsExporter { [pscustomobject]@{ Status = 'Installed'; Reason = 'installed it' } }
            $returned = @(Initialize-HostMetricsExporter -HostType 'host.test.metrics' 6>&1)
            Assert-Equal -Expected 1 -Actual $returned.Count 'the announcement is emitted once'
            Assert-Match 'exporter installed' "$($returned[0])" 'and it says what happened'
            $value = @(Initialize-HostMetricsExporter -HostType 'host.test.metrics' 6>$null)
            Assert-Equal -Expected 0 -Actual $value.Count 'nothing reaches the success stream, which the call site discards'
        }
        It 'warns with the reason on an outcome an operator has to act on' {
            Register-HostConditionProvider -HostType 'host.test.metrics' -Assert { $true } -AssertMinimum { $true } `
                -MetricsExporter { [pscustomobject]@{ Status = 'Unavailable'; Reason = 'winget is not available to this account' } }
            $warnings = @(Initialize-HostMetricsExporter -HostType 'host.test.metrics' 3>&1)
            Assert-Equal -Expected 1 -Actual $warnings.Count
            Assert-Match 'winget is not available to this account' "$($warnings[0])" 'a warning that cannot name the reason is a warning nobody can act on'
        }
        It 'is quiet on the outcome that happens every cycle' {
            Register-HostConditionProvider -HostType 'host.test.metrics' -Assert { $true } -AssertMinimum { $true } `
                -MetricsExporter { [pscustomobject]@{ Status = 'Present'; Reason = 'already registered' } }
            $noise = @(Initialize-HostMetricsExporter -HostType 'host.test.metrics' 3>&1 6>&1)
            Assert-Equal -Expected 0 -Actual $noise.Count 'a line every twelve minutes forever is a log nobody reads'
        }
        It 'still announces when a provider leaks an extra value' {
            Register-HostConditionProvider -HostType 'host.test.metrics' -Assert { $true } -AssertMinimum { $true } `
                -MetricsExporter { 'a stray line'; [pscustomobject]@{ Status = 'Installed'; Reason = 'installed it' } }
            $returned = @(Initialize-HostMetricsExporter -HostType 'host.test.metrics' 6>&1)
            Assert-Equal -Expected 1 -Actual $returned.Count
            Assert-Match 'exporter installed' "$($returned[0])" 'a stray line must degrade the message, never silence it'
        }
        It 'turns a throwing provider into a warning' {
            Register-HostConditionProvider -HostType 'host.test.metrics' -Assert { $true } -AssertMinimum { $true } `
                -MetricsExporter { throw 'the provider exploded' }
            $warnings = @(Initialize-HostMetricsExporter -HostType 'host.test.metrics' 3>&1)
            Assert-Equal -Expected 1 -Actual $warnings.Count
            Assert-Match 'the provider exploded' "$($warnings[0])" 'the dispatcher owes the cycle that it cannot fail it'
        }
    }
}

Describe 'the per-cycle call site cannot fail a cycle' {
    # The step is one call in a file this suite does not own, and its safety is
    # a property of the CALL, not of the function it calls: a call outside a try
    # raises when the module fails to import, and a call whose value is left on
    # the pipeline becomes part of the enclosing function's return. Neither is
    # visible from inside the module, neither shows up in a green cycle, and
    # only the parsed call site holds them.
    BeforeAll {
        function Get-YurunaCallSiteAncestor {
            param($Node, [string]$TypeName)
            $parent = $Node.Parent
            while ($null -ne $parent) {
                if ($parent.GetType().Name -eq $TypeName) { return $parent }
                $parent = $parent.Parent
            }
            return $null
        }
        $repoRoot = Get-YurunaTestRepoRoot -SuiteDirectory (Split-Path -Parent $PSCommandPath)
        $script:CallSite = @(
            Get-ChildItem -LiteralPath (Join-Path $repoRoot 'test/modules') -Filter '*.psm1' -File |
                ForEach-Object {
                    $path = $_.FullName
                    @((Get-YurunaTestFileAst -Path $path).FindAll({
                                param($n)
                                $n -is [System.Management.Automation.Language.CommandAst] -and
                                $n.GetCommandName() -eq 'Initialize-HostMetricsExporter'
                            }, $true)) | ForEach-Object { [pscustomobject]@{ File = $path; Ast = $_ } }
                }
        )
    }
    It 'is called exactly once, from the function the cycle runs' {
        Assert-Equal -Expected 1 -Actual $script:CallSite.Count `
            'the per-cycle convergence has exactly one call site; a second one is two cycles worth of attempts in one cycle'
        $owner = Get-YurunaCallSiteAncestor -Node $script:CallSite[0].Ast -TypeName 'FunctionDefinitionAst'
        Assert-NotNull $owner 'the call site must live inside a function, not at module top level'
        Assert-Equal -Expected 'Invoke-RunnerInnerCycle' -Actual $owner.Name `
            "the step belongs on the per-cycle path, not in $($owner.Name)"
    }
    It 'sits inside a try with a catch, so not even a failed import ends the cycle' {
        $try = Get-YurunaCallSiteAncestor -Node $script:CallSite[0].Ast -TypeName 'TryStatementAst'
        Assert-NotNull $try 'the call must sit inside a try statement'
        Assert-True ($try.CatchClauses.Count -ge 1) `
            'a try with no catch re-raises: the module may fail to import, and the command would then not exist at all'
    }
    It 'has its value discarded, never tested' {
        $call = $script:CallSite[0].Ast
        $pipeline = Get-YurunaCallSiteAncestor -Node $call -TypeName 'PipelineAst'
        Assert-NotNull $pipeline 'the call is a pipeline'
        $assigned = $pipeline.Parent -is [System.Management.Automation.Language.AssignmentStatementAst]
        $discarded = $pipeline.Extent.Text -match '\|\s*Out-Null\s*$'
        Assert-True ($assigned -or $discarded) `
            'the value must be assigned or discarded: an unassigned pipeline becomes output of the enclosing function'
        $if = Get-YurunaCallSiteAncestor -Node $call -TypeName 'IfStatementAst'
        if ($if) {
            foreach ($clause in $if.Clauses) {
                Assert-False ($clause.Item1.Extent.Text -match 'Initialize-HostMetricsExporter') `
                    'the step must never be the condition of a branch; that is what makes telemetry a reason to fail'
            }
        }
    }
}
