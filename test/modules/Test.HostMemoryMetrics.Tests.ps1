<#PSScriptInfo
.VERSION 2026.10.22
.GUID 428f2561-ce7c-4e31-98b0-f0b204309183
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host memory metrics pester
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

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostMemoryMetrics.psm1') -Force -DisableNameChecking
    $script:LinuxMemory = @'
MemTotal:       16384000 kB
MemFree:         1000000 kB
MemAvailable:    3000000 kB
Buffers:           10000 kB
Cached:          2000000 kB
SwapTotal:       4000000 kB
SwapFree:        3500000 kB
CommitLimit:    12000000 kB
Committed_AS:   15000000 kB
'@
    $script:MacMemory = @'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                1000.
Pages active:                              5000.
Pages inactive:                            2000.
Pages speculative:                          300.
Pages purgeable:                            700.
Pages occupied by compressor:               900.
hw.memsize: 17179869184
vm.swapusage: total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)
'@
}

Describe 'native memory samples preserve platform units and meanings' {
    It 'uses Linux MemAvailable instead of free pages and converts kB to bytes' {
        $sample = ConvertFrom-YurunaLinuxMemoryInfo -Text $script:LinuxMemory
        Assert-Equal 3072000000 $sample.available_bytes
        Assert-Equal 1024000000 $sample.free_bytes
        Assert-Equal 16777216000 $sample.total_bytes
        Assert-Equal 4096000000 $sample.swap_total_bytes
        Assert-Equal 3584000000 $sample.swap_free_bytes
    }

    It 'preserves Linux commitment above its accounting limit' {
        $sample = ConvertFrom-YurunaLinuxMemoryInfo -Text $script:LinuxMemory
        Assert-Equal 12288000000 $sample.commit_limit_bytes
        Assert-Equal 15360000000 $sample.committed_bytes
        Assert-True ($sample.committed_bytes -gt $sample.commit_limit_bytes) 'overcommit is observable rather than clamped to a Windows interpretation'
    }

    It 'preserves a valid zero swap capacity' {
        $sample = ConvertFrom-YurunaLinuxMemoryInfo -Text ($script:LinuxMemory -replace '4000000 kB', '0 kB' -replace '3500000 kB', '0 kB')
        Assert-Equal 0 $sample.swap_total_bytes
        Assert-Equal 0 $sample.swap_free_bytes
    }

    It 'rejects missing or malformed Linux readings: <Name>' -ForEach @(
        @{ Name = 'missing available'; Pattern = '(?m)^MemAvailable:.*'; Replacement = '' },
        @{ Name = 'wrong unit'; Pattern = '3000000 kB'; Replacement = '3000000 MB' },
        @{ Name = 'negative available'; Pattern = '3000000 kB'; Replacement = '-1 kB' },
        @{ Name = 'overflow'; Pattern = '3000000 kB'; Replacement = '9223372036854775807 kB' },
        @{ Name = 'unreadable total'; Pattern = '(?m)^MemTotal:.*'; Replacement = 'MemTotal: unknown kB' }
    ) {
        { ConvertFrom-YurunaLinuxMemoryInfo -Text ($script:LinuxMemory -replace $Pattern, $Replacement) } | Should -Throw
    }

    It 'does not invent optional Linux commitment counters' {
        $text = $script:LinuxMemory -replace '(?m)^(CommitLimit|Committed_AS):.*', ''
        $sample = ConvertFrom-YurunaLinuxMemoryInfo -Text $text
        Assert-False $sample.Contains('commit_limit_bytes')
        Assert-False $sample.Contains('committed_bytes')
    }

    It 'scales macOS counters by the reported <PageSize>-byte page size' -ForEach @(
        @{ PageSize = 4096 }, @{ PageSize = 16384 }
    ) {
        $sample = ConvertFrom-YurunaMacMemoryInfo -Text ($script:MacMemory.Replace('16384 bytes', "$PageSize bytes"))
        Assert-Equal (3000L * $PageSize) $sample.available_bytes
        Assert-Equal (1000L * $PageSize) $sample.free_bytes
        Assert-Equal 17179869184 $sample.total_bytes
        Assert-Equal 2147483648 $sample.swap_total_bytes
        Assert-Equal 1610612736 $sample.swap_free_bytes
        Assert-False $sample.Contains('commit_limit_bytes') 'macOS has no Windows-style commit limit'
        Assert-False $sample.Contains('committed_bytes')
    }

    It 'rejects missing or malformed macOS readings: <Name>' -ForEach @(
        @{ Name = 'missing page size'; Pattern = '(?m)^Mach Virtual.*'; Replacement = '' },
        @{ Name = 'missing inactive'; Pattern = '(?m)^Pages inactive:.*'; Replacement = '' },
        @{ Name = 'zero page size'; Pattern = '16384 bytes'; Replacement = '0 bytes' },
        @{ Name = 'missing hardware total'; Pattern = '(?m)^hw.memsize:.*'; Replacement = '' },
        @{ Name = 'bad swap'; Pattern = 'free = 1536.00M'; Replacement = 'free = unknown' }
    ) {
        { ConvertFrom-YurunaMacMemoryInfo -Text ($script:MacMemory -replace $Pattern, $Replacement) } | Should -Throw
    }
}

Describe 'the native memory exporter reports unavailable sources honestly' {
    It 'formats Prometheus bytes independently of the operator locale' {
        Mock Get-YurunaHostMemorySample -ModuleName Test.HostMemoryMetrics { [ordered]@{ available_bytes = 1234567890L } }
        $previous = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = 'de-DE'
            $result = Get-YurunaHostMemoryMetricPayload
            Assert-True $result.Success
            Assert-Match '(?m)^# TYPE yuruna_host_memory_available_bytes gauge$' $result.Body
            Assert-Match '(?m)^yuruna_host_memory_available_bytes 1234567890$' $result.Body
            Assert-Match '(?m)^yuruna_host_memory_collection_success 1$' $result.Body
        } finally { [Globalization.CultureInfo]::CurrentCulture = $previous }
    }

    It 'does not emit any memory samples after a read failure' {
        Mock Get-YurunaHostMemorySample -ModuleName Test.HostMemoryMetrics { throw 'unreadable source' }
        $result = Get-YurunaHostMemoryMetricPayload
        Assert-False $result.Success
        Assert-Match '(?m)^yuruna_host_memory_collection_success 0$' $result.Body
        Assert-False ($result.Body -match 'yuruna_host_memory_available_bytes')
    }

    It 'does not accept a partial native command result: <Flag>' -ForEach @(
        @{ Flag = 'TimedOut' }, @{ Flag = 'DrainTimedOut' }, @{ Flag = 'OutputTruncated' },
        @{ Flag = 'KillFailed' }, @{ Flag = 'DeadlineExhausted' }
    ) {
        $script:IncompleteNative = @{ Started = $true; ExitCode = 0; StdOut = $script:MacMemory; $Flag = $true }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.HostMemoryMetrics { $script:IncompleteNative }
        $result = Get-YurunaHostMemoryMetricPayload -Platform macOS
        Assert-False $result.Success
        Assert-False ($result.Body -match 'yuruna_host_memory_available_bytes')
    }

    It 'collects macOS counters in one bounded invocation with a fixed locale' {
        $script:CompleteNative = @{ Started = $true; ExitCode = 0; StdOut = $script:MacMemory }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.HostMemoryMetrics { $script:CompleteNative }
        $result = Get-YurunaHostMemoryMetricPayload -Platform macOS
        Assert-True $result.Success
        Assert-Match '(?m)^yuruna_host_memory_available_bytes 49152000$' $result.Body
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.HostMemoryMetrics -Times 1 -Exactly -Scope It -ParameterFilter {
            $TimeoutSeconds -eq 1 -and $MaxCapturedChars -le 16384 -and $Environment.LC_ALL -eq 'C'
        }
    }

    It 'does not export readings when the native command refuses the request' {
        Mock Invoke-BoundedNativeCommand -ModuleName Test.HostMemoryMetrics { @{ Started = $true; ExitCode = 1; StdOut = '' } }
        Assert-False (Get-YurunaHostMemoryMetricPayload -Platform macOS).Success
    }
}
