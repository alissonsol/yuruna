<#PSScriptInfo
.VERSION 2026.08.25
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

    IMPORTANT -- this script's exit code reports only whether the SUITE PROCESS
    SURVIVED, never whether its tests passed. Pester's standalone path does not
    propagate a failing run through the call operator: a suite whose tests fail
    still returns 0 here. The result file is the authority on pass/fail, and
    the caller treats a missing result file as the real failure signal. Do not
    "simplify" this by trusting the exit code.

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

try {
    $PesterPreference = New-PesterConfiguration
    $PesterPreference.Output.Verbosity      = 'None'
    $PesterPreference.TestResult.Enabled    = $true
    $PesterPreference.TestResult.OutputPath = $Xml
    # Left at its default ($false) deliberately: Run.Exit does not reach this
    # process through the call operator, so enabling it would only suggest an
    # exit-code contract that does not hold.
    & $Suite
    exit 0
} catch {
    # A parse error, a missing module, or a throw outside any It block. No
    # result file is written, which is how the caller distinguishes this from
    # a suite that ran and reported failures.
    Write-Error ("suite process failed: {0}" -f $_.Exception.Message) -ErrorAction Continue
    exit 2
}
