<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42970ec1-329c-40bb-8c37-f071deec7518
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
    the publisher behaviour that triggers the class.

    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Run: Invoke-Pester -Path host/modules/Yuruna.Image.Tests.ps1
#>

$here          = Split-Path -Parent $PSCommandPath
$ImageRepoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $ImageRepoRoot 'host/modules/Yuruna.Image.psm1') -Force -DisableNameChecking -Global

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

# A real SHA256SUMS body: publisher shape (`<sha256> *<filename>`, the asterisk
# being the binary-mode marker), LF line endings, trailing newline.
$ImageSumsBody = @(
    '2889120db0432e8029f8f01622efb40ce964e434ba2c81e98937ad1e2616e4f5 *resolute-server-cloudimg-arm64.manifest'
    '3e113fdd41f39e13729375173bb2ae793f87dc6db4294e5251ff2476971788ba *resolute-server-cloudimg-arm64.img'
    'b5b2cf1d0a4c4f0dd5b1f0e0a6a6e0f2fd1a2f7f6c3ff0a1a2d3c4b5a6978869 *resolute-server-cloudimg-amd64.img'
) -join "`n"
$ImageSumsBody += "`n"
$ImageTargetName = 'resolute-server-cloudimg-arm64.img'
$ImageTargetHash = '3e113fdd41f39e13729375173bb2ae793f87dc6db4294e5251ff2476971788ba'
$ImageSumsBytes  = [System.Text.Encoding]::UTF8.GetBytes($ImageSumsBody)

# One-shot HTTP responder on loopback. A raw TcpListener rather than
# HttpListener: HttpListener needs a URL ACL (or Administrator) to bind, which
# an unattended test run cannot assume. The socket is bound by the caller and
# handed to the job already listening, so the request can never arrive before
# there is something to accept it.
function Get-LoopbackChecksumListener {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    return @{
        Listener = $listener
        BaseUrl  = "http://127.0.0.1:$(([System.Net.IPEndPoint]$listener.LocalEndpoint).Port)"
    }
}

function Get-ChecksumResponderJob {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'Every value arrives through -ArgumentList into the job param() block; the analyzer does not follow that path.')]
    param(
        [System.Net.Sockets.TcpListener]$Listener,
        [string]$SumsBody = '',
        [int]$SumsStatus = 200,
        [string]$ImageBody = '',
        [int]$RequestCount = 1
    )
    return Start-ThreadJob -ScriptBlock {
        param($Listener, $SumsBody, $SumsStatus, $ImageBody, $RequestCount)
        try {
            for ($i = 0; $i -lt $RequestCount; $i++) {
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream  = $client.GetStream()
                    $buffer  = [byte[]]::new(8192)
                    $read    = $stream.Read($buffer, 0, $buffer.Length)
                    $request = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                    if ($request -match 'SHA256SUMS') {
                        $status = $SumsStatus
                        $body   = $SumsBody
                    } else {
                        $status = 200
                        $body   = $ImageBody
                    }
                    $reason  = if ($status -eq 200) { 'OK' } else { 'Not Found' }
                    $payload = [System.Text.Encoding]::UTF8.GetBytes($body)
                    # NO Content-Type header, exactly as the Ubuntu mirrors serve
                    # SHA256SUMS. That omission is what made Invoke-WebRequest
                    # hand `.Content` back as a Byte[] instead of a string.
                    $head      = "HTTP/1.1 $status $reason`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
                    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($headBytes, 0, $headBytes.Length)
                    $stream.Write($payload, 0, $payload.Length)
                    $stream.Flush()
                } finally { $client.Close() }
            }
        } finally { $Listener.Stop() }
    } -ArgumentList $Listener, $SumsBody, $SumsStatus, $ImageBody, $RequestCount
}

function New-ImageTestDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a throwaway temp directory each case removes itself.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-image-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

Describe 'A published checksum body is decoded, never coerced' {

    It 'finds the hash when the body arrived as raw bytes' {
        # A Byte[] is exactly what a Content-Type-less response produces, and
        # coercing it instead of decoding it makes every lookup answer "no entry".
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $ImageTargetName -ChecksumBody $ImageSumsBytes
        Assert-Equal -Expected 'found' -Actual $r.State
        Assert-Equal -Expected $ImageTargetHash -Actual $r.Hash
    }

    It 'finds the same hash when the body arrived as text' {
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $ImageTargetName -ChecksumBody $ImageSumsBody
        Assert-Equal -Expected 'found' -Actual $r.State
        Assert-Equal -Expected $ImageTargetHash -Actual $r.Hash
    }

    It 'finds the same hash when a pipeline unrolled the bytes into an object[]' {
        # A retry wrapper that captures `& $ScriptBlock 2>&1` unrolls a Byte[]
        # through the pipeline into individual bytes, so a `-is [byte[]]` guard
        # is FALSE for the very body that needs decoding.
        $unrolled = @($ImageSumsBytes | ForEach-Object { $_ })
        Assert-True ($unrolled -isnot [byte[]]) 'the fixture reproduces the unrolled shape'
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $ImageTargetName -ChecksumBody $unrolled
        Assert-Equal -Expected 'found' -Actual $r.State
        Assert-Equal -Expected $ImageTargetHash -Actual $r.Hash
    }

    It 'ignores a byte-order mark at the head of the body' {
        $withBom = [byte[]](@(0xEF, 0xBB, 0xBF) + $ImageSumsBytes)
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName 'resolute-server-cloudimg-arm64.manifest' -ChecksumBody $withBom
        Assert-Equal -Expected 'found' -Actual $r.State
        Assert-Equal -Expected '2889120db0432e8029f8f01622efb40ce964e434ba2c81e98937ad1e2616e4f5' -Actual $r.Hash
    }

    It 'shows why coercing the bytes to a string could never match' {
        # Guards the class rather than the instance: if someone reintroduces a
        # bare [string] cast, this is the shape they would be matching against.
        $coerced = [string]$ImageSumsBytes
        Assert-True ($coerced -notmatch [regex]::Escape($ImageTargetName)) 'the coerced form carries no filename'
        Assert-True ($coerced -match '^\d+ \d+ ') 'it is the space-joined decimal value of every byte'
    }
}

Describe 'A missing entry and an unreachable publisher are different answers' {

    It 'reports absent, naming the file, when the list has no line for it' {
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName 'not-published.img' -ChecksumBody $ImageSumsBody
        Assert-Equal -Expected 'absent' -Actual $r.State
        Assert-Equal -Expected '' -Actual $r.Hash
        Assert-True ($r.Detail -match 'not-published\.img') "the detail names the file, got '$($r.Detail)'"
    }

    It 'reports absent, carrying the status, when the publisher serves a 404' {
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -SumsStatus 404 -SumsBody 'not here'
        try {
            $r = Get-ImageChecksumLine -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" `
                -TargetFileName $ImageTargetName -WarningAction SilentlyContinue
            Assert-Equal -Expected 'absent' -Actual $r.State
            Assert-Equal -Expected 404 -Actual $r.Status
        } finally { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    It 'reports unreachable when nothing is listening at the address' {
        # A closed loopback port refuses immediately, so the whole retry budget
        # is spent in milliseconds; MaxAttempts 1 keeps even that off the clock.
        $bound = Get-LoopbackChecksumListener
        $port  = ([System.Net.IPEndPoint]$bound.Listener.LocalEndpoint).Port
        $bound.Listener.Stop()
        $dir = New-ImageTestDirectory
        try {
            $r = Get-PublishedChecksumBody -ChecksumUrl "http://127.0.0.1:$port/SHA256SUMS" `
                -DestinationPath (Join-Path $dir 'SHA256SUMS') -MaxAttempts 1 -TimeoutSec 5
            Assert-Equal -Expected 'unreachable' -Actual $r.State
            Assert-True ($r.Status -eq 0) 'a refused connection carries no HTTP status'
            Assert-True ($r.Detail -ne '') 'and the reason survives into the result'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reads the hash back over a response that carries no Content-Type' {
        # End-to-end through the fetch path, against the exact publisher
        # behaviour -- a 200 with no Content-Type -- that broke the lookup.
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -SumsBody $ImageSumsBody
        try {
            $r = Get-ImageChecksumLine -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -TargetFileName $ImageTargetName
            Assert-Equal -Expected 'found' -Actual $r.State
            Assert-Equal -Expected $ImageTargetHash -Actual $r.Hash
        } finally { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'The filename match is anchored to a whole checksum line' {

    It 'does not accept a longer filename this one is a prefix of' {
        # An unanchored substring search hands back the hash of a DIFFERENT
        # artifact, which then reads as a mismatch against a perfectly good file.
        $body = 'aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899 *resolute-server-cloudimg-arm64.img.torrent' + "`n"
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $ImageTargetName -ChecksumBody $body
        Assert-Equal -Expected 'absent' -Actual $r.State
    }

    It 'does not accept a line whose leading token is not a hash' {
        $body = "# resolute-server-cloudimg-arm64.img is published separately`n"
        $r = Get-ImageChecksumLine -ChecksumUrl 'https://example.invalid/SHA256SUMS' `
            -TargetFileName $ImageTargetName -ChecksumBody $body
        Assert-Equal -Expected 'absent' -Actual $r.State
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
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -ImageBody $payload `
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
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'deletes a download whose hash does not match the published one' {
        # The enforcing arm of the policy: it can only fire when the lookup
        # actually yields a hash, so it fails silently open if the decode breaks.
        $dir   = New-ImageTestDirectory
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -ImageBody 'tampered bytes' `
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
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the file when the publisher lists no entry for it' {
        # The module default must stay permissive: the AL2023 bring-ups on all
        # three host types reach a no-checksum branch whenever the release
        # directory publishes no sidecar, and a strict default would fail them.
        $dir   = New-ImageTestDirectory
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -ImageBody 'bytes' `
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
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'deletes the file when the caller opts in to strict on a missing entry' {
        $dir   = New-ImageTestDirectory
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -ImageBody 'bytes' `
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
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the file when the checksum publisher could not be reached' {
        # A 200 carrying no bytes is a truncating proxy or a captive portal, not
        # a publisher that ships no hash -- so it is unreachable, and the default
        # for that is permissive too.
        $dir   = New-ImageTestDirectory
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -ImageBody 'bytes' -SumsBody '' -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True $ok 'an unreachable checksum file is accepted under the default policy'
            Assert-True (Test-Path -LiteralPath $dest) 'and the download is kept'
        } finally {
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still compares the caller-supplied hash when the checksum file is unreachable' {
        # The caller handed over the hash, so an unreachable published list costs
        # only the signature leg. Routing that outcome through the unreachable
        # policy would accept bytes the caller had everything it needed to reject.
        $dir   = New-ImageTestDirectory
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -ImageBody 'tampered bytes' -SumsBody '' -RequestCount 2
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ExpectedSha256 $ImageTargetHash -ChecksumUrl "$($bound.BaseUrl)/SHA256SUMS" `
                -VerifyUbuntuSignature -OnMismatch 'WarnAndDelete' -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True (-not $ok) 'the supplied hash is compared, and it does not match'
            Assert-True (-not (Test-Path -LiteralPath $dest)) 'and the file is removed'
        } finally {
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the file when no checksum source was supplied at all' {
        $dir   = New-ImageTestDirectory
        $bound = Get-LoopbackChecksumListener
        $job   = Get-ChecksumResponderJob -Listener $bound.Listener -ImageBody 'bytes' -RequestCount 1
        $dest = Join-Path $dir 'image.img'
        try {
            $ok = Save-ImageWithChecksum -SourceUrl "$($bound.BaseUrl)/image.img" -DestPath $dest `
                -ChecksumUrl $null -OnMismatch 'WarnAndDelete' -RetryBudgetSeconds 0 `
                -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
            Assert-True $ok 'the caller opted out of verification, which is not a failure'
            Assert-True (Test-Path -LiteralPath $dest) 'and the download is kept'
        } finally {
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
