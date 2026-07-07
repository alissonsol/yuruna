<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42f0a1b2-c3d4-4e56-9788-9a0b1c2d3e4f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool host identity fingerprint reclaim reimage
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

# Host identity for the pool: a reimageable host loses its local runtime/ (and
# with it host.uuid), so without a way to re-recognize the same physical box its
# pool history would fork under a fresh uuid every reinstall. After each
# poolStorage drain a host publishes <networkPath>/hosts/info.<uuid>.yml carrying
# its uuid + a hardware fingerprint. On the next Enable-TestAutomation a host with
# NO local uuid scans those records and, when a fingerprint matches strongly
# enough, offers to RECLAIM the prior uuid (operator confirms -- never silent).
#
# The strong fingerprint keys (SMBIOS product UUID, baseboard serial) are
# root-only on Linux, which the unprivileged per-cycle drain cannot read. So the
# fingerprint is gathered ONCE, PRIVILEGED, at Enable-TestAutomation (sudo is
# primed there) and cached to runtime/host.hwid.json; the drain reads the cache.

# ---------------------------------------------------------------------------
# Pure normalization helpers (no I/O) -- the testable core.
# ---------------------------------------------------------------------------

# Junk SMBIOS/serial values that firmware ships as placeholders. Treated as
# "absent" so two unrelated boards that both report "Default string" never look
# like a match. Compared lowercased after trimming.
$script:HostIdJunkValues = @(
    '', '0',
    '00000000-0000-0000-0000-000000000000',
    'ffffffff-ffff-ffff-ffff-ffffffffffff',
    'to be filled by o.e.m.', 'to be filled by o.e.m',
    'default string', 'none', 'not specified', 'not available',
    'n/a', 'na', 'unknown', 'system serial number', 'system uuid',
    'not applicable', 'o.e.m.', 'oem'
)

<#
.SYNOPSIS
Returns $false for empty/placeholder firmware values so a junk key never contributes to a match score.
#>
function Test-HostFingerprintValueUsable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return -not ($script:HostIdJunkValues -contains $Value.Trim().ToLowerInvariant())
}

<#
.SYNOPSIS
Lowercases and trims a scalar firmware value and collapses any junk placeholder to '' so equality compares are meaningful.
#>
function ConvertTo-NormalizedFingerprintValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][string]$Value)
    if (-not (Test-HostFingerprintValueUsable -Value $Value)) { return '' }
    return $Value.Trim().ToLowerInvariant()
}

<#
.SYNOPSIS
Normalizes a set of MAC strings to lowercased colon-free hex, drops blanks/all-zero, de-dups, and sorts so the same NICs in any order/format compare equal.
#>
function ConvertTo-NormalizedMacList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()][string[]]$Mac)
    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($m in @($Mac)) {
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        $bare = ($m -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
        if ($bare.Length -ne 12) { continue }            # not a 48-bit MAC
        if ($bare -eq '000000000000') { continue }       # null MAC
        [void]$set.Add($bare)
    }
    # Two-step so a populated set is a real string[]. The empty case unwraps to
    # $null on return (PowerShell collapses a zero-length array); every caller
    # wraps the result in @() or reads .Count, both of which are $null-safe, so
    # the empty result is normalized back to an empty array at the call site.
    $out = [string[]]@()
    if ($set.Count -gt 0) { $out = [string[]]@($set) }
    return $out
}

# Match-field weights. SMBIOS UUID + baseboard serial are the strong, near-unique
# keys; a MAC overlap is medium (NICs can be swapped/cloned); cpu/ram/platform
# only corroborate. Tuned so a strong key alone clears the suggest threshold and
# corroboration alone needs several agreeing weak fields.
$script:HostIdWeights = [ordered]@{
    smbiosUuid      = 50
    baseboardSerial = 30
    macAddresses    = 20
    cpuModel        = 4
    cpuCount        = 2
    ramBytes        = 3
    platform        = 2
    hostType        = 2
}
# Auto-suggest reclaim at or above this score; below it the match is too weak to
# put in front of the operator as "probably this host".
$script:HostIdSuggestThreshold = 25

<#
.SYNOPSIS
Compares two fingerprints and returns @{ score; matchedFields; strong }; pure and deterministic, with `strong` true when a near-unique key (smbiosUuid or baseboardSerial) matched.
#>
function Get-HostIdentityMatchScore {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Mine,
        [Parameter(Mandatory)][hashtable]$Candidate
    )
    $score = 0
    $matched = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @('smbiosUuid', 'baseboardSerial', 'cpuModel', 'platform', 'hostType')) {
        $a = ConvertTo-NormalizedFingerprintValue -Value ([string]$Mine[$key])
        $b = ConvertTo-NormalizedFingerprintValue -Value ([string]$Candidate[$key])
        if ($a -and $b -and $a -eq $b) { $score += $script:HostIdWeights[$key]; $matched.Add($key) }
    }
    # Numeric corroboration: only count when BOTH sides report a positive value.
    foreach ($key in @('cpuCount', 'ramBytes')) {
        $a = 0L; $b = 0L
        [void][int64]::TryParse([string]$Mine[$key], [ref]$a)
        [void][int64]::TryParse([string]$Candidate[$key], [ref]$b)
        if ($a -gt 0 -and $a -eq $b) { $score += $script:HostIdWeights[$key]; $matched.Add($key) }
    }
    # MAC overlap: any shared physical address scores the medium weight.
    $mineMac = ConvertTo-NormalizedMacList -Mac ([string[]]@($Mine['macAddresses']))
    $candMac = ConvertTo-NormalizedMacList -Mac ([string[]]@($Candidate['macAddresses']))
    if ($mineMac.Count -gt 0 -and $candMac.Count -gt 0) {
        $shared = @($mineMac | Where-Object { $candMac -contains $_ })
        if ($shared.Count -gt 0) { $score += $script:HostIdWeights['macAddresses']; $matched.Add('macAddresses') }
    }

    $strong = ($matched -contains 'smbiosUuid') -or ($matched -contains 'baseboardSerial')
    return @{ score = $score; matchedFields = [string[]]@($matched); strong = $strong }
}

<#
.SYNOPSIS
Turns a score-DESC-ranked candidate list into a single pure decision the orchestrator acts on.
.DESCRIPTION
Pure so the policy is unit-testable without disk or prompt. Returns one of:
  none      : no candidate clears the suggest threshold.
  suggest   : exactly one clear front-runner -> offer it.
  ambiguous : two or more strong candidates, or a near-tie at the top -> list them and default to a NEW uuid (operator can still pick one).
Ranked must be sorted by score DESC.
#>
function Get-HostIdentityReclaimDecision {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()][object[]]$Ranked)
    $list = @($Ranked | Where-Object { $_ })
    if ($list.Count -eq 0) { return @{ action = 'none'; candidate = $null; candidates = @() } }
    $top = $list[0]
    if ([int]$top.score -lt $script:HostIdSuggestThreshold) {
        return @{ action = 'none'; candidate = $null; candidates = @() }
    }
    $aboveThreshold = @($list | Where-Object { [int]$_.score -ge $script:HostIdSuggestThreshold })
    $strongCount = @($aboveThreshold | Where-Object { $_.strong }).Count
    $nearTie = $false
    if ($aboveThreshold.Count -ge 2) {
        $nearTie = (([int]$aboveThreshold[0].score - [int]$aboveThreshold[1].score) -lt 15)
    }
    if ($strongCount -ge 2 -or $nearTie) {
        return @{ action = 'ambiguous'; candidate = $null; candidates = $aboveThreshold }
    }
    return @{ action = 'suggest'; candidate = $top; candidates = $aboveThreshold }
}

<#
.SYNOPSIS
Assembles the ordered object written to hosts/info.<uuid>.yml; pure so the YAML round-trip is testable.
#>
function New-HostInfoRecordObject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure value constructor; assembles an in-memory object and mutates no state.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$HostId,
        [Parameter(Mandatory)][hashtable]$Fingerprint,
        [Parameter(Mandatory)][string]$LastSeenUtc
    )
    $fp = $Fingerprint
    return [ordered]@{
        hostUuid    = $HostId
        hostname    = [string]$fp['hostname']
        hostType    = [string]$fp['hostType']
        platform    = [string]$fp['platform']
        lastSeenUtc = $LastSeenUtc
        hardware    = [ordered]@{
            smbiosUuid      = [string]$fp['smbiosUuid']
            baseboardSerial = [string]$fp['baseboardSerial']
            cpuModel        = [string]$fp['cpuModel']
            cpuCount        = [int]$fp['cpuCount']
            ramBytes        = [int64]$fp['ramBytes']
            macAddresses    = [string[]]@(ConvertTo-NormalizedMacList -Mac ([string[]]@($fp['macAddresses'])))
        }
    }
}

<#
.SYNOPSIS
Lifts a parsed info.<uuid>.yml mapping back into the flat fingerprint hashtable Get-HostIdentityMatchScore expects, tolerating a missing 'hardware' subtree; pure.
#>
function ConvertFrom-HostInfoRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $hw = if ($Record.Contains('hardware') -and ($Record['hardware'] -is [System.Collections.IDictionary])) { $Record['hardware'] } else { @{} }
    return @{
        smbiosUuid      = [string]$hw['smbiosUuid']
        baseboardSerial = [string]$hw['baseboardSerial']
        cpuModel        = [string]$hw['cpuModel']
        cpuCount        = [string]$hw['cpuCount']
        ramBytes        = [string]$hw['ramBytes']
        macAddresses    = [string[]]@($hw['macAddresses'])
        platform        = [string]$Record['platform']
        hostType        = [string]$Record['hostType']
        hostname        = [string]$Record['hostname']
    }
}

# ---------------------------------------------------------------------------
# OS-touching fingerprint gather (best-effort; never throws).
# ---------------------------------------------------------------------------

# Get-HostIdentityRuntimeDir resolves the runtime dir, preferring Test.YurunaDir's
# canonical resolver (which also creates it) and falling back to the env var.
# Returns '' when it genuinely cannot resolve, so callers can treat that as
# UNKNOWN rather than a confident "no runtime dir".
function Get-HostIdentityRuntimeDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue) {
        try {
            $d = [string](Initialize-YurunaRuntimeDir)
            if (-not [string]::IsNullOrWhiteSpace($d)) { return $d }
        } catch { Write-Verbose "Initialize-YurunaRuntimeDir failed: $($_.Exception.Message)" }
    }
    # Fall back to YURUNA_RUNTIME_DIR. An installer may have set it at User or
    # Machine scope without also updating this process's environment block, so a
    # plain $env: read is empty here even though the value exists. Resolve
    # process -> User -> Machine (the User/Machine stores exist only on Windows)
    # and refresh $env: so the value is visible to this process and any children.
    $val = [string]$env:YURUNA_RUNTIME_DIR
    if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
    if ($IsWindows) {
        foreach ($scope in @([System.EnvironmentVariableTarget]::User, [System.EnvironmentVariableTarget]::Machine)) {
            $scoped = ''
            try { $scoped = [string][System.Environment]::GetEnvironmentVariable('YURUNA_RUNTIME_DIR', $scope) } catch { $null = $_ }
            if (-not [string]::IsNullOrWhiteSpace($scoped)) {
                $env:YURUNA_RUNTIME_DIR = $scoped
                return $scoped
            }
        }
    }
    return ''
}

function Get-HostIdentityPlatform {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS)   { return 'macos' }
    if ($IsLinux)   { return 'linux' }
    return 'unknown'
}

function Get-HostIdentityHostType {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    switch (Get-HostIdentityPlatform) {
        'windows' { 'windows.hyper-v' }
        'macos'   { 'macos.utm' }
        'linux'   { 'ubuntu.kvm' }
        default   { 'unknown' }
    }
}

# Read a file with sudo only when allowed (Enable-TestAutomation has primed the
# cache); `-n` makes sudo fail fast rather than prompt when the cache is cold, so
# the drain's unprivileged path degrades to an empty value instead of hanging.
function Get-HostIdentityPrivilegedFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowSudo
    )
    if (Test-Path -LiteralPath $Path) {
        try {
            $direct = ([System.IO.File]::ReadAllText($Path)).Trim()
            if ($direct) { return $direct }
        } catch { Write-Verbose "direct read of $Path failed: $($_.Exception.Message)" }
    }
    if ($AllowSudo -and (Get-Command sudo -ErrorAction SilentlyContinue)) {
        try {
            $out = (& sudo -n cat $Path 2>$null)
            if ($LASTEXITCODE -eq 0 -and $out) { return ([string]($out | Select-Object -First 1)).Trim() }
        } catch { Write-Verbose "sudo read of $Path failed: $($_.Exception.Message)" }
    }
    return ''
}

function Get-HostFingerprintWindows {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $fp = @{ smbiosUuid = ''; baseboardSerial = ''; cpuModel = ''; cpuCount = 0; ramBytes = 0L; macAddresses = [string[]]@() }
    try { $fp.smbiosUuid      = [string](Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID } catch { $null = $_ }
    try { $fp.baseboardSerial = [string](Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop).SerialNumber } catch { $null = $_ }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $fp.cpuCount = [int]$cs.NumberOfLogicalProcessors
        $fp.ramBytes = [int64]$cs.TotalPhysicalMemory
    } catch { $null = $_ }
    try { $fp.cpuModel = [string](Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name } catch { $null = $_ }
    try {
        $macs = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop |
            Where-Object { $_.PhysicalAdapter -and $_.MACAddress } | ForEach-Object { [string]$_.MACAddress }
        $fp.macAddresses = [string[]]@($macs)
    } catch { $null = $_ }
    return $fp
}

# True only for a real physical Ethernet NIC. Software/virtual NICs -- libvirt
# virbr*, docker0, veth, bond, tap -- carry host-assigned MACs that are commonly
# randomized per boot/recreate; feeding them to the fingerprint inflates and
# destabilizes the cross-host match, so this drops them to mirror the Windows
# PhysicalAdapter intent.
function Test-LinuxPhysicalNic {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$InterfaceName,
        [Parameter(Mandatory)][string]$InterfacePath
    )
    # ARPHRD_ETHER == 1. Loopback (772), tunnels, and other non-Ethernet link
    # types report a different value and carry no stable burned-in Ethernet MAC.
    # A physical wireless NIC also reports type 1 and is intentionally kept -- its
    # permanent MAC (preferred via ethtool -P, which defeats per-connection MAC
    # randomization) is a valid box identifier.
    $typeFile = Join-Path $InterfacePath 'type'
    if (-not (Test-Path -LiteralPath $typeFile)) { return $false }
    $type = ''
    try { $type = ([System.IO.File]::ReadAllText($typeFile)).Trim() } catch { return $false }
    if ($type -ne '1') { return $false }
    # Virtual/software NICs are enumerated under /sys/devices/virtual/net (the
    # /sys/class/net/<if> symlink resolves there). virbr0/docker0/veth are ARPHRD
    # type 1 too, so this path check -- not the type -- is what excludes them.
    if (Test-Path -LiteralPath (Join-Path '/sys/devices/virtual/net' $InterfaceName)) { return $false }
    return $true
}

# Prefer a NIC's permanent (burned-in) MAC over its current address, so bonding,
# a MACVLAN, or a manual override does not change the fingerprint of the same
# physical box. ethtool may be absent or unprivileged; fall back to the current
# /sys .../address. Never throws.
function Get-LinuxNicPermanentMac {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$InterfaceName,
        [Parameter(Mandatory)][string]$InterfacePath
    )
    if (Get-Command ethtool -ErrorAction SilentlyContinue) {
        try {
            # -join to a single string before matching: some ethtool builds print
            # an extra notice line to stdout, and array `-match` would filter the
            # elements and leave $Matches unset. [regex]::Match avoids depending on
            # the $Matches automatic variable entirely.
            $out = (& ethtool -P $InterfaceName 2>$null) -join "`n"
            if ($LASTEXITCODE -eq 0) {
                $m = [regex]::Match($out, '([0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5})')
                if ($m.Success -and $m.Value -ne '00:00:00:00:00:00') { return $m.Value }
            }
        } catch { $null = $_ }
    }
    $addrFile = Join-Path $InterfacePath 'address'
    if (Test-Path -LiteralPath $addrFile) {
        try { return ([System.IO.File]::ReadAllText($addrFile)).Trim() } catch { $null = $_ }
    }
    return ''
}

function Get-HostFingerprintLinux {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$AllowSudo)
    $fp = @{ smbiosUuid = ''; baseboardSerial = ''; cpuModel = ''; cpuCount = 0; ramBytes = 0L; macAddresses = [string[]]@() }
    $fp.smbiosUuid      = Get-HostIdentityPrivilegedFile -Path '/sys/class/dmi/id/product_uuid' -AllowSudo:$AllowSudo
    $fp.baseboardSerial = Get-HostIdentityPrivilegedFile -Path '/sys/class/dmi/id/board_serial' -AllowSudo:$AllowSudo
    try {
        $cpuinfo = Get-Content -LiteralPath '/proc/cpuinfo' -ErrorAction Stop
        $model = ($cpuinfo | Where-Object { $_ -match '^model name\s*:' } | Select-Object -First 1)
        if ($model) { $fp.cpuModel = ($model -replace '^model name\s*:\s*', '').Trim() }
        $fp.cpuCount = @($cpuinfo | Where-Object { $_ -match '^processor\s*:' }).Count
    } catch { $null = $_ }
    try {
        $memLine = (Get-Content -LiteralPath '/proc/meminfo' -ErrorAction Stop | Where-Object { $_ -match '^MemTotal:' } | Select-Object -First 1)
        if ($memLine -match '(\d+)\s*kB') { $fp.ramBytes = [int64]$Matches[1] * 1024 }
    } catch { $null = $_ }
    try {
        $macs = foreach ($n in (Get-ChildItem -Path '/sys/class/net' -ErrorAction Stop)) {
            if ($n.Name -eq 'lo') { continue }
            if (-not (Test-LinuxPhysicalNic -InterfaceName $n.Name -InterfacePath $n.FullName)) { continue }
            $mac = Get-LinuxNicPermanentMac -InterfaceName $n.Name -InterfacePath $n.FullName
            if ($mac) { $mac }
        }
        $fp.macAddresses = [string[]]@($macs)
        if (@($fp.macAddresses).Count -eq 0) {
            Write-Verbose "Get-HostFingerprintLinux: no physical NIC MAC captured (all NICs virtual/non-Ethernet); the fingerprint relies on firmware/CPU keys."
        }
    } catch { $null = $_ }
    return $fp
}

# A macOS sysctl read, guarded so a failed or empty read cannot silently poison the
# fingerprint. Resolve-GuardedSysctlValue is the pure gate (testable without sysctl):
# it returns the trimmed value only when the read succeeded (exit 0) AND produced
# non-empty output, otherwise $null plus a Write-Verbose breadcrumb -- so a numeric
# caller keeps its default (0) rather than casting '' -> 0 into the fingerprint, and a
# chronically degraded fingerprint (which silently weakens reclaim) is observable under
# -Verbose. Get-SysctlValue is the thin OS-touching wrapper around it.
function Resolve-GuardedSysctlValue {
    [OutputType([string])]
    param([string]$Raw, [int]$ExitCode, [string]$Key)
    if ($ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($Raw)) { return $Raw.Trim() }
    Write-Verbose "Get-HostFingerprintMacOS: sysctl -n $Key unavailable (exit $ExitCode / empty output); the corroborating field stays at its default -- host fingerprint degraded, reclaim weakened."
    return $null
}
function Get-SysctlValue {
    [OutputType([string])]
    param([string]$Key)
    $raw = $null
    $ec = 1
    try { $raw = [string](& sysctl -n $Key 2>$null); $ec = $LASTEXITCODE } catch { $ec = 1 }
    return (Resolve-GuardedSysctlValue -Raw $raw -ExitCode $ec -Key $Key)
}

function Get-HostFingerprintMacOS {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $fp = @{ smbiosUuid = ''; baseboardSerial = ''; cpuModel = ''; cpuCount = 0; ramBytes = 0L; macAddresses = [string[]]@() }
    try {
        $ioreg = (& ioreg -rd1 -c IOPlatformExpertDevice 2>$null)
        $uuidLine = ($ioreg | Where-Object { $_ -match 'IOPlatformUUID' } | Select-Object -First 1)
        if ($uuidLine -match '"IOPlatformUUID"\s*=\s*"([^"]+)"') { $fp.smbiosUuid = $Matches[1] }
        $serLine = ($ioreg | Where-Object { $_ -match 'IOPlatformSerialNumber' } | Select-Object -First 1)
        if ($serLine -match '"IOPlatformSerialNumber"\s*=\s*"([^"]+)"') { $fp.baseboardSerial = $Matches[1] }
    } catch { $null = $_ }
    # Only a successful, non-empty sysctl read overwrites the field's default, so a
    # failed read leaves cpuModel=''/cpuCount=0/ramBytes=0 (no fingerprint change, no
    # re-key) while surfacing the degraded read in the verbose breadcrumb.
    $cpuModelVal = Get-SysctlValue -Key 'machdep.cpu.brand_string'
    if ($null -ne $cpuModelVal) { $fp.cpuModel = $cpuModelVal }
    $cpuCountVal = Get-SysctlValue -Key 'hw.logicalcpu'
    if ($null -ne $cpuCountVal) {
        try { $fp.cpuCount = [int]$cpuCountVal } catch { Write-Verbose "Get-HostFingerprintMacOS: hw.logicalcpu value '$cpuCountVal' is not an integer; cpuCount stays 0." }
    }
    $ramBytesVal = Get-SysctlValue -Key 'hw.memsize'
    if ($null -ne $ramBytesVal) {
        try { $fp.ramBytes = [int64]$ramBytesVal } catch { Write-Verbose "Get-HostFingerprintMacOS: hw.memsize value '$ramBytesVal' is not an int64; ramBytes stays 0." }
    }
    try {
        $macs = (& ifconfig 2>$null | Where-Object { $_ -match '^\s*ether\s' }) | ForEach-Object { ($_ -replace '^\s*ether\s+', '').Trim() }
        $fp.macAddresses = [string[]]@($macs)
    } catch { $null = $_ }
    return $fp
}

<#
.SYNOPSIS
Gathers the cross-platform hardware fingerprint and (unless -NoCache) writes it to runtime/host.hwid.json.
.DESCRIPTION
Pass -AllowSudo from the privileged path so the root-only Linux keys are captured; the unprivileged drain omits it and gets a degraded (but still useful) fingerprint. Never throws -- a field it cannot read stays empty.
#>
function Get-HostHardwareFingerprint {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch]$AllowSudo,
        [switch]$NoCache
    )
    $platform = Get-HostIdentityPlatform
    $fp = switch ($platform) {
        'windows' { Get-HostFingerprintWindows }
        'macos'   { Get-HostFingerprintMacOS }
        'linux'   { Get-HostFingerprintLinux -AllowSudo:$AllowSudo }
        default   { @{ smbiosUuid = ''; baseboardSerial = ''; cpuModel = ''; cpuCount = 0; ramBytes = 0L; macAddresses = [string[]]@() } }
    }
    # Normalize the strong keys + MACs at capture so the cache is already in the
    # comparable form Get-HostIdentityMatchScore consumes.
    $fp.smbiosUuid      = ConvertTo-NormalizedFingerprintValue -Value ([string]$fp.smbiosUuid)
    $fp.baseboardSerial = ConvertTo-NormalizedFingerprintValue -Value ([string]$fp.baseboardSerial)
    $fp.macAddresses    = [string[]]@(ConvertTo-NormalizedMacList -Mac ([string[]]@($fp.macAddresses)))
    $fp.cpuModel        = ([string]$fp.cpuModel).Trim()
    $fp.platform        = $platform
    $fp.hostType        = Get-HostIdentityHostType
    $fp.hostname        = [string][System.Net.Dns]::GetHostName()

    if (-not $NoCache) {
        $runtimeDir = Get-HostIdentityRuntimeDir
        if (-not [string]::IsNullOrWhiteSpace($runtimeDir)) {
            if (-not (Test-Path -LiteralPath $runtimeDir)) {
                try { New-Item -ItemType Directory -Force -Path $runtimeDir -ErrorAction Stop | Out-Null } catch { $null = $_ }
            }
            $cachePath = Join-Path $runtimeDir 'host.hwid.json'
            if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
                $null = Write-YurunaStateFileJson -Path $cachePath -InputObject $fp -Depth 6 -Confirm:$false
            } else {
                try { [System.IO.File]::WriteAllText($cachePath, ($fp | ConvertTo-Json -Depth 6 -Compress), [System.Text.UTF8Encoding]::new($false)) } catch { $null = $_ }
            }
        } else {
            Write-Verbose "Get-HostHardwareFingerprint: runtime dir unresolved; skipping host.hwid.json cache write."
        }
    }
    return $fp
}

<#
.SYNOPSIS
Reads the privileged-capture runtime/host.hwid.json, falling back to a best-effort unprivileged gather when the cache is absent.
.DESCRIPTION
The fallback does NOT write, so it can never overwrite the better privileged cache with a degraded one. Returns $null only if even the fallback gather is impossible.
#>
function Get-CachedHostHardwareFingerprint {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $runtimeDir = Get-HostIdentityRuntimeDir
    if (-not [string]::IsNullOrWhiteSpace($runtimeDir)) {
        $cachePath = Join-Path $runtimeDir 'host.hwid.json'
        if (Test-Path -LiteralPath $cachePath) {
            try {
                $raw = [System.IO.File]::ReadAllText($cachePath)
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                $fp = @{}
                foreach ($p in $obj.PSObject.Properties) { $fp[$p.Name] = $p.Value }
                if (-not $fp.ContainsKey('macAddresses') -or $null -eq $fp['macAddresses']) { $fp['macAddresses'] = [string[]]@() }
                $fp['macAddresses'] = [string[]]@($fp['macAddresses'])
                return $fp
            } catch { Write-Verbose "host.hwid.json read failed; regathering: $($_.Exception.Message)" }
        }
    }
    return (Get-HostHardwareFingerprint -NoCache)
}

# ---------------------------------------------------------------------------
# NAS-side host registry (hosts/info.<uuid>.yml).
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
Publishes <MountRoot>/hosts/info.<HostId>.yml (creating hosts/ if absent), atomically when Test.StateFile is available with a direct-write fallback.
.DESCRIPTION
Best-effort: returns the path on success, $null on any failure -- callers must never break on a registry write.
#>
function Write-HostInfoRecord {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$MountRoot,
        [Parameter(Mandatory)][string]$HostId,
        [Parameter(Mandatory)][hashtable]$Fingerprint,
        [string]$LastSeenUtc
    )
    if ([string]::IsNullOrWhiteSpace($MountRoot)) { return $null }
    $hostsDir = Join-Path $MountRoot 'hosts'
    $path = Join-Path $hostsDir ("info.$HostId.yml")
    if (-not $PSCmdlet.ShouldProcess($path, 'Write pool host-identity record')) { return $null }
    if (-not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        Write-Verbose "Write-HostInfoRecord: powershell-yaml not available; skipping."
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($LastSeenUtc)) {
        $LastSeenUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    try {
        if (-not (Test-Path -LiteralPath $hostsDir)) {
            New-Item -ItemType Directory -Force -Path $hostsDir -ErrorAction Stop | Out-Null
        }
        $record = New-HostInfoRecordObject -HostId $HostId -Fingerprint $Fingerprint -LastSeenUtc $LastSeenUtc
        $yaml = ConvertTo-Yaml $record
        $wrote = $false
        if (Get-Command Write-YurunaStateFile -ErrorAction SilentlyContinue) {
            $wrote = [bool](Write-YurunaStateFile -Path $path -Content $yaml -Confirm:$false)
        }
        if (-not $wrote) {
            [System.IO.File]::WriteAllText($path, $yaml, [System.Text.UTF8Encoding]::new($false))
        }
        return $path
    } catch {
        Write-Verbose "Write-HostInfoRecord failed for $path : $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
Reads every <MountRoot>/hosts/info.*.yml, scores each against the fingerprint, and returns the matches ranked by score DESC.
.DESCRIPTION
Records whose own hostUuid equals -ExcludeHostId are dropped (a host never matches its own record). Returns @() when the folder is absent or nothing scores > 0.
#>
function Find-PriorHostIdentity {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$MountRoot,
        [Parameter(Mandatory)][hashtable]$Fingerprint,
        [string]$ExcludeHostId
    )
    $hostsDir = Join-Path $MountRoot 'hosts'
    if (-not (Test-Path -LiteralPath $hostsDir)) { return @() }
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { return @() }
    $results = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -Path $hostsDir -Filter 'info.*.yml' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $record = $null
        try { $record = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction Stop | ConvertFrom-Yaml -Ordered -ErrorAction Stop } catch { Write-Verbose "skip $($f.Name): $($_.Exception.Message)"; continue }
        if (-not ($record -is [System.Collections.IDictionary])) { continue }
        $uuid = [string]$record['hostUuid']
        if ([string]::IsNullOrWhiteSpace($uuid)) { continue }
        if ($ExcludeHostId -and ($uuid -eq $ExcludeHostId)) { continue }
        $candFp = ConvertFrom-HostInfoRecord -Record $record
        $m = Get-HostIdentityMatchScore -Mine $Fingerprint -Candidate $candFp
        if ([int]$m.score -le 0) { continue }
        $results.Add([pscustomobject]@{
            uuid          = $uuid
            hostname      = [string]$record['hostname']
            lastSeenUtc   = [string]$record['lastSeenUtc']
            score         = [int]$m.score
            matchedFields = [string[]]@($m.matchedFields)
            strong        = [bool]$m.strong
        })
    }
    return @($results | Sort-Object -Property @{ Expression = 'score'; Descending = $true }, @{ Expression = 'lastSeenUtc'; Descending = $true })
}

# ---------------------------------------------------------------------------
# Enable-TestAutomation orchestrator (interactive).
# ---------------------------------------------------------------------------

# Test-HostIdentityInteractive returns $false when no operator can answer a
# prompt (redirected stdin / non-interactive host), so the orchestrator degrades
# to a clean no-op instead of blocking an unattended/CI Enable-TestAutomation.
function Test-HostIdentityInteractive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
    } catch { return $false }
    return $true
}

# Operator-facing console line. Writes straight to the host UI (not the cmdlet
# Write-Host, which the lint gate disallows, and not Write-Output, which would
# pollute the function's return value); only reached on the interactive path.
function Write-HostIdentityLine {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][string]$Message = '')
    $Host.UI.WriteLine($Message)
}

function Read-HostIdentityConfirm {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Prompt, [bool]$DefaultYes = $false)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
    return ($ans.Trim() -match '^(y|yes)$')
}

# Set-PoolStorageConfigValue round-trips test.config.yml (gitignored, per-host)
# and writes the four POOL keys under the networkStorage node (preserving the
# rest of the document, including any stash* keys). Returns $true on success.
function Set-PoolStorageConfigValue {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][bool]$Replicate,
        [Parameter(Mandatory)][string]$NetworkPath,
        [Parameter(Mandatory)][string]$NetworkUser,
        [Parameter(Mandatory)][string]$LocalPath
    )
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Write networkStorage (pool) config')) { return $false }
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) -or -not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        Write-Warning "networkStorage setup: powershell-yaml not available; cannot write $ConfigPath."
        return $false
    }
    try {
        $doc = $null
        if (Test-Path -LiteralPath $ConfigPath) {
            $doc = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Yaml -Ordered
        }
        if (-not ($doc -is [System.Collections.IDictionary])) { $doc = [ordered]@{} }
        if (-not ($doc['networkStorage'] -is [System.Collections.IDictionary])) { $doc['networkStorage'] = [ordered]@{} }
        # networkReplicate is a pool behavior -> write it under the `pool` node;
        # networkStorage carries only the path/credential keys.
        if (-not ($doc['pool'] -is [System.Collections.IDictionary])) { $doc['pool'] = [ordered]@{} }
        $doc['pool']['networkReplicate'] = $Replicate
        $ps = $doc['networkStorage']
        $ps['poolNetworkPath']  = $NetworkPath
        $ps['poolNetworkUser']  = $NetworkUser
        $ps['poolLocalPath']    = $LocalPath
        $yaml = ConvertTo-Yaml $doc
        $wrote = $false
        if (Get-Command Write-YurunaStateFile -ErrorAction SilentlyContinue) {
            $wrote = [bool](Write-YurunaStateFile -Path $ConfigPath -Content $yaml -Confirm:$false)
        }
        if (-not $wrote) { [System.IO.File]::WriteAllText($ConfigPath, $yaml, [System.Text.UTF8Encoding]::new($false)) }
        if (Get-Command Clear-TestConfigCache -ErrorAction SilentlyContinue) { Clear-TestConfigCache }
        return $true
    } catch {
        Write-Warning "networkStorage setup: could not write $ConfigPath ($($_.Exception.Message))."
        return $false
    }
}

# Resolve the vault key Get-Password/Test-PoolStorageVaultReady look the password
# up under for a logical user (users.yml vaultKey indirection, else the user name
# itself), so Set-Password lands the secret where the mount path will read it.
function Get-HostIdentityVaultKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$User)
    $vaultKey = ''
    if (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) {
        try { $vaultKey = [string](Get-EffectiveUser -LogicalUser $User).vaultKey } catch { Write-Verbose "Get-EffectiveUser failed: $($_.Exception.Message)" }
    }
    if ([string]::IsNullOrWhiteSpace($vaultKey)) { return $User }
    return $vaultKey
}

# Initialize-HostIdentityDependency loads the sibling modules the orchestrator
# needs (config read/write, the SMB mount, the vault, the runtime dir, atomic
# writes) from this module's own folder, plus the active authentication
# extension. Imports only what is NOT already loaded and uses -Global without
# -Force, so it neither evicts a globally-imported module nor resets a loaded
# module's $script: state -- both of which a blanket `-Force` re-import would do.
function Initialize-HostIdentityDependency {
    [CmdletBinding()]
    param()
    foreach ($m in @('Test.Config.psm1', 'Test.PoolStorage.psm1', 'Test.YurunaDir.psm1', 'Test.StateFile.psm1', 'Test.Extension.psm1')) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($m)
        if (-not (Get-Module -Name $name)) {
            $p = Join-Path $PSScriptRoot $m
            if (Test-Path -LiteralPath $p) { Import-Module $p -Global -ErrorAction SilentlyContinue }
        }
    }
    if (-not (Get-Command Set-Password -ErrorAction SilentlyContinue) -and (Get-Command Import-Extension -ErrorAction SilentlyContinue)) {
        try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
Interactive setup step that offers to configure poolStorage (config + vault, replication, mount) and, on a host with no local uuid, reclaim a prior identity from the NAS host registry.
.DESCRIPTION
Lets a reimaged box keep its pool history. Degrades to a warned no-op when run non-interactively. Never throws.
#>
function Invoke-PoolStorageSetupAndReclaim {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The SMB password is collected as a SecureString; the brief plaintext is only handed to the vault Set-Password, which stores plaintext by design.')]
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not (Test-HostIdentityInteractive)) {
        Write-Warning "poolStorage setup skipped (no interactive console). Run Enable-TestAutomation in a terminal to configure NAS replication + reclaim this host's pool identity."
        return
    }
    Initialize-HostIdentityDependency

    $runtimeDir = Get-HostIdentityRuntimeDir
    $runtimeResolved = -not [string]::IsNullOrWhiteSpace($runtimeDir)
    $uuidFile = if ($runtimeResolved) { Join-Path $runtimeDir 'host.uuid' } else { '' }
    # When the runtime dir is unresolved, uuid-presence is UNKNOWN (not 'absent'):
    # an empty path can neither confirm an existing host.uuid nor be written to,
    # so the reclaim/mint flow below is skipped rather than forking pool history
    # under a fresh id and attempting a write to an empty path.
    $uuidExists = $runtimeResolved -and (Test-Path -LiteralPath $uuidFile)
    $cfgPath = Join-Path $RepoRoot 'test/test.config.yml'

    # Current values (defaults for the prompts), read raw so a stale config cache
    # never hides an edit the operator just made by hand.
    $curPath = ''; $curUser = ''; $curLocal = ''
    if ((Test-Path -LiteralPath $cfgPath) -and (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        try {
            $cur = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Yaml -Ordered
            if ($cur -is [System.Collections.IDictionary] -and $cur['networkStorage'] -is [System.Collections.IDictionary]) {
                $curPath  = [string]$cur['networkStorage']['poolNetworkPath']
                $curUser  = [string]$cur['networkStorage']['poolNetworkUser']
                $curLocal = [string]$cur['networkStorage']['poolLocalPath']
            }
        } catch { $null = $_ }
    }

    Write-HostIdentityLine ''
    Write-HostIdentityLine 'networkStorage pool (optional NAS replication + pool host-identity):'
    if (-not $runtimeResolved) {
        Write-HostIdentityLine "  NOTE: the runtime directory could not be resolved here, so this host's pool identity cannot be determined. You may still configure NAS replication; reclaim/mint is skipped until the runtime dir is available."
    } elseif ($uuidExists) {
        Write-HostIdentityLine "  This host already has a pool identity (runtime/host.uuid). Reclaim is not needed; you may still (re)configure NAS replication."
    } else {
        Write-HostIdentityLine "  This host has NO pool identity yet. Configuring poolStorage now lets it scan the NAS for a prior identity and RECLAIM its uuid (e.g. after a reimage)."
    }
    if (-not (Read-HostIdentityConfirm -Prompt 'Configure poolStorage now?' -DefaultYes:$false)) {
        if ($runtimeResolved -and -not $uuidExists) {
            Write-Warning "Skipped. A NEW host.uuid will be minted on the first cycle; reconnecting this host's pool history later (after a reimage) is harder once a fresh uuid is in use."
        }
        return
    }

    $networkPath = Read-Host "  networkPath (SMB share, e.g. //server.local/work)$(if ($curPath){" [$curPath]"})"
    if ([string]::IsNullOrWhiteSpace($networkPath)) { $networkPath = $curPath }
    $networkUser = Read-Host "  networkUser (storage-only NAS account)$(if ($curUser){" [$curUser]"})"
    if ([string]::IsNullOrWhiteSpace($networkUser)) { $networkUser = $curUser }
    $localPath = Read-Host "  localPath (local mount point, e.g. /mnt/ypool-nas or 'y:')$(if ($curLocal){" [$curLocal]"})"
    if ([string]::IsNullOrWhiteSpace($localPath)) { $localPath = $curLocal }

    if ([string]::IsNullOrWhiteSpace($networkPath) -or [string]::IsNullOrWhiteSpace($networkUser) -or [string]::IsNullOrWhiteSpace($localPath)) {
        Write-Warning "poolStorage setup: networkPath, networkUser, and localPath are all required. Nothing written."
        return
    }
    if (($networkPath -match "'") -or ($networkUser -match "'")) {
        Write-Warning "poolStorage setup: networkPath/networkUser must not contain a single quote (it would break the guest seed). Nothing written."
        return
    }

    $secure = Read-Host "  SMB password for '$networkUser'" -AsSecureString
    $plain = ''
    try { $plain = [System.Net.NetworkCredential]::new('', $secure).Password } catch { $plain = '' }
    if ([string]::IsNullOrEmpty($plain)) {
        Write-Warning "poolStorage setup: empty password; nothing written (an empty SMB credential is rejected by the NAS)."
        return
    }

    # Seed test.config.yml from the template when the operator has not created it
    # yet, so we EXTEND a complete config rather than writing a poolStorage-only
    # file that drops every other setting.
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        $tmpl = Join-Path $RepoRoot 'test/test.config.yml.template'
        if (Test-Path -LiteralPath $tmpl) {
            try { Copy-Item -LiteralPath $tmpl -Destination $cfgPath -Force; Write-HostIdentityLine "  Created test.config.yml from the template." }
            catch { Write-Warning "poolStorage setup: could not create test.config.yml from the template ($($_.Exception.Message))." }
        }
    }

    if (-not (Set-PoolStorageConfigValue -ConfigPath $cfgPath -Replicate $true -NetworkPath $networkPath -NetworkUser $networkUser -LocalPath $localPath -Confirm:$false)) {
        return
    }
    Write-HostIdentityLine "  Wrote poolStorage config (replicate: true) to $cfgPath"

    if (Get-Command Set-Password -ErrorAction SilentlyContinue) {
        $vaultKey = Get-HostIdentityVaultKey -User $networkUser
        try { Set-Password -Username $vaultKey -NewPassword $plain; Write-HostIdentityLine "  Stored the SMB credential in the vault under '$vaultKey'." }
        catch { Write-Warning "poolStorage setup: Set-Password failed ($($_.Exception.Message)). Set it manually before enabling replication." }
    } else {
        Write-Warning "poolStorage setup: authentication extension not loaded; could not store the SMB password. Set it manually."
    }

    # Mount now so reclaim can read the NAS host registry, and so the operator
    # sees a real connection result instead of discovering a bad credential on
    # the first cycle.
    $cfg = $null
    if (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue) {
        try { $cfg = Get-YurunaPoolStorageConfig -Config (Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Yaml -Ordered) -IgnoreReplicate } catch { Write-Verbose "config reload: $($_.Exception.Message)" }
    }
    if (-not $cfg) { Write-Warning "poolStorage setup: could not reload the new config; skipping mount + reclaim."; return }

    $mounted = $false
    if (Get-Command Connect-YurunaPoolStorage -ErrorAction SilentlyContinue) {
        try { $mounted = [bool](Connect-YurunaPoolStorage -Config $cfg -Confirm:$false) } catch { Write-Verbose "mount: $($_.Exception.Message)" }
    }
    if ($mounted) { Write-HostIdentityLine "  Mounted $($cfg.NetworkPath) at $($cfg.LocalPath)." }
    else {
        Write-Warning "poolStorage setup: could not mount $($cfg.NetworkPath) at $($cfg.LocalPath). Config + vault are saved; fix the share/credential and re-run. Skipping reclaim."
        return
    }

    # poolStorage is now configured + mounted here, so this is a pool-services candidate.
    # Surface whether the pool-alert notification transport still needs setup, so the
    # operator on the caching-proxy + dashboards host doesn't silently skip pool alerting.
    # Best-effort + bounded; never blocks setup.
    try {
        if (-not (Get-Command Write-PoolNotifierSetupNotice -ErrorAction SilentlyContinue)) {
            $pnMod = Join-Path $PSScriptRoot 'Test.PoolNotifier.psm1'
            if (Test-Path -LiteralPath $pnMod) { Import-Module $pnMod -ErrorAction SilentlyContinue }
        }
        if (Get-Command Write-PoolNotifierSetupNotice -ErrorAction SilentlyContinue) {
            $null = Write-PoolNotifierSetupNotice -ConfigPath $cfgPath
        }
    } catch { $null = $_ }

    # Always (re)capture the privileged fingerprint while sudo is primed, so the
    # unprivileged per-cycle drain can publish the strong keys from the cache.
    $fp = Get-HostHardwareFingerprint -AllowSudo
    Write-HostIdentityLine "  Captured hardware fingerprint (smbiosUuid$(if($fp.smbiosUuid){' present'}else{' absent'}), $($fp.macAddresses.Count) MAC(s))."

    if (-not $runtimeResolved) {
        Write-Warning "poolStorage setup: the runtime directory is unresolved (YURUNA_RUNTIME_DIR not visible in-process and Test.YurunaDir unavailable), so this host's uuid can neither be read nor written. Skipping reclaim/mint to avoid forking pool history under a fresh id. Set YURUNA_RUNTIME_DIR (or make Test.YurunaDir importable) and re-run to reclaim this host's identity."
        return
    }

    if ($uuidExists) {
        $myUuid = ''
        try { $myUuid = ([System.IO.File]::ReadAllText($uuidFile)).Trim() } catch { $null = $_ }
        Write-HostIdentityLine "  This host keeps its existing pool identity: $myUuid"
        return
    }

    # No local uuid: offer to reclaim a prior identity from the NAS registry.
    $ranked = @()
    if (Get-Command Find-PriorHostIdentity -ErrorAction SilentlyContinue) {
        try { $ranked = @(Find-PriorHostIdentity -MountRoot $cfg.LocalPath -Fingerprint $fp) } catch { Write-Verbose "registry scan: $($_.Exception.Message)" }
    }
    $decision = Get-HostIdentityReclaimDecision -Ranked $ranked

    switch ($decision.action) {
        'none' {
            Write-HostIdentityLine "  No prior host identity matched this hardware. A new host.uuid will be minted on the first cycle."
        }
        'ambiguous' {
            Write-HostIdentityLine "  Multiple prior identities match this hardware -- not reclaiming automatically:"
            foreach ($c in $decision.candidates) {
                Write-HostIdentityLine ("    - {0}  (host '{1}', last seen {2}, score {3}, matched: {4})" -f $c.uuid, $c.hostname, $c.lastSeenUtc, $c.score, ($c.matchedFields -join ','))
            }
            if (Read-HostIdentityConfirm -Prompt '  Reclaim one of these by typing its uuid? (No = mint a new uuid)' -DefaultYes:$false) {
                $picked = (Read-Host '  uuid to reclaim').Trim()
                $match = $decision.candidates | Where-Object { $_.uuid -eq $picked } | Select-Object -First 1
                if ($match) { Set-ReclaimedHostUuid -UuidFile $uuidFile -Uuid $picked }
                else { Write-Warning "  '$picked' is not one of the listed candidates; minting a new uuid instead." }
            } else {
                Write-HostIdentityLine "  A new host.uuid will be minted on the first cycle."
            }
        }
        'suggest' {
            $c = $decision.candidate
            Write-HostIdentityLine ("  A prior host identity matches this hardware:")
            Write-HostIdentityLine ("    uuid {0}  (host '{1}', last seen {2}, score {3}, matched: {4})" -f $c.uuid, $c.hostname, $c.lastSeenUtc, $c.score, ($c.matchedFields -join ','))
            if (Read-HostIdentityConfirm -Prompt '  Reclaim this identity for this host?' -DefaultYes:$false) {
                Set-ReclaimedHostUuid -UuidFile $uuidFile -Uuid $c.uuid
            } else {
                Write-HostIdentityLine "  Not reclaimed. A new host.uuid will be minted on the first cycle."
            }
        }
    }
}

<#
.SYNOPSIS
Writes the chosen uuid to runtime/host.uuid so the next Get-YurunaHostId adopts it, validating the 42-prefixed 32-hex shape so a typo can't poison the pool join key.
#>
function Set-ReclaimedHostUuid {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Syncs $global:__YurunaHostId -- the single cache slot the harness reads the host id from -- so an already-cached id is consistent with the reclaimed runtime/host.uuid.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$UuidFile,
        [Parameter(Mandatory)][string]$Uuid
    )
    $u = $Uuid.Trim()
    if ($u -notmatch '^42[0-9a-fA-F]{30}$') {
        Write-Warning "  '$u' is not a valid host uuid (expected '42' + 30 hex). Not reclaiming."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($UuidFile, "Reclaim host uuid $u")) { return $false }
    try {
        $dir = Split-Path -Parent $UuidFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($UuidFile, $u, [System.Text.UTF8Encoding]::new($false))
        if ($global:__YurunaHostId) { $global:__YurunaHostId = $u }
        Write-HostIdentityLine "  Reclaimed pool identity: $u (written to runtime/host.uuid)."
        return $true
    } catch {
        Write-Warning "  Could not write runtime/host.uuid ($($_.Exception.Message)). Not reclaimed."
        return $false
    }
}

Export-ModuleMember -Function `
    Test-HostFingerprintValueUsable, ConvertTo-NormalizedFingerprintValue, ConvertTo-NormalizedMacList, `
    Get-HostIdentityMatchScore, Get-HostIdentityReclaimDecision, New-HostInfoRecordObject, ConvertFrom-HostInfoRecord, `
    Get-HostHardwareFingerprint, Get-CachedHostHardwareFingerprint, `
    Write-HostInfoRecord, Find-PriorHostIdentity, `
    Invoke-PoolStorageSetupAndReclaim, Set-ReclaimedHostUuid
