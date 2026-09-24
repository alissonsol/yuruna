<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42f463f6-e84a-4c17-b6df-5f7f46b59e05
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization diagnostic class schema pester
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
    Exercises diagnostic budgets, evidence identity, and privilege boundaries.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Force
    $script:diagModule = Get-Module Test.Diagnostic
    $script:handlerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1'),[ref]$null,[ref]$null)
    $script:diagnosticAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'automation/Get-SystemDiagnostic.ps1'),[ref]$null,[ref]$null)
    function Get-ObservationFunction {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='The AST predicate consumes Name.')]
        param($Ast,[string]$Name)
        $node=$Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name },$true)
        return $node.Extent.Text
    }
}

Describe 'Diagnostic completeness and ordering' {
    It 'bounds stalled address discovery before starting any evidence SSH command' -Skip:(-not $IsLinux) {
        $providerPath=Join-Path $TestDrive 'EvidenceAddressFixture.psm1'
        [IO.File]::WriteAllText($providerPath,"function Get-VMIp { Start-Sleep -Seconds 30; return '127.0.0.1' }; Export-ModuleMember -Function Get-VMIp")
        Import-Module $providerPath -Global -Force
        Mock 'Test.Ssh\Get-ProvenGuestAddress' -ModuleName Test.Diagnostic { return '' }
        Mock Test-Path -ModuleName Test.Diagnostic -ParameterFilter { $LiteralPath -like '*yuruna_ed25519' } { return $true }
        try {
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $result=& $script:diagModule { Invoke-GuestEvidenceSsh -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -Command true -TimeoutSeconds 3 }
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 4
            $result.success | Should -BeFalse
            $result.output | Should -Match 'guest address discovery'
        } finally { Remove-Module EvidenceAddressFixture -Force }
    }

    It 'preserves stdout and stderr from a killed SSH client only when requested' -Skip:(-not $IsLinux) {
        $nativeDir=Join-Path $TestDrive 'ssh-bin'
        [void][IO.Directory]::CreateDirectory($nativeDir)
        $native=Join-Path $nativeDir 'ssh'
        [IO.File]::WriteAllText($native,"#!/bin/bash`nprintf 'snapshotUtc=fixture\\n/proc/stat partial\\n'`nprintf 'partial stderr\\n' >&2`nsleep 30`n")
        & chmod +x $native
        $oldPath=$env:PATH
        try {
            $env:PATH=$nativeDir+[IO.Path]::PathSeparator+$oldPath
            foreach ($keep in @($true,$false)) {
                $clock=[Diagnostics.Stopwatch]::StartNew()
                $result=Test.Ssh\Invoke-GuestSsh -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -Command true `
                    -ResolvedAddress 127.0.0.1 -PrivateKeyPath fixture-key -TimeoutSeconds 1 -AddressWaitSeconds 0 -PreservePartialOutputOnTimeout:$keep
                $clock.Elapsed.TotalSeconds | Should -BeLessThan 4
                $result.success | Should -BeFalse
                if ($keep) {
                    $result.output | Should -Match '/proc/stat partial'
                    $result.output | Should -Match 'partial stderr'
                    $result.output | Should -Match 'Timed out after 1s'
                } else { $result.output | Should -Be 'Timed out after 1s' }
            }
        } finally { $env:PATH=$oldPath }
    }

    It 'distinguishes complete, partial, timeout, and unavailable captures' {
        foreach ($case in @(
            @{Text="state`nDiagnostics complete.";Success=$true;Expected='complete'},
            @{Text="# header`n========`n  CPU`n========`nCPU sample";Success=$false;Expected='partial'},
            @{Text="# header`nTimed out after 60s";Success=$false;Expected='timeout'},
            @{Text='';Success=$false;Expected='unavailable'},
            @{Text='Permission denied (publickey)';Success=$false;Expected='unavailable'},
            @{Text="========`n** ERROR in section 'CPU': unavailable`nDiagnostics complete.";Success=$true;Expected='partial'}
        )) {
            $path=Join-Path $TestDrive 'capture.txt'
            [IO.File]::WriteAllText($path,$case.Text)
            $actual=& $script:diagModule {param($p,$ok) Get-GuestDiagnosticOutcome -Manifest @{outPath=$p;success=$ok}} $path $case.Success
            $actual | Should -Be $case.Expected
        }
    }

    It 'saves the host artifact and short guest sample before the full guest ladder' {
        $script:observedOrder=[Collections.Generic.List[string]]::new()
        Mock Save-YurunaHostSampleSnapshot -ModuleName Test.Diagnostic {
            $script:observedOrder.Add('host')
            return [pscustomobject]@{Status='available';Path='host.json';Reason=''}
        }
        Mock Save-GuestPerformanceSnapshot -ModuleName Test.Diagnostic {
            $script:observedOrder.Add('guest-short')
            return @{diagnosticOutcome='complete';outPath='short.txt'}
        }
        Mock Invoke-GuestDiagnosticCapture -ModuleName Test.Diagnostic {
            $script:observedOrder.Add('guest-full')
            return @{success=$false;outPath=$null;reason='budget exhausted';bytes=0;mechanism='none'}
        }
        $manifest=Save-GuestDiagnostic -VMName test-vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -Id test `
            -StepInvocationId step-1 -SequenceInvocationId sequence-1
        ($script:observedOrder -join ',') | Should -Be 'host,guest-short,guest-full'
        $manifest.diagnosticOutcome | Should -Be 'timeout'
        $manifest.stepInvocationId | Should -Be 'step-1'
        $saved=Get-ChildItem -Path $TestDrive -Filter '*.manifest.json' | Select-Object -Last 1
        (Get-Content $saved.FullName -Raw | ConvertFrom-Json).diagnosticOutcome | Should -Be 'timeout'
    }

    It 'gives the short guest command a separate budget and no pwsh dependency' {
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            param($VMName,$GuestKey,$Command,$TimeoutSeconds )
            $null=$VMName; $null=$GuestKey
            $script:observedBudget=$TimeoutSeconds
            $script:observedCommand=$Command
            return @{success=$false;output="snapshotUtc=fixture`n/proc/stat partial`nTimed out after 3s";exitCode=-1}
        }
        $manifest=Save-GuestPerformanceSnapshot -VMName test-vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive `
            -TimeoutSeconds 3 -StepInvocationId step-2 -SequenceInvocationId sequence-2
        $script:observedBudget | Should -Be 3
        $script:observedCommand | Should -Match 'E_SI=step-2 E_QI=sequence-2 bash'
        $script:observedCommand | Should -Not -Match 'pwsh'
        (Get-Content $manifest.outPath -Raw) | Should -Match '/proc/stat partial'
        $manifest.diagnosticOutcome | Should -Be 'timeout'
        $manifest.hostClock.afterTicks | Should -BeGreaterOrEqual $manifest.hostClock.beforeTicks
        $manifest.hostClock.frequency | Should -BeGreaterThan 0
        $manifest.hostClock.beforeUtc | Should -Match 'Z$'
        $manifest.hostClock.afterUtc | Should -Match 'Z$'
    }
}

Describe 'Installer evidence privilege and read states' {
    It 'uses the existing privilege prefix and distinguishes read, empty, absent, and denied files' -Skip:(-not $IsLinux) {
        $prefix=Join-Path $TestDrive 'privilege.sh'
        $prefixLog=Join-Path $TestDrive 'privilege.calls'
        [IO.File]::WriteAllText($prefix, 'printf "called\n" >> "'+$prefixLog+'"'+"`n"+'exec "$@"'+"`n")
        $module=New-Module -ScriptBlock ([scriptblock]::Create(
            (Get-ObservationFunction $script:diagnosticAst 'Invoke-PrivProbe')+"`n"+(Get-ObservationFunction $script:diagnosticAst 'Read-LinuxDiagnosticFile')))
        & $module {param($p) $script:LinuxPriv=@('bash',$p)} $prefix
        $file=Join-Path $TestDrive 'curtin-install.log'
        [IO.File]::WriteAllText($file,"Retrying package download`nGH_TOKEN=fixture-seed-token")
        $r=& $module {param($p) Read-LinuxDiagnosticFile -Path $p} $file
        $r.State | Should -Be 'read'
        ($r.Lines -join "`n") | Should -Match 'Retrying'
        ($r.Lines -join "`n") | Should -Not -Match 'fixture-seed-token'
        $metadata=& $module {param($p) Read-LinuxDiagnosticFile -Path $p -MetadataOnly} $file
        ($metadata.Lines -join "`n") | Should -Not -Match 'Retrying'
        ($metadata.Lines -join "`n") | Should -Match 'bytes='
        [IO.File]::WriteAllText($file,'')
        (& $module {param($p) Read-LinuxDiagnosticFile -Path $p} $file).State | Should -Be 'empty'
        [IO.File]::WriteAllText($file,'private')
        & chmod 000 $file
        try { (& $module {param($p) Read-LinuxDiagnosticFile -Path $p} $file).State | Should -Be 'denied' }
        finally { & chmod 600 $file }
        Remove-Item $file
        (& $module {param($p) Read-LinuxDiagnosticFile -Path $p} $file).State | Should -Be 'absent'
        @(Get-Content $prefixLog).Count | Should -Be 5
    }
}

Describe 'Profile retention and invocation identity' {
    It 'redacts known credentials and disables traces for sensitive steps' {
        $text="+ GH_TOKEN=fictional-value`n+ printf '%s' vault-value`n+ authorization: bearer bearer-value`n+ echo ordinary"
        $safe=& $script:diagModule {param($t) Protect-GuestEvidenceText -Text $t -Variables @{password='vault-value'}} $text
        $safe | Should -Not -Match 'fictional-value|vault-value|bearer-value'
        $safe | Should -Match 'ordinary'
        $fn=[scriptblock]::Create((Get-ObservationFunction $script:handlerAst 'Get-FetchObservationEnvPrefix')+"`n"+'Get-FetchObservationEnvPrefix -Context $args[0]')
        (& $fn @{Step=@{sensitive=$true};ShowSensitive=$true;StepInvocationId='sensitive-step';SequenceInvocationId='sensitive-sequence'}) | Should -Be 'EXEC_PROFILE=0 EXEC_KEEP_PROFILE=0 E_SI=sensitive-step E_QI=sensitive-sequence '
    }

    It 'delivers integrity and profiling values through clear followed by the wrapper with quoted arguments' -Skip:(-not $IsLinux) {
        $stub=Join-Path $TestDrive 'fetch-and-execute.sh'
        [IO.File]::WriteAllText($stub, @'
#!/bin/bash
printf '%s\n' "$EXEC_KEEP_PROFILE" "$E_SI" "$E_QI" "$E_SHA" "$1"
'@)
        & chmod +x $stub
        $run=[scriptblock]::Create((Get-ObservationFunction $script:handlerAst 'Get-FetchExecutionCommand')+"`n"+'Get-FetchExecutionCommand -CommandLine $args[0] -EnvPrefix $args[1]')
        $command=& $run ("clear; '$stub' `"it's literal`"") 'EXEC_KEEP_PROFILE=1 E_SI=step E_QI=sequence E_SHA=digest '
        $output=& bash -c ('clear() { :; }; export -f clear; '+$command)
        $LASTEXITCODE | Should -Be 0
        ($output -join '|') | Should -Be "1|step|sequence|digest|it's literal"
    }

    It 'runs the real console and SSH handlers with retention armed before execution and collection afterward' {
        foreach ($action in @('fetchAndExecute','sshFetchAndExecute')) {
            $registration=$script:handlerAst.Find({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Register-SequenceAction' -and $n.Extent.Text.StartsWith("Register-SequenceAction -Name '$action'")},$true)
            $handler=($registration.CommandElements | Where-Object {$_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]} | Select-Object -Last 1).ScriptBlock.Extent.Text
            $fixture=@'
$script:Fail=@{}
$script:NonzeroScriptExitSentinel='NONZERO SCRIPT EXIT:'
$script:FetchExecuteTypedCharWarn=10000
$script:ShellRejectedCommandPattern=@('command not found')
$script:ShellRejectionWindowSeconds=20
$script:order=@()
function Get-FetchExecuteEnvPrefix { return '' }
function Invoke-TypeDrainEnter { param($Context,$Text) $script:sent=$Text; $script:order+='execute'; return $true }
function Wait-ForText { return $false }
function Get-GuestRunToken { return 'detached' }
function Invoke-GuestSsh { param($Command) $script:sent=$Command; $script:order+='execute'; return @{success=$false;addressResolved=$true;exitCode=7;output='YURUNA_EXECUTION stepInvocationId=original sequenceInvocationId=prior'} }
function Publish-GuestRetryMarker { return 0 }
function Test-GuestPayloadUnavailable { return $false }
function Save-FetchExecutionEvidence { param($Context,$Succeeded,$ElapsedSeconds) $script:order+='capture'; $script:succeeded=$Succeeded }
'@
            $module=New-Module -ScriptBlock ([scriptblock]::Create($fixture+"`n"+
                (Get-ObservationFunction $script:handlerAst 'Get-FetchExecutionCommand')+"`n"+
                (Get-ObservationFunction $script:handlerAst 'Get-FetchObservationEnvPrefix')+"`nfunction Invoke-TestHandler $handler"))
            $context=@{VMName='vm';GuestKey='guest.ubuntu.server.26';StepInvocationId='current';SequenceInvocationId='sequence';
                Step=@{text='fetch-and-execute.sh guest/test.sh';command='fetch-and-execute.sh guest/test.sh';waitPattern='complete'};
                Vars=@{};ExpandVariable={param($value,$vars) $null=$vars; $value};DefaultTimeoutSeconds=1;DefaultPollSeconds=1}
            $result=& $module {param($c) Invoke-TestHandler $c} $context
            $result | Should -BeFalse
            & $module {
                ($script:order -join ',') | Should -Be 'execute,capture'
                $script:sent | Should -Match '^EXEC_KEEP_PROFILE=1 E_SI=current E_QI=sequence '
                $script:succeeded | Should -BeFalse
            }
            if ($action -eq 'sshFetchAndExecute') { $context.CheckpointSourceStepInvocationId | Should -Be 'original' }
        }
    }

    It 'preserves a matching bounded trace and rejects a stale invocation log' -Skip:(-not $IsLinux) {
        $script:profileProbeLog=Join-Path $TestDrive 'execution.log'
        $trace=Join-Path ([IO.Path]::GetTempPath()) ('yuruna-fae-profile.'+[guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($trace,('x'*500000))
        [IO.File]::WriteAllText($script:profileProbeLog,"# stepInvocationId: current`n# profile: $trace`ncommand output")
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            param($Command)
            $probe=$Command.Replace('/tmp/yuruna-last-fetch-and-execute.log',$script:profileProbeLog)
            $output=& bash -c $probe
            return @{success=($LASTEXITCODE -eq 0);exitCode=$LASTEXITCODE;output=($output -join "`n")}
        }
        try {
            $r=Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId current
            $r.success | Should -BeTrue
            (Get-Item $r.outPath).Length | Should -BeLessThan 401000
            (Get-Content $r.outPath -Raw) | Should -Match '500000'
            $stale=Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId later
            $stale.success | Should -BeFalse
            $stale.outPath | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $trace }
    }

    It 'arms retention and threads the same identifiers into either transport' {
        $fn=[scriptblock]::Create((Get-ObservationFunction $script:handlerAst 'Get-FetchObservationEnvPrefix')+"`n"+'Get-FetchObservationEnvPrefix -Context $args[0]')
        $prefix=& $fn @{StepInvocationId='step-3';SequenceInvocationId='sequence-3'}
        $prefix | Should -Match 'EXEC_KEEP_PROFILE=1'
        $prefix | Should -Match 'E_SI=step-3'
        $prefix | Should -Match 'E_QI=sequence-3'
        $bad=& $fn @{StepInvocationId='$(touch unwanted)';SequenceInvocationId='bad;value'}
        $bad | Should -Be 'EXEC_KEEP_PROFILE=1 '
    }

    It 'fetches slow successes and all failures immediately, without delaying fast success' {
        $module=New-Module -ScriptBlock ([scriptblock]::Create(@'
$script:calls=@()
function Get-CycleGuestDataFolder { param($VMName) return 'fixture' }
function Save-GuestExecutionProfile { param($VMName,$GuestKey,$OutputFolder,$StepInvocationId,$TimeoutSeconds) $script:calls+=@{id=$StepInvocationId;budget=$TimeoutSeconds}; return @{success=$true} }
'@ + "`n"+(Get-ObservationFunction $script:handlerAst 'Save-FetchExecutionEvidence')))
        & $module {
            $context=@{StepInvocationId='current';VMName='vm';GuestKey='guest.ubuntu.server.26'}
            Save-FetchExecutionEvidence -Context $context -Succeeded $true -ElapsedSeconds 59
            Save-FetchExecutionEvidence -Context $context -Succeeded $true -ElapsedSeconds 60
            $context.CheckpointSourceStepInvocationId='original'
            Save-FetchExecutionEvidence -Context $context -Succeeded $false -ElapsedSeconds 1
            $script:calls.Count | Should -Be 2
            $script:calls[0].id | Should -Be 'current'
            $script:calls[1].id | Should -Be 'original'
            $script:calls[0].budget | Should -Be 20
        }
    }

    It 'posts SSH-equivalent checkpoint IDs and keeps the trace on success and failure' -Skip:(-not $IsLinux) {
        $wrapper=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $tail=$wrapper.Substring($wrapper.IndexOf("fae_log='/tmp/yuruna-last-fetch-and-execute.log'"))
        foreach ($exitCode in @(0,7)) {
            $fixture=Join-Path $TestDrive "wrapper-$exitCode"
            [void][IO.Directory]::CreateDirectory($fixture)
            $scriptPath=Join-Path $fixture 'run.sh'
            $log=Join-Path $fixture 'wrapper.log'
            $post=Join-Path $fixture 'checkpoints.json'
            $preamble=@'
FILE_PATH=guest/test.sh
FULL_URL=http://fixture/guest/test.sh
HOST_BASE=http://fixture/yuruna-repo/
BASE_SOURCE=host
byte_count=42
E_SI=step-test
E_QI=sequence-test
EXEC_KEEP_PROFILE=1
script_content='printf "==== first phase ====\n"; echo data; exit __EXIT__'
wget() { local arg; for arg in "$@"; do case "$arg" in --post-file=*) cp -- "${arg#*=}" '__POST__';; esac; done; }
'@
            [IO.File]::WriteAllText($scriptPath,$preamble.Replace('__EXIT__',[string]$exitCode).Replace('__POST__',$post)+"`n"+$tail.Replace("fae_log='/tmp/yuruna-last-fetch-and-execute.log'","fae_log='$log'"))
            $output=& bash $scriptPath
            $LASTEXITCODE | Should -Be $exitCode
            ($output -join "`n") | Should -Match 'YURUNA_EXECUTION stepInvocationId=step-test sequenceInvocationId=sequence-test'
            $checkpoint=Get-Content $post -Raw | ConvertFrom-Json
            $checkpoint.stepInvocationId | Should -Be 'step-test'
            $checkpoint.sequenceInvocationId | Should -Be 'sequence-test'
            $checkpoint.checkpoints[0].name | Should -Be 'first phase'
            $profileArtifact=(Get-Content $log | Where-Object {$_ -match '^# profile:'}) -replace '^# profile:\s*',''
            Test-Path $profileArtifact | Should -BeTrue
            Remove-Item -LiteralPath $profileArtifact
        }
    }
}
