<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4241b748-d045-41cb-81f6-f42876137267
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm screenshot png ocr pester
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
    KVM framebuffer conversion preserves pixels and stable PNG evidence.
.DESCRIPTION
    The production capture function is lifted from its host module. Fixtures
    cover every conversion fallback without requiring libvirt; ImageMagick,
    when installed, also verifies real PNG chunks, decoded RGB and OCR reuse.
#>

BeforeDiscovery {
    # BeforeAll runs after discovery, so the fixtures the cases below are
    # built from are written out again here.
    $pngHeader = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x03, 0x20)
    $ascii = { param([string]$Text) [Text.Encoding]::ASCII.GetBytes($Text) }
    $wrongChunk = [byte[]]$pngHeader.Clone()
    $wrongChunk[12] = 0x50
    $script:FrameSizeCases = @(
        @{ Name = 'a P6 header'; Bytes = [byte[]]((& $ascii "P6`n1280 800`n255`n") + [byte[]]::new(12)); Width = 1280; Height = 800; Size = '1280x800' }
        @{ Name = 'a P6 header after comments'; Bytes = [byte[]]((& $ascii "P6`n# first comment`n# second comment`n1280 800`n255`n") + [byte[]]::new(12)); Width = 1280; Height = 800; Size = '1280x800' }
        @{ Name = 'the P3 fixture'; Bytes = [byte[]](& $ascii "P3`n3 2`n255`n255 0 0 0 255 0 0 0 255`n16 32 64 128 192 255 255 255 255`n"); Width = 3; Height = 2; Size = '3x2' }
        @{ Name = 'a PNG header'; Bytes = $pngHeader; Width = 1280; Height = 800; Size = '1280x800' }
        @{ Name = 'a text file'; Bytes = [byte[]](& $ascii 'png-fixture'); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'an empty file'; Bytes = [byte[]]::new(0); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a PNG header cut to 20 bytes'; Bytes = [byte[]]$pngHeader[0..19]; Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a P6 header cut inside the height'; Bytes = [byte[]](& $ascii "P6`n1280 80"); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a zero width'; Bytes = [byte[]](& $ascii "P6`n0 800`n255`n"); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a width above 32768'; Bytes = [byte[]](& $ascii "P6`n40000 800`n255`n"); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a seven-digit width'; Bytes = [byte[]](& $ascii "P6`n1234567 800`n255`n"); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a negative width'; Bytes = [byte[]](& $ascii "P6`n-5 800`n255`n"); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a P5 header'; Bytes = [byte[]](& $ascii "P5`n10 10`n255`n"); Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a PNG header with another chunk type'; Bytes = $wrongChunk; Width = 0; Height = 0; Size = 'nothing' }
        @{ Name = 'a missing file'; Bytes = $null; Width = 0; Height = 0; Size = 'nothing' }
    )
}

BeforeAll {
    $script:ImageMagick = @(Get-Command convert -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    Import-Module (Join-Path $PSScriptRoot 'Test.DriverSource.psm1') -DisableNameChecking
    foreach ($name in 'Get-VMScreenshot', 'Get-KvmFrameSize', 'Restart-VMConsole', 'Test-DriverNativeResultComplete') {
        . ([scriptblock]::Create((Get-YurunaDriverFunction -Driver ubuntu.kvm -Name $name)))
    }
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:VirshQueryTimeoutSeconds = 20
    function Get-NativeResultFixture {
        param([int]$ExitCode = 0, [switch]$TimedOut)
        @{ Started = $true; ExitCode = $(if ($TimedOut) { 124 } else { $ExitCode }); TimedOut = [bool]$TimedOut
            DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; StdOut = ''; StdErr = '' }
    }
    function Invoke-Virsh { param([string[]]$VirshArgs) $null = $VirshArgs }
    function Invoke-VirshBounded { param([string[]]$VirshArgs, [int]$TimeoutSeconds) $null = $VirshArgs, $TimeoutSeconds }
    function bash { }
    function pkill { }
    function Test-VMConsoleOpen { param($VMName) $null = $VMName; return $false }
    function convert { }
    function pamtopng { }
    function Format-YurunaOperatorMessage { param($Key, $Arguments) $null = $Arguments; return $Key }
    function Get-PngChunk {
        param([string]$Path)
        $bytes = [IO.File]::ReadAllBytes($Path)
        $offset = 8
        while ($offset -lt $bytes.Length) {
            $length = [int]([long]$bytes[$offset] * 16777216 + [long]$bytes[$offset+1] * 65536 + [long]$bytes[$offset+2] * 256 + $bytes[$offset+3])
            $kind = [Text.Encoding]::ASCII.GetString($bytes, $offset + 4, 4)
            $payload = [byte[]]::new($length)
            [Array]::Copy($bytes, $offset + 8, $payload, 0, $length)
            [pscustomobject]@{ Kind = $kind; Data = [Convert]::ToBase64String($payload) }
            $offset += $length + 12
        }
    }
    $script:PpmBytes = [Text.Encoding]::ASCII.GetBytes("P3`n3 2`n255`n255 0 0 0 255 0 0 0 255`n16 32 64 128 192 255 255 255 255`n")
    # The first 24 bytes of a 1280 by 800 PNG: signature, IHDR length and type, width, height.
    $script:PngHeader = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x03, 0x20)
}

Describe 'KVM console recovery launch result' {
    BeforeEach {
        Mock Get-Command { [pscustomobject]@{ Name = 'virt-viewer' } } -ParameterFilter { $Name -eq 'virt-viewer' }
        Mock pkill { $global:LASTEXITCODE = 1 }
        Mock bash { $global:LASTEXITCODE = $script:ViewerExit }
        Mock Start-Sleep { }
        Mock Test-VMConsoleOpen { $true }
    }
    It 'reports launcher exit <ExitCode> as <Expected>' -TestCases @(
        @{ ExitCode = 0; Expected = $true }
        @{ ExitCode = 1; Expected = $false }
    ) {
        param($ExitCode, $Expected)
        $script:ViewerExit = $ExitCode
        Restart-VMConsole -VMName 'test-guest.ubuntu.server.26-01' -Confirm:$false | Should -Be $Expected
        Should -Invoke bash -Times 1 -Exactly
    }
    It 'refuses a missing viewer without attempting a launch' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'virt-viewer' }
        Restart-VMConsole -VMName 'vm' -Confirm:$false | Should -BeFalse
        Should -Invoke bash -Times 0
    }
    It 'refuses a detached launcher whose viewer never appears' {
        $script:ViewerExit = 0
        Mock Test-VMConsoleOpen { $false }
        Restart-VMConsole -VMName 'vm' -Confirm:$false | Should -BeFalse
        Should -Invoke Test-VMConsoleOpen -Times 20 -Exactly
    }
    It 'waits for the detached viewer to appear within its polling budget' {
        $script:ViewerExit = 0
        $script:ViewerProbe = 0
        Mock Test-VMConsoleOpen { $script:ViewerProbe++; return ($script:ViewerProbe -ge 3) }
        Restart-VMConsole -VMName 'vm' -Confirm:$false | Should -BeTrue
        Should -Invoke Test-VMConsoleOpen -Times 3 -Exactly
    }
    It 'preserves WhatIf without touching the viewer' {
        Restart-VMConsole -VMName 'vm' -WhatIf | Should -BeFalse
        Should -Invoke pkill -Times 0
        Should -Invoke bash -Times 0
    }
}

Describe 'KVM screenshot fallback behavior' {
    BeforeEach {
        $script:Engine = 'convert'
        $script:OutFile = Join-Path $TestDrive ("frame `u{fc} [1]-" + [guid]::NewGuid().ToString('N') + '.png')
        Mock Get-Command {
            if ($Name -eq $script:Engine) { return [pscustomobject]@{ Name = $Name } }
            return $null
        } -ParameterFilter { $Name -in @('convert', 'pamtopng') }
        Mock Invoke-VirshBounded {
            $script:CaptureArgs = @($VirshArgs)
            [IO.File]::WriteAllBytes($VirshArgs[-1], $script:PpmBytes)
            Get-NativeResultFixture
        }
        Mock Invoke-BoundedNativeCommand {
            $script:ConvertArgs = @($ArgumentList)
            [IO.File]::WriteAllText($ArgumentList[-1], 'png-fixture')
            Get-NativeResultFixture
        } -ParameterFilter { $FilePath -eq 'convert' }
        Mock Invoke-BoundedNativeCommand {
            $script:PamArgs = @($ArgumentList)
            [IO.File]::WriteAllText($ArgumentList[-1], 'pamtopng-fixture')
            Get-NativeResultFixture
        } -ParameterFilter { $FilePath -eq 'sh' }
    }
    It 'excludes only date and time metadata and keeps literal VM/path arguments' {
        Get-VMScreenshot -VMName "vm `u{fc} [1]; literal" -OutFile $script:OutFile | Should -BeExactly $script:OutFile
        $script:CaptureArgs | Should -Be @('screenshot', "vm `u{fc} [1]; literal", [IO.Path]::ChangeExtension($script:OutFile, '.ppm'))
        $script:ConvertArgs | Should -Be @([IO.Path]::ChangeExtension($script:OutFile, '.ppm'), '-define', 'png:exclude-chunk=date,time', $script:OutFile)
        Test-Path -LiteralPath ([IO.Path]::ChangeExtension($script:OutFile, '.ppm')) | Should -BeFalse
    }
    It 'returns the image path and the frame size for a window capture' {
        Mock Invoke-BoundedNativeCommand {
            [IO.File]::WriteAllBytes($ArgumentList[-1], $script:PngHeader)
            Get-NativeResultFixture
        } -ParameterFilter { $FilePath -eq 'convert' }
        $capture = Get-VMScreenshot -VMName 'vm' -Source window -OutFile $script:OutFile
        ($capture -is [hashtable]) | Should -BeTrue -Because 'Send-Click binds -Capture as [hashtable]; an ordered dictionary does not bind'
        $capture.ImagePath | Should -BeExactly $script:OutFile
        $capture.Width | Should -Be 1280
        $capture.Height | Should -Be 800
        Should -Invoke Invoke-VirshBounded -Times 1 -Exactly
    }
    It 'keeps returning a path string for a frame capture and reads no header' {
        Mock Get-KvmFrameSize { throw 'frame captures read no header' }
        $frame = Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile
        ($frame -is [string]) | Should -BeTrue
        $frame | Should -BeExactly $script:OutFile
        Should -Invoke Get-KvmFrameSize -Times 0 -Exactly
    }
    It 'reads the size of the raw frame when no converter is installed' {
        $script:Engine = 'none'
        $capture = Get-VMScreenshot -VMName 'vm' -Source window -OutFile $script:OutFile -WarningAction SilentlyContinue
        $capture.ImagePath | Should -BeExactly ([IO.Path]::ChangeExtension($script:OutFile, '.ppm'))
        $capture.Width | Should -Be 3
        $capture.Height | Should -Be 2
    }
    It 'reads PNG bytes that virsh wrote under the ppm name' {
        $script:Engine = 'none'
        Mock Invoke-VirshBounded {
            [IO.File]::WriteAllBytes($VirshArgs[-1], $script:PngHeader)
            Get-NativeResultFixture
        }
        $capture = Get-VMScreenshot -VMName 'vm' -Source window -OutFile $script:OutFile -WarningAction SilentlyContinue
        $capture.Width | Should -Be 1280
        $capture.Height | Should -Be 800
    }
    It 'discards a window capture whose size cannot be read' {
        $capture = Get-VMScreenshot -VMName 'vm' -Source window -OutFile $script:OutFile -WarningVariable w -WarningAction SilentlyContinue
        $capture | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:OutFile | Should -BeFalse
        @($w).Count | Should -Be 1
        "$($w[0])" | Should -BeExactly 'host.kvm_frame_size_unreadable'
    }
    It 'returns no frame when virsh fails' {
        Mock Invoke-VirshBounded { Get-NativeResultFixture -ExitCode 1 }
        Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        Should -Invoke Invoke-BoundedNativeCommand -Times 0
    }
    It 'gives up on a frame virsh does not deliver within its cap, keeping no partial capture' {
        Mock Invoke-VirshBounded {
            [IO.File]::WriteAllBytes($VirshArgs[-1], $script:PpmBytes[0..5])
            Get-NativeResultFixture -TimedOut
        }
        Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        Should -Invoke Invoke-VirshBounded -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 20 }
        Should -Invoke Invoke-BoundedNativeCommand -Times 0
        Test-Path -LiteralPath ([IO.Path]::ChangeExtension($script:OutFile, '.ppm')) | Should -BeFalse
    }
    It 'discards the partial PNG of a converter stopped at its cap' {
        Mock Invoke-BoundedNativeCommand {
            [IO.File]::WriteAllText($ArgumentList[-1], 'partial')
            Get-NativeResultFixture -TimedOut
        } -ParameterFilter { $FilePath -eq 'convert' }
        Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:OutFile | Should -BeFalse
        Test-Path -LiteralPath ([IO.Path]::ChangeExtension($script:OutFile, '.ppm')) | Should -BeFalse
    }
    It 'retains the pamtopng fallback' {
        $script:Engine = 'pamtopng'
        $script:OutFile = Join-Path $TestDrive 'pam-frame.png'
        Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile | Should -BeExactly $script:OutFile
        (Get-Content -LiteralPath $script:OutFile -Raw).Trim() | Should -BeExactly 'pamtopng-fixture'
        $script:PamArgs | Should -Be @('-c', 'exec pamtopng "$1" > "$2"', 'sh', [IO.Path]::ChangeExtension($script:OutFile, '.ppm'), $script:OutFile)
        Should -Invoke Invoke-BoundedNativeCommand -Times 0 -ParameterFilter { $FilePath -eq 'convert' }
        Should -Invoke Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'sh' }
    }
    It 'retains the raw PPM when neither converter is installed' {
        $script:Engine = 'none'
        $ppm = Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile -WarningAction SilentlyContinue
        $ppm | Should -BeExactly ([IO.Path]::ChangeExtension($script:OutFile, '.ppm'))
        Test-Path -LiteralPath $ppm | Should -BeTrue
    }
    It 'returns no frame when conversion creates no output' {
        Mock Invoke-BoundedNativeCommand { Get-NativeResultFixture } -ParameterFilter { $FilePath -eq 'convert' }
        Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile | Should -BeNullOrEmpty
        Test-Path -LiteralPath ([IO.Path]::ChangeExtension($script:OutFile, '.ppm')) | Should -BeFalse
    }
}

Describe 'KVM stable PNG conversion with actual ImageMagick' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Global -Force -DisableNameChecking
    }
    It 'preserves decoded colors and nonvolatile chunks while timestamp-only frames share one OCR answer' {
        if (-not $script:ImageMagick -or $IsWindows) {
            Set-ItResult -Skipped -Because 'The Unix KVM converter is not installed on this platform.'
            return
        }
        $script:CaptureIndex = 0
        Mock Invoke-VirshBounded {
            [IO.File]::WriteAllBytes($VirshArgs[-1], $script:PpmBytes)
            [IO.File]::SetLastWriteTimeUtc($VirshArgs[-1], [datetime]::new(2020 + $script:CaptureIndex, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
            $script:CaptureIndex++
            Get-NativeResultFixture
        }
        $frameA = Join-Path $TestDrive 'stable-a.png'
        $frameB = Join-Path $TestDrive 'stable-b.png'
        $rawPpm = Join-Path $TestDrive 'original.ppm'
        $original = Join-Path $TestDrive 'original.png'
        [IO.File]::WriteAllBytes($rawPpm, $script:PpmBytes)
        & $script:ImageMagick.Source $rawPpm $original
        $LASTEXITCODE | Should -Be 0
        Get-VMScreenshot -VMName 'fixture' -OutFile $frameA | Should -BeExactly $frameA
        $window = Get-VMScreenshot -VMName 'fixture' -Source window -OutFile (Join-Path $TestDrive 'stable-window.png')
        $window.Width | Should -Be 3
        $window.Height | Should -Be 2
        Start-Sleep -Milliseconds 1100
        Get-VMScreenshot -VMName 'fixture' -OutFile $frameB | Should -BeExactly $frameB
        (Get-FileHash -LiteralPath $frameA).Hash | Should -BeExactly (Get-FileHash -LiteralPath $frameB).Hash
        $originalChunks = @(Get-PngChunk -Path $original)
        $stableChunks = @(Get-PngChunk -Path $frameA)
        $originalChunks.Kind | Should -Contain 'tIME'
        $stableChunks.Kind | Should -Not -Contain 'tIME'
        $stableChunks.Kind | Should -Contain 'cHRM'
        $stableChunks.Kind | Should -Contain 'bKGD'
        $expected = @($originalChunks | Where-Object { $_.Kind -ne 'tIME' -and -not ($_.Kind -eq 'tEXt' -and [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($_.Data)).StartsWith('date:')) } | ForEach-Object { $_.Kind + ':' + $_.Data })
        @($stableChunks | ForEach-Object { $_.Kind + ':' + $_.Data }) | Should -Be $expected
        foreach ($image in @($original, $frameA)) {
            & $script:ImageMagick.Source $image -depth 8 ('rgb:' + $image + '.rgb')
            $LASTEXITCODE | Should -Be 0
        }
        (Get-FileHash -LiteralPath ($original + '.rgb')).Hash | Should -BeExactly (Get-FileHash -LiteralPath ($frameA + '.rgb')).Hash
        $counter = @{ Count = 0 }
        Register-OcrProvider -Name 'stable-kvm-frame-fixture' -Invoke { param($ImagePath); $null = $ImagePath; $counter.Count++; return 'unchanged screen' }.GetNewClosure() -IsAvailable { $true }
        Clear-OcrResultCache
        Invoke-OcrProvider -Name 'stable-kvm-frame-fixture' -ImagePath $frameA | Should -BeExactly 'unchanged screen'
        Invoke-OcrProvider -Name 'stable-kvm-frame-fixture' -ImagePath $frameB | Should -BeExactly 'unchanged screen'
        $counter.Count | Should -Be 1
    }
}

Describe 'KVM frame size reader' {
    It 'reads <Name> as <Size>' -ForEach $script:FrameSizeCases {
        $path = Join-Path $TestDrive ($Name + '.bin')
        if ($null -ne $Bytes) { [IO.File]::WriteAllBytes($path, [byte[]]$Bytes) }
        $frameSize = Get-KvmFrameSize -Path $path
        if ($Size -eq 'nothing') {
            $frameSize | Should -BeNullOrEmpty
        } else {
            $frameSize.Width | Should -Be $Width
            $frameSize.Height | Should -Be $Height
        }
    }
}
