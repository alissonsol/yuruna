<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42b8405a-5067-4b26-aad4-fe6a74c84f58
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install unattended host-update pester
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
    The installers' unattended mode, which the install phase of a host
    update runs: no prompt, no git command, nothing stopped, and a result
    record on every path.
.DESCRIPTION
    install/ubuntu.kvm.sh is run as the real file, with standard input
    closed and stand-ins for sudo and git first on PATH, in a scratch home,
    state folder and checkout; every case ends at a refusal before anything
    is installed, so the run changes nothing on the host. The record each
    refusal writes is read back. install/windows.hyper-v.ps1 is run the same
    way on its paths that end before the Windows-only preflight. What a
    refusal cannot reach (the checkout regions, the prompts, the windows,
    the holds) is held to its gate by reading the source: every git command
    of a checkout region, every prompt, window and hold lies on a path the
    unattended mode never takes. The Windows installer's record functions are
    loaded from its syntax tree and run on every platform, so the reason
    tokens, the step and the outcome they write are read back as well.

    install/macos.utm.sh is run as the real file the same way, behind a uname
    that answers Darwin on arm64, only on a host without Homebrew or UTM at
    the fixed paths it looks for them, so a run that got past its refusal
    still stops there. The end of its preflight and the regions a refusal
    cannot reach (the process stops and the UTM quit, the cask, the brew
    update, the keg cleanup, the pins, the baseline question) run as slices of
    the real file under stand-ins, and a scan of the file's code, with its strings, comments and
    heredocs blanked, holds every git command, bare sudo, prompt, signal and
    attended-only step to a branch the unattended mode never takes.
#>

BeforeDiscovery {
# The macOS installer looks for Homebrew and UTM at fixed paths no stand-in can
# move, and once its preflight passes it puts the real Homebrew ahead of every
# stand-in on PATH. Where either is present, a broken refusal would let a real-
# file run go on into the operator's Homebrew, so those runs happen only on a
# host that has neither.
$script:MacRealRunUnsafe = $IsWindows -or @(
    '/opt/homebrew/bin/brew', '/usr/local/bin/brew', '/Applications/UTM.app' |
        Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
}

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$script:KvmInstaller = Join-Path $repoRoot 'install/ubuntu.kvm.sh'
$script:WindowsInstaller = Join-Path $repoRoot 'install/windows.hyper-v.ps1'
$script:KvmLines = [IO.File]::ReadAllLines($script:KvmInstaller)
$script:ScratchBase = New-YurunaTestTempDir -Prefix 'install-unattended'
$script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$script:RequestId = '0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90'

# Installer output goes into assertion messages, which end up in the NUnit XML:
# its color escapes and control characters would make the report unwritable.
function ConvertTo-PlainText {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    $noAnsi = [regex]::Replace($Text, "\x1b\[[0-9;?]*[ -/]*[@-~]", '')
    return [regex]::Replace($noAnsi, "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", '')
}

function New-KvmSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a scratch tree that the suite removes.')]
    param([int]$SudoExit = 0, [switch]$Provisioned)
    $root = Join-Path $script:ScratchBase ('k-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
    $bin = Join-Path $root 'bin'
    $rec = Join-Path $root 'rec'
    $checkout = Join-Path $root 'checkout'
    $runtime = Join-Path $root 'runtime'
    foreach ($dir in @($bin, $rec, (Join-Path $root 'home'), (Join-Path $root 'state'), $checkout, $runtime)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    if ($Provisioned) {
        $null = New-Item -ItemType Directory -Path (Join-Path $checkout '.git'), (Join-Path $checkout 'test') -Force
        [IO.File]::WriteAllText((Join-Path $checkout 'test/Start-TestRunner.ps1'), '')
    }
    $stubs = @{
        sudo = "#!/bin/sh`nprintf '%s\n' `"`$*`" >> '$rec/sudo'`nexit $SudoExit`n"
        git  = "#!/bin/sh`nprintf '%s\n' `"`$*`" >> '$rec/git'`nexit 1`n"
    }
    foreach ($name in $stubs.Keys) {
        $path = Join-Path $bin $name
        [IO.File]::WriteAllText($path, $stubs[$name])
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    }
    [pscustomobject]@{ Root = $root; Bin = $bin; Rec = $rec; Checkout = $checkout; Runtime = $runtime; Home = (Join-Path $root 'home'); State = (Join-Path $root 'state') }
}

function Invoke-KvmInstaller {
    param([Parameter(Mandatory)]$Sandbox, [string[]]$Argument = @('--unattended', '--request-id', $script:RequestId, '--attempt', '3'))
    $environment = @{
        PATH = "$($Sandbox.Bin):$env:PATH"; HOME = $Sandbox.Home; XDG_STATE_HOME = $Sandbox.State
        YURUNA_DIR = $Sandbox.Checkout; YURUNA_RUNTIME_DIR = $Sandbox.Runtime; NO_COLOR = '1'
    }
    $r = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList (@($script:KvmInstaller) + $Argument) -Environment $environment -TimeoutSeconds 120
    $recordPath = Join-Path $Sandbox.State 'yuruna/install-result.json'
    [pscustomobject]@{
        ExitCode = $r.ExitCode; TimedOut = $r.TimedOut; Output = (ConvertTo-PlainText ($r.StdOut + "`n" + $r.StdErr))
        Record = if (Test-Path -LiteralPath $recordPath) { Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
        Git = @(if (Test-Path -LiteralPath (Join-Path $Sandbox.Rec 'git')) { Get-Content -LiteralPath (Join-Path $Sandbox.Rec 'git') })
        Sudo = @(if (Test-Path -LiteralPath (Join-Path $Sandbox.Rec 'sudo')) { Get-Content -LiteralPath (Join-Path $Sandbox.Rec 'sudo') })
    }
}

# The [start, end) line ranges of the shell functions, by name.
function Get-ShellFunctionSpan {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $spans = @{}
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^([a-z_][a-z0-9_]*)\(\) \{') {
            $name = $Matches[1]
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) { if ($Lines[$j] -eq '}') { break } }
            $spans[$name] = @($i, $j + 1)
        }
    }
    $spans
}

function Get-LineIndex {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines, [Parameter(Mandatory)][string]$Text, [int]$From = 0)
    for ($i = $From; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -eq $Text) { return $i } }
    throw "line not found: $Text"
}

# Whether a node of the Windows installer lies on a path the unattended mode
# never takes: the else branch of an if on $Unattended, a clause whose
# condition requires -not $Unattended, the relaunch of a non-administrator
# (refused unattended before it), or a function whose every call site does.
function Test-AttendedOnly {
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)]$Ast, [int]$Depth = 0)
    if ($Depth -gt 8) { return $false }
    $child = $Node
    for ($p = $Node.Parent; $p; $p = $p.Parent) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            $inElse = $p.ElseClause -and $child -eq $p.ElseClause
            if ($inElse -and @($p.Clauses | Where-Object { $_.Item1.Extent.Text -eq '$Unattended' }).Count -gt 0) { return $true }
            foreach ($clause in $p.Clauses) {
                if ($child -eq $clause.Item2 -and $clause.Item1.Extent.Text -match '-not \$Unattended\b|^-not \$isAdmin$') { return $true }
            }
        }
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $name = $p.Name
            $calls = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }.GetNewClosure(), $true))
            if ($calls.Count -eq 0) { return $false }
            foreach ($call in $calls) { if (-not (Test-AttendedOnly -Node $call -Ast $Ast -Depth ($Depth + 1))) { return $false } }
            return $true
        }
        $child = $p
    }
    return $false
}

# The code of a bash file, one string per source line: comments, the text of
# quoted strings and heredoc bodies become spaces, while a command
# substitution inside double quotes stays code. A scan of what the file runs
# then reads neither a message that names a command nor a comment about one.
function ConvertTo-ShellCodeLine {
    param([Parameter(Mandatory)][string]$Text)
    $out = [Text.StringBuilder]::new($Text.Length)
    $stack = [System.Collections.Generic.List[string]]::new(); $stack.Add('code')
    $depth = [System.Collections.Generic.List[int]]::new(); $depth.Add(0)
    $pending = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        $top = $stack[$stack.Count - 1]
        if ($c -eq "`n") {
            if ($top -eq 'comment') { $stack.RemoveAt($stack.Count - 1); $depth.RemoveAt($depth.Count - 1) }
            $null = $out.Append("`n"); $i++
            # A heredoc body starts on the line after its operator and ends at
            # the line that holds only its delimiter.
            foreach ($doc in $pending) {
                while ($i -lt $Text.Length) {
                    $lineEnd = $Text.IndexOf("`n", $i); if ($lineEnd -lt 0) { $lineEnd = $Text.Length }
                    $line = $Text.Substring($i, $lineEnd - $i)
                    $null = $out.Append(' ' * $line.Length); $i = $lineEnd
                    if ($i -lt $Text.Length) { $null = $out.Append("`n"); $i++ }
                    $candidate = if ($doc.Strip) { $line.TrimStart("`t") } else { $line }
                    if ($candidate -ceq $doc.Delimiter) { break }
                }
            }
            $pending.Clear()
            continue
        }
        switch ($top) {
            'comment' { $null = $out.Append(' '); $i++; continue }
            'squote' { if ($c -eq "'") { $stack.RemoveAt($stack.Count - 1); $depth.RemoveAt($depth.Count - 1) }; $null = $out.Append(' '); $i++; continue }
            'ansi' {
                if ($c -eq '\' -and $next -ne "`n") { $null = $out.Append('  '); $i += 2; continue }
                if ($c -eq "'") { $stack.RemoveAt($stack.Count - 1); $depth.RemoveAt($depth.Count - 1) }
                $null = $out.Append(' '); $i++; continue
            }
            'dquote' {
                if ($c -eq '\' -and $next -ne "`n") { $null = $out.Append('  '); $i += 2; continue }
                if ($c -eq '"') { $stack.RemoveAt($stack.Count - 1); $depth.RemoveAt($depth.Count - 1); $null = $out.Append(' '); $i++; continue }
                if ($c -eq '$' -and $next -eq '(') { $stack.Add('subst'); $depth.Add(0); $null = $out.Append('$('); $i += 2; continue }
                $null = $out.Append(' '); $i++; continue
            }
            default {
                if ($c -eq '\' -and $next -ne "`n") { $null = $out.Append($c).Append($next); $i += 2; continue }
                $previous = if ($i -gt 0) { $Text[$i - 1] } else { "`n" }
                if ($c -eq '#' -and ($previous -match '[\s;&|(]')) { $stack.Add('comment'); $depth.Add(0); $null = $out.Append(' '); $i++; continue }
                if ($c -eq "'") { $stack.Add('squote'); $depth.Add(0); $null = $out.Append(' '); $i++; continue }
                if ($c -eq '$' -and $next -eq "'") { $stack.Add('ansi'); $depth.Add(0); $null = $out.Append('  '); $i += 2; continue }
                if ($c -eq '"') { $stack.Add('dquote'); $depth.Add(0); $null = $out.Append(' '); $i++; continue }
                if ($c -eq '$' -and $next -eq '(') { $stack.Add('subst'); $depth.Add(0); $null = $out.Append('$('); $i += 2; continue }
                if ($top -eq 'subst' -and $c -eq '(') { $depth[$depth.Count - 1]++ }
                if ($top -eq 'subst' -and $c -eq ')') {
                    if ($depth[$depth.Count - 1] -eq 0) { $stack.RemoveAt($stack.Count - 1); $depth.RemoveAt($depth.Count - 1) } else { $depth[$depth.Count - 1]-- }
                }
                if ($c -eq '<' -and $next -eq '<' -and ($i + 2 -ge $Text.Length -or $Text[$i + 2] -ne '<') -and ($i -eq 0 -or $Text[$i - 1] -ne '<')) {
                    $m = [regex]::Match($Text.Substring($i), '^<<(-?)\s*([''"]?)([A-Za-z_][A-Za-z0-9_]*)\2')
                    if ($m.Success) { $pending.Add([pscustomobject]@{ Delimiter = $m.Groups[3].Value; Strip = ($m.Groups[1].Value -eq '-') }) }
                }
                $null = $out.Append($c); $i++
            }
        }
    }
    , ($out.ToString() -split "`n")
}

# For every line of a bash file, the if blocks it lies in, innermost last:
# each with the conditions of its if and elif clauses and the clause the line
# is in (if, elif or else). Keywords are found in the code view; a condition is
# read from the source, where its quoted words still stand (the code view keeps
# every character in place).
function Get-ShellBranchSnapshot {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Code, [Parameter(Mandatory)][string]$Source)
    $joined = $Code -join "`n"
    if ($Source.Length -ne $joined.Length) { throw 'the code view must keep every character of the source in place' }
    $lineStart = [System.Collections.Generic.List[int]]::new()
    $offset = 0
    foreach ($line in $Code) { $lineStart.Add($offset); $offset += $line.Length + 1 }
    $tokens = [regex]::Matches($joined, '(?<![\w$.-])(if|elif|else|fi|then)(?![\w-])')
    $snapshot = [object[]]::new($Code.Count)
    $stack = [System.Collections.Generic.List[object]]::new()
    $t = 0
    $openCondition = $null
    for ($line = 0; $line -lt $Code.Count; $line++) {
        $end = $lineStart[$line] + $Code[$line].Length
        while ($t -lt $tokens.Count -and $tokens[$t].Index -le $end) {
            $token = $tokens[$t]
            switch ($token.Value) {
                'if' { $stack.Add([pscustomobject]@{ Conditions = [System.Collections.Generic.List[string]]::new(); Clause = 'if' }); $openCondition = $token.Index + 2 }
                'elif' { if ($stack.Count) { $stack[$stack.Count - 1].Clause = 'elif' }; $openCondition = $token.Index + 4 }
                'then' {
                    if ($null -ne $openCondition -and $stack.Count) {
                        $stack[$stack.Count - 1].Conditions.Add($Source.Substring($openCondition, $token.Index - $openCondition).Trim().TrimEnd(';').Trim())
                    }
                    $openCondition = $null
                }
                'else' { if ($stack.Count) { $stack[$stack.Count - 1].Clause = 'else' } }
                'fi' { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) } }
            }
            $t++
        }
        $snapshot[$line] = @($stack | ForEach-Object { [pscustomobject]@{ Conditions = @($_.Conditions); Clause = $_.Clause } })
    }
    , $snapshot
}

# The [start, end) line ranges of the shell functions in code lines, by name.
function Get-ShellCodeFunctionSpan {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Code)
    $spans = @{}
    for ($i = 0; $i -lt $Code.Count; $i++) {
        if ($Code[$i] -match '^([a-z_][a-z0-9_]*)\(\) \{') {
            $name = $Matches[1]
            $j = $i
            if ($Code[$i] -notmatch '\}\s*$') { for ($j = $i + 1; $j -lt $Code.Count; $j++) { if ($Code[$j] -match '^\}') { break } } }
            $spans[$name] = @($i, $j + 1)
        }
    }
    $spans
}

# Whether a line of the macOS installer lies on a path the unattended mode
# never takes: a clause after an `if (( YURUNA_UNATTENDED ))`, the then clause
# of a condition that requires an attended run, a function line after the
# function's own unattended return, or a function whose every call site is
# such a line.
function Test-ShellAttendedOnly {
    param([Parameter(Mandatory)][int]$Line, [Parameter(Mandatory)]$Scan, [int]$Depth = 0)
    if ($Depth -gt 8) { return $false }
    $unattended = '^\(\( (\$\{)?YURUNA_UNATTENDED(:-0\})? \)\)$'
    $attended = '^\(\( ! (\$\{)?YURUNA_UNATTENDED(:-0\})? \)\)( &&|$)|&& "\$YURUNA_UNATTENDED" -eq 0 &&'
    foreach ($frame in @($Scan.Snapshot[$Line])) {
        $first = [string]@($frame.Conditions)[0]
        if ($frame.Clause -in @('elif', 'else') -and $first -match $unattended) { return $true }
        if ($frame.Clause -eq 'if' -and $first -match $attended) { return $true }
    }
    foreach ($name in $Scan.Spans.Keys) {
        $span = $Scan.Spans[$name]
        if ($Line -le $span[0] -or $Line -ge $span[1]) { continue }
        # An unattended branch at the top of the function body that returns.
        # The return sits directly in the branch, at its inner indentation: one
        # inside a nested condition may not run, and the path falls through.
        # The branch ends at its else or elif, whose return only the attended
        # path reaches.
        for ($j = $span[0] + 1; $j -lt $Line; $j++) {
            if ($Scan.Code[$j] -notmatch '^  if \(\( \$\{YURUNA_UNATTENDED:-0\} \)\); then\s*$') { continue }
            for ($k = $j + 1; $k -lt $Line; $k++) {
                if ($Scan.Code[$k] -match '^  ((else|elif)\b|fi\s*$)') {
                    if (@($Scan.Code[($j + 1)..($k - 1)] | Where-Object { $_ -match '^    return\b' }).Count -gt 0) { return $true }
                    break
                }
            }
        }
        $pattern = "(^|[\s;&|(!{])$([regex]::Escape($name))(\s|;|\)|$)"
        $calls = @(for ($i = 0; $i -lt $Scan.Code.Count; $i++) { if ($i -ne $span[0] -and $Scan.Code[$i] -match $pattern) { $i } })
        if ($calls.Count -eq 0) { return $false }
        foreach ($call in $calls) { if (-not (Test-ShellAttendedOnly -Line $call -Scan $Scan -Depth ($Depth + 1))) { return $false } }
        return $true
    }
    return $false
}

function Get-ShellScan {
    param([Parameter(Mandatory)][string]$Text)
    $code = ConvertTo-ShellCodeLine -Text $Text
    [pscustomobject]@{ Code = $code; Snapshot = (Get-ShellBranchSnapshot -Code $code -Source $Text); Spans = (Get-ShellCodeFunctionSpan -Code $code) }
}
}

AfterAll {
    foreach ($process in $script:Spawned) { try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $null = $_ } }
    Remove-YurunaTestTempDir $script:ScratchBase
}

Describe 'install/ubuntu.kvm.sh --unattended' -Skip:(-not $IsLinux) {
    It 'carries the marker the install step reads before it starts the file' {
        Assert-True ($script:KvmLines -contains 'YURUNA_UNATTENDED_PROTOCOL_VERSION=1') 'the marker names the unattended contract'
    }

    It 'refuses not_elevated when sudo would ask, and writes its record before any change' {
        $sandbox = New-KvmSandbox -SudoExit 1 -Provisioned
        $run = Invoke-KvmInstaller -Sandbox $sandbox
        Assert-False $run.TimedOut 'a refusal never waits for input'
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-NotNull $run.Record 'the record is written on a refusal before the first change'
        Assert-Equal 'failed' $run.Record['outcome']
        Assert-Equal 'not_elevated' $run.Record['reason']
        Assert-Equal $script:RequestId $run.Record['requestId']
        Assert-Equal 3 ([int]$run.Record['attempt'])
        Assert-True ([bool]$run.Record['unattended']) ''
        Assert-False ([bool]$run.Record['restartRequired']) 'the KVM installer never asks for a restart'
        Assert-Equal '-n true' ($run.Sudo -join ',') 'elevation is tested with sudo -n true and nothing else'
        Assert-Equal 0 $run.Git.Count 'no git command runs'
    }

    It 'refuses not_provisioned for a first install' {
        $sandbox = New-KvmSandbox
        $run = Invoke-KvmInstaller -Sandbox $sandbox
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Equal 'not_provisioned' $run.Record['reason']
        Assert-Equal 0 $run.Git.Count ''
    }

    # The installer treats aarch64 as KVM-capable whatever /proc/cpuinfo says;
    # -and keeps the discovery-time read of /proc/cpuinfo off other platforms.
    It 'refuses runner_present for a live runner and stops nothing' -Skip:(-not ($IsLinux -and ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64' -or (Select-String -LiteralPath '/proc/cpuinfo' -Pattern '(vmx|svm)' -Quiet)))) {
        $sandbox = New-KvmSandbox -Provisioned
        # A pgrep that finds nothing: a runner elsewhere on this host matches
        # the host-wide fallback, so only the pid file can satisfy this case.
        $pgrep = Join-Path $sandbox.Bin 'pgrep'
        [IO.File]::WriteAllText($pgrep, "#!/bin/sh`nexit 1`n")
        [IO.File]::SetUnixFileMode($pgrep, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        # A process whose arguments name the runner script: the pid file's
        # owner, as a runner's would be.
        $info = [System.Diagnostics.ProcessStartInfo]::new('bash')
        foreach ($item in @('-c', 'exec -a "pwsh-stand-in Start-TestRunner.ps1" sleep 120')) { $info.ArgumentList.Add($item) }
        $runner = [System.Diagnostics.Process]::Start($info)
        $script:Spawned.Add($runner)
        Start-Sleep -Milliseconds 300
        [IO.File]::WriteAllText((Join-Path $sandbox.Runtime 'runner.pid'), "$($runner.Id)")
        $run = Invoke-KvmInstaller -Sandbox $sandbox
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Equal 'runner_present' $run.Record['reason']
        Assert-False $runner.HasExited 'the runner is left running: the controller stops what must stop'
        Assert-Equal 0 $run.Git.Count ''
        Assert-False (Test-Path -LiteralPath (Join-Path $sandbox.Home '.yuruna/installer-state')) 'no recovery capsule is captured'
    }

    It 'keeps every git command of the checkout regions on the attended path' {
        $lines = $script:KvmLines
        $spans = Get-ShellFunctionSpan -Lines $lines
        $attended = [System.Collections.Generic.List[object]]::new()
        $start = Get-LineIndex -Lines $lines -Text 'elif [[ -d "$YURUNA_DIR/.git" ]]; then'
        Assert-True ($lines[$start - 2] -eq 'if (( YURUNA_UNATTENDED )); then') 'the clone region takes its unattended branch first'
        $attended.Add(@($start, (Get-LineIndex -Lines $lines -Text '# --- REGION: Renormalize line endings under .gitattributes' -From $start)))
        $renormalize = Get-LineIndex -Lines $lines -Text 'if (( ! YURUNA_UNATTENDED )) && [[ -d "$YURUNA_DIR/.git" ]]; then'
        $attended.Add(@($renormalize, (Get-LineIndex -Lines $lines -Text 'fi' -From $renormalize)))
        $pin = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like 'if *"$YURUNA_UNATTENDED" -eq 0*') { $i } })
        Assert-Equal 1 $pin.Count 'the pin requires an attended run'
        $attended.Add(@($pin[0], (Get-LineIndex -Lines $lines -Text 'restore_installer_state' -From $pin[0])))
        $inside = { param([int]$Line) foreach ($range in $attended) { if ($Line -ge $range[0] -and $Line -lt $range[1]) { return $true } }; $false }
        $gitLine = '(^|[\s;&|(!{])git\s+(-C|clone|fetch|pull|checkout|ls-remote|config|update-index|diff-index|add|rm|reset)\b'
        $gitFunctions = @($spans.Keys | Where-Object { $s = $spans[$_]; @($lines[$s[0]..($s[1] - 1)] | Where-Object { $_ -notmatch '^\s*#' -and $_ -match $gitLine }).Count -gt 0 })
        Assert-True ($gitFunctions.Count -gt 0) 'fixture sanity: the checkout helpers are found'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*#' -or $lines[$i] -notmatch $gitLine) { continue }
            $owner = @($spans.Keys | Where-Object { $i -ge $spans[$_][0] -and $i -lt $spans[$_][1] })
            if ($owner.Count -eq 0) { Assert-True (& $inside $i) "line $($i + 1) runs git outside the attended checkout path: $($lines[$i])" }
        }
        foreach ($name in $gitFunctions) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*#' -or $lines[$i] -notmatch "(^|[\s;&|(`$])$name(\s|$|\))" -or $lines[$i] -match "^$name\(\)") { continue }
                $owner = @($spans.Keys | Where-Object { $i -ge $spans[$_][0] -and $i -lt $spans[$_][1] })
                $fromHelper = @($owner | Where-Object { $_ -in $gitFunctions }).Count -gt 0
                Assert-True ($fromHelper -or (& $inside $i)) "line $($i + 1) calls $name outside the attended checkout path"
            }
        }
    }

    It 'asks nothing: the baseline question, sudo -v and the stops sit behind the unattended branches' {
        $lines = $script:KvmLines
        $text = $lines -join "`n"
        $read = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s+read -r -p ') { $i } })
        Assert-Equal 1 $read.Count 'one question in the file'
        $return = Get-LineIndex -Lines $lines -Text '  if (( ${YURUNA_UNATTENDED:-0} )); then'
        Assert-True ($return -lt $read[0] -and $lines[$return + 2] -eq '    return 0') 'the unattended run returns before the baseline question'
        $sudoV = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^sudo -v ') { $i } })
        Assert-Equal 1 $sudoV.Count ''
        $announce = Get-LineIndex -Lines $lines -Text 'if (( YURUNA_UNATTENDED )); then' -From (Get-LineIndex -Lines $lines -Text '# --- REGION: Elevation announcement')
        $else = Get-LineIndex -Lines $lines -Text 'else' -From $announce
        Assert-True ($else -lt $sudoV[0]) 'sudo -v is on the attended branch'
        Assert-Match -Pattern '(?s)if \(\( YURUNA_UNATTENDED \)\); then\n  log "Leaving the status service running \(unattended\)"\nelse\n  log "Stopping anything[^\n]+\n  capture_installer_state\n  stop_yuruna_processes\nfi' -Actual $text
        $preflight = Get-LineIndex -Lines $lines -Text '# --- REGION: Preflight: an unattended run needs a provisioned host'
        $refusal = Get-LineIndex -Lines $lines -Text '    refuse runner_present "A Yuruna runner is still running; an unattended run stops nothing."' -From $preflight
        Assert-True ($refusal -lt (Get-LineIndex -Lines $lines -Text '# --- REGION: Preflight: system requirements')) 'a live runner is refused by the unattended preflight, before the first change'
        Assert-Match -Pattern '(?s)if \(\( YURUNA_UNATTENDED \)\); then\n  log "Leaving test-\* VMs to the next cycle \(unattended\)"\nelif \[\[ -f "\$REMOVE_TEST_VMS" \]\]; then' -Actual $text
        Assert-True ($lines -contains 'if (( YURUNA_UNATTENDED )); then exec </dev/null; fi') 'standard input is never read'
    }
}

Describe 'install/macos.utm.sh --unattended' {
    BeforeAll {
        $script:MacInstaller = Join-Path $repoRoot 'install/macos.utm.sh'
        $script:MacText = [IO.File]::ReadAllText($script:MacInstaller)
        $script:MacLines = [IO.File]::ReadAllLines($script:MacInstaller)
        $script:MacScan = Get-ShellScan -Text $script:MacText

        # The real file, run under stand-ins: uname answers Darwin on arm64
        # unless a case names another system or machine, and every tool an
        # install would reach records its call and fails, so a run that went
        # past its refusal shows in the records instead of changing anything. The cases that run it skip a host with Homebrew
        # or UTM at the fixed paths the file looks for them, so each run ends
        # at a refusal even when the refusal under test is broken.
        function New-MacSandbox {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds a scratch tree that the suite removes.')]
            param([int]$SudoExit = 0, [int]$XcodeExit = 0, [string]$System = 'Darwin', [string]$Machine = 'arm64', [switch]$Provisioned)
            $root = Join-Path $script:ScratchBase ('m-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $bin = Join-Path $root 'bin'
            $rec = Join-Path $root 'rec'
            $checkout = Join-Path $root 'checkout'
            $runtime = Join-Path $root 'runtime'
            foreach ($dir in @($bin, $rec, (Join-Path $root 'home'), (Join-Path $root 'state'), $checkout, $runtime)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            if ($Provisioned) {
                $null = New-Item -ItemType Directory -Path (Join-Path $checkout '.git'), (Join-Path $checkout 'test') -Force
                [IO.File]::WriteAllText((Join-Path $checkout 'test/Start-TestRunner.ps1'), '')
            }
            $record = { param($Name, $Exit) "#!/bin/sh`nprintf '%s\n' `"`$*`" >> '$rec/$Name'`nexit $Exit`n" }
            $stubs = @{
                uname = "#!/bin/sh`nif [ `"`$1`" = -m ]; then echo $Machine; else echo $System; fi`n"
                sudo = (& $record 'sudo' $SudoExit)
                'xcode-select' = (& $record 'xcode-select' $XcodeExit)
                # A pgrep that finds nothing: a runner elsewhere on this host
                # must not decide a case; the runner case uses its pid file.
                pgrep = "#!/bin/sh`nexit 1`n"
            }
            foreach ($name in @('git', 'brew', 'osascript', 'pkill', 'killall', 'curl', 'open', 'launchctl', 'sw_vers')) { $stubs[$name] = (& $record $name 1) }
            foreach ($name in $stubs.Keys) {
                $path = Join-Path $bin $name
                [IO.File]::WriteAllText($path, $stubs[$name])
                [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
            }
            [pscustomobject]@{ Root = $root; Bin = $bin; Rec = $rec; Checkout = $checkout; Runtime = $runtime; Home = (Join-Path $root 'home'); State = (Join-Path $root 'state') }
        }

        function Invoke-MacInstaller {
            param([Parameter(Mandatory)]$Sandbox, [string[]]$Argument = @('--unattended', '--request-id', $script:RequestId, '--attempt', '3'))
            $environment = @{
                PATH = "$($Sandbox.Bin):$env:PATH"; HOME = $Sandbox.Home; XDG_STATE_HOME = $Sandbox.State
                YURUNA_DIR = $Sandbox.Checkout; YURUNA_RUNTIME_DIR = $Sandbox.Runtime; NO_COLOR = '1'
                YURUNA_REPAIR = ''; YURUNA_REFRESH = ''; YURUNA_INSTALL_LOG = ''; YURUNA_UNATTENDED = ''; BASH_ENV = ''
            }
            $r = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList (@($script:MacInstaller) + $Argument) -Environment $environment -TimeoutSeconds 120
            $recordPath = Join-Path $Sandbox.State 'yuruna/install-result.json'
            $read = { param($Name) @(if (Test-Path -LiteralPath (Join-Path $Sandbox.Rec $Name)) { Get-Content -LiteralPath (Join-Path $Sandbox.Rec $Name) }) }
            $tools = @{}
            foreach ($item in @(Get-ChildItem -LiteralPath $Sandbox.Rec -File)) { $tools[$item.Name] = @(Get-Content -LiteralPath $item.FullName) }
            [pscustomobject]@{
                ExitCode = $r.ExitCode; TimedOut = $r.TimedOut; Output = (ConvertTo-PlainText ($r.StdOut + "`n" + $r.StdErr))
                Record = if (Test-Path -LiteralPath $recordPath) { Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
                Sudo = (& $read 'sudo'); Xcode = (& $read 'xcode-select'); Tools = $tools
            }
        }

        # Calls of tools that change the host or ask a person; a refusal before
        # the first change records none of them.
        function Confirm-NothingChanged {
            param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Sandbox)
            foreach ($name in @('git', 'brew', 'osascript', 'pkill', 'killall', 'curl', 'open', 'launchctl')) {
                Assert-False $Run.Tools.ContainsKey($name) "$name ran before the refusal: $(@($Run.Tools[$name]) -join ' | ')"
            }
            Assert-False (Test-Path -LiteralPath (Join-Path $Sandbox.Home '.yuruna/installer-state')) 'no recovery capsule is captured'
        }

        # Runs a slice of the real file under bash with stand-ins defined
        # first: the outcome writer region, the deferred-issue region and the
        # named functions are lifted, then the body runs and the record is read
        # back.
        function Invoke-MacSlice {
            param([Parameter(Mandatory)][string]$Body, [string[]]$Function = @(), [string]$Stub = '', [switch]$Unattended)
            $root = Join-Path $script:ScratchBase ('s-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force
            $text = $script:MacText
            $deferred = $text.Substring($text.IndexOf('# --- REGION: Deferred issues'), $text.IndexOf('# --- REGION: https://yuruna.link/429fb30b-0003') - $text.IndexOf('# --- REGION: Deferred issues'))
            $writer = Get-YurunaTestShellFunction -Text $text -Name @('yuruna_json_string', 'write_install_result')
            $lifted = if ($Function.Count) { Get-YurunaTestShellFunction -Text $text -Name $Function } else { '' }
            $script = @(
                'set -euo pipefail'
                "log()  { printf 'LOG %s\n' `"`$*`"; }"
                "warn() { printf 'WARN %s\n' `"`$*`" >&2; }"
                "die()  { printf 'DIE %s\n' `"`$*`" >&2; exit 1; }"
                "yuruna_pwsh_version() { :; }"
                $deferred, $writer, $lifted, $Stub
                "YURUNA_UNATTENDED=$(if ($Unattended) { 1 } else { 0 }); YURUNA_INSTALL_LOG=''; XDG_STATE_HOME='$root/state'; _yuruna_step=''"
                $Body
                'write_install_result 0 macos.utm'
            ) -join "`n"
            $run = Invoke-YurunaTestShell -Body $script -Environment @{ PATH = '/usr/bin:/bin' }
            $recordPath = Join-Path $root 'state/yuruna/install-result.json'
            [pscustomobject]@{
                Output = $run.Output; ExitCode = $run.ExitCode
                Record = if (Test-Path -LiteralPath $recordPath) { Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
            }
        }

        # The top-level text between two lines of the file, both exact.
        function Get-MacSpan {
            param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
            $start = $script:MacText.IndexOf($From, [StringComparison]::Ordinal)
            Assert-True ($start -ge 0) "fixture sanity: '$From' is in the file"
            $end = $script:MacText.IndexOf($To, $start, [StringComparison]::Ordinal)
            Assert-True ($end -gt $start) "fixture sanity: '$To' follows '$From'"
            $script:MacText.Substring($start, $end - $start)
        }
    }

    It 'carries the marker the install step reads before it starts the file' {
        Assert-True ($script:MacLines -contains 'YURUNA_UNATTENDED_PROTOCOL_VERSION=1') 'the marker names the unattended contract'
        Assert-True ($script:MacLines -contains 'if (( YURUNA_UNATTENDED )); then exec </dev/null; fi') 'standard input is never read'
    }

    It 'installs its exit trap before the first refusal, so an attended refusal leaves a record too' -Skip:$script:MacRealRunUnsafe {
        $sandbox = New-MacSandbox -System 'Linux'
        $run = Invoke-MacInstaller -Sandbox $sandbox -Argument @()
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-NotNull $run.Record 'the record is written by the trap'
        Assert-Equal 'failed' $run.Record['outcome']
        Assert-False ([bool]$run.Record['unattended']) 'no switch, no unattended run'
        Assert-Null $run.Record['reason'] 'an attended run names no reason token'
        $trap = [Array]::IndexOf($script:MacLines, 'trap yuruna_install_cleanup EXIT')
        Assert-True ($trap -gt 0 -and $trap -lt [Array]::IndexOf($script:MacLines, '# --- REGION: Preflight: macOS only')) 'the trap precedes every preflight'
    }

    It 'refuses not_elevated when sudo would ask, and writes its record before any change' -Skip:$script:MacRealRunUnsafe {
        $sandbox = New-MacSandbox -SudoExit 1 -Provisioned
        $run = Invoke-MacInstaller -Sandbox $sandbox
        Assert-False $run.TimedOut 'a refusal never waits for input'
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-NotNull $run.Record 'the record is written on a refusal before the first change'
        Assert-Equal 'failed' $run.Record['outcome']
        Assert-Equal 'not_elevated' $run.Record['reason']
        Assert-Equal 'macos.utm' $run.Record['installer']
        Assert-Equal $script:RequestId $run.Record['requestId']
        Assert-Equal 3 ([int]$run.Record['attempt'])
        Assert-True ([bool]$run.Record['unattended']) ''
        Assert-False ([bool]$run.Record['restartRequired']) 'the macOS installer never asks for a restart'
        Assert-Equal 0 @($run.Record['remarks']).Count 'a refusal carries no remark'
        Assert-Equal '-n true' ($run.Sudo -join ',') 'elevation is tested with sudo -n true and nothing else'
        Confirm-NothingChanged -Run $run -Sandbox $sandbox
    }

    It 'records installer_failed for a failure without a token: the Apple Silicon gate' -Skip:$script:MacRealRunUnsafe {
        $sandbox = New-MacSandbox -Machine 'x86_64' -Provisioned
        $run = Invoke-MacInstaller -Sandbox $sandbox
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match -Pattern 'requires Apple Silicon' -Actual $run.Output
        Assert-NotNull $run.Record 'the record is written for a failure that names no token'
        Assert-Equal 'failed' $run.Record['outcome']
        Assert-Equal 'installer_failed' $run.Record['reason']
        Assert-Equal $script:RequestId $run.Record['requestId']
        Assert-Equal 3 ([int]$run.Record['attempt'])
        Confirm-NothingChanged -Run $run -Sandbox $sandbox
    }

    It 'refuses not_provisioned for a first install, and drops a malformed request id and attempt' -Skip:$script:MacRealRunUnsafe {
        $sandbox = New-MacSandbox
        $run = Invoke-MacInstaller -Sandbox $sandbox -Argument @('--unattended', '--request-id', 'not-a-guid', '--attempt', 'abc')
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Equal 'not_provisioned' $run.Record['reason']
        Assert-Null $run.Record['requestId'] 'a request id that is not a GUID is not recorded'
        Assert-Null $run.Record['attempt'] 'an attempt that is not a number is not recorded'
        Assert-Equal 0 $run.Xcode.Count 'the checkout is checked before the Command Line Tools'
        Confirm-NothingChanged -Run $run -Sandbox $sandbox
    }

    It 'refuses clt_missing without opening the install dialog' -Skip:$script:MacRealRunUnsafe {
        $sandbox = New-MacSandbox -XcodeExit 2 -Provisioned
        $run = Invoke-MacInstaller -Sandbox $sandbox
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Equal 'clt_missing' $run.Record['reason']
        Assert-Equal '-p' ($run.Xcode -join ',') 'the tools are only asked whether they are there'
        Confirm-NothingChanged -Run $run -Sandbox $sandbox
    }

    It 'refuses runner_present for a live runner and stops nothing' -Skip:$script:MacRealRunUnsafe {
        $sandbox = New-MacSandbox -Provisioned
        $info = [System.Diagnostics.ProcessStartInfo]::new('bash')
        foreach ($item in @('-c', 'exec -a "pwsh-stand-in Start-TestRunner.ps1" sleep 120')) { $info.ArgumentList.Add($item) }
        $runner = [System.Diagnostics.Process]::Start($info)
        $script:Spawned.Add($runner)
        Start-Sleep -Milliseconds 300
        [IO.File]::WriteAllText((Join-Path $sandbox.Runtime 'runner.pid'), "$($runner.Id)")
        $run = Invoke-MacInstaller -Sandbox $sandbox
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Equal 'runner_present' $run.Record['reason']
        Assert-False $runner.HasExited 'the runner is left running: the controller stops what must stop'
        Confirm-NothingChanged -Run $run -Sandbox $sandbox
    }

    It 'refuses not_provisioned when Homebrew is not at its fixed location, and never bootstraps it' -Skip:$script:MacRealRunUnsafe {
        $sandbox = New-MacSandbox -Provisioned
        $run = Invoke-MacInstaller -Sandbox $sandbox
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Equal 'not_provisioned' $run.Record['reason']
        Assert-Match -Pattern 'Homebrew is not installed \(looked for /opt/homebrew/bin/brew, /usr/local/bin/brew\)' -Actual $run.Output
        Confirm-NothingChanged -Run $run -Sandbox $sandbox
    }

    It 'ends its preflight with Homebrew found and refuses not_provisioned when UTM is missing, before any change' -Skip:$IsWindows {
        # The real-file runs stop earlier on a host without Homebrew; this
        # slice reaches the end of the preflight under stand-ins on every host.
        $span = Get-MacSpan -From '# --- REGION: Preflight: an unattended run needs a provisioned host' -To '# --- REGION: Preflight: system requirements'
        $refuse = [regex]::Match($script:MacText, '(?m)^refuse\(\) \{.*\}$').Value
        Assert-True ([bool]$refuse) 'fixture sanity: refuse() is a one-line function of the file'
        $root = Join-Path $script:ScratchBase ('p-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path "$root/checkout/.git", "$root/checkout/test", "$root/brew/bin", "$root/UTM.app" -Force
        [IO.File]::WriteAllText("$root/checkout/test/Start-TestRunner.ps1", '')
        [IO.File]::WriteAllText("$root/brew/bin/brew", "#!/bin/sh`nexit 0`n")
        [IO.File]::SetUnixFileMode("$root/brew/bin/brew", [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        $stub = {
            param($Brew, $Utm, $Pwsh = 'echo /stand-in/pwsh')
            @"
die() { printf 'DIE reason=%s %s\n' "`${YURUNA_RESULT_REASON:-}" "`$*" >&2; exit 1; }
$refuse
yuruna_resolve_pwsh() { $Pwsh; }
xcode-select() { return 0; }
yuruna_runner_alive() { return 1; }
yuruna_brew_candidates() { printf '%s\n' '$Brew'; }
YURUNA_DIR='$root/checkout'
UTM_APP='$Utm'
"@
        }
        $noUtm = Invoke-MacSlice -Unattended -Stub (& $stub "$root/brew/bin/brew" "$root/no-UTM.app") -Body $span
        Assert-Equal 1 $noUtm.ExitCode $noUtm.Output
        Assert-Match -Pattern ([regex]::Escape("DIE reason=not_provisioned UTM is not installed at $root/no-UTM.app")) -Actual $noUtm.Output
        Assert-Null $noUtm.Record 'the refusal ends the run where it stands'
        $ready = Invoke-MacSlice -Unattended -Stub (& $stub "$root/brew/bin/brew" "$root/UTM.app") -Body $span
        Assert-Equal 0 $ready.ExitCode $ready.Output
        Assert-False ($ready.Output -match 'DIE ') "a provisioned host passes the preflight: $($ready.Output)"
        Assert-Equal 'succeeded' $ready.Record['outcome'] ''
        $noBrew = Invoke-MacSlice -Unattended -Stub (& $stub "$root/no-brew" "$root/UTM.app") -Body $span
        Assert-Equal 1 $noBrew.ExitCode $noBrew.Output
        Assert-Match -Pattern ([regex]::Escape("DIE reason=not_provisioned Homebrew is not installed (looked for $root/no-brew)")) -Actual $noBrew.Output
        # A checkout, Homebrew and UTM are all present: only the missing
        # PowerShell refuses, before the later checks and before any change.
        $noPwsh = Invoke-MacSlice -Unattended -Stub (& $stub "$root/brew/bin/brew" "$root/UTM.app" 'return 1') -Body $span
        Assert-Equal 1 $noPwsh.ExitCode $noPwsh.Output
        Assert-Match -Pattern ([regex]::Escape("DIE reason=not_provisioned No framework checkout with PowerShell at $root/checkout")) -Actual $noPwsh.Output
        Assert-Null $noPwsh.Record 'the refusal ends the run where it stands'
    }

    It 'keeps every git command, bare sudo, prompt, stop and UTM quit on a path the unattended mode never takes' {
        $scan = $script:MacScan
        $checks = @(
            @{ Why = 'git'; Code = '(^|[\s;&|(!{])git\s+(-C|clone|fetch|pull|checkout|ls-remote|config|update-index|diff-index|add|rm|reset)\b' }
            @{ Why = 'sudo without -n'; Code = '(^|[\s;&|(!{])sudo\s+(?!-n\b)' }
            @{ Why = 'a process stop or UTM quit'; Code = '\b(osascript|pkill|killall|quit_mac_app|stop_yuruna_processes|capture_installer_state|is_service_vm_running)\b' }
            @{ Why = 'a signal'; Code = '\bkill\s+(?!-0)' }
            @{ Why = 'the UTM cask'; Code = '\bbrew_ensure_cask\b' }
            @{ Why = 'a checkout rewrite'; Code = '\b(renormalize_checkout|reclone_checkout)\b' }
            @{ Why = 'the Command Line Tools dialog'; Code = 'xcode-select --install' }
            @{ Why = 'the Homebrew bootstrap'; Code = 'NONINTERACTIVE=1 /bin/bash\b' }
            @{ Why = 'a Homebrew pin lifted'; Code = '\bbrew unpin\b' }
            @{ Why = 'the removal of the old PowerShell keg'; Code = '\bbrew cleanup\b' }
            @{ Why = 'a question'; Code = '\bread -r -p\b' }
            @{ Why = 'the attended host configuration'; Code = '\bpwsh\b.*-File\s'; Source = '-File "\$HOST_SETUP"' }
            @{ Why = 'the baseline reset'; Code = '\bpwsh\b.*-File\s'; Source = '-File "\$REMOVE_TEST_VMS"' }
        )
        foreach ($check in $checks) {
            $found = 0
            for ($i = 0; $i -lt $scan.Code.Count; $i++) {
                $code = $scan.Code[$i]
                if ($code -notmatch $check.Code -or $code -match '^[a-z_][a-z0-9_]*\(\) \{') { continue }
                if ($check.Source -and $script:MacLines[$i] -notmatch $check.Source) { continue }
                # The exit trap ends the attended run's sudo keepalive; an
                # unattended run starts none, so the name is empty there.
                if ($script:MacLines[$i] -match '^  if \[\[ -n "\$\{SUDO_KEEPALIVE_PID:-\}" \]\]; then kill ') { continue }
                $found++
                Assert-True (Test-ShellAttendedOnly -Line $i -Scan $scan) "line $($i + 1) runs $($check.Why) on the unattended path: $($script:MacLines[$i].Trim())"
            }
            Assert-True ($found -gt 0) "fixture sanity: $($check.Why) is found in the file"
        }
    }

    It 'reads the scan of attended paths the way the file means it' {
        # The scan itself, on a file whose shapes it must tell apart.
        $text = @'
if (( YURUNA_UNATTENDED )); then
  log "unattended"
elif sudo -v; then
  git fetch
else
  git pull
fi
if (( ! YURUNA_UNATTENDED )) && ! xcode-select -p; then
  xcode-select --install
fi
f() {
  if (( ${YURUNA_UNATTENDED:-0} )); then
    note "kept"
    return 0
  fi
  brew unpin x
}
g() {
  brew unpin y
}
nested_return() {
  if (( ${YURUNA_UNATTENDED:-0} )); then
    if [[ -n $x ]]; then
      return 0
    fi
  fi
  git fetch origin
}
no_return() {
  if (( ${YURUNA_UNATTENDED:-0} )); then
    note "kept"
  fi
  git fetch upstream
}
else_return() {
  if (( ${YURUNA_UNATTENDED:-0} )); then
    note "kept"
  else
    return 0
  fi
  git fetch upstream2
}
both_paths() {
  brew unpin z
}
f
nested_return
no_return
else_return
both_paths
if (( YURUNA_UNATTENDED )); then
  :
else
  g
  both_paths
fi
log "git pull is text, not a command"
# git reset in a comment
git status
'@
        $lines = $text -split "`n"
        $scan = Get-ShellScan -Text $text
        $at = { param($t) [Array]::IndexOf($lines, $t) }
        Assert-True (Test-ShellAttendedOnly -Line (& $at '  git fetch') -Scan $scan) 'an elif after the unattended branch'
        Assert-True (Test-ShellAttendedOnly -Line (& $at '  git pull') -Scan $scan) 'an else after the unattended branch'
        Assert-True (Test-ShellAttendedOnly -Line (& $at '  xcode-select --install') -Scan $scan) 'a then clause that requires an attended run'
        Assert-True (Test-ShellAttendedOnly -Line (& $at '  brew unpin x') -Scan $scan) 'after the function''s unattended return'
        Assert-True (Test-ShellAttendedOnly -Line (& $at '  brew unpin y') -Scan $scan) 'a function called only from attended lines'
        Assert-False (Test-ShellAttendedOnly -Line (& $at '  log "unattended"') -Scan $scan) 'the unattended branch itself'
        Assert-False (Test-ShellAttendedOnly -Line (& $at 'git status') -Scan $scan) 'top-level code'
        Assert-False (Test-ShellAttendedOnly -Line (& $at '  git fetch origin') -Scan $scan) 'a return inside a nested if does not end the unattended path'
        Assert-False (Test-ShellAttendedOnly -Line (& $at '  git fetch upstream') -Scan $scan) 'an unattended block without a return falls through'
        Assert-False (Test-ShellAttendedOnly -Line (& $at '  git fetch upstream2') -Scan $scan) 'a return in the else clause runs only on the attended path'
        Assert-False (Test-ShellAttendedOnly -Line (& $at '  brew unpin z') -Scan $scan) 'a function with one unattended call site among attended ones'
        Assert-True ($scan.Code[(& $at 'log "git pull is text, not a command"')] -notmatch 'git') 'a quoted word is not code'
        Assert-True ($scan.Code[(& $at '# git reset in a comment')] -notmatch 'git') 'a comment is not code'
    }

    It 'leaves the status service, the runner and UTM alone, and captures nothing' -Skip:$IsWindows {
        $span = Get-MacSpan -From 'PRESERVE_SERVICE_VM=0' -To '# --- REGION: Install platform packages'
        $stub = @'
yuruna_require_install_mode() { :; }
is_service_vm_running() { echo CALLED-is_service_vm_running; return 1; }
capture_installer_state() { echo CALLED-capture_installer_state; }
stop_yuruna_processes() { echo CALLED-stop_yuruna_processes; }
quit_mac_app() { echo "CALLED-quit_mac_app $*"; }
'@
        $unattended = Invoke-MacSlice -Unattended -Stub $stub -Body ($span + "`necho PRESERVE=`$PRESERVE_SERVICE_VM")
        Assert-Equal 0 $unattended.ExitCode $unattended.Output
        Assert-False ($unattended.Output -match 'CALLED-') "nothing is asked, captured, stopped or quit: $($unattended.Output)"
        Assert-Match -Pattern 'PRESERVE=1' -Actual $unattended.Output
        $attended = Invoke-MacSlice -Stub $stub -Body ($span + "`necho PRESERVE=`$PRESERVE_SERVICE_VM")
        foreach ($name in @('is_service_vm_running', 'capture_installer_state', 'stop_yuruna_processes', 'quit_mac_app UTM')) {
            Assert-Match -Pattern "CALLED-$name" -Actual $attended.Output 'the attended run is unchanged'
        }
    }

    It 'records a failed brew update as an issue with the remark brew_update_failed' -Skip:$IsWindows {
        $span = Get-MacSpan -From 'if [[ $BREW_SKIP_UPDATE -eq 0 ]]; then' -To '# --- REGION: Quit a macOS app gracefully'
        $stub = "brew() { return 1; }`nBREW_SKIP_UPDATE=0"
        $unattended = Invoke-MacSlice -Unattended -Stub $stub -Body $span
        Assert-Equal 0 $unattended.ExitCode $unattended.Output
        Assert-Equal 'succeeded-with-issues' $unattended.Record['outcome']
        Assert-Equal 'brew_update_failed' (@($unattended.Record['remarks']) -join ',')
        Assert-Match -Pattern 'brew update exited non-zero' -Actual (@($unattended.Record['issues']) -join ' ')
        $attended = Invoke-MacSlice -Stub $stub -Body $span
        Assert-Equal 'succeeded' $attended.Record['outcome'] 'the attended run still only warns'
        Assert-Equal 0 @($attended.Record['remarks']).Count ''
    }

    It 'never upgrades the UTM cask, and records a newer UTM as utm_upgrade_deferred' -Skip:$IsWindows {
        $span = Get-MacSpan -From 'log "Installing / upgrading required casks"' -To '# --- REGION: record_dotnet_install_location'
        $stub = @'
brew() {
  case "$*" in
    "list --cask --versions utm") echo "utm 4.6.4" ;;
    "outdated --cask --greedy --quiet utm") if [[ "${UTM_OUTDATED:-0}" == 1 ]]; then echo utm; fi ;;
    *) echo "BREW $*" ;;
  esac
}
brew_ensure_cask() { echo "CALLED-brew_ensure_cask $*"; }
PRESERVE_SERVICE_VM=1
'@
        $outdated = Invoke-MacSlice -Unattended -Function 'utm_cask_outdated' -Stub ($stub + "`nUTM_OUTDATED=1") -Body $span
        Assert-Equal 0 $outdated.ExitCode $outdated.Output
        Assert-False ($outdated.Output -match 'CALLED-brew_ensure_cask') 'the cask is never upgraded unattended'
        Assert-Equal 'utm_upgrade_deferred' (@($outdated.Record['remarks']) -join ',')
        Assert-Match -Pattern 'newer UTM is available' -Actual (@($outdated.Record['issues']) -join ' ')
        $current = Invoke-MacSlice -Unattended -Function 'utm_cask_outdated' -Stub $stub -Body $span
        Assert-Equal 'succeeded' $current.Record['outcome'] 'a current UTM is no issue'
        Assert-Equal 0 @($current.Record['remarks']).Count ''
        $attended = Invoke-MacSlice -Function 'utm_cask_outdated' -Stub ($stub + "`nPRESERVE_SERVICE_VM=0") -Body $span
        Assert-Match -Pattern 'CALLED-brew_ensure_cask utm' -Actual $attended.Output 'the attended run upgrades it as before'
    }

    It 'keeps the old PowerShell keg: no install cleanup and no brew cleanup' -Skip:$IsWindows {
        $exports = Get-MacSpan -From 'export NONINTERACTIVE=1' -To 'BREW_SKIP_UPDATE=0'
        $cleanup = Get-MacSpan -From 'if (( YURUNA_UNATTENDED )); then
  log "Leaving brew cleanup' -To 'command -v pwsh >/dev/null 2>&1 || die "pwsh not found after install."'
        $body = $exports + "`n" + $cleanup + "`necho KEG-CLEANUP=`${HOMEBREW_NO_INSTALL_CLEANUP:-unset}"
        $stub = 'brew() { echo "BREW $*"; }'
        $unattended = Invoke-MacSlice -Unattended -Stub $stub -Body $body
        Assert-Match -Pattern 'KEG-CLEANUP=1' -Actual $unattended.Output 'Homebrew keeps the replaced keg'
        Assert-False ($unattended.Output -cmatch 'BREW cleanup') 'brew cleanup is not run'
        $attended = Invoke-MacSlice -Stub $stub -Body $body
        Assert-Match -Pattern 'KEG-CLEANUP=unset' -Actual $attended.Output ''
        Assert-Match -Pattern 'BREW cleanup --quiet' -Actual $attended.Output 'the attended run cleans up as before'
    }

    It 'leaves a Homebrew pin in place and records the pinned formula as an issue' -Skip:$IsWindows {
        $stub = @'
brew() {
  case "$1" in
    list) echo powershell ;;
    unpin) UNPINNED="$2" ;;
  esac
}
'@
        $body = 'if brew_unpin_if_pinned powershell; then echo UPGRADE=go; else echo UPGRADE=skip; fi; echo "UNPINNED=${UNPINNED:-none}"'
        $unattended = Invoke-MacSlice -Unattended -Function 'brew_unpin_if_pinned' -Stub $stub -Body $body
        Assert-Match -Pattern 'UNPINNED=none' -Actual $unattended.Output 'the operator''s pin stays'
        Assert-Match -Pattern 'UPGRADE=skip' -Actual $unattended.Output 'the caller is told to skip the upgrade the pin holds back'
        Assert-Match -Pattern "'powershell' formula is pinned" -Actual (@($unattended.Record['issues']) -join ' ')
        $attended = Invoke-MacSlice -Function 'brew_unpin_if_pinned' -Stub $stub -Body $body
        Assert-Match -Pattern 'UNPINNED=powershell' -Actual $attended.Output 'the attended run lifts it as before'
        Assert-Match -Pattern 'UPGRADE=go' -Actual $attended.Output ''
    }

    It 'records a pin once over every repair pass and skips the upgrade the pin holds back' -Skip:$IsWindows {
        $stub = @'
brew() {
  case "$1" in
    list) echo powershell ;;
  esac
}
brew_ensure_formula() { echo "ENSURE $1"; }
prefer_newest_binary() { echo "PROMOTE $1"; }
'@
        $body = "repair_powershell 1`nrepair_powershell 2`nrepair_brew_tool curl curl"
        $functions = @('brew_unpin_if_pinned', 'repair_powershell', 'repair_brew_tool')
        $unattended = Invoke-MacSlice -Unattended -Function $functions -Stub $stub -Body $body
        Assert-Equal 0 $unattended.ExitCode $unattended.Output
        $pinned = @(@($unattended.Record['issues']) | Where-Object { $_ -match "'powershell' formula is pinned" })
        Assert-Equal 1 $pinned.Count "one pin is one issue, however many passes meet it: $(@($unattended.Record['issues']) -join ' | ')"
        Assert-False ($unattended.Output -match 'ENSURE powershell') 'an upgrade the pin holds back is not attempted'
        Assert-Equal 2 @($unattended.Output -split "`n" | Where-Object { $_ -eq 'PROMOTE pwsh' }).Count 'a newer copy elsewhere is still promoted'
        Assert-Match -Pattern 'ENSURE curl' -Actual $unattended.Output 'a formula that is not pinned is upgraded as before'
        $attended = Invoke-MacSlice -Function $functions -Stub $stub -Body $body
        Assert-Equal 2 @($attended.Output -split "`n" | Where-Object { $_ -eq 'ENSURE powershell' }).Count 'the attended run lifts the pin and upgrades on each pass'
        Assert-Match -Pattern "unpinning the 'powershell' formula" -Actual $attended.Output ''
    }

    It 'records a baseline shortfall instead of asking about it' -Skip:$IsWindows {
        $stub = @'
sw_vers() { echo 15.0; }
sysctl() { echo 4; }
df() { printf 'Filesystem 1K-blocks Used Available\n/dev/x 1 1 1024\n'; }
uname() { echo arm64; }
'@
        $run = Invoke-MacSlice -Unattended -Function 'preflight_system_requirements' -Stub $stub -Body 'preflight_system_requirements </dev/null'
        # read -p prints its prompt only to a terminal, so the question shows
        # here by the banner the attended path writes before it asks.
        Assert-False ($run.Output -match 'System does not meet Yuruna TESTED requirements') "nothing is asked: $($run.Output)"
        Assert-Equal 0 $run.ExitCode $run.Output
        $issues = @($run.Record['issues']) -join ' | '
        Assert-Match -Pattern 'Below the tested baseline: macOS 15\.0 detected' -Actual $issues
        $attended = Invoke-MacSlice -Function 'preflight_system_requirements' -Stub $stub -Body 'preflight_system_requirements </dev/null'
        Assert-Match -Pattern 'System does not meet Yuruna TESTED requirements' -Actual $attended.Output 'fixture sanity: the attended path prints the banner the assertion above looks for'
    }

    It 'adds tmux to the Homebrew formulae it installs and reports' {
        Assert-True ($script:MacLines -contains 'brew_ensure_formula tmux') 'the host controller session needs tmux'
        $report = @($script:MacLines | Where-Object { $_ -like 'REPORT_BREW_FORMULAE=*' })
        Assert-Equal 1 $report.Count ''
        Assert-Match -Pattern '\btmux\b' -Actual $report[0]
    }
}

Describe 'install/windows.hyper-v.ps1 -Unattended' {
    BeforeAll {
        $script:WindowsAst = Get-YurunaTestFileAst -Path $script:WindowsInstaller

        # Runs the installer's own record functions, loaded from its syntax tree
        # into a module of their own, and returns the record they write: the
        # tokens, the step and the outcome split are reached on every platform,
        # where the real file stops at the Windows-only preflight. The module's
        # script scope stands in for the installer's, with the parameters and
        # state the functions read set as an unattended run sets them.
        function Invoke-WindowsRecordFunction {
            param([Parameter(Mandatory)][scriptblock]$Body, [object[]]$ArgumentList = @(), [hashtable]$State = @{})
            $names = @('Write-Step', 'Write-Die', 'Stop-InstallRefused', 'Write-InstallResult')
            $definitions = @($script:WindowsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names }.GetNewClosure(), $true))
            Assert-Equal $names.Count $definitions.Count 'fixture sanity: each record function is defined once'
            $root = Join-Path $script:ScratchBase ('r-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $null = New-Item -ItemType Directory -Path $root -Force
            $module = New-Module -Name ('InstallRecord' + [Guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create((@($definitions | ForEach-Object { $_.Extent.Text }) -join "`n")))
            $savedLocalAppData = Save-YurunaTestEnvironment -Name @('LOCALAPPDATA')
            try {
                $env:LOCALAPPDATA = $root
                $null = & $module {
                    param($Root, $RequestId, $State, $BodyText, $ArgumentList)
                    $ErrorActionPreference = 'Stop'
                    $script:Unattended = $true
                    $script:UpgradePowerShell = $false
                    $script:RequestId = $RequestId
                    $script:Attempt = 4
                    $script:YurunaDir = $Root
                    $script:LogPath = ''
                    $script:YurunaIssue = [System.Collections.Generic.List[string]]::new()
                    $script:InstallStep = ''
                    $script:InstallReason = ''
                    $script:InstallError = $null
                    $script:InstallSucceeded = $false
                    $script:RestartNeeded = $false
                    $script:PwshUpgrade = $null
                    foreach ($name in $State.Keys) { Set-Variable -Name $name -Scope Script -Value $State[$name] }
                    . ([scriptblock]::Create($BodyText)) @ArgumentList
                } $root $script:RequestId $State $Body.ToString() $ArgumentList
            } finally {
                Restore-YurunaTestEnvironment -Saved $savedLocalAppData
            }
            $recordPath = Join-Path $root 'yuruna/install-result.json'
            Assert-True (Test-Path -LiteralPath $recordPath) 'the record is written'
            Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable
        }
    }

    It 'declares the unattended switches and carries the marker the install step reads' {
        $names = @($script:WindowsAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($name in @('Unattended', 'UpgradePowerShell', 'RequestId', 'Attempt', 'YurunaDir')) { Assert-True ($names -contains $name) "-$name is declared" }
        Assert-True (([IO.File]::ReadAllLines($script:WindowsInstaller)) -contains '$script:YurunaUnattendedProtocolVersion = 1') 'the marker names the unattended contract'
    }

    It 'writes its record with the request, the attempt and a reason on a refusal before the first change' {
        $root = Join-Path $script:ScratchBase ('w-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path $root -Force
        $r = Invoke-BoundedNativeCommand -FilePath ([Environment]::ProcessPath) -TimeoutSeconds 120 -Environment @{ LOCALAPPDATA = $root; NO_COLOR = '1' } -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:WindowsInstaller, '-Unattended', '-RequestId', $script:RequestId, '-Attempt', '2',
            '-YurunaDir', (Join-Path $root 'checkout'), '-LogPath', (Join-Path $root 'install.log'))
        Assert-False $r.TimedOut ''
        if ($IsWindows) { Set-ItResult -Skipped -Because 'off Windows the Windows-only preflight is the refusal this case reads'; return }
        Assert-True ($r.ExitCode -ne 0) (ConvertTo-PlainText ($r.StdOut + $r.StdErr))
        $record = Get-Content -LiteralPath (Join-Path $root 'yuruna/install-result.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal 'failed' $record['outcome']
        Assert-Equal 'installer_failed' $record['reason']
        Assert-Equal $script:RequestId $record['requestId']
        Assert-Equal 2 ([int]$record['attempt'])
        Assert-True ([bool]$record['unattended']) ''
        Assert-False ([bool]$record['restartRequired']) ''
        Assert-True ($record.Contains('pwshUpgrade') -and $record.Contains('step')) 'the record has the fields of the unattended contract'
    }

    # The script-scope trap of the installer writes the failed record of a
    # refusal; the catch here plays that trap.
    It 'records <Reason> as the reason of a refusal' -ForEach @(
        @{ Reason = 'not_elevated' }, @{ Reason = 'not_provisioned' }, @{ Reason = 'runner_present' }
    ) {
        $record = Invoke-WindowsRecordFunction -ArgumentList @($Reason) -Body {
            param($Token)
            Write-Step 'Checking the unattended preconditions'
            try { Stop-InstallRefused -Reason $Token -Message 'refused' } catch { Write-InstallResult -Outcome 'failed' }
        }
        Assert-Equal 'failed' $record['outcome']
        Assert-Equal 1 ([int]$record['exitCode'])
        Assert-Equal $Reason $record['reason']
        Assert-Equal $script:RequestId $record['requestId']
        Assert-Equal 4 ([int]$record['attempt'])
        Assert-True ([bool]$record['unattended']) ''
        Assert-Equal 'Checking the unattended preconditions' $record['step']
    }

    It 'records installer_failed and the step it failed on for a failure without a token' {
        $record = Invoke-WindowsRecordFunction -Body {
            Write-Step 'Enabling the Hyper-V feature'
            try { throw 'DISM failed' } catch { $script:InstallError = $_ }
            # What runs after the main try whatever its outcome.
            Write-Step 'Checking installed versions against the required floors'
            Write-InstallResult
        }
        Assert-Equal 'failed' $record['outcome']
        Assert-Equal 'installer_failed' $record['reason']
        Assert-Equal 'Enabling the Hyper-V feature' $record['step'] 'the step names where the run failed, not a later one'
        Assert-Match -Pattern '\}\s*catch\s*\{\s*\$script:InstallError = \$_\s*\}\s*finally\s*\{' -Actual $script:WindowsAst.Extent.Text
    }

    It 'records the last step of a run that succeeded' {
        $record = Invoke-WindowsRecordFunction -State @{ InstallSucceeded = $true } -Body {
            Write-Step 'Enabling the Hyper-V feature'
            Write-Step 'Checking installed versions against the required floors'
            Write-InstallResult
        }
        Assert-Equal 'succeeded' $record['outcome']
        Assert-Null $record['reason']
        Assert-Equal 'Checking installed versions against the required floors' $record['step']
    }

    It 'records a failed run that also needs a restart as failed, with restartRequired' {
        $record = Invoke-WindowsRecordFunction -State @{ RestartNeeded = $true } -Body {
            try { throw 'seeding test.config.yml failed' } catch { $script:InstallError = $_ }
            Write-InstallResult
        }
        Assert-Equal 'failed' $record['outcome'] 'a pending restart never hides a failure'
        Assert-Equal 1 ([int]$record['exitCode'])
        Assert-Equal 'installer_failed' $record['reason']
        Assert-True ([bool]$record['restartRequired']) 'the restart is carried on its own'
    }

    It 'records restart-required only for a run that succeeded' {
        $record = Invoke-WindowsRecordFunction -State @{ RestartNeeded = $true; InstallSucceeded = $true } -Body { Write-InstallResult }
        Assert-Equal 'restart-required' $record['outcome']
        Assert-Equal 0 ([int]$record['exitCode'])
        Assert-Null $record['reason']
        Assert-True ([bool]$record['restartRequired']) ''
    }

    It 'records the PowerShell upgrade the host controller runs after the install' {
        $record = Invoke-WindowsRecordFunction -State @{ InstallSucceeded = $true; PwshUpgrade = [pscustomobject]@{ From = '7.7.0'; To = '7.7.1' } } -Body { Write-InstallResult }
        Assert-Equal 'succeeded' $record['outcome']
        Assert-NotNull $record['pwshUpgrade'] 'the pending upgrade is recorded'
        Assert-Equal '7.7.0' $record['pwshUpgrade']['from']
        Assert-Equal '7.7.1' $record['pwshUpgrade']['to']
        Assert-True ([bool]$record['pwshUpgrade']['pending']) 'the upgrade is pending: this run never starts it'
    }

    It 'runs -UpgradePowerShell only under Windows PowerShell, so PowerShell 7 never replaces itself' {
        $root = Join-Path $script:ScratchBase ('w-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path $root -Force
        $r = Invoke-BoundedNativeCommand -FilePath ([Environment]::ProcessPath) -TimeoutSeconds 60 -Environment @{ LOCALAPPDATA = $root } -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:WindowsInstaller, '-Unattended', '-UpgradePowerShell')
        Assert-Equal 2 $r.ExitCode (ConvertTo-PlainText ($r.StdOut + $r.StdErr))
        Assert-False (Test-Path -LiteralPath (Join-Path $root 'yuruna/install-result.json')) 'the upgrade mode leaves the install record to the install phase'
    }

    It 'keeps every git command, prompt, window and hold on a path the unattended mode never takes' {
        $ast = $script:WindowsAst
        $git = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.CommandElements[0].Extent.Text -eq '$gitExe' }, $true))
        Assert-True ($git.Count -gt 5) 'fixture sanity: the git calls are found'
        foreach ($call in $git) { Assert-True (Test-AttendedOnly -Node $call -Ast $ast) "line $($call.Extent.StartLineNumber) runs git on the unattended path" }
        foreach ($name in @('Start-Process', 'Stop-YurunaProcess', 'Assert-YurunaCheckoutMovable', 'Invoke-YurunaInstallerState', 'Start-PwshUpgradeAfterExit')) {
            foreach ($call in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }.GetNewClosure(), $true))) {
                Assert-True (Test-AttendedOnly -Node $call -Ast $ast) "line $($call.Extent.StartLineNumber): $name is reachable unattended"
            }
        }
        $holds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Sleep' -and $n.Extent.Text -match '-Seconds' }, $true))
        foreach ($hold in $holds) { Assert-True (Test-AttendedOnly -Node $hold -Ast $ast) "line $($hold.Extent.StartLineNumber) holds the unattended run" }
        $read = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Read-Host' }, $true))
        Assert-Equal 1 $read.Count 'one question in the file'
        $text = $script:WindowsAst.Extent.Text
        $guard = $text.IndexOf("    if (`$Unattended) {`n        foreach (`$i in `$issues) { Add-InstallIssue", [StringComparison]::Ordinal)
        Assert-True ($guard -gt 0 -and $guard -lt $read[0].Extent.StartOffset) 'the unattended run records the baseline and returns before the question'
        Assert-Match -Pattern "if \(-not \`$isAdmin\) \{ Stop-InstallRefused -Reason 'not_elevated'" -Actual $text
    }
}
