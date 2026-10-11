<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42cb39b2-5a81-409a-936f-4fd0ad06b7e3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test retry diagnostic log append pester
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
    Holds the diagnostic log Invoke-WithYurunaRetry keeps under -LogPath to its
    exact bytes, and each attempt to a single append.
.DESCRIPTION
    The log is read after a failure, by a person and by the system diagnostic,
    so its content is a contract: one section per attempt, made of a header
    line, one line per captured output object, and the exception message when
    the attempt threw. The first Describe compares whole files for every shape
    the capture can take -- nothing, a scalar, a $null, an object whose text
    holds a line break, an error record merged from the error stream -- so a
    change of line terminator, encoding or ordering fails as loudly as a
    missing line.

    The second Describe holds the mechanism rather than the clock. An attempt
    reaches the log through one Add-Content call whatever it printed; a tool
    that prints two thousand lines otherwise pays two thousand file opens, which
    on a host that scans files as they are opened is most of a minute against a
    few milliseconds. An elapsed-time assertion would state that only for the
    machine it was tuned on, and would fail on a slow one for no defect.

    The third Describe is the contract of the section writer itself, which the
    retry helper writes through.

    Get-Date is mocked inside the module so the timestamp in every header is
    fixed, and Start-Sleep so no test waits out a backoff. Every file lives
    under TestDrive. Preferences are passed explicitly wherever a test counts
    error records, because the suite runner starts each suite with a different
    $ErrorActionPreference than a suite started on its own.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Retry.psm1') -Force -DisableNameChecking

    $script:Stamp = '2026-09-27T12:34:56Z'

    function ConvertTo-LogHex {
        <#
        .SYNOPSIS
            The bytes a log holding these lines must have, as hexadecimal text:
            UTF-8 with no byte order mark, every line followed by the platform
            line terminator.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([string[]]$Line)
        $text = [System.Text.StringBuilder]::new()
        foreach ($entry in $Line) { $null = $text.Append($entry).Append([Environment]::NewLine) }
        return [System.BitConverter]::ToString([System.Text.UTF8Encoding]::new($false).GetBytes($text.ToString()))
    }

    function Confirm-LogContent {
        <#
        .SYNOPSIS
            Fails unless the file holds exactly the given lines, byte for byte.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, Position = 0)][string]$Path,
            [Parameter(Position = 1)][string[]]$Line,
            [Parameter(Position = 2)][string]$Because = ''
        )
        $expected = ConvertTo-LogHex -Line $Line
        $actual = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($Path))
        Assert-StringEqual $expected $actual ("$Because`nThe log holds:`n" + [System.IO.File]::ReadAllText($Path))
    }

    function Get-AttemptHeader {
        <#
        .SYNOPSIS
            The header line of one attempt, with the mocked timestamp.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Label, [int]$Attempt, [int]$MaxAttempts, [int]$ExitCode)
        return "== $script:Stamp $Label attempt $Attempt/$MaxAttempts (exit=$ExitCode) =="
    }
}

Describe 'the retry diagnostic log holds one section per attempt, byte for byte' {
    BeforeEach {
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
        Mock -ModuleName 'Yuruna.Retry' Get-Date { [datetime]::new(2026, 9, 27, 12, 34, 56, [DateTimeKind]::Utc) }
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.stderr.log')
    }

    It 'writes the header and then every output line of an attempt' {
        $result = Invoke-WithYurunaRetry -Label 'fixture tool' -MaxAttempts 1 -LogPath $script:Log -ScriptBlock {
            'first line'; 'second line'; 'third line'
            $global:LASTEXITCODE = 0
        }
        Assert-True $result.Success
        Confirm-LogContent $script:Log @(
            (Get-AttemptHeader -Label 'fixture tool' -Attempt 1 -MaxAttempts 1 -ExitCode 0)
            'first line', 'second line', 'third line')
    }

    It 'writes <Name> as the lines a per-object append gives' -ForEach @(
        @{ Name = 'no output'; Emit = { }; Line = @() }
        @{ Name = 'a single string'; Emit = { 'only line' }; Line = @('only line') }
        @{ Name = 'an empty string between two lines'; Emit = { 'before'; ''; 'after' }; Line = @('before', '', 'after') }
        @{ Name = 'a null between two lines'; Emit = { 'before'; $null; 'after' }; Line = @('before', '', 'after') }
        @{ Name = 'a null and nothing else'; Emit = { $null }; Line = @() }
        @{ Name = 'a line feed inside one object'; Emit = { "first`nsecond"; 'third' }; Line = @("first`nsecond", 'third') }
        @{ Name = 'a carriage return and line feed inside one object'; Emit = { "first`r`nsecond" }; Line = @("first`r`nsecond") }
        @{ Name = 'a line that ends in a line feed'; Emit = { "ends here`n"; 'next' }; Line = @("ends here`n", 'next') }
        @{ Name = 'text outside ASCII'; Emit = { "caf$([char]0xE9) $([char]0x4E2D)$([char]0x6587)" }; Line = @("caf$([char]0xE9) $([char]0x4E2D)$([char]0x6587)") }
        @{ Name = 'whitespace-only lines'; Emit = { '   '; "`t" }; Line = @('   ', "`t") }
        @{ Name = 'an integer and a hashtable'; Emit = { 42; @{ key = 'value' } }; Line = @('42', 'System.Collections.Hashtable') }
        @{ Name = 'an error record merged from the error stream'; Emit = { 'to the output'; Write-Error 'to the error stream' -ErrorAction Continue; 'tail' }; Line = @('to the output', 'to the error stream', 'tail') }
    ) {
        $emitBlock = $Emit
        $null = Invoke-WithYurunaRetry -Label 'fixture tool' -MaxAttempts 1 -LogPath $script:Log -ScriptBlock {
            & $emitBlock
            $global:LASTEXITCODE = 0
        }.GetNewClosure()
        Confirm-LogContent $script:Log (@(Get-AttemptHeader -Label 'fixture tool' -Attempt 1 -MaxAttempts 1 -ExitCode 0) + $Line)
    }

    It 'writes a number the same way under a culture whose decimal separator is a comma' {
        $prior = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $null = Invoke-WithYurunaRetry -Label 'fixture tool' -MaxAttempts 1 -LogPath $script:Log -ScriptBlock {
                1.5
                $global:LASTEXITCODE = 0
            }
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $prior }
        Confirm-LogContent $script:Log @((Get-AttemptHeader -Label 'fixture tool' -Attempt 1 -MaxAttempts 1 -ExitCode 0), '1.5')
    }

    It 'appends a section for every attempt, in order, each with its own exit code' {
        $script:calls = 0
        $result = Invoke-WithYurunaRetry -Label 'flaky tool' -MaxAttempts 3 -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 -LogPath $script:Log -ScriptBlock {
            $script:calls++
            "output of call $script:calls"
            $global:LASTEXITCODE = if ($script:calls -lt 3) { 7 } else { 0 }
        }
        Assert-True $result.Success
        Assert-Equal 3 $result.Attempts
        Confirm-LogContent $script:Log @(
            (Get-AttemptHeader -Label 'flaky tool' -Attempt 1 -MaxAttempts 3 -ExitCode 7), 'output of call 1'
            (Get-AttemptHeader -Label 'flaky tool' -Attempt 2 -MaxAttempts 3 -ExitCode 7), 'output of call 2'
            (Get-AttemptHeader -Label 'flaky tool' -Attempt 3 -MaxAttempts 3 -ExitCode 0), 'output of call 3')
    }

    It 'logs the one attempt of a failure the retry predicate declared permanent' {
        $result = Invoke-WithYurunaRetry -Label 'refused tool' -MaxAttempts 4 -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 -LogPath $script:Log -ScriptBlock {
            'Error from server (NotFound): namespaces "missing" not found'
            $global:LASTEXITCODE = 3
        } -ShouldRetry { $false }
        Assert-False $result.Success
        Assert-Equal 1 $result.Attempts
        Confirm-LogContent $script:Log @(
            (Get-AttemptHeader -Label 'refused tool' -Attempt 1 -MaxAttempts 4 -ExitCode 3)
            'Error from server (NotFound): namespaces "missing" not found')
    }

    It 'has the attempt in the log before the retry predicate and the retry callback run' {
        # A predicate or callback may read the log to decide or to report, so
        # the section of the attempt it is asked about has to be there already.
        $seen = [System.Collections.Generic.List[string]]::new()
        $log = $script:Log
        $count = { if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log).Count } else { 0 } }.GetNewClosure()
        $null = Invoke-WithYurunaRetry -Label 'ordered tool' -MaxAttempts 2 -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 -LogPath $log -ScriptBlock {
            'one line of output'
            $global:LASTEXITCODE = 5
        } -OnAttempt {
            param($info)
            $seen.Add("attempt $($info.Attempt) starts with $(& $count) line(s) logged")
        }.GetNewClosure() -ShouldRetry {
            param($info)
            $seen.Add("predicate for attempt $($info.Attempt) sees $(& $count) line(s) logged")
            $true
        }.GetNewClosure() -OnRetry {
            param($info)
            $seen.Add("callback for attempt $($info.Attempt) sees $(& $count) line(s) logged")
        }.GetNewClosure()
        Assert-StringEqual (@(
                'attempt 1 starts with 0 line(s) logged'
                'predicate for attempt 1 sees 2 line(s) logged'
                'callback for attempt 1 sees 2 line(s) logged'
                'attempt 2 starts with 2 line(s) logged') -join '|') ($seen -join '|')
        Assert-Equal 4 @(Get-Content -LiteralPath $log).Count
    }

    It 'logs the exception message, and nothing the attempt printed before it, when the attempt throws' {
        $result = Invoke-WithYurunaRetry -Label 'throwing tool' -MaxAttempts 1 -LogPath $script:Log -ScriptBlock {
            'printed before the throw'
            throw "first line of the message`nsecond line of the message"
        }
        Assert-False $result.Success
        Assert-Equal 1 $result.LastExit
        Confirm-LogContent $script:Log @(
            (Get-AttemptHeader -Label 'throwing tool' -Attempt 1 -MaxAttempts 1 -ExitCode 1)
            "[exception] first line of the message`nsecond line of the message")
    }

    It 'leaves what the log already holds in place' {
        $earlier = 'earlier section' + [Environment]::NewLine
        [System.IO.File]::WriteAllText($script:Log, $earlier, [System.Text.UTF8Encoding]::new($false))
        $null = Invoke-WithYurunaRetry -Label 'fixture tool' -MaxAttempts 1 -LogPath $script:Log -ScriptBlock {
            'appended line'
            $global:LASTEXITCODE = 0
        }
        Confirm-LogContent $script:Log @(
            'earlier section'
            (Get-AttemptHeader -Label 'fixture tool' -Attempt 1 -MaxAttempts 1 -ExitCode 0)
            'appended line')
    }

    It 'returns the captured objects themselves, logged or not' -ForEach @(
        @{ Logged = $true }
        @{ Logged = $false }
    ) {
        $arguments = @{
            Label       = 'fixture tool'
            MaxAttempts = 1
            ScriptBlock = { 'text'; Write-Error 'problem' -ErrorAction Continue; 42; $global:LASTEXITCODE = 0 }
        }
        if ($Logged) { $arguments['LogPath'] = $script:Log }
        $result = Invoke-WithYurunaRetry @arguments
        Assert-Equal 3 @($result.LastOutput).Count
        Assert-True ($result.LastOutput[0] -is [string])
        Assert-True ($result.LastOutput[1] -is [System.Management.Automation.ErrorRecord]) 'logging must not turn the returned error record into text'
        Assert-True ($result.LastOutput[2] -is [int])
        Assert-Equal $Logged (Test-Path -LiteralPath $script:Log)
    }

    It 'still returns the result of the attempt when the log cannot be written' {
        $missing = Join-Path $TestDrive ('absent-' + [guid]::NewGuid().ToString('N'))
        $result = Invoke-WithYurunaRetry -Label 'fixture tool' -MaxAttempts 1 -LogPath (Join-Path $missing 'tool.stderr.log') -ScriptBlock {
            'first line'; 'second line'
            $global:LASTEXITCODE = 0
        } 2>$null
        Assert-True $result.Success
        Assert-Equal 1 $result.Attempts
        Assert-Equal 2 @($result.LastOutput).Count
        Assert-False (Test-Path -LiteralPath $missing) 'a failed log write must not create the folder it could not find'
    }
}

Describe 'the retry diagnostic log is appended once per attempt' {
    BeforeEach {
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
        Mock -ModuleName 'Yuruna.Retry' Get-Date { [datetime]::new(2026, 9, 27, 12, 34, 56, [DateTimeKind]::Utc) }
    }

    Context 'counting the appends' {
        BeforeEach {
            Mock -ModuleName 'Yuruna.Retry' Add-Content { }
            $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.stderr.log')
        }

        It 'appends once for an attempt that printed <Count> line(s)' -ForEach @(
            @{ Count = 0 }
            @{ Count = 1 }
            @{ Count = 250 }
        ) {
            $lines = @(for ($index = 1; $index -le $Count; $index++) { "line $index" })
            $null = Invoke-WithYurunaRetry -Label 'chatty tool' -MaxAttempts 1 -LogPath $script:Log -ScriptBlock {
                $lines
                $global:LASTEXITCODE = 0
            }.GetNewClosure()
            Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 1 -Exactly
            $expectedHeader = Get-AttemptHeader -Label 'chatty tool' -Attempt 1 -MaxAttempts 1 -ExitCode 0
            Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq $script:Log -and @($Value).Count -eq ($Count + 1) -and @($Value)[0] -ceq $expectedHeader
            }
        }

        It 'appends once per attempt across a retried run' {
            $script:calls = 0
            $null = Invoke-WithYurunaRetry -Label 'flaky tool' -MaxAttempts 3 -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 -LogPath $script:Log -ScriptBlock {
                $script:calls++
                'line one'; 'line two'; 'line three'
                $global:LASTEXITCODE = 9
            }
            Assert-Equal 3 $script:calls
            Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 3 -Exactly
        }

        It 'appends the header and the exception message together when the attempt throws' {
            $null = Invoke-WithYurunaRetry -Label 'throwing tool' -MaxAttempts 1 -LogPath $script:Log -ScriptBlock { throw 'boom' }
            Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 1 -Exactly -ParameterFilter {
                @($Value).Count -eq 2 -and @($Value)[1] -ceq '[exception] boom'
            }
        }

        It 'appends nothing when no log was asked for' {
            $null = Invoke-WithYurunaRetry -Label 'quiet tool' -MaxAttempts 1 -ScriptBlock { 'line'; $global:LASTEXITCODE = 0 }
            Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 0 -Exactly
        }
    }

    It 'reports a log that cannot be written once per attempt, not once per line' {
        $missing = Join-Path (Join-Path $TestDrive ('absent-' + [guid]::NewGuid().ToString('N'))) 'tool.stderr.log'
        $lines = @(for ($index = 1; $index -le 40; $index++) { "line $index" })
        $streams = @(Invoke-WithYurunaRetry -Label 'chatty tool' -MaxAttempts 1 -LogPath $missing -ErrorAction Continue -ScriptBlock {
                $lines
                $global:LASTEXITCODE = 0
            }.GetNewClosure() 2>&1)
        $records = @($streams | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $results = @($streams | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        Assert-Equal 1 $records.Count 'forty lines that cannot be logged are one failure to report, not forty-one'
        Assert-Equal 1 $results.Count
        Assert-True $results[0].Success
    }
}

Describe 'Write-YurunaToolLogSection writes one section in one append' {
    BeforeEach {
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.stderr.log')
    }

    It 'is exported by the retry module' {
        $command = Get-Command -Name Write-YurunaToolLogSection -ErrorAction SilentlyContinue
        Assert-NotNull $command 'the section writer does not resolve after importing Yuruna.Retry'
        Assert-StringEqual 'Yuruna.Retry' $command.ModuleName
    }

    It 'writes the header and then one line per element' {
        Write-YurunaToolLogSection -LogFile $script:Log -Header '== tool (exit=0) ==' -Line @('one', 'two')
        Write-YurunaToolLogSection -LogFile $script:Log -Header '== tool again (exit=3) ==' -Line 'scalar'
        Confirm-LogContent $script:Log @('== tool (exit=0) ==', 'one', 'two', '== tool again (exit=3) ==', 'scalar')
    }

    It 'writes only the header when the lines are <Name>' -ForEach @(
        @{ Name = 'left out'; Extra = @{} }
        @{ Name = 'null'; Extra = @{ Line = $null } }
        @{ Name = 'an empty array'; Extra = @{ Line = @() } }
    ) {
        $extra = $Extra
        Write-YurunaToolLogSection -LogFile $script:Log -Header '== tool (exit=0) ==' @extra
        Confirm-LogContent $script:Log @('== tool (exit=0) ==')
    }

    It 'writes a null or empty element as an empty line instead of dropping it' {
        Write-YurunaToolLogSection -LogFile $script:Log -Header '== tool (exit=0) ==' -Line @('before', $null, '', 'after')
        Confirm-LogContent $script:Log @('== tool (exit=0) ==', 'before', '', '', 'after')
    }

    It 'writes an empty header as an empty line' {
        Write-YurunaToolLogSection -LogFile $script:Log -Header '' -Line @('body')
        Confirm-LogContent $script:Log @('', 'body')
    }

    It 'renders every element as a string cast does, whatever the culture' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('from the error stream'), 'Fixture', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $prior = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            Write-YurunaToolLogSection -LogFile $script:Log -Header '== tool (exit=0) ==' -Line @(1.5, $record, 42, "two`nlines")
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $prior }
        Confirm-LogContent $script:Log @('== tool (exit=0) ==', '1.5', 'from the error stream', '42', "two`nlines")
    }

    It 'reaches the file through exactly one append' {
        Mock -ModuleName 'Yuruna.Retry' Add-Content { }
        Write-YurunaToolLogSection -LogFile $script:Log -Header '== tool (exit=0) ==' -Line @(for ($index = 1; $index -le 500; $index++) { "line $index" })
        Should -Invoke Add-Content -ModuleName 'Yuruna.Retry' -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq $script:Log -and @($Value).Count -eq 501
        }
    }

    It 'puts nothing on the output stream' {
        $output = @(Write-YurunaToolLogSection -LogFile $script:Log -Header '== tool (exit=0) ==' -Line @('one'))
        Assert-Equal 0 $output.Count 'a caller that collects its own output would get the log section mixed into it'
    }

    It 'reports a log that cannot be written as one error record and creates nothing' {
        $missing = Join-Path $TestDrive ('absent-' + [guid]::NewGuid().ToString('N'))
        $streams = @(Write-YurunaToolLogSection -LogFile (Join-Path $missing 'tool.stderr.log') -Header '== tool (exit=0) ==' -Line @('one', 'two', 'three') -ErrorAction Continue 2>&1)
        Assert-Equal 1 @($streams | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count
        Assert-False (Test-Path -LiteralPath $missing)
    }

    It 'throws when the caller asked for errors to stop' {
        $missing = Join-Path $TestDrive ('absent-' + [guid]::NewGuid().ToString('N'))
        $errorId = ''
        try { Write-YurunaToolLogSection -LogFile (Join-Path $missing 'tool.stderr.log') -Header '== tool (exit=0) ==' -Line @('one') -ErrorAction Stop }
        catch { $errorId = [string]$_.FullyQualifiedErrorId }
        # The error has to be the append's own, so a throw for any other reason
        # -- the command not resolving, a parameter not binding -- fails here.
        Assert-Match 'AddContentCommand$' $errorId 'the caller must be stopped by the append itself'
    }

    Context 'called from another module, as the publishers call it' {
        BeforeAll {
            # A module of its own, so the preference the caller sets lives in a
            # scope the retry module cannot see by itself.
            $script:Caller = New-Module -Name 'ToolLogCallerFixture' -ScriptBlock {
                function Invoke-FixtureAppend {
                    <#
                    .SYNOPSIS
                        Appends one section under the given error preference and
                        then reports that the next statement was reached.
                    #>
                    param([string]$Path, [string]$Preference)
                    $ErrorActionPreference = $Preference
                    Write-YurunaToolLogSection -LogFile $Path -Header '== tool (exit=0) ==' -Line @('one', 'two')
                    'the caller went on'
                }
                Export-ModuleMember -Function Invoke-FixtureAppend
            }
            Import-Module $script:Caller -Force -DisableNameChecking
        }

        AfterAll {
            Remove-Module -Name 'ToolLogCallerFixture' -Force -ErrorAction SilentlyContinue
        }

        It 'stops the caller on a log that cannot be written when the caller''s own preference is Stop' {
            $missing = Join-Path $TestDrive ('absent-' + [guid]::NewGuid().ToString('N'))
            $errorId = ''
            try { $null = Invoke-FixtureAppend -Path (Join-Path $missing 'tool.stderr.log') -Preference 'Stop' }
            catch { $errorId = [string]$_.FullyQualifiedErrorId }
            Assert-Match 'AddContentCommand$' $errorId 'the caller must be stopped by the append itself'
        }

        It 'lets the caller go on, with <Records> error record(s), when the caller''s own preference is <Preference>' -ForEach @(
            @{ Preference = 'Continue'; Records = 1 }
            @{ Preference = 'SilentlyContinue'; Records = 0 }
        ) {
            $missing = Join-Path $TestDrive ('absent-' + [guid]::NewGuid().ToString('N'))
            $streams = @(Invoke-FixtureAppend -Path (Join-Path $missing 'tool.stderr.log') -Preference $Preference 2>&1)
            Assert-Equal $Records @($streams | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count
            Assert-StringEqual 'the caller went on' (@($streams | Where-Object { $_ -is [string] }) -join '|')
        }

        It 'writes the section for that caller' {
            $null = Invoke-FixtureAppend -Path $script:Log -Preference 'Stop'
            Confirm-LogContent $script:Log @('== tool (exit=0) ==', 'one', 'two')
        }
    }
}
