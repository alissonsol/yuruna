<#PSScriptInfo
.VERSION 2026.10.04
.GUID 423c6a1c-f359-436b-9533-31e9a82bfb68
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate license copyright guid metadata
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
    Gate: a code or manifest file opens with the license pointer and copyright
    line, and a PowerShell file carries a unique 42-prefixed GUID.
.DESCRIPTION
    Rules, by the name each finding carries:

      copyright        A "Copyright (c) <years> by Alisson Sol et al." line in
                       the first 40 lines. PowerShell keeps it as .COPYRIGHT in
                       the <#PSScriptInfo block; a PowerShell file without that
                       block fails as psscriptinfo.
      license-pointer  "LICENSEURI https://yuruna.link/license" on the line
                       directly above the copyright line (blank lines and bare
                       comment markers do not count), or .LICENSEURI in the
                       PSScriptInfo block.
      guid             The PSScriptInfo .GUID is well formed, starts with 42,
                       and no other tracked file declares it.
      generated-banner A file under a generated path that has no header names
                       its generator in its first 12 lines.

    Covered formats are the extensions in $StyleByExtension below. JSON has no
    comments, Markdown keeps its license in a footer, lock, checksum, key and
    image files are data, and a .template skeleton is rendered into operator
    files with its comments, so none of those is checked. An extensionless file
    is checked when it starts with a #! line.

    The only exemptions are the ones in tools/source-metadata.exemptions.json:
    generated paths (naming their generator), vendored paths, and groups of
    synchronized copies that share a GUID by design (naming their sync tool).
    Each carries a reason, and a path no entry covers is checked.

    -Staged reads the index, looks only at added, modified and renamed files,
    and blocks a gap the commit introduces. A gap already present in a file the
    commit merely edits is printed as a note, so editing an old file never
    forces a stamp. -All reads the working tree of every tracked file and
    reports the debt: a summary, the count per rule, and where the findings are.
    It also reports exemptions that match nothing or cover only files that
    already comply.

    Exit codes follow the entry-point contract (Get-EntryPointExitCode):
        0  No blocking finding.
        1  A blocking finding (-Staged: a new gap; -All: only with -FailOnDebt).
        2  No verdict: bad arguments, an invalid exemptions file, or git failed.

    Why the rules exist, and how to fix each: CONTRIBUTING.md, "Source metadata".
.PARAMETER Staged
    Check the files staged for commit. This is what the pre-commit hook runs.
.PARAMETER All
    Check every tracked file of each -Root and report the debt.
.PARAMETER Root
    Repositories to check. Default: the repository this script lives in. -Staged
    takes exactly one. With -All, GUIDs must also be unique across all of them.
.PARAMETER RepoName
    The name the exemptions file uses for the (single) -Root. Default: the
    folder name of the main checkout the root belongs to, so a linked worktree
    is named after its main checkout. That is how the exemptions file names the
    four workspace repositories (yuruna, yuruna-project, yuruna.link and
    amisad.dev); a checkout cloned into a folder of another name passes it here.
.PARAMETER ExemptionsPath
    The exemptions file. Default: source-metadata.exemptions.json beside this
    script, whichever repository -Root names.
.PARAMETER FailOnDebt
    Treat a gap that already existed as a failure: with -All, any finding; with
    -Staged, also the gaps in files the commit merely edits.
.PARAMETER Detail
    With -All, list every finding instead of the count per directory.
.PARAMETER Quiet
    With -Staged, print no success line (notes about gaps that already existed
    still print). With -All, print only the summary line.
.EXAMPLE
    pwsh tools/Test-SourceMetadata.ps1 -Staged -Quiet
    # What the pre-commit hook runs.
.EXAMPLE
    pwsh tools/Test-SourceMetadata.ps1 -All -Root ../yuruna,../yuruna-project
    # The debt report for two repositories.
#>

[CmdletBinding()]
[OutputType([void])]
param(
    [switch]$Staged,
    [switch]$All,
    [string[]]$Root,
    [string]$RepoName,
    [string]$ExemptionsPath,
    [switch]$FailOnDebt,
    [switch]$Detail,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$ToolRoot = $PSScriptRoot
$FrameworkRoot = Split-Path -Parent $ToolRoot
Import-Module (Join-Path $FrameworkRoot 'test/modules/Test.Prelude.psm1') -Global -Force
$ExitOk        = Get-EntryPointExitCode -Outcome Ok
$ExitFailure   = Get-EntryPointExitCode -Outcome Failure
$ExitCannotRun = Get-EntryPointExitCode -Outcome CannotRun

# Where a header must sit, and how much of a file is read to find it. A banner
# is shorter: it is the first thing a generator writes.
$HeaderWindow = 40
$BannerWindow = 12
$ReadBytes    = 16384

$CopyrightPattern = '\(c\)\s*\d{4}(?:\s*-\s*\d{4})?\s+by\s+Alisson Sol et al\.'
$PointerPattern   = 'LICENSEURI\s+https://yuruna\.link/license(?![\w./-])'
$GuidPattern      = '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
$ExemptionsName   = 'tools/source-metadata.exemptions.json'
$DeclareHint      = "A generated or vendored file is declared in $ExemptionsName instead (CONTRIBUTING.md, Source metadata)."

# The coverage map: which comment style a file kind takes. A style is also the
# shape of the lines a fix hint prints. psinfo has no wrapper because its header
# is the PSScriptInfo block, not two comment lines.
$Wrapper = @{
    hash = '# {0}'; slash = '// {0}'; block = '/* {0} */'; xml = '<!-- {0} -->'
    razor = '@* {0} *@'; sql = '-- {0}'; cmd = '@REM {0}'
}
$StyleByExtension = @{}
$StyleByName = @{}
foreach ($row in @(
        @{ Style = 'psinfo'; Extension = 'ps1 psm1 psd1' }
        @{ Style = 'hash'; Extension = 'sh bash py yml yaml tf hcl toml service sudoers user-data meta-data network-config bazel'; Name = 'Dockerfile BUILD WORKSPACE' }
        @{ Style = 'slash'; Extension = 'go js cjs mjs ts tsx cs rs dart mod' }
        @{ Style = 'block'; Extension = 'css' }
        @{ Style = 'xml'; Extension = 'html htm xml csproj' }
        @{ Style = 'razor'; Extension = 'cshtml' }
        @{ Style = 'sql'; Extension = 'sql' }
        @{ Style = 'cmd'; Extension = 'cmd bat' })) {
    foreach ($item in ($row.Extension -split ' ')) { $StyleByExtension['.' + $item] = $row.Style }
    foreach ($item in ($row.Name -split ' ' | Where-Object { $_ })) { $StyleByName[$item] = $row.Style }
}

# --- REGION: git
function Open-GitProcess {
    [CmdletBinding()]
    [OutputType([Diagnostics.Process])]
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Argument, [switch]$RedirectInput)
    $info = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($item in (@('-C', $Repository) + $Argument)) { $info.ArgumentList.Add($item) }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    if ($RedirectInput) {
        $info.RedirectStandardInput = $true
        $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    }
    return [Diagnostics.Process]::Start($info)
}

function Invoke-Git {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Argument)
    $process = Open-GitProcess -Repository $Repository -Argument $Argument
    $text = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ Code = $process.ExitCode; Text = $text }
}

function Read-StreamLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $next = $Stream.ReadByte()
        if ($next -lt 0) { throw 'git cat-file ended before answering every request.' }
        if ($next -eq 10) { break }
        $bytes.Add([byte]$next)
    }
    return [Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function ConvertTo-HeadLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][byte[]]$Buffer, [Parameter(Mandatory)][int]$Count)
    $text = [Text.Encoding]::UTF8.GetString($Buffer, 0, $Count)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return [string[]]@(($text -split "`r?`n") | Select-Object -First $HeaderWindow)
}

function Read-FileHead {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    $buffer = [byte[]]::new($ReadBytes)
    $stream = [IO.File]::OpenRead($Path)
    try { $count = $stream.Read($buffer, 0, $buffer.Length) } finally { $stream.Dispose() }
    return ConvertTo-HeadLine -Buffer $buffer -Count $count
}

# One cat-file process answers every spec ("<revision>:<path>"), a request and
# its reply at a time so neither pipe can fill while the other side waits. The
# value is the first lines of the blob, or $null when the object is missing.
function Read-GitObjectHead {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Repository, [string[]]$Spec)
    $heads = @{}
    if (-not $Spec) { return $heads }
    $process = Open-GitProcess -Repository $Repository -Argument @('cat-file', '--batch') -RedirectInput
    $stream = $process.StandardOutput.BaseStream
    $scratch = [byte[]]::new(65536)
    try {
        foreach ($item in $Spec) {
            $process.StandardInput.Write($item + "`n")
            $process.StandardInput.Flush()
            $reply = Read-StreamLine -Stream $stream
            if ($reply -notmatch '^[0-9a-f]{40,64} (\w+) (\d+)$') { $heads[$item] = $null; continue }
            $isBlob = $Matches[1] -eq 'blob'
            $left = [long]$Matches[2]
            $keep = [byte[]]::new([Math]::Min($left, $ReadBytes))
            $filled = 0
            while ($filled -lt $keep.Length) {
                $got = $stream.Read($keep, $filled, $keep.Length - $filled)
                if ($got -le 0) { throw 'git cat-file ended inside an object.' }
                $filled += $got
            }
            $left -= $keep.Length
            while ($left -gt 0) {
                $got = $stream.Read($scratch, 0, [int][Math]::Min($left, $scratch.Length))
                if ($got -le 0) { throw 'git cat-file ended inside an object.' }
                $left -= $got
            }
            [void]$stream.ReadByte()
            $heads[$item] = if ($isBlob) { ConvertTo-HeadLine -Buffer $keep -Count $keep.Length } else { $null }
        }
    } finally {
        $process.StandardInput.Close()
        $process.WaitForExit()
    }
    return $heads
}

# --- REGION: exemptions
function Read-Exemption {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $errors = [Collections.Generic.List[string]]::new()
    $entries = [Collections.Generic.List[object]]::new()
    $groups = [Collections.Generic.List[object]]::new()
    $document = $null
    try { $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -AsHashtable }
    catch { $errors.Add("cannot read or parse it: $($_.Exception.Message)") }
    if ($document -isnot [hashtable]) {
        if ($errors.Count -eq 0) { $errors.Add('the top level must be a JSON object') }
        return [pscustomobject]@{ Errors = $errors; Entry = $entries; Group = $groups }
    }
    if ($document['schema'] -cne 'yuruna.source-metadata/v1') { $errors.Add('"schema" must be "yuruna.source-metadata/v1"') }
    foreach ($key in $document.Keys) {
        if ($key -cnotin 'schema', 'description', 'generated', 'vendored', 'synchronizedCopies') { $errors.Add("unknown top-level key '$key'") }
    }
    $shapes = @(
        @{ Section = 'generated'; Required = 'repo', 'generator', 'paths', 'reason' }
        @{ Section = 'vendored'; Required = 'repo', 'paths', 'reason' }
        @{ Section = 'synchronizedCopies'; Required = 'repo', 'syncTool', 'files', 'reason' })
    foreach ($shape in $shapes) {
        $list = $document[$shape.Section]
        if ($null -eq $list) { continue }
        if ($list -isnot [array]) { $errors.Add("'$($shape.Section)' must be an array"); continue }
        for ($i = 0; $i -lt $list.Count; $i++) {
            $item = $list[$i]
            $label = "$($shape.Section)[$i]"
            if ($item -isnot [hashtable]) { $errors.Add("$label must be an object"); continue }
            foreach ($key in $item.Keys) {
                if ($key -cnotin $shape.Required) { $errors.Add("$label has unknown key '$key'") }
            }
            $complete = $true
            foreach ($key in $shape.Required) {
                $value = $item[$key]
                if ($value -is [array]) { $present = $value.Count -gt 0 -and -not @($value | Where-Object { $_ -isnot [string] -or -not $_.Trim() }) }
                else { $present = $value -is [string] -and [bool]$value.Trim() }
                if (-not $present) { $errors.Add("$label needs a non-empty '$key'"); $complete = $false }
            }
            if ($complete -and $shape.Section -eq 'synchronizedCopies' -and $item['files'].Count -lt 2) {
                $errors.Add("$label needs at least two 'files' (one file has nothing to be a copy of)")
                $complete = $false
            }
            if (-not $complete) { continue }
            # Paths are matched as repository-relative with forward slashes.
            if ($shape.Section -eq 'synchronizedCopies') {
                $groups.Add([pscustomobject]@{ Repo = $item['repo']; Tool = $item['syncTool']; File = @($item['files'] -replace '\\', '/'); Label = $label })
            } else {
                $generator = if ($shape.Section -eq 'generated') { $item['generator'] } else { $null }
                $entries.Add([pscustomobject]@{ Kind = $shape.Section; Repo = $item['repo']; Path = @($item['paths'] -replace '\\', '/'); Label = $label; Generator = $generator })
            }
        }
    }
    return [pscustomobject]@{ Errors = $errors; Entry = $entries; Group = $groups }
}

function Resolve-Exemption {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$RelativePath)
    foreach ($entry in $Exemption.Entry) {
        if ($entry.Repo -ne $Repo) { continue }
        foreach ($pattern in $entry.Path) {
            if ($RelativePath -clike $pattern) { return $entry }
        }
    }
    return $null
}

# --- REGION: rules
function Get-FreshGuid {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $n = [guid]::NewGuid().ToString('N')
    return '42' + $n.Substring(2, 6) + '-' + $n.Substring(8, 4) + '-' + $n.Substring(12, 4) + '-' + $n.Substring(16, 4) + '-' + $n.Substring(20, 12)
}

# Whether the name could belong to a covered format, so that a file of any other
# kind is never opened. An extensionless file might start with a #! line.
function Test-CoveredName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RelativePath)
    $name = [IO.Path]::GetFileName($RelativePath)
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    return (-not $extension) -or $StyleByExtension.ContainsKey($extension) -or $StyleByName.ContainsKey($name)
}

function Get-FileStyle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RelativePath, [string]$FirstLine)
    $name = [IO.Path]::GetFileName($RelativePath)
    if ($StyleByName.ContainsKey($name)) { return $StyleByName[$name] }
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    if ($extension) { return $StyleByExtension[$extension] }
    if ($FirstLine -and $FirstLine.StartsWith('#!')) { return 'hash' }
    return $null
}

function Get-HeaderFact {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Style, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)
    $fact = [pscustomobject]@{ Block = $false; Copyright = $false; Pointer = $false; Guid = $null }
    if ($Style -eq 'psinfo') {
        $inside = $false
        foreach ($text in $Line) {
            if (-not $inside) {
                if ($text -match '^\s*<#PSScriptInfo\b') { $inside = $true; $fact.Block = $true }
                continue
            }
            if ($text -match '#>') { break }
            if ($text -match "^\s*\.COPYRIGHT\s+$CopyrightPattern") { $fact.Copyright = $true }
            elseif ($text -match '^\s*\.LICENSEURI\s+https://yuruna\.link/license(?![\w./-])') { $fact.Pointer = $true }
            elseif ($text -match '^\s*\.GUID\s+(\S+)') { $fact.Guid = $Matches[1] }
        }
        return $fact
    }
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -notmatch "Copyright\s*$CopyrightPattern") { continue }
        $fact.Copyright = $true
        for ($j = $i - 1; $j -ge 0; $j--) {
            if ($Line[$j] -match '[A-Za-z0-9]') { $fact.Pointer = $Line[$j] -match $PointerPattern; break }
        }
        break
    }
    return $fact
}

function ConvertTo-Problem {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Rule, [Parameter(Mandatory)][string]$Message, [string[]]$Fix = @())
    return [pscustomobject]@{ Rule = $Rule; Message = $Message; Fix = $Fix; Existing = $false }
}

# The copyright / license-pointer gaps of a file judged on its own, ignoring
# every exemption.
function Get-HeaderGap {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Style, [Parameter(Mandatory)][pscustomobject]$Fact)
    $problems = [Collections.Generic.List[object]]::new()
    $year = (Get-Date).Year
    if ($Style -eq 'psinfo') {
        if (-not $Fact.Block) {
            $fix = @('Start the file with the PSScriptInfo block its neighbors use (copy one from a sibling file) holding',
                ".COPYRIGHT (c) 2019-$year by Alisson Sol et al., .LICENSEURI https://yuruna.link/license and a fresh .GUID,",
                "for example $(Get-FreshGuid).", $DeclareHint)
            $problems.Add((ConvertTo-Problem -Rule 'psscriptinfo' -Fix $fix `
                        -Message "no <#PSScriptInfo block in the first $HeaderWindow lines, so no copyright, license pointer or GUID"))
            return @($problems)
        }
        if (-not $Fact.Copyright) {
            $problems.Add((ConvertTo-Problem -Rule 'copyright' -Fix @(".COPYRIGHT (c) 2019-$year by Alisson Sol et al.", $DeclareHint) `
                        -Message 'the PSScriptInfo block has no .COPYRIGHT (c) <years> by Alisson Sol et al. line'))
        }
        if (-not $Fact.Pointer) {
            $problems.Add((ConvertTo-Problem -Rule 'license-pointer' -Fix @('.LICENSEURI https://yuruna.link/license') `
                        -Message 'the PSScriptInfo block has no .LICENSEURI https://yuruna.link/license line'))
        }
        return @($problems)
    }
    $pointer = $Wrapper[$Style] -f 'LICENSEURI https://yuruna.link/license'
    $copyright = $Wrapper[$Style] -f "Copyright (c) 2019-$year by Alisson Sol et al."
    if (-not $Fact.Copyright) {
        $fix = @('Add these two lines at the top (below a shebang, <?xml?> or #cloud-config line that must stay first):',
            $pointer, $copyright, $DeclareHint)
        $problems.Add((ConvertTo-Problem -Rule 'copyright' -Fix $fix `
                    -Message "no 'Copyright (c) <years> by Alisson Sol et al.' line in the first $HeaderWindow lines"))
    } elseif (-not $Fact.Pointer) {
        $problems.Add((ConvertTo-Problem -Rule 'license-pointer' -Fix @('Put this line directly above the copyright line:', $pointer) `
                    -Message 'the line above the copyright line is not LICENSEURI https://yuruna.link/license'))
    }
    return @($problems)
}

function Get-GuidProblem {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Style, [Parameter(Mandatory)][pscustomobject]$Fact)
    if ($Style -ne 'psinfo' -or -not $Fact.Block) { return @() }
    $fresh = Get-FreshGuid
    if (-not $Fact.Guid) {
        return @(ConvertTo-Problem -Rule 'guid' -Message 'the PSScriptInfo block has no .GUID line' -Fix @(".GUID $fresh"))
    }
    if ($Fact.Guid -notmatch $GuidPattern) {
        return @(ConvertTo-Problem -Rule 'guid' -Message "'$($Fact.Guid)' is not a GUID" -Fix @("Use a fresh one, for example $fresh."))
    }
    if (-not $Fact.Guid.StartsWith('42')) {
        return @(ConvertTo-Problem -Rule 'guid' -Message "'$($Fact.Guid)' does not start with 42" -Fix @("Use a fresh one, for example $fresh."))
    }
    return @()
}

# Everything wrong with one file. A vendored file keeps its upstream header. A
# generated file may skip the header but must say what generated it; a file under
# a generated path that has neither is hand-written work hiding under the path.
function Get-FileProblem {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Style, [Parameter(Mandatory)][pscustomobject]$Fact,
          [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line, $Exempt)
    if ($Exempt -and $Exempt.Kind -eq 'vendored') { return @() }
    $problems = [Collections.Generic.List[object]]::new()
    $gap = @(Get-HeaderGap -Style $Style -Fact $Fact)
    if (-not $Exempt) {
        foreach ($item in $gap) { $problems.Add($item) }
    } elseif ($gap.Count -gt 0 -and -not @($Line | Select-Object -First $BannerWindow | Where-Object { $_.Contains($Exempt.Generator) })) {
        $problems.Add((ConvertTo-Problem -Rule 'generated-banner' `
                    -Message "is under the generated paths of $($Exempt.Generator) but neither names it in its first $BannerWindow lines nor carries the standard header" `
                    -Fix @("Have the generator write 'Generated by $($Exempt.Generator)' at the top. A hand-written file gets the standard header",
                        "instead, and the paths in $ExemptionsName must not cover it.")))
    }
    foreach ($item in (Get-GuidProblem -Style $Style -Fact $Fact)) { $problems.Add($item) }
    return @($problems)
}

# A file may share its GUID only as a member of a declared group of synchronized
# copies. The group is the authorization, so an outsider that takes the same
# GUID is the file flagged, not the copies.
function Test-GuidShareAllowed {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$RelativePath)
    foreach ($group in $Exemption.Group) {
        if ($group.Repo -eq $Repo -and $RelativePath -cin $group.File) { return $true }
    }
    return $false
}

function ConvertTo-ClashProblem {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Guid, [Parameter(Mandatory)][string[]]$Other)
    $shown = ($Other | Select-Object -First 3) -join ', '
    if ($Other.Count -gt 3) { $shown += " and $($Other.Count - 3) more" }
    return ConvertTo-Problem -Rule 'guid' -Message "GUID $Guid is also declared by $shown" `
        -Fix @("A GUID names one file across renames: use a fresh one, for example $(Get-FreshGuid).",
            "Byte-identical copies kept in step by a tool are declared under synchronizedCopies in $ExemptionsName.")
}

# --- REGION: reporting
# The same fix is printed once; later findings that need it get one line, so a
# commit that adds fifty files in one format stays readable.
function Write-Problem {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][pscustomobject]$Finding, [string]$Label = 'FAIL')
    $fixText = $Finding.Fix -join "`n"
    if ($Finding.Fix.Count -gt 0 -and -not $script:ShownFix.Add($fixText)) {
        Write-Output ('{0}  {1}  [{2}]  {3}' -f $Label, $Finding.Path, $Finding.Rule, $Finding.Message)
        return
    }
    Write-Output ('{0}  {1}  [{2}]' -f $Label, $Finding.Path, $Finding.Rule)
    Write-Output "      $($Finding.Message)"
    if ($Finding.Fix.Count -gt 0) {
        Write-Output "      fix: $($Finding.Fix[0])"
        foreach ($more in ($Finding.Fix | Select-Object -Skip 1)) { Write-Output "           $more" }
    }
}

function Get-FindingGroup {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Finding)
    $part = @($Finding.Path -split '/')
    $depth = [Math]::Min($part.Count - 1, 3)
    return $Finding.Repo + '/' + (($part | Select-Object -First $depth) -join '/')
}

# --- REGION: main
try {
    if ($Staged -eq $All) {
        Write-Error 'Test-SourceMetadata: pass exactly one of -Staged or -All.' -ErrorAction Continue
        exit $ExitCannotRun
    }
    # `pwsh -File` hands "-Root a,b" over as ONE string, so a list is split here.
    $Root = @($Root | Where-Object { $_ } | ForEach-Object { if (Test-Path -LiteralPath $_) { $_ } else { $_ -split ',' } })
    if (-not $Root) { $Root = @($FrameworkRoot) }
    if (($Staged -or $RepoName) -and $Root.Count -ne 1) {
        Write-Error 'Test-SourceMetadata: -Staged and -RepoName take exactly one -Root.' -ErrorAction Continue
        exit $ExitCannotRun
    }
    if (-not $ExemptionsPath) { $ExemptionsPath = Join-Path $ToolRoot 'source-metadata.exemptions.json' }
    $Exemption = Read-Exemption -Path $ExemptionsPath
    if ($Exemption.Errors.Count -gt 0) {
        Write-Output "Test-SourceMetadata: $ExemptionsPath is not usable:"
        foreach ($message in $Exemption.Errors) { Write-Output "  - $message" }
        exit $ExitCannotRun
    }

    # The exemptions file names a repository by the folder of its main checkout,
    # so a linked worktree in a folder of another name is still that repository.
    $repos = foreach ($path in $Root) {
        $full = (Resolve-Path -LiteralPath $path).Path
        $common = Invoke-Git -Repository $full -Argument @('rev-parse', '--git-common-dir')
        if ($common.Code -ne 0) {
            Write-Error "Test-SourceMetadata: $full is not a git repository." -ErrorAction Continue
            exit $ExitCannotRun
        }
        $commonDir = [IO.Path]::GetFullPath([IO.Path]::Combine($full, $common.Text.Trim()))
        $name = Split-Path -Leaf $full
        if ((Split-Path -Leaf $commonDir) -eq '.git') { $name = Split-Path -Leaf (Split-Path -Parent $commonDir) }
        if ($RepoName) { $name = $RepoName }
        [pscustomobject]@{ Root = $full; Name = $name }
    }

    $script:ShownFix = [Collections.Generic.HashSet[string]]::new()

    # The files to judge: where each is, and the first lines it holds. -All
    # reads the working tree; -Staged reads the index, which is what the commit
    # carries even when the working copy has moved on.
    $candidate = [Collections.Generic.List[object]]::new()
    if ($All) {
        foreach ($repo in $repos) {
            $listing = Invoke-Git -Repository $repo.Root -Argument @('ls-files', '-z')
            if ($listing.Code -ne 0) { throw "git ls-files failed in $($repo.Root)" }
            foreach ($relative in ($listing.Text -split "`0" | Where-Object { $_ })) {
                if (-not (Test-CoveredName -RelativePath $relative)) { continue }
                $full = Join-Path $repo.Root $relative
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                $line = Read-FileHead -Path $full
                $style = Get-FileStyle -RelativePath $relative -FirstLine $line[0]
                if ($style) { $candidate.Add([pscustomobject]@{ Repo = $repo.Name; Path = $relative; Style = $style; Line = $line; Added = $false; Before = $relative }) }
            }
        }
    } else {
        $repo = $repos[0]
        $diff = Invoke-Git -Repository $repo.Root -Argument @('diff', '--cached', '--name-status', '-z', '--diff-filter=AMR')
        if ($diff.Code -ne 0) { throw "git diff --cached failed in $($repo.Root)" }
        $token = @($diff.Text -split "`0" | Where-Object { $_ })
        $change = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $token.Count;) {
            if ($token[$i] -match '^[RC]') {
                $change.Add([pscustomobject]@{ Added = $false; Path = $token[$i + 2]; Before = $token[$i + 1] })
                $i += 3
            } else {
                $change.Add([pscustomobject]@{ Added = $token[$i] -eq 'A'; Path = $token[$i + 1]; Before = $token[$i + 1] })
                $i += 2
            }
        }
        $change = @($change | Where-Object { Test-CoveredName -RelativePath $_.Path })
        $heads = Read-GitObjectHead -Repository $repo.Root -Spec @($change | ForEach-Object { ':' + $_.Path })
        foreach ($item in $change) {
            $line = $heads[':' + $item.Path]
            if ($null -eq $line) { continue }
            $style = Get-FileStyle -RelativePath $item.Path -FirstLine $line[0]
            if ($style) { $candidate.Add([pscustomobject]@{ Repo = $repo.Name; Path = $item.Path; Style = $style; Line = $line; Added = $item.Added; Before = $item.Before }) }
        }
    }

    # Header rules, with the exemption each path resolves to. For an exempt
    # file the rules it would face unexempted are counted too, so an entry
    # that only covers files which already comply can be called out.
    $exempted = @{}
    $checked = foreach ($file in $candidate) {
        $fact = Get-HeaderFact -Style $file.Style -Line $file.Line
        $exempt = Resolve-Exemption -Repo $file.Repo -RelativePath $file.Path
        if ($exempt) {
            if (-not $exempted.ContainsKey($exempt.Label)) { $exempted[$exempt.Label] = [pscustomobject]@{ Matched = 0; Compliant = 0 } }
            $exempted[$exempt.Label].Matched++
            if (@(Get-HeaderGap -Style $file.Style -Fact $fact).Count -eq 0) { $exempted[$exempt.Label].Compliant++ }
        }
        $problem = [Collections.Generic.List[object]]::new()
        foreach ($item in (Get-FileProblem -Style $file.Style -Fact $fact -Line $file.Line -Exempt $exempt)) { $problem.Add($item) }
        [pscustomobject]@{
            Repo = $file.Repo; Path = $file.Path; Style = $file.Style; Added = $file.Added; Before = $file.Before
            Fact = $fact; Exempt = $exempt; Problem = $problem
        }
    }
    $checked = @($checked)

    # GUID uniqueness. -All compares every file it read. -Staged looks only at
    # files that are new or whose .GUID line changed -- git names them in one
    # call -- and asks git for other index entries holding those GUIDs in one
    # grep, so a commit never pays for walking the tree.
    $guidFile = @($checked | Where-Object { $_.Style -eq 'psinfo' -and $_.Fact.Guid -match $GuidPattern -and -not ($_.Exempt -and $_.Exempt.Kind -eq 'vendored') })
    if ($Staged -and $guidFile.Count -gt 0) {
        $named = Invoke-Git -Repository $repos[0].Root -Argument @('diff', '--cached', '--name-only', '-z', '--diff-filter=AMR',
            '-G', '^[[:space:]]*\.GUID[[:space:]]', '--', '*.ps1', '*.psm1', '*.psd1')
        $guidChanged = @($named.Text -split "`0" | Where-Object { $_ })
        $guidFile = @($guidFile | Where-Object { $_.Path -cin $guidChanged })
    }
    if ($All) {
        foreach ($set in ($guidFile | Group-Object { $_.Fact.Guid.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })) {
            $member = @($set.Group)
            foreach ($one in ($member | Where-Object { -not (Test-GuidShareAllowed -Repo $_.Repo -RelativePath $_.Path) })) {
                $other = @($member | Where-Object { $_ -ne $one } | ForEach-Object { "$($_.Repo)/$($_.Path)" })
                $one.Problem.Add((ConvertTo-ClashProblem -Guid $one.Fact.Guid -Other $other))
            }
        }
    } else {
        $searched = @($guidFile | ForEach-Object { $_.Fact.Guid.ToLowerInvariant() } | Sort-Object -Unique)
        $holder = @{}
        for ($start = 0; $start -lt $searched.Count; $start += 100) {
            $argument = @('grep', '--cached', '-n', '-i', '-F')
            foreach ($guid in ($searched | Select-Object -Skip $start -First 100)) { $argument += @('-e', $guid) }
            $hit = Invoke-Git -Repository $repos[0].Root -Argument ($argument + @('--', '*.ps1', '*.psm1', '*.psd1'))
            foreach ($row in ($hit.Text -split "`n" | Where-Object { $_ })) {
                if ($row -notmatch '^(?<path>.+?):(?<n>\d+):\s*\.GUID\s+(?<guid>[0-9a-fA-F-]{36})\s*$' -or [int]$Matches['n'] -gt $HeaderWindow) { continue }
                $key = $Matches['guid'].ToLowerInvariant()
                if (-not $holder.ContainsKey($key)) { $holder[$key] = [Collections.Generic.List[string]]::new() }
                $holder[$key].Add($Matches['path'])
            }
        }
        foreach ($one in ($guidFile | Where-Object { -not (Test-GuidShareAllowed -Repo $_.Repo -RelativePath $_.Path) })) {
            $other = @($holder[$one.Fact.Guid.ToLowerInvariant()] | Where-Object { $_ -cne $one.Path })
            if ($other.Count -gt 0) { $one.Problem.Add((ConvertTo-ClashProblem -Guid $one.Fact.Guid -Other $other)) }
        }
    }

    # A gap the previous version of the file already had is not this commit's
    # doing. A moved or edited file is compared with the version it replaces;
    # a GUID problem is never excused, because the tree holds none to excuse.
    if ($Staged) {
        $touched = @($checked | Where-Object { $_.Problem.Count -gt 0 -and -not $_.Added })
        $previous = Read-GitObjectHead -Repository $repos[0].Root -Spec @($touched | ForEach-Object { 'HEAD:' + $_.Before })
        foreach ($file in $touched) {
            $old = $previous['HEAD:' + $file.Before]
            if ($null -eq $old) { continue }
            $oldFact = Get-HeaderFact -Style $file.Style -Line $old
            $oldRule = @(Get-FileProblem -Style $file.Style -Fact $oldFact -Line $old -Exempt $file.Exempt | ForEach-Object { $_.Rule })
            foreach ($problem in $file.Problem) { $problem.Existing = $problem.Rule -ne 'guid' -and $problem.Rule -in $oldRule }
        }
    }

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($file in $checked) {
        foreach ($problem in $file.Problem) {
            $findings.Add([pscustomobject]@{
                    Repo = $file.Repo; Path = $file.Path; Rule = $problem.Rule; Message = $problem.Message
                    Fix = @($problem.Fix); Existing = $problem.Existing })
        }
    }

    # Whole-tree upkeep of the exemptions file.
    if ($All) {
        $named = @($repos | ForEach-Object { $_.Name })
        foreach ($entry in $Exemption.Entry) {
            if ($entry.Repo -cnotin $named) { continue }
            $count = $exempted[$entry.Label]
            $what = if ($entry.Kind -eq 'generated') { "$($entry.Kind) entry for $($entry.Generator)" } else { "$($entry.Kind) entry" }
            $text = $null
            if (-not $count) { $text = "$what matches no tracked file in $($entry.Repo); remove it or correct its paths" }
            elseif ($count.Compliant -eq $count.Matched) { $text = "$what covers only files that already carry the standard header; remove it so they are checked" }
            if ($text) {
                $findings.Add([pscustomobject]@{ Repo = $entry.Repo; Path = $ExemptionsName; Rule = 'exemption'; Message = $text; Fix = @(); Existing = $true })
            }
        }
        foreach ($group in $Exemption.Group) {
            if ($group.Repo -cnotin $named) { continue }
            $member = @($checked | Where-Object { $_.Repo -eq $group.Repo -and $_.Path -cin $group.File })
            $guids = @($member | ForEach-Object { "$($_.Fact.Guid)".ToLowerInvariant() } | Sort-Object -Unique)
            $text = $null
            if ($member.Count -ne $group.File.Count) { $text = "the synchronized copies kept by $($group.Tool) are not all tracked files in $($group.Repo)" }
            elseif ($guids.Count -ne 1) { $text = "the copies kept by $($group.Tool) declare $($guids.Count) different GUIDs; run the tool so they match again" }
            if ($text) {
                $findings.Add([pscustomobject]@{ Repo = $group.Repo; Path = $ExemptionsName; Rule = 'exemption'; Message = $text; Fix = @(); Existing = $true })
            }
        }
    }

    # Verdict and report.
    $blocking = @($findings | Where-Object { $FailOnDebt -or ($Staged -and -not $_.Existing) })
    if ($Staged) {
        foreach ($finding in $blocking) { Write-Problem -Finding $finding }
        $debt = @($findings | Where-Object { $_ -notin $blocking })
        foreach ($finding in ($debt | Select-Object -First 8)) {
            Write-Output ('NOTE  {0}  [{1}]  {2} (already so before this commit; not blocking)' -f $finding.Path, $finding.Rule, $finding.Message)
        }
        if ($debt.Count -gt 8) { Write-Output "NOTE  ... and $($debt.Count - 8) more existing gap(s) in the staged files." }
        if ($blocking.Count -gt 0) {
            $fileCount = @($blocking | Select-Object -ExpandProperty Path -Unique).Count
            Write-Output "Test-SourceMetadata [staged]: $($blocking.Count) problem(s) in $fileCount of $($checked.Count) checked file(s)."
            exit $ExitFailure
        }
        if (-not $Quiet) { Write-Output "Test-SourceMetadata [staged]: $($checked.Count) file(s) checked, no new gap." }
        exit $ExitOk
    }

    $clean = @($checked | Where-Object { $_.Problem.Count -eq 0 -and -not $_.Exempt })
    $generated = @($checked | Where-Object { $_.Exempt -and $_.Exempt.Kind -eq 'generated' -and $_.Problem.Count -eq 0 })
    $vendored = @($checked | Where-Object { $_.Exempt -and $_.Exempt.Kind -eq 'vendored' -and $_.Problem.Count -eq 0 })
    $synchronized = @($clean | Where-Object { $one = $_; @($Exemption.Group | Where-Object { $_.Repo -eq $one.Repo -and $one.Path -cin $_.File }).Count -gt 0 })
    $withFinding = @($findings | Where-Object { $_.Rule -ne 'exemption' } | ForEach-Object { $_.Repo + '/' + $_.Path } | Sort-Object -Unique).Count
    Write-Output ('Test-SourceMetadata [all]: {0} repo(s), {1} checked file(s): {2} compliant ({3} of them synchronized copies), {4} generated and exempt, {5} vendored and exempt, {6} with findings.' -f
        $repos.Count, $checked.Count, $clean.Count, $synchronized.Count, $generated.Count, $vendored.Count, $withFinding)
    if (-not $Quiet) {
        if ($generated.Count -gt 0) {
            Write-Output ('  generated, exempt: ' + (($generated | Group-Object { $_.Exempt.Generator } | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '))
        }
        if ($findings.Count -gt 0) {
            Write-Output ('  findings by rule: ' + (($findings | Group-Object Rule | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '))
            if ($Detail) {
                foreach ($finding in $findings) { Write-Problem -Finding $finding -Label 'GAP ' }
            } else {
                Write-Output '  where (rerun with -Detail for every finding):'
                foreach ($group in ($findings | Group-Object { Get-FindingGroup -Finding $_ } | Sort-Object Count -Descending)) {
                    Write-Output ('    {0,4}  {1}' -f $group.Count, $group.Name)
                }
            }
        }
    }
    if ($FailOnDebt -and $findings.Count -gt 0) { exit $ExitFailure }
    exit $ExitOk
} catch {
    Write-Error "Test-SourceMetadata: $($_.Exception.Message)" -ErrorAction Continue
    exit $ExitCannotRun
}
