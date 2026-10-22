<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42fd8317-806e-4cf5-9c09-8c822a472e35
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host memory prometheus metrics
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
    Native Linux and macOS memory gauges for the host status service.
.DESCRIPTION
    The status listener already runs on each host and supplies the scrape
    endpoint without another package, service or firewall port. Linux reports
    MemAvailable and its separate commitment accounting. macOS estimates
    available memory as free plus inactive pages; it has no equivalent commit
    limit. Unreadable or incomplete samples never become zero-byte readings.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking

function ConvertFrom-YurunaLinuxMemoryInfo {
    <# .SYNOPSIS
        Parse Linux /proc/meminfo, whose kB values are multiples of 1024 bytes.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Text)
    $names = [ordered]@{
        MemTotal = 'total_bytes'; MemFree = 'free_bytes'; MemAvailable = 'available_bytes'
        SwapTotal = 'swap_total_bytes'; SwapFree = 'swap_free_bytes'
        CommitLimit = 'commit_limit_bytes'; Committed_AS = 'committed_bytes'
    }
    $readings = @{}
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^([A-Za-z_]+):\s+(\d+)\s+kB\s*$' -and $names.Contains($Matches[1])) {
            $readings[$Matches[1]] = [long]([decimal]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture) * 1024)
        }
    }
    foreach ($name in @('MemTotal', 'MemFree', 'MemAvailable', 'SwapTotal', 'SwapFree')) {
        if (-not $readings.ContainsKey($name)) { throw "memory-source-missing:$name" }
    }
    if ($readings.MemTotal -le 0 -or $readings.MemAvailable -gt $readings.MemTotal -or
        $readings.MemFree -gt $readings.MemTotal -or $readings.SwapFree -gt $readings.SwapTotal) {
        throw 'memory-source-inconsistent'
    }
    $sample = [ordered]@{}
    foreach ($name in $names.Keys) {
        # Commitment is a pair: absence of one must not look like zero charge.
        if ($name -in @('CommitLimit', 'Committed_AS') -and
            (-not $readings.ContainsKey('CommitLimit') -or -not $readings.ContainsKey('Committed_AS'))) { continue }
        $sample[$names[$name]] = $readings[$name]
    }
    return $sample
}

function ConvertFrom-YurunaMacMemoryInfo {
    <# .SYNOPSIS
        Parse one vm_stat plus sysctl snapshot, retaining the machine's page size.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Text)
    $patterns = @{
        page = '(?m)^Mach Virtual Memory Statistics:\s*\(page size of (\d+) bytes\)'
        free = '(?m)^Pages free:\s+(\d+)\.?\s*$'
        inactive = '(?m)^Pages inactive:\s+(\d+)\.?\s*$'
        total = '(?m)^hw\.memsize:\s+(\d+)\s*$'
    }
    $readings = @{}
    foreach ($name in $patterns.Keys) {
        if ($Text -notmatch $patterns[$name]) { throw "memory-source-missing:$name" }
        $readings[$name] = [decimal]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Text -notmatch '(?m)^vm\.swapusage:\s+total = (\d+(?:\.\d+)?)M\s+used = \d+(?:\.\d+)?M\s+free = (\d+(?:\.\d+)?)M(?:\s|$)') {
        throw 'memory-source-missing:swap'
    }
    $sample = [ordered]@{
        total_bytes = [long]$readings.total
        free_bytes = [long]($readings.free * $readings.page)
        # Inactive pages may be reclaimed. Purgeable/speculative counters can
        # overlap other page categories, so adding them inflates availability.
        available_bytes = [long](($readings.free + $readings.inactive) * $readings.page)
        swap_total_bytes = [long]([decimal]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * 1048576)
        swap_free_bytes = [long]([decimal]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture) * 1048576)
    }
    if ($readings.page -le 0 -or $sample.total_bytes -le 0 -or $sample.available_bytes -gt $sample.total_bytes -or
        $sample.swap_free_bytes -gt $sample.swap_total_bytes) { throw 'memory-source-inconsistent' }
    return $sample
}

function Get-YurunaHostMemorySample {
    <# .SYNOPSIS
        Read native counters without allowing a stalled tool to park the listener.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Platform)
    if ($Platform -eq 'Linux') {
        return ConvertFrom-YurunaLinuxMemoryInfo -Text ([IO.File]::ReadAllText('/proc/meminfo'))
    }
    if ($Platform -eq 'macOS') {
        # Both fixed, read-only commands share one cap, including output drain
        # and cleanup. No request text is accepted by the shell.
        $result = Invoke-BoundedNativeCommand -FilePath '/bin/sh' -ArgumentList @('-c', '/usr/bin/vm_stat && /usr/sbin/sysctl hw.memsize vm.swapusage') `
            -TimeoutSeconds 1 -MaxCapturedChars 8192 -Environment @{ LC_ALL = 'C' }
        if (-not (Test-BoundedNativeResultComplete -Result $result) -or $result.ExitCode -ne 0) {
            throw 'memory-source-incomplete'
        }
        return ConvertFrom-YurunaMacMemoryInfo -Text $result.StdOut
    }
    throw 'memory-source-unsupported'
}

function Get-YurunaHostMemoryMetricPayload {
    <# .SYNOPSIS
        Return Prometheus exposition and whether the complete memory read succeeded.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateSet('Linux', 'macOS', 'Windows')][string]$Platform = $(if ($IsLinux) { 'Linux' } elseif ($IsMacOS) { 'macOS' } else { 'Windows' }))
    $health = "# HELP yuruna_host_memory_collection_success Whether the native memory read succeeded.`n# TYPE yuruna_host_memory_collection_success gauge`n"
    try {
        $sample = Get-YurunaHostMemorySample -Platform $Platform
        $body = [Text.StringBuilder]::new()
        foreach ($name in $sample.Keys) {
            $metric = "yuruna_host_memory_$name"
            $null = $body.Append("# TYPE $metric gauge`n$metric ")
            $null = $body.Append(([long]$sample[$name]).ToString([Globalization.CultureInfo]::InvariantCulture)).Append("`n")
        }
        $null = $body.Append($health).Append("yuruna_host_memory_collection_success 1`n")
        return [pscustomobject]@{ Success = $true; Body = $body.ToString() }
    } catch {
        Write-Verbose "native memory metrics: $($_.Exception.Message)"
        return [pscustomobject]@{ Success = $false; Body = $health + "yuruna_host_memory_collection_success 0`n" }
    }
}

Export-ModuleMember -Function ConvertFrom-YurunaLinuxMemoryInfo, ConvertFrom-YurunaMacMemoryInfo, Get-YurunaHostMemoryMetricPayload
