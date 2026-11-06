<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42fd17d5-cc0b-4b81-94e7-4b54d311a679
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test image checksum sha256 decode pester
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
# Pester supplies Describe/It/Should here. Without it every one of those calls
# raises CommandNotFoundException, the engine keeps going, and the file reaches
# its end and exits 0 -- so a harness that shells this out records a PASS for a
# suite that executed no assertion at all. A test that cannot run must say so in
# its exit code; silence that reads as success is worse than no test.
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    Coverage for the image-download integrity gateway: decoding a published
    checksum body, telling a missing entry from an unreachable publisher, and
    the accept/delete decision each of those outcomes drives.
.DESCRIPTION
    Guards a silent-bypass class this gateway is one careless edit away from at
    all times. cloud-images and releases.ubuntu.com serve SHA256SUMS with no
    Content-Type header, so Invoke-WebRequest cannot infer text and returns
    `.Content` as a Byte[]; matching a regex against that array coerces it to
    the space-joined DECIMAL value of every byte, which no checksum pattern can
    match. The lookup then answers "not found" for every file the publisher DOES
    list -- indistinguishable from a genuine miss, and under the permissive
    default it accepts the download unverified while saying so in one warning
    line. The first Describe pins the decode; the rest pin the three outcomes
    that a single $null return cannot keep apart.

    No network and no mocks: bodies are literals, and the fetch path is
    exercised against a raw loopback socket that answers HTTP by hand -- with
    the Content-Type header deliberately omitted, so the responder reproduces
    the publisher behavior that triggers the class.

    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Run: Invoke-Pester -Path host/modules/Yuruna.Image.Tests.ps1
#>

BeforeAll {
$here          = Split-Path -Parent $PSCommandPath
$ImageRepoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $ImageRepoRoot 'host/modules/Yuruna.Image.psm1') -Force -DisableNameChecking -Global

Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'test/modules/Test.Assert.psm1') -Force -Global -DisableNameChecking

# A real SHA256SUMS body: publisher shape (`<sha256> *<filename>`, the asterisk
# being the binary-mode marker), LF line endings, trailing newline.
$ImageSumsBody = @(
    '2889120db0432e8029f8f01622efb40ce964e434ba2c81e98937ad1e2616e4f5 *resolute-server-cloudimg-arm64.manifest'
    '3e113fdd41f39e13729375173bb2ae793f87dc6db4294e5251ff2476971788ba *resolute-server-cloudimg-arm64.img'
    'b5b2cf1d0a4c4f0dd5b1f0e0a6a6e0f2fd1a2f7f6c3ff0a1a2d3c4b5a6978869 *resolute-server-cloudimg-amd64.img'
) -join "`n"
$ImageSumsBody += "`n"
$script:ImageTargetName = 'resolute-server-cloudimg-arm64.img'
$script:ImageTargetHash = '3e113fdd41f39e13729375173bb2ae793f87dc6db4294e5251ff2476971788ba'
$script:ImageSumsBytes  = [System.Text.Encoding]::UTF8.GetBytes($ImageSumsBody)

# One loopback responder serves the checksum list and the image: a request
# naming SHA256SUMS gets the list (or its status), any other the image bytes.
# Neither reply carries a Content-Type, exactly as the Ubuntu mirrors serve
# SHA256SUMS. That omission is what made Invoke-WebRequest hand `.Content` back
# as a Byte[] instead of a string.
function Start-ChecksumResponder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: starts a loopback responder each case stops itself.')]
    param(
        [string]$SumsBody = '',
        [int]$SumsStatus = 200,
        [string]$ImageBody = '',
        [int]$RequestCount = 1
    )
    return Start-YurunaTestHttpResponder -RequestCount $RequestCount -Route ([ordered]@{
            'SHA256SUMS' = (New-YurunaTestHttpReply -StatusCode $SumsStatus -Body $SumsBody)
            '.'          = (New-YurunaTestHttpReply -Body $ImageBody)
        })
}

function New-ImageTestDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a throwaway temp directory each case removes itself.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return New-YurunaTestTempDir -Prefix 'yuruna-image-test'
}
}

Describe 'A published checksum body is decoded, never coerced' {

    It 'finds the hash when the body arrived as raw bytes' {
        # A Byte[] is exactly what a Content-Type-less response produces, and
        # coercing it instead of decoding it makes every lookup answer "no entry".
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $script:ImageTargetName -ChecksumBody $script:ImageSumsBytes
        Assert-StringEqual -Expected 'found' -Actual $r.State
        Assert-StringEqual -Expected $script:ImageTargetHash -Actual $r.Hash
    }

    It 'finds the same hash when the body arrived as text' {
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $script:ImageTargetName -ChecksumBody $ImageSumsBody
        Assert-StringEqual -Expected 'found' -Actual $r.State
        Assert-StringEqual -Expected $script:ImageTargetHash -Actual $r.Hash
    }

    It 'finds the same hash when a pipeline unrolled the bytes into an object[]' {
        # A retry wrapper that captures `& $ScriptBlock 2>&1` unrolls a Byte[]
        # through the pipeline into individual bytes, so a `-is [byte[]]` guard
        # is FALSE for the very body that needs decoding.
        $unrolled = @($script:ImageSumsBytes | ForEach-Object { $_ })
        Assert-True ($unrolled -isnot [byte[]]) 'the fixture reproduces the unrolled shape'
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $script:ImageTargetName -ChecksumBody $unrolled
        Assert-StringEqual -Expected 'found' -Actual $r.State
        Assert-StringEqual -Expected $script:ImageTargetHash -Actual $r.Hash
    }

    It 'ignores a byte-order mark at the head of the body' {
        $withBom = [byte[]](@(0xEF, 0xBB, 0xBF) + $script:ImageSumsBytes)
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName 'resolute-server-cloudimg-arm64.manifest' -ChecksumBody $withBom
        Assert-StringEqual -Expected 'found' -Actual $r.State
        Assert-StringEqual -Expected '2889120db0432e8029f8f01622efb40ce964e434ba2c81e98937ad1e2616e4f5' -Actual $r.Hash
    }

    It 'shows why coercing the bytes to a string could never match' {
        # Guards the class rather than the instance: if someone reintroduces a
        # bare [string] cast, this is the shape they would be matching against.
        $coerced = [string]$script:ImageSumsBytes
        Assert-True ($coerced -notmatch [regex]::Escape($script:ImageTargetName)) 'the coerced form carries no filename'
        Assert-True ($coerced -match '^\d+ \d+ ') 'it is the space-joined decimal value of every byte'
    }
}

Describe 'A missing entry and an unreachable publisher are different answers' {

    It 'reports absent, naming the file, when the list has no line for it' {
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName 'not-published.img' -ChecksumBody $ImageSumsBody
        Assert-StringEqual -Expected 'absent' -Actual $r.State
        Assert-StringEqual -Expected '' -Actual $r.Hash
        Assert-True ($r.Detail -match 'not-published\.img') "the detail names the file, got '$($r.Detail)'"
    }

    It 'reports absent, carrying the status, when the publisher serves a 404' {
                $bound = Start-ChecksumResponder -SumsStatus 404 -SumsBody 'not here'
        try {
            $r = Get-ImageChecksumLine -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" `
                -TargetFileName $script:ImageTargetName -WarningAction SilentlyContinue
            Assert-StringEqual -Expected 'absent' -Actual $r.State
            Assert-StringEqual -Expected 404 -Actual $r.Status
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
        }
    }

    It 'reports unreachable when nothing is listening at the address' {
        # A closed loopback port refuses immediately, so the whole retry budget
        # is spent in milliseconds; MaxAttempts 1 keeps even that off the clock.
        $port  = Get-YurunaTestFreePort
        $dir = New-ImageTestDirectory
        try {
            $r = Get-PublishedChecksumBody -ChecksumUrl "http://127.0.0.1:$port/SHA256SUMS" `
                -DestinationPath (Join-Path $dir 'SHA256SUMS') -MaxAttempts 1 -TimeoutSec 5
            Assert-StringEqual -Expected 'unreachable' -Actual $r.State
            Assert-True ($r.Status -eq 0) 'a refused connection carries no HTTP status'
            Assert-True ($r.Detail -ne '') 'and the reason survives into the result'
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'reads the hash back over a response that carries no Content-Type' {
        # End-to-end through the fetch path, against the exact publisher
        # behavior -- a 200 with no Content-Type -- that broke the lookup.
                $bound = Start-ChecksumResponder -SumsBody $ImageSumsBody
        try {
            $r = Get-ImageChecksumLine -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -TargetFileName $script:ImageTargetName
            Assert-StringEqual -Expected 'found' -Actual $r.State
            Assert-StringEqual -Expected $script:ImageTargetHash -Actual $r.Hash
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
        }
    }
}

Describe 'The filename match is anchored to a whole checksum line' {

    It 'does not accept a longer filename this one is a prefix of' {
        # An unanchored substring search hands back the hash of a DIFFERENT
        # artifact, which then reads as a mismatch against a perfectly good file.
        $body = 'aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899 *resolute-server-cloudimg-arm64.img.torrent' + "`n"
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $script:ImageTargetName -ChecksumBody $body
        Assert-StringEqual -Expected 'absent' -Actual $r.State
    }

    It 'does not accept a line whose leading token is not a hash' {
        $body = "# resolute-server-cloudimg-arm64.img is published separately`n"
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $script:ImageTargetName -ChecksumBody $body
        Assert-StringEqual -Expected 'absent' -Actual $r.State
    }
}

Describe 'The download policy is permissive by default and strict only on request' {

    It 'accepts a download the publisher does list' {
        # The whole chain end to end: transfer, Content-Type-less checksum
        # fetch, decode, per-file lookup, hash compare.
        $payload = 'yuruna image bytes'
        $hash    = [BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($payload))
        ).Replace('-', '').ToLowerInvariant()
        $dir   = New-ImageTestDirectory
                $bound = Start-ChecksumResponder -ImageBody $payload `
            -SumsBody "$hash *image.img`n" -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -RetryBudgetSeconds 0 `
                -OnMismatch 'WarnAndDelete' `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True $ok 'a verified download is accepted'
            Assert-True (Test-Path -LiteralPath $dest) 'and the file is kept'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'deletes a download whose hash does not match the published one' {
        # The enforcing arm of the policy: it can only fire when the lookup
        # actually yields a hash, so it fails silently open if the decode breaks.
        $dir   = New-ImageTestDirectory
                $bound = Start-ChecksumResponder -ImageBody 'tampered bytes' `
            -SumsBody ('00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *image.img' + "`n") -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -RetryBudgetSeconds 0 `
                -OnMismatch 'WarnAndDelete' `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True (-not $ok) 'a mismatch fails the caller'
            Assert-True (-not (Test-Path -LiteralPath $dest)) 'and the tampered file is removed'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'keeps the file when the publisher lists no entry for it' {
        # The module default must stay permissive: the AL2023 bring-ups on all
        # three host types reach a no-checksum branch whenever the release
        # directory publishes no sidecar, and a strict default would fail them.
        $dir   = New-ImageTestDirectory
                $bound = Start-ChecksumResponder -ImageBody 'bytes' `
            -SumsBody $ImageSumsBody -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -ChecksumTargetFileName 'not-published.img' `
                -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True $ok 'an unlisted file is accepted under the default policy'
            Assert-True (Test-Path -LiteralPath $dest) 'and the download is kept'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'deletes the file when the caller opts in to strict on a missing entry' {
        $dir   = New-ImageTestDirectory
                $bound = Start-ChecksumResponder -ImageBody 'bytes' `
            -SumsBody $ImageSumsBody -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -ChecksumTargetFileName 'not-published.img' `
                -OnMissingChecksum 'WarnAndDelete' -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True (-not $ok) 'the strict policy refuses the artifact'
            Assert-True (-not (Test-Path -LiteralPath $dest)) 'and removes it'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'keeps the file when the checksum publisher could not be reached' {
        # A 200 carrying no bytes is a truncating proxy or a captive portal, not
        # a publisher that ships no hash -- so it is unreachable, and the default
        # for that is permissive too.
        $dir   = New-ImageTestDirectory
                $bound = Start-ChecksumResponder -ImageBody 'bytes' -SumsBody '' -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True $ok 'an unreachable checksum file is accepted under the default policy'
            Assert-True (Test-Path -LiteralPath $dest) 'and the download is kept'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'still compares the caller-supplied hash when the checksum file is unreachable' {
        # The caller handed over the hash, so an unreachable published list costs
        # only the signature leg. Routing that outcome through the unreachable
        # policy would accept bytes the caller had everything it needed to reject.
        $dir   = New-ImageTestDirectory
                $bound = Start-ChecksumResponder -ImageBody 'tampered bytes' -SumsBody '' -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ExpectedSha256 $script:ImageTargetHash -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" `
                -VerifyUbuntuSignature -OnMismatch 'WarnAndDelete' -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True (-not $ok) 'the supplied hash is compared, and it does not match'
            Assert-True (-not (Test-Path -LiteralPath $dest)) 'and the file is removed'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'keeps the file when no checksum source was supplied at all' {
        $dir   = New-ImageTestDirectory
                $bound = Start-ChecksumResponder -ImageBody 'bytes' -RequestCount 1
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl $null -OnMismatch 'WarnAndDelete' -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True $ok 'the caller opted out of verification, which is not a failure'
            Assert-True (Test-Path -LiteralPath $dest) 'and the download is kept'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }
}

# gpg is never required, but where gpg and the pinned keyring are present a
# signature that cannot be fetched or checked is refused like a wrong one:
# whoever can block the signature must not be able to switch the check off.
Describe 'A checksum signature that cannot be checked is refused where it could have been' {
    BeforeAll {
        $script:SumsDir = New-YurunaTestTempDir -Prefix 'yuruna-sig-test'
        $script:SumsPath = Join-Path $script:SumsDir 'checksums.SHA256SUMS'
        [System.IO.File]::WriteAllBytes($script:SumsPath, $script:ImageSumsBytes)
    }
    AfterAll { Remove-YurunaTestTempDir $script:SumsDir }

    It 'proceeds on the hash alone on a host without gpg' {
        Mock -ModuleName Yuruna.Image Get-Command { $null } -ParameterFilter { $Name -eq 'gpg' }
        Test-PublishedChecksumSignature -ChecksumUrl 'http://127.0.0.1:9/SHA256SUMS' -ChecksumFilePath $script:SumsPath |
            Should -BeExactly 'unverified'
    }

    It 'calls a signature it could not fetch unavailable, not unverified' -Skip:(-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
        Mock -ModuleName Yuruna.Image Invoke-WebRequest { throw 'connection refused' }
        Test-PublishedChecksumSignature -ChecksumUrl 'http://127.0.0.1:9/SHA256SUMS' -ChecksumFilePath $script:SumsPath |
            Should -BeExactly 'unavailable'
    }

    It 'calls a fetched signature gpg cannot verify unavailable' -Skip:(-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
        Mock -ModuleName Yuruna.Image Invoke-WebRequest { [System.IO.File]::WriteAllText($OutFile, 'not a signature') }
        Test-PublishedChecksumSignature -ChecksumUrl 'http://127.0.0.1:9/SHA256SUMS' -ChecksumFilePath $script:SumsPath |
            Should -BeExactly 'unavailable'
    }

    It 'refuses the download under the mismatch policy when the signature cannot be checked' -Skip:(-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
        $payload = 'yuruna image bytes'
        $hash    = [BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($payload))
        ).Replace('-', '').ToLowerInvariant()
        $dir   = New-ImageTestDirectory
        # The signature request matches the SHA256SUMS route, so gpg is handed
        # the checksum text as a signature, which it cannot verify.
        $bound = Start-ChecksumResponder -ImageBody $payload `
            -SumsBody "$hash *image.img`n" -RequestCount 3
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -VerifyUbuntuSignature -RetryBudgetSeconds 0 `
                -OnMismatch 'WarnAndDelete' `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True (-not $ok) 'a checksum list whose signature cannot be checked is not trusted'
            Assert-True (-not (Test-Path -LiteralPath $dest)) 'and the file is removed'
        } finally {
            $null = Stop-YurunaTestHttpResponder $bound
            Remove-YurunaTestTempDir $dir
        }
    }
}

Describe 'image preparation returns only its boolean outcome' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $repoRoot 'host/modules/Yuruna.HostDownload.psm1') -Global -DisableNameChecking
        Import-Module (Join-Path $repoRoot 'host/modules/Yuruna.DownloadAgent.psm1') -Global -DisableNameChecking
    }

    BeforeEach {
        $script:AgentOutcome = 'downloaded'
        $script:FixtureImage = @{
            HostType = 'host.windows.hyper-v'; Arch = 'amd64'; SourceUrl = 'https://example.invalid/image.img'
            ChecksumUrl = 'https://example.invalid/SHA256SUMS'; DownloadDir = $TestDrive
            BaseImageName = 'fixture-extension'; BaseImageFile = (Join-Path $TestDrive 'fixture-extension.vhdx')
            OriginFile = (Join-Path $TestDrive 'fixture-extension.txt'); Format = 'vhdx'
        }
        Mock -ModuleName Yuruna.Image Resolve-DownloadAgentEndpoint { 'http://127.0.0.1:1' }
        Mock -ModuleName Yuruna.Image Request-DownloadAgentImage {
            if ($script:AgentOutcome -eq 'downloaded') { [IO.File]::WriteAllBytes($StagingPath, [byte[]]@(1, 2, 3, 4)) }
            @{ outcome = $script:AgentOutcome; sourceUrl = 'https://example.invalid/image.img'; filename = 'image.img'; lastModified = '' }
        }
        Mock -ModuleName Yuruna.Image Test-DownloadAlreadyCurrent { $false }
        Mock -ModuleName Yuruna.Image Write-ImageSentinel { }
        Mock -ModuleName Yuruna.Image Save-ImageWithChecksum { throw 'The fixture agent already supplied the bytes.' }
        Mock -ModuleName Yuruna.Image Convert-Qcow2ToVhdx { $false }
        Mock -ModuleName Yuruna.Image Resolve-QemuImgCommand { $null }
    }

    It 'rejects an undersized agent download with one false value' {
        $result = Save-UbuntuExtensionImage -Image $script:FixtureImage -MinimumBytes 100 -ErrorAction SilentlyContinue
        Assert-StringEqual 'Boolean' $result.GetType().Name 'agent progress must not make a failed download truthy'
        Assert-False $result
        Should -Invoke -ModuleName Yuruna.Image Convert-Qcow2ToVhdx -Times 0 -Exactly
    }

    It 'rejects a failed conversion after agent progress with one false value' {
        $result = Save-UbuntuExtensionImage -Image $script:FixtureImage -MinimumBytes 1 -ErrorAction SilentlyContinue
        Assert-StringEqual 'Boolean' $result.GetType().Name 'agent progress must not make a failed conversion truthy'
        Assert-False $result
        Should -Invoke -ModuleName Yuruna.Image Convert-Qcow2ToVhdx -Times 1 -Exactly
    }

    It 'reports an already-current agent result with one true value' {
        $script:AgentOutcome = 'skipped'
        $result = Save-UbuntuExtensionImage -Image $script:FixtureImage -MinimumBytes 1
        Assert-StringEqual 'Boolean' $result.GetType().Name 'skip progress belongs outside the return stream'
        Assert-True $result
    }

    It 'reports a completed qcow2 promotion with one true value' {
        $script:FixtureImage.Format = 'qcow2'
        $script:FixtureImage.BaseImageFile = Join-Path $TestDrive 'fixture-extension.qcow2'
        $result = Save-UbuntuExtensionImage -Image $script:FixtureImage -MinimumBytes 1
        Assert-StringEqual 'Boolean' $result.GetType().Name 'promotion progress belongs outside the return stream'
        Assert-True $result
        Assert-True ([IO.File]::Exists($script:FixtureImage.BaseImageFile))
    }

    It 'rejects an unavailable resize tool with one false value' {
        $result = Expand-ExtensionVmDisk -Path (Join-Path $TestDrive 'fixture.qcow2') -SizeBytes 256GB -Format qcow2 -WarningAction SilentlyContinue
        Assert-StringEqual 'Boolean' $result.GetType().Name 'resize progress must not bypass the caller failure gate'
        Assert-False $result
    }
}

Describe 'The Windows 11 ISO is fetched on the resumable download engine' {
    # Microsoft serves the ISO from a short-lived signed URL and the file is
    # multi-gigabyte: a transport that cannot resume starts a cut-short transfer
    # over, and one outside the host driver's wrapper never sees the caching
    # proxy. The fetch step of each Fido-driven host script is sliced out and
    # run with the engine stood in by a function that writes what it was asked
    # to fetch, and with BITS and Invoke-WebRequest stood in by functions that
    # refuse, so the staged bytes can only have come through Save-CachedHttpUri.
    It 'stages the ISO through Save-CachedHttpUri on <Driver>' -ForEach @(
        @{ Driver = 'windows.hyper-v'; Script = 'host/windows.hyper-v/guest.windows.11/Get-Image.ps1' }
        @{ Driver = 'macos.utm';       Script = 'host/macos.utm/guest.windows.11/Get-Image.ps1' }
    ) {
        $source = Get-Content -Raw -LiteralPath (Join-Path $ImageRepoRoot $Script)
        $notice = $source.IndexOf("-Key 'host.operator_26d58e13fc858352')", [StringComparison]::Ordinal)
        $start = if ($notice -ge 0) { $source.IndexOf("`n", $notice) + 1 } else { -1 }
        $end = if ($start -gt 0) { $source.IndexOf('if (-not (Test-Path $downloadFile))', $start, [StringComparison]::Ordinal) } else { -1 }
        Assert-True ($start -gt 0 -and $end -gt $start) "$Script still frames its ISO fetch between the download notice and the staged-file check"
        $body = $source.Substring($start, $end - $start)
        $downloadFile = Join-Path $TestDrive "$Driver.downloaded.iso"
        $url = 'https://software.download.example.invalid/Win11.iso?t=fixture'
        $fixture = Join-Path $TestDrive "$Driver.fetch.ps1"
        $header = @(
            'function Format-YurunaOperatorMessage { param($Key, $Arguments) $null = $Arguments; $Key }'
            'function Save-CachedHttpUri { param([string]$Uri, [string]$OutFile) [IO.File]::WriteAllText($OutFile, "engine $Uri") }'
            "function Start-BitsTransfer { throw 'BITS is not the ISO transport' }"
            "function Invoke-WebRequest { throw 'Invoke-WebRequest is not the ISO transport' }"
            "`$downloadUrl = '$url'"
            "`$downloadFile = '" + $downloadFile.Replace("'", "''") + "'"
        )
        [IO.File]::WriteAllText($fixture, ($header -join "`n") + "`n" + $body + "`nexit 0`n")
        $output = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $fixture 2>&1 | ForEach-Object { "$_" })
        Assert-Equal 0 $LASTEXITCODE "the sliced fetch of $Script must complete; output: $($output -join ' | ')"
        Assert-True ([IO.File]::Exists($downloadFile)) "$Script stages the ISO at its download path"
        Assert-StringEqual "engine $url" ([IO.File]::ReadAllText($downloadFile)) "on $Driver the bytes must come from Save-CachedHttpUri, the engine every other image fetch uses"
    }
}
