<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42ebb62d-e1a8-4c57-811c-f982498db617
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service archive provenance revision pester
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
    The committed-content tarball carries proof of which commit it is.
.DESCRIPTION
    `git archive` strips .git/, so a guest brought up from the tarball has no
    repository to interrogate: every `git rev-parse` there fails and the running
    service can name a version but not a revision. A deployment that cannot name
    its commit cannot be tied to reviewed source, and "the fix is deployed" then
    rests on the operator's memory of which tarball was fetched.

    Two sidecars at archive root close that. .yuruna-origin says where the tree
    came from; .yuruna-revision says which commit it is. Both are written by the
    one archive streamer both endpoints share, so the framework tarball and the
    project tarball behave identically.

    The commit is resolved BEFORE the archive is cut and the archive is taken of
    that object name rather than of `HEAD`, so a commit landing between the two
    git invocations cannot leave the sidecar describing a tree the tarball does
    not contain. Only a full 40-character object name is written: an abbreviated
    value cannot be compared against a candidate commit without ambiguity.

    The server is emitted from a here-string, so what runs on a host is not this
    file -- it is the text the launcher produces. The streamer is expanded the
    way the launcher expands it, lifted out of the result, and called, so what is
    asserted is the behavior of the code that will be on the host.

    The tarball is read with a minimal tar walk rather than an external
    extractor: the entries under test are at archive root, and a byte-level read
    depends on nothing the suite would have to detect per platform.

    Run: Invoke-Pester -Path test/modules/Test.StatusArchiveProvenance.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot    = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:ServicePath = Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1'
$script:DiagnosticsGoPath = Join-Path $script:RepoRoot `
    'test/extension/pool-control-service/server/internal/httpsrv/diagnostics.go'

# The generated server, produced the way the launcher produces it. The template
# writes every runtime variable with a leading backtick so it survives
# generation; reading the template would leave those backticks in place and
# assert against text the host never runs. ExpandString performs exactly the
# interpolation the here-string performs.
function Get-GeneratedServerText {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $lines = [IO.File]::ReadAllLines($script:ServicePath)
    $start = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match '^\$serverScript = @"$') { $start = $i + 1; continue }
        if ($start -ge 0 -and $lines[$i] -match '^"@$') { $end = $i - 1; break }
    }
    if ($start -lt 0 -or $end -lt $start) { throw 'could not find the server here-string in the launcher' }
    return $ExecutionContext.InvokeCommand.ExpandString((($lines[$start..$end]) -join "`n"))
}

$script:ServerText = Get-GeneratedServerText

function Get-FunctionFromServer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:ServerText, [ref]$null, [ref]$null)
    $found = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $found) { return '' }
    return $found.Extent.Text
}

# The streamer plus the surroundings the running server supplies: the error sink
# and the response objects the request handler already holds. Bound here rather
# than mocked so the call under test is the shipped one.
function New-ArchiveInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a scriptblock in memory; there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    $text = Get-FunctionFromServer -Name 'Send-GitArchive'
    if (-not $text) { throw 'Send-GitArchive is not in the emitted server' }
    return [scriptblock]::Create(@"
param([string]`$RepoDir, [string]`$Method)
`$script:ServerErr = @()
function Write-ServerErr { param([string]`$Message) `$script:ServerErr += `$Message }
$text
`$stream   = [System.IO.MemoryStream]::new()
`$response = [pscustomobject]@{
    StatusCode      = 200
    ContentType     = ''
    ContentLength64 = 0
    Headers         = [System.Net.WebHeaderCollection]::new()
    OutputStream    = `$stream
}
`$request = [pscustomobject]@{ HttpMethod = `$Method }
`$context = [pscustomobject]@{ Response = [pscustomobject]@{} }
`$context.Response | Add-Member -MemberType ScriptMethod -Name Abort -Value { }
Send-GitArchive -Response `$response -Request `$request -Context `$context ``
    -RepoDir `$RepoDir -ErrorLabel 'test-archive'
[pscustomobject]@{
    StatusCode      = `$response.StatusCode
    ContentType     = `$response.ContentType
    ContentLength64 = [long]`$response.ContentLength64
    Bytes           = `$stream.ToArray()
    ServerErr       = `$script:ServerErr
}
"@)
}

$script:InvokeArchive = New-ArchiveInvoker

# Entries at archive root, read straight out of the tar stream. A tar member is
# a 512-byte header followed by its content padded to 512; the name is the first
# NUL-terminated field and the size is an octal string at offset 124. Nothing
# here needs the long-name extensions, because the sidecars are single root
# files with ASCII names.
function Read-TarGzEntry {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $raw = [System.IO.MemoryStream]::new()
    $gz  = [System.IO.Compression.GZipStream]::new(
        [System.IO.MemoryStream]::new($Bytes), [System.IO.Compression.CompressionMode]::Decompress)
    try { $gz.CopyTo($raw) } finally { $gz.Dispose() }
    $tar = $raw.ToArray()

    $entries = @{}
    $offset  = 0
    while (($offset + 512) -le $tar.Length) {
        $name = [System.Text.Encoding]::ASCII.GetString($tar, $offset, 100).TrimEnd([char]0)
        if (-not $name) { break }
        $sizeField = [System.Text.Encoding]::ASCII.GetString($tar, $offset + 124, 12).Trim([char]0, ' ')
        $size = if ($sizeField) { [Convert]::ToInt64($sizeField, 8) } else { 0 }
        $offset += 512
        if ($size -gt 0 -and ($offset + $size) -le $tar.Length) {
            $entries[$name] = [System.Text.Encoding]::UTF8.GetString($tar, $offset, [int]$size)
        } elseif ($size -eq 0) {
            $entries[$name] = ''
        }
        $offset += [int]([math]::Ceiling($size / 512.0) * 512)
    }
    return $entries
}

# One repository with exactly one commit, and an origin only when asked for. Its
# working tree carries a file the archive must contain, so a tarball of the
# wrong tree is visible rather than merely unproven.
function New-ArchiveFixtureRepo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a throwaway repository under the temp path; there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$OriginUrl)

    $dir = New-YurunaTestTempDir -Prefix 'archive-provenance'
    $git = { param([string[]]$Arg) & git -C $dir @Arg 2>&1 | Out-Null }
    & $git @('init', '--quiet')
    & $git @('config', 'user.name', 'suite')
    & $git @('config', 'user.email', 'suite@example.invalid')
    [IO.File]::WriteAllText((Join-Path $dir 'VERSION'), "0.0.0`n")
    & $git @('add', 'VERSION')
    & $git @('commit', '--quiet', '-m', 'seed')
    if ($OriginUrl) { & $git @('remote', 'add', 'origin', $OriginUrl) }
    $head = (& git -C $dir rev-parse HEAD 2>$null | Select-Object -First 1)
    return @{ Path = $dir; Head = ([string]$head).Trim() }
}
}

Describe 'the committed-content tarball names the commit it was cut from' {

    It 'emits a syntactically valid server script' {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $script:ServerText, [ref]$null, [ref]$parseErrors)

        $findings = @($parseErrors | ForEach-Object {
                "line $($_.Extent.StartLineNumber), column $($_.Extent.StartColumnNumber): $($_.Message)"
            })
        Assert-NoFinding $findings `
            'the expanded server here-string does not parse as the status-service child will parse it'
    }

    It 'wires both public archive routes to the shared streamer and the intended repository' {
        $frameworkRoute = 'if ($path -eq ''yuruna-archive.tar.gz'')'
        $projectRoute = 'if ($path -eq ''yuruna-project-archive.tar.gz'')'
        $frameworkCall = 'Send-GitArchive -Response $res -Request $req -Context $ctx -RepoDir $repoRoot -ErrorLabel ''yuruna-archive'''
        $projectCall = 'Send-GitArchive -Response $res -Request $req -Context $ctx -RepoDir $projectRoot -ErrorLabel ''yuruna-project-archive'''

        $frameworkRouteAt = $script:ServerText.IndexOf($frameworkRoute, [StringComparison]::Ordinal)
        $projectRouteAt = $script:ServerText.IndexOf($projectRoute, [StringComparison]::Ordinal)
        $frameworkCallAt = $script:ServerText.IndexOf($frameworkCall, [StringComparison]::Ordinal)
        $projectCallAt = $script:ServerText.IndexOf($projectCall, [StringComparison]::Ordinal)

        Assert-True ($frameworkRouteAt -ge 0) 'the framework archive route is absent from the emitted server'
        Assert-True ($projectRouteAt -gt $frameworkRouteAt) `
            'the project archive route is absent or no longer follows the framework route'
        Assert-True ($frameworkCallAt -gt $frameworkRouteAt -and $frameworkCallAt -lt $projectRouteAt) `
            'the framework archive route does not stream the framework repository'
        Assert-True ($projectCallAt -gt $projectRouteAt) `
            'the project archive route does not stream the project repository'
        Assert-Equal -Expected 2 -Actual ([regex]::Matches(
                $script:ServerText, 'Send-GitArchive\s+-Response').Count) `
            'an archive endpoint bypasses the shared streamer or an unexpected caller was added'
    }

    It 'archives the resolved object name rather than the moving HEAD' {
        $text = Get-FunctionFromServer -Name 'Send-GitArchive'

        Assert-True ($text -match "rev-parse\s+HEAD") `
            'the streamer never resolves the commit it is about to archive'
        Assert-True ($text -match "'\^\[0-9a-f\]\{40\}\`$'") `
            'the resolved revision is used without proving it is a full object name'
        Assert-True ($text -match "@\('-o',\s*\`$tmp,\s*\`$treeish\)") `
            'the archive is still taken of HEAD, so a commit landing mid-request destroys the match'
    }

    It 'carries both sidecars for a repository that has an origin' {
        $repo = New-ArchiveFixtureRepo -OriginUrl 'https://example.invalid/yuruna.git'
        try {
            $result = & $script:InvokeArchive $repo.Path 'GET'
            Assert-NoFinding @($result.ServerErr) 'the streamer reported an error'
            Assert-Equal -Expected 200 -Actual $result.StatusCode 'the archive was not served'

            $entries = Read-TarGzEntry -Bytes $result.Bytes
            Assert-True $entries.ContainsKey('.yuruna-revision') `
                'the tarball carries no revision sidecar, so an extracted tree cannot name its commit'
            Assert-StringEqual -Expected $repo.Head -Actual ($entries['.yuruna-revision'].Trim()) `
                'the revision sidecar does not name the archived commit'
            Assert-StringEqual -Expected 'https://example.invalid/yuruna.git' `
                -Actual ($entries['.yuruna-origin'].Trim()) `
                'the origin sidecar no longer records where the tree came from'
            Assert-True $entries.ContainsKey('VERSION') `
                'the tarball does not carry the committed tree'
        } finally { Remove-YurunaTestTempDir -Path $repo.Path }
    }

    It 'records the revision even when the repository has no origin remote' {
        # The two sidecars answer different questions and one being unanswerable
        # must not suppress the other.
        $repo = New-ArchiveFixtureRepo
        try {
            $entries = Read-TarGzEntry -Bytes (& $script:InvokeArchive $repo.Path 'GET').Bytes
            Assert-True (-not $entries.ContainsKey('.yuruna-origin')) `
                'an origin sidecar was written for a repository that has no origin'
            Assert-StringEqual -Expected $repo.Head -Actual ($entries['.yuruna-revision'].Trim()) `
                'the revision sidecar is missing when there is no origin to report'
        } finally { Remove-YurunaTestTempDir -Path $repo.Path }
    }

    It 'writes a full object name, never an abbreviation' {
        $repo = New-ArchiveFixtureRepo
        try {
            $entries = Read-TarGzEntry -Bytes (& $script:InvokeArchive $repo.Path 'GET').Bytes
            Assert-Match -Pattern '^[0-9a-f]{40}$' -Actual ($entries['.yuruna-revision'].Trim()) `
                'an abbreviated revision cannot be compared against a candidate commit without ambiguity'
        } finally { Remove-YurunaTestTempDir -Path $repo.Path }
    }

    It 'answers a HEAD request with the same length and no body' {
        # The sidecars change the archive's size, so the advertised length has to
        # be the one the GET would actually write.
        $repo = New-ArchiveFixtureRepo
        try {
            $get  = & $script:InvokeArchive $repo.Path 'GET'
            $head = & $script:InvokeArchive $repo.Path 'HEAD'
            Assert-Equal -Expected $get.Bytes.Length -Actual $get.ContentLength64 `
                'the GET Content-Length does not describe the emitted archive bytes'
            Assert-Equal -Expected $get.Bytes.Length -Actual $head.ContentLength64 `
                'HEAD does not advertise the length of the corresponding GET archive'
            Assert-Equal -Expected 0 -Actual $head.Bytes.Length 'a HEAD response carried a body'
            Assert-StringEqual -Expected 'application/gzip' -Actual $get.ContentType `
                'the archive is no longer served as a gzip stream'
        } finally { Remove-YurunaTestTempDir -Path $repo.Path }
    }

    It 'refuses to serve an archive of a directory that is not a repository' {
        $dir = New-YurunaTestTempDir -Prefix 'archive-provenance-nonrepo'
        try {
            $result = & $script:InvokeArchive $dir 'GET'
            Assert-Equal -Expected 500 -Actual $result.StatusCode `
                'a non-repository produced something other than a failure'
            Assert-True ($result.Bytes.Length -gt 0) 'the failure carried no explanation'
        } finally { Remove-YurunaTestTempDir -Path $dir }
    }

    It 'names the sidecar the same way the consuming service does' {
        # The producer is PowerShell and the consumer is Go, so nothing but a
        # test holds the two spellings together; a rename on one side would
        # otherwise show up as a deployment that silently cannot prove itself.
        $goSource = [IO.File]::ReadAllText($script:DiagnosticsGoPath)
        $goName = [regex]::Match($goSource, 'frameworkRevisionSidecar\s*=\s*"([^"]+)"')
        Assert-True $goName.Success 'the pool diagnostics reader declares no revision sidecar name'
        Assert-StringEqual -Expected '.yuruna-revision' -Actual $goName.Groups[1].Value `
            'the reader looks for a sidecar the archive streamer does not write'
    }
}
