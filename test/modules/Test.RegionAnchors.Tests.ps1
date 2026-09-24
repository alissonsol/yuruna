<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42a1c8e3-5b47-4f60-9d2a-7e83b415cc09
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test docs anchors region pester
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
    Hold the REGION anchor gate to reaching a verdict, and to failing when
    a pointer names a heading that is not there.
.DESCRIPTION
    Every published `docs/` heading is a public address: a REGION pointer in
    the source names a slug and an anchor, and readers follow it from
    yuruna.link. Renaming a heading breaks those links silently, which is
    what tools/Test-RegionAnchors.ps1 exists to catch.

    The gate reads its slug-to-document map from a sibling checkout, and for
    a long time it warned and exited 0 when that map was absent. On a host
    without the sibling clone -- which includes any fresh environment -- it
    therefore reported success over nothing at all, and a green run meant
    only that the map could not be found. It now exits 2 there: it has
    checked nothing and says so, so a caller that requires evidence can tell
    the difference between "the pointers resolve" and "no pointer was read".

    This suite pins the three outcomes apart. It builds its own fixture map
    rather than trusting the sibling checkout, because a suite that passes
    only where someone happens to have cloned a second repository is the
    same failure the gate itself had.

    Run: Invoke-Pester -Path test/modules/Test.RegionAnchors.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Gate = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Test-RegionAnchors.ps1'

# A child pwsh, because the exit code is the whole contract here and only
# survives a process boundary.
function Invoke-Gate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]]$Argument)
    $argv = @('-NoProfile', '-File', $script:Gate) + $Argument
    $out = (& pwsh @argv 2>&1 | Out-String)
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-anchors-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

# The map shape is [ <slug or slug array>, <title>, <url or url array> ].
function New-LinkMap {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Entry)
    $path = Join-Path $script:Sandbox $Name
    Set-Content -LiteralPath $path -Value ($Entry | ConvertTo-Json -Depth 6 -AsArray) -Encoding utf8
    return $path
}

$script:RealMap = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna.link/yuruna.link.json'
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'the anchor gate says which of the three things happened' {

    It 'exits 2 when the link map is absent, having checked nothing' {
        $missing = Join-Path $script:Sandbox 'no-such-map.json'
        $run = Invoke-Gate -Argument @('-Quiet', '-LinkMap', $missing)
        Assert-Equal -Expected 2 -Actual $run.ExitCode `
            -Because "a gate that read no map has proved nothing and must not report success:`n$($run.Output)"
        Assert-Match -Pattern 'link map not found' -Actual $run.Output `
            'the warning has to name the missing input'
    }

    It 'fails when a pointer names an anchor id that does not exist' {
        # Every pointer in the tree now addresses a heading by id, so the
        # defect this gate exists for is an id naming nothing -- a heading
        # deleted, or a pointer typed by hand. Handing it an index with no
        # ids at all makes every real pointer unresolvable at once, which is
        # the same condition one deleted heading produces for one pointer.
        $empty = Join-Path $script:Sandbox 'no-anchors.json'
        Set-Content -LiteralPath $empty -Value '{ "schema": "yuruna.doc-anchors/v1", "files": [] }' -Encoding utf8
        $run = Invoke-Gate -Argument @('-Quiet', '-AnchorManifest', $empty)
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "an id that names no heading is the defect this gate exists for:`n$($run.Output)"
        Assert-Match -Pattern 'names no heading' -Actual $run.Output `
            'the report has to say the id resolves to nothing'
    }

    It 'fails when an id is recorded but the document no longer carries it' {
        # The manifest is generated FROM the documents, so checking a pointer
        # against the manifest alone proves only that the generator ran. A
        # heading deleted and its id later reissued to different text would
        # still look valid, and every published link to it would land on
        # unrelated prose without any error -- the exact silent failure the
        # id scheme exists to remove. So the gate asks the document.
        #
        # This points a real id at a document that does not contain it, which
        # is the same condition a deleted heading produces.
        $real = ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath (
            Join-Path $script:RepoRoot 'globalization/manifests/doc-anchors.json'))
        $victim = @($real.files | Where-Object { @($_.anchors).Count -gt 0 })[0]
        $moved = Join-Path $script:Sandbox 'moved-anchors.json'
        $payload = [ordered]@{
            schema = 'yuruna.doc-anchors/v1'
            files  = @(@($real.files) | ForEach-Object {
                [ordered]@{
                    id      = $_.id
                    repo    = $_.repo
                    # Every file claims a document that carries none of these ids.
                    source  = 'docs/accessibility.md'
                    anchors = @($_.anchors)
                }
            })
        }
        Set-Content -LiteralPath $moved -Value ($payload | ConvertTo-Json -Depth 8) -Encoding utf8
        Assert-True ($null -ne $victim) 'the real manifest carries no anchors to move'

        $run = Invoke-Gate -Argument @('-Quiet', '-AnchorManifest', $moved)
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "an id the document does not carry has to fail, or a deleted heading goes unnoticed:`n$($run.Output)"
    }

    It 'accepts every anchor id the generator recorded' {
        # The other direction: with the real index, the ids actually written
        # into the documents all resolve. A gate that only ever failed would
        # be as useless as one that only ever passed.
        $run = Invoke-Gate -Argument @('-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a pointer names an id the documents no longer carry:`n$($run.Output)"
    }

    It 'does not fail a slug it cannot resolve to a document in this repository' {
        # A slug whose target is an external site is outside what this gate
        # can see. Reporting it is right; failing on it would make every
        # external reference a build break.
        $map = New-LinkMap -Name 'external-only.json' -Entry @(
            , @('5whys', 'Why?', 'https://alissonsol.blogspot.com/2020/02/why.html'))
        $run = Invoke-Gate -Argument @('-Quiet', '-LinkMap', $map)
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "an unresolvable slug is reported, not failed:`n$($run.Output)"
    }

    It 'resolves every pointer against the real map when the sibling checkout is there' {
        if (-not (Test-Path -LiteralPath $script:RealMap -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'the yuruna.link sibling checkout is not present on this host'
            return
        }
        $run = Invoke-Gate -Argument @('-Quiet', '-LinkMap', $script:RealMap)
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a published heading was renamed without its pointers:`n$($run.Output)"
    }

    It 'rejects a broken pointer copied into the project candidate' {
        $sourceProject = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
        $sourceRelative = 'example/text-to-sql/components/frontend/text-to-sql-ui/Services/ClaudeLlmClient.cs'
        $documentRelative = 'example/text-to-sql/README.md'
        if (-not (Test-Path -LiteralPath (Join-Path $sourceProject $sourceRelative) -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $sourceProject $documentRelative) -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'the source project checkout is not beside the framework'
            return
        }

        $project = Join-Path $script:Sandbox 'project-pointer-candidate'
        foreach ($relative in @($sourceRelative, $documentRelative)) {
            $destination = Join-Path $project $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $sourceProject $relative) -Destination $destination
        }
        $sourcePath = Join-Path $project $sourceRelative
        $source = [IO.File]::ReadAllText($sourcePath).Replace(
            '4286c679-0007', '4286c679-dead')
        [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
        $null = & git -C $project init --quiet 2>&1
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE 'could not initialize the project candidate fixture'

        $map = New-LinkMap -Name 'project-local.json' -Entry @(
            , @('4286c679', 'Text-to-SQL',
                'https://github.com/alissonsol/yuruna-project/blob/main/example/text-to-sql/README.md'))
        $run = Invoke-Gate -Argument @(
            '-Quiet', '-ProjectRoot', $project, '-Path', $project, '-LinkMap', $map)
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "a broken pointer in the staged project was invisible:`n$($run.Output)"
        Assert-Match -Pattern 'yuruna-project/.+ClaudeLlmClient\.cs' -Actual $run.Output
        Assert-Match -Pattern '4286c679-dead' -Actual $run.Output
    }

    It 'passes the selected project root from cross-repository orchestration' {
        $crossRepo = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools/Invoke-CrossRepoGate.ps1'))
        $pattern = '(?s)\$anchorArgs\s*=\s*@\(.*?''-ProjectRoot'',\s*\$ProjectRoot\)'
        Assert-Match -Pattern $pattern `
            -Actual $crossRepo `
            -Because 'the staged project checkout is not supplied to the region-anchor leaf'
    }
}
