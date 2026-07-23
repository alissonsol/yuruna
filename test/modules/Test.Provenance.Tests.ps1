<#PSScriptInfo
.VERSION 2026.07.22
.GUID 4260f181-a3d7-4772-b069-c453a1938b2a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test provenance pester
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
    Pester coverage for Test.Provenance.psm1: the two-line base-image
    provenance sidecar reader and the transcript line it emits.
.DESCRIPTION
    Covers the sidecar path derivation (extension swap, including
    multi-dot image names), every shape the sidecar takes on disk
    (absent, zero-byte, one line, two lines, blank filename line, extra
    lines), and the three observable outcomes of Write-BaseImageProvenance
    (missing-file warning, blank-url warning, "Provenance: <url>" on the
    information stream rather than verbose, so it survives at the default
    logLevel).
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4
    and Pester 5+. Run: Invoke-Pester -Path test/modules/Test.Provenance.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Provenance.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Only the PATH is computed at file scope; the directory itself is created in
# BeforeAll and removed in AfterAll. A standalone run executes this file body
# twice (discovery, then run), so a temp dir built here would be created and
# torn down during discovery and every It would then probe a path that no
# longer exists. $PID keeps the name identical across the two passes while
# staying unique per test process.
$provRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-provenance-tests-$PID"

# Writes a placeholder base image and, optionally, its sidecar.
#   -SidecarLine omitted  -> no sidecar file at all
#   -SidecarLine @()      -> a zero-byte sidecar
#   -SidecarLine @(a,b)   -> a sidecar with those lines
function New-ImageFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ImageName,
        [string[]]$SidecarLine
    )
    $imagePath   = Join-Path $Root $ImageName
    Set-Content -LiteralPath $imagePath -Value 'placeholder-image-bytes'
    $sidecarPath = [System.IO.Path]::ChangeExtension($imagePath, '.txt')
    if ($null -eq $SidecarLine) {
        if (Test-Path -LiteralPath $sidecarPath) { Remove-Item -LiteralPath $sidecarPath -Force }
    } elseif ($SidecarLine.Count -eq 0) {
        Set-Content -LiteralPath $sidecarPath -Value '' -NoNewline
    } else {
        Set-Content -LiteralPath $sidecarPath -Value $SidecarLine
    }
    return $imagePath
}

# Runs Write-BaseImageProvenance with the warning (3) and information (6)
# streams merged into the success stream, then splits them back apart by
# record type so a test can assert on each independently.
function Get-ProvenanceEmission {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$BaseImagePath)
    $records = @(Write-BaseImageProvenance -BaseImagePath $BaseImagePath 3>&1 6>&1)
    return @{
        Warnings    = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }     | ForEach-Object { "$($_.Message)" })
        Information = @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
    }
}

Describe 'Test.Provenance' {

    BeforeAll {
        New-Item -ItemType Directory -Path $provRoot -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $provRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Get-BaseImageProvenance sidecar path' {

        It 'swaps only the final image extension for .txt' -TestCases @(
            @{ imageName = 'ubuntu-24.04.4-desktop-amd64.iso'; sidecarName = 'ubuntu-24.04.4-desktop-amd64.txt' }
            @{ imageName = 'test-windows-11-01.vhdx';          sidecarName = 'test-windows-11-01.txt' }
            @{ imageName = 'al2023-kvm-2023.6.20260101.qcow2'; sidecarName = 'al2023-kvm-2023.6.20260101.txt' }
            @{ imageName = 'image-with-no-extension';          sidecarName = 'image-with-no-extension.txt' }
        ) {
            param($imageName, $sidecarName)
            $p = Get-BaseImageProvenance -BaseImagePath (Join-Path $provRoot $imageName)
            Assert-Equal -Expected (Join-Path $provRoot $sidecarName) -Actual $p.ProvenancePath `
                -Because 'the version dots in a real ISO name must not be mistaken for the extension'
        }

        It 'reports an absent sidecar with empty fields instead of throwing' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'absent-sidecar.iso'
            $p   = Get-BaseImageProvenance -BaseImagePath $img
            Assert-Equal -Expected $false -Actual $p.FileExists
            Assert-Equal -Expected ''     -Actual $p.Filename
            Assert-Equal -Expected ''     -Actual $p.Url
            Assert-True  ($p.ProvenancePath.EndsWith('absent-sidecar.txt')) 'the derived path is returned even when nothing is there'
        }

        It 'reports an absent sidecar for an image in a directory that does not exist' {
            $p = Get-BaseImageProvenance -BaseImagePath (Join-Path (Join-Path $provRoot 'no-such-dir') 'ghost.iso')
            Assert-Equal -Expected $false -Actual $p.FileExists
            Assert-Equal -Expected ''     -Actual $p.Url
        }
    }

    Context 'Get-BaseImageProvenance sidecar contents' {

        It 'returns the trimmed filename and url from a two-line sidecar' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'two-line.iso' -SidecarLine @(
                '  ubuntu-24.04.4-desktop-amd64.iso  ',
                "`thttps://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso "
            )
            $p = Get-BaseImageProvenance -BaseImagePath $img
            Assert-Equal -Expected $true -Actual $p.FileExists
            Assert-Equal -Expected 'ubuntu-24.04.4-desktop-amd64.iso' -Actual $p.Filename
            Assert-Equal -Expected 'https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso' -Actual $p.Url
        }

        It 'leaves Url empty when the sidecar carries only the filename line' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'one-line.iso' -SidecarLine @('ubuntu-24.04.4-desktop-amd64.iso')
            $p   = Get-BaseImageProvenance -BaseImagePath $img
            Assert-Equal -Expected $true -Actual $p.FileExists
            Assert-Equal -Expected 'ubuntu-24.04.4-desktop-amd64.iso' -Actual $p.Filename
            Assert-Equal -Expected '' -Actual $p.Url -Because 'a missing line surfaces as an empty string, not $null'
        }

        It 'reports FileExists with empty fields for a zero-byte sidecar' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'empty-sidecar.iso' -SidecarLine @()
            $p   = Get-BaseImageProvenance -BaseImagePath $img
            Assert-Equal -Expected $true -Actual $p.FileExists -Because 'the file is there; it just has nothing in it'
            Assert-Equal -Expected ''    -Actual $p.Filename
            Assert-Equal -Expected ''    -Actual $p.Url
        }

        It 'still reads the url when the filename line is blank' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'blank-first.iso' -SidecarLine @('', 'https://example.test/images/blank-first.iso')
            $p   = Get-BaseImageProvenance -BaseImagePath $img
            Assert-Equal -Expected ''    -Actual $p.Filename
            Assert-Equal -Expected 'https://example.test/images/blank-first.iso' -Actual $p.Url -Because 'line 2 is the url regardless of what line 1 holds'
        }

        It 'ignores everything past the first two lines' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'extra-lines.iso' -SidecarLine @(
                'ubuntu-24.04.4-desktop-amd64.iso',
                'https://example.test/images/extra.iso',
                'sha256:deadbeef',
                'fetched: 2026-07-13'
            )
            $p = Get-BaseImageProvenance -BaseImagePath $img
            Assert-Equal -Expected 'ubuntu-24.04.4-desktop-amd64.iso'      -Actual $p.Filename
            Assert-Equal -Expected 'https://example.test/images/extra.iso' -Actual $p.Url
        }
    }

    Context 'Write-BaseImageProvenance' {

        It 'warns that the provenance FILE is missing when there is no sidecar' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'emit-no-sidecar.iso'
            $e   = Get-ProvenanceEmission -BaseImagePath $img
            Assert-Equal -Expected 1 -Actual $e.Warnings.Count
            Assert-Equal -Expected 'base image provenance file not present' -Actual $e.Warnings[0] `
                -Because 'the "file" wording is what tells the operator Get-Image.ps1 never wrote a sidecar'
            Assert-Equal -Expected 0 -Actual $e.Information.Count -Because 'no Provenance: line when there is nothing to report'
        }

        It 'warns that provenance is not present when the sidecar has no url line' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'emit-no-url.iso' -SidecarLine @('ubuntu-24.04.4-desktop-amd64.iso')
            $e   = Get-ProvenanceEmission -BaseImagePath $img
            Assert-Equal -Expected 1 -Actual $e.Warnings.Count
            Assert-Equal -Expected 'base image provenance not present' -Actual $e.Warnings[0] `
                -Because 'a sidecar that exists but carries no url is a distinct outcome from a missing sidecar'
            Assert-Equal -Expected 0 -Actual $e.Information.Count
        }

        It 'treats a whitespace-only url line as absent' {
            $img = New-ImageFixture -Root $provRoot -ImageName 'emit-blank-url.iso' -SidecarLine @('ubuntu.iso', "   `t ")
            $e   = Get-ProvenanceEmission -BaseImagePath $img
            Assert-Equal -Expected 1 -Actual $e.Warnings.Count
            Assert-Equal -Expected 'base image provenance not present' -Actual $e.Warnings[0]
            Assert-Equal -Expected 0 -Actual $e.Information.Count -Because 'a blank url must never be emitted as "Provenance: "'
        }

        It 'emits the url on the information stream so it lands in the transcript at the default logLevel' {
            $url = 'https://cdn.example.test/images/al2023-kvm.qcow2'
            $img = New-ImageFixture -Root $provRoot -ImageName 'emit-ok.qcow2' -SidecarLine @('al2023-kvm.qcow2', $url)
            $e   = Get-ProvenanceEmission -BaseImagePath $img
            Assert-Equal -Expected 0 -Actual $e.Warnings.Count -Because 'a healthy sidecar produces no warning'
            Assert-Equal -Expected 1 -Actual $e.Information.Count -Because 'verbose would hide the only durable link to the upstream image rev'
            Assert-Equal -Expected "Provenance: $url" -Actual $e.Information[0]
        }

        It 'emits the url even when the sidecar filename line is blank' {
            $url = 'https://cdn.example.test/images/nameless.iso'
            $img = New-ImageFixture -Root $provRoot -ImageName 'emit-nameless.iso' -SidecarLine @('', $url)
            $e   = Get-ProvenanceEmission -BaseImagePath $img
            Assert-Equal -Expected 0 -Actual $e.Warnings.Count
            Assert-Equal -Expected "Provenance: $url" -Actual $e.Information[0] -Because 'only the url gates the audit-trail line, not the filename'
        }
    }
}
