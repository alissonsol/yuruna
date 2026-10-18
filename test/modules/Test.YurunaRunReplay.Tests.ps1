<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42a44e29-5c60-4a95-983b-2d0faa58e472
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest replay shell performance pester
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
    Verify automation/yuruna-run.sh replays guest output through one
    descriptor that stays open, with no per-tick wc/sed/cat, while every
    replayed byte and every exit path stays exactly as before.
.DESCRIPTION
    Runs wherever bash is on PATH (Git Bash on Windows); a missing bash is a
    failure that names the tool, per the project's skip rule, not a skip.
    The dynamic tests drive the real script end to end with a unique
    --token per test and TMPDIR pointed at TestDrive, so no two runs and no
    two test files collide. Streams are captured through Latin-1 (a lossless
    byte<->char round trip for every value 0x00-0xFF) so the byte comparisons
    below are exact, not a text decoding's approximation of exact.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ScriptPath = Join-Path $script:RepoRoot 'automation/yuruna-run.sh'
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -DisableNameChecking

    if (-not (Get-Command -Name bash -ErrorAction SilentlyContinue)) {
        throw "bash is not on PATH; install it (Git Bash on Windows) and run this suite again."
    }

    function ConvertTo-Base64Utf8 {
        param([Parameter(Mandatory)][string]$Text)
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n")))
    }

    function Invoke-YurunaRun {
        <# .SYNOPSIS
            Runs the real script against $TestDrive; returns stdout/stderr as
            exact bytes (via a Latin-1 round trip) plus the exit code.
        #>
        param([Parameter(Mandatory)][string[]]$RunArgs, [int]$TimeoutSeconds = 20)
        $result = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList (@($script:ScriptPath) + $RunArgs) `
            -Environment @{ TMPDIR = $TestDrive } -TimeoutSeconds $TimeoutSeconds -StreamEncoding ([Text.Encoding]::Latin1)
        if (-not (Test-BoundedNativeResultComplete $result)) {
            throw "yuruna-run.sh did not complete: $($result | ConvertTo-Json -Compress)"
        }
        [pscustomobject]@{
            StdOutBytes = [Text.Encoding]::Latin1.GetBytes($result.StdOut)
            StdErr      = $result.StdErr
            ExitCode    = $result.ExitCode
        }
    }

    function Get-YurunaRunExitLine {
        param([Parameter(Mandatory)][string]$StdErr)
        ($StdErr -split "`n" | Where-Object { $_ -match '^YURUNA_RUN_EXIT ' } | Select-Object -Last 1)
    }
}

Describe 'yuruna-run.sh replays every output shape byte for byte' {
    It 'replays blank lines, spacing, tabs, backslashes, embedded CRs, a line over 64 KiB, and a final partial line' {
        $payload = @(
            "printf 'line one\n'"
            "printf '\n'"
            "printf '  spaced  \n'"
            "printf 'tab\ta\n'"
            "printf 'back\\slash\n'"
            "printf 'withcr\r\n'"
            "sleep 1"
            'LONG=$(head -c 70000 /dev/zero | tr ' + "'\0' 'A')"
            'printf ' + "'%s\n' " + '"$LONG"'
            "sleep 1"
            "printf 'final-no-newline'"
            "exit 5"
        ) -join "`n"
        $token = 'shapes-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $run = Invoke-YurunaRun -RunArgs @('--token', $token, '--budget', '15', '--cmd-b64', (ConvertTo-Base64Utf8 $payload))

        $expected = [Text.Encoding]::Latin1.GetBytes(
            "line one`n" + "`n" + "  spaced  `n" + "tab`ta`n" + "back\slash`n" + "withcr`r`n" +
            ('A' * 70000) + "`n" + 'final-no-newline' + "`n"
        )
        [Convert]::ToBase64String($run.StdOutBytes) | Should -Be ([Convert]::ToBase64String($expected)) -Because 'a byte difference must show as a difference, not a stringified near-match'
        $run.ExitCode | Should -Be 5
        Get-YurunaRunExitLine -StdErr $run.StdErr | Should -Be 'YURUNA_RUN_EXIT rc=5 lines=8'
    }

    It 'resumes from --from-line N without replaying lines 1..N again' {
        $token = 'resume-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $payload = (1..6 | ForEach-Object { "printf 'line %s\n' $_" }) -join "`n"
        $first = Invoke-YurunaRun -RunArgs @('--token', $token, '--budget', '15', '--cmd-b64', (ConvertTo-Base64Utf8 $payload))
        $first.ExitCode | Should -Be 0
        Get-YurunaRunExitLine -StdErr $first.StdErr | Should -Be 'YURUNA_RUN_EXIT rc=0 lines=6'

        $resumed = Invoke-YurunaRun -RunArgs @('--token', $token, '--from-line', '3')
        [Text.Encoding]::Latin1.GetString($resumed.StdOutBytes) | Should -Be "line 4`nline 5`nline 6`n"
        Get-YurunaRunExitLine -StdErr $resumed.StdErr | Should -Be 'YURUNA_RUN_EXIT rc=0 lines=6'
    }

    It 'reports lines=0 for a payload that prints nothing' {
        $token = 'silent-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $run = Invoke-YurunaRun -RunArgs @('--token', $token, '--budget', '15', '--cmd-b64', (ConvertTo-Base64Utf8 'exit 0'))
        $run.StdOutBytes.Count | Should -Be 0
        $run.ExitCode | Should -Be 0
        Get-YurunaRunExitLine -StdErr $run.StdErr | Should -Be 'YURUNA_RUN_EXIT rc=0 lines=0'
    }

    It 'passes a non-zero exit code through unchanged' {
        $token = 'rc-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $run = Invoke-YurunaRun -RunArgs @('--token', $token, '--budget', '15', '--cmd-b64', (ConvertTo-Base64Utf8 "printf 'done\n'`nexit 17"))
        $run.ExitCode | Should -Be 17
        Get-YurunaRunExitLine -StdErr $run.StdErr | Should -Be 'YURUNA_RUN_EXIT rc=17 lines=1'
    }
}

Describe 'yuruna-run.sh replay starts no process per tick' {
    BeforeAll {
        $script:ScriptText = Get-Content -Raw -LiteralPath $script:ScriptPath
    }
    It 'names none of wc, sed or cat in yr_drain' {
        $body = Get-YurunaTestShellFunction -Text $script:ScriptText -Name 'yr_drain'
        $body | Should -Not -Match '\bwc\b'
        $body | Should -Not -Match '\bsed\b'
        $body | Should -Not -Match '\bcat\b'
    }
    It 'names none of wc, sed or cat in the replay wait loop' {
        $match = [regex]::Match($script:ScriptText, '(?ms)^while \[ ! -f "\$YR_STATUS" \]; do$.*?^done$')
        $match.Success | Should -BeTrue -Because 'the wait loop must still exist with its original guard'
        $match.Value | Should -Not -Match '\bwc\b'
        $match.Value | Should -Not -Match '\bsed\b'
        $match.Value | Should -Not -Match '\bcat\b'
    }
    It 'opens descriptor 7 exactly once' {
        @([regex]::Matches($script:ScriptText, 'exec 7<')).Count | Should -Be 1
    }
}
