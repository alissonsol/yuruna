<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 4269bfd0-3aed-475d-942d-47e877a194c1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ocr engine cache pester
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
    Verify that Invoke-OcrProvider reuses an engine's answer for byte-identical
    frames instead of running the engine again.
.DESCRIPTION
    A tesseract pass over a full-HD console frame costs seconds of CPU, and
    consecutive waitForText polls often capture the same frame. The
    characterization Describe below pins what every caller still sees (the
    exact answer shape, every error, every path); the mechanism Describe pins
    that a repeated frame is recognized once per engine. "Frame" fixtures are
    small byte arrays written to TestDrive -- the cache hashes bytes, so
    nothing here needs to decode a real image.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Force -Global
    if (Get-Command Clear-OcrResultCache -ErrorAction SilentlyContinue) { Clear-OcrResultCache }
    $script:OcrCallLog = [System.Collections.Generic.List[string]]::new()
    function Register-CountingOcrProvider {
        <# .SYNOPSIS
            Registers a fake provider that records every path it is given and
            answers from a scripted queue, one item per call past the queue end.
        #>
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Answer)
        # GetNewClosure snapshots plain locals into the scriptblock's own scope
        # at registration time; without it every registered provider would
        # share one dynamically-scoped lookup instead of its own state. An
        # explicit $script: reference is not a plain local, so the call log
        # is captured the same way, through a local alias to the same list.
        $fixture = [pscustomobject]@{ Name = $Name; Answer = $Answer; Index = 0 }
        $callLog = $script:OcrCallLog
        Register-OcrProvider -Name $Name -Invoke {
            param([string]$ImagePath)
            $callLog.Add("$($fixture.Name)|$ImagePath")
            $slot = [Math]::Min($fixture.Index, $fixture.Answer.Count - 1)
            $fixture.Index++
            $value = $fixture.Answer[$slot]
            if ($value -is [System.Management.Automation.ScriptBlock]) { return (& $value) }
            $value
        }.GetNewClosure() -IsAvailable { $true }
    }
    function New-OcrFrame {
        <# .SYNOPSIS
            Writes a frame fixture with the given bytes and returns its path.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes under TestDrive, which Pester removes; not user-facing state.')]
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][byte[]]$Bytes)
        $path = Join-Path $TestDrive $Name
        [IO.File]::WriteAllBytes($path, $Bytes)
        $path
    }
}
Describe 'OCR answers are unchanged' {
    BeforeEach {
        $script:OcrCallLog.Clear()
        if (Get-Command Clear-OcrResultCache -ErrorAction SilentlyContinue) { Clear-OcrResultCache }
    }
    It 'returns a string answer exactly' {
        Register-CountingOcrProvider -Name 'cache-fixture-string' -Answer @('plain text')
        $frame = New-OcrFrame -Name 'string.png' -Bytes ([byte[]](1, 2, 3))
        Invoke-OcrProvider -Name 'cache-fixture-string' -ImagePath $frame | Should -Be 'plain text'
    }
    It 'returns a multi-line answer exactly' {
        Register-CountingOcrProvider -Name 'cache-fixture-multiline' -Answer @("line one`nline two`nline three")
        $frame = New-OcrFrame -Name 'multiline.png' -Bytes ([byte[]](4, 5, 6))
        Invoke-OcrProvider -Name 'cache-fixture-multiline' -ImagePath $frame | Should -Be "line one`nline two`nline three"
    }
    It 'returns an array answer exactly, not flattened to a string' {
        Register-CountingOcrProvider -Name 'cache-fixture-array' -Answer @(, @('alpha', 'beta'))
        $frame = New-OcrFrame -Name 'array.png' -Bytes ([byte[]](7, 8, 9))
        $result = Invoke-OcrProvider -Name 'cache-fixture-array' -ImagePath $frame
        , $result | Should -Be (, @('alpha', 'beta'))
    }
    It 'returns $null exactly' {
        # A literal $null inside the queue would make the Mandatory array
        # parameter itself bind to $null (PowerShell rejects a Mandatory
        # argument that resolves to null, element or not), so the null answer
        # is wrapped in a scriptblock the same way a non-trivial one would be.
        Register-CountingOcrProvider -Name 'cache-fixture-null' -Answer @({ $null })
        $frame = New-OcrFrame -Name 'null.png' -Bytes ([byte[]](10, 11))
        Invoke-OcrProvider -Name 'cache-fixture-null' -ImagePath $frame | Should -BeNullOrEmpty
    }
    It 'propagates a throwing provider with the same message' {
        Register-OcrProvider -Name 'cache-fixture-throws' -Invoke { param($p) $null = $p; throw 'simulated engine failure' } -IsAvailable { $true }
        $frame = New-OcrFrame -Name 'throws.png' -Bytes ([byte[]](12, 13))
        { Invoke-OcrProvider -Name 'cache-fixture-throws' -ImagePath $frame } | Should -Throw 'simulated engine failure'
    }
    It 'reaches the provider with a missing image path, and its error surfaces' {
        Register-OcrProvider -Name 'cache-fixture-missing' -Invoke { param($p) throw "provider saw path: $p" } -IsAvailable { $true }
        $missing = Join-Path $TestDrive 'does-not-exist.png'
        { Invoke-OcrProvider -Name 'cache-fixture-missing' -ImagePath $missing } | Should -Throw "*provider saw path: $missing*"
    }
    It 'gives each of two engines in sequence the same path' {
        Register-CountingOcrProvider -Name 'cache-fixture-seq-a' -Answer @('a-text')
        Register-CountingOcrProvider -Name 'cache-fixture-seq-b' -Answer @('b-text')
        $frame = New-OcrFrame -Name 'seq.png' -Bytes ([byte[]](14, 15, 16))
        $null = Invoke-OcrProvider -Name 'cache-fixture-seq-a' -ImagePath $frame
        $null = Invoke-OcrProvider -Name 'cache-fixture-seq-b' -ImagePath $frame
        , @($script:OcrCallLog) | Should -Be (, @("cache-fixture-seq-a|$frame", "cache-fixture-seq-b|$frame"))
    }
}

Describe 'an identical frame is recognized once per engine' {
    BeforeEach {
        $script:OcrCallLog.Clear()
        if (Get-Command Clear-OcrResultCache -ErrorAction SilentlyContinue) { Clear-OcrResultCache }
    }
    It 'calls the engine once for the same bytes read twice' {
        Register-CountingOcrProvider -Name 'cache-fixture-same' -Answer @('first', 'second')
        $frame = New-OcrFrame -Name 'same.png' -Bytes ([byte[]](1, 2, 3, 4))
        $first = Invoke-OcrProvider -Name 'cache-fixture-same' -ImagePath $frame
        $second = Invoke-OcrProvider -Name 'cache-fixture-same' -ImagePath $frame
        $script:OcrCallLog.Count | Should -Be 1
        $second | Should -Be $first
        $first | Should -Be 'first'
    }
    It 'calls the engine once for the same bytes under two different file names' {
        Register-CountingOcrProvider -Name 'cache-fixture-rename' -Answer @('text')
        $bytes = [byte[]](21, 22, 23)
        $frameA = New-OcrFrame -Name 'name-a.png' -Bytes $bytes
        $frameB = New-OcrFrame -Name 'name-b.png' -Bytes $bytes
        $null = Invoke-OcrProvider -Name 'cache-fixture-rename' -ImagePath $frameA
        $null = Invoke-OcrProvider -Name 'cache-fixture-rename' -ImagePath $frameB
        $script:OcrCallLog.Count | Should -Be 1
    }
    It 'calls each of two engines once for the same bytes' {
        Register-CountingOcrProvider -Name 'cache-fixture-two-a' -Answer @('a')
        Register-CountingOcrProvider -Name 'cache-fixture-two-b' -Answer @('b')
        $frame = New-OcrFrame -Name 'two.png' -Bytes ([byte[]](31, 32))
        $null = Invoke-OcrProvider -Name 'cache-fixture-two-a' -ImagePath $frame
        $null = Invoke-OcrProvider -Name 'cache-fixture-two-a' -ImagePath $frame
        $null = Invoke-OcrProvider -Name 'cache-fixture-two-b' -ImagePath $frame
        $null = Invoke-OcrProvider -Name 'cache-fixture-two-b' -ImagePath $frame
        ($script:OcrCallLog | Where-Object { $_ -like 'cache-fixture-two-a|*' }).Count | Should -Be 1
        ($script:OcrCallLog | Where-Object { $_ -like 'cache-fixture-two-b|*' }).Count | Should -Be 1
    }
    It 'calls the engine twice when the frame is rewritten in place with new bytes' {
        Register-CountingOcrProvider -Name 'cache-fixture-rewrite' -Answer @('before', 'after')
        $path = Join-Path $TestDrive 'rewrite.png'
        [IO.File]::WriteAllBytes($path, [byte[]](41, 42))
        $before = Invoke-OcrProvider -Name 'cache-fixture-rewrite' -ImagePath $path
        [IO.File]::WriteAllBytes($path, [byte[]](43, 44))
        $after = Invoke-OcrProvider -Name 'cache-fixture-rewrite' -ImagePath $path
        $script:OcrCallLog.Count | Should -Be 2
        $before | Should -Be 'before'
        $after | Should -Be 'after'
    }
    It 'calls the engine again after an empty or whitespace answer' {
        Register-CountingOcrProvider -Name 'cache-fixture-empty' -Answer @('', '   ', 'finally')
        $frame = New-OcrFrame -Name 'empty.png' -Bytes ([byte[]](51, 52))
        $null = Invoke-OcrProvider -Name 'cache-fixture-empty' -ImagePath $frame
        $null = Invoke-OcrProvider -Name 'cache-fixture-empty' -ImagePath $frame
        $third = Invoke-OcrProvider -Name 'cache-fixture-empty' -ImagePath $frame
        $script:OcrCallLog.Count | Should -Be 3
        $third | Should -Be 'finally'
    }
    It 'calls a throwing provider again on the next poll, never caching the failure' {
        $script:ThrowCount = 0
        Register-OcrProvider -Name 'cache-fixture-throw-twice' -Invoke {
            param($p)
            $null = $p
            $script:ThrowCount++
            throw "simulated failure $script:ThrowCount"
        } -IsAvailable { $true }
        $frame = New-OcrFrame -Name 'throw-twice.png' -Bytes ([byte[]](61, 62))
        { Invoke-OcrProvider -Name 'cache-fixture-throw-twice' -ImagePath $frame } | Should -Throw 'simulated failure 1'
        { Invoke-OcrProvider -Name 'cache-fixture-throw-twice' -ImagePath $frame } | Should -Throw 'simulated failure 2'
    }
    It 'recognizes the first of five distinct frames again once the limit of four is exceeded' {
        Register-CountingOcrProvider -Name 'cache-fixture-limit' -Answer @('f1', 'f2', 'f3', 'f4', 'f5', 'f1-again')
        $frames = 1..5 | ForEach-Object { New-OcrFrame -Name "limit-$_.png" -Bytes ([byte[]]($_, $_, $_)) }
        foreach ($frame in $frames) { $null = Invoke-OcrProvider -Name 'cache-fixture-limit' -ImagePath $frame }
        $script:OcrCallLog.Count | Should -Be 5
        $again = Invoke-OcrProvider -Name 'cache-fixture-limit' -ImagePath $frames[0]
        $script:OcrCallLog.Count | Should -Be 6
        $again | Should -Be 'f1-again'
    }
}
Describe 'Clear-OcrResultCache' {
    BeforeEach {
        $script:OcrCallLog.Clear()
        if (Get-Command Clear-OcrResultCache -ErrorAction SilentlyContinue) { Clear-OcrResultCache }
    }
    It 'is exported and empties the cache' {
        Get-Command Clear-OcrResultCache -Module Test.OcrEngine -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Register-CountingOcrProvider -Name 'cache-fixture-clear' -Answer @('one', 'two')
        $frame = New-OcrFrame -Name 'clear.png' -Bytes ([byte[]](71, 72))
        $first = Invoke-OcrProvider -Name 'cache-fixture-clear' -ImagePath $frame
        Clear-OcrResultCache
        $second = Invoke-OcrProvider -Name 'cache-fixture-clear' -ImagePath $frame
        $script:OcrCallLog.Count | Should -Be 2
        $first | Should -Be 'one'
        $second | Should -Be 'two'
    }
}
