<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42e621ac-ad54-49e2-8681-64687c21a8c8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna javascript node test assets status
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
    Run every candidate JavaScript self-test with node.
.DESCRIPTION
    The browser assets under test/status and the stash-service web directory
    carry their own checks in *.test.js, and this script is the only thing in
    the repo that runs them.

    Those files are framework-free CommonJS scripts, not a suite: each one
    `require`s node's built-in assert/vm, reads the asset beside it through
    __dirname, prints a PASS line and leaves a non-zero exit behind on failure.
    There is no package.json, no runner and nothing to install, so "hand the
    file to node" is the entire execution contract and this script is only the
    discovery and reporting around it. __dirname is also why the working
    directory is irrelevant here: each file is invoked by absolute path.

    Discovery uses Git's tracked and untracked, non-ignored candidate set rather
    than a filesystem walk. An ignored scratch copy or nested checkout cannot
    slip in, while a new *.test.js is covered before its first commit.

    A run that could not happen is reported as SKIPPED, never as success: on a
    host without node every discovered file is named and the exit code is the
    missing-toolchain one, so a green summary always means the assertions
    actually executed.

.PARAMETER Path
    Repo-relative root to search for *.test.js. Default: test.
.PARAMETER Root
    Repository candidate root. Defaults to this tool's repository. The
    override exists for isolated discovery mutation tests.
.PARAMETER Quiet
    Print only the summary line.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-JsTest.ps1
    Exits 0 when every file passes, 1 when any fails, 2 when node is absent.
#>

[CmdletBinding()]
param(
    [string]$Path = 'test',
    [string]$Root,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = if ($Root) { [IO.Path]::GetFullPath($Root) } else { Split-Path -Parent $PSScriptRoot }
$pathspec = ($Path -replace '\\', '/').TrimEnd('/') + '/*.test.js'

$tests = @(& git -C $RepoRoot ls-files --cached --others --exclude-standard -- $pathspec |
    Sort-Object -Unique)
if ($LASTEXITCODE -ne 0 -or $tests.Count -eq 0) {
    # -ErrorAction Continue, because $ErrorActionPreference = 'Stop' turns a
    # Write-Error into a terminating error that ends the script with exit 1 --
    # the code that means "a test failed" -- before `exit 2` is ever reached.
    Write-Error "no candidate *.test.js under $Path" -ErrorAction Continue
    exit 2
}

# Discovery deliberately precedes the toolchain check, so a skipped run still
# names every file it left unchecked instead of reporting an empty nothing.
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    if (-not $Quiet) {
        foreach ($t in $tests) { Write-Information "SKIPPED $t" -InformationAction Continue }
    }
    Write-Information ("{0} JavaScript test file(s), 0 run -- SKIPPED: node is not installed or not on PATH" -f $tests.Count) -InformationAction Continue
    exit 2
}

$failures = [Collections.Generic.List[string]]::new()

foreach ($t in $tests) {
    $output = & node (Join-Path $RepoRoot $t) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures.Add($t)
        if (-not $Quiet) {
            Write-Information "--- FAIL $t ---" -InformationAction Continue
            ($output | Out-String).TrimEnd() | Write-Information -InformationAction Continue
        }
    } elseif (-not $Quiet) {
        Write-Information "ok $t" -InformationAction Continue
    }
}

Write-Information ("{0} JavaScript test file(s), {1} failed" -f $tests.Count, $failures.Count) -InformationAction Continue

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Error "${f}: node exited non-zero" -ErrorAction Continue }
    exit 1
}
exit 0
