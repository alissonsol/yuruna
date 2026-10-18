<#PSScriptInfo
.VERSION 2026.10.18
.GUID 428d0026-4579-4914-a98d-4a8df192c465
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status archive framework scope pester
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
    The framework tarball a guest fetches every cycle carries dev-only/ and
    docs/ out: no guest-side code reads either, and the public repository
    does not even have the first one.
.DESCRIPTION
    Two kinds of evidence, matching Test.StatusArchiveProvenance's own
    pattern for this same streamer:

      * an audit over the actual guest/, automation/ and host/vmconfig/
        sources (and the project checkout, when present) that no local
        reference to dev-only/ or docs/ survives outside a Markdown link or
        an external URL that merely contains the word "docs";
      * the emitted Send-GitArchive, lifted out of the generated server text
        the way the launcher expands it and called against a throwaway
        repository, proving the pathspec actually removes both folders from
        the bytes a guest receives, and that the cache key keeps a scoped
        and an unscoped archive of the same commit from colliding.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
    $script:ServicePath = Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1'

    function Confirm-SiblingCheckout {
        param([Parameter(Mandatory)][string]$Path)
        $Path | Should -Exist -Because "the $(Split-Path -Leaf $Path) checkout has to sit beside the framework checkout; clone it there and run this suite again"
    }

    # The template writes every runtime variable with a leading backtick so it
    # survives generation; ExpandString performs exactly the interpolation the
    # here-string performs, matching what a host actually runs.
    function Get-GeneratedServerText {
        [CmdletBinding()]
        [OutputType([string])]
        param()
        return Get-YurunaTestGeneratedServerText -Path $script:ServicePath -Expand { param($Raw) $ExecutionContext.InvokeCommand.ExpandString($Raw) }
    }
    $script:ServerText = Get-GeneratedServerText
    $script:ServerAst = [Management.Automation.Language.Parser]::ParseInput($script:ServerText, [ref]$null, [ref]$null)

    function Get-FunctionFromServer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Name)
        $found = Get-YurunaTestFunctionAst -Ast $script:ServerAst -Name $Name
        if (-not $found) { return '' }
        return $found.Extent.Text
    }

    # The streamer plus the surroundings the running server supplies, bound
    # here rather than mocked so the call under test is the shipped one.
    function New-ArchiveInvoker {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a scriptblock in memory; there is nothing for an operator to confirm.')]
        [CmdletBinding()]
        [OutputType([scriptblock])]
        param()
        $text = Get-FunctionFromServer -Name 'Send-GitArchive'
        $routeImport = Get-FunctionFromServer -Name 'Import-RouteModule'
        if (-not $text) { throw 'Send-GitArchive is not in the emitted server' }
        return [scriptblock]::Create(@"
param([string]`$RepoDir, [string[]]`$ExcludePath)
`$script:ServerErr = @()
function Write-ServerErr { param([string]`$Message) `$script:ServerErr += `$Message }
$routeImport
$text
`$stream   = [System.IO.MemoryStream]::new()
`$response = [pscustomobject]@{
    StatusCode      = 200
    ContentType     = ''
    ContentLength64 = 0
    Headers         = [System.Net.WebHeaderCollection]::new()
    OutputStream    = `$stream
}
`$request = [pscustomobject]@{ HttpMethod = 'GET' }
`$context = [pscustomobject]@{ Response = [pscustomobject]@{} }
`$context.Response | Add-Member -MemberType ScriptMethod -Name Abort -Value { }
Send-GitArchive -Response `$response -Request `$request -Context `$context ``
    -RepoDir `$RepoDir -ErrorLabel 'test-archive' -ExcludePath `$ExcludePath
[pscustomobject]@{
    StatusCode = `$response.StatusCode
    Bytes      = `$stream.ToArray()
    ServerErr  = `$script:ServerErr
}
"@)
    }
    $script:InvokeArchive = New-ArchiveInvoker

    # Entries at archive root, read straight out of the tar stream -- the same
    # minimal walk Test.StatusArchiveProvenance uses: a tar member is a 512-byte
    # header followed by its content padded to 512, name first, size octal at
    # offset 124.
    function Get-TarGzEntryName {
        [CmdletBinding()]
        [OutputType([string[]])]
        param([Parameter(Mandatory)][byte[]]$Bytes)
        $raw = [System.IO.MemoryStream]::new()
        $gz = [System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($Bytes), [System.IO.Compression.CompressionMode]::Decompress)
        try { $gz.CopyTo($raw) } finally { $gz.Dispose() }
        $tar = $raw.ToArray()
        $names = [System.Collections.Generic.List[string]]::new()
        $offset = 0
        while (($offset + 512) -le $tar.Length) {
            $name = [System.Text.Encoding]::ASCII.GetString($tar, $offset, 100).TrimEnd([char]0)
            if (-not $name) { break }
            $sizeField = [System.Text.Encoding]::ASCII.GetString($tar, $offset + 124, 12).Trim([char]0, ' ')
            $size = if ($sizeField) { [Convert]::ToInt64($sizeField, 8) } else { 0 }
            [void]$names.Add($name)
            $offset += 512 + [int]([math]::Ceiling($size / 512.0) * 512)
        }
        return $names.ToArray()
    }

    function New-ArchiveScopeFixtureRepo {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a throwaway repository under the temp path; there is nothing for an operator to confirm.')]
        [CmdletBinding()]
        [OutputType([string])]
        param()
        $dir = New-YurunaTestTempDir -Prefix 'archive-scope'
        $git = { param([string[]]$Arg) & git -C $dir @Arg 2>&1 | Out-Null }
        & $git @('init', '--quiet')
        & $git @('config', 'user.name', 'suite')
        & $git @('config', 'user.email', 'suite@example.invalid')
        foreach ($rel in 'dev-only/a.txt', 'docs/b.md', 'automation/c.ps1', 'guest/d.sh') {
            $full = Join-Path $dir $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [IO.File]::WriteAllText($full, "$rel`n")
        }
        & $git @('add', '-A')
        & $git @('commit', '--quiet', '-m', 'seed')
        return $dir
    }

    # Matches the drift check's own pattern. An external URL that happens to
    # contain the word docs/ (k8s.io/docs/...) is not a local framework path
    # and is not what this audit polices; a Markdown link is documentation
    # linking to documentation, not guest-read code.
    function Get-LocalDocsOrDevOnlyReference {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$PathSpec)
        $findings = @()
        Push-Location $Root
        try {
            $hits = @(& git grep -n -E 'yuruna/(docs|dev-only)/|[^.]/docs/' -- @PathSpec 2>$null)
        } finally { Pop-Location }
        foreach ($line in $hits) {
            if ($line -match '^(?<file>[^:]+):\d+:(?<text>.*)$') {
                $file = $Matches['file']
                $text = $Matches['text']
                if ($file -match '\.md$') { continue }
                if ($text -match '\bhttps?://\S*docs/') { continue }
                $findings += "${file}: ${text}"
            }
        }
        return $findings
    }
}

Describe 'no guest-side source reads dev-only/ or docs/ from the framework tree' {
    It 'frames the framework sources this way' {
        $findings = Get-LocalDocsOrDevOnlyReference -Root $script:RepoRoot -PathSpec @('guest', 'automation/*.sh', 'automation/*.ps1', 'host/vmconfig')
        Assert-NoFinding $findings 'excluding dev-only/ and docs/ from the framework tarball is safe only because nothing on the guest path reads either'
    }
    It 'frames the project sources this way, when the sibling checkout is present' {
        Confirm-SiblingCheckout -Path $script:ProjectRoot
        $findings = Get-LocalDocsOrDevOnlyReference -Root $script:ProjectRoot -PathSpec @('*.sh', '*.ps1', '*.yml')
        Assert-NoFinding $findings 'a project script that reads dev-only/ or docs/ from the framework tree would break under the scoped tarball'
    }
}

Describe 'the framework archive route excludes dev-only/ and docs/, without touching the project route or any other file' {
    It 'emits a syntactically valid server script' {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:ServerText, [ref]$null, [ref]$parseErrors)
        $findings = @($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" })
        Assert-NoFinding $findings 'the expanded server here-string does not parse as the status-service child will parse it'
    }
    It 'binds the framework route to -ExcludePath dev-only,docs and leaves the project route unscoped' {
        $frameworkCall = $script:ServerText.IndexOf(
            "Send-GitArchive -Response `$res -Request `$req -Context `$ctx -RepoDir `$repoRoot -ErrorLabel 'yuruna-archive' -ExcludePath @('dev-only', 'docs')",
            [StringComparison]::Ordinal)
        $projectCall = $script:ServerText.IndexOf(
            "Send-GitArchive -Response `$res -Request `$req -Context `$ctx -RepoDir `$projectRoot -ErrorLabel 'yuruna-project-archive'",
            [StringComparison]::Ordinal)
        $frameworkCall | Should -BeGreaterOrEqual 0 -Because 'the framework route no longer scopes the tarball the way the plan requires'
        $projectCall | Should -BeGreaterOrEqual 0
        $script:ServerText | Should -Not -Match ([regex]::Escape("RepoDir `$projectRoot") + '[^\r\n]*ExcludePath')
    }
    It 'removes dev-only/ and docs/ from the served bytes, keeps every other file and both sidecars' {
        $repo = New-ArchiveScopeFixtureRepo
        try {
            $scoped = & $script:InvokeArchive $repo @('dev-only', 'docs')
            Assert-NoFinding @($scoped.ServerErr) 'the streamer reported an error'
            $scoped.StatusCode | Should -Be 200
            $names = Get-TarGzEntryName -Bytes $scoped.Bytes
            $names | Should -Contain 'automation/c.ps1'
            $names | Should -Contain 'guest/d.sh'
            $names | Should -Contain '.yuruna-revision'
            $names | Where-Object { $_ -like 'dev-only/*' } | Should -BeNullOrEmpty
            $names | Where-Object { $_ -like 'docs/*' } | Should -BeNullOrEmpty
        } finally { Remove-YurunaTestTempDir -Path $repo }
    }
    It 'keeps the cache key separate for a scoped and an unscoped archive of the same commit' {
        $repo = New-ArchiveScopeFixtureRepo
        try {
            $scoped = & $script:InvokeArchive $repo @('dev-only', 'docs')
            $scopedNames = Get-TarGzEntryName -Bytes $scoped.Bytes
            $scopedNames | Where-Object { $_ -like 'dev-only/*' -or $_ -like 'docs/*' } | Should -BeNullOrEmpty

            $unscoped = & $script:InvokeArchive $repo @()
            Assert-NoFinding @($unscoped.ServerErr) 'the streamer reported an error'
            $unscopedNames = Get-TarGzEntryName -Bytes $unscoped.Bytes
            $unscopedNames | Should -Contain 'dev-only/a.txt'
            $unscopedNames | Should -Contain 'docs/b.md'
            $unscopedNames | Should -Contain 'automation/c.ps1'
            $unscopedNames | Should -Contain 'guest/d.sh'
        } finally { Remove-YurunaTestTempDir -Path $repo }
    }
}
