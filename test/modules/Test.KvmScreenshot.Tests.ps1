<#PSScriptInfo
.VERSION 2026.10.14
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

BeforeAll {
    $script:ImageMagick = @(Get-Command convert -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    $hostPath = Join-Path $PSScriptRoot '../../host/ubuntu.kvm/modules/Yuruna.Host.psm1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($hostPath, [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VMScreenshot' }, $true)
    if (-not $definition) { throw 'Get-VMScreenshot is absent.' }
    . ([scriptblock]::Create($definition.Extent.Text))
    function Invoke-Virsh { param([string[]]$VirshArgs) $null = $VirshArgs }
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
}

Describe 'KVM screenshot fallback behavior' {
    BeforeEach {
        $script:Engine = 'convert'
        $script:OutFile = Join-Path $TestDrive ("frame `u{fc} [1]-" + [guid]::NewGuid().ToString('N') + '.png')
        Mock Get-Command {
            if ($Name -eq $script:Engine) { return [pscustomobject]@{ Name = $Name } }
            return $null
        } -ParameterFilter { $Name -in @('convert', 'pamtopng') }
        Mock Invoke-Virsh {
            $script:CaptureArgs = @($VirshArgs)
            [IO.File]::WriteAllBytes($VirshArgs[-1], $script:PpmBytes)
            $global:LASTEXITCODE = 0
        }
        Mock convert {
            $script:ConvertArgs = @($args)
            [IO.File]::WriteAllText($args[-1], 'png-fixture')
        }
        Mock pamtopng { 'pamtopng-fixture' }
    }
    It 'excludes only date and time metadata and keeps literal VM/path arguments' {
        Get-VMScreenshot -VMName "vm `u{fc} [1]; literal" -OutFile $script:OutFile | Should -BeExactly $script:OutFile
        $script:CaptureArgs | Should -Be @('screenshot', "vm `u{fc} [1]; literal", [IO.Path]::ChangeExtension($script:OutFile, '.ppm'))
        $script:ConvertArgs | Should -Be @([IO.Path]::ChangeExtension($script:OutFile, '.ppm'), '-define', 'png:exclude-chunk=date,time', $script:OutFile)
        Test-Path -LiteralPath ([IO.Path]::ChangeExtension($script:OutFile, '.ppm')) | Should -BeFalse
    }
    It 'maps window capture to the same framebuffer operation' {
        Get-VMScreenshot -VMName 'vm' -Source window -OutFile $script:OutFile | Should -BeExactly $script:OutFile
        Should -Invoke Invoke-Virsh -Times 1 -Exactly
    }
    It 'returns no frame when virsh fails' {
        Mock Invoke-Virsh { $global:LASTEXITCODE = 1 }
        Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        Should -Invoke convert -Times 0
    }
    It 'retains the pamtopng fallback' {
        $script:Engine = 'pamtopng'
        $script:OutFile = Join-Path $TestDrive 'pam-frame.png'
        Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile | Should -BeExactly $script:OutFile
        (Get-Content -LiteralPath $script:OutFile -Raw).Trim() | Should -BeExactly 'pamtopng-fixture'
        Should -Invoke convert -Times 0
        Should -Invoke pamtopng -Times 1 -Exactly
    }
    It 'retains the raw PPM when neither converter is installed' {
        $script:Engine = 'none'
        $ppm = Get-VMScreenshot -VMName 'vm' -OutFile $script:OutFile -WarningAction SilentlyContinue
        $ppm | Should -BeExactly ([IO.Path]::ChangeExtension($script:OutFile, '.ppm'))
        Test-Path -LiteralPath $ppm | Should -BeTrue
    }
    It 'returns no frame when conversion creates no output' {
        Mock convert { }
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
        Mock Invoke-Virsh {
            [IO.File]::WriteAllBytes($VirshArgs[-1], $script:PpmBytes)
            [IO.File]::SetLastWriteTimeUtc($VirshArgs[-1], [datetime]::new(2020 + $script:CaptureIndex, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
            $script:CaptureIndex++
            $global:LASTEXITCODE = 0
        }
        Mock convert { & $script:ImageMagick.Source @args }
        $frameA = Join-Path $TestDrive 'stable-a.png'
        $frameB = Join-Path $TestDrive 'stable-b.png'
        $rawPpm = Join-Path $TestDrive 'original.ppm'
        $original = Join-Path $TestDrive 'original.png'
        [IO.File]::WriteAllBytes($rawPpm, $script:PpmBytes)
        & $script:ImageMagick.Source $rawPpm $original
        $LASTEXITCODE | Should -Be 0
        Get-VMScreenshot -VMName 'fixture' -OutFile $frameA | Should -BeExactly $frameA
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
