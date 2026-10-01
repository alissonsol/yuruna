<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42bcdf70-8f13-463a-8f88-0dcd1771f9c7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install signed manifest snippet pester
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
    Executes the published verified-install snippets from install/README.md
    against a signed fixture, so a check that silently passes everything is
    caught by running it rather than by reading it.
.DESCRIPTION
    The snippets are the only thing standing between a downloaded installer
    and its execution, and the way they fail open is invisible on the page: a
    digest command that does not exist on the operator's machine yields an
    empty string, and a substring match of an empty string succeeds against
    every manifest line. So the blocks are extracted verbatim from the README
    and run, unmodified, against a manifest signed with a key generated here:

      * bash block -- under bash, and under zsh (the macOS default shell) when
        it is installed; a fake `curl` on a private PATH serves the fixture
        files and can fail any one of them.
      * Windows block -- in a child pwsh, with `irm` replaced by a function
        that serves the same fixture. On a non-Windows host a backslash is
        part of a file name for the .NET file API, so the shim writes each
        download under both spellings and the block runs unchanged.

    Each case asserts on whether the fake installer ran, not on how the
    snippet phrased its refusal alone. Cases that need `openssl` are Skipped,
    never passed, on a host without it.
#>

BeforeDiscovery {
    $script:OpenSslAtDiscovery = [bool](Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue)

    $script:Shells = @(
        foreach ($name in @('bash', 'zsh')) {
            $found = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { @{ ShellName = $name; ShellPath = $found.Source } }
        })

    $caseDefault = @{ Manifest = 'valid'; FailDownload = ''; DigestFails = $false; LastLine = 'install'; Target = 'install/macos.utm.sh'; Expect = 'ran'; Message = '' }
    $newCase = {
        param([hashtable]$Override)
        $row = $caseDefault.Clone()
        foreach ($k in $Override.Keys) { $row[$k] = $Override[$k] }
        $row
    }
    $script:BashCases = @(
        & $newCase @{ CaseName = 'a valid signed manifest runs the installer' }
        & $newCase @{ CaseName = 'the Ubuntu choice verifies against its own row'; Target = 'install/ubuntu.kvm.sh' }
        & $newCase @{ CaseName = 'the right hash under another pathname''s row refuses'; Manifest = 'hash-under-other-row'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'the hash appearing only inside a comment line refuses'; Manifest = 'hash-in-comment'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'a commented-out row for the exact path refuses'; Manifest = 'commented-row'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'duplicate rows for the requested path refuse'; Manifest = 'duplicate-row'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'a manifest that fails its signature refuses'; Manifest = 'tampered'; Expect = 'refused'; Message = 'SIGNATURE INVALID' }
        & $newCase @{ CaseName = 'a failed download refuses'; FailDownload = 'install/install.sha256.sig'; Expect = 'refused'; Message = 'DOWNLOAD FAILED' }
        & $newCase @{ CaseName = 'a failed installer download refuses'; FailDownload = 'install/macos.utm.sh'; Expect = 'refused'; Message = 'DOWNLOAD FAILED' }
        & $newCase @{ CaseName = 'a digest command that fails refuses'; DigestFails = $true; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'an empty signed manifest refuses'; Manifest = 'empty'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'the refresh variant runs the downloaded installer with both refresh signals'; LastLine = 'refresh' }
        & $newCase @{ CaseName = 'the refresh variant still refuses a mismatched installer'; LastLine = 'refresh'; Manifest = 'hash-under-other-row'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
    )
    $script:WindowsCases = @(
        & $newCase @{ CaseName = 'a valid signed manifest runs the installer'; Target = 'install/windows.hyper-v.ps1' }
        & $newCase @{ CaseName = 'the right hash under another pathname''s row refuses'; Target = 'install/windows.hyper-v.ps1'; Manifest = 'hash-under-other-row'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'the hash appearing only inside a comment line refuses'; Target = 'install/windows.hyper-v.ps1'; Manifest = 'hash-in-comment'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'duplicate rows for the requested path refuse'; Target = 'install/windows.hyper-v.ps1'; Manifest = 'duplicate-row'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'a row whose path differs only in case refuses'; Target = 'install/windows.hyper-v.ps1'; Manifest = 'path-case'; Expect = 'refused'; Message = 'INSTALLER HASH MISMATCH' }
        & $newCase @{ CaseName = 'a manifest that fails its signature refuses'; Target = 'install/windows.hyper-v.ps1'; Manifest = 'tampered'; Expect = 'refused'; Message = 'SIGNATURE INVALID' }
        & $newCase @{ CaseName = 'a failed download stops the whole block before the installer runs'; Target = 'install/windows.hyper-v.ps1'; FailDownload = 'install/install.sha256.sig'; Expect = 'refused'; Message = '404' }
    )
}

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

$script:ReadmePath = Join-Path $repoRoot 'install/README.md'
$script:TranslatedReadmePath = Join-Path $repoRoot 'docs/pt-BR/install/README.md'
$script:ReadmeText = [IO.File]::ReadAllText($script:ReadmePath)

function Get-FencedBlock {
    param([Parameter(Mandatory)][string]$Text)
    foreach ($m in [regex]::Matches($Text, '(?ms)^```[^\n]*\n(.*?)^```')) { $m.Groups[1].Value }
}

# The first fenced block after a marker line, searched from a section heading
# on, so a marker that also appears in an earlier section is not picked up.
function Get-BlockAfter {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Marker)
    $sectionAt = $Text.IndexOf($Section, [StringComparison]::Ordinal)
    if ($sectionAt -lt 0) { throw "Section '$Section' not found in install/README.md." }
    $markerAt = $Text.IndexOf($Marker, $sectionAt, [StringComparison]::Ordinal)
    if ($markerAt -lt 0) { throw "Marker '$Marker' not found after '$Section'." }
    $m = [regex]::Match($Text.Substring($markerAt), '(?ms)^```[^\n]*\n(.*?)^```')
    if (-not $m.Success) { throw "No code block after '$Marker'." }
    return $m.Groups[1].Value
}

function ConvertTo-PlainText {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    $noAnsi = [regex]::Replace($Text, "\x1b\[[0-9;?]*[ -/]*[@-~]", '')
    return [regex]::Replace($noAnsi, "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", '')
}

function Write-StubScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes an executable stub inside a temp sandbox the test removes.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"))
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute')
    }
}

$script:VerifiedSection = '## Verified install'
$script:RefreshSection = '## Refresh an installed macOS host'
$script:BashBlock = Get-BlockAfter -Text $script:ReadmeText -Section $script:VerifiedSection -Marker '**macOS UTM / Ubuntu KVM**'
$script:WindowsBlock = Get-BlockAfter -Text $script:ReadmeText -Section $script:VerifiedSection -Marker '**Windows Hyper-V**'
$script:RefreshBlocks = @(Get-FencedBlock -Text $script:ReadmeText.Substring($script:ReadmeText.IndexOf($script:RefreshSection, [StringComparison]::Ordinal)))

# One key for the whole suite: generating RSA keys is the slow part, and every
# case needs a manifest signed by the key its snippet is told to trust.
$script:SigningKey = [System.Security.Cryptography.RSA]::Create(2048)

$script:OpenSsl = (Get-Command -Name openssl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source

# Builds the served tree (fake installers, manifest, signature, public key)
# for one case, plus a fake curl in front of the real one.
function New-SignedFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a signed temp tree the test removes.')]
    param([Parameter(Mandatory)][hashtable]$Case)
    $root = New-YurunaTestTempDir -Prefix 'yuruna-signed-snippet'
    $srv = Join-Path $root 'srv'; $bin = Join-Path $root 'bin'; $rec = Join-Path $root 'rec'
    New-Item -ItemType Directory -Force -Path (Join-Path $srv 'install/keys'), $bin, $rec, (Join-Path $root 'tmp'), (Join-Path $root 'home') | Out-Null

    # Each fake installer records that it ran, its arguments and the refresh
    # variable, so a case can tell exactly which file was executed and how.
    $installers = [ordered]@{}
    foreach ($leaf in @('macos.utm.sh', 'ubuntu.kvm.sh')) {
        $installers["install/$leaf"] = "#!/bin/bash`nprintf '%s\n' '$leaf' > '$rec/ran'`nprintf '%s\n' `"`$@`" > '$rec/argv'`nprintf '%s' `"`${YURUNA_REFRESH-<unset>}`" > '$rec/refresh'`n"
    }
    $installers['install/windows.hyper-v.ps1'] = "[IO.File]::WriteAllText('$rec/ran', 'windows.hyper-v.ps1')`n"
    $hashes = @{}
    foreach ($path in $installers.Keys) {
        $full = Join-Path $srv $path
        [IO.File]::WriteAllText($full, $installers[$path])
        $hashes[$path] = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($full))).ToLowerInvariant()
    }

    $target = $Case.Target
    $other = if ($target -eq 'install/ubuntu.kvm.sh') { 'install/macos.utm.sh' } else { 'install/ubuntu.kvm.sh' }
    $unrelated = ('0' * 63) + '1'
    $rows = [System.Collections.Generic.List[string]]::new()
    switch ($Case.Manifest) {
        'empty' { }
        'hash-under-other-row' {
            foreach ($path in $installers.Keys) {
                if ($path -eq $target) { $rows.Add("$unrelated  $path") }
                elseif ($path -eq $other) { $rows.Add("$($hashes[$target])  $path") }
                else { $rows.Add("$($hashes[$path])  $path") }
            }
        }
        'hash-in-comment' {
            $rows.Add("# previous release: $($hashes[$target])  $target")
            foreach ($path in $installers.Keys) { if ($path -ne $target) { $rows.Add("$($hashes[$path])  $path") } }
        }
        'commented-row' {
            foreach ($path in $installers.Keys) {
                if ($path -eq $target) { $rows.Add("#$($hashes[$path])  $path") } else { $rows.Add("$($hashes[$path])  $path") }
            }
        }
        'duplicate-row' {
            foreach ($path in $installers.Keys) { $rows.Add("$($hashes[$path])  $path") }
            $rows.Add("$($hashes[$target])  $target")
        }
        'path-case' {
            foreach ($path in $installers.Keys) {
                if ($path -eq $target) { $rows.Add("$($hashes[$path])  $($path.ToUpperInvariant())") } else { $rows.Add("$($hashes[$path])  $path") }
            }
        }
        default { foreach ($path in $installers.Keys) { $rows.Add("$($hashes[$path])  $path") } }
    }
    $manifestText = if ($rows.Count) { ($rows -join "`n") + "`n" } else { '' }
    $manifestBytes = [Text.Encoding]::ASCII.GetBytes($manifestText)
    $signature = $script:SigningKey.SignData($manifestBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($Case.Manifest -eq 'tampered') {
        # Signed first, altered after: the swapped row is well formed and
        # carries the right hash, so only the signature can catch it.
        $manifestBytes = [Text.Encoding]::ASCII.GetBytes(($manifestText -replace '(?m)^[0-9a-f]{64}(  install/windows)', ($unrelated + '$1')))
    }
    [IO.File]::WriteAllBytes((Join-Path $srv 'install/install.sha256'), $manifestBytes)
    [IO.File]::WriteAllBytes((Join-Path $srv 'install/install.sha256.sig'), $signature)
    [IO.File]::WriteAllText((Join-Path $srv 'install/keys/yuruna-release-signing.pub.pem'), $script:SigningKey.ExportSubjectPublicKeyInfoPem() + "`n")
    [IO.File]::WriteAllText((Join-Path $srv 'install/keys/yuruna-release-signing.pub.xml'), $script:SigningKey.ToXmlString($false))
    [IO.File]::WriteAllText((Join-Path $root 'fail.list'), ([string]$Case.FailDownload) + "`n")

    Write-StubScript -Path (Join-Path $bin 'curl') -Text @"
#!/bin/bash
url=''; out=''
while [ `$# -gt 0 ]; do
  case "`$1" in
    -o) out="`$2"; shift 2 ;;
    -*) shift ;;
    *)  url="`$1"; shift ;;
  esac
done
printf '%s\n' "`$url" >> '$rec/curl.log'
rel="`${url#*/refs/tags/*/}"
if grep -qxF "`$rel" '$root/fail.list'; then printf 'curl: (22) The requested URL returned error: 404\n' >&2; exit 22; fi
[ -f '$srv/'"`$rel" ] || { printf 'curl: (22) The requested URL returned error: 404\n' >&2; exit 22; }
cp '$srv/'"`$rel" "`$out"
"@
    if ($Case.DigestFails -and $script:OpenSsl) {
        # Fails only the digest the snippet compares, so the signature check
        # before it still passes and the refusal has to come from the empty digest.
        Write-StubScript -Path (Join-Path $bin 'openssl') -Text @"
#!/bin/bash
for a in "`$@"; do [ "`$a" = "-r" ] && exit 1; done
exec '$($script:OpenSsl)' "`$@"
"@
    }
    return @{ Root = $root; Srv = $srv; Bin = $bin; Rec = $rec; Hashes = $hashes }
}

function Get-FixtureEvidence {
    param([Parameter(Mandatory)][hashtable]$Fixture)
    $read = { param($name) $p = Join-Path $Fixture.Rec $name; if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p).Trim() } else { $null } }
    return @{
        Ran     = (& $read 'ran')
        Argv    = (& $read 'argv')
        Refresh = (& $read 'refresh')
        Urls    = @(if (Test-Path -LiteralPath (Join-Path $Fixture.Rec 'curl.log')) { Get-Content -LiteralPath (Join-Path $Fixture.Rec 'curl.log') })
    }
}

function Invoke-BashSnippet {
    param([Parameter(Mandatory)][hashtable]$Case, [Parameter(Mandatory)][string]$ShellPath)
    $fixture = New-SignedFixture -Case $Case
    try {
        $text = $script:BashBlock
        if ($Case.Target -ne 'install/macos.utm.sh') {
            # The README tells Ubuntu operators to change S in the first line.
            $text = $text.Replace('S=install/macos.utm.sh', "S=$($Case.Target)")
        }
        if ($Case.LastLine -eq 'refresh') {
            $refreshLine = $script:RefreshBlocks[1].Trim()
            $lines = @($text.TrimEnd("`n") -split "`n")
            $lines[-1] = $refreshLine
            $text = ($lines -join "`n") + "`n"
        }
        $snippet = Join-Path $fixture.Root 'snippet.sh'
        [IO.File]::WriteAllText($snippet, $text)
        $pathPrefix = $fixture.Bin
        $openSslDir = Split-Path -Parent $script:OpenSsl
        if ($openSslDir -notin @('/usr/bin', '/bin')) { $pathPrefix = "${pathPrefix}:$openSslDir" }
        $environment = @{
            PATH = "${pathPrefix}:/usr/bin:/bin"; TMPDIR = (Join-Path $fixture.Root 'tmp'); HOME = (Join-Path $fixture.Root 'home')
            ZDOTDIR = (Join-Path $fixture.Root 'home'); YURUNA_REFRESH = ''; BASH_ENV = ''; ENV = ''; LC_ALL = 'C'
        }
        $r = Invoke-BoundedNativeCommand -FilePath $ShellPath -ArgumentList @($snippet) -Environment $environment -TimeoutSeconds 60
        $evidence = Get-FixtureEvidence -Fixture $fixture
        $evidence['Started'] = [bool]$r.Started
        $evidence['TimedOut'] = [bool]$r.TimedOut
        $evidence['ExitCode'] = $r.ExitCode
        $evidence['Output'] = ConvertTo-PlainText ($r.StdOut + "`n" + $r.StdErr)
        $evidence['Hashes'] = $fixture.Hashes
        return $evidence
    } finally {
        Remove-YurunaTestTempDir $fixture.Root
    }
}

function Invoke-WindowsSnippet {
    param([Parameter(Mandatory)][hashtable]$Case)
    $fixture = New-SignedFixture -Case $Case
    try {
        $snippet = Join-Path $fixture.Root 'snippet.ps1'
        [IO.File]::WriteAllText($snippet, $script:WindowsBlock)
        $driver = Join-Path $fixture.Root 'driver.ps1'
        [IO.File]::WriteAllText($driver, @'
param([string]$SnippetPath, [string]$ServeRoot, [string]$FailList, [string]$UrlLog)
Remove-Item -LiteralPath 'Alias:irm' -Force -ErrorAction SilentlyContinue
function irm {
    param([Parameter(Position = 0)][string]$Uri, [string]$OutFile)
    Add-Content -LiteralPath $UrlLog -Value $Uri
    $rel = $Uri -replace '^.*/refs/tags/[^/]+/', ''
    if (@(Get-Content -LiteralPath $FailList) -contains $rel) { throw "404 Not Found: $Uri" }
    $source = Join-Path $ServeRoot $rel
    if (-not (Test-Path -LiteralPath $source)) { throw "404 Not Found: $Uri" }
    $bytes = [IO.File]::ReadAllBytes($source)
    [IO.File]::WriteAllBytes($OutFile, $bytes)
    # The snippet reads some files back through the raw .NET file API with a
    # Windows separator; off Windows that backslash is part of a file name, so
    # the same bytes are written under that spelling as well.
    $leaf = Split-Path -Leaf $OutFile
    [IO.File]::WriteAllBytes((Split-Path -Parent $OutFile) + '\' + $leaf, $bytes)
}
try {
    . ([scriptblock]::Create([IO.File]::ReadAllText($SnippetPath)))
    exit 0
} catch {
    [Console]::Error.WriteLine("REFUSED: $($_.Exception.Message)")
    exit 1
}
'@)
        $pwshPath = [Environment]::ProcessPath
        $environment = @{ TEMP = (Join-Path $fixture.Root 'tmp'); TMPDIR = (Join-Path $fixture.Root 'tmp'); NO_COLOR = '1' }
        $r = Invoke-BoundedNativeCommand -FilePath $pwshPath -TimeoutSeconds 120 -Environment $environment -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driver,
            '-SnippetPath', $snippet, '-ServeRoot', $fixture.Srv, '-FailList', (Join-Path $fixture.Root 'fail.list'),
            '-UrlLog', (Join-Path $fixture.Rec 'curl.log'))
        $evidence = Get-FixtureEvidence -Fixture $fixture
        $evidence['Started'] = [bool]$r.Started
        $evidence['TimedOut'] = [bool]$r.TimedOut
        $evidence['ExitCode'] = $r.ExitCode
        $evidence['Output'] = ConvertTo-PlainText ($r.StdOut + "`n" + $r.StdErr)
        return $evidence
    } finally {
        Remove-YurunaTestTempDir $fixture.Root
    }
}

function Confirm-SnippetOutcome {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][hashtable]$Case, [string]$Shell)
    Assert-True ($Result.Started -and -not $Result.TimedOut) "the snippet must start and finish inside its cap ($Shell)"
    if ($Case.Expect -eq 'ran') {
        Assert-Equal (Split-Path -Leaf $Case.Target) $Result.Ran "the verified installer must run ($Shell); output: $($Result.Output)"
        Assert-Equal 0 $Result.ExitCode "a verified run exits with the installer's code ($Shell)"
        Assert-True (@($Result.Urls).Count -ge 4) "every artifact is downloaded ($Shell)"
        foreach ($u in $Result.Urls) {
            Assert-Match '/refs/tags/\d{4}\.\d{2}\.\d{2}(\.\d+)?/' $u "downloads come from a release tag, never a moving branch ($Shell)"
        }
    } else {
        Assert-Null $Result.Ran "a refused snippet must never run the installer ($Shell)"
        Assert-True ($Result.ExitCode -ne 0) "a refusal exits non-zero ($Shell)"
        Assert-Match ([regex]::Escape($Case.Message)) $Result.Output "the refusal must say why ($Shell)"
    }
}
}

Describe 'The published verification snippets' {
    It 'compute the digest with openssl -r and never with sha256sum or a substring match' {
        # sha256sum is absent on stock macOS; its empty substitution made a
        # substring grep match every manifest line.
        Assert-False ($script:BashBlock -match 'sha256sum') 'sha256sum does not exist on stock macOS'
        Assert-False ($script:BashBlock -match 'grep -qF') 'a substring match accepts a hash from any line'
        Assert-Match ([regex]::Escape('openssl dgst -sha256 -r')) $script:BashBlock 'openssl -r prints the digest first, in the form the 64-hex check expects'
        Assert-Match ([regex]::Escape("grep -Eqx '[0-9a-f]{64}'")) $script:BashBlock 'an empty or malformed digest must be refused, not compared'
        Assert-Match ([regex]::Escape('$2 == p')) $script:BashBlock 'the digest is matched against the row whose path equals the requested file'
    }

    It 'fails the bash block on any download failure' {
        Assert-Match ([regex]::Escape('-o "$t/$(basename "$f")" || {')) $script:BashBlock 'curl failures must stop the block'
    }

    It 'carries no # comment in the bash block (interactive zsh does not treat # as a comment)' {
        # Pasted into the macOS default shell, "S=... # note" runs "#" as a
        # command and S is set only in that command's environment.
        $withHash = @($script:BashBlock -split "`n" | Where-Object { $_ -match '(^|\s)#' })
        Assert-Equal 0 $withHash.Count ('lines with a # comment: ' + ($withHash -join ' | '))
    }

    It 'matches the Windows digest against the exact manifest row, case-sensitively' {
        Assert-False ($script:WindowsBlock -match 'SimpleMatch') 'a substring match accepts a hash from any line'
        Assert-Match ([regex]::Escape("-cmatch '^([0-9a-f]{64})  install/windows\.hyper-v\.ps1$'")) $script:WindowsBlock 'the row is matched whole'
        Assert-Match ([regex]::Escape('$w.Count -ne 1')) $script:WindowsBlock 'a duplicated row refuses'
    }

    It 'runs the Windows block as one statement that stops on the first error' {
        # A console that runs pasted lines one at a time would otherwise carry
        # on to the run line after a throw.
        Assert-Match '^& \{ \$ErrorActionPreference=''Stop''' $script:WindowsBlock 'the block opens a single scriptblock with errors terminating'
        Assert-Match '\}\s*$' $script:WindowsBlock 'and closes it after the run line'
        Assert-Match ([regex]::Escape("[guid]::NewGuid()")) $script:WindowsBlock 'each run downloads into a fresh directory, never onto an earlier run''s files'
    }

    It 'keeps the pt-BR translation''s code blocks byte-identical to the English ones' {
        $english = @(Get-FencedBlock -Text $script:ReadmeText)
        $translated = @(Get-FencedBlock -Text ([IO.File]::ReadAllText($script:TranslatedReadmePath)))
        Assert-Equal $english.Count $translated.Count 'the translation carries every code block, in order'
        for ($i = 0; $i -lt $english.Count; $i++) {
            Assert-True ([string]::Equals($english[$i], $translated[$i], [StringComparison]::Ordinal)) "code block $i differs between install/README.md and its pt-BR translation"
        }
    }
}

Describe 'The refresh forms in install/README.md' {
    It 'documents the convenience form with the $0 placeholder and both signals, pinned to a release tag' {
        $convenience = $script:RefreshBlocks[0].Trim()
        Assert-Match '^YURUNA_REFRESH=1 /bin/bash -c "\$\(curl -fsSL ''https://raw\.githubusercontent\.com/alissonsol/yuruna/refs/tags/\d{4}\.\d{2}\.\d{2}(\.\d+)?/install/macos\.utm\.sh''\)" _ --refresh$' $convenience `
            'the tag keeps an older installer, which ignores --refresh and installs, from being fetched'
    }

    It 'documents the verified form as the verified block''s last line with both signals' {
        Assert-Equal 'YURUNA_REFRESH=1 bash "$t/$(basename "$S")" --refresh' $script:RefreshBlocks[1].Trim() ''
        Assert-Match '(?m)^bash "\$t/\$\(basename "\$S"\)"\s*$' $script:BashBlock 'the replaced last line exists in the verified block'
    }

    It 'repoints every tagged URL with the release-pin tool''s own pattern' {
        $tool = [IO.File]::ReadAllText((Join-Path $repoRoot 'tools/Update-YurunaReleasePins.ps1'))
        Assert-Match ([regex]::Escape("pat = '(alissonsol/yuruna/)refs/tags/' + `$calver")) $tool 'the pin tool rewrites every alissonsol/yuruna tag reference'
        $calver = '\d{4}\.\d{2}\.\d{2}(?:\.\d+)?'
        $tags = @([regex]::Matches($script:ReadmeText, "alissonsol/yuruna/refs/tags/($calver)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        Assert-Equal 1 $tags.Count ('every tagged URL names one release: ' + ($tags -join ', '))
        $repinned = [regex]::Replace($script:ReadmeText, '(alissonsol/yuruna/)refs/tags/' + $calver, '${1}refs/tags/2099.01.01')
        Assert-Equal 3 ([regex]::Matches($repinned, 'refs/tags/2099\.01\.01')).Count 'the Windows and bash verified URLs and the refresh URL all move together'
    }
}

Describe 'The bash verification snippet under <ShellName>' -ForEach $script:Shells {
    It '<CaseName>' -ForEach $script:BashCases {
        if (-not $script:OpenSsl) { Set-ItResult -Skipped -Because 'openssl is not installed on this host; the snippet verifies with it'; return }
        $result = Invoke-BashSnippet -Case $_ -ShellPath $ShellPath
        Confirm-SnippetOutcome -Result $result -Case $_ -Shell $ShellName
        if ($_.LastLine -eq 'refresh' -and $_.Expect -eq 'ran') {
            Assert-Equal '--refresh' $result.Argv "the refresh variant passes --refresh ($ShellName)"
            Assert-Equal '1' $result.Refresh "the refresh variant sets YURUNA_REFRESH=1 ($ShellName)"
        }
        if ($_.LastLine -eq 'install' -and $_.Expect -eq 'ran') {
            Assert-True ([string]::IsNullOrEmpty($result.Argv)) "the install form passes no argument ($ShellName)"
            # The fixture clears YURUNA_REFRESH to empty so a parent value cannot leak in.
            Assert-True ($result.Refresh -in @('', '<unset>')) "the install form carries no refresh signal ($ShellName)"
        }
    }
}

# Defined only where zsh and openssl both exist (a macOS host), so a host
# without them reports no row rather than a skipped one; the release gate
# requires this row to pass on a macOS host.
if (@($script:Shells | Where-Object { $_.ShellName -eq 'zsh' }).Count -gt 0 -and $script:OpenSslAtDiscovery) {
    Describe 'The zsh run of the bash verification snippet' {
        # This case stands on its own rather than pointing at the per-shell block
        # above: it proves the interpreter really is zsh, and runs an accepted and a
        # refused case under it, so it can pass only where both actually ran.
        $zsh = @($script:Shells | Where-Object { $_.ShellName -eq 'zsh' } | Select-Object -First 1)
        $zshPath = if ($zsh.Count) { [string]$zsh[0].ShellPath } else { '' }
        $zshCases = @($script:BashCases | Where-Object { $_.CaseName -in @('a valid signed manifest runs the installer', 'a digest command that fails refuses') })
        It 'ran the verification snippet under zsh (<ZshLabel>)' -ForEach @(@{ ZshLabel = $(if ($zshPath) { $zshPath } else { 'not present on this host' }); ZshPath = $zshPath; ZshCases = $zshCases }) {
            if (-not $ZshPath) {
                Set-ItResult -Skipped -Because 'zsh is not installed on this host; the release gate runs this suite on a macOS host, where it is the default shell'
                return
            }
            if (-not $script:OpenSsl) {
                Set-ItResult -Skipped -Because 'openssl is not installed on this host; the snippet verifies with it, so nothing ran under zsh'
                return
            }
            $probe = Invoke-BoundedNativeCommand -FilePath $ZshPath -ArgumentList @('-c', 'printf "%s" "$ZSH_VERSION"') -TimeoutSeconds 10
            $version = if ($probe.Started -and -not $probe.TimedOut) { $probe.StdOut.Trim() } else { '' }
            Assert-Match '^\d+\.\d+' $version "the interpreter at $ZshPath must really be zsh"
            Assert-Equal 2 @($ZshCases).Count 'an accepted and a refused case reached this run'
            foreach ($case in $ZshCases) {
                $result = Invoke-BashSnippet -Case $case -ShellPath $ZshPath
                Confirm-SnippetOutcome -Result $result -Case $case -Shell "zsh $version ($($case.CaseName))"
            }
        }
    }
}

Describe 'The Windows verification snippet in a child pwsh' {
    It '<CaseName>' -ForEach $script:WindowsCases {
        $result = Invoke-WindowsSnippet -Case $_
        Confirm-SnippetOutcome -Result $result -Case $_ -Shell 'pwsh'
    }
}
