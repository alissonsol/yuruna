<#PSScriptInfo
.VERSION 2026.07.16
.GUID 42d71104-fd71-45a5-bf16-48383ba0385d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test git filemode execbit shellscript pester
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
    Guards that every tracked shell script is recorded executable (mode
    100755) in the git index, so Linux checkouts run them without chmod.
.DESCRIPTION
    Windows working trees do not carry the Unix exec bit (core.fileMode is
    false), so a shell script created or copied on Windows silently lands in
    the index as 100644; every Linux clone and git-archive tarball then needs
    a manual chmod, and the miss only surfaces later as a guest-side
    "Permission denied". On Windows the bit exists ONLY in the index, so the
    tests read `git ls-files -s`, never the working tree.

    Remediation for an offender:  git update-index --chmod=+x -- <path>

    Sweeps:
      * every tracked *.sh index entry must be mode 100755;
      * every other tracked regular file whose content opens with a '#!'
        shebang must be mode 100755 (catches extensionless scripts);
      * the same *.sh rule for the disposable project/ clone of the sibling
        yuruna-project repository, which has no test suite of its own. The
        clone tracks that repository's origin, so an offender there is fixed
        (and pushed) in yuruna-project, not in the clone.

    The throw-based Assert-* helpers live at script scope and are referenced
    from It blocks, so this runs under Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$testDir  = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $testDir

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Test-GitWorkTree {
    param([string]$Root)
    if (-not (Get-Command -Name git -ErrorAction SilentlyContinue)) { return $false }
    return ((git -C $Root rev-parse --is-inside-work-tree 2>$null) -eq 'true')
}

# Index entries as Mode/Path objects. ls-files -s prints
# "<mode> <blob> <stage><TAB><path>"; splitting on the TAB keeps paths with
# spaces intact, and core.quotepath=false keeps non-ASCII paths literal
# instead of C-escaped (a quoted path would never match Test-Path).
function Get-GitIndexEntry {
    param([string]$Root, [string]$PathSpec = '.')
    $entries = @()
    foreach ($line in @(git -C $Root -c core.quotepath=false ls-files -s -- $PathSpec)) {
        $meta, $path = $line -split "`t", 2
        if (-not $path) { continue }
        $entries += [pscustomobject]@{ Mode = ($meta -split ' ')[0]; Path = $path }
    }
    $entries
}

function Get-NonExecutableShellScript {
    param([string]$Root)
    @(Get-GitIndexEntry -Root $Root -PathSpec '*.sh' |
        Where-Object { $_.Mode -eq '100644' } |
        ForEach-Object { $_.Path })
}

# Byte-level check that a file opens with '#!'. Bytes, not Get-Content: the
# file may be any encoding, and a shebang only works as the first two BYTES
# anyway (a BOM or UTF-16 prefix already breaks it for the kernel).
function Test-LeadingShebang {
    param([string]$FullPath)
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return $false }
    $stream = [System.IO.File]::OpenRead($FullPath)
    try {
        $buffer = [byte[]]::new(2)
        return (($stream.Read($buffer, 0, 2) -eq 2) -and ($buffer[0] -eq 0x23) -and ($buffer[1] -eq 0x21))
    }
    finally { $stream.Dispose() }
}

# Skip (rather than fail) outside a git work tree: guests run these suites
# from a git-archive tarball that has no .git, and there the index -- the only
# thing being asserted -- does not exist to check.
$script:skipRepo = -not (Test-GitWorkTree -Root $repoRoot)

# project/ is a disposable per-cycle clone of the sibling yuruna-project repo
# (feedback_project_dir_is_disposable_clone.md); it is git-ignored here, so
# the main sweep never sees it and it gets its own guarded pass.
$projectClone = Join-Path $repoRoot 'project'
$script:skipProjectClone = (-not (Test-Path -LiteralPath (Join-Path $projectClone '.git'))) -or
    (-not (Test-GitWorkTree -Root $projectClone))

Describe 'Tracked *.sh files are recorded executable in the git index' {
    It 'has no *.sh index entry at mode 100644' -Skip:$script:skipRepo {
        $offenders = @(Get-NonExecutableShellScript -Root $repoRoot)
        Assert-True ($offenders.Count -eq 0) "fix with: git update-index --chmod=+x -- $($offenders -join ' ')"
    }

    It 'has no *.sh index entry at mode 100644 in the project/ clone (yuruna-project)' -Skip:$script:skipProjectClone {
        $offenders = @(Get-NonExecutableShellScript -Root $projectClone)
        Assert-True ($offenders.Count -eq 0) "fix in the yuruna-project repository and push (the clone is disposable): git update-index --chmod=+x -- $($offenders -join ' ')"
    }
}

Describe 'Tracked shebang scripts outside *.sh are recorded executable' {
    It 'has no non-.sh tracked file that opens with #! at mode 100644' -Skip:$script:skipRepo {
        $offenders = @()
        foreach ($entry in @(Get-GitIndexEntry -Root $repoRoot)) {
            if ($entry.Mode -ne '100644') { continue }
            if ($entry.Path -like '*.sh') { continue }
            if (Test-LeadingShebang -FullPath (Join-Path $repoRoot $entry.Path)) { $offenders += $entry.Path }
        }
        Assert-True ($offenders.Count -eq 0) "fix with: git update-index --chmod=+x -- $($offenders -join ' ')"
    }
}
