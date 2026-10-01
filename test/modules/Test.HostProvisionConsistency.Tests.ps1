<#PSScriptInfo
.VERSION 2026.09.30
.GUID 427dc7e5-42e7-4d34-bef6-83be459c7402
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host provisioning consistency
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

<#
.SYNOPSIS
    Verify host provisioning failure boundaries without operating a hypervisor.
.DESCRIPTION
    Runs the service builders' disk-capacity gate in child PowerShell processes,
    exercises ISO adoption against temporary files, and calls the real provider
    lifecycle exports with module-local native-command stubs.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Pwsh = [Environment]::ProcessPath
    $script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-host-provision-' + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $script:FixtureRoot
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking

    function Invoke-ProvisionFixture {
        param([string]$Body, [string[]]$Argument = @())
        $fixture = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString() + '.ps1')
        # Extracted branches retain their production renderer dependency. Put
        # the import after any parameter block so child argument binding stays
        # identical to the original fixture.
        $ast = [Management.Automation.Language.Parser]::ParseInput($Body, [ref]$null, [ref]$null)
        $offset = if ($ast.ParamBlock) { $ast.ParamBlock.Extent.EndOffset } else { 0 }
        $adapter = (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1').Replace("'", "''")
        $Body = $Body.Insert($offset, "`nImport-Module '$adapter' -DisableNameChecking`n")
        Set-Content -LiteralPath $fixture -Value $Body -Encoding utf8
        $output = @(& $script:Pwsh -NoLogo -NoProfile -File $fixture @Argument 2>&1)
        return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }

    function Get-ProvisionAst {
        param([string]$Path)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        if ($errors) { throw "$Path does not parse: $($errors[0].Message)" }
        return $ast
    }

    function Get-EffectiveGuestBuilderSource {
        param([string]$Path)
        $source = Get-Content -LiteralPath $Path -Raw
        if ($source -match 'modules/New-UbuntuServerVM.ps1') {
            $shared = Join-Path (Split-Path (Split-Path $Path -Parent) -Parent) 'modules/New-UbuntuServerVM.ps1'
            return Get-Content -LiteralPath $shared -Raw
        }
        return $source
    }

    $script:ServiceBuilders = @(Get-ChildItem (Join-Path $script:RepoRoot 'host/*/guest.*-service/New-VM.ps1'))
    $script:GuestBuilders = @(Get-ChildItem (Join-Path $script:RepoRoot 'host/*/guest.*/New-VM.ps1'))
    $script:UtmFixture = @'
param([string]$ModulePath, [string]$Mode, [int]$NativeExitCode)
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
& $module {
    param($ExitCode)
    $script:NativeExitCode = $ExitCode
    $script:StopCalls = [Collections.Generic.List[string]]::new()
    $script:WatchdogStops = 0
    function script:Invoke-UtmctlLifecycle {
        param([string]$Verb, [string]$VMName, [switch]$Kill, $Deadline, [int]$TimeoutSeconds, [switch]$Quiet)
        $script:StopCalls.Add("$Verb $VMName$(if ($Kill) { ' --kill' })")
        return @{
            ExitCode = $script:NativeExitCode; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $true
            DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; DeadlineExhausted = $false
            Verb = $Verb; VMName = $VMName; Kill = [bool]$Kill; OutcomeKnown = $true; FailureKind = 'none'; Text = ''
        }
    }
    function script:Stop-UtmDialogWatchdog { $script:WatchdogStops++ }
    function script:Start-Sleep { param([int]$Seconds) }
} $NativeExitCode
$result = switch ($Mode) {
    'graceful' { Yuruna.Host\Stop-VM -VMName 'test-provision' -Confirm:$false }
    'force'   { Yuruna.Host\Stop-VM -VMName 'test-provision' -Force -Confirm:$false }
    'direct-force' { Yuruna.Host\Stop-VMForce -VMName 'test-provision' -Confirm:$false }
    'whatif'  { Yuruna.Host\Stop-VM -VMName 'test-provision' -Force -WhatIf }
    'direct-whatif' { Yuruna.Host\Stop-VMForce -VMName 'test-provision' -WhatIf }
}
$calls = @(& $module { $script:StopCalls.ToArray() })
$watchdogStops = & $module { $script:WatchdogStops }
@{ Result = [bool]$result; Calls = $calls; WatchdogStops = $watchdogStops } | ConvertTo-Json -Compress
'@
    $script:KvmFixture = @'
param([string]$ModulePath, [string]$Mode, [string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$vmDir = Join-Path $ScratchRoot 'test-provision'
$null = New-Item -ItemType Directory -Path $vmDir -Force
Set-Content -LiteralPath (Join-Path $vmDir 'disk.qcow2') -Value 'retained guest data'
& $module {
    param($Mode, $ScratchRoot)
    $script:FixtureMode = $Mode
    $script:VmRootDir = $ScratchRoot
    function script:virsh {
        $global:LASTEXITCODE = 1
        if ($args[2] -eq 'list' -and $script:FixtureMode -ne 'inventory-failed') {
            $global:LASTEXITCODE = 0
            if ($script:FixtureMode -eq 'present') { 'test-provision' }
        }
    }
} $Mode $ScratchRoot
$result = Yuruna.Host\Remove-VM -VMName 'test-provision' -Confirm:$false
@{ Result = [bool]$result; DiskExists = (Test-Path -LiteralPath (Join-Path $vmDir 'disk.qcow2')) } | ConvertTo-Json -Compress
'@
}

AfterAll {
    if ($script:FixtureRoot -and (Test-Path -LiteralPath $script:FixtureRoot)) {
        Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force
    }
}

Describe 'Per-guest builder log-module lifetime' {
    It 'uses the same feature-detected non-forcing log setup in every New-VM builder' {
        Assert-True ($script:GuestBuilders.Count -eq 25) 'all per-guest New-VM builders must be covered'
        $canonicalBlock = @'
# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }
'@
        foreach ($builder in $script:GuestBuilders) {
            $text = (Get-EffectiveGuestBuilderSource -Path $builder.FullName) -replace "`r`n", "`n"
            Assert-True ($text.Replace('$GuestScriptRoot', '$PSScriptRoot').Contains($canonicalBlock)) "$($builder.FullName) must reuse the loaded log module without -Force"
        }
    }
}

Describe 'Per-guest builder phase order' {
    It 'keeps the canonical host-independent provisioning subsequence in every New-VM builder' {
        $markers = @(
            '# --- REGION: Log level from environment',
            '# --- REGION: Seek the base image',
            '# --- REGION: Remove existing VM',
            '# --- REGION: Create copies and files for VM'
        )
        foreach ($builder in $script:GuestBuilders) {
            $text = Get-EffectiveGuestBuilderSource -Path $builder.FullName
            $previous = -1
            foreach ($marker in $markers) {
                $current = $text.IndexOf($marker, [StringComparison]::Ordinal)
                Assert-True ($current -gt $previous) "$($builder.FullName) must keep the ordered provisioning phase '$marker'"
                $previous = $current
            }
        }
    }

    It 'delays destructive KVM guest-disk replacement until seed generation succeeds' {
        $kvmDiskPhases = @{
            'host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1' = '# --- REGION: Copy base image -> per-VM disk'
            'host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1'  = '# --- REGION: Create empty install target'
            'host/ubuntu.kvm/guest.ubuntu.server.26/New-VM.ps1'  = '# --- REGION: Create empty install target'
        }
        foreach ($relativePath in $kvmDiskPhases.Keys) {
            $text = Get-EffectiveGuestBuilderSource -Path (Join-Path $script:RepoRoot $relativePath)
            $seedPhase = $text.IndexOf('# --- REGION: Generate cloud-init seed ISO', [StringComparison]::Ordinal)
            $diskPhase = $text.IndexOf($kvmDiskPhases[$relativePath], [StringComparison]::Ordinal)
            Assert-True ($seedPhase -ge 0 -and $diskPhase -gt $seedPhase) "$relativePath must preserve the prior disk until the seed preflight succeeds"
        }
    }
}

Describe 'Amazon Linux origin-listing boundary' {
    It 'makes every listing request terminating and rejects a missing qcow2 link explicitly' {
        $imageScripts = @(
            'host/windows.hyper-v/guest.amazon.linux.2023/Get-Image.ps1',
            'host/macos.utm/guest.amazon.linux.2023/Get-Image.ps1',
            'host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1'
        )
        foreach ($relativePath in $imageScripts) {
            $text = Get-EffectiveGuestBuilderSource -Path (Join-Path $script:RepoRoot $relativePath)
            Assert-Match '\$html\s*=\s*Invoke-WebRequest\s+-Uri\s+\$sourceUrl\s+-ErrorAction\s+Stop\b' $text "$relativePath must terminate when its origin listing request fails"
        }

        foreach ($hostName in @('macos.utm', 'ubuntu.kvm')) {
            $relativePath = "host/$hostName/guest.amazon.linux.2023/Get-Image.ps1"
            $text = Get-EffectiveGuestBuilderSource -Path (Join-Path $script:RepoRoot $relativePath)
            $ast = Get-ProvisionAst (Join-Path $script:RepoRoot $relativePath)
            $missing = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -match '^\s*-not\s+\$qcow2Link\s*$'
                }, $true)
            Assert-NotNull $missing "$relativePath must reject an absent qcow2 link"
            $body = '$qcow2Link = $null; $sourceUrl = "fixture://origin/"' + "`n" + $missing.Extent.Text + "`nWrite-Output 'AFTER_ORIGIN_GATE'"
            $result = Invoke-ProvisionFixture $body
            Assert-True ($result.ExitCode -ne 0) "$relativePath must fail before composing an absent qcow2 URL"
            Assert-False ($result.Output.Contains('AFTER_ORIGIN_GATE')) "$relativePath continued after an absent qcow2 link"
            Assert-True ($result.Output.Contains('No .qcow2 listed at fixture://origin/')) "$relativePath must name the missing image and origin"
        }
    }
}

Describe 'Download-agent artifact pattern' {
    BeforeAll {
        # One record per -ExpectedFilenamePattern argument that a Get-Image script
        # hands a download-agent call: the argument's AST and, when that is a
        # variable, the assignment that precedes the call in the script ($null
        # when there is none). An unassigned variable binds as an empty pattern,
        # which the agent reads as "no expectation" and accepts any artifact.
        function Get-AgentPatternArgument {
            param([string]$Path)
            $ast = Get-ProvisionAst $Path
            $calls = $ast.FindAll({ param($n)
                    $n -is [Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in @('Invoke-DownloadAgentFirst', 'Request-DownloadAgentImage')
                }, $true)
            foreach ($call in $calls) {
                $elements = $call.CommandElements
                for ($i = 0; $i -lt $elements.Count; $i++) {
                    $parameter = $elements[$i]
                    if ($parameter -isnot [Management.Automation.Language.CommandParameterAst] -or
                        $parameter.ParameterName -ne 'ExpectedFilenamePattern') { continue }
                    $value = if ($parameter.Argument) { $parameter.Argument } else { $elements[$i + 1] }
                    $assignment = $null
                    if ($value -is [Management.Automation.Language.VariableExpressionAst]) {
                        $name = $value.VariablePath.UserPath
                        $assignment = $ast.FindAll({ param($n)
                                $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                                $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                                $n.Left.VariablePath.UserPath -eq $name -and
                                $n.Extent.StartOffset -lt $call.Extent.StartOffset
                            }, $true) | Select-Object -First 1
                    }
                    [pscustomobject]@{ Command = $call.GetCommandName(); Value = $value; Assignment = $assignment }
                }
            }
        }
    }

    It 'assigns the variable a Get-Image script hands the agent as its artifact pattern before the call' {
        $checked = 0
        foreach ($file in Get-ChildItem (Join-Path $script:RepoRoot 'host/*/guest.*/Get-Image.ps1')) {
            foreach ($argument in @(Get-AgentPatternArgument $file.FullName)) {
                $checked++
                if ($argument.Value -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
                $name = $argument.Value.VariablePath.UserPath
                Assert-NotNull $argument.Assignment "$($file.FullName) hands $($argument.Command) `$$name but assigns it nowhere before the call, which switches the agent's artifact check off"
            }
        }
        Assert-True ($checked -ge 6) "each Amazon Linux 2023 and Windows 11 Get-Image script must state an artifact pattern; found $checked"
    }

    It 'gives every Amazon Linux 2023 host a pattern that accepts only the artifact it stages' {
        $cases = @(
            @{ Script = 'host/macos.utm/guest.amazon.linux.2023/Get-Image.ps1';       Extension = 'qcow2'; Refused = @('zip', 'vhdx') }
            @{ Script = 'host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1';      Extension = 'qcow2'; Refused = @('zip', 'vhdx') }
            @{ Script = 'host/windows.hyper-v/guest.amazon.linux.2023/Get-Image.ps1'; Extension = 'zip';   Refused = @('qcow2') }
            @{ Script = 'host/windows.hyper-v/guest.amazon.linux.2023/Get-Image.ps1'; Extension = 'qcow2'; Refused = @('zip') }
        )
        foreach ($case in $cases) {
            $argument = @(Get-AgentPatternArgument (Join-Path $script:RepoRoot $case.Script) |
                    Where-Object Command -eq 'Invoke-DownloadAgentFirst')
            Assert-True ($argument.Count -eq 1) "$($case.Script) must hand Invoke-DownloadAgentFirst exactly one artifact pattern"
            $expression = if ($argument[0].Assignment) { $argument[0].Assignment.Right.Extent.Text } else { $argument[0].Value.Extent.Text }
            # The Hyper-V pattern is built from the extension its architecture
            # branch picks; the macOS and KVM patterns ignore the parameter.
            $pattern = & ([scriptblock]::Create('param($downloadExtension)' + "`n" + $expression)) $case.Extension
            Assert-True (-not [string]::IsNullOrWhiteSpace($pattern)) "$($case.Script) must hand the agent a non-empty pattern; an empty one accepts any artifact"
            $stem = 'al2023-kvm-2023.9.20260101.0-kernel-6.1-x86_64'
            Assert-True ("$stem.$($case.Extension)" -match $pattern) "$($case.Script) must accept a .$($case.Extension) artifact (pattern '$pattern')"
            Assert-False ("$stem.$($case.Extension).sha256" -match $pattern) "$($case.Script) must refuse the checksum sidecar (pattern '$pattern')"
            foreach ($other in $case.Refused) {
                Assert-False ("$stem.$other" -match $pattern) "$($case.Script) must refuse a .$other artifact (pattern '$pattern')"
            }
        }
    }
}

Describe 'Service VM disk-capacity boundary' {
    It 'fails the child build before any later phase when expansion fails on every host' {
        Assert-True ($script:ServiceBuilders.Count -eq 12) 'all four service families on all three hosts must be covered'
        foreach ($builder in $script:ServiceBuilders) {
            $ast = Get-ProvisionAst $builder.FullName
            $call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Expand-ExtensionVmDisk' }, $true)
            Assert-NotNull $call "missing disk-capacity gate: $($builder.FullName)"
            $gate = $call
            while ($gate -and $gate -isnot [System.Management.Automation.Language.IfStatementAst]) { $gate = $gate.Parent }
            Assert-NotNull $gate "disk resize is not guarded by an if: $($builder.FullName)"
            $body = @'
$ErrorActionPreference = 'Continue'
$diskImg = $DiskImage = $vhdxFile = 'fixture-disk'
function Expand-ExtensionVmDisk { param($Path, $SizeBytes, $Format) return $false }
'@ + "`n" + $gate.Extent.Text + "`nWrite-Output 'AFTER_DISK_RESIZE'`nexit 0"
            $result = Invoke-ProvisionFixture $body
            Assert-True ($result.ExitCode -ne 0) "$($builder.FullName) must report a failed child build"
            Assert-False ($result.Output.Contains('AFTER_DISK_RESIZE')) "$($builder.FullName) continued after failed expansion"
            Assert-True ($result.Output.Contains('Could not resize')) "$($builder.FullName) must identify disk expansion as the failure"
        }
    }

    It 'continues after successful expansion on every host' {
        foreach ($builder in $script:ServiceBuilders) {
            $ast = Get-ProvisionAst $builder.FullName
            $gate = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Expand-ExtensionVmDisk' }, $true)
            while ($gate -and $gate -isnot [System.Management.Automation.Language.IfStatementAst]) { $gate = $gate.Parent }
            Assert-NotNull $gate "disk resize is not guarded by an if: $($builder.FullName)"
            $body = @'
$ErrorActionPreference = 'Stop'
$diskImg = $DiskImage = $vhdxFile = 'fixture-disk'
function Expand-ExtensionVmDisk { param($Path, $SizeBytes, $Format) return $true }
'@ + "`n" + $gate.Extent.Text + "`nWrite-Output 'AFTER_DISK_RESIZE'`nexit 0"
            $result = Invoke-ProvisionFixture $body
            Assert-True ($result.ExitCode -eq 0) "$($builder.FullName): $($result.Output)"
            Assert-True ($result.Output.Contains('AFTER_DISK_RESIZE')) "$($builder.FullName) did not continue after successful expansion"
        }
    }
}

Describe 'KVM Windows media adoption' {
    It 'rejects ARM-labeled media and accepts x64 or unlabeled media without changing their bytes' {
        $path = Join-Path $script:RepoRoot 'host/ubuntu.kvm/guest.windows.11/Get-Image.ps1'
        $ast = Get-ProvisionAst $path
        $candidate = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$candidate' }, $true)
        $adoption = $candidate
        while ($adoption -isnot [System.Management.Automation.Language.IfStatementAst]) { $adoption = $adoption.Parent }
        foreach ($case in @(
            @{ Name = 'Win11_English_Arm64.iso'; Adopt = $false },
            @{ Name = 'Win11_English_ARM64.iso'; Adopt = $false },
            @{ Name = 'Win11_English_x64.iso'; Adopt = $true },
            @{ Name = 'Win11_custom.iso'; Adopt = $true }
        )) {
            $downloadDir = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $downloadDir
            $baseImageName = 'host.ubuntu.kvm.guest.windows.11'
            $winIso = Join-Path $downloadDir "$baseImageName.iso"
            $original = Join-Path $downloadDir $case.Name
            Set-Content -LiteralPath $original -Value 'fixture ISO bytes' -NoNewline
            & ([scriptblock]::Create($adoption.Extent.Text)) | Out-Null
            Assert-True ((Test-Path -LiteralPath $winIso) -eq $case.Adopt) "wrong architecture decision for $($case.Name)"
            Assert-True ((Test-Path -LiteralPath $original) -ne $case.Adopt) "wrong adoption result for $($case.Name)"
            $retained = if ($case.Adopt) { $winIso } else { $original }
            Assert-StringEqual 'fixture ISO bytes' (Get-Content -LiteralPath $retained -Raw)
        }
    }
}

Describe 'UTM public Stop-VM contract' {
    It 'uses graceful stopping by default and kill stopping with Force' {
        $modulePath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('graceful', 'force', 'direct-force')) {
            $r = Invoke-ProvisionFixture $script:UtmFixture @($modulePath, $mode, '0')
            Assert-True ($r.ExitCode -eq 0) $r.Output
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-True $data.Result
            Assert-True ($data.Calls.Count -eq 1) $r.Output
            Assert-True ($data.WatchdogStops -eq 1) "$mode must stop the dialog watchdog once"
            $expected = if ($mode -eq 'graceful') { 'stop test-provision' } else { 'stop test-provision --kill' }
            Assert-StringEqual $expected $data.Calls[0]
        }
    }

    It 'propagates native failure from both stop modes' {
        $modulePath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('graceful', 'force', 'direct-force')) {
            $r = Invoke-ProvisionFixture $script:UtmFixture @($modulePath, $mode, '9')
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-False $data.Result $r.Output
            Assert-True ($data.Calls.Count -eq 1) $r.Output
            Assert-True ($data.WatchdogStops -eq 1) "$mode must stop the dialog watchdog even when utmctl fails"
        }
    }

    It 'does not invoke utmctl when Force is previewed with WhatIf' {
        $modulePath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('whatif', 'direct-whatif')) {
            $r = Invoke-ProvisionFixture $script:UtmFixture @($modulePath, $mode, '0')
            Assert-True ($r.ExitCode -eq 0) $r.Output
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-False $data.Result
            Assert-True ($data.Calls.Count -eq 0) $r.Output
            Assert-True ($data.WatchdogStops -eq 0) "$mode must leave the dialog watchdog running"
        }
    }
}

Describe 'KVM public Remove-VM absence proof' {
    It 'retains guest storage when failed undefine is followed by an unavailable inventory or a surviving domain' {
        $modulePath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
        foreach ($mode in @('inventory-failed', 'present')) {
            $scratchRoot = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
            $r = Invoke-ProvisionFixture $script:KvmFixture @($modulePath, $mode, $scratchRoot)
            Assert-True ($r.ExitCode -eq 0) $r.Output
            $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            Assert-False $data.Result $r.Output
            Assert-True $data.DiskExists 'failed inventory or a surviving VM cannot authorize disk deletion'
        }
    }

    It 'removes leftover storage when inventory confirms the domain is already absent' {
        $modulePath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
        $scratchRoot = Join-Path $script:FixtureRoot ([guid]::NewGuid().ToString())
        $r = Invoke-ProvisionFixture $script:KvmFixture @($modulePath, 'absent', $scratchRoot)
        Assert-True ($r.ExitCode -eq 0) $r.Output
        $data = ($r.Output -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        Assert-True $data.Result $r.Output
        Assert-False $data.DiskExists
    }
}
