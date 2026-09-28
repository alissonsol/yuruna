<#PSScriptInfo
.VERSION 2026.09.27
.GUID 424d0135-9a4f-40da-a735-010d52f5a269
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test detached-launch host-refresh pester
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
    Start-YurunaDetachedProcess and its helpers: the detached worker shape a
    host refresh and a restarted runner use.
.DESCRIPTION
    POSIX launches are real: a stand-in worker in a private directory records
    the arguments it received, its environment and its handshake, so the
    argument vector (spaces, quotes, dollar signs, backticks, shell
    metacharacters, empty strings, trailing slashes, non-ASCII), the
    -NonInteractive refusal of a prompt, stdin at end of file, the stream
    files and the separate process group are all observed from the child.

    The Windows argument encoder is pure and round-trips through a reference
    CommandLineToArgvW parser implemented here, so it runs on every host. The
    hop body runs in a child pwsh on any host for its spec handling; the full
    Windows hop with its unredirected launcher runs only on Windows and is
    reported as skipped elsewhere.
#>

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $script:Here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.InnerSpawn.psm1') -Force -DisableNameChecking
    $script:ModulePath = Join-Path $script:Here 'Test.InnerSpawn.psm1'
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-detach'
    $script:Pwsh = [Environment]::ProcessPath

    function ConvertFrom-TestWindowsCommandLine {
        # Reference splitter with the CommandLineToArgvW / MSVCRT rules the
        # encoder targets: 2n backslashes before a quote give n and a quote
        # toggle, 2n+1 give n and a literal quote, other backslashes are
        # literal, and "" inside quotes is a literal quote.
        [CmdletBinding()]
        [OutputType([string[]], [object[]])]
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
        $out = [System.Collections.Generic.List[string]]::new()
        $i = 0
        $n = $Line.Length
        while ($i -lt $n) {
            while ($i -lt $n -and ($Line[$i] -eq ' ' -or $Line[$i] -eq "`t")) { $i++ }
            if ($i -ge $n) { break }
            $sb = [System.Text.StringBuilder]::new()
            $inQuote = $false
            while ($i -lt $n) {
                $c = $Line[$i]
                if (-not $inQuote -and ($c -eq ' ' -or $c -eq "`t")) { break }
                if ($c -eq [char]92) {
                    $slashes = 0
                    while ($i -lt $n -and $Line[$i] -eq [char]92) { $slashes++; $i++ }
                    if ($i -lt $n -and $Line[$i] -eq '"') {
                        [void]$sb.Append([char]92, [int][Math]::Floor($slashes / 2))
                        if ($slashes % 2 -eq 1) { [void]$sb.Append('"'); $i++ }
                    } else {
                        [void]$sb.Append([char]92, $slashes)
                    }
                    continue
                }
                if ($c -eq '"') {
                    if ($inQuote -and $i + 1 -lt $n -and $Line[$i + 1] -eq '"') { [void]$sb.Append('"'); $i += 2; continue }
                    $inQuote = -not $inQuote
                    $i++
                    continue
                }
                [void]$sb.Append($c)
                $i++
            }
            $out.Add($sb.ToString())
        }
        return , $out.ToArray()
    }

    function New-StandInWorker {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a stand-in worker script under the suite temp dir.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([int]$LingerSeconds = 0)
        $path = Join-Path $script:Work ('worker-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $module = $script:ModulePath.Replace("'", "''")
        $body = @"
Import-Module '$module' -DisableNameChecking
`$null = Write-YurunaDetachedHandshake -RequestId 'req-7' -Attempt 2
`$prompt = try { `$null = Read-Host 'answer'; 'returned' } catch { 'refused' }
`$stdinText = [Console]::In.ReadToEnd()
[ordered]@{
    args        = @(`$args)
    commandLine = @([Environment]::GetCommandLineArgs())
    prompt      = `$prompt
    stdinLength = `$stdinText.Length
    cwd         = (Get-Location).ProviderPath
    nonInteractive = `$env:YURUNA_NONINTERACTIVE
    extra       = `$env:YURUNA_TEST_EXTRA
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Split-Path -Parent `$env:YURUNA_DETACH_HANDSHAKE) 'observed.json') -Encoding utf8NoBOM
'to-stdout'
[Console]::Error.WriteLine('to-stderr')
Start-Sleep -Seconds $LingerSeconds
"@
        [System.IO.File]::WriteAllText($path, $body)
        return $path
    }

    function New-PrivateDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a directory under the suite temp dir.')]
        [CmdletBinding()]
        [OutputType([string])]
        param()
        $dir = Join-Path $script:Work ('private-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }

    function Wait-TestFile {
        [CmdletBinding()]
        [OutputType([bool])]
        param([string]$Path, [int]$Seconds = 30)
        $until = [DateTime]::UtcNow.AddSeconds($Seconds)
        while ([DateTime]::UtcNow -lt $until) {
            if (Test-Path -LiteralPath $Path) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }
}

AfterAll {
    Remove-YurunaTestTempDir $script:Work
}

Describe 'Start-YurunaDetachedProcess -- POSIX detach with a real stand-in worker' -Skip:$IsWindows {
    It 'carries every argument verbatim, refuses prompts, detaches stdin and streams, and leads its own process group' {
        $private = New-PrivateDir
        $sentinel = Join-Path $script:Work 'must-not-exist'
        $nonAscii = 'caf' + [char]0x00E9 + ' ' + [char]0x65E5
        $arguments = @('has space', "it's", '$HOME', 'back`tick', "; touch $sentinel", '', 'trailing/', $nonAscii)
        $handshake = Join-Path $private 'hs.json'
        $r = Start-YurunaDetachedProcess -FilePath (New-StandInWorker -LingerSeconds 5) -ArgumentList $arguments `
            -WorkingDirectory $script:Work -Environment @{ YURUNA_TEST_EXTRA = 'extra-value' } `
            -StdOutPath (Join-Path $private 'out.txt') -StdErrPath (Join-Path $private 'err.txt') `
            -PrivateDirectory $private -HandshakePath $handshake -WaitForHandshakeMilliseconds 30000 -Confirm:$false
        Assert-True $r.Launched "launched ($($r.Reason) $($r.Detail))"
        Assert-Equal -Expected 'launched' -Actual $r.Reason
        Assert-True ($r.FinalPid -gt 0) 'the final worker PID, not the launcher, is reported'
        Assert-NotEqual -Expected $r.LauncherPid -Actual $r.FinalPid
        Assert-Equal -Expected $r.FinalPid -Actual ([int]$r.Handshake.pid) -Because 'the handshake was written by the worker itself'
        $verified = Read-YurunaDetachedHandshake -Path $handshake -ExpectedRequestId 'req-7' -ExpectedAttempt 2
        Assert-True $verified.Valid "the live worker matches its handshake ($($verified.Reason))"
        Assert-True (Wait-TestFile -Path (Join-Path $private 'observed.json')) 'the worker reported what it saw'
        $seen = Get-Content -LiteralPath (Join-Path $private 'observed.json') -Raw | ConvertFrom-Json
        Assert-Equal -Expected ($arguments -join '|') -Actual (@($seen.args) -join '|') -Because 'every argument arrives as one element, unexpanded'
        Assert-False (Test-Path -LiteralPath $sentinel) 'a shell metacharacter in an argument never runs'
        Assert-True (@($seen.commandLine) -contains '-NonInteractive') 'launched -NonInteractive'
        Assert-Equal -Expected 'refused' -Actual $seen.prompt -Because 'a prompt in the worker is refused, not waited on'
        Assert-Equal -Expected 0 -Actual ([int]$seen.stdinLength) -Because 'stdin is at end of file'
        # macOS exposes /var through /private/var in a new process. Compare
        # the directory identities instead of requiring the parent's alias.
        $expectedCwd = Resolve-YurunaCanonicalPath -Path $script:Work
        $actualCwd = Resolve-YurunaCanonicalPath -Path $seen.cwd
        Assert-True ($expectedCwd.Resolved -and $actualCwd.Resolved) 'both working directories resolve'
        Assert-Equal -Expected $expectedCwd.Path -Actual $actualCwd.Path
        Assert-Equal -Expected '1' -Actual $seen.nonInteractive
        Assert-Equal -Expected 'extra-value' -Actual $seen.extra
        Assert-True (Wait-TestFile -Path (Join-Path $private 'err.txt')) 'stderr file exists'
        Start-Sleep -Seconds 1
        Assert-Match -Pattern 'to-stdout' -Actual (Get-Content -LiteralPath (Join-Path $private 'out.txt') -Raw)
        Assert-Match -Pattern 'to-stderr' -Actual (Get-Content -LiteralPath (Join-Path $private 'err.txt') -Raw)
    }

    It 'never lets the launcher''s own handshake path or hop identity reach the worker' {
        $private = New-PrivateDir
        $report = Join-Path $private 'env.txt'
        $probe = Join-Path $script:Work ('env-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($probe, 'Set-Content -LiteralPath $args[0] -Value "HS=$env:YURUNA_DETACH_HANDSHAKE;HOP=$env:YURUNA_DETACH_HOP_PID;START=$env:YURUNA_DETACH_HOP_START" -Encoding utf8NoBOM')
        $names = @('YURUNA_DETACH_HANDSHAKE', 'YURUNA_DETACH_HOP_PID', 'YURUNA_DETACH_HOP_START')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            # What a launcher that is itself a detached worker carries.
            $env:YURUNA_DETACH_HANDSHAKE = Join-Path $private 'launcher-hs.json'
            $env:YURUNA_DETACH_HOP_PID = '4242'
            $env:YURUNA_DETACH_HOP_START = '1700000000000'
            $r = Start-YurunaDetachedProcess -FilePath $probe -ArgumentList @($report) -WorkingDirectory $script:Work -StdOutPath '/dev/null' `
                -StdErrPath (Join-Path $private 'err.txt') -PrivateDirectory $private -Confirm:$false
            Assert-True $r.Launched "launched ($($r.Reason) $($r.Detail))"
        } finally {
            foreach ($name in $names) {
                if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
            }
        }
        Assert-True (Wait-TestFile -Path $report) 'the worker reported its environment'
        Start-Sleep -Milliseconds 200
        Assert-Equal -Expected 'HS=;HOP=;START=' -Actual (Get-Content -LiteralPath $report -Raw).Trim() -Because 'the worker starts with none of the launcher''s detach state'
    }

    It 'refuses a stream path outside the private directory, a relative path and an unwritable stream, launching nothing' {
        $private = New-PrivateDir
        $worker = New-StandInWorker
        $outside = Start-YurunaDetachedProcess -FilePath $worker -WorkingDirectory $script:Work -StdOutPath (Join-Path $script:Work 'out.txt') `
            -StdErrPath (Join-Path $private 'err.txt') -PrivateDirectory $private -Confirm:$false
        Assert-Equal -Expected 'invalid-argument' -Actual $outside.Reason
        Assert-Equal -Expected 'StdOutPath' -Actual $outside.Detail
        $relative = Start-YurunaDetachedProcess -FilePath 'worker.ps1' -WorkingDirectory $script:Work -StdOutPath '/dev/null' `
            -StdErrPath (Join-Path $private 'err.txt') -PrivateDirectory $private -Confirm:$false
        Assert-Equal -Expected 'FilePath' -Actual $relative.Detail
        $unwritable = Start-YurunaDetachedProcess -FilePath $worker -WorkingDirectory $script:Work -StdOutPath '/dev/null' `
            -StdErrPath (Join-Path $private 'missing-dir/err.txt') -PrivateDirectory $private -Confirm:$false
        Assert-Equal -Expected 'invalid-argument' -Actual $unwritable.Reason
        Assert-Equal -Expected 'StdErrPath' -Actual $unwritable.Detail
        Assert-Null $unwritable.FinalPid
    }

    It 'reports launcher-failed when no interpreter resolves, and launches nothing under -WhatIf' {
        $private = New-PrivateDir
        $worker = New-StandInWorker
        Mock -ModuleName Test.InnerSpawn Get-PwshExePath { '/nonexistent/pwsh' }
        $r = Start-YurunaDetachedProcess -FilePath $worker -WorkingDirectory $script:Work -StdOutPath '/dev/null' `
            -StdErrPath (Join-Path $private 'err.txt') -PrivateDirectory $private -Confirm:$false
        Assert-Equal -Expected 'launcher-failed' -Actual $r.Reason
        Assert-Equal -Expected 'pwsh-unresolved' -Actual $r.Detail
        $preview = Start-YurunaDetachedProcess -FilePath $worker -WorkingDirectory $script:Work -StdOutPath '/dev/null' `
            -StdErrPath (Join-Path $private 'err2.txt') -PrivateDirectory $private -WhatIf
        Assert-Equal -Expected 'whatif' -Actual $preview.Reason
        Assert-False $preview.Launched 'a preview launches nothing'
    }

    It 'times out when the worker never writes its handshake' {
        $private = New-PrivateDir
        $silent = Join-Path $script:Work 'silent.ps1'
        [System.IO.File]::WriteAllText($silent, 'Start-Sleep -Seconds 3')
        $r = Start-YurunaDetachedProcess -FilePath $silent -WorkingDirectory $script:Work -StdOutPath '/dev/null' `
            -StdErrPath (Join-Path $private 'err.txt') -PrivateDirectory $private -HandshakePath (Join-Path $private 'hs.json') `
            -WaitForHandshakeMilliseconds 1500 -Confirm:$false
        Assert-Equal -Expected 'handshake-timeout' -Actual $r.Reason
        Assert-False $r.Launched 'an unacknowledged worker is not a launch'
        Assert-True ($r.FinalPid -gt 0) 'the worker identity is still reported'
    }
}

Describe 'The POSIX launcher body' {
    It 'passes shellcheck at warning severity' -Skip:($IsWindows -or -not (Get-Command shellcheck -CommandType Application -ErrorAction SilentlyContinue)) {
        $body = InModuleScope Test.InnerSpawn { $script:DetachShellBody }
        Assert-Match -Pattern 'nohup "\$@"' -Actual $body
        $file = Join-Path (New-PrivateDir) 'detach-body.sh'
        [System.IO.File]::WriteAllText($file, "#!/bin/bash`n$body`n")
        $r = Invoke-BoundedNativeCommand -FilePath 'shellcheck' -ArgumentList @('--severity=warning', '--', $file) -TimeoutSeconds 60
        Assert-True (Test-BoundedNativeResultComplete -Result $r) 'shellcheck ran to completion'
        $findings = (([string]$r.StdOut + [string]$r.StdErr) -replace "`e\[[0-9;]*m", '').Trim()
        Assert-Equal -Expected 0 -Actual $r.ExitCode -Because $findings
    }
}

Describe 'Get-YurunaDetachProcessIdentity bounds its ps by the caller''s deadline (macOS shape, stand-in)' {
    It 'passes the deadline to ps, and skips ps once the deadline is spent' {
        Mock -ModuleName Test.InnerSpawn Get-YurunaDetachPlatform { 'MacOS' }
        $script:PsCalls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Test.InnerSpawn Invoke-BoundedNativeCommand {
            $script:PsCalls.Add([pscustomobject]@{ TimeoutSeconds = $TimeoutSeconds; HasDeadline = ($null -ne $Deadline) })
            @{ Started = $true; ExitCode = 0; StdOut = '  1   42  501'; StdErr = ''; TimedOut = $false; DeadlineExhausted = $false; Truncated = $false }
        }
        Mock -ModuleName Test.InnerSpawn Test-BoundedNativeResultComplete { $true }
        $bounded = InModuleScope Test.InnerSpawn { Get-YurunaDetachProcessIdentity -ProcessId $PID -Deadline (New-YurunaDeadline -TotalMilliseconds 3000) }
        Assert-Equal -Expected 1 -Actual $script:PsCalls.Count
        Assert-True ($script:PsCalls[0].TimeoutSeconds -le 3) "timeout $($script:PsCalls[0].TimeoutSeconds) s stays inside the 3 s deadline"
        Assert-True $script:PsCalls[0].HasDeadline 'the deadline itself is passed down'
        Assert-Equal -Expected 42 -Actual $bounded.ProcessGroupId
        $spent = InModuleScope Test.InnerSpawn { Get-YurunaDetachProcessIdentity -ProcessId $PID -Deadline (New-YurunaDeadline -TotalMilliseconds 0) }
        Assert-Equal -Expected 1 -Actual $script:PsCalls.Count -Because 'a spent deadline runs no ps'
        Assert-Null $spent.ProcessGroupId
    }
}

Describe 'ConvertTo-YurunaWindowsCommandLine (reference CommandLineToArgvW round trip)' {
    It 'round-trips empty strings, whitespace, trailing backslashes, embedded quotes, UNC paths and non-ASCII' {
        $cases = @('', ' ', "`t", 'plain', 'a b', 'a\', 'a\\', 'a"b', 'a\"b', 'a\\"b', '\\server\share\', 'C:\Program Files\x\',
            ('na' + [char]0x00EF + 've caf' + [char]0x00E9), 'ends with space ', '"quoted"')
        $line = ConvertTo-YurunaWindowsCommandLine -Argument $cases
        $back = ConvertFrom-TestWindowsCommandLine -Line $line
        Assert-Equal -Expected $cases.Count -Actual $back.Count -Because "the line was: $line"
        for ($i = 0; $i -lt $cases.Count; $i++) {
            Assert-StringEqual -Expected $cases[$i] -Actual $back[$i] -Because "argument $i"
        }
    }
    It 'leaves an argument without separators or quotes unquoted' {
        Assert-Equal -Expected 'a\b c:\d\ -X' -Actual (ConvertTo-YurunaWindowsCommandLine -Argument @('a\b', 'c:\d\', '-X'))
    }
    It 'rejects the characters a Windows path argument cannot carry' {
        foreach ($bad in @('a"b', 'a<b', 'a>b', 'a|b', 'a?b', 'a*b', ('a' + [char]0 + 'b'), '')) {
            Assert-False (Test-YurunaWindowsPathArgument -Path $bad) "rejected: $bad"
        }
        Assert-True (Test-YurunaWindowsPathArgument -Path 'C:\Users\Yuruna Test\run $x''s\') 'spaces, dollar signs and apostrophes are fine'
    }
}

Describe 'Invoke-YurunaDetachedHop spec handling (run in a child pwsh)' -Skip:$IsWindows {
    It 'launches the final worker from a valid spec, acknowledges separately, and hands it the hop identity' {
        $private = New-PrivateDir
        $probe = Join-Path $script:Work 'hop-final.ps1'
        [System.IO.File]::WriteAllText($probe, "Set-Content -LiteralPath '$(Join-Path $private 'final.txt')' -Value `"`$env:YURUNA_DETACH_HOP_PID|`$env:YURUNA_TEST_EXTRA`"")
        $spec = Join-Path $private 'x.hop.json'
        [ordered]@{
            schemaVersion = 1; pwsh = $script:Pwsh; argumentList = @('-NoProfile', '-NonInteractive', '-File', $probe)
            workingDirectory = $script:Work; environment = @{ YURUNA_TEST_EXTRA = 'from-spec' }
            stdin = (Join-Path $private 'stdin.empty'); stdout = (Join-Path $private 'out.txt'); stderr = (Join-Path $private 'err.txt')
        } | ConvertTo-Json | Set-Content -LiteralPath $spec -Encoding utf8NoBOM
        & $script:Pwsh -NoProfile -NonInteractive -Command "Import-Module '$($script:ModulePath)' -DisableNameChecking; exit (Invoke-YurunaDetachedHop -SpecPath '$spec')"
        $hopExit = $LASTEXITCODE
        Assert-Equal -Expected 0 -Actual $hopExit
        $ack = Get-Content -LiteralPath "$spec.ack.json" -Raw | ConvertFrom-Json
        Assert-True $ack.launched 'the hop acknowledged the launch'
        Assert-True ([int]$ack.finalPid -gt 0 -and [int]$ack.finalPid -ne [int]$ack.hopPid) 'the acknowledgment names the final worker, distinct from the hop'
        Assert-True (Wait-TestFile -Path (Join-Path $private 'final.txt')) 'the final worker ran'
        Start-Sleep -Milliseconds 300
        $final = (Get-Content -LiteralPath (Join-Path $private 'final.txt') -Raw).Trim()
        Assert-Equal -Expected "$($ack.hopPid)|from-spec" -Actual $final -Because 'the worker learns the hop identity and the spec environment'
        Assert-True (Test-Path -LiteralPath (Join-Path $private 'stdin.empty')) 'the empty stdin sentinel was created'
    }
    It 'refuses a spec with a relative path and records why' {
        $private = New-PrivateDir
        $spec = Join-Path $private 'bad.hop.json'
        [ordered]@{ schemaVersion = 1; pwsh = 'pwsh'; argumentList = @(); workingDirectory = $script:Work
            stdin = 'in'; stdout = 'out'; stderr = 'err' } | ConvertTo-Json | Set-Content -LiteralPath $spec -Encoding utf8NoBOM
        & $script:Pwsh -NoProfile -NonInteractive -Command "Import-Module '$($script:ModulePath)' -DisableNameChecking; exit (Invoke-YurunaDetachedHop -SpecPath '$spec')"
        Assert-Equal -Expected 1 -Actual $LASTEXITCODE
        $ack = Get-Content -LiteralPath "$spec.ack.json" -Raw | ConvertFrom-Json
        Assert-False $ack.launched 'nothing launched'
        Assert-Equal -Expected 'spec-invalid-pwsh' -Actual $ack.error
    }
    It 'reports a failed second spawn in its acknowledgment' {
        $private = New-PrivateDir
        $spec = Join-Path $private 'fail.hop.json'
        [ordered]@{ schemaVersion = 1; pwsh = '/nonexistent/pwsh'; argumentList = @('-NoProfile'); workingDirectory = $script:Work
            stdin = (Join-Path $private 'stdin.empty'); stdout = (Join-Path $private 'o.txt'); stderr = (Join-Path $private 'e.txt') } |
            ConvertTo-Json | Set-Content -LiteralPath $spec -Encoding utf8NoBOM
        & $script:Pwsh -NoProfile -NonInteractive -Command "Import-Module '$($script:ModulePath)' -DisableNameChecking; exit (Invoke-YurunaDetachedHop -SpecPath '$spec')"
        Assert-Equal -Expected 1 -Actual $LASTEXITCODE
        Assert-Equal -Expected 'final-start-failed' -Actual (Get-Content -LiteralPath "$spec.ack.json" -Raw | ConvertFrom-Json).error
    }
}

# Defined only on Windows: the reparent hop exists only there, and a new
# suite may not carry skips.
if ($IsWindows) {
    Describe 'Start-YurunaDetachedProcess -- Windows reparent hop' {
        It 'launches through an unredirected hop, whose acknowledgment is distinct from the worker handshake' {
            $private = New-PrivateDir
            $handshake = Join-Path $private 'hs.json'
            $r = Start-YurunaDetachedProcess -FilePath (New-StandInWorker -LingerSeconds 5) -ArgumentList @('has space', 'trailing\') `
                -WorkingDirectory $script:Work -StdOutPath (Join-Path $private 'out.txt') -StdErrPath (Join-Path $private 'err.txt') `
                -PrivateDirectory $private -HandshakePath $handshake -WaitForHandshakeMilliseconds 60000 -Confirm:$false
            Assert-True $r.Launched "launched ($($r.Reason) $($r.Detail))"
            Assert-NotEqual -Expected $r.LauncherPid -Actual $r.FinalPid
            $ack = @(Get-ChildItem -LiteralPath $private -Filter '*.hop.json.ack.json')[0]
            Assert-NotNull $ack
            Assert-Equal -Expected $r.FinalPid -Actual ([int]$r.Handshake.pid)
        }
        It 'lets the final worker wait for the hop to exit' {
            $hop = Start-Process -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 2' -PassThru -WindowStyle Hidden
            $start = ([DateTimeOffset]$hop.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
            $r = Wait-YurunaDetachedHopExit -HopPid $hop.Id -HopStartTimeUnixMs $start -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
            Assert-True $r.Exited 'the hop exited'
            Assert-Equal -Expected 'exited' -Actual $r.Reason
        }
    }
}

Describe 'Read-YurunaDetachedHandshake and Wait-YurunaDetachedHopExit' {
    BeforeAll {
        $script:HsDir = New-PrivateDir
        function Write-TestHandshake {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a handshake file under the suite temp dir.')]
            param([int]$ProcessId, $Start, [string]$RequestId = 'r1', [int]$Attempt = 1)
            $path = Join-Path $script:HsDir ('hs-' + [guid]::NewGuid().ToString('N') + '.json')
            [ordered]@{ schemaVersion = 1; pid = $ProcessId; startTimeUnixMs = $Start; requestId = $RequestId; attempt = $Attempt } |
                ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            return $path
        }
        $script:OwnStart = ([DateTimeOffset](Get-Process -Id $PID).StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
    }

    It 'verifies the exact tuple and names each mismatch' {
        Assert-True (Read-YurunaDetachedHandshake -Path (Write-TestHandshake -ProcessId $PID -Start $script:OwnStart) -ExpectedRequestId 'r1' -ExpectedAttempt 1).Valid 'this live process'
        Assert-Equal -Expected 'missing' -Actual (Read-YurunaDetachedHandshake -Path (Join-Path $script:HsDir 'none.json') -ExpectedRequestId 'r1').Reason
        $bad = Join-Path $script:HsDir 'bad.json'
        Set-Content -LiteralPath $bad -Value '{not json' -Encoding utf8NoBOM
        Assert-Equal -Expected 'unreadable' -Actual (Read-YurunaDetachedHandshake -Path $bad -ExpectedRequestId 'r1').Reason
        Assert-Equal -Expected 'request-mismatch' -Actual (Read-YurunaDetachedHandshake -Path (Write-TestHandshake -ProcessId $PID -Start $script:OwnStart -RequestId 'other') -ExpectedRequestId 'r1').Reason
        Assert-Equal -Expected 'attempt-mismatch' -Actual (Read-YurunaDetachedHandshake -Path (Write-TestHandshake -ProcessId $PID -Start $script:OwnStart) -ExpectedRequestId 'r1' -ExpectedAttempt 5).Reason
        Assert-Equal -Expected 'start-mismatch' -Actual (Read-YurunaDetachedHandshake -Path (Write-TestHandshake -ProcessId $PID -Start ($script:OwnStart - 60000)) -ExpectedRequestId 'r1').Reason
        $dead = Start-Process -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru
        $dead.WaitForExit()
        Assert-Equal -Expected 'process-absent' -Actual (Read-YurunaDetachedHandshake -Path (Write-TestHandshake -ProcessId $dead.Id -Start $script:OwnStart) -ExpectedRequestId 'r1').Reason
        $incomplete = [pscustomobject]@{ Complete = $false; Rows = @() }
        Assert-Equal -Expected 'identity-unknown' -Actual (Read-YurunaDetachedHandshake -Path (Write-TestHandshake -ProcessId 999999 -Start 1) -ExpectedRequestId 'r1' -ProcessTable $incomplete).Reason
    }

    It 'reads no hop as exited, times out on a live hop, and detects a recycled hop PID' {
        $saved = $env:YURUNA_DETACH_HOP_PID
        try {
            Remove-Item Env:YURUNA_DETACH_HOP_PID -ErrorAction SilentlyContinue
            Assert-Equal -Expected 'no-hop' -Actual (Wait-YurunaDetachedHopExit -Deadline (New-YurunaDeadline -TotalMilliseconds 1000)).Reason
        } finally {
            if ($null -ne $saved) { $env:YURUNA_DETACH_HOP_PID = $saved }
        }
        $live = Wait-YurunaDetachedHopExit -HopPid $PID -HopStartTimeUnixMs $script:OwnStart -Deadline (New-YurunaDeadline -TotalMilliseconds 400)
        Assert-False $live.Exited 'a live hop is waited on until the deadline'
        Assert-Equal -Expected 'timeout' -Actual $live.Reason
        $recycled = Wait-YurunaDetachedHopExit -HopPid $PID -HopStartTimeUnixMs ($script:OwnStart - 600000) -Deadline (New-YurunaDeadline -TotalMilliseconds 1000)
        Assert-Equal -Expected 'recycled' -Actual $recycled.Reason
    }
}

Describe 'New-InnerRunnerArgList -NonInteractive' {
    It 'inserts -NonInteractive after -NoProfile only when asked' {
        $plain = New-InnerRunnerArgList -ScriptPath '/x/inner.ps1' -Parameters @{}
        Assert-Equal -Expected '-NoLogo|-NoProfile|-Command' -Actual (($plain | Select-Object -First 3) -join '|')
        $strict = New-InnerRunnerArgList -ScriptPath '/x/inner.ps1' -Parameters @{} -NonInteractive
        Assert-Equal -Expected '-NoLogo|-NoProfile|-NonInteractive|-Command' -Actual (($strict | Select-Object -First 4) -join '|')
    }
}
