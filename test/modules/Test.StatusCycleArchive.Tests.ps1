<#PSScriptInfo
.VERSION 2026.08.07
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
    Guards the /archive/<cycle-folder>.zip route and the share page it feeds.
.DESCRIPTION
    The archive route takes a folder name off the URL and packs whatever it
    resolves to, so the name grammar is the whole boundary: it is what keeps
    the archive pointed at one cycle results folder under log/ and nowhere
    else on disk.
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

# The share page's own slice of the script every status page shares. Format
# checks read this rather than the whole file: other routes serve tarballs of
# their own (the committed-content archives), and one of those named in some
# unrelated handler is not this page asking for the wrong thing.
$ShareRegion = [regex]::Match($ShareJs, '(?s)// --- REGION: share-cycle\.html.*?(?=// Page dispatch keyed)').Value

# The literal the route matches the URL leaf against. In the generator it lives
# in a here-string, so the end-anchor is written as a backtick-escaped `$;
# strip that escape to recover the regex the running service uses.
$ArchiveMatch = [regex]::Match($SvcSource, "\`$leaf\s+-notmatch\s+'(\^[^']+)'")
$ArchiveRegex = if ($ArchiveMatch.Success) { $ArchiveMatch.Groups[1].Value -replace '`\$', '$' } else { $null }

# A real folder name, as Format-CycleFolderBaseName builds it.
$GoodLeaf = '000724.2026-08-05.01-47-56.42e5e36df63d4edf8b664e6cf6fce463'

# The packing the route does, written here the same way: entries rooted at the
# cycle folder, files opened with ReadWrite sharing because a running cycle is
# still being written to, and any name the server refuses to serve on its own
# left out. What the tests below exercise is whether this host's runtime really
# behaves that way -- the archive an operator extracts is the only proof.
function Compress-TestCycleFolder {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CycleFolder,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Exclude = @()
    )
    $root = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath.TrimEnd('\', '/')
    $zip = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            $blocked = $false
            foreach ($shape in $Exclude) {
                if ([System.IO.Path]::GetFileName($file) -like $shape) { $blocked = $true; break }
            }
            if ($blocked) { continue }
            $entryName = $CycleFolder + '/' + ($file.Substring($root.Length + 1) -replace '\\', '/')
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $inStream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $entryStream = $entry.Open()
                try { $inStream.CopyTo($entryStream) } finally { $entryStream.Dispose() }
            } finally { $inStream.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Get-TestArchiveEntry {
    param([Parameter(Mandatory)][string]$Path)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try { @($zip.Entries | ForEach-Object { $_.FullName.TrimEnd('/') }) } finally { $zip.Dispose() }
}

Describe 'the cycle archive route grammar' {

    It 'is still present on the archive route' {
        Assert-True ($null -ne $ArchiveRegex) `
            'no leaf grammar found on the archive route: without it the URL names an arbitrary tar target'
        Assert-True ($SvcSource -match "\`$path\s+-like\s+'archive/\*'") `
            'the archive route dispatch is gone'
    }

    It 'accepts a cycle results folder, complete or still running' {
        foreach ($leaf in @("$GoodLeaf.zip", "$GoodLeaf.incomplete.zip")) {
            Assert-True ($leaf -match $ArchiveRegex) "'$leaf' must be accepted: it is a real cycle folder archive name"
        }
    }

    It 'captures the host id and the UTC start the archive is named from' {
        Assert-True ("$GoodLeaf.zip" -match $ArchiveRegex) 'the good leaf must match to capture from'
        Assert-Equal -Expected $GoodLeaf -Actual $Matches[1] -Because 'group 1 is the folder handed to tar'
        Assert-Equal -Expected '2026-08-05' -Actual $Matches[2] -Because 'group 2 is the UTC date'
        Assert-Equal -Expected '01-47-56' -Actual $Matches[3] -Because 'group 3 is the UTC time'
        Assert-Equal -Expected '42e5e36df63d4edf8b664e6cf6fce463' -Actual $Matches[4] -Because 'group 4 is the host id'
        # The name an operator ends up mailing: short host id, then the cycle's
        # own UTC start spelled as a timestamp rather than as a folder.
        $archiveName = '{0}.{1}T{2}Z.zip' -f $Matches[4].Substring(0, 8), $Matches[2], $Matches[3]
        Assert-Equal -Expected '42e5e36d.2026-08-05T01-47-56Z.zip' -Actual $archiveName `
            -Because 'the archive name is what the Subject line and the attachment are built from'
    }

    It 'refuses anything that is not exactly one cycle folder archive' {
        foreach ($leaf in @(
                '../../../etc/passwd.zip',
                "..%2f$GoodLeaf.zip",
                "sub/$GoodLeaf.zip",
                "$GoodLeaf/../other.zip",
                "/$GoodLeaf.zip",
                "$GoodLeaf.zip.ps1",
                "$GoodLeaf.tar.gz",
                "$GoodLeaf",
                '000724.2026-08-05.01-47-56.nothex.zip',
                '724.2026-08-05.01-47-56.42e5e36df63d4edf8b664e6cf6fce463.zip',
                '.zip',
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

    It 'packs a cycle-shaped tree with the zip writer this host runs on' {
        # The route packs in-process, so there is no archiver to go missing --
        # but the shape of what comes out is still the feature: one folder-rooted
        # tree an operator can extract anywhere, guest subfolders and all.
        Assert-True ($null -ne ('System.IO.Compression.ZipFile' -as [type])) `
            'no zip writer on this runtime: /archive/<cycle>.zip cannot pack anything'

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        try {
            $src = Join-Path $work $GoodLeaf
            $guest = Join-Path $src 'test-guest.ubuntu.server.24-01'
            $null = New-Item -ItemType Directory -Path $guest -Force
            Set-Content -LiteralPath (Join-Path $src 'manifest.json') -Value '{"ok":true}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $guest 'transcript.txt') -Value 'guest log' -Encoding utf8

            $out = Join-Path $work 'out.zip'
            Compress-TestCycleFolder -SourceRoot $src -CycleFolder $GoodLeaf -Destination $out
            Assert-True (Test-Path -LiteralPath $out) 'the packer produced no archive'

            # Rooting every entry at the cycle folder is what keeps the host's
            # whole log path out of the archive, and the guest subfolder has to
            # be in there or "recursively" is not what happened.
            $entries = @(Get-TestArchiveEntry -Path $out)
            Assert-True ($entries -contains "$GoodLeaf/manifest.json") 'the cycle file is missing from the archive'
            Assert-True ($entries -contains "$GoodLeaf/test-guest.ubuntu.server.24-01/transcript.txt") `
                'the guest subfolder is missing: the archive must be recursive'
            foreach ($e in $entries) {
                Assert-True ($e -eq $GoodLeaf -or $e.StartsWith("$GoodLeaf/")) `
                    "archive entry '$e' escapes the cycle folder: every entry must be rooted at it"
            }
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'packs a file that is still being written, as a running cycle always has' {
        # An operator shares the cycle they are watching, so the archive is built
        # over a folder with an open transcript in it. Reading with the default
        # share mode would be refused on exactly that file, losing the one an
        # operator most wanted to send.
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        try {
            $src = Join-Path $work "$GoodLeaf.incomplete"
            $null = New-Item -ItemType Directory -Path $src -Force
            $live = Join-Path $src 'transcript.html'
            $writer = [System.IO.File]::Open($live, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('<p>cycle running</p>')
                $writer.Write($bytes, 0, $bytes.Length)
                $writer.Flush()

                $out = Join-Path $work 'out.zip'
                Compress-TestCycleFolder -SourceRoot $src -CycleFolder "$GoodLeaf.incomplete" -Destination $out
                $entries = @(Get-TestArchiveEntry -Path $out)
                Assert-True ($entries -contains "$GoodLeaf.incomplete/transcript.html") `
                    'the open transcript was skipped: the packer must read with ReadWrite sharing'
            } finally { $writer.Dispose() }
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
        Assert-True ($SvcSource -match '(?s)foreach \(`\$shape in `\$secretNameShapes\) \{\s*\r?\n\s*if \(\[System\.IO\.Path\]::GetFileName\(`\$file\) -like `\$shape\)') `
            'the archive route must test every packed file name against the secret name shapes'
        Assert-True ($SvcSource -match 'if \(`\$blocked\) \{ continue \}') `
            'the packer must skip the files that matched a shape, not merely note them'
        # One list, three consumers: both deny-lists and the packer. Enumerating
        # the shapes again anywhere is how the copies drift apart.
        $consumers = [regex]::Matches($SvcSource, '\$secretNameShapes').Count
        Assert-True ($consumers -ge 4) `
            "expected the shared shapes to be defined once and read by both deny-lists and the packer, saw $consumers references"
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($SvcSource, "'\*\.snapshot\.json'").Count) `
            -Because 'the shapes must be written once, not restated per consumer'
    }

    It 'leaves a snapshot or backup out of the archive it builds' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        try {
            $src = Join-Path $work $GoodLeaf
            $nested = Join-Path $src 'test-guest.ubuntu.server.24-01'
            $null = New-Item -ItemType Directory -Path $nested -Force
            Set-Content -LiteralPath (Join-Path $src 'manifest.json') -Value '{"ok":true}' -Encoding utf8
            # The exact shapes the deny-list added after a vault snapshot turned
            # up readable under a generated name. One of them sits a level down:
            # matching on the file name has to reach every depth of the tree, or
            # a guest folder is the way around the list.
            foreach ($leak in @('vault.snapshot.json', 'test.config.snapshot.2026.json', 'creds.bak', 'creds.backup', 'x.tmp')) {
                Set-Content -LiteralPath (Join-Path $src $leak) -Value 'secret' -Encoding utf8
            }
            Set-Content -LiteralPath (Join-Path $nested 'guest.vault.bak') -Value 'secret' -Encoding utf8

            $out = Join-Path $work 'out.zip'
            Compress-TestCycleFolder -SourceRoot $src -CycleFolder $GoodLeaf -Destination $out `
                -Exclude @('*.snapshot.json', '*.snapshot.*.json', '*.backup', '*.bak', '*.tmp')

            $entries = @(Get-TestArchiveEntry -Path $out)
            Assert-True ($entries -contains "$GoodLeaf/manifest.json") 'the cycle artifact must still be packed'
            $findings = @()
            foreach ($e in $entries) {
                if ($e -match '\.(snapshot\.json|backup|bak|tmp)$' -or $e -match '\.snapshot\..*\.json$') {
                    $findings += "the archive carries '$e', which the server refuses to serve on its own"
                }
            }
            Assert-NoFinding $findings 'the name-shape exclusion must hold, or the archive is a way around the deny-list'
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'cleans up the archive it wrote, whatever happened' {
        # The zip is written under the runtime dir so a pack that fails halfway
        # can still answer 500 rather than a truncated download. Leaving one
        # behind per share would grow the runtime dir without bound.
        Assert-True ($SvcSource -match 'share-cycle\.') 'the temp archive name is gone'
        Assert-True ($SvcSource -match '(?s)ZipFile\]::Open\(`\$tmpArchive.*?finally \{\s*\r?\n\s*Remove-Item -LiteralPath `\$tmpArchive') `
            'the temp archive must be removed in a finally, so a failed pack does not leak it'
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
            if (-not ("$folder.zip" -match $ArchiveRegex)) { $findings += "the host rejects '$folder' but the share page accepts it" }
        }
        foreach ($folder in @('../etc', "sub/$GoodLeaf", '000724.2026-08-05.01-47-56.nothex', '')) {
            if ($folder -match $jsRegex) { $findings += "the share page accepts '$folder', which the host refuses" }
            if ("$folder.zip" -match $ArchiveRegex) { $findings += "the host accepts '$folder', which the share page refuses" }
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
        # The body says the archive is attached because the fallback leaves the
        # attaching to the operator: a mail client that reads its own draft for
        # that word is the last warning before a message that promises a file
        # and carries none.
        Assert-True ($ShareJs -match "var body = 'Yuruna cycle results are attached'") `
            'the mail body is not "Yuruna cycle results are attached"'
        Assert-True ($ShareJs -match "mailto:\?subject=") 'the draft is no longer opened with mailto:'
    }

    It 'names a zip at both ends, and asks for one' {
        # The archive is downloaded by a browser and then attached to a message.
        # A .zip is a type both ends already understand; a gzipped tarball reads
        # as an opaque blob to download reputation checks and mail scanners.
        Assert-True ($ShareRegion.Length -gt 0) 'the share-cycle region is gone from yuruna.common.js'
        $findings = @()
        if ($ShareRegion -notmatch "info\.stamp \+ '\.zip'") { $findings += 'the attachment name is not a .zip' }
        if ($ShareRegion -notmatch "encodeURIComponent\(info\.folder\) \+ '\.zip'") { $findings += 'the page asks the host for something other than a .zip' }
        if ($ShareRegion -match 'tar\.gz') { $findings += 'the share page still names a tar.gz somewhere' }
        if ($ShareRegion -notmatch "type: 'application/zip'") { $findings += 'the shared File is not typed as a zip' }
        Assert-NoFinding $findings 'one archive format, named the same by the page, the file and the share sheet'
    }

    It 'shows the attach step as an instruction rather than fine print' {
        # On the download path the message is incomplete until the operator
        # attaches the file themselves, so the sentence that says so has to
        # carry weight on the page.
        Assert-True ($SharePage -match '<strong>[^<]*attach\s+the\s+downloaded\s+file\s+before\s+sending\.\s*</strong>') `
            'the attach instruction is no longer emphasised on the share page'
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
