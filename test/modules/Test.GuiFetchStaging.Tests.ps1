<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42dc2c8b-375c-4869-8113-cd1b1b7a0e53
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test gui transport integrity pester
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
    Verifies bounded macOS GUI fetch staging with local shells and mocked host I/O.
#>

BeforeDiscovery {
    $script:localShellAvailable = $false
    if (Get-Command bash -CommandType Application -ErrorAction SilentlyContinue) {
        try {
            & bash -c 'command -v sha256sum >/dev/null 2>&1' 2>$null
            $script:localShellAvailable = $LASTEXITCODE -eq 0
        } catch { $script:localShellAvailable = $false }
    }
}

BeforeAll {
    $source = Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1'
    $tokens = $null; $errors = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    function Get-FunctionSource([string]$Name) {
        $script:ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true).Extent.Text
    }
    $script:NonzeroScriptExitSentinel = 'NONZERO SCRIPT EXIT:'
    . ([scriptblock]::Create((Get-FunctionSource 'Get-GuiFetchExecutionInput')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-FetchExecutionCommand')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-FetchObservationEnvPrefix')))
    . ([scriptblock]::Create((Get-FunctionSource 'Get-FetchExecuteEnvPrefix')))
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1') -Force
    $script:payload = '/usr/local/lib/yuruna/fetch-and-execute.sh project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh'
    $script:context = @{Step=@{};StepInvocationId='9dd7e79e0e404f0b8aa334f1337540e9';SequenceInvocationId='2ba53dd6961e4beea8ec17e8416f8651'}
    # The production log recorded a 223-character integrity envelope.
    $script:integrity = 'EXEC_REQUIRE_SHA256=1 E_SHA=' + ('c' * 64) + ' E_RETRY_SHA=' + ('d' * 64) + ' E_FB_REPO=alissonsol/yurunadev E_FB_REF=933b9d5b0bee '
    $script:realisticCommand = Get-FetchExecutionCommand -CommandLine $script:payload -EnvPrefix ((Get-FetchObservationEnvPrefix -Context $script:context) + $script:integrity)
    function Invoke-LocalInput([string[]]$Lines) {
        $result = & bash -c ($Lines -join "`n") 2>&1
        $script:localExitCode = $LASTEXITCODE
        return ($result -join "`n")
    }
}

Describe 'Bounded GUI command staging' {
    It 'keeps a short command unchanged' {
        @(Get-GuiFetchExecutionInput -CommandLine 'echo ready') | Should -HaveCount 1
        Get-GuiFetchExecutionInput -CommandLine 'echo ready' | Should -BeExactly 'echo ready'
    }

    It 'stages the 458-character failing workload with complete identifiers and hashes' {
        $script:payload.Length | Should -Be 129
        $script:integrity.Length | Should -Be 223
        $script:realisticCommand.Length | Should -Be 458
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        $lines | Should -HaveCount 4
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 400 }
        foreach ($line in $lines[0..($lines.Count - 2)]) { $line.Length | Should -BeLessOrEqual 240 }
        $lines[-1] | Should -Match 'sha256sum'
        $lines[-1] | Should -Not -Match 'NONZERO SCRIPT EXIT:'
    }

    It 'keeps every echoed input and the combined echo outside the real fuzzy failure matcher' {
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        foreach ($line in $lines) { Test-OCRMatch -Text $line -Pattern 'NONZERO SCRIPT EXIT:' | Should -BeFalse }
        Test-OCRMatch -Text ($lines -join "`n") -Pattern 'NONZERO SCRIPT EXIT:' | Should -BeFalse
    }

    It 'uses the real integrity builder and preserves its hashes and enforced flag' {
        function Get-YurunaGitHubSource { return @{Repo='alissonsol/yurunadev';Ref='933b9d5b0beedd9a5b36a33306093242f87b63f3'} }
        function Test-YurunaFileMatchesHead { return $true }
        $relative = 'project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh'
        $file = Join-Path $TestDrive $relative
        $retry = Join-Path $TestDrive 'automation/yuruna-retry.sh'
        $null = New-Item -ItemType Directory -Path (Split-Path $file), (Split-Path $retry) -Force
        [IO.File]::WriteAllText($file, '# test payload')
        [IO.File]::WriteAllText($retry, '# test retry library')
        $prefix = Get-FetchExecuteEnvPrefix -CommandLine $script:payload -RepoRoot $TestDrive
        $prefix | Should -Match 'EXEC_REQUIRE_SHA256=1 '
        $prefix | Should -Match ('E_SHA=' + (Get-FileHash $file).Hash.ToLowerInvariant())
        $prefix | Should -Match ('E_RETRY_SHA=' + (Get-FileHash $retry).Hash.ToLowerInvariant())
        $command = Get-FetchExecutionCommand -CommandLine $script:payload -EnvPrefix ((Get-FetchObservationEnvPrefix -Context $script:context) + $prefix)
        $command.Length | Should -Be 458
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 400 }
    }

    It 'counts escaped apostrophes against every physical input line' {
        $command = ": " + ("''" * 250)
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 400 }
        foreach ($line in $lines[0..($lines.Count - 2)]) { $line.Length | Should -BeLessOrEqual 240 }
    }
}

Describe 'GUI command staging in a local bash with sha256sum' -Skip:(-not $script:localShellAvailable) {
    It 'reconstructs the complete workload command without executing it' {
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        # Inspect the verified command without running a workload or contacting
        # a host. The actual digest and reconstruction execute unchanged.
        $lines[-1] = $lines[-1].Replace('eval "$__y"', 'printf %s "$__y"')
        Invoke-LocalInput $lines | Should -BeExactly $script:realisticCommand
        $script:localExitCode | Should -Be 0
    }

    It 'emits a failure that the real fuzzy OCR matcher recognizes after corruption' {
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $script:realisticCommand)
        $lines[1] = $lines[1].Replace('c', 'e')
        $output = Invoke-LocalInput $lines
        Test-OCRMatch -Text $output -Pattern 'NONZERO SCRIPT EXIT:' | Should -BeTrue
        $script:localExitCode | Should -Be 125
    }

    It 'preserves compound shell syntax, literal quotes, and a nonzero exit status' {
        # A quoted long no-op exercises escaping without producing output.
        $command = "printf '%s\n' `"it's literal`"; : '" + ('x' * 450) + "'; printf '%s\n' second; exit 17"
        Invoke-LocalInput @(Get-GuiFetchExecutionInput -CommandLine $command) | Should -BeExactly "it's literal`nsecond"
        $script:localExitCode | Should -Be 17
    }

    It 'executes an apostrophe-heavy command without changing its quoting' {
        $command = ": " + ("''" * 250)
        Invoke-LocalInput @(Get-GuiFetchExecutionInput -CommandLine $command) | Should -BeExactly ''
        $script:localExitCode | Should -Be 0
    }

    It 'rejects a changed chunk before executing any payload' {
        $command = "echo EXECUTED; : '" + ('x' * 450) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        $lines[1] = $lines[1].Replace('x', 'z')
        Invoke-LocalInput $lines | Should -BeExactly 'NONZERO SCRIPT EXIT: GUI command integrity mismatch'
        $script:localExitCode | Should -Be 125
    }

    It 'rejects a missing chunk and cannot reuse a parent shell variable' {
        $command = "echo EXECUTED; : '" + ('x' * 450) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        $missing = @('__y=stale') + @($lines[0]) + @($lines[2..($lines.Count - 1)])
        Invoke-LocalInput $missing | Should -BeExactly 'NONZERO SCRIPT EXIT: GUI command integrity mismatch'
        $script:localExitCode | Should -Be 125
    }

    It 'executes nothing when preparation ends before the closing line' {
        $command = "echo EXECUTED; : '" + ('x' * 450) + "'"
        $lines = @(Get-GuiFetchExecutionInput -CommandLine $command)
        $output = Invoke-LocalInput $lines[0..($lines.Count - 2)]
        $output | Should -Not -Match 'EXECUTED'
        $script:localExitCode | Should -Not -Be 0
    }

    It 'preserves an outer shell variable and leaves no staging state' {
        $command = ": '" + ('x' * 450) + "'"
        $lines = @('__y=outer') + @(Get-GuiFetchExecutionInput -CommandLine $command) + @('printf %s "$__y"')
        Invoke-LocalInput $lines | Should -BeExactly 'outer'
        $script:localExitCode | Should -Be 0
    }

    It 'preserves sensitive profiling opt-out, identities, and scoped environment' {
        $context = @{Step=@{sensitive=$true};StepInvocationId='9dd7e79e0e404f0b8aa334f1337540e9';SequenceInvocationId='2ba53dd6961e4beea8ec17e8416f8651'}
        $payload = "printf '%s|%s|%s|%s' `"`$EXEC_PROFILE`" `"`$EXEC_KEEP_PROFILE`" `"`$E_SI`" `"`$E_QI`"; : '" + ('x' * 450) + "'"
        $command = Get-FetchExecutionCommand -CommandLine $payload -EnvPrefix (Get-FetchObservationEnvPrefix -Context $context)
        Invoke-LocalInput @(Get-GuiFetchExecutionInput -CommandLine $command) | Should -BeExactly '0|0|9dd7e79e0e404f0b8aa334f1337540e9|2ba53dd6961e4beea8ec17e8416f8651'
        $script:localExitCode | Should -Be 0
    }

    It 'does not leak profiling settings or identities across ordinary, sensitive and ordinary invocations' {
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('unset EXEC_PROFILE EXEC_KEEP_PROFILE E_SI E_QI')
        $expected = [Collections.Generic.List[string]]::new()
        foreach ($index in 0..2) {
            $sensitive = $index -eq 1
            $context = @{Step=@{sensitive=$sensitive};StepInvocationId=('a' * 31) + $index;SequenceInvocationId=('b' * 31) + $index}
            $payload = 'printf "%s|%s|%s|%s\n" "${EXEC_PROFILE:-1}" "$EXEC_KEEP_PROFILE" "$E_SI" "$E_QI"; : ' + "'" + ('x' * 450) + "'"
            $command = Get-FetchExecutionCommand -CommandLine $payload -EnvPrefix (Get-FetchObservationEnvPrefix -Context $context)
            foreach ($line in @(Get-GuiFetchExecutionInput -CommandLine $command)) { $lines.Add($line) }
            $expectedProfileState = if ($sensitive) { '0' } else { '1' }
            $expected.Add("$expectedProfileState|$expectedProfileState|$($context.StepInvocationId)|$($context.SequenceInvocationId)")
        }
        $lines.Add('printf "parent:%s|%s|%s|%s" "${EXEC_PROFILE-unset}" "${EXEC_KEEP_PROFILE-unset}" "${E_SI-unset}" "${E_QI-unset}"')
        $expected.Add('parent:unset|unset|unset|unset')
        Invoke-LocalInput $lines.ToArray() | Should -BeExactly ($expected -join "`n")
        $script:localExitCode | Should -Be 0
    }
}

Describe 'GUI fetch handler integration' {
    BeforeAll {
        $registration = $script:ast.Find({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Register-SequenceAction' -and $n.Extent.Text.StartsWith("Register-SequenceAction -Name 'fetchAndExecute'")}, $true)
        $handler = ($registration.CommandElements | Where-Object {$_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]} | Select-Object -Last 1).ScriptBlock.Extent.Text
        $providerAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'Test.HostIO.Utm.psm1'), [ref]$null, [ref]$null)
        $providerRegistration = $providerAst.Find({param($n)
            $n -is [Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Register-HostIOProvider' -and
            $n.Extent.Text.StartsWith("Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Text'")
        }, $true)
        $provider = ($providerRegistration.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.ScriptBlockExpressionAst]
        } | Select-Object -Last 1).ScriptBlock.Extent.Text
        $fixture = @'
$script:NonzeroScriptExitSentinel='NONZERO SCRIPT EXIT:'
$script:FetchExecuteTypedCharWarn=400
$script:ShellRejectedCommandPattern=@('command not found','No such file or directory')
$script:ShellRejectionWindowSeconds=20
$script:sent=[System.Collections.Generic.List[string]]::new()
$script:shellEscapeFlags=[System.Collections.Generic.List[bool]]::new()
$script:utmCalls=[System.Collections.Generic.List[object]]::new()
$script:useUtmProvider=$false
$script:vncCalls=0
$script:waited=0
$script:captured=0
$script:failSend=0
function Get-FetchExecuteEnvPrefix { return 'EXEC_REQUIRE_SHA256=1 E_SHA=' + ('c' * 64) + ' E_RETRY_SHA=' + ('d' * 64) + ' E_FB_REPO=alissonsol/yurunadev E_FB_REF=933b9d5b0bee ' }
function Invoke-TypeDrainEnter {
    param($Context,$Text,$CharDelayMs,[switch]$ShellEscape)
    $script:sent.Add($Text)
    $script:shellEscapeFlags.Add([bool]$ShellEscape)
    if ($script:sent.Count -eq $script:failSend) { return $false }
    if ($script:useUtmProvider) {
        return Invoke-TestUtmProvider @{VMName=$Context.VMName;Text=$Text;CharDelayMs=$CharDelayMs;ShellEscape=[bool]$ShellEscape}
    }
    return $true
}
function Send-TextVNC { $script:vncCalls++; return $false }
function Send-TextUTM {
    param($VMName,$Text,$CharDelayMs,[switch]$ShellEscape)
    $script:utmCalls.Add(@{VMName=$VMName;Text=$Text;CharDelayMs=$CharDelayMs;ShellEscape=[bool]$ShellEscape})
    return $true
}
function Wait-ForText { param($FreshMatch,$EarlyFailurePattern,$FailurePattern) $script:waited++; $script:fresh=$FreshMatch; $script:early=$EarlyFailurePattern; $script:failure=$FailurePattern; return $true }
function Save-FetchExecutionEvidence { param($Context,$Succeeded,$ElapsedSeconds) $script:captured++; $script:succeeded=$Succeeded }
'@
        $helpers = (Get-FunctionSource 'Get-FetchExecutionCommand') + "`n" + (Get-FunctionSource 'Get-FetchObservationEnvPrefix') + "`n" + (Get-FunctionSource 'Get-GuiFetchExecutionInput')
        $script:handlerModule = New-Module -ScriptBlock ([scriptblock]::Create(
            $fixture + "`n" + $helpers + "`nfunction Invoke-TestUtmProvider $provider`nfunction Invoke-TestHandler $handler"))
    }

    BeforeEach {
        & $script:handlerModule {
            $script:sent.Clear();$script:shellEscapeFlags.Clear();$script:utmCalls.Clear()
            $script:waited=0;$script:captured=0;$script:failSend=0;$script:vncCalls=0;$script:useUtmProvider=$false
        }
        $script:handlerContext = @{HostType='host.macos.utm';VMName='vm';GuestKey='guest.ubuntu.server.26';StepInvocationId='9dd7e79e0e404f0b8aa334f1337540e9';SequenceInvocationId='2ba53dd6961e4beea8ec17e8416f8651';
            Step=@{text=$script:payload;waitPattern='FETCHED AND EXECUTED:';timeoutSeconds=1200;freshMatchTailLines=60};
            Vars=@{};ExpandVariable={param($value,$vars) $null=$vars; $value};DefaultTimeoutSeconds=1;DefaultPollSeconds=1}
    }

    It 'sends bounded GUI lines and preserves the existing completion and failure monitor' {
        $result = @(& $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext)
        $result | Should -HaveCount 1
        $result[0] | Should -BeTrue
        & $script:handlerModule {
            $script:sent | Should -HaveCount 4
            foreach ($line in $script:sent) { $line.Length | Should -BeLessOrEqual 400 }
            @($script:shellEscapeFlags | Where-Object { $_ }) | Should -HaveCount 0
            $script:waited | Should -Be 1
            $script:fresh | Should -BeTrue
            $script:early | Should -Contain 'command not found'
            $script:failure | Should -Contain 'NONZERO SCRIPT EXIT:'
            $script:captured | Should -Be 1
            $script:succeeded | Should -BeTrue
        }
    }

    It 'passes every staged line literally through the UTM fallback when VNC fails' {
        & $script:handlerModule { $script:useUtmProvider=$true }
        $result = & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext
        $result | Should -BeTrue
        & $script:handlerModule {
            $script:vncCalls | Should -Be 4
            $script:utmCalls | Should -HaveCount 4
            for ($index = 0; $index -lt $script:sent.Count; $index++) {
                $script:utmCalls[$index].Text | Should -BeExactly $script:sent[$index]
                $script:utmCalls[$index].ShellEscape | Should -BeFalse
                $script:utmCalls[$index].VMName | Should -Be 'vm'
            }
            $script:waited | Should -Be 1
        }
    }

    It 'keeps shell escaping enabled for a short macOS command and its UTM fallback' {
        $script:handlerContext.Step.text='echo ready'
        & $script:handlerModule { $script:useUtmProvider=$true }
        $result = & $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext
        $result | Should -BeTrue
        & $script:handlerModule {
            $script:sent | Should -HaveCount 1
            $script:shellEscapeFlags[0] | Should -BeTrue
            $script:vncCalls | Should -Be 1
            $script:utmCalls[0].Text | Should -BeExactly $script:sent[0]
            $script:utmCalls[0].ShellEscape | Should -BeTrue
        }
    }

    It 'never submits the execution guard after a preparation-send failure' {
        & $script:handlerModule { $script:failSend=2 }
        $result = @(& $script:handlerModule {param($c) Invoke-TestHandler $c} $script:handlerContext)
        $result | Should -HaveCount 1
        $result[0] | Should -BeFalse
        & $script:handlerModule {
            $script:sent | Should -HaveCount 2
            ($script:sent -join "`n") | Should -Not -Match 'eval'
            $script:waited | Should -Be 0
            $script:captured | Should -Be 1
            $script:succeeded | Should -BeFalse
        }
    }

    It 'leaves another host GUI transport on its existing single-command path' {
        $script:handlerContext.HostType='host.windows.hyper-v'
        $result = & $script:handlerModule {param($c) Invoke-TestHandler $c -WarningAction SilentlyContinue} $script:handlerContext
        $result | Should -BeTrue
        & $script:handlerModule {
            $script:sent | Should -HaveCount 1
            $script:shellEscapeFlags[0] | Should -BeTrue
            $script:waited | Should -Be 1
        }
    }
}
