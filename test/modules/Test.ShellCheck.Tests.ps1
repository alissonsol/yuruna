<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42fa2e2a-4fa0-4919-9c5c-c40875c57b71
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test shellcheck lint pester
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
    Pester coverage for tools/Invoke-ShellCheck.ps1 -- which files it picks up,
    what its severity setting lets through, and its three exit codes.
.DESCRIPTION
    The gate runs against a throwaway git repository rather than against this
    one, for two reasons. Its discovery IS `git ls-files`, so a fixture only
    becomes visible to it by living inside a repository; and assertions pinned
    to the real tree would restate whatever the shell sources happen to contain
    today instead of stating what the gate does with them.

    Each fixture isolates one behavior: a script clean at every severity, a
    script whose only defect is error-severity (the default must fail it), a
    script whose only defect is info-severity (the default must pass it and a
    lowered severity must not), an extensionless file carrying a shell shebang,
    and files that are neither.

    The gate is launched as a child process because its verdict is its exit
    code -- dot-sourcing it would end this session at its first `exit`.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.ShellCheck.Tests.ps1
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    # The two tools the fixtures need. Skipping is decided per test with
    # Set-ItResult rather than with -Skip, so the probe belongs here: -Skip is
    # evaluated during discovery, and a file-scope assignment made then is gone
    # by the time the run phase reads it.
    $script:GateBlocker =
    if (-not (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
        'shellcheck is not installed on this host'
    } elseif (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        'git is not installed on this host, and the gate discovers its files with git ls-files'
    } else {
        ''
    }

    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Sandbox = $null

    # Fixtures, each verified against shellcheck's own severity ladder:
    #   clean   -- nothing at any severity
    #   broken  -- an unparseable test expression, which is error-severity
    #   noisy   -- unquoted expansion, which is info-severity and nothing more
    #   hook    -- the broken script again, extensionless and shebanged
    #   plain   -- no extension, no shebang, so not shell at all
    $script:Fixtures = [ordered]@{
        'clean/ok.sh'     = "#!/bin/bash`nset -euo pipefail`n`nmain() {`n  echo `"hello `${1:-world}`"`n}`n`nmain `"`$@`"`n"
        'broken/bad.sh'   = "#!/bin/bash`nset -euo pipefail`n`nif [ -n `"`$1`" ; then`n  echo `"yes`"`nfi`n"
        'noisy/noisy.sh'  = "#!/bin/bash`nset -euo pipefail`n`ntarget=`$1`necho `$target`n"
        'hook/pre-commit' = "#!/bin/sh`nif [ -z `"`$1`" ; then`n  exit 1`nfi`nexit 0`n"
        'plain/VERSION'   = "2026.09.12`n"
        'plain/notes'     = "not a shell script`n"
    }

    if (-not $script:GateBlocker) {
        $script:Sandbox = New-YurunaTestTempDir -Prefix 'yuruna-shellcheck'
        & git init --quiet $script:Sandbox 2>&1 | Out-Null

        $gateDir = Join-Path $script:Sandbox 'tools'
        $null = New-Item -ItemType Directory -Force -Path $gateDir
        # The gate takes its repo root as the parent of its own directory, so
        # the copy has to keep the tools/ level for the sandbox to become root.
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'tools/Invoke-ShellCheck.ps1') `
            -Destination (Join-Path $gateDir 'Invoke-ShellCheck.ps1')
        $script:SandboxGate = Join-Path $gateDir 'Invoke-ShellCheck.ps1'

        foreach ($name in $script:Fixtures.Keys) {
            $target = Join-Path $script:Sandbox $name
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
            # WriteAllText, not Set-Content: the fixtures assert on line numbers,
            # and a BOM or CRLF would be shellcheck's finding rather than ours.
            [IO.File]::WriteAllText($target, $script:Fixtures[$name], [Text.UTF8Encoding]::new($false))
        }
    }

    function Invoke-GateUnderTest {
        <#
        .SYNOPSIS
        Runs the sandboxed gate and returns its exit code with its output.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Position = 0)][string[]]$Arguments = @(),
            [string]$SearchPath
        )
        $restore = $env:PATH
        try {
            if ($PSBoundParameters.ContainsKey('SearchPath')) { $env:PATH = $SearchPath }
            $output = & $script:Pwsh -NoProfile -File $script:SandboxGate @Arguments 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
        } finally {
            $env:PATH = $restore
        }
    }
}

AfterAll {
    Remove-YurunaTestTempDir $script:Sandbox
}

Describe 'which files the gate picks up' {
    It 'passes a shell script that is clean at every severity' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        $run = Invoke-GateUnderTest @('-Path', 'clean', '-Severity', 'style')
        Assert-Equal 0 $run.ExitCode "A clean fixture must pass. Output: $($run.Output)"
        Assert-Match 'across 1 tracked/new shell file' $run.Output 'The summary must name how many files were checked.'
    }

    It 'fails a shell script carrying a defect the default severity covers' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        $run = Invoke-GateUnderTest @('-Path', 'broken')
        Assert-Equal 1 $run.ExitCode "A parse failure must fail the gate at its default severity. Output: $($run.Output)"
        Assert-Match 'broken/bad\.sh:\d+:\d+\s+SC\d+\s+\S' $run.Output 'Each finding must carry file, line, code and message.'
    }

    It 'checks an extensionless file whose first line is a shell shebang' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        $run = Invoke-GateUnderTest @('-Path', 'hook')
        Assert-Equal 1 $run.ExitCode "A shebanged hook is shell source and must be scanned. Output: $($run.Output)"
        Assert-Match 'hook/pre-commit:\d+' $run.Output 'The finding must name the hook it came from.'
    }

    It 'leaves alone a file that is neither *.sh nor shebanged' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        $run = Invoke-GateUnderTest @('-Path', 'plain')
        Assert-Equal 0 $run.ExitCode "Non-shell files must not reach shellcheck. Output: $($run.Output)"
        Assert-Match 'No shell files to scan' $run.Output 'An empty selection must say so rather than report a clean scan.'
    }
}

Describe 'the severity aperture' {
    It 'passes an info-severity defect at the default severity' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        $run = Invoke-GateUnderTest @('-Path', 'noisy')
        Assert-Equal 0 $run.ExitCode "The default is error-severity and must let this through. Output: $($run.Output)"
        Assert-Match 'shellcheck: 0 finding' $run.Output 'A pass has to be reported as zero findings, not as an empty scan.'
    }

    It 'reports that same file once the severity is lowered' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        $run = Invoke-GateUnderTest @('-Path', 'noisy', '-Severity', 'info')
        Assert-Equal 1 $run.ExitCode "-Severity info must widen the aperture, not just relabel it. Output: $($run.Output)"
        Assert-Match 'noisy/noisy\.sh:\d+:\d+\s+SC2086\s+\S' $run.Output 'The widened scan must report file, line, code and message.'
    }
}

Describe 'reporting and exit codes' {
    It 'prints only the summary under -Quiet' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        $run = Invoke-GateUnderTest @('-Path', 'noisy', '-Severity', 'info', '-Quiet')
        Assert-Equal 1 $run.ExitCode "-Quiet changes what is printed, never the verdict. Output: $($run.Output)"
        Assert-Match 'shellcheck: 1 finding' $run.Output 'The summary survives -Quiet.'
        Assert-True ($run.Output -notmatch 'SC2086') "-Quiet must suppress the per-finding lines. Output: $($run.Output)"
    }

    It 'exits 2, not 1, when shellcheck is not on PATH' {
        if ($script:GateBlocker) { Set-ItResult -Skipped -Because $script:GateBlocker; return }
        # An empty PATH is safe here: the child is launched by absolute path,
        # and the gate probes for shellcheck before it needs git. Exit 2 has to
        # stay distinct from exit 1, or "the tool is missing" reads as "the tree
        # is dirty" and a host with no shellcheck looks like a failing gate.
        $empty = New-YurunaTestTempDir -Prefix 'yuruna-shellcheck-nopath'
        try {
            $run = Invoke-GateUnderTest -SearchPath $empty
            Assert-Equal 2 $run.ExitCode "A missing shellcheck is its own exit code. Output: $($run.Output)"
        } finally {
            Remove-YurunaTestTempDir $empty
        }
    }
}
