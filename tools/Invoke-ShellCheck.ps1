<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42d95a38-0ff3-43d7-99b3-685dafc66496
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lint shell shellcheck
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
    Run shellcheck over the repo's shell source -- git-tracked and new
    (not-yet-committed, non-ignored) files ONLY.
.DESCRIPTION
    Shell is the one language here whose mistakes do not surface at build time.
    The guest and installer scripts are handed to a VM and run there, so an
    unbalanced quote or a malformed test expression shows up as a cycle that
    failed minutes later with an opaque exit code, never as an error on the
    host that produced the file.

    Files are selected with `git ls-files --cached --others --exclude-standard`
    (tracked + new, minus everything .gitignore covers) -- the same selector
    Invoke-Lint.ps1 uses, so the two gates see one set of files and neither
    walks the per-cycle clone or the other generated trees. Beyond *.sh it
    takes extensionless files whose first line is a shell shebang, which is how
    the git hooks are covered; the repo holds four extensionless files in
    total, so reading one line from each costs nothing.

    APERTURE -- WHAT THE DEFAULT DOES AND DOES NOT CATCH.

    The default severity is 'error' and the tree is clean there. That level is
    the class this gate exists for: text no shell can parse (SC1072/SC1073 and
    their relatives) and a script with no shebang -- failures that otherwise
    reach a guest before anything notices them.

    It catches nothing shellcheck rates warning or below. Above the default the
    tree is NOT clean, and most of what appears is not a defect:

      * SC1091 (27) -- `source` targets that exist only at runtime, such as
        /usr/local/lib/yuruna/yuruna-retry.sh, which is installed on the guest
        and absent from any checkout.
      * SC2086 (12) -- word splitting that is deliberate. `yuruna_warm_refs
        "flannel" $_cni_refs` passes a list of refs; quoting it would pass one
        argument and break the call.
      * SC2034 (4), SC2016 (4), SC2024 (3), SC2155 (1), SC2329 (1).

    Totals over that same file set: 0 at 'error', 8 at 'warning', 52 at 'style'
    (shellcheck's floor, so that number is all of them).

    TO TIGHTEN. Lowering the default to 'warning' means settling 8 findings,
    each a judgment call about a script that runs on a live guest: `sudo cmd >>
    file`, where the redirection is the caller's and not root's (SC2024);
    variables set for an operator to read or override rather than for the script
    to consume (SC2034); a `local x=$(...)` that discards the command's status
    (SC2155). Lowering it to 'info' additionally wants a `# shellcheck source=`
    directive on every runtime source and a marker at each deliberate-splitting
    call site. Directives already present in the sources are honored, so the
    work is incremental -- silence a class where it is wrong about this repo,
    then lower the default one step.
.PARAMETER Path
    Optional repo-relative subpath to limit the scan (e.g. 'guest').
    Default: the whole repo.
.PARAMETER Severity
    shellcheck's minimum severity -- error, warning, info or style, each
    including everything more severe. Default: error. See APERTURE above.
.PARAMETER Quiet
    Print only the summary line, not each finding.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-ShellCheck.ps1
    Scans all tracked/new shell files; exits non-zero if any finding.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-ShellCheck.ps1 -Severity info
    The whole picture, including the classes the default leaves out.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [ValidateSet('error', 'warning', 'info', 'style')]
    [string]$Severity = 'error',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# shellcheck exits non-zero whenever it has anything to report, which is a
# normal outcome here and not an error. Where that mapping is enabled, the
# 'Stop' preference above would turn every reported finding into a terminating
# error and lose the findings themselves.
$PSNativeCommandUseErrorActionPreference = $false

# Probed before anything touches git, so "not installed" is answerable without
# a repository and cannot be confused with a discovery failure.
if (-not (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
    # -ErrorAction Continue keeps this non-terminating under the 'Stop'
    # preference: a terminating error would exit 1, which is the code that
    # means "the scan found something".
    Write-Error "shellcheck is not installed. See https://github.com/koalaman/shellcheck#installing" -ErrorAction Continue
    exit 2
}

$RepoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $RepoRoot
try {
    # The extension filter runs HERE, not as a git pathspec. A `*.sh` pathspec
    # is expanded against the current directory before git sees it whenever a
    # file there matches, which silently narrows the set to one directory.
    # Forward slashes: git prints '/'-separated paths on every platform, so
    # Join-Path (a backslash on Windows) would not match the prefix.
    $prefix = if ($Path) { ($Path -replace '\\', '/').TrimEnd('/') + '/' } else { '' }
    $candidates = @(git ls-files --cached --others --exclude-standard |
        Where-Object { $_ } |
        Where-Object { -not $prefix -or $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Sort-Object -Unique)

    # An extensionless file is shell only if line 1 says so. The word boundary
    # is what keeps a `#!/usr/bin/pwsh` hook from being fed to shellcheck.
    $files = @($candidates | Where-Object {
            if ($_ -match '\.sh$') { return $true }
            if ((Split-Path -Leaf $_) -match '\.') { return $false }
            $first = Get-Content -LiteralPath $_ -TotalCount 1 -ErrorAction SilentlyContinue
            return ($first -match '^#!.*\b(bash|dash|ksh|zsh|sh)\b')
        })

    if ($files.Count -eq 0) {
        Write-Output "No shell files to scan$(if ($Path) { " under '$Path'" })."
        exit 0
    }

    $raw = & shellcheck --format=json1 --severity=$Severity -- @files
    $shellcheckExit = $LASTEXITCODE

    $report = $null
    try { $report = ($raw -join "`n") | ConvertFrom-Json } catch { $report = $null }
    if ($null -eq $report) {
        # An answer that cannot be read must never be reported as a clean one.
        Write-Output ($raw | Out-String).TrimEnd()
        Write-Output ("shellcheck: could not analyze {0} shell file(s), exit {1}." -f $files.Count, $shellcheckExit)
        exit 1
    }

    $findings = @($report.comments)
    if (-not $Quiet) {
        foreach ($c in $findings) {
            Write-Output ("{0}:{1}:{2}  SC{3}  {4}" -f $c.file, $c.line, $c.column, $c.code, $c.message)
        }
    }
    Write-Output ("shellcheck: {0} finding(s) across {1} tracked/new shell file(s) at severity '{2}' and above." -f `
            $findings.Count, $files.Count, $Severity)
    exit (($findings.Count -gt 0) ? 1 : 0)
} finally {
    Pop-Location
}
