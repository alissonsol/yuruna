<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42aa4085-e085-4c79-b144-441aaa2ef208
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu kvm deep-diagnostics freeze evidence
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
    Deep diagnostics mode for an Ubuntu KVM host: settings that leave evidence
    behind when the whole machine freezes, and the record that undoes them.
.DESCRIPTION
    A host that hard-freezes stops within seconds, loses the last few seconds
    of what it wrote, and logs nothing about the freeze itself. Evidence has
    to come from places that survive it: a kernel that panics and reboots
    instead of hanging, crash records kept in firmware storage (pstore), a
    hardware watchdog that resets a machine whose processors stopped, a
    journal synced every few seconds, kernel messages sent to another machine
    as they happen (netconsole), and a bundle written at the next boot.

    Enable-DeepDiagnostics.ps1 and Disable-DeepDiagnostics.ps1 import this
    module; the runner and the host driver never load it. The plan reads the
    host without privilege, so -WhatIf needs no password. Every change goes
    through Invoke-DeepDiagnosticsSudo, every read through the readers in the
    "Host access" region, and the state file records each prior value before
    the first change, so Disable restores the host from the record alone.
#>

Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# --- REGION: Contract
# The state file and the evidence bundles are read by the host diagnostic and
# the runner's boot recovery; their paths and the schema name are a contract.
$script:StateSchema = 'yuruna.deep-diagnostics-state/v1'
$script:StatePath = '/var/lib/yuruna/deep-diagnostics/state.json'
$script:EvidenceDirectory = '/var/log/yuruna/deep-diagnostics'
$script:LibraryDirectory = '/usr/local/lib/yuruna/deep-diagnostics'
$script:ConfigDirectory = '/etc/yuruna/deep-diagnostics'
# The netconsole target yuruna-netconsole.sh creates through configfs.
$script:NetconsoleDirectory = '/sys/kernel/config/netconsole/yuruna'
$script:UnitDirectory = '/etc/systemd/system'
$script:TemplateDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'deep-diagnostics'
$script:GeneratedHeader = '# Written by host/ubuntu.kvm/Enable-DeepDiagnostics.ps1; Disable-DeepDiagnostics.ps1 removes it.'

# Named to sort after every other drop-in, so these values are the ones the
# boot applies. kernel.hung_task_panic is deliberately absent: slow storage
# under a heavy VM install trips it on a host that is not hung.
$script:SysctlFileName = '99-zz-yuruna-deep-diagnostics.conf'
$script:SysctlDirectory = @('/etc/sysctl.d', '/run/sysctl.d', '/usr/local/lib/sysctl.d', '/usr/lib/sysctl.d', '/lib/sysctl.d')
$script:SysctlSetting = [ordered]@{
    'kernel.softlockup_panic'             = '1'
    'kernel.hardlockup_panic'             = '1'
    'kernel.nmi_watchdog'                 = '1'
    'kernel.softlockup_all_cpu_backtrace' = '1'
    'kernel.hardlockup_all_cpu_backtrace' = '1'
    'kernel.panic_on_oops'                = '1'
    # Seconds between a panic and the automatic reboot.
    'kernel.panic'                        = '30'
    # Console level 6 lets warnings and notices, the vitals among them, reach
    # netconsole as well as the journal.
    'kernel.printk'                       = '6 4 1 7'
}

$script:JournaldFileName = '99-yuruna-deep-diagnostics.conf'
$script:JournaldMain = @('/etc/systemd/journald.conf', '/run/systemd/journald.conf', '/usr/local/lib/systemd/journald.conf', '/usr/lib/systemd/journald.conf')
$script:JournaldDirectory = @('/etc/systemd/journald.conf.d', '/run/systemd/journald.conf.d', '/usr/local/lib/systemd/journald.conf.d', '/usr/lib/systemd/journald.conf.d')
$script:JournaldSetting = [ordered]@{ Storage = 'persistent'; SyncIntervalSec = '10s' }
$script:JournaldDefault = [ordered]@{ Storage = 'auto'; SyncIntervalSec = '5m' }

# The chipset watchdog drivers by CPU vendor. softdog is never a fallback: it
# runs on the processors that freeze, so it cannot fire on a hard freeze.
$script:WatchdogDriver = @{ GenuineIntel = 'iTCO_wdt'; AuthenticAMD = 'sp5100_tco' }
$script:WatchdogSeconds = '60s'
# How systemctl show prints RuntimeWatchdogSec=60s back.
$script:WatchdogShown = '1min'

# ConvertFrom-Json turns ISO-8601-looking strings into [DateTime] unless told
# not to (-DateKind String, PowerShell 7.5 and later), and a [DateTime] written
# back renders in the current culture. ConvertTo-DeepDiagnosticsUtcText covers
# the versions without the option.
$script:StateJsonOption = @{}
if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:StateJsonOption.DateKind = 'String' }

$script:ComponentTitleKey = [ordered]@{
    sysctl       = 'host.deep_diagnostics_title_sysctl'
    pstore       = 'host.deep_diagnostics_title_pstore'
    watchdog     = 'host.deep_diagnostics_title_watchdog'
    journald     = 'host.deep_diagnostics_title_journald'
    rasdaemon    = 'host.deep_diagnostics_title_rasdaemon'
    netconsole   = 'host.deep_diagnostics_title_netconsole'
    vitals       = 'host.deep_diagnostics_title_vitals'
    bootEvidence = 'host.deep_diagnostics_title_boot_evidence'
}

# --- REGION: Host access
# The only functions that touch the host. Everything else decides from what
# they return, which is what lets the suite run the whole flow against a
# simulated host.
function Test-DeepDiagnosticsLinux {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$IsLinux
}

function Test-DeepDiagnosticsPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    return (Test-Path -LiteralPath $Path)
}

function Get-DeepDiagnosticsFileText {
    <#
    .SYNOPSIS
        A file's text, or $null when it is absent or unreadable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        return [IO.File]::ReadAllText($Path)
    } catch {
        Write-Verbose "read $Path`: $($_.Exception.Message)"
        return $null
    }
}

function Get-DeepDiagnosticsDirectoryEntry {
    <#
    .SYNOPSIS
        Full paths of a directory's entries; nothing when it does not exist.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

function Invoke-DeepDiagnosticsNative {
    <#
    .SYNOPSIS
        Run one unprivileged command and return @{ ExitCode; Output }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    # Pinned locally: a non-zero exit is an answer here (a unit that is not
    # enabled, a package that is not installed), never an error to throw.
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $out = & $FilePath @ArgumentList 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ((@($out) | ForEach-Object { "$_" }) -join "`n").Trim() }
    } catch {
        return @{ ExitCode = 127; Output = "$($_.Exception.Message)" }
    }
}

function Invoke-DeepDiagnosticsSudo {
    <#
    .SYNOPSIS
        Run one privileged command through `sudo -n` and return @{ ExitCode; Output }.
    .DESCRIPTION
        -n always: the script primes sudo once, with its reasons on screen, and
        a timestamp that expires during a long apt step must become an exit
        code here rather than a password prompt nobody expected.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Argument)
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $out = & sudo -n @Argument 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ((@($out) | ForEach-Object { "$_" }) -join "`n").Trim() }
    } catch {
        return @{ ExitCode = 127; Output = "$($_.Exception.Message)" }
    }
}

# --- REGION: Small readers
function ConvertTo-DeepDiagnosticsValue {
    # /proc/sys separates kernel.printk's four numbers with tabs and a drop-in
    # with spaces; both compare and report as single spaces.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    return ((("$Text").Trim() -split '\s+') -join ' ')
}

function ConvertTo-DeepDiagnosticsUtcText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    return "$Value"
}

function Get-DeepDiagnosticsLeaf {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    return $Path.Substring($Path.LastIndexOf('/') + 1)
}

function Get-DeepDiagnosticsParent {
    # Linux paths on every platform the suite runs on, so no Split-Path.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $index = $Path.LastIndexOf('/')
    if ($index -le 0) { return '' }
    return $Path.Substring(0, $index)
}

function Get-DeepDiagnosticsUnitState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Unit)
    $first = {
        param([string]$Text, [string]$Fallback)
        $word = @("$Text" -split '\s+' | Where-Object { $_ })[0]
        if ($word -match '^[a-z-]+$') { return $word }
        return $Fallback
    }
    $enabled = (Invoke-DeepDiagnosticsNative -FilePath 'systemctl' -ArgumentList @('is-enabled', $Unit)).Output
    $active = (Invoke-DeepDiagnosticsNative -FilePath 'systemctl' -ArgumentList @('is-active', $Unit)).Output
    return [pscustomobject]@{ Enabled = (& $first $enabled 'not-found'); Active = (& $first $active 'inactive') }
}

function Get-DeepDiagnosticsPackageStatus {
    # dpkg-query is the authority on a package's state: the status
    # abbreviation, such as 'ii', 'hi' or 'rc', or '' when dpkg does not know
    # the package.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-DeepDiagnosticsNative -FilePath 'dpkg-query' -ArgumentList @('-W', '-f=${db:Status-Abbrev}', $Name)
    if ($r.ExitCode -ne 0) { return '' }
    return "$($r.Output)"
}

function Test-DeepDiagnosticsPackage {
    # The second letter of the status abbreviation is the package's state, and
    # 'i' means installed and configured whatever the first letter (the
    # selection: 'h' for a package on hold) or the third (an error flag) says.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    return ((Get-DeepDiagnosticsPackageStatus -Name $Name) -cmatch '^.i')
}

function Get-DeepDiagnosticsRuntimeWatchdog {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $r = Invoke-DeepDiagnosticsNative -FilePath 'systemctl' -ArgumentList @('show', '-p', 'RuntimeWatchdogUSec', '--value')
    $value = "$($r.Output)".Trim()
    if (-not $value) { return '0' }
    return $value
}

function Get-DeepDiagnosticsWatchdogDevice {
    # The registered watchdogs in index order, with the identity each driver reports.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $devices = foreach ($path in @(Get-DeepDiagnosticsDirectoryEntry -Path '/sys/class/watchdog')) {
        $name = Get-DeepDiagnosticsLeaf -Path $path
        if ($name -notmatch '^watchdog(\d+)$') { continue }
        [pscustomobject]@{
            Path     = $path
            Name     = $name
            Index    = [int]$Matches[1]
            Identity = (ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "$path/identity"))
        }
    }
    return @($devices | Sort-Object Index)
}

function Get-DeepDiagnosticsWatchdogProvider {
    <#
    .SYNOPSIS
        The kernel module that provides the registered hardware watchdog, as
        @{ Module; BuiltIn; Drivers }: Module names it when exactly one loaded
        driver can, BuiltIn says the kernel has the driver built in, and
        Drivers lists the loaded watchdog drivers that were found.
    .DESCRIPTION
        Not every driver gives its watchdog a parent device to follow back to
        the driver (i6300esb registers one with none), so the provider is read
        from the loaded modules instead: those whose file is under
        kernel/drivers/watchdog/, except the ones that drive no hardware (the
        watchdog core, softdog and the pretimeout governors) and a library
        another of them uses (iTCO_vendor_support under iTCO_wdt). With none
        loaded, a hardware watchdog driver listed in modules.builtin is built
        into the kernel.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    # A module is named after its file, with '-' read as '_'.
    $hardwareDriver = {
        param([string]$File)
        $name = $File.Replace('-', '_')
        if ($name -cin @('watchdog', 'softdog') -or $name.StartsWith('pretimeout_', [StringComparison]::Ordinal)) { return '' }
        return $name
    }
    # Each /proc/modules line: name, size, use count, the modules that use it
    # ('-' or 'a,b,'), state, address.
    $usedBy = @{}
    foreach ($line in ("$(Get-DeepDiagnosticsFileText -Path '/proc/modules')" -split "`n")) {
        $field = @($line.Trim() -split '\s+')
        if ($field.Count -lt 4) { continue }
        $usedBy[$field[0]] = @($field[3].Split(',', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_ -ne '-' })
    }
    $watchdog = [Collections.Generic.List[string]]::new()
    if ($usedBy.Count -gt 0) {
        # One modinfo for every loaded module. A name it cannot resolve prints
        # an error line instead of a path, which the pattern skips. The
        # absolute path comes first: /usr/sbin is not on PATH in every shell.
        $modinfo = if (Test-DeepDiagnosticsPath -Path '/usr/sbin/modinfo') { '/usr/sbin/modinfo' } else { 'modinfo' }
        $r = Invoke-DeepDiagnosticsNative -FilePath $modinfo -ArgumentList (@('-F', 'filename') + [string[]]@($usedBy.Keys | Sort-Object))
        foreach ($path in ("$($r.Output)" -split "`n")) {
            $m = [regex]::Match($path.Trim(), '/kernel/drivers/watchdog/(?<file>[^/]+?)\.ko(?:\.\w+)?$')
            if (-not $m.Success) { continue }
            $name = & $hardwareDriver $m.Groups['file'].Value
            if ($name -and $usedBy.ContainsKey($name) -and -not $watchdog.Contains($name)) { $watchdog.Add($name) }
        }
    }
    $drivers = @($watchdog | Where-Object { $users = $usedBy[$_]; @($users | Where-Object { $watchdog.Contains($_) }).Count -eq 0 })
    $builtIn = $false
    if ($drivers.Count -eq 0) {
        $release = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path '/proc/sys/kernel/osrelease')
        $list = "$(Get-DeepDiagnosticsFileText -Path "/lib/modules/$release/modules.builtin")"
        foreach ($m in [regex]::Matches($list, '(?m)^kernel/drivers/watchdog/(?<file>[^/\s]+)\.ko\s*$')) {
            if (& $hardwareDriver $m.Groups['file'].Value) { $builtIn = $true }
        }
    }
    return [pscustomobject]@{
        Module  = if ($drivers.Count -eq 1) { "$($drivers[0])" } else { '' }
        BuiltIn = $builtIn
        Drivers = $drivers
    }
}

function Get-DeepDiagnosticsTemplate {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return ([IO.File]::ReadAllText((Join-Path $script:TemplateDirectory $Name))).Replace("`r`n", "`n")
}

function Get-DeepDiagnosticsConfigFile {
    <#
    .SYNOPSIS
        The effective drop-in files across directories, in the order systemd
        applies them: one file per name, from the first directory that has
        it, sorted by name.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string[]]$Directory)
    $byName = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($dir in $Directory) {
        foreach ($path in @(Get-DeepDiagnosticsDirectoryEntry -Path $dir)) {
            $name = Get-DeepDiagnosticsLeaf -Path $path
            if ($name.EndsWith('.conf', [StringComparison]::Ordinal) -and -not $byName.ContainsKey($name)) { $byName[$name] = $path }
        }
    }
    $names = [string[]]@($byName.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return @($names | ForEach-Object { $byName[$_] })
}

function Get-DeepDiagnosticsSetting {
    <#
    .SYNOPSIS
        Key/value pairs of a sysctl.d file, or of one section of a systemd
        configuration file when -Section is given.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()][AllowEmptyString()][string]$Text, [string]$Section = '')
    $inside = -not $Section
    $settings = foreach ($raw in ("$Text" -split "`n")) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[(.+)\]$') {
            if ($Section) { $inside = ($Matches[1] -eq $Section) }
            continue
        }
        $equals = $line.IndexOf('=')
        if (-not $inside -or $equals -lt 1) { continue }
        $key = $line.Substring(0, $equals).Trim()
        # A sysctl.d key may be marked '-' (ignore failures) and may use '/'
        # between its parts; both name the same setting.
        if (-not $Section) { $key = $key.TrimStart('-').Replace('/', '.') }
        [pscustomobject]@{ Key = $key; Value = (ConvertTo-DeepDiagnosticsValue $line.Substring($equals + 1)) }
    }
    return @($settings)
}

function Get-DeepDiagnosticsLaterSetting {
    <#
    .SYNOPSIS
        Settings for the given keys in drop-ins that sort after FileName, which
        therefore win over it at boot.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string[]]$Directory,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$Key,
        [string]$Section = ''
    )
    $later = foreach ($path in @(Get-DeepDiagnosticsConfigFile -Directory $Directory)) {
        if ([string]::CompareOrdinal((Get-DeepDiagnosticsLeaf -Path $path), $FileName) -le 0) { continue }
        foreach ($setting in @(Get-DeepDiagnosticsSetting -Text (Get-DeepDiagnosticsFileText -Path $path) -Section $Section)) {
            if ($Key -ccontains $setting.Key) { [pscustomobject]@{ Path = $path; Key = $setting.Key; Value = $setting.Value } }
        }
    }
    return @($later)
}

# --- REGION: Plan building blocks
function New-DeepDiagnosticsComponent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record; changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Name)
    return [pscustomobject]@{
        Name    = $Name
        # apply: has steps to run; current: already in place; skip: cannot apply here.
        Action  = 'apply'
        Reason  = ''
        Notes   = [Collections.Generic.List[string]]::new()
        Changes = [Collections.Generic.List[object]]::new()
        Steps   = [Collections.Generic.List[object]]::new()
        # What the state file keeps for Disable: every value as it was before
        # Enable changed it.
        Record  = [ordered]@{
            files    = [Collections.Generic.List[object]]::new()
            sysctl   = [Collections.Generic.List[object]]::new()
            units    = [Collections.Generic.List[object]]::new()
            modules  = [Collections.Generic.List[object]]::new()
            packages = [Collections.Generic.List[object]]::new()
        }
    }
}

function Add-DeepDiagnosticsChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Component, [Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Previous, [AllowEmptyString()][string]$New)
    $Component.Changes.Add([pscustomobject]@{ Key = $Key; Previous = $Previous; New = $New })
}

function Add-DeepDiagnosticsSudoStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Component,
        [Parameter(Mandatory)][string[]]$Argument,
        # A failure is logged and the component still counts as applied.
        [switch]$Optional,
        # A failure fails the component but does not stop the steps after it.
        [switch]$Independent,
        [scriptblock]$After
    )
    $Component.Steps.Add(@{ Kind = 'sudo'; Argument = $Argument; Optional = [bool]$Optional; Independent = [bool]$Independent; After = $After })
}

function Add-DeepDiagnosticsFileStep {
    <#
    .SYNOPSIS
        Plan one file Enable owns: record what is there now, and write it only
        when its content differs.
    .OUTPUTS
        [bool] $true when the file will be written.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Component,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [string]$Mode = '0644'
    )
    $current = Get-DeepDiagnosticsFileText -Path $Path
    $exists = Test-DeepDiagnosticsPath -Path $Path
    if ($exists -and $null -eq $current) {
        # Something is there that cannot be read, so it could not be put back.
        $Component.Action = 'skip'
        $Component.Reason = Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_existing_unreadable' -Arguments @{ path = "$Path" }
        return $false
    }
    $entry = [ordered]@{ path = $Path; existed = [bool]$exists; mode = $Mode }
    if ($exists) { $entry.previousContent = $current }
    $Component.Record.files.Add($entry)
    if ($current -ceq $Content) { return $false }
    $previous = if ($exists) {
        Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_saved_content' -Arguments @{ statePath = "$script:StatePath" }
    } else {
        Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_absent'
    }
    Add-DeepDiagnosticsChange -Component $Component -Key $Path -Previous $previous -New (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_yuruna_file')
    $Component.Steps.Add(@{ Kind = 'file'; Path = $Path; Content = $Content; Mode = $Mode })
    return $true
}

function Add-DeepDiagnosticsUnitStep {
    <#
    .SYNOPSIS
        Plan one unit to be enabled and, with -Start or -Restart, running;
        record how it was before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Component,
        [Parameter(Mandatory)][string]$Unit,
        # Enable installs the unit file itself, so Disable removes the unit
        # rather than putting an earlier state back.
        [switch]$Owned,
        [switch]$Start,
        # The unit's files changed, so a running instance must restart to use them.
        [switch]$Restart
    )
    $state = Get-DeepDiagnosticsUnitState -Unit $Unit
    $Component.Record.units.Add([ordered]@{ name = $Unit; owned = [bool]$Owned; enabled = $state.Enabled; active = $state.Active })
    $wantActive = $Start -or $Restart
    $after = @($(if ($state.Enabled -ne 'enabled') { 'enabled' } else { $state.Enabled }), $(if ($wantActive) { 'active' } else { $state.Active })) -join ', '
    $before = @($state.Enabled, $state.Active) -join ', '
    if ($state.Enabled -ne 'enabled') {
        Add-DeepDiagnosticsSudoStep -Component $Component -Argument @('systemctl', 'enable', $Unit)
    }
    if ($Restart -and $state.Active -eq 'active') {
        Add-DeepDiagnosticsSudoStep -Component $Component -Argument @('systemctl', 'restart', $Unit)
    } elseif ($wantActive -and $state.Active -ne 'active') {
        Add-DeepDiagnosticsSudoStep -Component $Component -Argument @('systemctl', 'start', $Unit)
    }
    if ($before -ne $after) { Add-DeepDiagnosticsChange -Component $Component -Key $Unit -Previous $before -New $after }
}

function Complete-DeepDiagnosticsComponent {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Component)
    if ($Component.Action -eq 'apply' -and $Component.Steps.Count -eq 0) { $Component.Action = 'current' }
    if ($Component.Action -eq 'skip') {
        $Component.Steps.Clear()
        $Component.Changes.Clear()
    }
    return $Component
}

function Skip-DeepDiagnosticsComponent {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Component, [Parameter(Mandatory)][string]$Reason)
    $Component.Action = 'skip'
    $Component.Reason = $Reason
    return (Complete-DeepDiagnosticsComponent -Component $Component)
}

# --- REGION: Component plans
function Get-DeepDiagnosticsSysctlPlan {
    <#
    .SYNOPSIS
        Lockups and oopses become panics, and a panic reboots after 30 seconds
        with every CPU's backtrace in the log, instead of a host that hangs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $c = New-DeepDiagnosticsComponent -Name 'sysctl'
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add($script:GeneratedHeader)
    $runtime = [Collections.Generic.List[string[]]]::new()
    foreach ($key in $script:SysctlSetting.Keys) {
        $raw = Get-DeepDiagnosticsFileText -Path ('/proc/sys/' + $key.Replace('.', '/'))
        if ($null -eq $raw) {
            $c.Notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_sysctl_not_exposed' -Arguments @{ key = "$key" }))
            continue
        }
        $current = ConvertTo-DeepDiagnosticsValue $raw
        $wanted = $script:SysctlSetting[$key]
        $lines.Add("$key = $wanted")
        $c.Record.sysctl.Add([ordered]@{ key = $key; previous = $current; value = $wanted })
        if ($current -ne $wanted) {
            Add-DeepDiagnosticsChange -Component $c -Key $key -Previous $current -New $wanted
            $runtime.Add([string[]]@('sysctl', '-w', "$key=$wanted"))
        }
    }
    [void](Add-DeepDiagnosticsFileStep -Component $c -Path "/etc/sysctl.d/$script:SysctlFileName" -Content (($lines -join "`n") + "`n"))
    # A key the kernel exposes can still refuse a value: kernel.nmi_watchdog
    # does without a usable hard-lockup detector. The other keys apply anyway,
    # and the failure names the refused one.
    foreach ($argument in $runtime) { Add-DeepDiagnosticsSudoStep -Component $c -Argument $argument -Independent }
    foreach ($later in @(Get-DeepDiagnosticsLaterSetting -Directory $script:SysctlDirectory -FileName $script:SysctlFileName -Key @($script:SysctlSetting.Keys))) {
        $c.Notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_setting_overridden' -Arguments @{ path = "$($later.Path)"; key = "$($later.Key)"; value = "$($later.Value)" }))
    }
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

function Get-DeepDiagnosticsPstorePlan {
    <#
    .SYNOPSIS
        A panic's last kernel messages kept in UEFI variables (efi-pstore) and
        archived at the next boot by systemd-pstore.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $c = New-DeepDiagnosticsComponent -Name 'pstore'
    if (-not (Test-DeepDiagnosticsPath -Path '/sys/firmware/efi')) {
        return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_pstore_legacy_bios'))
    }
    if (-not (Test-DeepDiagnosticsPath -Path '/sys/module/pstore')) {
        return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_pstore_unsupported'))
    }
    $unit = Get-DeepDiagnosticsUnitState -Unit 'systemd-pstore.service'
    if ($unit.Enabled -eq 'masked') {
        return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_pstore_unit_masked'))
    }
    $backend = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path '/sys/module/pstore/parameters/backend')
    if ($backend -and $backend -ne '(null)') {
        $c.Notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_pstore_backend' -Arguments @{ backend = "$backend" }))
    } else {
        $loaded = Test-DeepDiagnosticsPath -Path '/sys/module/efi_pstore'
        $c.Record.modules.Add([ordered]@{ name = 'efi_pstore'; wasLoaded = [bool]$loaded })
        # Some builds register efi-pstore disabled; the module option is what
        # turns it on, and it has to be on disk before the module loads.
        $release = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path '/proc/sys/kernel/osrelease')
        $config = Get-DeepDiagnosticsFileText -Path "/boot/config-$release"
        $disabledParameter = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path '/sys/module/efi_pstore/parameters/pstore_disable')
        $needOption = ("$config" -match '(?m)^CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y\s*$') -or ($disabledParameter -eq 'Y')
        [void](Add-DeepDiagnosticsFileStep -Component $c -Path '/etc/modules-load.d/yuruna-deep-diagnostics.conf' -Content "$script:GeneratedHeader`nefi_pstore`n")
        if ($needOption) {
            [void](Add-DeepDiagnosticsFileStep -Component $c -Path '/etc/modprobe.d/yuruna-deep-diagnostics.conf' -Content "$script:GeneratedHeader`noptions efi_pstore pstore_disable=N`n")
        }
        if ($loaded) { Add-DeepDiagnosticsSudoStep -Component $c -Argument @('modprobe', '-r', 'efi_pstore') }
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('modprobe', 'efi_pstore')
        $c.Steps.Add(@{
                Kind  = 'check'
                Check = {
                    $now = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path '/sys/module/pstore/parameters/backend')
                    if (-not $now -or $now -eq '(null)') {
                        return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_pstore_no_backend' -Arguments @{ backend = "$now" })
                    }
                    return ''
                }
            })
        Add-DeepDiagnosticsChange -Component $c -Key (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_key_pstore_backend') `
            -Previous (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_none') -New 'efi_pstore'
    }
    # A systemd too old to have systemd-pstore leaves the records in
    # /sys/fs/pstore, where the boot evidence bundle still reads them.
    if ($unit.Enabled -notin @('enabled', 'static', 'alias', 'indirect', 'generated', 'enabled-runtime', 'not-found')) {
        Add-DeepDiagnosticsUnitStep -Component $c -Unit 'systemd-pstore.service'
    }
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

function Get-DeepDiagnosticsWatchdogPlan {
    <#
    .SYNOPSIS
        systemd pings a hardware watchdog every 30 seconds, so a host whose
        processors stop is reset after 60 seconds instead of waiting for a
        person to power-cycle it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $c = New-DeepDiagnosticsComponent -Name 'watchdog'
    $devices = @(Get-DeepDiagnosticsWatchdogDevice)
    $hardware = @($devices | Where-Object { $_.Identity -ne 'Software Watchdog' })[0]
    $software = @($devices | Where-Object { $_.Identity -eq 'Software Watchdog' })[0]
    $runtime = Get-DeepDiagnosticsRuntimeWatchdog
    $vendor = (([regex]::Match("$(Get-DeepDiagnosticsFileText -Path '/proc/cpuinfo')", '(?m)^vendor_id\s*:\s*(\S+)')).Groups[1].Value)
    $module = "$($script:WatchdogDriver[$vendor])"
    foreach ($daemon in @('watchdog.service', 'wd_keepalive.service')) {
        if ((Get-DeepDiagnosticsUnitState -Unit $daemon).Active -eq 'active') {
            return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_daemon' -Arguments @{ unit = "$daemon" }))
        }
    }
    # The module that provides the device the drop-in names, loaded again at
    # every boot; empty for a driver built into the kernel, which needs no unit.
    $driver = ''
    if ($hardware) {
        $device = "/dev/$($hardware.Name)"
        $state = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "$($hardware.Path)/state")
        # Active while systemd has no runtime watchdog means another process
        # opened it; the device takes one opener at a time.
        if ($state -eq 'active' -and $runtime -eq '0') {
            return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_held' -Arguments @{ device = "$device" }))
        }
        if ((ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "$($hardware.Path)/nowayout")) -eq '1') {
            return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_nowayout' -Arguments @{ device = "$device" }))
        }
        # The driver that provides it is not necessarily the CPU vendor's (a
        # virtual machine's i6300esb, say). One that cannot be identified
        # would leave the watchdog armed now and gone after the next reboot,
        # which reads as applied while the next freeze finds no watchdog.
        $provider = Get-DeepDiagnosticsWatchdogProvider
        if (-not $provider.Module -and -not $provider.BuiltIn) {
            $found = if ($provider.Drivers.Count -gt 0) { $provider.Drivers -join ', ' } else { Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_none' }
            return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_provider_unknown' -Arguments @{ device = "$device"; identity = "$($hardware.Identity)"; drivers = "$found" }))
        }
        $driver = $provider.Module
    } elseif ($software) {
        return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_softdog' -Arguments @{ device = "/dev/$($software.Name)" }))
    } elseif (-not $module) {
        return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_no_driver' -Arguments @{ vendor = "$vendor" }))
    } else {
        $driver = $module
        $device = '/dev/watchdog0'
        $c.Record.modules.Add([ordered]@{ name = $module; wasLoaded = $false })
        Add-DeepDiagnosticsChange -Component $c -Key $module -Previous (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_not_loaded') `
            -New (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_loaded')
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('modprobe', $module)
        $c.Steps.Add(@{
                Kind   = 'check'
                Module = $module
                Check  = {
                    param($Step)
                    $registered = @(Get-DeepDiagnosticsWatchdogDevice | Where-Object { $_.Identity -ne 'Software Watchdog' })[0]
                    if (-not $registered) {
                        return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_no_device' -Arguments @{ module = "$($Step.Module)" })
                    }
                    if ((ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "$($registered.Path)/nowayout")) -eq '1') {
                        return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_watchdog_nowayout' -Arguments @{ device = "/dev/$($registered.Name)" })
                    }
                    return ''
                }
            })
    }
    # Ubuntu deny-lists the hardware watchdog drivers, which then load only
    # when named, so a driver that is loaded now has to be named again at
    # every boot.
    if ($driver) {
        $unitChanged = Add-DeepDiagnosticsFileStep -Component $c -Path "$script:UnitDirectory/yuruna-watchdog-driver@.service" -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-watchdog-driver@.service')
        if ($unitChanged) { Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'daemon-reload') }
        Add-DeepDiagnosticsUnitStep -Component $c -Unit "yuruna-watchdog-driver@$driver.service" -Owned
    }
    $dropIn = "$script:GeneratedHeader`n[Manager]`nRuntimeWatchdogSec=$script:WatchdogSeconds`n"
    if ($device -ne '/dev/watchdog0') { $dropIn += "WatchdogDevice=$device`n" }
    $c.Record.runtimeWatchdogPrevious = $runtime
    $c.Record.device = $device
    $dropInChanged = Add-DeepDiagnosticsFileStep -Component $c -Path '/etc/systemd/system.conf.d/99-yuruna-deep-diagnostics.conf' -Content $dropIn
    if ($dropInChanged -or $runtime -ne $script:WatchdogShown) {
        Add-DeepDiagnosticsChange -Component $c -Key 'RuntimeWatchdogSec' -Previous $runtime -New $script:WatchdogSeconds
        # system.conf is read only when PID 1 starts or re-executes.
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'daemon-reexec')
    }
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

function Get-DeepDiagnosticsJournaldValue {
    # The values journald runs with, from its main file and every drop-in but
    # the one named, over its built-in defaults.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([string]$Exclude = '')
    $value = [ordered]@{}
    foreach ($key in $script:JournaldDefault.Keys) { $value[$key] = $script:JournaldDefault[$key] }
    $main = @($script:JournaldMain | Where-Object { Test-DeepDiagnosticsPath -Path $_ })[0]
    $files = @(@($main) + @(Get-DeepDiagnosticsConfigFile -Directory $script:JournaldDirectory) | Where-Object { $_ -and $_ -ne $Exclude })
    foreach ($path in $files) {
        foreach ($setting in @(Get-DeepDiagnosticsSetting -Text (Get-DeepDiagnosticsFileText -Path $path) -Section 'Journal')) {
            if ($value.Contains($setting.Key)) { $value[$setting.Key] = $setting.Value }
        }
    }
    return $value
}

function Get-DeepDiagnosticsJournaldPlan {
    <#
    .SYNOPSIS
        A persistent journal synced to disk every 10 seconds rather than every
        5 minutes, so the minutes before a freeze are on disk afterwards.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $c = New-DeepDiagnosticsComponent -Name 'journald'
    $path = "/etc/systemd/journald.conf.d/$script:JournaldFileName"
    $before = Get-DeepDiagnosticsJournaldValue -Exclude $path
    $c.Record.previous = $before
    $c.Record.journalDirectoryExisted = [bool](Test-DeepDiagnosticsPath -Path '/var/log/journal')
    $content = "$script:GeneratedHeader`n[Journal]`n" + (($script:JournaldSetting.Keys | ForEach-Object { "$_=$($script:JournaldSetting[$_])" }) -join "`n") + "`n"
    if (Add-DeepDiagnosticsFileStep -Component $c -Path $path -Content $content) {
        foreach ($key in $script:JournaldSetting.Keys) {
            if ($before[$key] -ne $script:JournaldSetting[$key]) { Add-DeepDiagnosticsChange -Component $c -Key $key -Previous $before[$key] -New $script:JournaldSetting[$key] }
        }
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'restart', 'systemd-journald.service')
    }
    foreach ($later in @(Get-DeepDiagnosticsLaterSetting -Directory $script:JournaldDirectory -FileName $script:JournaldFileName -Key @($script:JournaldSetting.Keys) -Section 'Journal')) {
        $c.Notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_setting_overridden' -Arguments @{ path = "$($later.Path)"; key = "$($later.Key)"; value = "$($later.Value)" }))
    }
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

function Get-DeepDiagnosticsRasdaemonPlan {
    <#
    .SYNOPSIS
        rasdaemon records machine-check, memory-controller and PCIe errors,
        which name failing hardware that a freeze alone does not.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $c = New-DeepDiagnosticsComponent -Name 'rasdaemon'
    $status = Get-DeepDiagnosticsPackageStatus -Name 'rasdaemon'
    if ($status -cmatch '^.i') {
        Add-DeepDiagnosticsUnitStep -Component $c -Unit 'rasdaemon.service' -Start
    } else {
        # 'rc': removed earlier with its configuration files kept, which the
        # install takes up again and a purge at Disable would delete.
        $c.Record.packages.Add([ordered]@{ name = 'rasdaemon'; installedByYuruna = $false; configFilesBefore = ($status -cmatch '^.c') })
        Add-DeepDiagnosticsChange -Component $c -Key 'rasdaemon' -Previous (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_not_installed') `
            -New (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_installed')
        # Fresh package lists help, and stale ones usually still install it.
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('apt-get', 'update', '-q') -Optional
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-q', 'rasdaemon') -After {
            param($Component)
            $Component.Record.packages[0].installedByYuruna = $true
        }
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'enable', '--now', 'rasdaemon.service')
    }
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

function Get-DeepDiagnosticsNetconsoleTarget {
    # What the kernel is sending to now, read back from configfs.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $dir = $script:NetconsoleDirectory
    return [pscustomobject]@{
        Enabled = (ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "$dir/enabled")) -eq '1'
        Address = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "$dir/remote_ip")
        Port    = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "$dir/remote_port")
    }
}

function Get-DeepDiagnosticsNetconsolePlan {
    <#
    .SYNOPSIS
        Kernel messages sent over UDP to another machine as they are logged,
        which reaches the receiver even when the last seconds never reach disk.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$Target)
    $c = New-DeepDiagnosticsComponent -Name 'netconsole'
    if (-not $Target) {
        return (Skip-DeepDiagnosticsComponent -Component $c -Reason (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_netconsole_no_target'))
    }
    $text = "$($Target.Address):$($Target.Port)"
    $changed = @(
        Add-DeepDiagnosticsFileStep -Component $c -Path "$script:LibraryDirectory/yuruna-netconsole.sh" -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-netconsole.sh') -Mode '0755'
        Add-DeepDiagnosticsFileStep -Component $c -Path "$script:ConfigDirectory/netconsole.conf" -Content "$script:GeneratedHeader`nTARGET=$text`n"
        Add-DeepDiagnosticsFileStep -Component $c -Path "$script:UnitDirectory/yuruna-netconsole.service" -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-netconsole.service')
    )
    # This host takes a new address at every boot and lease; without the hook
    # the target is re-applied at boot only.
    if (Test-DeepDiagnosticsPath -Path '/etc/NetworkManager/dispatcher.d') {
        $changed += Add-DeepDiagnosticsFileStep -Component $c -Path '/etc/NetworkManager/dispatcher.d/90-yuruna-netconsole' -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-netconsole-dispatcher.sh') -Mode '0755'
    } else {
        $c.Notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_netconsole_no_dispatcher'))
    }
    $c.Record.modules.Add([ordered]@{ name = 'netconsole'; wasLoaded = [bool](Test-DeepDiagnosticsPath -Path '/sys/module/netconsole') })
    if ($changed[2]) { Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'daemon-reload') }
    Add-DeepDiagnosticsUnitStep -Component $c -Unit 'yuruna-netconsole.service' -Owned
    $live = Get-DeepDiagnosticsNetconsoleTarget
    $sending = $live.Enabled -and $live.Address -eq $Target.Address -and $live.Port -eq "$($Target.Port)"
    if (($changed -contains $true) -or -not $sending) {
        $previous = if ($live.Enabled) { "$($live.Address):$($live.Port)" } else { Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_none' }
        Add-DeepDiagnosticsChange -Component $c -Key (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_key_netconsole') -Previous $previous -New $text
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @("$script:LibraryDirectory/yuruna-netconsole.sh", 'apply')
        $c.Steps.Add(@{
                Kind  = 'check'
                Check = {
                    if (-not (Get-DeepDiagnosticsNetconsoleTarget).Enabled) { return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_netconsole_not_enabled') }
                    return ''
                }
            })
    }
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

function Get-DeepDiagnosticsVitalsPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $c = New-DeepDiagnosticsComponent -Name 'vitals'
    $loopChanged = Add-DeepDiagnosticsFileStep -Component $c -Path "$script:LibraryDirectory/yuruna-vitals.sh" -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-vitals.sh') -Mode '0755'
    $unitChanged = Add-DeepDiagnosticsFileStep -Component $c -Path "$script:UnitDirectory/yuruna-vitals.service" -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-vitals.service')
    if ($unitChanged) { Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'daemon-reload') }
    Add-DeepDiagnosticsUnitStep -Component $c -Unit 'yuruna-vitals.service' -Owned -Start -Restart:($loopChanged -or $unitChanged)
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

function Get-DeepDiagnosticsBootEvidencePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $c = New-DeepDiagnosticsComponent -Name 'bootEvidence'
    [void](Add-DeepDiagnosticsFileStep -Component $c -Path "$script:LibraryDirectory/yuruna-boot-evidence.sh" -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-boot-evidence.sh') -Mode '0755')
    $unit = Add-DeepDiagnosticsFileStep -Component $c -Path "$script:UnitDirectory/yuruna-boot-evidence.service" -Content (Get-DeepDiagnosticsTemplate -Name 'yuruna-boot-evidence.service')
    if (-not (Test-DeepDiagnosticsPath -Path $script:EvidenceDirectory)) {
        Add-DeepDiagnosticsSudoStep -Component $c -Argument @('install', '-d', '-m', '0750', '-o', 'root', '-g', 'systemd-journal', $script:EvidenceDirectory)
        Add-DeepDiagnosticsChange -Component $c -Key $script:EvidenceDirectory -Previous (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_absent') -New 'root:systemd-journal 0750'
    }
    if ($unit) { Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'daemon-reload') }
    $state = Get-DeepDiagnosticsUnitState -Unit 'yuruna-boot-evidence.service'
    Add-DeepDiagnosticsUnitStep -Component $c -Unit 'yuruna-boot-evidence.service' -Owned
    # Run once now as well: the previous boot may be the freeze being chased,
    # and the bundle's once-per-boot check keeps a second run from adding one.
    if ($state.Enabled -ne 'enabled') { Add-DeepDiagnosticsSudoStep -Component $c -Argument @('systemctl', 'start', 'yuruna-boot-evidence.service') }
    return (Complete-DeepDiagnosticsComponent -Component $c)
}

# --- REGION: Plan
function ConvertTo-DeepDiagnosticsTarget {
    <#
    .SYNOPSIS
        '<IPv4>[:port]' as @{ Address; Port }, or $null when it is not one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][string]$Text)
    $m = [regex]::Match("$Text".Trim(), '^(?<address>(?:\d{1,3}\.){3}\d{1,3})(?::(?<port>\d{1,5}))?$')
    if (-not $m.Success) { return $null }
    $address = $m.Groups['address'].Value
    foreach ($octet in $address.Split('.')) { if ([int]$octet -gt 255) { return $null } }
    $port = if ($m.Groups['port'].Success) { [int]$m.Groups['port'].Value } else { 6666 }
    if ($port -lt 1 -or $port -gt 65535) { return $null }
    return [pscustomobject]@{ Address = $address; Port = $port }
}

function Get-DeepDiagnosticsRefusal {
    <#
    .SYNOPSIS
        Why this host cannot run deep diagnostics mode, or '' when it can.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$NetconsoleTarget = '')
    if (-not (Test-DeepDiagnosticsLinux)) { return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_requires_linux') }
    # The directory systemd creates when it is the running init; a container
    # or another init has a systemctl binary but no manager to talk to.
    if (-not (Test-DeepDiagnosticsPath -Path '/run/systemd/system')) { return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_requires_systemd') }
    if ($NetconsoleTarget -and -not (ConvertTo-DeepDiagnosticsTarget -Text $NetconsoleTarget)) {
        return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_target_invalid' -Arguments @{ target = "$NetconsoleTarget" })
    }
    return ''
}

function Read-DeepDiagnosticsState {
    <#
    .SYNOPSIS
        The state file as a hashtable: @{ State; Error }. State is $null when
        the file does not exist; Error explains a file that exists but is not
        a deep-diagnostics state.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if (-not (Test-DeepDiagnosticsPath -Path $script:StatePath)) { return @{ State = $null; Error = '' } }
    $text = Get-DeepDiagnosticsFileText -Path $script:StatePath
    $jsonOption = $script:StateJsonOption
    try {
        $state = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop @jsonOption
        if (-not $state -or $state['schema'] -ne $script:StateSchema) { throw "schema is not $script:StateSchema" }
        return @{ State = $state; Error = '' }
    } catch {
        return @{ State = $null; Error = (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_state_unreadable' -Arguments @{ path = "$script:StatePath"; message = "$($_.Exception.Message)" }) }
    }
}

function Merge-DeepDiagnosticsRecord {
    <#
    .SYNOPSIS
        Keep the first Enable's prior values in a later Enable's record.
    .DESCRIPTION
        A second Enable sees the values the first one set. Recording those as
        the prior values would make Disable restore Enable's own settings, so
        whatever the state file already holds for an entry wins, and entries
        only the state file has are carried forward.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [AllowNull()]$Previous)
    if (-not $Previous) { return }
    $identity = [ordered]@{ files = 'path'; sysctl = 'key'; units = 'name'; modules = 'name'; packages = 'name' }
    foreach ($list in $identity.Keys) {
        foreach ($old in @($Previous[$list])) {
            if (-not $old) { continue }
            $key = $identity[$list]
            $match = @($Record[$list] | Where-Object { $_[$key] -eq $old[$key] })[0]
            if (-not $match) {
                $copy = [ordered]@{}
                foreach ($name in $old.Keys) { $copy[$name] = $old[$name] }
                $Record[$list].Add($copy)
                continue
            }
            foreach ($name in @($old.Keys)) {
                if ($list -eq 'packages' -and $name -eq 'installedByYuruna') {
                    $match[$name] = [bool]$old[$name] -or [bool]$match[$name]
                } elseif ($name -ne $key -and $name -ne 'value' -and $name -ne 'mode') {
                    $match[$name] = $old[$name]
                }
            }
            if ($list -eq 'files' -and -not $old.Contains('previousContent')) { $match.Remove('previousContent') }
        }
    }
    foreach ($name in @($Previous.Keys)) {
        if ($name -in @('status', 'reason') -or $identity.Contains($name)) { continue }
        $Record[$name] = $Previous[$name]
    }
}

function Get-DeepDiagnosticsMissingDirectory {
    # The directories that do not exist yet among these and their parents,
    # deepest first, which is the order Disable removes them in.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string[]]$Directory)
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($dir in $Directory) {
        $current = $dir
        while ($current -and -not $missing.Contains($current) -and -not (Test-DeepDiagnosticsPath -Path $current)) {
            $missing.Add($current)
            $current = Get-DeepDiagnosticsParent -Path $current
        }
    }
    return @($missing | Sort-Object -Property @{ Expression = { $_.Split('/').Count }; Descending = $true }, @{ Expression = { $_ } })
}

function Get-DeepDiagnosticsInitialStatus {
    <#
    .SYNOPSIS
        Each component's status before any of its steps runs: skipped with its
        reason, applied when already in place, and failed until a component
        still to apply completes, so a run that stops halfway never reads as
        applied.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Component)
    $interrupted = Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_reason_interrupted'
    $status = [ordered]@{}
    foreach ($c in $Component) {
        $status[$c.Name] = switch ($c.Action) {
            'skip' { @{ status = 'skipped'; reason = $c.Reason } }
            'current' { @{ status = 'applied'; reason = '' } }
            default { @{ status = 'failed'; reason = $interrupted } }
        }
    }
    return $status
}

function Get-DeepDiagnosticsPlan {
    <#
    .SYNOPSIS
        What Enable will change on this host, component by component, with the
        prior value of everything it will touch. Reads only; no privilege.
    .PARAMETER NetconsoleTarget
        '<IPv4>[:port]' of the receiver. Empty keeps the target the state file
        names, if any, so running Enable again does not drop it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][string]$NetconsoleTarget = '')
    $read = Read-DeepDiagnosticsState
    if ($read.Error) { throw $read.Error }
    $state = $read.State
    if (-not $NetconsoleTarget -and $state) { $NetconsoleTarget = "$($state['netconsoleTarget'])" }
    $target = if ($NetconsoleTarget) { ConvertTo-DeepDiagnosticsTarget -Text $NetconsoleTarget } else { $null }
    $components = @(
        Get-DeepDiagnosticsSysctlPlan
        Get-DeepDiagnosticsPstorePlan
        Get-DeepDiagnosticsWatchdogPlan
        Get-DeepDiagnosticsJournaldPlan
        Get-DeepDiagnosticsRasdaemonPlan
        Get-DeepDiagnosticsNetconsolePlan -Target $target
        Get-DeepDiagnosticsVitalsPlan
        Get-DeepDiagnosticsBootEvidencePlan
    )
    $directories = [Collections.Generic.List[string]]::new()
    $directories.Add((Get-DeepDiagnosticsParent -Path $script:StatePath))
    $directories.Add($script:EvidenceDirectory)
    foreach ($c in $components) {
        if ($state -and $state['components']) { Merge-DeepDiagnosticsRecord -Record $c.Record -Previous $state['components'][$c.Name] }
        foreach ($step in @($c.Steps | Where-Object { $_.Kind -eq 'file' })) { $directories.Add((Get-DeepDiagnosticsParent -Path $step.Path)) }
    }
    $created = [Collections.Generic.List[string]]::new()
    foreach ($dir in @(Get-DeepDiagnosticsMissingDirectory -Directory $directories)) { $created.Add($dir) }
    if ($state) { foreach ($dir in @($state['createdDirectories'])) { if ($dir -and -not $created.Contains($dir)) { $created.Add($dir) } } }
    # Only a run with nothing to apply and a state file that already says so
    # changes nothing. The host diagnostic reports each status from the state
    # file, so one recorded as failed that is in place now (installed by hand,
    # a target that came up later) is still written as applied.
    $stateCurrent = [bool]$state -and @($components | Where-Object Action -eq 'apply').Count -eq 0
    if ($stateCurrent) {
        $initial = Get-DeepDiagnosticsInitialStatus -Component $components
        foreach ($c in $components) {
            $old = if ($state['components']) { $state['components'][$c.Name] } else { $null }
            if (-not $old -or "$($old['status'])" -cne $initial[$c.Name].status -or "$($old['reason'])" -cne "$($initial[$c.Name].reason)") { $stateCurrent = $false }
        }
    }
    $account = if ($env:SUDO_USER) { $env:SUDO_USER } else { [Environment]::UserName }
    return [pscustomobject]@{
        Components         = $components
        StateCurrent       = $stateCurrent
        Target             = if ($target) { "$($target.Address):$($target.Port)" } else { '' }
        TargetPort         = if ($target) { $target.Port } else { 0 }
        CreatedDirectories = @($created | Sort-Object -Property @{ Expression = { $_.Split('/').Count }; Descending = $true }, @{ Expression = { $_ } })
        EnabledAtUtc       = if ($state) { ConvertTo-DeepDiagnosticsUtcText $state['enabledAtUtc'] } else { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
        EnabledBy          = if ($state) { "$($state['enabledBy'])" } else { $account }
        PreviousState      = $state
    }
}

function Get-DeepDiagnosticsTitle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return (Format-YurunaOperatorMessage -Key $script:ComponentTitleKey[$Name])
}

function Format-DeepDiagnosticsChange {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Change)
    return (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_change' -Arguments @{ key = "$($Change.Key)"; previous = "$($Change.Previous)"; new = "$($Change.New)" })
}

function Write-DeepDiagnosticsPlan {
    <#
    .SYNOPSIS
        Show the plan: every component, and every value it changes as
        'key: previous -> new', before anything is written.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_plan_header' -Arguments @{ hostName = "$([Environment]::MachineName)" })
    foreach ($c in $Plan.Components) {
        $arguments = @{ component = "$($c.Name)"; title = "$(Get-DeepDiagnosticsTitle -Name $c.Name)" }
        $key = switch ($c.Action) { 'apply' { 'host.deep_diagnostics_plan_apply' } 'current' { 'host.deep_diagnostics_plan_current' } default { 'host.deep_diagnostics_plan_skip' } }
        if ($c.Action -eq 'skip') { $arguments.reason = "$($c.Reason)" }
        Write-Information (Format-YurunaOperatorMessage -Key $key -Arguments $arguments)
        foreach ($change in $c.Changes) { Write-Information (Format-DeepDiagnosticsChange -Change $change) }
        foreach ($note in $c.Notes) { Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_plan_note' -Arguments @{ note = "$note" }) }
    }
    if (@($Plan.Components | Where-Object Action -eq 'apply').Count -gt 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_state_record' -Arguments @{ path = "$script:StatePath" })
    }
}

# --- REGION: Apply
function Install-DeepDiagnosticsFile {
    <#
    .SYNOPSIS
        Write one root-owned file through a private temporary copy and
        `install`, which replaces the target in one step with its mode set.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content, [string]$Mode = '0644')
    $temp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($temp, $Content, [Text.UTF8Encoding]::new($false))
        $r = Invoke-DeepDiagnosticsSudo -Argument @('install', '-D', '-m', $Mode, '-o', 'root', '-g', 'root', $temp, $Path)
        if ($r.ExitCode -ne 0) {
            throw (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_step_failed' -Arguments @{ command = "install $Path"; exitCode = "$($r.ExitCode)"; output = "$($r.Output)" })
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DeepDiagnosticsStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [AllowNull()]$Component)
    switch ($Step.Kind) {
        'file' { Install-DeepDiagnosticsFile -Path $Step.Path -Content $Step.Content -Mode $Step.Mode }
        'sudo' {
            $r = Invoke-DeepDiagnosticsSudo -Argument $Step.Argument
            if ($r.ExitCode -ne 0) {
                $message = Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_step_failed' -Arguments @{ command = "$($Step.Argument -join ' ')"; exitCode = "$($r.ExitCode)"; output = "$($r.Output)" }
                if (-not $Step.Optional) { throw $message }
                Write-Verbose $message
                return
            }
            if ($Step.After) { & $Step.After $Component }
        }
        'check' {
            $why = & $Step.Check $Step
            if ($why) { throw $why }
        }
        'unload' {
            # Decided when it runs, not when planned: systemd holds the
            # watchdog driver until the re-execution earlier in the restore.
            $users = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path "/sys/module/$($Step.Module)/refcnt")
            if ($users -and $users -ne '0') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_module_in_use' -Arguments @{ module = "$($Step.Module)" })
                return
            }
            $r = Invoke-DeepDiagnosticsSudo -Argument @('modprobe', '-r', $Step.Module)
            if ($r.ExitCode -ne 0) {
                throw (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_step_failed' -Arguments @{ command = "modprobe -r $($Step.Module)"; exitCode = "$($r.ExitCode)"; output = "$($r.Output)" })
            }
        }
    }
}

function Invoke-DeepDiagnosticsComponent {
    # Runs one component's steps in order; returns '' or why it failed. A
    # failed step stops the ones after it unless it is independent.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Component)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($step in $Component.Steps) {
        try {
            Invoke-DeepDiagnosticsStep -Step $step -Component $Component
        } catch {
            $failures.Add("$($_.Exception.Message)")
            if (-not $step.Independent) { break }
        }
    }
    return ($failures -join '; ')
}

function Save-DeepDiagnosticsState {
    <#
    .SYNOPSIS
        Write the state file: the record of every prior value, and each
        component's status.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][System.Collections.IDictionary]$Status)
    $components = [ordered]@{}
    foreach ($c in $Plan.Components) {
        $entry = [ordered]@{ status = $Status[$c.Name].status; reason = $Status[$c.Name].reason }
        foreach ($name in $c.Record.Keys) { $entry[$name] = $c.Record[$name] }
        $components[$c.Name] = $entry
    }
    $document = [ordered]@{
        schema             = $script:StateSchema
        enabledAtUtc       = $Plan.EnabledAtUtc
        enabledBy          = $Plan.EnabledBy
        hostType           = 'host.ubuntu.kvm'
        netconsoleTarget   = $Plan.Target
        updatedAtUtc       = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        createdDirectories = @($Plan.CreatedDirectories)
        components         = $components
    }
    Install-DeepDiagnosticsFile -Path $script:StatePath -Content (($document | ConvertTo-Json -Depth 8) + "`n") -Mode '0644'
}

function Invoke-DeepDiagnosticsEnable {
    <#
    .SYNOPSIS
        Record the prior state, then apply each component of the plan,
        continuing past one that fails.
    .OUTPUTS
        @{ ExitCode; Status }: 0 when every component is applied or skipped
        with a reason, 1 when nothing could be changed, 2 when a component
        failed and the others are in place.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Plan)
    $previous = $Plan.PreviousState
    $pending = @($Plan.Components | Where-Object Action -eq 'apply')
    if ($Plan.StateCurrent) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_nothing_to_change')
        return [pscustomobject]@{ ExitCode = 0; Status = $null }
    }
    if (-not $PSCmdlet.ShouldProcess($script:StatePath, (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_should_record'))) {
        return [pscustomobject]@{ ExitCode = 0; Status = $null }
    }
    if ((Invoke-DeepDiagnosticsSudo -Argument @('true')).ExitCode -ne 0) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_sudo_unavailable') -ErrorAction Continue
        return [pscustomobject]@{ ExitCode = 1; Status = $null }
    }
    $status = Get-DeepDiagnosticsInitialStatus -Component $Plan.Components
    # Before the first change, so a host that freezes while this runs still
    # leaves Disable a complete record.
    try {
        Save-DeepDiagnosticsState -Plan $Plan -Status $status
    } catch {
        Write-Error "$($_.Exception.Message)" -ErrorAction Continue
        return [pscustomobject]@{ ExitCode = 1; Status = $status }
    }
    foreach ($c in $pending) {
        $title = Get-DeepDiagnosticsTitle -Name $c.Name
        if (-not $PSCmdlet.ShouldProcess("$($c.Name) ($title)", (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_should_apply'))) {
            $old = if ($previous -and $previous['components']) { $previous['components'][$c.Name] } else { $null }
            $status[$c.Name] = if ($old) { @{ status = "$($old['status'])"; reason = "$($old['reason'])" } } else { @{ status = 'skipped'; reason = (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_reason_declined') } }
        } else {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_applying' -Arguments @{ component = "$($c.Name)"; title = "$title" })
            $why = Invoke-DeepDiagnosticsComponent -Component $c
            if ($why) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_component_failed' -Arguments @{ component = "$($c.Name)"; reason = "$why" })
                $status[$c.Name] = @{ status = 'failed'; reason = $why }
            } else {
                $status[$c.Name] = @{ status = 'applied'; reason = '' }
            }
        }
        try {
            Save-DeepDiagnosticsState -Plan $Plan -Status $status
        } catch {
            Write-Warning "$($_.Exception.Message)"
        }
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_summary_header')
    foreach ($name in $status.Keys) {
        $arguments = @{ component = "$name" }
        $key = switch ($status[$name].status) { 'applied' { 'host.deep_diagnostics_summary_applied' } 'skipped' { 'host.deep_diagnostics_summary_skipped' } default { 'host.deep_diagnostics_summary_failed' } }
        if ($status[$name].status -ne 'applied') { $arguments.reason = "$($status[$name].reason)" }
        Write-Information (Format-YurunaOperatorMessage -Key $key -Arguments $arguments)
    }
    if ($Plan.Target) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_receiver_command' -Arguments @{ port = "$($Plan.TargetPort)" })
    } else {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_netconsole_how_to')
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_verify')
    $failed = @($status.Keys | Where-Object { $status[$_].status -eq 'failed' })
    if ($failed.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_enable_incomplete' -Arguments @{ count = "$($failed.Count)" })
        return [pscustomobject]@{ ExitCode = 2; Status = $status }
    }
    return [pscustomobject]@{ ExitCode = 0; Status = $status }
}

# --- REGION: Restore
function Add-DeepDiagnosticsRestoreItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Item,
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Previous,
        [AllowEmptyString()][string]$New,
        [Parameter(Mandatory)][hashtable[]]$Step
    )
    $Item.Add([pscustomobject]@{ Change = [pscustomobject]@{ Key = $Key; Previous = $Previous; New = $New }; Steps = $Step })
}

function Get-DeepDiagnosticsRestorePlan {
    <#
    .SYNOPSIS
        What Disable will revert, read from the state file alone and checked
        against the host as it is now.
    .DESCRIPTION
        Order matters: the netconsole target goes first, since its configfs
        directory keeps the netconsole module from unloading; units stop
        before their files go; systemd re-reads its configuration before a
        watchdog driver it held is unloaded; sysctl values return after the
        drop-in that would re-apply them at boot is gone; packages Enable
        installed go last.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$State, [switch]$RemoveEvidence)
    $items = [Collections.Generic.List[object]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    $components = if ($State -and $State['components']) { $State['components'] } else { @{} }
    $entries = { param([string]$List) foreach ($name in $components.Keys) { foreach ($entry in @($components[$name][$List])) { if ($entry) { $entry } } } }
    $removed = Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_removed'
    $yurunaFile = Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_yuruna_file'
    $installedByYuruna = @(& $entries 'packages' | Where-Object { $_['installedByYuruna'] } | ForEach-Object { "$($_['name'])" })
    $configFilesBefore = @(& $entries 'packages' | Where-Object { $_['configFilesBefore'] } | ForEach-Object { "$($_['name'])" })

    # Keyed on the directory, not on the target being enabled: one the kernel
    # refused or disabled still pins the module. rmdir removes an enabled
    # target as well, and needs no helper script, so a run that removes the
    # script after a failed removal leaves the next run able to retry.
    if ($State -and "$($State['netconsoleTarget'])" -and (Test-DeepDiagnosticsPath -Path $script:NetconsoleDirectory)) {
        Add-DeepDiagnosticsRestoreItem -Item $items -Key (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_key_netconsole') -Previous "$($State['netconsoleTarget'])" -New $removed `
            -Step @(@{ Kind = 'sudo'; Argument = @('rmdir', '--', $script:NetconsoleDirectory) })
    }
    foreach ($unit in @(& $entries 'units')) {
        $name = "$($unit['name'])"
        $now = Get-DeepDiagnosticsUnitState -Unit $name
        if ($unit['owned']) {
            if ($now.Enabled -ne 'not-found' -or $now.Active -eq 'active') {
                Add-DeepDiagnosticsRestoreItem -Item $items -Key $name -Previous "$($now.Enabled), $($now.Active)" -New $removed -Step @(@{ Kind = 'sudo'; Argument = @('systemctl', 'disable', '--now', $name) })
            }
            continue
        }
        if ($installedByYuruna -contains ($name -replace '\.service$', '')) { continue }
        $steps = [Collections.Generic.List[hashtable]]::new()
        if ("$($unit['enabled'])" -eq 'disabled' -and $now.Enabled -eq 'enabled') { $steps.Add(@{ Kind = 'sudo'; Argument = @('systemctl', 'disable', $name) }) }
        if ("$($unit['active'])" -ne 'active' -and $now.Active -eq 'active') { $steps.Add(@{ Kind = 'sudo'; Argument = @('systemctl', 'stop', $name) }) }
        if ($steps.Count -gt 0) {
            Add-DeepDiagnosticsRestoreItem -Item $items -Key $name -Previous "$($now.Enabled), $($now.Active)" -New "$($unit['enabled']), $($unit['active'])" -Step $steps.ToArray()
        }
    }
    $reexec = $false
    $lastUnitFile = $null
    foreach ($component in $components.Keys) {
        foreach ($file in @($components[$component]['files'])) {
            if (-not $file) { continue }
            $path = "$($file['path'])"
            $now = Get-DeepDiagnosticsFileText -Path $path
            if ($file['existed'] -and $file.Contains('previousContent')) {
                if ($now -cne "$($file['previousContent'])") {
                    Add-DeepDiagnosticsRestoreItem -Item $items -Key $path -Previous $yurunaFile -New (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_restored_content' -Arguments @{ statePath = "$script:StatePath" }) `
                        -Step @(@{ Kind = 'file'; Path = $path; Content = "$($file['previousContent'])"; Mode = $(if ($file['mode']) { "$($file['mode'])" } else { '0644' }) })
                }
            } elseif (-not $file['existed'] -and (Test-DeepDiagnosticsPath -Path $path)) {
                Add-DeepDiagnosticsRestoreItem -Item $items -Key $path -Previous $yurunaFile -New $removed -Step @(@{ Kind = 'sudo'; Argument = @('rm', '-f', '--', $path) })
            } else {
                continue
            }
            if ($component -eq 'watchdog' -and $path -like '/etc/systemd/system.conf.d/*') { $reexec = $true }
            if ($path -like "$script:UnitDirectory/*") { $lastUnitFile = $items[$items.Count - 1] }
            if ($component -eq 'journald') {
                $before = $components['journald']['previous']
                Add-DeepDiagnosticsRestoreItem -Item $items -Key (@($script:JournaldSetting.Keys) -join ', ') -Previous (@($script:JournaldSetting.Values) -join ', ') `
                    -New (@($script:JournaldSetting.Keys | ForEach-Object { "$($before[$_])" }) -join ', ') -Step @(@{ Kind = 'sudo'; Argument = @('systemctl', 'restart', 'systemd-journald.service') })
            }
        }
    }
    # Re-executing also reloads units; otherwise systemd forgets the removed
    # unit files with a reload right after the last of them goes.
    if ($reexec) {
        Add-DeepDiagnosticsRestoreItem -Item $items -Key 'RuntimeWatchdogSec' -Previous $script:WatchdogSeconds -New "$($components['watchdog']['runtimeWatchdogPrevious'])" `
            -Step @(@{ Kind = 'sudo'; Argument = @('systemctl', 'daemon-reexec') })
    } elseif ($lastUnitFile) {
        $lastUnitFile.Steps = @($lastUnitFile.Steps) + @(@{ Kind = 'sudo'; Argument = @('systemctl', 'daemon-reload') })
    }
    foreach ($entry in @(& $entries 'sysctl')) {
        $key = "$($entry['key'])"
        $now = ConvertTo-DeepDiagnosticsValue (Get-DeepDiagnosticsFileText -Path ('/proc/sys/' + $key.Replace('.', '/')))
        $previous = "$($entry['previous'])"
        if ($now -and $now -ne $previous) {
            Add-DeepDiagnosticsRestoreItem -Item $items -Key $key -Previous $now -New $previous -Step @(@{ Kind = 'sudo'; Argument = @('sysctl', '-w', "$key=$previous") })
        }
    }
    foreach ($module in @(& $entries 'modules')) {
        $name = "$($module['name'])"
        if ($module['wasLoaded'] -or -not (Test-DeepDiagnosticsPath -Path "/sys/module/$name")) { continue }
        Add-DeepDiagnosticsRestoreItem -Item $items -Key $name -Previous (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_loaded') -New (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_not_loaded') `
            -Step @(@{ Kind = 'unload'; Module = $name })
    }
    foreach ($package in $installedByYuruna) {
        if (-not (Test-DeepDiagnosticsPackage -Name $package)) { continue }
        # A purge also removes the configuration files and the unit links a
        # plain remove leaves behind in dpkg's 'rc' state, unless the package
        # was in that state before the install. Never --autoremove: that
        # removes every package apt considers unneeded, old kernels among them.
        $verb = if ($configFilesBefore -contains $package) { 'remove' } else { 'purge' }
        Add-DeepDiagnosticsRestoreItem -Item $items -Key $package -Previous (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_installed') -New $removed `
            -Step @(@{ Kind = 'sudo'; Argument = @('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', $verb, '-y', '-q', $package) })
        $notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_dependencies_kept' -Arguments @{ package = "$package" }))
    }
    if (Test-DeepDiagnosticsPath -Path $script:EvidenceDirectory) {
        if ($RemoveEvidence) {
            # The parent is Yuruna's own and goes once it is empty, however
            # many Enable and Disable runs ago it was created; rmdir leaves
            # it when anything else is in it.
            Add-DeepDiagnosticsRestoreItem -Item $items -Key $script:EvidenceDirectory -Previous (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_value_evidence') -New $removed -Step @(
                @{ Kind = 'sudo'; Argument = @('rm', '-rf', '--', $script:EvidenceDirectory) }
                @{ Kind = 'sudo'; Argument = @('rmdir', '--ignore-fail-on-non-empty', '--', (Get-DeepDiagnosticsParent -Path $script:EvidenceDirectory)) })
        } else {
            $notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_evidence_kept' -Arguments @{ path = "$script:EvidenceDirectory" }))
        }
    }
    if ($components['journald'] -and $components['journald'].Contains('journalDirectoryExisted') -and -not $components['journald']['journalDirectoryExisted'] -and (Test-DeepDiagnosticsPath -Path '/var/log/journal')) {
        $notes.Add((Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_journal_directory_created' -Arguments @{ path = '/var/log/journal' }))
    }
    return [pscustomobject]@{ State = $State; Items = $items; Notes = $notes }
}

function Write-DeepDiagnosticsRestorePlan {
    <#
    .SYNOPSIS
        Show what Disable will revert, as 'key: current -> restored', before
        anything changes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    if (-not $Plan.State) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_not_enabled' -Arguments @{ path = "$script:StatePath" })
    } else {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_restore_header' -Arguments @{ enabledAtUtc = (ConvertTo-DeepDiagnosticsUtcText $Plan.State['enabledAtUtc']); enabledBy = "$($Plan.State['enabledBy'])" })
    }
    foreach ($item in $Plan.Items) { Write-Information (Format-DeepDiagnosticsChange -Change $item.Change) }
    foreach ($note in $Plan.Notes) { Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_plan_note' -Arguments @{ note = "$note" }) }
}

function Invoke-DeepDiagnosticsDisable {
    <#
    .SYNOPSIS
        Revert what the state file records, then remove the state file and the
        directories Enable created. A failed step keeps the state file, so a
        second run finishes the restore.
    .OUTPUTS
        @{ ExitCode; Failed }: 0 restored, 1 nothing could be done, 2 partly restored.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Plan)
    if (-not $Plan.State -and $Plan.Items.Count -eq 0) { return [pscustomobject]@{ ExitCode = 0; Failed = 0 } }
    if (-not $PSCmdlet.ShouldProcess($script:StatePath, (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_should_restore'))) {
        return [pscustomobject]@{ ExitCode = 0; Failed = 0 }
    }
    if ((Invoke-DeepDiagnosticsSudo -Argument @('true')).ExitCode -ne 0) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_sudo_unavailable') -ErrorAction Continue
        return [pscustomobject]@{ ExitCode = 1; Failed = 0 }
    }
    $failed = 0
    foreach ($item in $Plan.Items) {
        try {
            foreach ($step in $item.Steps) { Invoke-DeepDiagnosticsStep -Step $step -Component $null }
            Write-Information (Format-DeepDiagnosticsChange -Change $item.Change)
        } catch {
            $failed++
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_restore_failed' -Arguments @{ item = "$($item.Change.Key)"; message = "$($_.Exception.Message)" })
        }
    }
    if ($failed -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_restore_incomplete' -Arguments @{ count = "$failed"; path = "$script:StatePath" })
        return [pscustomobject]@{ ExitCode = 2; Failed = $failed }
    }
    if ($Plan.State) {
        $r = Invoke-DeepDiagnosticsSudo -Argument @('rm', '-f', '--', $script:StatePath)
        if ($r.ExitCode -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_restore_failed' -Arguments @{ item = "$script:StatePath"; message = "$($r.Output)" })
            return [pscustomobject]@{ ExitCode = 2; Failed = 1 }
        }
        # Only the directories Enable created, and only once nothing is left
        # in them: evidence that is kept keeps its directory.
        foreach ($dir in @($Plan.State['createdDirectories'])) {
            if ($dir -and (Test-DeepDiagnosticsPath -Path "$dir")) { [void](Invoke-DeepDiagnosticsSudo -Argument @('rmdir', '--ignore-fail-on-non-empty', '--', "$dir")) }
        }
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.deep_diagnostics_restore_done' -Arguments @{ count = "$($Plan.Items.Count)" })
    return [pscustomobject]@{ ExitCode = 0; Failed = 0 }
}

Export-ModuleMember -Function Get-DeepDiagnosticsRefusal, Get-DeepDiagnosticsPlan, Write-DeepDiagnosticsPlan, Invoke-DeepDiagnosticsEnable,
Read-DeepDiagnosticsState, Get-DeepDiagnosticsRestorePlan, Write-DeepDiagnosticsRestorePlan, Invoke-DeepDiagnosticsDisable, ConvertTo-DeepDiagnosticsTarget
