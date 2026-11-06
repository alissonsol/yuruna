<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42b0450c-414d-47ec-b744-a45b9c2c8588
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host ubuntu kvm deep-diagnostics pester
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
    Deep diagnostics mode on an Ubuntu KVM host: what Enable plans, records and
    applies, and that Disable puts every value back.
.DESCRIPTION
    Yuruna.Host.DeepDiagnostics.psm1 reaches the host only through the six
    functions of its "Host access" region. Each case here mocks them against a
    simulated host -- files and their modes, directories, sysctl values, units,
    kernel modules, packages, the watchdog and the netconsole target -- whose
    sudo layer carries out the same commands a real host would. A case can then
    run Enable and Disable end to end and compare the whole host before and
    after, without touching the machine running the suite.

    Messages are rendered by a mock as "key|name=value|..." so a case asserts
    which message was chosen and with what values, independently of the
    catalog text.

    The helper scripts run for real where they only read (one vitals sample,
    a boot bundle written to a temporary file) and through lifted functions
    where they would write to the kernel.
#>

BeforeDiscovery {
    # Skip conditions are read at discovery, before BeforeAll runs. The lifted
    # shell functions take POSIX paths, which Windows temp paths are not.
    $script:CanRunShell = [bool](Get-Command bash -CommandType Application -ErrorAction SilentlyContinue) -and -not $IsWindows
    $script:HasShellCheck = [bool](Get-Command shellcheck -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Global -DisableNameChecking
    $script:ModulePath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.DeepDiagnostics.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking
    $script:ModuleName = 'Yuruna.Host.DeepDiagnostics'
    $script:Helpers = Join-Path $script:RepoRoot 'host/ubuntu.kvm/deep-diagnostics'
    $script:StatePath = '/var/lib/yuruna/deep-diagnostics/state.json'
    $script:SysctlDropIn = '/etc/sysctl.d/99-zz-yuruna-deep-diagnostics.conf'
    $script:Bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

    # --- REGION: Simulated host
    function New-FakeHost {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory simulated host.')]
        param(
            [string]$Vendor = 'GenuineIntel',
            [switch]$LegacyBios,
            [switch]$AptFails,
            [switch]$RasdaemonInstalled,
            # Installed and on hold (apt-mark hold), so dpkg reports 'hi'.
            [switch]$RasdaemonHeld,
            # Removed earlier with its configuration files kept: dpkg 'rc'.
            [switch]$RasdaemonConfigFiles,
            [switch]$NoNetworkManager,
            [switch]$NoSystemd,
            # Another process holds the watchdog device open.
            [switch]$WatchdogHeld,
            [string[]]$Module = @(),
            # Watchdog drivers built into the kernel, listed in modules.builtin.
            [string[]]$BuiltIn = @(),
            [string]$KernelConfig = "CONFIG_EFI_VARS_PSTORE=m`n",
            [hashtable]$Sysctl = @{},
            [string[]]$MissingSysctl = @(),
            [hashtable]$File = @{}
        )
        $fake = [pscustomobject]@{
            Files           = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
            Modes           = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
            Dirs            = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            Sysctl          = [ordered]@{
                'kernel.softlockup_panic'             = '0'
                'kernel.hardlockup_panic'             = '0'
                'kernel.nmi_watchdog'                 = '0'
                'kernel.softlockup_all_cpu_backtrace' = '0'
                'kernel.hardlockup_all_cpu_backtrace' = '0'
                'kernel.panic_on_oops'                = '0'
                'kernel.panic'                        = '0'
                'kernel.printk'                       = "4`t4`t1`t7"
                'kernel.osrelease'                    = '6.8.0-31-generic'
            }
            Units           = @{ 'systemd-pstore.service' = @{ Enabled = 'enabled'; Active = 'inactive' }; 'systemd-journald.service' = @{ Enabled = 'static'; Active = 'active' } }
            # What /sys/module shows: loaded modules and pstore, which is
            # built in and so absent from /proc/modules.
            Modules         = [Collections.Generic.HashSet[string]]::new([string[]]@('pstore'), [StringComparer]::Ordinal)
            BuiltIn         = @($BuiltIn)
            Packages        = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            Held            = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            ConfigFiles     = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            # Present: the configfs directory exists, enabled or not.
            Netconsole      = @{ Present = $false; Enabled = '0'; Address = ''; Port = '' }
            RuntimeWatchdog = '0'
            Calls           = [Collections.Generic.List[string]]::new()
            StateWrites     = [Collections.Generic.List[string]]::new()
            AptFails        = [bool]$AptFails
            WatchdogHeld    = [bool]$WatchdogHeld
        }
        foreach ($name in $Module) { [void]$fake.Modules.Add($name) }
        foreach ($dir in @('/etc/sysctl.d', '/etc/systemd/system', '/etc/modules-load.d', '/etc/modprobe.d', '/var/log/journal', '/var/lib',
                '/usr/local/lib', '/sys/module/pstore', '/sys/class/watchdog', '/boot')) { Add-FakeDirectory -Fake $fake -Path $dir }
        if (-not $NoSystemd) { Add-FakeDirectory -Fake $fake -Path '/run/systemd/system' }
        if (-not $LegacyBios) { Add-FakeDirectory -Fake $fake -Path '/sys/firmware/efi' }
        if (-not $NoNetworkManager) { Add-FakeDirectory -Fake $fake -Path '/etc/NetworkManager/dispatcher.d' }
        $fake.Files['/proc/cpuinfo'] = "processor`t: 0`nvendor_id`t: $Vendor`n"
        $fake.Files['/etc/sysctl.d/10-console-messages.conf'] = "kernel.printk = 4 4 1 7`n"
        $fake.Files['/boot/config-6.8.0-31-generic'] = $KernelConfig
        $fake.Files['/usr/sbin/modinfo'] = ''
        foreach ($key in $Sysctl.Keys) { $fake.Sysctl[$key] = $Sysctl[$key] }
        foreach ($key in $MissingSysctl) { $fake.Sysctl.Remove($key) }
        foreach ($path in $File.Keys) {
            Add-FakeDirectory -Fake $fake -Path ($path.Substring(0, $path.LastIndexOf('/')))
            $fake.Files[$path] = $File[$path]
            $fake.Modes[$path] = '0644'
        }
        if ($RasdaemonInstalled -or $RasdaemonHeld) {
            [void]$fake.Packages.Add('rasdaemon')
            $fake.Units['rasdaemon.service'] = @{ Enabled = 'enabled'; Active = 'active' }
        }
        if ($RasdaemonHeld) { [void]$fake.Held.Add('rasdaemon') }
        if ($RasdaemonConfigFiles) { [void]$fake.ConfigFiles.Add('rasdaemon') }
        $script:Fake = $fake
        return $fake
    }

    # The kernel module file of each module the simulated host knows.
    $script:FakeModuleFile = @{
        'iTCO_wdt'       = 'kernel/drivers/watchdog/iTCO_wdt.ko.zst'
        'sp5100_tco'     = 'kernel/drivers/watchdog/sp5100_tco.ko.zst'
        'i6300esb'       = 'kernel/drivers/watchdog/i6300esb.ko.zst'
        'softdog'        = 'kernel/drivers/watchdog/softdog.ko.zst'
        'watchdog'       = 'kernel/drivers/watchdog/watchdog.ko.zst'
        'sch56xx_common' = 'kernel/drivers/hwmon/sch56xx-common.ko.zst'
        'efi_pstore'     = 'kernel/drivers/firmware/efi/efi-pstore.ko.zst'
        'netconsole'     = 'kernel/drivers/net/netconsole.ko.zst'
    }
    # Each watchdog driver's identity, in the order the drivers take
    # watchdog0: one built into the kernel probes before any module loads.
    $script:FakeWatchdogIdentity = [ordered]@{
        'iTCO_wdt'       = 'iTCO_wdt'
        'sp5100_tco'     = 'SP5100 TCO timer'
        'i6300esb'       = 'i6300ESB timer'
        'sch56xx_common' = 'sch56xx watchdog'
        'softdog'        = 'Software Watchdog'
    }

    function Add-FakeDirectory {
        param($Fake, [string]$Path)
        $current = $Path
        while ($current) {
            [void]$Fake.Dirs.Add($current)
            $index = $current.LastIndexOf('/')
            $current = if ($index -gt 0) { $current.Substring(0, $index) } else { '' }
        }
    }

    function Get-FakeWatchdogIdentity {
        foreach ($name in $script:Fake.BuiltIn) { if ($script:FakeWatchdogIdentity.Contains($name)) { return $script:FakeWatchdogIdentity[$name] } }
        foreach ($name in $script:FakeWatchdogIdentity.Keys) { if ($script:Fake.Modules.Contains($name)) { return $script:FakeWatchdogIdentity[$name] } }
        return $null
    }

    function Get-FakeModuleList {
        # name, size, use count, the modules that use it, state, address. The
        # watchdog core, loaded as a module, is used by every watchdog driver.
        $fake = $script:Fake
        $lines = foreach ($name in @($fake.Modules | Where-Object { $_ -ne 'pstore' } | Sort-Object)) {
            $users = if ($name -eq 'watchdog') { @($script:FakeWatchdogIdentity.Keys | Where-Object { $fake.Modules.Contains($_) }) } else { @() }
            $usedBy = if ($users.Count -gt 0) { ($users -join ',') + ',' } else { '-' }
            "$name 16384 $($users.Count) $usedBy Live 0x0000000000000000"
        }
        return (@($lines) -join "`n") + "`n"
    }

    function Get-FakeUnitState {
        param([string]$Name)
        # A unit Enable installs exists only while its file does; a template
        # instance exists while the template does.
        if ($Name -like 'yuruna-*') {
            $file = if ($Name -match '^(?<base>[^@]+@)[^.]+(?<ext>\..+)$') { "/etc/systemd/system/$($Matches['base'])$($Matches['ext'])" } else { "/etc/systemd/system/$Name" }
            if (-not $script:Fake.Files.ContainsKey($file)) { return @{ Enabled = 'not-found'; Active = 'inactive' } }
        }
        $unit = $script:Fake.Units[$Name]
        if (-not $unit) {
            if ($Name -like 'yuruna-*') { return @{ Enabled = 'disabled'; Active = 'inactive' } }
            return @{ Enabled = 'not-found'; Active = 'inactive' }
        }
        return @{ Enabled = $unit.Enabled; Active = $unit.Active }
    }

    function Get-FakeText {
        param([string]$Path)
        $fake = $script:Fake
        if ($Path -match '^/proc/sys/(?<a>[^/]+)/(?<b>[^/]+)$') { return $fake.Sysctl["$($Matches['a']).$($Matches['b'])"] }
        if ($Path -eq '/proc/modules') { return (Get-FakeModuleList) }
        if ($Path -eq "/lib/modules/$($fake.Sysctl['kernel.osrelease'])/modules.builtin") {
            # The core where it is not a module, a pretimeout governor, and
            # every driver built in.
            $builtin = @('kernel/fs/pstore/pstore.ko', 'kernel/drivers/watchdog/pretimeout_noop.ko')
            if (-not $fake.Modules.Contains('watchdog')) { $builtin += 'kernel/drivers/watchdog/watchdog.ko' }
            $builtin += @($fake.BuiltIn | ForEach-Object { ($script:FakeModuleFile[$_] -replace '\.zst$', '') })
            return (($builtin -join "`n") + "`n")
        }
        if ($Path -eq '/sys/module/pstore/parameters/backend') { if ($fake.Modules.Contains('efi_pstore')) { return "efi_pstore`n" } else { return "(null)`n" } }
        if ($Path -match '^/sys/module/(?<m>[^/]+)/refcnt$') {
            $m = $Matches['m']
            if (-not $fake.Modules.Contains($m)) { return $null }
            if ($m -in @('iTCO_wdt', 'sp5100_tco', 'i6300esb') -and $fake.RuntimeWatchdog -ne '0') { return "1`n" }
            # configfs pins the subsystem's module and the item's owner, both
            # netconsole, for as long as a target directory exists.
            if ($m -eq 'netconsole' -and $fake.Netconsole.Present) { return "2`n" }
            return "0`n"
        }
        if ($Path -match '^/sys/class/watchdog/watchdog0/(?<attribute>\w+)$') {
            $identity = Get-FakeWatchdogIdentity
            if (-not $identity) { return $null }
            switch ($Matches['attribute']) {
                'identity' { return "$identity`n" }
                'state' { if ($fake.RuntimeWatchdog -ne '0' -or $fake.WatchdogHeld) { return "active`n" } else { return "inactive`n" } }
                'nowayout' { return "0`n" }
            }
            return $null
        }
        if ($Path -match '^/sys/kernel/config/netconsole/yuruna/(?<attribute>\w+)$') {
            switch ($Matches['attribute']) {
                'enabled' { return "$($fake.Netconsole.Enabled)`n" }
                'remote_ip' { return "$($fake.Netconsole.Address)`n" }
                'remote_port' { return "$($fake.Netconsole.Port)`n" }
            }
            return $null
        }
        if ($fake.Files.ContainsKey($Path)) { return $fake.Files[$Path] }
        return $null
    }

    function Test-FakePath {
        param([string]$Path)
        $fake = $script:Fake
        if ($fake.Files.ContainsKey($Path) -or $fake.Dirs.Contains($Path)) { return $true }
        if ($Path -eq '/sys/kernel/config/netconsole/yuruna') { return [bool]$fake.Netconsole.Present }
        if ($Path -match '^/proc/sys/') { return $null -ne (Get-FakeText -Path $Path) }
        if ($Path -match '^/sys/module/(?<m>[^/]+)$') { return $fake.Modules.Contains($Matches['m']) }
        if ($Path -eq '/sys/class/watchdog/watchdog0') { return $null -ne (Get-FakeWatchdogIdentity) }
        return $false
    }

    function Get-FakeEntry {
        param([string]$Path)
        $fake = $script:Fake
        $entries = [Collections.Generic.List[string]]::new()
        foreach ($candidate in @($fake.Files.Keys) + @($fake.Dirs)) {
            if ($candidate.StartsWith("$Path/", [StringComparison]::Ordinal) -and $candidate.Substring($Path.Length + 1) -notmatch '/') { $entries.Add($candidate) }
        }
        if ($Path -eq '/sys/class/watchdog' -and (Get-FakeWatchdogIdentity)) { $entries.Add('/sys/class/watchdog/watchdog0') }
        return @($entries | Sort-Object -Unique)
    }

    function Invoke-FakeNative {
        param([string]$FilePath, [string[]]$ArgumentList)
        $fake = $script:Fake
        if ($FilePath -eq 'systemctl' -and $ArgumentList[0] -eq 'is-enabled') { return @{ ExitCode = 0; Output = (Get-FakeUnitState -Name $ArgumentList[1]).Enabled } }
        if ($FilePath -eq 'systemctl' -and $ArgumentList[0] -eq 'is-active') { return @{ ExitCode = 0; Output = (Get-FakeUnitState -Name $ArgumentList[1]).Active } }
        if ($FilePath -eq 'systemctl' -and $ArgumentList[0] -eq 'show') { return @{ ExitCode = 0; Output = $fake.RuntimeWatchdog } }
        if ($FilePath -eq 'dpkg-query') {
            if ($fake.Held.Contains($ArgumentList[-1])) { return @{ ExitCode = 0; Output = 'hi ' } }
            if ($fake.Packages.Contains($ArgumentList[-1])) { return @{ ExitCode = 0; Output = 'ii ' } }
            if ($fake.ConfigFiles.Contains($ArgumentList[-1])) { return @{ ExitCode = 0; Output = 'rc ' } }
            return @{ ExitCode = 1; Output = "dpkg-query: no packages found matching $($ArgumentList[-1])" }
        }
        if ($FilePath -eq '/usr/sbin/modinfo' -and $ArgumentList[0] -eq '-F' -and $ArgumentList[1] -eq 'filename') {
            # One line per name, in order; an unknown one is an error line.
            $exit = 0
            $lines = foreach ($name in @($ArgumentList | Select-Object -Skip 2)) {
                if ($script:FakeModuleFile.ContainsKey($name)) { "/lib/modules/$($fake.Sysctl['kernel.osrelease'])/$($script:FakeModuleFile[$name])" } else { $exit = 1; "modinfo: ERROR: Module $name not found." }
            }
            return @{ ExitCode = $exit; Output = (@($lines) -join "`n") }
        }
        throw "unexpected native command: $FilePath $($ArgumentList -join ' ')"
    }

    function Invoke-FakeSudo {
        param([string[]]$Argument)
        $fake = $script:Fake
        $fake.Calls.Add(($Argument -join ' '))
        $ok = @{ ExitCode = 0; Output = '' }
        switch ($Argument[0]) {
            'true' { return $ok }
            'install' {
                if ($Argument -ccontains '-d') { Add-FakeDirectory -Fake $fake -Path $Argument[-1]; return $ok }
                $destination = $Argument[-1]
                $content = [IO.File]::ReadAllText($Argument[-2])
                Add-FakeDirectory -Fake $fake -Path ($destination.Substring(0, $destination.LastIndexOf('/')))
                $fake.Files[$destination] = $content
                $fake.Modes[$destination] = $Argument[[array]::IndexOf($Argument, '-m') + 1]
                if ($destination -eq $script:StatePath) { $fake.StateWrites.Add($content) }
                return $ok
            }
            'rm' {
                $target = $Argument[-1]
                foreach ($path in @($fake.Files.Keys)) { if ($path -eq $target -or ($Argument[1] -eq '-rf' -and $path.StartsWith("$target/", [StringComparison]::Ordinal))) { [void]$fake.Files.Remove($path); [void]$fake.Modes.Remove($path) } }
                if ($Argument[1] -eq '-rf') { foreach ($dir in @($fake.Dirs)) { if ($dir -eq $target -or $dir.StartsWith("$target/", [StringComparison]::Ordinal)) { [void]$fake.Dirs.Remove($dir) } } }
                return $ok
            }
            'rmdir' {
                $target = $Argument[-1]
                if ($target -eq '/sys/kernel/config/netconsole/yuruna') {
                    # Removing a target disables it first if it is enabled.
                    if (-not $fake.Netconsole.Present) { return @{ ExitCode = 1; Output = "rmdir: failed to remove '$target': No such file or directory" } }
                    $fake.Netconsole = @{ Present = $false; Enabled = '0'; Address = ''; Port = '' }
                    return $ok
                }
                if (@(Get-FakeEntry -Path $target).Count -eq 0) { [void]$fake.Dirs.Remove($target) }
                return $ok
            }
            'sysctl' {
                # The kernel prints a multi-value setting tab-separated,
                # however it was written.
                $key, $value = $Argument[2] -split '=', 2
                $fake.Sysctl[$key] = ($value.Trim() -split '\s+') -join "`t"
                return $ok
            }
            'modprobe' {
                if ($Argument[1] -eq '-r') { [void]$fake.Modules.Remove($Argument[2]) } else { [void]$fake.Modules.Add($Argument[1]) }
                return $ok
            }
            'apt-get' { return $ok }
            'env' {
                $package = $Argument[-1]
                if ($Argument -ccontains 'install') {
                    if ($fake.AptFails) { return @{ ExitCode = 100; Output = "E: Unable to locate package $package" } }
                    [void]$fake.Packages.Add($package)
                    [void]$fake.ConfigFiles.Remove($package)
                    $fake.Units["$package.service"] = @{ Enabled = 'disabled'; Active = 'inactive' }
                } elseif ($Argument -ccontains 'remove' -or $Argument -ccontains 'purge') {
                    # remove keeps the configuration files and the unit's
                    # links (dpkg 'rc'); purge deletes them.
                    [void]$fake.Packages.Remove($package)
                    $fake.Units.Remove("$package.service")
                    if ($Argument -ccontains 'remove') { [void]$fake.ConfigFiles.Add($package) } else { [void]$fake.ConfigFiles.Remove($package) }
                }
                return $ok
            }
            'systemctl' {
                $verb = $Argument[1]
                $unit = $Argument[-1]
                if ($verb -in @('daemon-reload')) { return $ok }
                if ($verb -eq 'daemon-reexec') {
                    $dropIn = $fake.Files['/etc/systemd/system.conf.d/99-yuruna-deep-diagnostics.conf']
                    $fake.RuntimeWatchdog = if ($dropIn -match 'RuntimeWatchdogSec=60s') { '1min' } else { '0' }
                    return $ok
                }
                $state = Get-FakeUnitState -Name $unit
                if ($state.Enabled -eq 'not-found') { return @{ ExitCode = 5; Output = "Unit $unit not found." } }
                if (-not $fake.Units.ContainsKey($unit)) { $fake.Units[$unit] = @{ Enabled = $state.Enabled; Active = $state.Active } }
                switch ($verb) {
                    'enable' { $fake.Units[$unit].Enabled = 'enabled'; if ($Argument -ccontains '--now') { $fake.Units[$unit].Active = 'active' } }
                    'disable' { $fake.Units[$unit].Enabled = 'disabled'; if ($Argument -ccontains '--now') { $fake.Units[$unit].Active = 'inactive' } }
                    'stop' { $fake.Units[$unit].Active = 'inactive' }
                    default {
                        # start and restart. The boot evidence unit is a oneshot
                        # that leaves a bundle behind.
                        if ($unit -eq 'yuruna-boot-evidence.service') {
                            $fake.Files['/var/log/yuruna/deep-diagnostics/boot-20261103T120000Z-1a2b3c4d.txt'] = "schema=yuruna.deep-diagnostics-boot/v1`n"
                        } else {
                            $fake.Units[$unit].Active = 'active'
                        }
                    }
                }
                return $ok
            }
            '/usr/local/lib/yuruna/deep-diagnostics/yuruna-netconsole.sh' {
                if ($Argument[1] -ne 'apply') { break }
                $target = ([regex]::Match($fake.Files['/etc/yuruna/deep-diagnostics/netconsole.conf'], '(?m)^TARGET=(?<a>[^:\s]+):(?<p>\d+)')).Groups
                [void]$fake.Modules.Add('netconsole')
                $fake.Netconsole = @{ Present = $true; Enabled = '1'; Address = $target['a'].Value; Port = $target['p'].Value }
                return $ok
            }
        }
        throw "unexpected sudo command: $($Argument -join ' ')"
    }

    function Get-FakeSnapshot {
        # The whole host as one comparable text.
        param($Fake = $script:Fake)
        $units = [ordered]@{}
        foreach ($name in @(@($Fake.Units.Keys) + @('yuruna-vitals.service', 'yuruna-boot-evidence.service', 'yuruna-netconsole.service', 'yuruna-watchdog-driver@iTCO_wdt.service', 'yuruna-watchdog-driver@i6300esb.service') | Sort-Object -Unique)) {
            $state = Get-FakeUnitState -Name $name
            $units[$name] = "$($state.Enabled)/$($state.Active)"
        }
        $files = [ordered]@{}
        foreach ($path in @($Fake.Files.Keys | Sort-Object)) { $files[$path] = "$($Fake.Modes[$path])|$($Fake.Files[$path])" }
        return ([ordered]@{
                Files      = $files
                Dirs       = @($Fake.Dirs | Sort-Object)
                Sysctl     = $Fake.Sysctl
                Units      = $units
                Modules    = @($Fake.Modules | Sort-Object)
                Packages   = @($Fake.Packages | Sort-Object)
                # Packages removed with their configuration kept (dpkg 'rc').
                Removed    = @($Fake.ConfigFiles | Sort-Object)
                Netconsole = "$($Fake.Netconsole.Present)|$($Fake.Netconsole.Enabled)|$($Fake.Netconsole.Address)|$($Fake.Netconsole.Port)"
                Watchdog   = $Fake.RuntimeWatchdog
            } | ConvertTo-Json -Depth 5)
    }

    function Get-FakeState {
        if (-not $script:Fake.Files.ContainsKey($script:StatePath)) { return $null }
        return ($script:Fake.Files[$script:StatePath] | ConvertFrom-Json -AsHashtable)
    }

    function Invoke-FakeEnable {
        param([string]$Target = '', [switch]$Preview)
        $plan = Get-DeepDiagnosticsPlan -NetconsoleTarget $Target
        Write-DeepDiagnosticsPlan -Plan $plan -InformationVariable shown -InformationAction SilentlyContinue
        $result = Invoke-DeepDiagnosticsEnable -Plan $plan -WhatIf:$Preview -Confirm:$false -InformationVariable applied -InformationAction SilentlyContinue -WarningVariable warned -WarningAction SilentlyContinue
        return [pscustomobject]@{ Plan = $plan; Result = $result; Shown = @($shown | ForEach-Object { "$($_.MessageData)" }); Applied = @($applied | ForEach-Object { "$($_.MessageData)" }); Warned = @($warned | ForEach-Object { "$_" }) }
    }

    function Invoke-FakeDisable {
        param([switch]$RemoveEvidence, [switch]$Preview)
        $read = Read-DeepDiagnosticsState
        $plan = Get-DeepDiagnosticsRestorePlan -State $read.State -RemoveEvidence:$RemoveEvidence
        Write-DeepDiagnosticsRestorePlan -Plan $plan -InformationVariable shown -InformationAction SilentlyContinue
        $result = Invoke-DeepDiagnosticsDisable -Plan $plan -WhatIf:$Preview -Confirm:$false -InformationVariable applied -InformationAction SilentlyContinue -WarningVariable warned -WarningAction SilentlyContinue
        return [pscustomobject]@{ Plan = $plan; Result = $result; Shown = @($shown | ForEach-Object { "$($_.MessageData)" }); Applied = @($applied | ForEach-Object { "$($_.MessageData)" }); Warned = @($warned | ForEach-Object { "$_" }) }
    }

    function Get-Component {
        param($Plan, [string]$Name)
        return @($Plan.Components | Where-Object Name -eq $Name)[0]
    }

    # "key|name=value|..." for a change line, the way the mocked renderer writes it.
    function Format-ChangeLine {
        param([string]$Key, [string]$Previous, [string]$New)
        return "host.deep_diagnostics_change|key=$Key|new=$New|previous=$Previous"
    }

    # A shell fixture made of lifted functions and the lines that call them.
    function Invoke-HelperFunction {
        param([string]$Script, [string[]]$Function, [string]$Body, [hashtable]$Environment = @{})
        $text = [IO.File]::ReadAllText((Join-Path $script:Helpers $Script))
        $lifted = Get-YurunaTestShellFunction -Text $text -Name $Function
        return (Invoke-YurunaTestShell -Body ("set -u`n" + $lifted + "`n" + $Body) -Environment $Environment)
    }

    # A temporary directory holding a journalctl stand-in, to put first on PATH.
    function New-FakeJournalctl {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a stand-in into a new temporary directory.')]
        param([string]$Script)
        $bin = New-YurunaTestTempDir -Prefix 'yuruna-fake-journalctl'
        [IO.File]::WriteAllText((Join-Path $bin 'journalctl'), $Script.Replace("`r`n", "`n"))
        if (-not $IsWindows) { & chmod +x (Join-Path $bin 'journalctl') }
        return $bin
    }
}

Describe 'Deep diagnostics mode' {
    BeforeEach {
        # The six host-access functions and the renderer, against $script:Fake.
        Mock -ModuleName $script:ModuleName Test-DeepDiagnosticsLinux { $true }
        Mock -ModuleName $script:ModuleName Test-DeepDiagnosticsPath { Test-FakePath -Path $Path }
        Mock -ModuleName $script:ModuleName Get-DeepDiagnosticsFileText { Get-FakeText -Path $Path }
        Mock -ModuleName $script:ModuleName Get-DeepDiagnosticsDirectoryEntry { Get-FakeEntry -Path $Path }
        Mock -ModuleName $script:ModuleName Invoke-DeepDiagnosticsNative { Invoke-FakeNative -FilePath $FilePath -ArgumentList $ArgumentList }
        Mock -ModuleName $script:ModuleName Invoke-DeepDiagnosticsSudo { Invoke-FakeSudo -Argument $Argument }
        Mock -ModuleName $script:ModuleName Format-YurunaOperatorMessage {
            (@($Key) + @($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" })) -join '|'
        }
    }

    Context 'Enable-DeepDiagnostics plan' {
        It 'reports every value it will change as key: previous -> new, the operator value included' {
            [void](New-FakeHost -Sysctl @{ 'kernel.panic' = '10' })
            $run = Invoke-FakeEnable -Preview
            $sysctl = Get-Component -Plan $run.Plan -Name 'sysctl'
            $panic = @($sysctl.Changes | Where-Object Key -eq 'kernel.panic')[0]
            Assert-Equal '10' $panic.Previous 'the operator value is the previous value'
            Assert-Equal '30' $panic.New 'kernel.panic reboots 30 seconds after a panic'
            Assert-True ($run.Shown -contains (Format-ChangeLine -Key 'kernel.panic' -Previous '10' -New '30')) "the plan shows the change before anything is written: $($run.Shown -join ' / ')"
            $printk = @($sysctl.Changes | Where-Object Key -eq 'kernel.printk')[0]
            Assert-Equal '4 4 1 7' $printk.Previous 'the tab-separated runtime value reads as single spaces'
            Assert-Equal '6 4 1 7' $printk.New 'console level 6 lets notices reach netconsole'
        }

        It 'changes nothing under -WhatIf' {
            [void](New-FakeHost)
            $before = Get-FakeSnapshot
            $run = Invoke-FakeEnable -Preview
            Assert-Equal 0 $run.Result.ExitCode 'a preview succeeds'
            Assert-Equal 0 $script:Fake.Calls.Count "no privileged command runs: $($script:Fake.Calls -join ' / ')"
            Assert-Equal $before (Get-FakeSnapshot) 'the host is unchanged'
        }

        It 'writes only the sysctl keys the kernel exposes, never hung_task_panic' {
            [void](New-FakeHost -MissingSysctl @('kernel.hardlockup_panic', 'kernel.hardlockup_all_cpu_backtrace'))
            $run = Invoke-FakeEnable
            $dropIn = $script:Fake.Files[$script:SysctlDropIn]
            Assert-Match '(?m)^kernel\.softlockup_panic = 1$' $dropIn 'soft lockups panic'
            Assert-Match '(?m)^kernel\.panic_on_oops = 1$' $dropIn 'oopses panic'
            Assert-Match '(?m)^kernel\.panic = 30$' $dropIn 'a panic reboots after 30 seconds'
            Assert-Match '(?m)^kernel\.printk = 6 4 1 7$' $dropIn 'notices reach the consoles'
            Assert-False ($dropIn -match 'hardlockup') 'a key the kernel does not expose is left out'
            Assert-False ($dropIn -match 'hung_task') 'slow storage must not panic a host that is not hung'
            $notes = @((Get-Component -Plan $run.Plan -Name 'sysctl').Notes)
            Assert-True ($notes -contains 'host.deep_diagnostics_sysctl_not_exposed|key=kernel.hardlockup_panic') "the omission is reported: $($notes -join ' / ')"
            Assert-Equal '30' $script:Fake.Sysctl['kernel.panic'] 'the value applies at runtime too'
        }

        It 'reports a later-sorting drop-in that overrides one of its keys at boot' {
            [void](New-FakeHost -File @{ '/etc/sysctl.d/zz-local.conf' = "kernel/panic = 5`n" })
            $run = Invoke-FakeEnable -Preview
            $notes = @((Get-Component -Plan $run.Plan -Name 'sysctl').Notes)
            Assert-True ($notes -contains 'host.deep_diagnostics_setting_overridden|key=kernel.panic|path=/etc/sysctl.d/zz-local.conf|value=5') "the override is named: $($notes -join ' / ')"
        }

        It 'generates the journald, watchdog and unit contents the boot depends on' {
            [void](New-FakeHost)
            [void](Invoke-FakeEnable -Target '192.168.7.50')
            $files = $script:Fake.Files
            Assert-Match '(?ms)^\[Journal\]\s*^Storage=persistent$\s*^SyncIntervalSec=10s$' $files['/etc/systemd/journald.conf.d/99-yuruna-deep-diagnostics.conf'] 'journald drop-in'
            $watchdog = $files['/etc/systemd/system.conf.d/99-yuruna-deep-diagnostics.conf']
            Assert-Match '(?ms)^\[Manager\]\s*^RuntimeWatchdogSec=60s$' $watchdog 'the runtime watchdog drop-in'
            Assert-False ($watchdog -match 'WatchdogDevice') 'watchdog0 is systemd''s default device'
            Assert-Match '(?m)^After=systemd-pstore\.service systemd-journal-flush\.service$' $files['/etc/systemd/system/yuruna-boot-evidence.service'] 'the bundle waits for pstore and the journal flush'
            Assert-Match '(?m)^After=network-online\.target$' $files['/etc/systemd/system/yuruna-netconsole.service'] 'the target is set once the network is up'
            Assert-Match '(?m)^ExecStart=/sbin/modprobe %i$' $files['/etc/systemd/system/yuruna-watchdog-driver@.service'] 'the driver is loaded by name at boot'
            Assert-Equal "# Written by host/ubuntu.kvm/Enable-DeepDiagnostics.ps1; Disable-DeepDiagnostics.ps1 removes it.`nTARGET=192.168.7.50:6666`n" $files['/etc/yuruna/deep-diagnostics/netconsole.conf'] 'the default port is 6666'
            foreach ($script in @('yuruna-netconsole.sh', 'yuruna-vitals.sh', 'yuruna-boot-evidence.sh')) {
                Assert-Equal '0755' $script:Fake.Modes["/usr/local/lib/yuruna/deep-diagnostics/$script"] "$script is executable"
            }
            Assert-Equal '0755' $script:Fake.Modes['/etc/NetworkManager/dispatcher.d/90-yuruna-netconsole'] 'NetworkManager runs only an executable hook'
            Assert-Equal 'enabled' (Get-FakeUnitState -Name 'yuruna-watchdog-driver@iTCO_wdt.service').Enabled 'the Intel driver loads at every boot'
            Assert-Equal '1min' $script:Fake.RuntimeWatchdog 'systemd re-executed with the watchdog armed'
            Assert-Equal '1' $script:Fake.Netconsole.Enabled 'the netconsole target is up'
        }

        It 'turns efi-pstore on through a module option only where the kernel build disables it' {
            [void](New-FakeHost)
            [void](Invoke-FakeEnable)
            Assert-Equal "# Written by host/ubuntu.kvm/Enable-DeepDiagnostics.ps1; Disable-DeepDiagnostics.ps1 removes it.`nefi_pstore`n" $script:Fake.Files['/etc/modules-load.d/yuruna-deep-diagnostics.conf'] 'efi_pstore loads at every boot'
            Assert-False ($script:Fake.Files.ContainsKey('/etc/modprobe.d/yuruna-deep-diagnostics.conf')) 'no option where the build enables it'
            Assert-True $script:Fake.Modules.Contains('efi_pstore') 'efi_pstore is loaded now'
            [void](New-FakeHost -KernelConfig "CONFIG_EFI_VARS_PSTORE=m`nCONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y`n")
            [void](Invoke-FakeEnable)
            Assert-Match '(?m)^options efi_pstore pstore_disable=N$' $script:Fake.Files['/etc/modprobe.d/yuruna-deep-diagnostics.conf'] 'the option turns it on'
            $calls = @($script:Fake.Calls)
            $option = [array]::FindIndex([string[]]$calls, [Predicate[string]]{ param($c) $c -like '*/etc/modprobe.d/yuruna-deep-diagnostics.conf' })
            $load = [array]::IndexOf([string[]]$calls, 'modprobe efi_pstore')
            Assert-True ($option -ge 0 -and $option -lt $load) "the option is on disk before the module loads: $($calls -join ' / ')"
        }

        It 'uses a hardware watchdog that is already registered and loads its driver at every boot' {
            [void](New-FakeHost -Vendor 'AuthenticAMD' -Module @('sp5100_tco'))
            $run = Invoke-FakeEnable
            Assert-False (@((Get-Component -Plan $run.Plan -Name 'watchdog').Changes | Where-Object Key -eq 'sp5100_tco').Count -gt 0) 'a loaded driver is not loaded again'
            Assert-Equal 'enabled' (Get-FakeUnitState -Name 'yuruna-watchdog-driver@sp5100_tco.service').Enabled 'the deny-listed driver is named again at boot'
            Assert-Equal '1min' $script:Fake.RuntimeWatchdog 'systemd arms the watchdog'
            Assert-True (@((Get-FakeState).components.watchdog.modules | Where-Object { $_.name -eq 'sp5100_tco' }).Count -eq 0) 'a driver that was loaded before is not recorded for unloading'
        }

        It 'loads at every boot the driver that provides the registered watchdog, not the CPU vendor''s' {
            # A KVM guest on an AMD host: Ubuntu deny-lists i6300esb, which was
            # loaded by hand, and the watchdog core is a module too.
            [void](New-FakeHost -Vendor 'AuthenticAMD' -Module @('watchdog', 'i6300esb'))
            $before = Get-FakeSnapshot
            $run = Invoke-FakeEnable
            $unit = 'yuruna-watchdog-driver@i6300esb.service'
            Assert-True ($run.Shown -contains (Format-ChangeLine -Key $unit -Previous 'not-found, inactive' -New 'enabled, inactive')) "the plan names the unit that loads it at boot: $($run.Shown -join ' / ')"
            Assert-Equal 'enabled' (Get-FakeUnitState -Name $unit).Enabled 'the driver that provides /dev/watchdog0 loads at every boot'
            Assert-Match '(?m)^ExecStart=/sbin/modprobe %i$' $script:Fake.Files['/etc/systemd/system/yuruna-watchdog-driver@.service'] 'through the template unit'
            Assert-Equal 0 @($script:Fake.Calls | Where-Object { $_ -match 'sp5100_tco' }).Count "the vendor's driver is not involved: $($script:Fake.Calls -join ' / ')"
            Assert-Equal '1min' $script:Fake.RuntimeWatchdog 'systemd arms the watchdog'
            $state = Get-FakeState
            Assert-Equal 'applied' $state.components.watchdog.status 'the watchdog is in place now and after a reboot'
            Assert-True (@($state.components.watchdog.units | Where-Object { $_.name -eq $unit -and $_.owned }).Count -eq 1) 'the unit is recorded for Disable to remove'
            Assert-Equal 0 @($state.components.watchdog.modules).Count 'a driver that was loaded before is not recorded for unloading'
            $disable = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $disable.Result.ExitCode "Disable succeeds; warnings: $($disable.Warned -join ' / ')"
            Assert-Equal $before (Get-FakeSnapshot) 'the unit and template are gone and the driver stays loaded, as before'
        }

        It 'skips the watchdog, with the reason, when the driver that provides it cannot be identified' {
            # A driver outside drivers/watchdog, and none built in.
            [void](New-FakeHost -Module @('sch56xx_common'))
            [void](Invoke-FakeEnable)
            $state = Get-FakeState
            Assert-Equal 'skipped' $state.components.watchdog.status 'nothing would load the driver at the next boot'
            Assert-Equal 'host.deep_diagnostics_watchdog_provider_unknown|device=/dev/watchdog0|drivers=host.deep_diagnostics_value_none|identity=sch56xx watchdog' $state.components.watchdog.reason 'the reason names the device'
            Assert-Equal '0' $script:Fake.RuntimeWatchdog 'nothing is armed for this boot only'
            Assert-False ($script:Fake.Files.ContainsKey('/etc/systemd/system.conf.d/99-yuruna-deep-diagnostics.conf')) 'systemd is not given a watchdog'
            Assert-Equal 'applied' $state.components.journald.status 'the rest applies'
            # Two loaded hardware watchdog drivers: which one is watchdog0
            # cannot be told.
            [void](New-FakeHost -Module @('iTCO_wdt', 'i6300esb'))
            [void](Invoke-FakeEnable)
            $state = Get-FakeState
            Assert-Equal 'skipped' $state.components.watchdog.status 'an ambiguous provider is not guessed'
            Assert-Equal 'host.deep_diagnostics_watchdog_provider_unknown|device=/dev/watchdog0|drivers=i6300esb, iTCO_wdt|identity=iTCO_wdt' $state.components.watchdog.reason 'the reason lists the candidates'
        }

        It 'needs no boot unit for a watchdog driver built into the kernel' {
            [void](New-FakeHost -BuiltIn @('iTCO_wdt'))
            $run = Invoke-FakeEnable
            Assert-Equal 'applied' (Get-FakeState).components.watchdog.status 'the driver is there at every boot'
            Assert-Equal '1min' $script:Fake.RuntimeWatchdog 'systemd arms the watchdog'
            Assert-False ($script:Fake.Files.ContainsKey('/etc/systemd/system/yuruna-watchdog-driver@.service')) 'no unit loads a built-in driver'
            Assert-Equal 0 @($script:Fake.Calls | Where-Object { $_ -match 'iTCO_wdt|yuruna-watchdog-driver' }).Count "nothing is loaded or enabled for it: $($script:Fake.Calls -join ' / ')"
            Assert-Equal 0 @((Get-Component -Plan $run.Plan -Name 'watchdog').Changes | Where-Object { $_.Key -like 'yuruna-watchdog-driver*' }).Count 'the plan names no unit'
        }

        It 'sets the target at boot only, and says so, when NetworkManager is not installed' {
            [void](New-FakeHost -NoNetworkManager)
            $run = Invoke-FakeEnable -Target '192.168.7.50:7000'
            Assert-False ($script:Fake.Files.ContainsKey('/etc/NetworkManager/dispatcher.d/90-yuruna-netconsole')) 'no hook without NetworkManager'
            Assert-True (@((Get-Component -Plan $run.Plan -Name 'netconsole').Notes) -contains 'host.deep_diagnostics_netconsole_no_dispatcher') 'the limitation is reported'
            Assert-Equal '7000' $script:Fake.Netconsole.Port 'the given port is used'
        }
    }

    Context 'Enable-DeepDiagnostics state record' {
        It 'records the prior state before the first change' {
            [void](New-FakeHost -Sysctl @{ 'kernel.panic' = '10' })
            [void](Invoke-FakeEnable)
            $mutating = @($script:Fake.Calls | Where-Object { $_ -ne 'true' })
            Assert-Match ([regex]::Escape($script:StatePath) + '$') $mutating[0] "the first change is the state file: $($mutating[0])"
            $first = $script:Fake.StateWrites[0] | ConvertFrom-Json -AsHashtable
            $panic = @($first.components.sysctl.sysctl | Where-Object { $_.key -eq 'kernel.panic' })[0]
            Assert-Equal '10' $panic.previous 'the operator value is on disk before anything changes'
            Assert-Equal 'failed' $first.components.watchdog.status 'a component not yet applied reads as not in place'
            Assert-Equal 'host.deep_diagnostics_reason_interrupted' $first.components.watchdog.reason 'and says why'
        }

        It 'keeps the state contract another diagnostic reads' {
            [void](New-FakeHost)
            [void](Invoke-FakeEnable -Target '192.168.7.50:6666')
            $state = Get-FakeState
            Assert-Equal 'yuruna.deep-diagnostics-state/v1' $state.schema 'schema'
            # The file on disk is the contract, so the timestamp is read as text.
            Assert-Match '"enabledAtUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"' $script:Fake.Files[$script:StatePath] 'enabledAtUtc is ISO-8601 UTC'
            Assert-True ([bool]$state.enabledBy) 'enabledBy names the account'
            Assert-Equal 'host.ubuntu.kvm' $state.hostType 'hostType'
            Assert-Equal '192.168.7.50:6666' $state.netconsoleTarget 'netconsoleTarget'
            foreach ($name in @('sysctl', 'pstore', 'watchdog', 'journald', 'rasdaemon', 'netconsole', 'vitals', 'bootEvidence')) {
                Assert-Equal 'applied' $state.components[$name].status "$name is applied"
                Assert-True $state.components[$name].Contains('reason') "$name carries a reason field"
            }
            Assert-Equal '0644' $script:Fake.Modes[$script:StatePath] 'the state is readable without privilege'
        }

        It 'changes nothing on a second run' {
            [void](New-FakeHost)
            [void](Invoke-FakeEnable -Target '192.168.7.50')
            $state = $script:Fake.Files[$script:StatePath]
            $snapshot = Get-FakeSnapshot
            $script:Fake.Calls.Clear()
            $second = Invoke-FakeEnable
            Assert-Equal 0 $second.Result.ExitCode 'the second run succeeds'
            Assert-Equal 0 @($second.Plan.Components | Where-Object Action -eq 'apply').Count "nothing is left to apply: $(@($second.Plan.Components | Where-Object Action -eq 'apply' | ForEach-Object Name) -join ', ')"
            Assert-Equal 0 $script:Fake.Calls.Count "no privileged command runs: $($script:Fake.Calls -join ' / ')"
            Assert-Equal $state $script:Fake.Files[$script:StatePath] 'the first record of the prior values stands'
            Assert-Equal $snapshot (Get-FakeSnapshot) 'the host is unchanged'
            Assert-True ($second.Applied -contains 'host.deep_diagnostics_nothing_to_change') 'the operator is told'
        }

        It 'keeps the first prior values when a drifted value is applied again' {
            [void](New-FakeHost -Sysctl @{ 'kernel.panic' = '10' })
            [void](Invoke-FakeEnable)
            $enabledAt = [regex]::Match($script:Fake.Files[$script:StatePath], '"enabledAtUtc":\s*"[^"]*"').Value
            $script:Fake.Sysctl['kernel.panic'] = '20'
            $again = Invoke-FakeEnable
            Assert-Equal $enabledAt ([regex]::Match($script:Fake.Files[$script:StatePath], '"enabledAtUtc":\s*"[^"]*"').Value) 'the rewritten state keeps the first enable time, in ISO-8601, in any culture'
            Assert-True ($again.Shown -contains (Format-ChangeLine -Key 'kernel.panic' -Previous '20' -New '30')) 'the drift is reported as it is now'
            $panic = @((Get-FakeState).components.sysctl.sysctl | Where-Object { $_.key -eq 'kernel.panic' })[0]
            Assert-Equal '10' $panic.previous 'Disable still restores the value from before the first run'
        }

        It 'records a component that failed before and is in place now as applied' {
            [void](New-FakeHost -AptFails)
            $first = Invoke-FakeEnable
            Assert-Equal 2 $first.Result.ExitCode 'the first run fails on rasdaemon'
            Assert-Equal 'failed' (Get-FakeState).components.rasdaemon.status 'and records it'
            # The operator installs it by hand, as the failure advised; the
            # package enables and starts its unit.
            $script:Fake.AptFails = $false
            [void]$script:Fake.Packages.Add('rasdaemon')
            $script:Fake.Units['rasdaemon.service'] = @{ Enabled = 'enabled'; Active = 'active' }
            $script:Fake.Calls.Clear()
            $second = Invoke-FakeEnable
            Assert-Equal 'current' (Get-Component -Plan $second.Plan -Name 'rasdaemon').Action 'nothing is left to do on the host'
            Assert-Equal 0 $second.Result.ExitCode 'the second run succeeds'
            $state = Get-FakeState
            Assert-Equal 'applied' $state.components.rasdaemon.status 'the state no longer reports the old failure'
            Assert-Equal '' $state.components.rasdaemon.reason 'nor its reason'
            $mutating = @($script:Fake.Calls | Where-Object { $_ -ne 'true' })
            Assert-Equal 1 $mutating.Count "only the state file is written: $($mutating -join ' / ')"
            Assert-Match ([regex]::Escape($script:StatePath) + '$') $mutating[0] 'the one write is the state file'
            Assert-False ([bool]$state.components.rasdaemon.packages[0].installedByYuruna) 'the operator installed the package'
            [void](Invoke-FakeDisable -RemoveEvidence)
            Assert-True $script:Fake.Packages.Contains('rasdaemon') 'so Disable keeps it'
            Assert-Equal 'enabled/active' "$((Get-FakeUnitState -Name 'rasdaemon.service').Enabled)/$((Get-FakeUnitState -Name 'rasdaemon.service').Active)" 'running as the operator left it'
            Assert-False $script:Fake.Files.ContainsKey($script:StatePath) 'and the mode is off'
        }
    }

    Context 'A component that cannot apply' {
        It 'skips pstore on a legacy BIOS host with the reason and applies the rest' {
            [void](New-FakeHost -LegacyBios)
            $run = Invoke-FakeEnable
            $state = Get-FakeState
            Assert-Equal 'skipped' $state.components.pstore.status 'pstore needs UEFI'
            Assert-Equal 'host.deep_diagnostics_pstore_legacy_bios' $state.components.pstore.reason 'the reason is recorded'
            Assert-False $script:Fake.Modules.Contains('efi_pstore') 'efi_pstore is not loaded'
            foreach ($name in @('sysctl', 'watchdog', 'journald', 'rasdaemon', 'vitals', 'bootEvidence')) { Assert-Equal 'applied' $state.components[$name].status "$name still applies" }
            Assert-Equal 0 $run.Result.ExitCode 'a skip is not a failure'
        }

        It 'skips the watchdog when no hardware watchdog driver is known, and never uses softdog' {
            [void](New-FakeHost -Vendor 'CentaurHauls')
            [void](Invoke-FakeEnable)
            $state = Get-FakeState
            Assert-Equal 'skipped' $state.components.watchdog.status 'no hardware watchdog'
            Assert-Equal 'host.deep_diagnostics_watchdog_no_driver|vendor=CentaurHauls' $state.components.watchdog.reason 'the reason names the vendor'
            Assert-False $script:Fake.Modules.Contains('softdog') 'softdog cannot fire on a hard freeze'
            Assert-False ($script:Fake.Files.ContainsKey('/etc/systemd/system.conf.d/99-yuruna-deep-diagnostics.conf')) 'systemd is not given a watchdog'
            Assert-Equal 'applied' $state.components.journald.status 'the rest applies'
        }

        It 'marks rasdaemon failed when apt fails, keeps the others, and exits 2' {
            [void](New-FakeHost -AptFails)
            $run = Invoke-FakeEnable
            $state = Get-FakeState
            Assert-Equal 'failed' $state.components.rasdaemon.status 'the install failed'
            Assert-Match 'Unable to locate package rasdaemon' $state.components.rasdaemon.reason 'the apt output is the reason'
            Assert-Equal $false $state.components.rasdaemon.packages[0].installedByYuruna 'nothing was installed'
            foreach ($name in @('sysctl', 'pstore', 'watchdog', 'journald', 'vitals', 'bootEvidence')) { Assert-Equal 'applied' $state.components[$name].status "$name still applies" }
            Assert-Equal 2 $run.Result.ExitCode 'a failed component is exit 2'
            Assert-True (@($run.Warned | Where-Object { $_ -like 'host.deep_diagnostics_component_failed|component=rasdaemon|*' }).Count -eq 1) "the failure is a warning: $($run.Warned -join ' / ')"
        }

        It 'skips a watchdog another process holds open' {
            [void](New-FakeHost -Module @('iTCO_wdt') -WatchdogHeld)
            [void](Invoke-FakeEnable)
            $state = Get-FakeState
            Assert-Equal 'skipped' $state.components.watchdog.status 'systemd cannot open a device another process holds'
            Assert-Equal 'host.deep_diagnostics_watchdog_held|device=/dev/watchdog0' $state.components.watchdog.reason 'the reason names the device'
            Assert-Equal '0' $script:Fake.RuntimeWatchdog 'systemd is not re-executed with a watchdog'
        }

        It 'applies every runtime value the kernel accepts when it refuses one, and names the refused key' {
            [void](New-FakeHost)
            # Without a usable hard-lockup detector the kernel exposes
            # kernel.nmi_watchdog but refuses to turn it on.
            Mock -ModuleName $script:ModuleName Invoke-DeepDiagnosticsSudo {
                if (($Argument -join ' ') -eq 'sysctl -w kernel.nmi_watchdog=1') {
                    $script:Fake.Calls.Add(($Argument -join ' '))
                    return @{ ExitCode = 255; Output = 'sysctl: setting key "kernel.nmi_watchdog": Operation not supported' }
                }
                Invoke-FakeSudo -Argument $Argument
            }
            $run = Invoke-FakeEnable
            $state = Get-FakeState
            Assert-Equal 'failed' $state.components.sysctl.status 'the component is not fully in place'
            Assert-Match 'command=sysctl -w kernel\.nmi_watchdog=1\|' $state.components.sysctl.reason 'the reason names the refused key'
            Assert-Equal '0' $script:Fake.Sysctl['kernel.nmi_watchdog'] 'the refused value stays as it was'
            foreach ($key in @('kernel.softlockup_panic', 'kernel.hardlockup_panic', 'kernel.softlockup_all_cpu_backtrace', 'kernel.hardlockup_all_cpu_backtrace', 'kernel.panic_on_oops')) {
                Assert-Equal '1' $script:Fake.Sysctl[$key] "$key applies at runtime anyway"
            }
            Assert-Equal '30' $script:Fake.Sysctl['kernel.panic'] 'kernel.panic applies at runtime anyway'
            Assert-Equal "6`t4`t1`t7" $script:Fake.Sysctl['kernel.printk'] 'kernel.printk applies at runtime anyway'
            Assert-Equal 2 $run.Result.ExitCode 'a failed component is exit 2'
            foreach ($name in @('pstore', 'watchdog', 'journald', 'rasdaemon', 'vitals', 'bootEvidence')) { Assert-Equal 'applied' $state.components[$name].status "$name still applies" }
        }
    }

    Context 'Refusal' {
        It 'refuses off Linux before reading anything else' {
            [void](New-FakeHost)
            Mock -ModuleName $script:ModuleName Test-DeepDiagnosticsLinux { $false }
            Assert-Equal 'host.deep_diagnostics_requires_linux' (Get-DeepDiagnosticsRefusal) 'off Linux'
            Assert-Equal 0 $script:Fake.Calls.Count 'nothing privileged ran'
        }

        It 'refuses without systemd and for a malformed target' {
            [void](New-FakeHost -NoSystemd)
            Assert-Equal 'host.deep_diagnostics_requires_systemd' (Get-DeepDiagnosticsRefusal) 'no systemd'
            [void](New-FakeHost)
            Assert-Equal '' (Get-DeepDiagnosticsRefusal -NetconsoleTarget '192.168.7.50:6666') 'a valid target'
            foreach ($bad in @('192.168.7.300', 'receiver.lan', '192.168.7.50:0', '192.168.7.50:70000')) {
                Assert-Equal "host.deep_diagnostics_target_invalid|target=$bad" (Get-DeepDiagnosticsRefusal -NetconsoleTarget $bad) "refuses $bad"
            }
        }

        It 'refuses to plan over a state file it cannot read, changing nothing' {
            [void](New-FakeHost -File @{ $script:StatePath = '{ "schema": "something-else/v9" }' })
            Assert-Throw -Script { Get-DeepDiagnosticsPlan } -Match '^host\.deep_diagnostics_state_unreadable\|' -Because 'an unknown state file stops the plan'
            Assert-Equal 0 $script:Fake.Calls.Count 'nothing privileged ran'
        }

        It 'runs the real scripts as a no-change preview, or refuses on a host without Linux and systemd' {
            $statePresent = Test-Path -LiteralPath $script:StatePath
            $stateText = if ($statePresent) { Get-Content -Raw -LiteralPath $script:StatePath } else { '' }
            foreach ($name in @('Enable-DeepDiagnostics.ps1', 'Disable-DeepDiagnostics.ps1')) {
                $r = Invoke-BoundedNativeCommand -FilePath ([Environment]::ProcessPath) -TimeoutSeconds 180 -Environment @{ NO_COLOR = '1' } -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $script:RepoRoot "host/ubuntu.kvm/$name"), '-WhatIf')
                Assert-True ($r.Started -and -not $r.TimedOut) "$name finished inside its cap"
                $expected = if ($IsLinux -and (Test-Path -LiteralPath '/run/systemd/system')) { 0 } else { 1 }
                Assert-Equal $expected $r.ExitCode "$name -WhatIf exit code; output: $($r.StdOut) $($r.StdErr)"
            }
            Assert-Equal $statePresent (Test-Path -LiteralPath $script:StatePath) 'the preview neither created nor removed a state file'
            if ($statePresent) { Assert-Equal $stateText (Get-Content -Raw -LiteralPath $script:StatePath) 'the state file is unchanged' }
        }
    }

    Context 'Disable-DeepDiagnostics' {
        It 'puts the whole host back as it was, operator values and files included' {
            [void](New-FakeHost -RasdaemonInstalled -Sysctl @{ 'kernel.panic' = '10' } -File @{
                    '/etc/sysctl.d/60-operator.conf'                    = "kernel.panic = 10`n"
                    '/etc/systemd/journald.conf.d/50-operator.conf'     = "[Journal]`nStorage=volatile`nSystemMaxUse=1G`n"
                    '/etc/sysctl.d/99-zz-yuruna-deep-diagnostics.conf' = "kernel.panic = 5`n"
                })
            $before = Get-FakeSnapshot
            $enable = Invoke-FakeEnable -Target '192.168.7.50'
            Assert-True ($enable.Shown -contains (Format-ChangeLine -Key 'Storage' -Previous 'volatile' -New 'persistent')) "the operator's journald value is reported: $($enable.Shown -join ' / ')"
            Assert-Equal 'current' (Get-Component -Plan $enable.Plan -Name 'rasdaemon').Action 'an installed, running rasdaemon is left as it is'
            Assert-Equal "kernel.panic = 5`n" (@((Get-FakeState).components.sysctl.files | Where-Object { $_.path -eq $script:SysctlDropIn })[0].previousContent) 'a file Enable replaces is kept in the state'
            $disable = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $disable.Result.ExitCode "Disable succeeds; warnings: $($disable.Warned -join ' / ')"
            Assert-True ($disable.Shown -contains (Format-ChangeLine -Key 'kernel.panic' -Previous '30' -New '10')) "the restore is reported as key: current -> restored: $($disable.Shown -join ' / ')"
            Assert-Equal $before (Get-FakeSnapshot) 'every file, value, unit, module and package is as it was'
            Assert-True $script:Fake.Packages.Contains('rasdaemon') 'rasdaemon the operator installed stays'
        }

        It 'removes rasdaemon only because Enable installed it' {
            [void](New-FakeHost)
            $before = Get-FakeSnapshot
            [void](Invoke-FakeEnable)
            Assert-True ((Get-FakeState).components.rasdaemon.packages[0].installedByYuruna) 'the install is recorded'
            $disable = Invoke-FakeDisable -RemoveEvidence
            Assert-False $script:Fake.Packages.Contains('rasdaemon') 'the package Enable installed is removed'
            # A plain remove leaves dpkg's 'rc' state: the configuration files
            # and the unit's dangling links.
            Assert-True ($script:Fake.Calls -contains 'env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q rasdaemon') "it is purged: $($script:Fake.Calls -join ' / ')"
            Assert-Equal 0 @($script:Fake.Calls | Where-Object { $_ -match 'autoremove' }).Count 'autoremove would take unrelated packages, old kernels among them'
            Assert-True ($disable.Shown -contains 'host.deep_diagnostics_plan_note|note=host.deep_diagnostics_dependencies_kept|package=rasdaemon') "Disable says the packages the install pulled in stay: $($disable.Shown -join ' / ')"
            Assert-Equal $before (Get-FakeSnapshot) 'the host is as it was, with no configuration files left behind'
        }

        It 'puts back the configuration files a package had kept before Enable installed it' {
            # Removed earlier without a purge; the install takes the files up again.
            [void](New-FakeHost -RasdaemonConfigFiles)
            $before = Get-FakeSnapshot
            [void](Invoke-FakeEnable)
            Assert-True $script:Fake.Packages.Contains('rasdaemon') 'Enable installed it'
            [void](Invoke-FakeDisable -RemoveEvidence)
            Assert-True ($script:Fake.Calls -contains 'env DEBIAN_FRONTEND=noninteractive apt-get remove -y -q rasdaemon') "a purge would delete files that predate the mode: $($script:Fake.Calls -join ' / ')"
            Assert-Equal $before (Get-FakeSnapshot) 'the package is removed with its configuration files kept, as before'
        }

        It 'keeps the evidence bundles unless -RemoveEvidence is given' {
            [void](New-FakeHost)
            [void](Invoke-FakeEnable)
            $bundle = '/var/log/yuruna/deep-diagnostics/boot-20261103T120000Z-1a2b3c4d.txt'
            Assert-True $script:Fake.Files.ContainsKey($bundle) 'Enable collected a bundle at once'
            $disable = Invoke-FakeDisable
            Assert-True $script:Fake.Files.ContainsKey($bundle) 'the evidence stays'
            Assert-True ($disable.Shown -contains 'host.deep_diagnostics_plan_note|note=host.deep_diagnostics_evidence_kept|path=/var/log/yuruna/deep-diagnostics') 'and Disable says where'
            Assert-False $script:Fake.Files.ContainsKey($script:StatePath) 'the state file is gone'
            Assert-False $script:Fake.Dirs.Contains('/var/lib/yuruna') 'the directories Enable created are gone'
            $later = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $later.Result.ExitCode 'evidence can be removed after the mode is off'
            Assert-False $script:Fake.Files.ContainsKey($bundle) 'the evidence is removed on request'
            Assert-False $script:Fake.Dirs.Contains('/var/log/yuruna') 'and its parent, now empty'
        }

        It 'removes the empty /var/log/yuruna with the evidence after a Disable that kept it and a later Enable' {
            [void](New-FakeHost)
            $before = Get-FakeSnapshot
            [void](Invoke-FakeEnable)
            [void](Invoke-FakeDisable)
            # The second Enable finds the evidence directory in place, so its
            # state does not record creating it.
            [void](Invoke-FakeEnable)
            Assert-False (@((Get-FakeState).createdDirectories) -contains '/var/log/yuruna') 'the second record does not name the parent'
            $disable = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $disable.Result.ExitCode "Disable succeeds; warnings: $($disable.Warned -join ' / ')"
            $line = Format-ChangeLine -Key '/var/log/yuruna/deep-diagnostics' -Previous 'host.deep_diagnostics_value_evidence' -New 'host.deep_diagnostics_value_removed'
            Assert-True ($disable.Shown -contains $line) "the plan line names what is removed: $($disable.Shown -join ' / ')"
            Assert-False $script:Fake.Dirs.Contains('/var/log/yuruna') 'no empty /var/log/yuruna is left behind'
            Assert-Equal $before (Get-FakeSnapshot) 'the host is as it was'
            # A parent that holds anything else stays.
            [void](New-FakeHost -File @{ '/var/log/yuruna/pwsh-yaml-install.log' = "installed`n" })
            [void](Invoke-FakeEnable)
            [void](Invoke-FakeDisable -RemoveEvidence)
            Assert-True $script:Fake.Files.ContainsKey('/var/log/yuruna/pwsh-yaml-install.log') 'another file in it is kept'
            Assert-True $script:Fake.Dirs.Contains('/var/log/yuruna') 'and so is the directory'
        }

        It 'keeps the state file when a step fails, so a second run finishes' {
            [void](New-FakeHost)
            $before = Get-FakeSnapshot
            [void](Invoke-FakeEnable)
            Mock -ModuleName $script:ModuleName Invoke-DeepDiagnosticsSudo {
                if ($Argument[0] -eq 'sysctl') { $script:Fake.Calls.Add(($Argument -join ' ')); return @{ ExitCode = 1; Output = 'sysctl: permission denied' } }
                Invoke-FakeSudo -Argument $Argument
            }
            $first = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 2 $first.Result.ExitCode 'a partial restore is exit 2'
            Assert-True $script:Fake.Files.ContainsKey($script:StatePath) 'the record stays for the next run'
            Mock -ModuleName $script:ModuleName Invoke-DeepDiagnosticsSudo { Invoke-FakeSudo -Argument $Argument }
            $second = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $second.Result.ExitCode 'the second run finishes'
            Assert-Equal $before (Get-FakeSnapshot) 'the host is as it was'
        }

        It 'removes a netconsole target the kernel left disabled, and the module it held' {
            [void](New-FakeHost)
            $before = Get-FakeSnapshot
            [void](Invoke-FakeEnable -Target '192.168.7.50')
            # The kernel disables a target whose device went away, and keeps
            # its directory.
            $script:Fake.Netconsole.Enabled = '0'
            $disable = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $disable.Result.ExitCode "Disable succeeds; warnings: $($disable.Warned -join ' / ')"
            Assert-True ($script:Fake.Calls -contains 'rmdir -- /sys/kernel/config/netconsole/yuruna') "the target is removed: $($script:Fake.Calls -join ' / ')"
            Assert-Equal $before (Get-FakeSnapshot) 'no target and no netconsole module are left'
        }

        It 'retries a netconsole target whose removal failed, although the same run removed the helper script' {
            [void](New-FakeHost)
            $before = Get-FakeSnapshot
            [void](Invoke-FakeEnable -Target '192.168.7.50')
            Mock -ModuleName $script:ModuleName Invoke-DeepDiagnosticsSudo {
                if ($Argument[0] -eq 'rmdir' -and $Argument[-1] -eq '/sys/kernel/config/netconsole/yuruna') {
                    $script:Fake.Calls.Add(($Argument -join ' '))
                    return @{ ExitCode = 1; Output = "rmdir: failed to remove '$($Argument[-1])': Device or resource busy" }
                }
                Invoke-FakeSudo -Argument $Argument
            }
            $first = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 2 $first.Result.ExitCode 'a target left in place is a partial restore'
            Assert-True $script:Fake.Files.ContainsKey($script:StatePath) 'the record stays for the next run'
            Assert-False $script:Fake.Files.ContainsKey('/usr/local/lib/yuruna/deep-diagnostics/yuruna-netconsole.sh') 'the helper script is already gone'
            Mock -ModuleName $script:ModuleName Invoke-DeepDiagnosticsSudo { Invoke-FakeSudo -Argument $Argument }
            $second = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $second.Result.ExitCode 'the second run finishes'
            Assert-Equal $before (Get-FakeSnapshot) 'the target is gone and the host is as it was'
        }

        It 'treats a package on hold as installed and puts its unit back' {
            [void](New-FakeHost -RasdaemonHeld)
            $script:Fake.Units['rasdaemon.service'] = @{ Enabled = 'disabled'; Active = 'inactive' }
            $before = Get-FakeSnapshot
            $enable = Invoke-FakeEnable
            Assert-True ($enable.Shown -contains (Format-ChangeLine -Key 'rasdaemon.service' -Previous 'disabled, inactive' -New 'enabled, active')) "the unit is what changes: $($enable.Shown -join ' / ')"
            Assert-Equal 0 @($script:Fake.Calls | Where-Object { $_ -like 'env *apt-get*' }).Count 'nothing is installed over it'
            Assert-Equal 'enabled/active' "$((Get-FakeUnitState -Name 'rasdaemon.service').Enabled)/$((Get-FakeUnitState -Name 'rasdaemon.service').Active)" 'the mode runs rasdaemon'
            $disable = Invoke-FakeDisable -RemoveEvidence
            Assert-Equal 0 $disable.Result.ExitCode "Disable succeeds; warnings: $($disable.Warned -join ' / ')"
            Assert-Equal $before (Get-FakeSnapshot) 'the held package stays, with its unit disabled and stopped again'
        }

        It 'reports that the mode is not enabled when there is no state file' {
            [void](New-FakeHost)
            $run = Invoke-FakeDisable
            Assert-Equal 0 $run.Result.ExitCode 'nothing to restore is success'
            Assert-True ($run.Shown -contains "host.deep_diagnostics_not_enabled|path=$script:StatePath") 'the operator is told'
            Assert-Equal 0 $script:Fake.Calls.Count 'nothing privileged ran'
        }
    }

    Context 'Helper scripts' {
        It 'passes ShellCheck' -Skip:(-not $script:HasShellCheck) {
            $r = Invoke-BoundedNativeCommand -FilePath ([Environment]::ProcessPath) -TimeoutSeconds 120 -Environment @{ NO_COLOR = '1' } -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $script:RepoRoot 'tools/Invoke-ShellCheck.ps1'), '-Path', 'host/ubuntu.kvm/deep-diagnostics', '-Severity', 'style')
            Assert-Equal 0 $r.ExitCode "ShellCheck findings: $($r.StdOut) $($r.StdErr)"
        }

        It 'writes one vitals line well under the 240-byte budget' -Skip:(-not $IsLinux) {
            $r = Invoke-BoundedNativeCommand -FilePath $script:Bash.Source -TimeoutSeconds 30 -ArgumentList @((Join-Path $script:Helpers 'yuruna-vitals.sh'), '--once')
            $line = "$($r.StdOut)".TrimEnd()
            Assert-Equal 0 $r.ExitCode "vitals --once exit; stderr: $($r.StdErr)"
            Assert-Match '^yuruna-vitals: load=\S+ mem=\d+M swap=\d+M dirty=\d+M wb=\d+M( psi=cpu:\S+,mem:\S+,io:\S+)? cpu=\S+ nvme=\S+ fans=\S+ qemu=\d+$' $line 'the line format'
            Assert-True ([Text.Encoding]::UTF8.GetByteCount($line) -lt 240) "the line is $($line.Length) bytes"
        }

        It 'has the README find the vitals by their journald identifier, not by searching messages' {
            # journald stores a /dev/kmsg record a program wrote with its
            # leading "word:" as SYSLOG_IDENTIFIER and only the rest as
            # MESSAGE, which is all journalctl -g searches.
            $vitals = [IO.File]::ReadAllText((Join-Path $script:Helpers 'yuruna-vitals.sh'))
            $tag = [regex]::Match($vitals, "printf '(?<tag>[a-z-]+): load=").Groups['tag'].Value
            Assert-Equal 'yuruna-vitals' $tag 'the word each vitals line starts with'
            $readme = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/ubuntu.kvm/README.md'))
            $commands = @([regex]::Matches($readme, '`(?<command>journalctl [^`]*' + [regex]::Escape($tag) + '[^`]*)`') | ForEach-Object { $_.Groups['command'].Value })
            Assert-True ($commands.Count -gt 0) 'the README shows how to see the vitals in the journal'
            foreach ($command in $commands) {
                Assert-False ($command -match ('(^|\s)(-g|--grep)[\s=]+' + [regex]::Escape($tag))) "'$command' searches messages, which do not hold the tag"
            }
        }

        It 'reads package, core, NVMe and fan sensors from hwmon' -Skip:(-not $script:CanRunShell) {
            $root = New-YurunaTestTempDir -Prefix 'yuruna-hwmon'
            try {
                $tree = @{
                    'hwmon0/name' = 'coretemp'; 'hwmon0/temp1_label' = 'Package id 0'; 'hwmon0/temp1_input' = '55000'
                    'hwmon0/temp2_label' = 'Core 0'; 'hwmon0/temp2_input' = '61000'; 'hwmon0/temp3_label' = 'Core 1'; 'hwmon0/temp3_input' = '58000'
                    'hwmon1/name' = 'nvme'; 'hwmon1/temp1_label' = 'Composite'; 'hwmon1/temp1_input' = '41000'; 'hwmon1/temp2_label' = 'Sensor 1'; 'hwmon1/temp2_input' = '50000'
                    'hwmon2/name' = 'nct6798'; 'hwmon2/fan1_input' = '1200'; 'hwmon2/fan2_input' = '0'; 'hwmon2/temp1_input' = '90000'
                }
                foreach ($rel in $tree.Keys) {
                    $path = Join-Path $root $rel
                    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path))
                    [IO.File]::WriteAllText($path, "$($tree[$rel])`n")
                }
                $r = Invoke-HelperFunction -Script 'yuruna-vitals.sh' -Function @('vitals_hwmon') -Body "shopt -s nullglob`nvitals_max_fans=8`nvitals_hwmon '$($root -replace '\\', '/')'"
                Assert-Equal ' cpu=55/61C nvme=41C fans=1200,0' $r.Output 'package, hottest core, NVMe composite and every fan; other sensors are ignored'
            } finally { Remove-YurunaTestTempDir $root }
        }

        It 'routes to the gateway off the subnet and to the target on it' -Skip:(-not $script:CanRunShell) {
            $bin = New-YurunaTestTempDir -Prefix 'yuruna-fake-ip'
            try {
                [IO.File]::WriteAllText((Join-Path $bin 'ip'), "#!/bin/bash`ncase `"`$*`" in`n  *8.8.8.8*) echo '8.8.8.8 via 192.168.7.1 dev yuruna-br0 src 192.168.7.110 uid 0 \    cache' ;;`n  *) echo '192.168.7.50 dev yuruna-br0 src 192.168.7.110 uid 0 \    cache' ;;`nesac`n")
                if (-not $IsWindows) { & chmod +x (Join-Path $bin 'ip') }
                $path = "$($bin -replace '\\', '/'):$env:PATH"
                $r = Invoke-HelperFunction -Script 'yuruna-netconsole.sh' -Function @('netconsole_route') -Body "netconsole_route 8.8.8.8`nnetconsole_route 192.168.7.50" -Environment @{ PATH = $path }
                Assert-Equal "yuruna-br0 192.168.7.110 192.168.7.1`nyuruna-br0 192.168.7.110 192.168.7.50" $r.Output 'device, source and next hop'
            } finally { Remove-YurunaTestTempDir $bin }
        }

        It 'reads the target with a default port and rejects a malformed one' -Skip:(-not $script:CanRunShell) {
            $dir = New-YurunaTestTempDir -Prefix 'yuruna-netconsole-conf'
            try {
                $conf = ($dir -replace '\\', '/') + '/netconsole.conf'
                $body = @"
printf '# comment\nTARGET=192.168.7.50\n' > '$conf'; netconsole_read_target '$conf'
printf 'TARGET=192.168.7.50:7000\n' > '$conf'; netconsole_read_target '$conf'
printf 'TARGET=192.168.7.50:99999\n' > '$conf'; netconsole_read_target '$conf' || echo rejected
printf 'TARGET=receiver.lan\n' > '$conf'; netconsole_read_target '$conf' || echo rejected
"@
                $r = Invoke-HelperFunction -Script 'yuruna-netconsole.sh' -Function @('netconsole_read_target') -Body $body
                Assert-Equal "192.168.7.50 6666`n192.168.7.50 7000`nrejected`nrejected" $r.Output 'the default port, an explicit port, and two rejections'
            } finally { Remove-YurunaTestTempDir $dir }
        }

        It 'configures a netconsole target and then recognizes it as current' -Skip:(-not $script:CanRunShell) {
            $dir = New-YurunaTestTempDir -Prefix 'yuruna-configfs'
            try {
                foreach ($name in @('dev_name', 'local_ip', 'remote_ip', 'remote_port', 'remote_mac', 'extended')) { [IO.File]::WriteAllText((Join-Path $dir $name), "`n") }
                [IO.File]::WriteAllText((Join-Path $dir 'enabled'), "1`n")
                $target = $dir -replace '\\', '/'
                $body = @"
netconsole_matches '$target' br0 192.168.7.110 192.168.7.50 6666 aa:bb:cc:dd:ee:ff && echo stale-match
netconsole_configure '$target' br0 192.168.7.110 192.168.7.50 6666 aa:bb:cc:dd:ee:ff && echo configured
netconsole_matches '$target' br0 192.168.7.110 192.168.7.50 6666 aa:bb:cc:dd:ee:ff && echo current
netconsole_matches '$target' br0 192.168.7.111 192.168.7.50 6666 aa:bb:cc:dd:ee:ff || echo new-address
cat '$target/extended'
"@
                $r = Invoke-HelperFunction -Script 'yuruna-netconsole.sh' -Function @('netconsole_matches', 'netconsole_configure') -Body $body
                Assert-Equal "configured`ncurrent`nnew-address`n1" $r.Output 'an unconfigured target does not match; a configured one does until the address changes; extended is on'
            } finally { Remove-YurunaTestTempDir $dir }
        }

        It 'names one bundle per boot and finds the existing one' -Skip:(-not $script:CanRunShell) {
            $dir = New-YurunaTestTempDir -Prefix 'yuruna-evidence'
            try {
                $target = $dir -replace '\\', '/'
                $body = @"
evidence_target '$target' 1a2b3c4d-1111-2222-3333-444455556666 20261103T120000Z
touch '$target/boot-20261103T120000Z-1a2b3c4d.txt'
evidence_target '$target' 1a2b3c4d-1111-2222-3333-444455556666 20261103T130000Z
echo done
"@
                $r = Invoke-HelperFunction -Script 'yuruna-boot-evidence.sh' -Function @('evidence_target') -Body $body
                Assert-Equal "$target/boot-20261103T120000Z-1a2b3c4d.txt`ndone" $r.Output 'the first run names the bundle, the second finds it'
            } finally { Remove-YurunaTestTempDir $dir }
        }

        It 'reads the previous boot from the journal, its id in the dashed form bootId has' -Skip:(-not $script:CanRunShell) {
            # The journal's export format writes _BOOT_ID as 32 hex digits.
            $bin = New-FakeJournalctl -Script @'
#!/bin/bash
case " $* " in
  *' -b -1 -n 1 -o export '*) printf '__CURSOR=s=1\n__REALTIME_TIMESTAMP=1793678683921326\n_BOOT_ID=bb5ec8127a9546828ca784e66d155b58\nMESSAGE=last\n' ;;
esac
'@
            try {
                $r = Invoke-HelperFunction -Script 'yuruna-boot-evidence.sh' -Function @('evidence_previous_boot') -Environment @{ PATH = "$($bin -replace '\\', '/'):$env:PATH" } `
                    -Body "evidence_previous_id=''`nevidence_previous_last=''`nevidence_previous_boot`nprintf '%s %s\n' `"`$evidence_previous_id`" `"`$evidence_previous_last`""
                Assert-Equal 'bb5ec812-7a95-4682-8ca7-84e66d155b58 1793678683' $r.Output 'the id as /proc/sys/kernel/random/boot_id writes it, and the last entry in seconds'
            } finally { Remove-YurunaTestTempDir $bin }
        }

        It 'adds the previous boot''s systemd watchdog lines, bounded, with those PID 1 logged through the kernel log' -Skip:(-not $script:CanRunShell) {
            # PID 1 logs whether it armed the watchdog among its other lines. What it
            # logs while it re-executes, as Enable makes it do, reaches the journal
            # through /dev/kmsg and carries SYSLOG_PID=1 instead of _PID=1.
            $bin = New-FakeJournalctl -Script @'
#!/bin/bash
args=" $* "
case "$args" in
  *' -b -1 _PID=1 '*)
    for i in $(seq 1 30); do
      echo "2026-11-03T04:09:22.0000$i+00:00 host systemd[1]: Watchdog running with a hardware timeout of 1min. $i"
      echo "2026-11-03T04:09:22.0000$i+00:00 host systemd[1]: Started unrelated-$i.service."
    done
    case "$args" in
      *' + SYSLOG_PID=1 '*) echo "2026-11-03T05:04:13.472045+00:00 host systemd[1]: Using hardware watchdog /dev/watchdog0: 'i6300ESB timer', version 0." ;;
    esac ;;
esac
'@
            try {
                $r = Invoke-HelperFunction -Script 'yuruna-boot-evidence.sh' -Function @('evidence_previous_watchdog') -Body 'evidence_previous_watchdog' -Environment @{ PATH = "$($bin -replace '\\', '/'):$env:PATH" }
                $lines = @("$($r.Output)" -split "`n")
                Assert-Equal 20 $lines.Count "the last 20 watchdog lines: $($r.Output)"
                Assert-Match 'systemd\[1\]: Using hardware watchdog /dev/watchdog0' $lines[-1] 'the arming PID 1 logged through the kernel log'
                Assert-Match 'systemd\[1\]: Watchdog running with a hardware timeout of 1min\. 30$' $lines[-2] 'after its own lines, down to the last one'
                Assert-Equal 0 @($lines | Where-Object { $_ -notmatch 'Watchdog running|Using hardware watchdog' }).Count 'and no other PID 1 line'
            } finally { Remove-YurunaTestTempDir $bin }
        }

        It 'lists the journal''s last 20 boots, which date the restarts without last' -Skip:(-not $script:CanRunShell) {
            $bin = New-FakeJournalctl -Script @'
#!/bin/bash
case " $* " in
  *' --list-boots '*) for i in $(seq 1 30); do echo "boot $i"; done ;;
esac
'@
            try {
                $r = Invoke-HelperFunction -Script 'yuruna-boot-evidence.sh' -Function @('evidence_boot_list') -Body 'evidence_boot_list' -Environment @{ PATH = "$($bin -replace '\\', '/'):$env:PATH" }
                Assert-Equal (@(11..30 | ForEach-Object { "boot $_" }) -join "`n") $r.Output 'the newest 20 boots'
            } finally { Remove-YurunaTestTempDir $bin }
        }

        It 'bounds each section of the bundle' -Skip:(-not $script:CanRunShell) {
            $r = Invoke-HelperFunction -Script 'yuruna-boot-evidence.sh' -Function @('evidence_section') -Body "evidence_section_bytes=100`nevidence_section 'big' head -c 5000 /dev/zero | tr '\0' x | wc -c"
            Assert-Equal '118' "$($r.Output)".Trim() 'a 5000-byte source is cut at 100 bytes, plus the title and newlines'
        }

        It 'writes a bounded bundle with every section' -Skip:(-not $IsLinux) {
            $dir = New-YurunaTestTempDir -Prefix 'yuruna-bundle'
            try {
                $out = Join-Path $dir 'bundle.txt'
                $r = Invoke-BoundedNativeCommand -FilePath $script:Bash.Source -TimeoutSeconds 120 -ArgumentList @((Join-Path $script:Helpers 'yuruna-boot-evidence.sh'), '--output', $out)
                Assert-Equal 0 $r.ExitCode "the bundle is written; stderr: $($r.StdErr)"
                $text = [IO.File]::ReadAllText($out)
                Assert-Match '(?m)^schema=yuruna\.deep-diagnostics-boot/v1$' $text 'the bundle names its schema'
                Assert-Match '(?m)^previousBootLastEntryUtc=' $text 'the time the previous boot stopped writing'
                # The hardware-error section matches startup banners as well,
                # and this boot's systemd watchdog is read before PID 1 arms
                # it, so both titles say so.
                $titles = @('previous boot: journal tail', 'previous boot: kernel warnings and worse', 'previous boot: yuruna-vitals, last 10 minutes',
                    'previous boot: systemd (PID 1) watchdog lines',
                    'this boot: hardware error and watchdog kernel lines, startup banners included (a banner such as "AER: enabled" or "EDAC MC: Ver" is not an error)',
                    'pstore', 'journalctl --list-boots, last 20', 'last -x -F', 'ras-mc-ctl --summary', 'ras-mc-ctl --errors', 'wdctl',
                    'this boot: systemd watchdog when this bundle was written, usually before PID 1 arms it')
                $missing = @($titles | Where-Object { -not $text.Contains("===== $_ =====") })
                Assert-Equal 0 $missing.Count "sections missing: $($missing -join ' / ')"
                Assert-True ((Get-Item -LiteralPath $out).Length -le 2097152 + 64) 'the bundle stays within about 2 MB'
                Assert-Equal ([Convert]::ToInt32('640', 8)) ([int](Get-Item -LiteralPath $out).UnixFileMode) 'the bundle is 0640'
            } finally { Remove-YurunaTestTempDir $dir }
        }
    }
}
