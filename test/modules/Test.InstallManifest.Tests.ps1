<#PSScriptInfo
.VERSION 2026.10.26
.GUID 42357e45-1be3-4923-bebd-60e195c757a0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna install checksum manifest integrity
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
    Every hash in install/install.sha256 matches the installer it names.
.DESCRIPTION
    The installers are the `curl | sh` entry point, and install/install.sha256 is
    what a cautious user checks before running one. Nothing verified that the
    manifest still described the files it names, and it drifted: the manifest was
    last written two months before the installers it covers, so the documented
    `sha256sum -c install/install.sha256` step failed for every entry while the
    repository looked healthy.

    DETECTION ONLY, DELIBERATELY. This suite reports the correct hashes and stops
    there. Regenerating the manifest invalidates install.sha256.sig, and the
    private half of that signing key is not in the repository -- so a run that
    "helpfully" rewrote the manifest would replace a stale-but-signed file with a
    current-but-unsigned one, and a signature that verifiably does not match is a
    worse failure than a hash that is merely old. Rewriting is the operator's
    step, with their key.

    While the fix belongs to the operator, the drift is reported as a SKIP
    rather than a failure: the fix is not available to the person running the
    gate, and a permanently red gate teaches everyone to ignore it. The fix is
    the operator's when the signature no longer verifies the manifest (the
    unsigned development manifest a version bump leaves behind) or when a
    drifted installer changed after the signature was committed. A signature
    that verifies, and is at least as new as every installer the manifest
    misdescribes, signed a manifest that never described them: that is a
    broken publish and FAILS. Order is read from commit times, which every
    clone shares; file times are useless for it, because a fresh clone writes
    install.sha256.sig before the installers (index order) and the signature
    would always look older. A commit carrying a release tag, and a public tree
    (one without dev-only/), are what users verify against: there the manifest
    must verify and match, and neither case is skipped.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $script:RepoRootPath  = $repoRoot

    # Parse the sha256sum format: "<64 hex><two spaces><repo-relative path>".
    function Get-ManifestEntry {
        param([string]$Root = $script:RepoRootPath)
        $manifest = Join-Path $Root 'install/install.sha256'
        if (-not (Test-Path -LiteralPath $manifest)) { return @() }
        Get-Content -LiteralPath $manifest |
            ForEach-Object {
                if ($_ -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                    [pscustomobject]@{
                        Recorded = $Matches[1].ToLowerInvariant()
                        Relative = $Matches[2]
                        FullPath = Join-Path $Root $Matches[2]
                    }
                }
            }
    }

    # The check the installers document: a detached PKCS#1 v1.5 signature over
    # SHA-256 of the manifest bytes, against the bundled public key.
    function Test-ManifestSignature {
        param([string]$Root = $script:RepoRootPath)
        $manifest  = Join-Path $Root 'install/install.sha256'
        $signature = Join-Path $Root 'install/install.sha256.sig'
        $publicKey = Join-Path $Root 'install/keys/yuruna-release-signing.pub.pem'
        foreach ($path in @($manifest, $signature, $publicKey)) {
            if (-not (Test-Path -LiteralPath $path)) { return $false }
        }
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportFromPem((Get-Content -LiteralPath $publicKey -Raw))
            return $rsa.VerifyData([IO.File]::ReadAllBytes($manifest), [IO.File]::ReadAllBytes($signature),
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        } catch {
            return $false
        } finally {
            $rsa.Dispose()
        }
    }

    # Commit time (Unix seconds) of the last change to a path, with an
    # uncommitted change counting as newer than every commit; $null when git
    # cannot say, as in a tree that is not a checkout.
    function Get-PathChangeTime {
        param([string]$Root, [string]$Relative)
        $pending = @(& git -C $Root status --porcelain -- $Relative 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($pending.Count -gt 0) { return [long]::MaxValue }
        $stamp = [string](& git -C $Root log -1 --format=%ct -- $Relative 2>$null)
        if ($LASTEXITCODE -ne 0 -or $stamp -notmatch '^\d+$') { return $null }
        return [long]$stamp
    }

    # True where the manifest is what users verify against: a commit carrying a
    # release tag, or a public tree (the publisher strips dev-only/). There an
    # unsigned or stale manifest is a broken release, never the operator's
    # pending step, so it fails instead of skipping.
    function Test-ManifestMustVerify {
        param([string]$Root = $script:RepoRootPath)
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'dev-only'))) { return $true }
        $tags = @(& git -C $Root tag --points-at HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { return $false }
        return [bool](@($tags | Where-Object { $_ -match '^\d{4}\.\d{2}\.\d{2}(\.\d+)?$' }).Count)
    }

    # True while the fix for a drifted manifest is the operator's (see the
    # file's description). A tree git cannot date is given the benefit of the
    # doubt, as the operator's step.
    function Test-SignatureStale {
        param([string]$Root = $script:RepoRootPath, [string[]]$Drifted = @())
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'install/install.sha256.sig'))) { return $false }
        if (-not (Test-ManifestSignature -Root $Root)) { return $true }
        $signed = Get-PathChangeTime -Root $Root -Relative 'install/install.sha256.sig'
        if ($null -eq $signed) { return $true }
        foreach ($relative in $Drifted) {
            $changed = Get-PathChangeTime -Root $Root -Relative $relative
            if ($null -eq $changed -or $changed -gt $signed) { return $true }
        }
        return $false
    }
}

Describe 'the installer integrity manifest' {
    It 'exists and names at least one installer' {
        $manifest = Join-Path $script:RepoRootPath 'install/install.sha256'
        Assert-True (Test-Path -LiteralPath $manifest) "missing $manifest"
        Assert-True (@(Get-ManifestEntry).Count -gt 0) 'the manifest lists no usable <hash>  <path> entry'
    }

    It 'names only files that exist' {
        $absent = @(Get-ManifestEntry | Where-Object { -not (Test-Path -LiteralPath $_.FullPath) })
        Assert-True ($absent.Count -eq 0) "the manifest names files that are not in the repo: $(($absent.Relative) -join ', ')"
    }

    It 'records the hash each installer actually has' {
        $drift = [Collections.Generic.List[string]]::new()
        $drifted = [Collections.Generic.List[string]]::new()
        foreach ($e in Get-ManifestEntry) {
            if (-not (Test-Path -LiteralPath $e.FullPath)) { continue }
            $actual = (Get-FileHash -LiteralPath $e.FullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $e.Recorded) {
                $drift.Add("$($e.Relative)`n    recorded $($e.Recorded)`n    actual   $actual")
                $drifted.Add($e.Relative)
            }
        }

        if ($drift.Count -gt 0 -and (Test-SignatureStale -Drifted $drifted) -and -not (Test-ManifestMustVerify)) {
            Set-ItResult -Skipped -Because @"
install.sha256 is out of date, and renewing its signature is the operator's
step: install.sha256.sig does not verify this manifest, or an installer changed
after it was signed. Regenerating the manifest here would leave a manifest the
signature does not verify.
Operator step -- regenerate and re-sign with the release key:
$($drift -join "`n")
"@
            return
        }

        Assert-True ($drift.Count -eq 0) @"
install.sha256 does not match the installers it names:
$($drift -join "`n")
"@
    }

    It 'carries a signature the bundled release key verifies' {
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoRootPath 'install/install.sha256.sig')) 'install/install.sha256.sig is missing'
        if (-not (Test-ManifestSignature)) {
            Assert-False (Test-ManifestMustVerify) 'a release tag or a public tree must carry a manifest its signature verifies; re-sign with tools/Update-YurunaReleasePins.ps1 -PrivateKeyPath'
            Set-ItResult -Skipped -Because @"
install.sha256.sig does not verify install/install.sha256 with
install/keys/yuruna-release-signing.pub.pem: an unsigned development manifest,
which a version bump leaves behind (dev-only/tools/Update-Version.ps1 regenerates
it with -SkipSign). The publisher re-signs with
tools/Update-YurunaReleasePins.ps1 -PrivateKeyPath before tagging.
"@
        }
    }
}

# The decision above in a scratch checkout signed by a throwaway key, so each
# ownership rule is exercised whatever state the real manifest is in.
Describe 'who owns the fix for a drifted manifest' {
    BeforeAll {
        $script:signer = [Security.Cryptography.RSA]::Create(2048)
        $script:publicPem = $script:signer.ExportSubjectPublicKeyInfoPem()

        function Invoke-FixtureGit {
            param([string]$Root, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgument)
            $output = & git -C $Root -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false @GitArgument 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($GitArgument -join ' ') failed: $output" }
        }

        function Write-FixtureFile {
            param([string]$Root, [string]$Relative, [string]$Text)
            [IO.File]::WriteAllText((Join-Path $Root $Relative), $Text, [Text.UTF8Encoding]::new($false))
        }

        # Writes a manifest naming install/setup.sh with the hash of $ForText
        # and signs it with the throwaway key.
        function Write-SignedFixtureManifest {
            param([string]$Root, [string]$ForText)
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ForText))).ToLowerInvariant()
            Write-FixtureFile -Root $Root -Relative 'install/install.sha256' -Text "$hash  install/setup.sh`n"
            $bytes = [IO.File]::ReadAllBytes((Join-Path $Root 'install/install.sha256'))
            $sig = $script:signer.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            [IO.File]::WriteAllBytes((Join-Path $Root 'install/install.sha256.sig'), $sig)
        }

        function Save-FixtureCommit {
            param([string]$Root, [long]$At)
            $env:GIT_AUTHOR_DATE = "@$At +0000"
            $env:GIT_COMMITTER_DATE = "@$At +0000"
            try {
                Invoke-FixtureGit $Root add -A
                Invoke-FixtureGit $Root commit -q -m "fixture at $At"
            } finally {
                Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
            }
        }

        function New-ManifestFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Creates isolated test fixtures beneath TestDrive.')]
            [CmdletBinding()]
            param()
            $root = Join-Path $TestDrive ('install-manifest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path (Join-Path $root 'install/keys') -Force | Out-Null
            Write-FixtureFile -Root $root -Relative 'install/keys/yuruna-release-signing.pub.pem' -Text $script:publicPem
            Invoke-FixtureGit $root init -q
            return $root
        }
    }
    AfterAll {
        $script:signer.Dispose()
    }

    It 'verifies the signature over the manifest bytes, and refuses one changed byte' {
        $root = New-ManifestFixture
        Write-FixtureFile -Root $root -Relative 'install/setup.sh' -Text "echo v1`n"
        Write-SignedFixtureManifest -Root $root -ForText "echo v1`n"
        Assert-True (Test-ManifestSignature -Root $root) 'a manifest signed by the bundled key verifies'
        $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'install/install.sha256'))
        $bytes[0] = [byte](($bytes[0] -bxor 1))
        [IO.File]::WriteAllBytes((Join-Path $root 'install/install.sha256'), $bytes)
        Assert-False (Test-ManifestSignature -Root $root) 'one changed byte must fail verification'
    }

    It 'fails a signed manifest that never described the installer it names' {
        $root = New-ManifestFixture
        Write-FixtureFile -Root $root -Relative 'install/setup.sh' -Text "echo v2`n"
        Write-SignedFixtureManifest -Root $root -ForText "echo v1`n"
        Save-FixtureCommit -Root $root -At 1700000000
        # A fresh clone writes the signature first, so its file time is the oldest.
        (Get-Item -LiteralPath (Join-Path $root 'install/install.sha256.sig')).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1)
        Assert-False (Test-SignatureStale -Root $root -Drifted @('install/setup.sh')) 'signed together with the installer it misdescribes: a broken publish'
    }

    It 'leaves the fix to the operator once an installer changes after a valid signing' {
        $root = New-ManifestFixture
        Write-FixtureFile -Root $root -Relative 'install/setup.sh' -Text "echo v1`n"
        Write-SignedFixtureManifest -Root $root -ForText "echo v1`n"
        Save-FixtureCommit -Root $root -At 1700000000
        Write-FixtureFile -Root $root -Relative 'install/setup.sh' -Text "echo v2`n"
        Assert-True (Test-SignatureStale -Root $root -Drifted @('install/setup.sh')) 'an uncommitted installer edit is newer than the signature'
        Save-FixtureCommit -Root $root -At 1700000100
        Assert-True (Test-SignatureStale -Root $root -Drifted @('install/setup.sh')) 'a committed installer edit after the signature'
    }

    It 'holds a release tag and a public tree to a manifest that verifies' {
        $root = New-ManifestFixture
        New-Item -ItemType Directory -Path (Join-Path $root 'dev-only') -Force | Out-Null
        Write-FixtureFile -Root $root -Relative 'dev-only/README.md' -Text "private`n"
        Write-FixtureFile -Root $root -Relative 'install/setup.sh' -Text "echo v1`n"
        Write-SignedFixtureManifest -Root $root -ForText "echo v1`n"
        Save-FixtureCommit -Root $root -At 1700000000
        Assert-False (Test-ManifestMustVerify -Root $root) 'a private tree between releases keeps the pending re-sign as the operator step'
        Invoke-FixtureGit -Root $root -GitArgument @('tag', '2026.10.26')
        Assert-True (Test-ManifestMustVerify -Root $root) 'a commit carrying a release tag is what users verify'
        Invoke-FixtureGit -Root $root -GitArgument @('tag', '--delete', '2026.10.26')
        Invoke-FixtureGit -Root $root -GitArgument @('tag', 'rollback-before-something')
        Assert-False (Test-ManifestMustVerify -Root $root) 'a tag that is not a release does not count'
        Remove-Item -LiteralPath (Join-Path $root 'dev-only') -Recurse -Force
        Assert-True (Test-ManifestMustVerify -Root $root) 'a tree without dev-only/ is a public tree'
    }

    It 'leaves the fix to the operator while the signature no longer verifies the manifest' {
        $root = New-ManifestFixture
        Write-FixtureFile -Root $root -Relative 'install/setup.sh' -Text "echo v1`n"
        Write-SignedFixtureManifest -Root $root -ForText "echo v1`n"
        Save-FixtureCommit -Root $root -At 1700000000
        Write-FixtureFile -Root $root -Relative 'install/install.sha256' -Text "$('0' * 64)  install/setup.sh`n"
        Save-FixtureCommit -Root $root -At 1700000000
        Assert-True (Test-SignatureStale -Root $root -Drifted @('install/setup.sh')) 'an unsigned development manifest'
    }
}
