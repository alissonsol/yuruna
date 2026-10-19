<#PSScriptInfo
.VERSION 2026.10.18.2
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
    # The wrapper writes its recorder folder and trace under the guest's /tmp
    # and names both in its log; a guest prunes them on its next run, so a test
    # that runs the wrapper here removes them itself, on every path.
    function Remove-WrapperTmpArtifact {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes only /tmp artifacts a fixture run named in its own log.')]
        [CmdletBinding()]
        param([string]$LogPath)
        if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return }
        foreach ($line in @(Get-Content -LiteralPath $LogPath)) {
            if ($line -match '^# (?:recorder|profile):\s*(/tmp/yuruna-fae-(?:recorder|profile)\.[A-Za-z0-9]+)\s*$') {
                Remove-Item -LiteralPath $Matches[1] -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
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
    . ([scriptblock]::Create((Get-ObservationFunction $script:handlerAst 'Get-FetchExecutionCommand')))
    . ([scriptblock]::Create((Get-ObservationFunction $script:handlerAst 'Get-FetchExecutionContext')))
    $script:NonzeroScriptExitSentinel = 'NONZERO SCRIPT EXIT:'
}

Describe 'Diagnostic completeness and ordering' {
    It 'bounds stalled address discovery before starting any evidence SSH command' {
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
                $result.timedOut | Should -BeTrue
                if ($keep) {
                    $result.output | Should -Match '/proc/stat partial'
                    $result.output | Should -Match 'partial stderr'
                } else {
                    $result.output | Should -Not -Match '/proc/stat partial|partial stderr'
                    $result.output | Should -Not -BeNullOrEmpty
                }
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
        $manifest=& $script:diagModule {
            param($OutputFolder)
            Save-GuestDiagnosticCore -VMName test-vm -GuestKey guest.ubuntu.server.26 -OutputFolder $OutputFolder -Id test `
                -StepInvocationId step-1 -SequenceInvocationId sequence-1
        } $TestDrive
        ($script:observedOrder -join ',') | Should -Be 'host,guest-short,guest-full'
        $manifest.diagnosticOutcome | Should -Be 'timeout'
        $manifest.stepInvocationId | Should -Be 'step-1'
        $manifest.hostSnapshot.Path | Should -Be 'host.json'
        $manifest.guestSnapshot.outPath | Should -Be 'short.txt'
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
        $context = @{Step=@{sensitive=$true};StepInvocationId='sensitive-step';SequenceInvocationId='sensitive-sequence'}
        $fields = (Get-FetchExecutionContext -Context $context -CommandLine 'true').Fields
        $fields.EXEC_PROFILE | Should -BeExactly '0'
        $fields.EXEC_KEEP_PROFILE | Should -BeExactly '0'
        $fields.E_SI | Should -BeExactly 'sensitive-step'
        $fields.E_QI | Should -BeExactly 'sensitive-sequence'
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
function Get-FetchExecutionContext { param($Context,$CommandLine) $null=$Context;$null=$CommandLine; return [pscustomobject]@{Command='yfe 7c4e2a91b80 bash -c true';Launch='yfe 7c4e2a91b80 bash -c true'} }
function Get-GuiFetchExecutionInput { param($CommandLine) return $CommandLine }
function Get-GuiFetchEnvelopeInput { param($FetchContext,$CommandLine) $null=$FetchContext;$null=$CommandLine; return @() }
function Test-GuiFetchEnvelopeSupported { param($Context) $null=$Context; return $false }
function Invoke-TypeDrainEnter { param($Context,$Text) $script:sent=$Text; $script:order+='execute'; return $true }
function Wait-ForText { return $false }
function Get-GuestRunToken { return 'detached' }
function Invoke-GuestSsh { param($Command) $script:sent=$Command; $script:order+='execute'; return @{success=$false;addressResolved=$true;exitCode=7;output='YURUNA_EXECUTION stepInvocationId=original sequenceInvocationId=prior'} }
function Publish-GuestRetryMarker { return 0 }
function Test-GuestPayloadUnavailable { return $false }
function Save-FetchExecutionEvidence { param($Context,$Succeeded,$ElapsedSeconds) $script:order+='capture'; $script:succeeded=$Succeeded }
'@
            $charDelayHelper=Get-ObservationFunction $script:handlerAst 'Resolve-SequenceCharDelay'
            $module=New-Module -ScriptBlock ([scriptblock]::Create($charDelayHelper+"`n"+$fixture+"`nfunction Invoke-TestHandler $handler"))
            $context=@{VMName='vm';GuestKey='guest.ubuntu.server.26';StepInvocationId='current';SequenceInvocationId='sequence';
                Step=@{text='fetch-and-execute.sh guest/test.sh';command='fetch-and-execute.sh guest/test.sh';waitPattern='complete'};
                Vars=@{};ExpandVariable={param($value,$vars) $null=$vars; $value};DefaultTimeoutSeconds=1;DefaultPollSeconds=1}
            $result=& $module {param($c) Invoke-TestHandler $c} $context
            $result | Should -BeFalse
            & $module {
                ($script:order -join ',') | Should -Be 'execute,capture'
                $script:sent | Should -Match '^yfe [0-9a-f]{11} '
                $script:succeeded | Should -BeFalse
            }
            if ($action -eq 'sshFetchAndExecute') {
                $context.CheckpointSourceStepInvocationId | Should -Be 'original'
                $context.CheckpointSourceSequenceInvocationId | Should -Be 'prior'
            }
        }
    }

    It 'preserves a matching bounded trace and rejects a stale invocation log' -Skip:(-not $IsLinux) {
        $script:profileProbeLog=Join-Path $TestDrive 'execution.log'
        # The guest probe reads a profile only from /tmp, which the suite's own temp folder is not.
        $trace=Join-Path '/tmp' ('yuruna-fae-profile.'+[guid]::NewGuid().ToString('N'))
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
        $fields=(Get-FetchExecutionContext -Context @{Step=@{};StepInvocationId='step-3';SequenceInvocationId='sequence-3'} -CommandLine 'true').Fields
        $fields.EXEC_KEEP_PROFILE | Should -BeExactly '1'
        $fields.E_SI | Should -BeExactly 'step-3'
        $fields.E_QI | Should -BeExactly 'sequence-3'
        $bad=(Get-FetchExecutionContext -Context @{Step=@{};StepInvocationId='$(touch unwanted)';SequenceInvocationId='bad;value'} -CommandLine 'true').Fields
        $bad.Contains('E_SI') | Should -BeFalse
        $bad.Contains('E_QI') | Should -BeFalse
    }

    It 'fetches slow successes and all failures immediately, without delaying fast success' {
        $module=New-Module -ScriptBlock ([scriptblock]::Create(@'
$script:calls=@()
function Get-CycleGuestDataFolder { param($VMName) return 'fixture' }
function Save-GuestExecutionProfile { param($VMName,$GuestKey,$OutputFolder,$StepInvocationId,$TimeoutSeconds,$Variables,$ScriptPath,$SequenceInvocationId) $script:calls+=@{id=$StepInvocationId;budget=$TimeoutSeconds;path=$ScriptPath;sequence=$SequenceInvocationId}; return @{success=$true} }
'@ + "`n"+(Get-ObservationFunction $script:handlerAst 'Save-FetchExecutionEvidence')))
        & $module {
            $context=@{StepInvocationId='current';SequenceInvocationId='current-sequence';FetchExecutionPath='guest/test.sh';VMName='vm';GuestKey='guest.ubuntu.server.26'}
            Save-FetchExecutionEvidence -Context $context -Succeeded $true -ElapsedSeconds 59
            Save-FetchExecutionEvidence -Context $context -Succeeded $true -ElapsedSeconds 60
            $context.CheckpointSourceStepInvocationId='original'
            $context.CheckpointSourceSequenceInvocationId='original-sequence'
            Save-FetchExecutionEvidence -Context $context -Succeeded $false -ElapsedSeconds 1
            $script:calls.Count | Should -Be 2
            $script:calls[0].id | Should -Be 'current'
            $script:calls[1].id | Should -Be 'original'
            $script:calls[0].budget | Should -Be 20
            $script:calls[0].path | Should -Be 'guest/test.sh'
            $script:calls[1].path | Should -Be 'guest/test.sh'
            $script:calls[0].sequence | Should -Be 'current-sequence'
            $script:calls[1].sequence | Should -Be 'original-sequence'
        }
    }

    It 'posts SSH-equivalent checkpoint IDs and keeps the trace on success and failure' -Skip:(-not $IsLinux) {
        $wrapper=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $tail=$wrapper.Substring($wrapper.IndexOf('# --- REGION: Execute payload'))
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
fae_log='__LOG__'
printf '# Yuruna fetch-and-execute log\n# script: guest/test.sh\n# stepInvocationId: %s\n# sequenceInvocationId: %s\n# ---\n' "$E_SI" "$E_QI" > "$fae_log"
wget() { local arg; for arg in "$@"; do case "$arg" in --post-file=*) cp -- "${arg#*=}" '__POST__';; esac; done; }
'@
            [IO.File]::WriteAllText($scriptPath,$preamble.Replace('__EXIT__',[string]$exitCode).Replace('__POST__',$post).Replace('__LOG__',$log)+"`n"+$tail)
            try {
                $output=& bash $scriptPath
                $LASTEXITCODE | Should -Be $exitCode
                ($output -join "`n") | Should -Match 'YURUNA_EXECUTION stepInvocationId=step-test sequenceInvocationId=sequence-test'
                $checkpoint=Get-Content $post -Raw | ConvertFrom-Json
                $checkpoint.stepInvocationId | Should -Be 'step-test'
                $checkpoint.sequenceInvocationId | Should -Be 'sequence-test'
                $checkpoint.checkpoints[0].name | Should -Be 'first phase'
                $profileArtifact=(Get-Content $log | Where-Object {$_ -match '^# profile:'}) -replace '^# profile:\s*',''
                Test-Path $profileArtifact | Should -BeTrue
            } finally {
                Remove-WrapperTmpArtifact -LogPath $log
            }
        }
    }
}

Describe 'Prearmed guest flight recorder' {
    It 'uploads bounded, redacted process evidence while the payload is still blocked' -Skip:(-not $IsLinux) {
        $fixture=Join-Path $TestDrive 'recorder-live'
        [void][IO.Directory]::CreateDirectory($fixture)
        $bin=Join-Path $fixture 'bin'
        [void][IO.Directory]::CreateDirectory($bin)
        $upload=Join-Path $fixture 'uploaded.txt'
        $uploadClock=Join-Path $fixture 'uploaded.utc'
        $stub=@'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in --post-file=*) cp -- "${arg#*=}" '__UPLOAD__'; date -u +%s%N > '__CLOCK__';; esac
done
'@
        [IO.File]::WriteAllText((Join-Path $bin 'wget'),$stub.Replace('__UPLOAD__',$upload).Replace('__CLOCK__',$uploadClock))
        & chmod +x (Join-Path $bin 'wget')
        $wrapper=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $tail=$wrapper.Substring($wrapper.IndexOf('# --- REGION: Execute payload'))
        $log=Join-Path $fixture 'wrapper.log'
        $ended=Join-Path $fixture 'payload-ended.utc'
        $preamble=@'
FILE_PATH=guest/test.sh
FULL_URL=http://fixture/guest/test.sh
HOST_BASE=http://fixture/yuruna-repo/
BASE_SOURCE=host
byte_count=42
E_SI=recorder-live-test
E_QI=recorder-live-sequence
EXEC_KEEP_PROFILE=1
EXEC_RECORDER_INTERVAL_SECONDS=1
EXEC_RECORDER_MAX_SAMPLES=2
E_RECORDER_PATH=diagnostics/cycle/vm/execution.system.diagnostic.recorder-live-test.txt
export PATH='__BIN__':"$PATH"
export GH_TOKEN=fixture-recorder-private-token
script_content='printf "payload began\n"; sleep 4; date -u +%s%N > "__ENDED__"; exit 7'
fae_log='__LOG__'
printf '# Yuruna fetch-and-execute log\n# script: guest/test.sh\n# stepInvocationId: %s\n# sequenceInvocationId: %s\n# ---\n' "$E_SI" "$E_QI" > "$fae_log"
'@
        $scriptPath=Join-Path $fixture 'run.sh'
        [IO.File]::WriteAllText($scriptPath,$preamble.Replace('__BIN__',$bin).Replace('__ENDED__',$ended).Replace('__LOG__',$log)+"`n"+$tail)
        try {
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $output=& bash $scriptPath
            $LASTEXITCODE | Should -Be 7
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 8
            ($output -join "`n") | Should -Match 'NONZERO SCRIPT EXIT:'
            Test-Path $upload | Should -BeTrue
            [long](Get-Content $uploadClock) | Should -BeLessThan ([long](Get-Content $ended))
            (Get-Item $upload).Length | Should -BeLessThan 1100000
            $captured=Get-Content $upload -Raw
            $captured | Should -Match 'recorderSchema=1'
            $captured | Should -Match 'stepInvocationId=recorder-live-test'
            $captured | Should -Match '/proc/sys/kernel/random/boot_id'
            $captured | Should -Match '/proc/uptime'
            $captured | Should -Match 'per-thread CPU/state'
            $captured | Should -Match '--- network ---'
            $captured | Should -Match '--- ip -4 route ---'
            $captured | Should -Match '--- /proc/net/dev ---'
            $captured | Should -Match '--- systemd-networkd journal ---'
            $vmbusDevices=[Math]::Min(64,@(Get-ChildItem -LiteralPath /sys/bus/vmbus/devices -ErrorAction SilentlyContinue).Count)
            $captured | Should -Match "vmbusDeviceSamples=$vmbusDevices cap=64"
            $captured | Should -Not -Match 'fixture-recorder-private-token'
            $recorder=(Get-Content $log | Where-Object {$_ -match '^# recorder:'}) -replace '^# recorder:\s*',''
            $deadline=[Diagnostics.Stopwatch]::StartNew()
            do {
                $status=Get-Content (Join-Path $recorder 'status') -Raw
                $kernelStatus=if (Test-Path (Join-Path $recorder 'kernel.status')) { Get-Content (Join-Path $recorder 'kernel.status') -Raw } else { '' }
                if ($status -match 'state=stopped' -and ($status -match 'upload=complete' -or $kernelStatus -match 'state=stopped.*upload=complete')) { break }
                Start-Sleep -Milliseconds 100
            } while ($deadline.Elapsed.TotalSeconds -lt 10)
            $status | Should -Match 'state=stopped samples=2 upload=(complete|delegated-kernel)'
            if ($status -match 'upload=delegated-kernel') { $kernelStatus | Should -Match 'state=stopped.*upload=complete' }
        } finally {
            Remove-WrapperTmpArtifact -LogPath $log
        }
    }

    It 'filters known credentials, assignments, authorization, and multiline private keys before retention' -Skip:(-not $IsLinux) {
        $source=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $redactor=[regex]::Match($source,'(?ms)^fae_recorder_redact\(\) \{.*?^\}').Value
        $probe=Join-Path $TestDrive 'redactor.sh'
        $inputText=@'
ordinary CPU sample
kernel mentions fixture-secret-value
kernel mentions second-secret-line
PASSWORD=something
Authorization: bearer confidential
-----BEGIN RSA PRIVATE KEY-----
key bytes
-----END RSA PRIVATE KEY-----
ordinary final sample
'@
        [IO.File]::WriteAllText($probe,$redactor+"`nexport RECORDER_SECRET=$'fixture-secret-value\nsecond-secret-line'`n"+"fae_recorder_redact <<'INPUT'`n"+$inputText+"`nINPUT`n")
        $safe=(& bash $probe) -join "`n"
        $LASTEXITCODE | Should -Be 0
        $safe | Should -Not -Match 'fixture-secret-value|second-secret-line|something|confidential|key bytes'
        $safe | Should -Match 'ordinary CPU sample'
        $safe | Should -Match 'ordinary final sample'
    }

    It 'samples runnable, blocked, and CPU-heavy sleeping threads with a bounded stack count' -Skip:(-not $IsLinux) {
        $source=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $collector=([regex]::Match($source,'(?ms)^guest_evidence_clock\(\) \{.*?^\}').Value)+"`n"+([regex]::Match($source,'(?ms)^fae_recorder_collect\(\) \{.*?^\}').Value)
        $probe=Join-Path $TestDrive 'thread-probe.sh'
        $fixture=@'
fae_recorder_read() { printf 'read=%s\n' "$1"; }
ps() { printf '101 111 0 0.0 R runnable\n102 112 1 0.0 D blocked\n103 113 1 40.0 S cpu-heavy\n104 114 1 0.0 S asleep\n'; }
journalctl() { :; }
fae_recorder_collect
'@
        [IO.File]::WriteAllText($probe,$collector+"`n"+$fixture)
        $sample=(& bash $probe) -join "`n"
        $sample | Should -Match 'read=/proc/101/task/111/stack'
        $sample | Should -Match 'read=/proc/102/task/112/stack'
        $sample | Should -Match 'read=/proc/103/task/113/stack'
        $sample | Should -Not -Match 'read=/proc/104/task/114/stack'
        $sample | Should -Match 'threadStackSamples=3 cap=16'
    }

    It 'retains an explicit SSH failure and independently discovers a prior recorder upload' {
        $fixture=Join-Path $TestDrive 'recorder-fallback'
        [void][IO.Directory]::CreateDirectory($fixture)
        $artifact=Join-Path $fixture 'execution.system.diagnostic.failed-step.txt'
        [IO.File]::WriteAllText($artifact,"recorderSchema=1`nstepInvocationId=failed-step`nheartbeatUtc=$([datetime]::UtcNow.AddMinutes(-2).ToString('o'))`nsampleIndex=3")
        $module=New-Module -ScriptBlock ([scriptblock]::Create(@'
function Get-CycleGuestDataFolder { param($VMName) return $script:fixture }
function Save-GuestExecutionProfile { param($VMName,$GuestKey,$OutputFolder,$StepInvocationId,$TimeoutSeconds) return @{success=$false;diagnosticOutcome='unavailable';reasonCode='profile-ssh-timeout';sshResponsive=$false;outPath=$null} }
'@ + "`n"+(Get-ObservationFunction $script:handlerAst 'Save-FetchExecutionEvidence')))
        & $module {param($f) $script:fixture=$f} $fixture
        $context=@{Step=@{};StepInvocationId='failed-step';VMName='vm';GuestKey='guest.ubuntu.server.26';Vars=@{}}
        & $module {param($c) Save-FetchExecutionEvidence -Context $c -Succeeded $false -ElapsedSeconds 1} $context
        $context.ExecutionProfile.reasonCode | Should -Be 'profile-ssh-timeout'
        $context.ExecutionProfile.recorder.outPath | Should -Be $artifact
        $context.ExecutionProfile.recorder.heartbeatAgeSeconds | Should -BeGreaterThan 110
        $manifest=Get-Content (Join-Path $fixture 'fetch-and-execute.failed-step.evidence.json') -Raw | ConvertFrom-Json
        $manifest.recorder.reasonCode | Should -Be 'recorder-upload-retained'
    }

    It 'reports missing profile files distinctly from SSH timeout and mismatched invocation' {
        foreach ($case in @(
            @{Output='profile execution log absent';Exit=66;Reason='profile-file-absent';Responsive=$true},
            @{Output='profile invocation mismatch: previous';Exit=65;Reason='profile-invocation-mismatch';Responsive=$true},
            @{Output='Timed out after 20s';Exit=-1;Reason='profile-ssh-timeout';Responsive=$false}
        )) {
            $script:profileFailureCase=$case
            Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic { return @{success=$false;output=$script:profileFailureCase.Output;exitCode=$script:profileFailureCase.Exit} }
            $capture=Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId failed
            $capture.reasonCode | Should -Be $case.Reason
            $capture.sshResponsive | Should -Be $case.Responsive
            $capture.diagnosticOutcome | Should -Be 'unavailable'
        }
    }
}

Describe 'Recorder context delivery' {
    It 'uses the runner-created cycle folder and excludes sensitive invocations' {
        $functions=(Get-ObservationFunction $script:handlerAst 'Get-FetchExecutionCommand')+"`n"+(Get-ObservationFunction $script:handlerAst 'Get-FetchExecutionContext')
        $module=New-Module -ScriptBlock ([scriptblock]::Create(@'
function Get-CycleGuestDataFolder { param($VMName) return '/tmp/log/42.incomplete/test-vm' }
$script:NonzeroScriptExitSentinel='NONZERO SCRIPT EXIT:'
function Resolve-StatusServiceEndpoint { throw 'Host-driver discovery must not run while building a fetch context.' }
'@+"`n"+$functions))
        $context=@{VMName='test-vm';Step=@{};StepInvocationId='step-42';SequenceInvocationId='sequence-42'}
        $built=& $module {param($c) Get-FetchExecutionContext -Context $c -CommandLine true} $context
        $built.Fields.E_RECORDER_PATH | Should -BeExactly 'diagnostics/42.incomplete/test-vm/execution.system.diagnostic.step-42.txt'
        $context.RecorderArtifactPath | Should -BeExactly (Join-Path '/tmp/log/42.incomplete/test-vm' 'execution.system.diagnostic.step-42.txt')
        $context.Step.sensitive=$true
        $sensitive=& $module {param($c) Get-FetchExecutionContext -Context $c -CommandLine true} $context
        $sensitive.Fields.EXEC_RECORDER | Should -BeExactly '0'
        $sensitive.Fields.Contains('E_RECORDER_URL') | Should -BeFalse
        $sensitive.Fields.Contains('E_RECORDER_PATH') | Should -BeFalse
    }

    It 'delivers validated recorder destinations as data and rejects unsafe destination syntax' -Skip:(-not $IsLinux) {
        $launcher=Join-Path $repo 'automation/yuruna-fetch-context.sh'
        $command='printf "%s" "${E_RECORDER_PATH:-${E_RECORDER_URL:-}}"'
        $hasher=[Security.Cryptography.SHA256]::Create()
        try { $commandHash=[Convert]::ToHexString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($command))).ToLowerInvariant() }
        finally { $hasher.Dispose() }
        foreach ($url in @(
            'http://fixture:8080/diagnostics/42.incomplete/vm/execution.system.diagnostic.step.txt',
            'http://fixture:8080/diagnostics/../vm/execution.system.diagnostic.step.txt',
            'http://fixture:8080/diagnostics/42/vm/execution.system.diagnostic.step.txt;touch-unwanted',
            'http://user:secret@fixture:8080/diagnostics/42/vm/execution.system.diagnostic.step.txt',
            'diagnostics/42.incomplete/vm/execution.system.diagnostic.step.txt',
            'diagnostics/../vm/execution.system.diagnostic.step.txt',
            'diagnostics/42/vm/execution.system.diagnostic.step.txt;touch-unwanted'
        )) {
            $values=[ordered]@{id='abcdef01234';cmd_sha=$commandHash;EXEC_KEEP_PROFILE='1'}
            $field=if ($url.StartsWith('http')) { 'E_RECORDER_URL' } else { 'E_RECORDER_PATH' }
            $values[$field]=$url
            $lines=@('YFE1')
            foreach ($key in $values.Keys) { $lines+="$key=$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($values[$key])))" }
            $bytes=[Text.Encoding]::UTF8.GetBytes(($lines -join "`n")+"`n")
            $hasher=[Security.Cryptography.SHA256]::Create()
            try { $digest=[Convert]::ToHexString($hasher.ComputeHash($bytes)).ToLowerInvariant() }
            finally { $hasher.Dispose() }
            $encoded=[Convert]::ToBase64String($bytes)
            $driver=Join-Path $TestDrive 'context-recorder.sh'
            $homeDir=Join-Path $TestDrive ('context-home-'+[guid]::NewGuid().ToString('N'))
            $script="export HOME='$homeDir'`nprintf '%s' '$encoded' | bash '$launcher' --prepare abcdef01234 $($bytes.Length) $digest || exit `$?`n"+
                "bash '$launcher' abcdef01234 bash -c '$command'`n"
            [IO.File]::WriteAllText($driver,$script)
            $result=(& bash $driver 2>&1) -join "`n"
            if ($url -in @('http://fixture:8080/diagnostics/42.incomplete/vm/execution.system.diagnostic.step.txt','diagnostics/42.incomplete/vm/execution.system.diagnostic.step.txt')) {
                $LASTEXITCODE | Should -Be 0
                $result | Should -BeExactly $url
            } else {
                $LASTEXITCODE | Should -Be 125
                $result | Should -Match 'YFE_CONTEXT_FIELD'
            }
        }
    }
}


Describe 'Recorder and profile execution bounds' {
    It 'kills a stalled collector without losing its earlier output or overrunning its budget' -Skip:(-not $IsLinux) {
        $source=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $begin=$source.IndexOf('fae_recorder_redact()')
        $end=$source.IndexOf("fae_recorder_folder=''")
        $functions=$source.Substring($begin,$end-$begin)
        $folder=Join-Path $TestDrive 'blocked-collector'
        [void][IO.Directory]::CreateDirectory($folder)
        $probe=Join-Path $TestDrive 'blocked-collector.sh'
        $fixture=@'
fae_recorder_collect() { printf 'sampleUtc=before-stall\n'; trap '' TERM; while :; do sleep 1; done; }
E_SI=blocked-collector
fae_recorder_loop "$BASHPID" '__FOLDER__' 1 1
'@
        [IO.File]::WriteAllText($probe,$functions+"`n"+$fixture.Replace('__FOLDER__',$folder))
        $clock=[Diagnostics.Stopwatch]::StartNew()
        & bash $probe 2>&1 | Out-Null
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 13
        $evidence=Get-Content (Join-Path $folder 'evidence.txt') -Raw
        $evidence | Should -Match 'sampleUtc=before-stall'
        $evidence | Should -Match 'sampleExitCode=(124|137)'
        $evidence | Should -Match 'recorderState=stopped'
        (Get-Item (Join-Path $folder 'evidence.txt')).Length | Should -BeLessThan 1100000
    }

    It 'does not confuse a command timeout argument or ordinary timeout text with an SSH timeout' {
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            return @{success=$true;exitCode=0;output="--- YURUNA EXECUTION LOG ---`ncommand timeout --signal=TERM 600 docker build`n--- YURUNA COMMAND PROFILE (last 400000 bytes) ---`n+ timeout 30 curl --connect-timeout 5"}
        }
        $capture=Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId timeout-argument
        $capture.success | Should -BeTrue
        $capture.timedOut | Should -BeFalse
        $capture.reasonCode | Should -Be 'profile-complete'
        $capture.diagnosticOutcome | Should -Be 'complete'
    }
}

Describe 'Recorder inherited output and retention limits' {
    It 'bounds a collector descendant that inherits stdout after its direct parent exits' -Skip:(-not $IsLinux) {
        $source=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $begin=$source.IndexOf('fae_recorder_redact()')
        $end=$source.IndexOf("fae_recorder_folder=''")
        $functions=$source.Substring($begin,$end-$begin)
        $folder=Join-Path $TestDrive 'inherited-pipe-collector'
        [void][IO.Directory]::CreateDirectory($folder)
        $probe=Join-Path $TestDrive 'inherited-pipe-collector.sh'
        $fixture=@'
fae_recorder_collect() {
    printf 'sampleUtc=before-descendant\n'
    sleep 60 &
}
E_SI=inherited-pipe-collector
fae_recorder_loop "$BASHPID" '__FOLDER__' 1 1
'@
        [IO.File]::WriteAllText($probe,$functions+"`n"+$fixture.Replace('__FOLDER__',$folder))
        $clock=[Diagnostics.Stopwatch]::StartNew()
        & bash $probe 2>&1 | Out-Null
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 13
        $evidence=Get-Content (Join-Path $folder 'evidence.txt') -Raw
        $evidence | Should -Match 'sampleUtc=before-descendant'
        $evidence | Should -Match 'sampleExitCode=(124|137)'
        $evidence | Should -Match 'recorderState=stopped'
    }

    It 'caps a noisy collector before retaining its evidence' -Skip:(-not $IsLinux) {
        $source=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $begin=$source.IndexOf('fae_recorder_redact()')
        $end=$source.IndexOf("fae_recorder_folder=''")
        $functions=$source.Substring($begin,$end-$begin)
        $folder=Join-Path $TestDrive 'noisy-collector'
        [void][IO.Directory]::CreateDirectory($folder)
        $probe=Join-Path $TestDrive 'noisy-collector.sh'
        $fixture=@'
fae_recorder_collect() { yes 'ordinary CPU sample'; }
E_SI=noisy-collector
fae_recorder_loop "$BASHPID" '__FOLDER__' 1 1
'@
        [IO.File]::WriteAllText($probe,$functions+"`n"+$fixture.Replace('__FOLDER__',$folder))
        & bash $probe 2>&1 | Out-Null
        (Get-Item (Join-Path $folder 'sample.0')).Length | Should -Be 131072
        $evidence=Get-Content (Join-Path $folder 'evidence.txt') -Raw
        $evidence | Should -Match 'sampleTruncated=true'
        (Get-Item (Join-Path $folder 'metadata.txt')).Length | Should -BeLessOrEqual 32768
        (Get-Item (Join-Path $folder 'evidence.txt')).Length | Should -BeLessThan (131072+32768+1024)
    }
}


Describe 'Multiline known guest evidence secrets' {
    It 'removes a configured secret spanning multiple trace lines' {
        $secret="known-secret-first-line`nknown-secret-second-line"
        $text="ordinary output`n+ printf '$secret'`nordinary final output"
        $safe=& $script:diagModule {param($t,$s) Protect-GuestEvidenceText -Text $t -Variables @{password=$s}} $text $secret
        $safe | Should -Not -Match 'known-secret-first-line|known-secret-second-line'
        $safe | Should -Match 'ordinary output'
        $safe | Should -Match 'ordinary final output'
    }
}

Describe 'Execution profile and recorder transfer capacity' {
    It 'requests enough SSH capacity for a full bounded recorder ring and command trace' {
        $script:largeProfileOutput="--- YURUNA EXECUTION LOG ---`n--- YURUNA COMMAND PROFILE (last 400000 bytes) ---`n"+(('x'*100+"`n")*4000)+"`n--- YURUNA RECORDER EVIDENCE ---`n"+(('y'*100+"`n")*11000)
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            param($MaxCapturedChars)
            if ($MaxCapturedChars -lt $script:largeProfileOutput.Length) {
                return @{success=$false;exitCode=0;outputTruncated=$true;output=$script:largeProfileOutput.Substring(0,$MaxCapturedChars)}
            }
            return @{success=$true;exitCode=0;outputTruncated=$false;output=$script:largeProfileOutput}
        }
        $capture=Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId large-recorder
        $capture.success | Should -BeTrue
        $capture.outputTruncated | Should -BeFalse
        (Get-Item $capture.outPath).Length | Should -BeGreaterThan 1500000
        Should -Invoke Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic -Times 1 -ParameterFilter { $MaxCapturedChars -eq 2097152 }
    }

    It 'preserves partial evidence and distinguishes an explicitly truncated transport' {
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            return @{success=$false;exitCode=0;outputTruncated=$true;output="--- YURUNA EXECUTION LOG ---`n--- YURUNA COMMAND PROFILE (last 400000 bytes) ---`npartial"}
        }
        $capture=Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId truncated-recorder
        $capture.success | Should -BeFalse
        $capture.outputTruncated | Should -BeTrue
        $capture.diagnosticOutcome | Should -Be 'partial'
        $capture.reasonCode | Should -Be 'profile-output-truncated'
        (Get-Content $capture.outPath -Raw) | Should -Match 'partial'
    }
}


Describe 'Evidence credential and tail boundaries' {
    It 'redacts a known multiline credential fragment when the trace begins after its first line' {
        $secret="known-first-secret-line`nknown-second-secret-line"
        $text="known-second-secret-line`n+ echo ordinary"
        $safe=& $script:diagModule {param($t,$s) Protect-GuestEvidenceText -Text $t -Variables @{password=$s}} $text $secret
        $safe | Should -Not -Match 'known-first-secret-line|known-second-secret-line'
        $safe | Should -Match 'ordinary'
    }

    It 'drops the initial partial trace line at the byte boundary while preserving following commands' -Skip:(-not $IsLinux) {
        $script:boundaryExecutionLog=Join-Path $TestDrive 'boundary-execution.log'
        # The guest probe reads a profile only from /tmp, which the suite's own temp folder is not.
        $tracePath=Join-Path '/tmp' ('yuruna-fae-profile.'+[guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tracePath,('x'*500000)+"known-private-suffix`n+ echo following-command`n")
        [IO.File]::WriteAllText($script:boundaryExecutionLog,"# stepInvocationId: boundary`n# profile: $tracePath`ncommand output")
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            param($Command)
            $probe=$Command.Replace('/tmp/yuruna-last-fetch-and-execute.log',$script:boundaryExecutionLog)
            $output=& bash -c $probe
            return @{success=($LASTEXITCODE -eq 0);exitCode=$LASTEXITCODE;output=($output -join "`n")}
        }
        try {
            $capture=Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId boundary
            $capture.success | Should -BeTrue
            $saved=Get-Content $capture.outPath -Raw
            $saved | Should -Not -Match 'known-private-suffix|xxxxxxxx'
            $saved | Should -Match 'following-command'
        } finally { Remove-Item -LiteralPath $tracePath }
    }
}


Describe 'Recorder decimal configuration' {
    It 'normalizes padded decimal cadence and sample limits while preserving the byte cap' -Skip:(-not $IsLinux) {
        $source=Get-Content (Join-Path $repo 'automation/fetch-and-execute.sh') -Raw
        $begin=$source.IndexOf('fae_recorder_redact()')
        $end=$source.IndexOf('# Profile Bash 5 payloads')
        $functions=$source.Substring($begin,$end-$begin)
        $probe=Join-Path $TestDrive 'decimal-recorder.sh'
        $logPath=Join-Path $TestDrive 'decimal-recorder.log'
        $fixture=@'
fae_recorder_collect() { yes 'ordinary CPU sample'; }
fae_log='__LOG__'
E_SI=decimal-recorder
EXEC_RECORDER_INTERVAL_SECONDS=08
EXEC_RECORDER_MAX_SAMPLES=01
fae_start_recorder
wait
printf '%s' "$fae_recorder_folder"
'@
        [IO.File]::WriteAllText($probe,$functions+"`n"+$fixture.Replace('__LOG__',$logPath))
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $folder=(& bash $probe 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
        try {
            $evidence=Get-Content (Join-Path $folder 'evidence.txt') -Raw
            $evidence | Should -Match 'intervalSeconds=8 maxSamples=1 '
            $evidence | Should -Match 'sampleIndex=0'
            $evidence | Should -Match 'sampleTruncated=true'
            (Get-Item (Join-Path $folder 'sample.0')).Length | Should -Be 131072
            (Get-Content (Join-Path $folder 'status') -Raw) | Should -Match 'state=stopped samples=1 '
        } finally { Remove-Item -LiteralPath $folder -Recurse -Force }
    }
}
