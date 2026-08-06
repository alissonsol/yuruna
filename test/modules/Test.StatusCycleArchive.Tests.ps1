<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42b7d914-3c60-4a18-9f52-6d0e8b47c913
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status-service archive share-cycle pester
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
    Guards the /archive/<cycle-folder>.tar.gz route and the share page it feeds.
.DESCRIPTION
    The archive route takes a folder name off the URL and hands it to tar, so
    the name grammar is the whole boundary: it is what keeps the archive
    pointed at one cycle results folder under log/ and nowhere else on disk.
    A sanitiser would be the wrong shape here -- there is exactly one legal
    form, so anything else is refused rather than cleaned up, and these tests
    pin both halves of that (what it accepts, and that no separator, traversal
    or absolute path can pass).

    The grammar is written twice, in PowerShell on the host and in JavaScript
    on the share page, because the two ends do different jobs with it: one
    resolves a folder on disk, the other derives the archive name and the mail
    subject shown to the operator. A drift test keeps them one grammar -- the
    same reason the control proof has a golden vector across three languages.

    Both regexes are read out of their source rather than restated here, so
    this cannot pass against a guard that has been widened or deleted
    somewhere else in the file.

    Read from Start-StatusService.ps1, which is the tracked GENERATOR, not
    from test/status/runtime/.status-service.ps1 -- that copy is gitignored
    runtime output, absent on a fresh clone and overwritten on every service
    start, so a guard reading it would test a file no commit can change.
    The generator emits the route inside a here-string, hence the escaped `$
    in the pattern below.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.StatusCycleArchive.Tests.ps1
#>

$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = Split-Path -Parent (Split-Path -Parent $here)
$svcPath   = Join-Path $repoRoot 'test/Start-StatusService.ps1'
$statusDir = Join-Path $repoRoot 'test/status'

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-NoFinding {
    param([string[]]$Findings, [string]$Because = '')
    if ($Findings.Count -gt 0) { throw ("$Because`n  " + ($Findings -join "`n  ")) }
}

# File scope, above the first Describe: a Describe body is evaluated during
# discovery and its variables are gone before any It runs.
$SvcSource  = Get-Content -Raw -LiteralPath $svcPath
$ShareJs    = Get-Content -Raw -LiteralPath (Join-Path $statusDir 'yuruna.common.js')
$SharePage  = Get-Content -Raw -LiteralPath (Join-Path $statusDir 'share-cycle.html')

# The literal the route matches the URL leaf against. In the generator it lives
# in a here-string, so the end-anchor is written as a backtick-escaped `$;
# strip that escape to recover the regex the running service uses.
$ArchiveMatch = [regex]::Match($SvcSource, "\`$leaf\s+-notmatch\s+'(\^[^']+)'")
$ArchiveRegex = if ($ArchiveMatch.Success) { $ArchiveMatch.Groups[1].Value -replace '`\$', '$' } else { $null }

# A real folder name, as Format-CycleFolderBaseName builds it.
$GoodLeaf = '000724.2026-08-05.01-47-56.42e5e36df63d4edf8b664e6cf6fce463'

Describe 'the cycle archive route grammar' {

    It 'is still present on the archive route' {
        Assert-True ($null -ne $ArchiveRegex) `
            'no leaf grammar found on the archive route: without it the URL names an arbitrary tar target'
        Assert-True ($SvcSource -match "\`$path\s+-like\s+'archive/\*'") `
            'the archive route dispatch is gone'
    }

    It 'accepts a cycle results folder, complete or still running' {
        foreach ($leaf in @("$GoodLeaf.tar.gz", "$GoodLeaf.incomplete.tar.gz")) {
            Assert-True ($leaf -match $ArchiveRegex) "'$leaf' must be accepted: it is a real cycle folder archive name"
        }
    }

    It 'captures the host id and the UTC start the archive is named from' {
        Assert-True ("$GoodLeaf.tar.gz" -match $ArchiveRegex) 'the good leaf must match to capture from'
        Assert-Equal -Expected $GoodLeaf -Actual $Matches[1] -Because 'group 1 is the folder handed to tar'
        Assert-Equal -Expected '2026-08-05' -Actual $Matches[2] -Because 'group 2 is the UTC date'
        Assert-Equal -Expected '01-47-56' -Actual $Matches[3] -Because 'group 3 is the UTC time'
        Assert-Equal -Expected '42e5e36df63d4edf8b664e6cf6fce463' -Actual $Matches[4] -Because 'group 4 is the host id'
        # The name an operator ends up mailing: short host id, then the cycle's
        # own UTC start spelled as a timestamp rather than as a folder.
        $archiveName = '{0}.{1}T{2}Z.tar.gz' -f $Matches[4].Substring(0, 8), $Matches[2], $Matches[3]
        Assert-Equal -Expected '42e5e36d.2026-08-05T01-47-56Z.tar.gz' -Actual $archiveName `
            -Because 'the archive name is what the Subject line and the attachment are built from'
    }

    It 'refuses anything that is not exactly one cycle folder archive' {
        foreach ($leaf in @(
                '../../../etc/passwd.tar.gz',
                "..%2f$GoodLeaf.tar.gz",
                "sub/$GoodLeaf.tar.gz",
                "$GoodLeaf/../other.tar.gz",
                "/$GoodLeaf.tar.gz",
                "$GoodLeaf.tar.gz.ps1",
                "$GoodLeaf.zip",
                "$GoodLeaf",
                '000724.2026-08-05.01-47-56.nothex.tar.gz',
                '724.2026-08-05.01-47-56.42e5e36df63d4edf8b664e6cf6fce463.tar.gz',
                '.tar.gz',
                '')) {
            Assert-Equal -Expected $false -Actual ($leaf -match $ArchiveRegex) `
                -Because "'$leaf' must NOT be accepted: the leaf grammar is the only thing bounding what tar is aimed at"
        }
    }

    It 'is anchored at both ends, so no separator can ride along' {
        Assert-True ($ArchiveRegex.StartsWith('^')) 'the grammar must be anchored at the start'
        Assert-True ($ArchiveRegex.EndsWith('$')) 'the grammar must be anchored at the end'
    }

    It 'runs before the static-file dispatch, so archive/ cannot fall through to it' {
        $routeAt  = $SvcSource.IndexOf("-like 'archive/*'")
        $staticAt = $SvcSource.IndexOf("-like 'yuruna-repo/*'")
        Assert-True ($routeAt -gt 0 -and $staticAt -gt 0) 'both dispatches must exist to compare'
        Assert-True ($routeAt -lt $staticAt) `
            'the archive route must be reached before the by-prefix file dispatch, or archive/ would serve a directory listing instead'
    }

    It 'packs a cycle-shaped tree with the tar this host actually has' {
        # The route shells out to tar, so its availability and its -C behaviour
        # are the feature, not an implementation detail. bsdtar ships in-box on
        # Windows 10 1803+ and on macOS; Linux has GNU tar. A host without one
        # serves 500s from this route, which is worth failing here rather than
        # discovering from an operator.
        Assert-True ($null -ne (Get-Command tar -ErrorAction SilentlyContinue)) `
            'no tar on this host: /archive/<cycle>.tar.gz cannot pack anything'

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        try {
            $src = Join-Path $work $GoodLeaf
            $guest = Join-Path $src 'test-guest.ubuntu.server.24-01'
            $null = New-Item -ItemType Directory -Path $guest -Force
            Set-Content -LiteralPath (Join-Path $src 'manifest.json') -Value '{"ok":true}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $guest 'transcript.txt') -Value 'guest log' -Encoding utf8

            $out = Join-Path $work 'out.tar.gz'
            $tarErr = & tar -czf $out -C $work $GoodLeaf 2>&1
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because "tar failed: $($tarErr -join ' ')"
            Assert-True (Test-Path -LiteralPath $out) 'tar produced no archive'

            # -C is what keeps the host's whole log path out of the archive: every
            # entry must sit under the cycle folder, and the guest subfolder has
            # to be in there or "recursively" is not what happened.
            $listed = @(& tar -tzf $out 2>&1)
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because "tar could not list its own archive: $($listed -join ' ')"
            $entries = @($listed | ForEach-Object { ($_ -replace '\\', '/').TrimEnd('/') })
            Assert-True ($entries -contains "$GoodLeaf/manifest.json") 'the cycle file is missing from the archive'
            Assert-True ($entries -contains "$GoodLeaf/test-guest.ubuntu.server.24-01/transcript.txt") `
                'the guest subfolder is missing: the archive must be recursive'
            foreach ($e in $entries) {
                Assert-True ($e -eq $GoodLeaf -or $e.StartsWith("$GoodLeaf/")) `
                    "archive entry '$e' escapes the cycle folder: -C must root it at the folder"
            }
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'packs under the same name rules the per-file deny-lists enforce' {
        # An archive is a bulk read, and it is dispatched ABOVE the deny-list that
        # guards the per-file reads -- so that list never sees these bytes. A
        # shape the server refuses to serve on its own must not travel inside a
        # tarball either, or the route is a way around every name rule at once.
        Assert-True ($SvcSource -match "\`$secretNameShapes\s*=\s*@\(") `
            'the shared secret-name shapes are gone'
        # Single-quoted: in the generator these variables are backtick-escaped, so
        # the source text really contains a backtick before each $.
        Assert-True ($SvcSource -match 'foreach \(`\$shape in `\$secretNameShapes\) \{ `\$tarArgs \+= "--exclude=') `
            'the archive route must exclude the secret name shapes when packing'
        Assert-True ($SvcSource -match '& tar @tarArgs') `
            'the packer must pass the exclusions it just built'
        # One list, three consumers: both deny-lists and the packer. Enumerating
        # the shapes again anywhere is how the copies drift apart.
        $consumers = [regex]::Matches($SvcSource, '\$secretNameShapes').Count
        Assert-True ($consumers -ge 4) `
            "expected the shared shapes to be defined once and read by both deny-lists and the packer, saw $consumers references"
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($SvcSource, "'\*\.snapshot\.json'").Count) `
            -Because 'the shapes must be written once, not restated per consumer'
    }

    It 'leaves a snapshot or backup out of the archive it builds' {
        Assert-True ($null -ne (Get-Command tar -ErrorAction SilentlyContinue)) 'no tar on this host'
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        try {
            $src = Join-Path $work $GoodLeaf
            $null = New-Item -ItemType Directory -Path $src -Force
            Set-Content -LiteralPath (Join-Path $src 'manifest.json') -Value '{"ok":true}' -Encoding utf8
            # The exact shapes the deny-list added after a vault snapshot turned
            # up readable under a generated name.
            foreach ($leak in @('vault.snapshot.json', 'test.config.snapshot.2026.json', 'creds.bak', 'creds.backup', 'x.tmp')) {
                Set-Content -LiteralPath (Join-Path $src $leak) -Value 'secret' -Encoding utf8
            }

            $out = Join-Path $work 'out.tar.gz'
            $tarArgs = @()
            foreach ($shape in @('*.snapshot.json', '*.snapshot.*.json', '*.backup', '*.bak', '*.tmp')) { $tarArgs += "--exclude=$shape" }
            $tarArgs += @('-czf', $out, '-C', $work, $GoodLeaf)
            $tarErr = & tar @tarArgs 2>&1
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because "tar failed: $($tarErr -join ' ')"

            $entries = @(& tar -tzf $out 2>&1 | ForEach-Object { ($_ -replace '\\', '/').TrimEnd('/') })
            Assert-True ($entries -contains "$GoodLeaf/manifest.json") 'the cycle artifact must still be packed'
            $findings = @()
            foreach ($e in $entries) {
                if ($e -match '\.(snapshot\.json|backup|bak|tmp)$' -or $e -match '\.snapshot\..*\.json$') {
                    $findings += "the archive carries '$e', which the server refuses to serve on its own"
                }
            }
            Assert-NoFinding $findings 'tar --exclude must hold on this platform, or the archive is a way around the deny-list'
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'cleans up the archive it wrote, whatever happened' {
        # The tarball is written under the runtime dir because a gzip stream
        # cannot survive a PowerShell pipeline. Leaving one behind per share
        # would grow the runtime dir without bound.
        Assert-True ($SvcSource -match 'share-cycle\.') 'the temp archive name is gone'
        Assert-True ($SvcSource -match '(?s)& tar @tarArgs.*?finally \{\s*\r?\n\s*Remove-Item -LiteralPath `\$tmpArchive') `
            'the temp archive must be removed in a finally, so a tar failure does not leak it'
    }
}

Describe 'the share page and the host agree on one grammar' {

    It 'matches the same folder names in JavaScript as on the host' {
        $jsMatch = [regex]::Match($ShareJs, 'SHARE_CYCLE_RE\s*=\s*/(\^[^/]+)/')
        Assert-True $jsMatch.Success 'share-cycle.html''s folder grammar (SHARE_CYCLE_RE) is gone from yuruna.common.js'
        $jsRegex = $jsMatch.Groups[1].Value

        # Same folders, judged by both ends. The page derives the archive name
        # and the mail subject from its match; the host resolves a directory
        # from its own. A folder one accepts and the other rejects is a button
        # that offers a download the service will 404.
        $findings = @()
        foreach ($folder in @(
                $GoodLeaf,
                "$GoodLeaf.incomplete",
                '000001.2026-01-01.00-00-00.42ffffffffffffffffffffffffffffff')) {
            if (-not ($folder -match $jsRegex)) { $findings += "the share page rejects '$folder' but the host accepts it" }
            if (-not ("$folder.tar.gz" -match $ArchiveRegex)) { $findings += "the host rejects '$folder' but the share page accepts it" }
        }
        foreach ($folder in @('../etc', "sub/$GoodLeaf", '000724.2026-08-05.01-47-56.nothex', '')) {
            if ($folder -match $jsRegex) { $findings += "the share page accepts '$folder', which the host refuses" }
            if ("$folder.tar.gz" -match $ArchiveRegex) { $findings += "the host accepts '$folder', which the share page refuses" }
        }
        Assert-NoFinding $findings 'one folder grammar, written at both ends'
    }

    It 'boots from the id the page carries and drives every field on it' {
        Assert-True ($ShareJs -match 'function bootShareCycle') 'yuruna.common.js has no bootShareCycle'
        Assert-True ($ShareJs -match "getElementById\('share-cycle'\)\)\s*\{\s*\r?\n\s*bootShareCycle") `
            'the page dispatch does not reach bootShareCycle'
        $findings = @()
        foreach ($id in @('share-cycle', 'share-host', 'share-cycle-number', 'share-started', 'share-filename', 'share-go', 'share-status')) {
            if ($SharePage -notmatch "id=`"$id`"") { $findings += "share-cycle.html has no #$id" }
            if ($ShareJs -notmatch "'$id'") { $findings += "yuruna.common.js never touches #$id" }
        }
        Assert-NoFinding $findings 'the page and its handler have to name the same elements'
    }

    It 'builds the subject and body the operator was promised' {
        Assert-True ($ShareJs -match "'Yuruna Host '\s*\+\s*info\.shortHost\s*\+\s*' at '\s*\+\s*info\.stamp") `
            'the mail subject is not "Yuruna Host <id> at <UTC time>"'
        Assert-True ($ShareJs -match "var body = 'Yuruna cycle results'") `
            'the mail body is not "Yuruna cycle results"'
        Assert-True ($ShareJs -match "mailto:\?subject=") 'the draft is no longer opened with mailto:'
    }

    It 'falls back to a download when the browser cannot attach a file itself' {
        # navigator.share is secure-context gated and the status service speaks
        # plain HTTP over the LAN, so the fallback is the path a lab host
        # actually takes -- it is the feature, not a corner case.
        Assert-True ($ShareJs -match 'function downloadThenDraft') 'the download fallback is gone'
        Assert-True ($ShareJs -match 'navigator\.canShare') `
            'the share path must test canShare({files}), not merely navigator.share'
        Assert-True ($ShareJs -match "err\.name === 'AbortError'") `
            'a share the operator cancelled must not fall through to a download they did not ask for'
    }
}
