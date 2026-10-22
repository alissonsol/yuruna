<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4243f981-9a67-4b29-81f5-966316b4be67
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester runner
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Run exactly ONE Pester suite in this process and write its NUnit result
    file. Spawned per suite by tools/Invoke-TestSuite.ps1.
.DESCRIPTION
    The suite is invoked with the call operator (`& $Suite`), NOT with
    `Invoke-Pester -Path`. The two are not interchangeable in this repo: a
    suite that assigns its fixtures at file scope is discovered and run in one
    pass by the standalone path, while `Invoke-Pester -Path` splits discovery
    from run and the fixtures are empty by the time an It body executes. Three
    suites depend on that difference and fail 73 tests under the other form.

    Setting $PesterPreference here rather than inside each suite is what lets
    the standalone path still emit a machine-readable result: the preference is
    read from this scope when the suite's first Describe triggers the run.

    This script's exit code reports whether the suite returned with readable
    NUnit results, never whether its tests passed. Pester's standalone path
    does not propagate a failing run through the call operator: a suite whose
    tests fail still returns 0 here. The result file is the authority on
    pass/fail. The caller must also validate it because a suite can terminate
    the process before this script checks the result.

.PARAMETER Suite
    Absolute path to the *.Tests.ps1 file to run.
.PARAMETER Xml
    Absolute path of the NUnit result file to write.
.EXAMPLE
    pwsh -NoProfile -File tools/_InvokeOneSuite.ps1 -Suite /repo/test/modules/Test.Backoff.Tests.ps1 -Xml /tmp/r.xml
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Suite,
    [Parameter(Mandatory)][string]$Xml
)

$ErrorActionPreference = 'Stop'

# Under tools/Invoke-TestSuite.ps1 the runner already gave this process a temp
# folder of its own and removes it after this process ends, killed or not. Run
# directly, this script does the same for itself: every process the suite
# starts inherits the folder, so whatever a test or a killed child leaves
# behind goes with it. See the matching block in Invoke-TestSuite.ps1 for why
# /tmp and why DOTNET_EnableDiagnostics.
$ownedTempRoot = $null
$savedTempEnvironment = @{}
if ([string]::IsNullOrWhiteSpace($env:YURUNA_TEST_TEMP_ROOT)) {
    $tempBase = if ($IsWindows) { [IO.Path]::GetTempPath() } else { '/tmp' }
    $ownedTempRoot = Join-Path $tempBase ('yrn-suite-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Force -Path $ownedTempRoot
    foreach ($name in 'TMPDIR', 'TMP', 'TEMP', 'YURUNA_TEST_TEMP_ROOT', 'DOTNET_EnableDiagnostics') {
        $savedTempEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        $value = if ($name -eq 'DOTNET_EnableDiagnostics') { '0' } else { $ownedTempRoot }
        [Environment]::SetEnvironmentVariable($name, $value)
    }
}

try {
    $pesterModule = Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge [version]'6.0.0' -and $_.Version -lt [version]'7.0.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pesterModule) { throw 'Pester 6.x is required; install Pester 6.2.0.' }
    Import-Module $pesterModule.Path -Force -ErrorAction Stop
    $PesterPreference = New-PesterConfiguration
    $PesterPreference.Output.Verbosity      = 'None'
    $PesterPreference.TestResult.Enabled    = $true
    $PesterPreference.TestResult.OutputPath = $Xml
    # Pinned rather than defaulted: the coordinator parses the NUnit 2.5 schema.
    $PesterPreference.TestResult.OutputFormat = 'NUnitXml'
    # Left at its default ($false) deliberately: Run.Exit does not reach this
    # process through the call operator, so enabling it would only suggest an
    # exit-code contract that does not hold.

    # A suite that commits through a hook must never reach the network, the
    # Claude Code CLI a logged-in machine would draft through, or a
    # translation command set in the operator's environment.
    $env:YURUNA_TRANSLATE = '0'
    $env:YURUNA_TRANSLATE_CLI = '0'
    $env:YURUNA_TRANSLATE_COMMAND = '0'
    & $Suite
    # Pester can catch an internal reporting failure, print it to stdout, and
    # return normally. Process survival alone must not claim a complete run.
    if (-not (Test-Path -LiteralPath $Xml -PathType Leaf)) {
        throw "Suite returned without writing its NUnit result file: $Xml"
    }
    $result = [xml](Get-Content -LiteralPath $Xml -Raw)
    # NUnit's name attribute shadows Name in PowerShell's XML adapter.
    if ($result.DocumentElement.LocalName -cne 'test-results') {
        throw "Suite produced an invalid NUnit result file: $Xml"
    }
    exit 0
} catch {
    # Invocation and reporting failures are distinct from failed assertions,
    # which still produce readable NUnit evidence for the caller to judge.
    Write-Error ("suite process failed: {0}" -f $_.Exception.Message) -ErrorAction Continue
    exit 2
} finally {
    if ($ownedTempRoot) {
        foreach ($name in $savedTempEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTempEnvironment[$name]) }
        Remove-Item -LiteralPath $ownedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
