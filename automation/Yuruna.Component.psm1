<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42eaea7b-b54f-495c-bbdc-838c8758fced
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Component
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
$validationModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Validation.psm1"
Import-Module -Name $validationModulePath
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-DynamicExpression")
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Result.psm1') -Global -Force
# New-YurunaTimestampedBackup: the shared timestamped-backup step, so the
# timestamp format cannot drift between the three publishers.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Common.psm1') -Global -Force
# Set-ExpandedVariableHashtable + Set-ExpandedResourcesOutput live in
# Yuruna.VariableExpansion. Component passes -NoExpand because its
# layering happens at the YAML level -- ExpandString here would
# interpolate against whatever happens to be in env at the moment,
# which is exactly what the layered model is meant to avoid.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.VariableExpansion.psm1') -Global -Force
# Registry-login dispatch wiring for the component-push pipeline --
# see docs/authentication.md#component-registry-login.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Component.Registry.psm1') -Global -Force
Remove-Item Env:DOCKER_BUILDKIT -Force -ErrorAction SilentlyContinue

function Publish-ComponentList {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        $project_root,
        $config_subfolder
    )

    # Split the inner scriptblock's pipeline: hashtables become the manifest
    # (via $state, which the ForEach-Object child scope can mutate), and every
    # other line routes to the host via Out-Default so phase output
    # cannot array-wrap the manifest returned to callers.
    # --- REGION: https://yuruna.link/42d69dfa-003d
    $state = @{ manifest = $null }
    & {
    param($project_root, $config_subfolder)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (!(Confirm-ComponentList $project_root $config_subfolder)) { return (New-YurunaResultManifest -Success $false -ErrorMessage "Confirm-ComponentList failed for $project_root / $config_subfolder" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    Write-Debug "---- Publishing Components"
    # For each component: merge variables (resources global + resources.output
    # + component-level globals + component locals), run buildCommand from the
    # folder, then tag and push to the registry. Commands come from components.yml.

    $componentsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/components.yml"
    if (-Not (Test-Path -Path $componentsFile)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_3b76598616520aa3' -Arguments @{ componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $false -ErrorMessage "File not found: $componentsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    $componentsYaml = ConvertFrom-File $componentsFile
    if ($null -eq $componentsYaml) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_ba98150f5b113567' -Arguments @{ componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $true -Skipped $true -DurationMs $sw.ElapsedMilliseconds); }
    if ($null -eq $componentsYaml.components) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_ba98150f5b113567' -Arguments @{ componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $true -Skipped $true -DurationMs $sw.ElapsedMilliseconds); }

    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/components"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    New-YurunaTimestampedBackup -SourceFile $componentsFile -WorkFolder $workFolder -Prefix 'components'

    $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    $resourcesOutputYaml = $null
    if (Test-Path -Path $resourcesOutputFile) {
        $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile
    }

    # Verbatim to env (-NoExpand): layering is done at the YAML level.
    Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -NoExpand
    Set-ExpandedVariableHashtable -Variables $componentsYaml.globalVariables -NoExpand

    $componentsPath = Join-Path -Path $project_root -ChildPath "components/"

    # Per-environment docker stderr/stdout log + final-rc sidecar. Mirrors
    # Set-Resource's tofu.stderr.log pattern so Get-SystemDiagnostic.ps1's
    # *.stderr.log glob picks it up on failure. All components in this run
    # append to the same log (preProcessor/build/postProcessor/tag/login/push
    # per component); docker.rc is rewritten after each docker call so the
    # LAST exit code is what the diagnostic reports. Truncated at the start
    # of the run so a re-run doesn't inherit stale text.
    $dockerLogFile = Join-Path -Path $workFolder -ChildPath "docker.stderr.log"
    $dockerRcFile  = Join-Path -Path $workFolder -ChildPath "docker.rc"
    Remove-Item -LiteralPath $dockerLogFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dockerRcFile  -Force -ErrorAction SilentlyContinue

    function Protect-ComponentCommandText {
        param([string]$Text)
        foreach ($entry in Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)password|token|secret' -and $_.Value }) {
            $Text = $Text.Replace($entry.Value, '<redacted>')
        }
        return $Text
    }

    function Invoke-ComponentCommand {
        # Each phase has its own supervised process so a stuck native child is
        # bounded without terminating the publisher. A private state sidecar
        # preserves environment changes made by PowerShell preprocessors.
        param([string]$Phase, [string]$Command, [switch]$Sensitive)
        $phaseWatch = [Diagnostics.Stopwatch]::StartNew()
        $secrets = @(Get-ChildItem Env: | Where-Object { $_.Name -match '(?i)password|token|secret' -and $_.Value } |
            Select-Object -ExpandProperty Value -Unique | Sort-Object { $_.Length } -Descending)
        function Protect-ComponentText {
            param([string]$Text)
            foreach ($secret in $secrets) { $Text = $Text.Replace($secret, '<redacted>') }
            return $Text
        }
        function Write-ComponentRecord {
            param([string]$Text)
            $text = Protect-ComponentText $Text
            Add-Content -LiteralPath $dockerLogFile -Value $text -ErrorAction Stop
            Write-Information $text -InformationAction Continue
        }
        $loggedCommand = if ($Sensitive) { '<command withheld>' } else { Protect-ComponentText $Command }
        Write-ComponentRecord "== [$Phase] $loggedCommand == phase=begin utc=$([DateTime]::UtcNow.ToString('o')) timeoutSeconds=$commandTimeout"
        $native = $null
        $stateFolder = $null
        $rc = 1
        $outcome = 'launch_failed'
        $buffers = @{ stdout = ''; stderr = '' }
        try {
            $stateFolder = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-component-' + [guid]::NewGuid().ToString('N'))
            if ($IsWindows) {
                $null = [IO.Directory]::CreateDirectory($stateFolder)
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
                $acl = [Security.AccessControl.DirectorySecurity]::new()
                $acl.SetAccessRuleProtection($true, $false)
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                Set-Acl -LiteralPath $stateFolder -AclObject $acl -ErrorAction Stop
            } else {
                $null = [IO.Directory]::CreateDirectory($stateFolder, [IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
            }
            $stateFile = Join-Path $stateFolder 'environment.json'
            $childScript = @'
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$global:LASTEXITCODE = 0
[Console]::Out.WriteLine("[command pid=$PID utc=$([DateTime]::UtcNow.ToString('o'))]")
$comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$initial = [Collections.Generic.Dictionary[string,string]]::new($comparer)
foreach ($entry in Get-ChildItem Env:) { $initial[$entry.Name] = $entry.Value }
$code = 1
try {
    & ([scriptblock]::Create($env:YURUNA_COMPONENT_COMMAND)) *>&1 | ForEach-Object { [Console]::Out.WriteLine([string]$_) }
    $code = $global:LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.ToString())
} finally {
    $changed = [Collections.Generic.List[object]]::new()
    foreach ($entry in Get-ChildItem Env:) {
        if (-not $initial.ContainsKey($entry.Name) -or $initial[$entry.Name] -cne $entry.Value) { $changed.Add(@{ name = $entry.Name; value = $entry.Value }) }
        [void]$initial.Remove($entry.Name)
    }
    @{ changed = @($changed.ToArray()); removed = @($initial.Keys); location = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path } | ConvertTo-Json -Depth 3 -Compress |
        Set-Content -LiteralPath $env:YURUNA_COMPONENT_STATE -Encoding utf8 -ErrorAction Stop
}
exit $code
'@
            function Write-ComponentOutput {
                param([string]$Text)
                if (-not $Text) { return }
                Add-Content -LiteralPath $dockerLogFile -Value $Text -NoNewline -ErrorAction Stop
                $message = [Management.Automation.HostInformationMessage]::new()
                $message.Message = $Text
                $message.NoNewLine = $true
                Write-Information $message -InformationAction Continue
            }
            function Send-ComponentOutput {
                param([string]$Stream, [switch]$Final)
                $text = $buffers[$Stream]
                if (-not $text) { return }
                # Keep only a suffix that could become a secret after the next
                # read. This also protects partial credentials at a capture cap.
                $hold = 0
                foreach ($secret in $secrets) {
                    for ($length = [Math]::Min($text.Length, $secret.Length - 1); $length -gt $hold; $length--) {
                        if ($text.EndsWith($secret.Substring(0, $length), [StringComparison]::Ordinal)) { $hold = $length; break }
                    }
                }
                $emit = if ($Final) { $text.Length } else { $text.Length - $hold }
                $masked = [bool[]]::new($emit)
                foreach ($secret in $secrets) {
                    $offset = 0
                    while ($offset -lt $text.Length) {
                        $index = $text.IndexOf($secret, $offset, [StringComparison]::Ordinal)
                        if ($index -lt 0 -or $index -ge $emit) { break }
                        [Array]::Fill[bool]($masked, $true, $index, [Math]::Min($secret.Length, $emit - $index))
                        $offset = $index + 1
                    }
                }
                if ($Final -and $hold -gt 0) { [Array]::Fill[bool]($masked, $true, $text.Length - $hold, $hold) }
                $safe = [Text.StringBuilder]::new()
                $insideSecret = $false
                for ($offset = 0; $offset -lt $emit; $offset++) {
                    if ($masked[$offset]) {
                        if (-not $insideSecret) { [void]$safe.Append('<redacted>') }
                        $insideSecret = $true
                    } else {
                        [void]$safe.Append($text[$offset])
                        $insideSecret = $false
                    }
                }
                Write-ComponentOutput $safe.ToString()
                $buffers[$Stream] = $text.Substring($emit)
            }
            $handler = {
                param($Chunk, $Stream)
                $buffers[$Stream] += $Chunk
                Send-ComponentOutput -Stream $Stream
            }
            $native = Invoke-BoundedNativeCommand -FilePath (Get-PwshApplicationPath) `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $childScript) `
                -WorkingDirectory $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path -TimeoutSeconds $commandTimeout `
                -Environment @{ YURUNA_COMPONENT_COMMAND = $Command; YURUNA_COMPONENT_STATE = $stateFile } `
                -MaxCapturedChars 1048576 -OutputHandler $handler
            $rc = $native.ExitCode
            $outcome = if (-not $native.Started) { 'launch_failed' } elseif ($native.KillFailed) { 'kill_failed' } elseif ($native.TimedOut) { 'timed_out' } elseif ($native.DrainTimedOut) { 'drain_incomplete' } else { 'completed' }
            foreach ($stream in 'stdout', 'stderr') {
                Send-ComponentOutput -Stream $stream -Final
            }
            if ($native.OutputTruncated) { Write-ComponentRecord '[output truncated at 1048576 characters per stream]' }
            if ($native.OutputHandlerError) { throw "Component evidence writer failed: $($native.OutputHandlerError)" }
            if ($native.StartError) { Write-ComponentRecord "[launch error] $($native.StartError)" }
            if ($native.Started -and -not $native.TimedOut -and -not $native.DrainTimedOut) {
                if (-not (Test-Path -LiteralPath $stateFile) -or (Get-Item -LiteralPath $stateFile).Length -gt 1048576) {
                    throw 'Component environment state is missing or exceeds its bound.'
                }
                $environmentState = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json -AsHashtable
                foreach ($name in $environmentState.removed) { [Environment]::SetEnvironmentVariable($name, $null) }
                foreach ($entry in $environmentState.changed) { [Environment]::SetEnvironmentVariable($entry.name, $entry.value) }
                Set-Location -LiteralPath $environmentState.location -ErrorAction Stop
            }
            if ($native.DrainTimedOut -or $native.KillFailed) { $rc = 124 }
        } catch {
            $rc = 1
            if ($outcome -eq 'completed') { $outcome = 'evidence_failed' }
            Write-ComponentRecord "[phase error] $($_.Exception.Message)"
        } finally {
            $processId = if ($native) { $native.ProcessId } else { 0 }
            $killFailed = if ($native) { $native.KillFailed } else { $false }
            try {
                Write-ComponentRecord "`n== [$Phase] phase=end utc=$([DateTime]::UtcNow.ToString('o')) pid=$processId exit=$rc outcome=$outcome killFailed=$killFailed elapsedMs=$($phaseWatch.ElapsedMilliseconds) =="
            } finally {
                try { Set-Content -LiteralPath $dockerRcFile -Value $rc -NoNewline }
                finally {
                    if ($stateFolder) { Remove-Item -LiteralPath $stateFolder -Recurse -Force -ErrorAction SilentlyContinue }
                    $global:LASTEXITCODE = $rc
                }
            }
        }
    }

    foreach ($component in $componentsYaml.components) {
        $commandTimeout = 600
        $configuredTimeout = if ($component.Contains('commandTimeoutSeconds')) { $component['commandTimeoutSeconds'] } else { $componentsYaml.globalVariables['commandTimeoutSeconds'] }
        if ($null -ne $configuredTimeout -and (-not [int]::TryParse([string]$configuredTimeout, [ref]$commandTimeout) -or $commandTimeout -lt 1 -or $commandTimeout -gt 3600)) {
            return (New-YurunaResultManifest -Success $false -ErrorMessage 'commandTimeoutSeconds must be an integer between 1 and 3600.' -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds)
        }
        $projectName = $component['project']
        if ([string]::IsNullOrEmpty($projectName)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_c6903487e18366b6' -Arguments @{ componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $false -ErrorMessage "component.project cannot be null or empty in file: $componentsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        $projectNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($projectName)
        Write-Verbose "$projectName = $projectNameExpanded"
        $projectName = $projectNameExpanded
        Set-Item -Path Env:projectName -Value ${projectName}
        $buildPath = $component['buildPath']
        if ([string]::IsNullOrEmpty($buildPath)) {
            $buildPath = $projectName;
        }
        $buildPath = $ExecutionContext.InvokeCommand.ExpandString($buildPath)

        $buildFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "components/$buildPath")
        if (-Not (Test-Path -Path $buildFolder)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_22827d1698f66f24' -Arguments @{ buildFolder = "$buildFolder"; componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $false -ErrorMessage "Components folder not found: $buildFolder (used in $componentsFile)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_337741d0b21e8f43' -Arguments @{ projectName = "$projectName"; buildFolder = "$buildFolder" })

        # No string expansion for the components script here; values are
        # layered in order: resources globals, resources.output, components
        # globals, component locals. Each layer is also pushed to env via
        # the helper's per-key Set-Item.
        $componentVars = [ordered]@{}
        Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -Sink $componentVars -NoExpand
        Set-ExpandedVariableHashtable -Variables $componentsYaml.globalVariables -Sink $componentVars -NoExpand
        Set-ExpandedVariableHashtable -Variables $component.variables -Sink $componentVars -NoExpand

        $buildCommand = $component['buildCommand']
        if ([string]::IsNullOrEmpty($buildCommand)) { $buildCommand = $componentsYaml.globalVariables['buildCommand'] }
        if ([string]::IsNullOrEmpty($buildCommand)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_1277101be3303544' -Arguments @{ componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $false -ErrorMessage "buildCommand cannot be null or empty in $componentsFile (both globalVariables and component level)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }

        $dockerfile = Join-Path -Path $buildFolder -ChildPath "Dockerfile"
        if (-Not (Test-Path -Path $dockerfile)) { $dockerfile = Join-Path -Path $buildFolder -ChildPath "dockerfile"; }
        if (-Not (Test-Path -Path $dockerfile)) { $dockerfile = Join-Path -Path $buildFolder -ChildPath "$projectName-dockerfile"; }
        if (-Not (Test-Path -Path $dockerfile)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_4d056a8f44de93c4' -Arguments @{ buildFolder = "$buildFolder" }); return (New-YurunaResultManifest -Success $false -ErrorMessage "Missing dockerfile in folder: $buildFolder" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }

        $componentVars['project'] = $projectName
        $componentVars['buildPath'] = $buildPath
        $componentVars['dockerfile'] = $dockerfile
        foreach ($key in $componentVars.Keys) {
            $value = $componentVars[$key]
            if ([string]::IsNullOrEmpty($value)) { Write-Debug "WARNING: empty value for $key" }
            Set-Item -Path Env:$key -Value ${value}
            Write-Debug (Protect-ComponentCommandText "$projectName[Env:$key] is $(Get-Content -Path Env:$key)")
        }

        Push-Location $componentsPath -ErrorAction Stop
        try {
        $preProcessor = $componentVars['preProcessor']
        if ([string]::IsNullOrEmpty($preProcessor)) { $preProcessor = $componentsYaml.globalVariables['preProcessor'] }
        if (-Not ([string]::IsNullOrEmpty($preProcessor))) {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($preProcessor)
        $displayCommand = Protect-ComponentCommandText $executionCommand
            Write-Information "preProcessor: $displayCommand"
            Invoke-ComponentCommand -Phase "preProcessor[$projectName]" -Command $executionCommand
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_69144d64953b7a98' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; executionCommand = "$displayCommand" })
                # A non-zero tool exit is a failure: report success=$false so a
                # consumer keying on `success` (Complete-YurunaRun, diagnostics)
                # catches it. The exit code + failureClass carry the triage
                # detail. Deriving success from the ambient $ErrorActionPreference
                # instead would let a failed build/tag/push masquerade as a pass
                # at the framework defaults (EAP stays 'Continue').
                return (New-YurunaResultManifest -Success $false -ErrorMessage "preProcessor[$projectName] exit ${LASTEXITCODE}: $displayCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
            }
        }

        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($buildCommand)
        $displayCommand = Protect-ComponentCommandText $executionCommand
        Write-Debug "Build: $displayCommand"
        Invoke-ComponentCommand -Phase "build[$projectName]" -Command $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_04b616b009d4b902' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; executionCommand = "$displayCommand" })
            return (New-YurunaResultManifest -Success $false -ErrorMessage "build[$projectName] exit ${LASTEXITCODE}: $displayCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
        }

        $postProcessor = $componentVars['postProcessor']
        if ([string]::IsNullOrEmpty($postProcessor)) { $postProcessor = $componentsYaml.globalVariables['postProcessor'] }
        if (-Not ([string]::IsNullOrEmpty($postProcessor))) {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($postProcessor)
        $displayCommand = Protect-ComponentCommandText $executionCommand
            Write-Information "postProcessor: $displayCommand"
            Invoke-ComponentCommand -Phase "postProcessor[$projectName]" -Command $executionCommand
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_1976f6226f942cc8' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; executionCommand = "$displayCommand" })
                return (New-YurunaResultManifest -Success $false -ErrorMessage "postProcessor[$projectName] exit ${LASTEXITCODE}: $displayCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
            }
        }
        }
        finally {
            Pop-Location
        }

        $tagCommand = $component['tagCommand']
        if ([string]::IsNullOrEmpty($tagCommand)) { $tagCommand = $componentsYaml.globalVariables['tagCommand']; }
        if ([string]::IsNullOrEmpty($tagCommand)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_564abb9d3abeae2e' -Arguments @{ componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $false -ErrorMessage "tagCommand cannot be null or empty in $componentsFile (both globalVariables and component level)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        $pushCommand = $component['pushCommand']
        if ([string]::IsNullOrEmpty($pushCommand)) { $pushCommand = $componentsYaml.globalVariables['pushCommand']; }
        if ([string]::IsNullOrEmpty($pushCommand)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_59d1126624ee215b' -Arguments @{ componentsFile = "$componentsFile" }); return (New-YurunaResultManifest -Success $false -ErrorMessage "pushCommand cannot be null or empty in $componentsFile (both globalVariables and component level)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($tagCommand)
        $displayCommand = Protect-ComponentCommandText $executionCommand
        Write-Debug "Tag: $displayCommand"
        Invoke-ComponentCommand -Phase "tag[$projectName]" -Command $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_134bb283b64fa9b9' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; executionCommand = "$displayCommand" })
            return (New-YurunaResultManifest -Success $false -ErrorMessage "tag[$projectName] exit ${LASTEXITCODE}: $displayCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
        }

        # Registry login dispatched through Yuruna.Component.Registry
        # (Azure ACR, ECR, GAR, Docker Hub, generic). $null means "no
        # provider matched or this provider opted out" -- silently skip
        # the phase and let the operator's pre-existing docker
        # credential helper handle the push.
        $registryLocation = $([Environment]::GetEnvironmentVariable("${env:registryName}.registryLocation"))
        $loginCommand = Resolve-ComponentRegistryLogin -RegistryLocation $registryLocation
        if ($loginCommand) {
            # Providers leave credential environment references intact for the
            # PowerShell pipeline; interpolating them into source both executes
            # secret text as code and exposes it through command diagnostics.
            $executionCommand = "$loginCommand *>&1"
            Invoke-ComponentCommand -Phase "registryLogin[$projectName]" -Command $executionCommand -Sensitive | Write-Verbose
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_0966db03993b9bcb' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; executionCommand = '<command withheld>' })
                return (New-YurunaResultManifest -Success $false -ErrorMessage "registryLogin[$projectName] exit ${LASTEXITCODE}: <command withheld>" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
            }
        }

        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($pushCommand)
        $displayCommand = Protect-ComponentCommandText $executionCommand
        Write-Debug "Push: $displayCommand"
        Invoke-ComponentCommand -Phase "push[$projectName]" -Command $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_a15f59ef0d1479f4' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; executionCommand = "$displayCommand" })
            return (New-YurunaResultManifest -Success $false -ErrorMessage "push[$projectName] exit ${LASTEXITCODE}: $displayCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
        }
    }

    return (New-YurunaResultManifest -Success $true -DurationMs $sw.ElapsedMilliseconds);

    } $project_root $config_subfolder | ForEach-Object {
        if ($_ -is [System.Collections.IDictionary]) {
            $state.manifest = $_
        }
        else {
            $_ | Out-Default
        }
    }

    if ($null -eq $state.manifest) {
        return (New-YurunaResultManifest -Success $false -ErrorMessage 'Publish-ComponentList produced no manifest' -FailureClass 'unknown')
    }
    return $state.manifest
}

Export-ModuleMember -Function * -Alias *
