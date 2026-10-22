<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42a81c9d-90e8-4500-a6b5-1aa69e8c5892
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-GitMirrorNativeValue {
    <# .SYNOPSIS
        Substitute declared native fixture paths without evaluating shell text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value, [hashtable]$Variables)
    $replacementVariables = $Variables
    return [regex]::Replace($Value, '\$\{([A-Za-z][A-Za-z0-9]+)\}', {
            param($match)
            $name = $match.Groups[1].Value
            if (-not $replacementVariables.ContainsKey($name)) { throw "Unknown native recipe variable: $name" }
            return [string]$replacementVariables[$name]
        })
}

function Test-GitMirrorInstallerSignature {
    <# .SYNOPSIS
        Verify exact installer bytes through the bundled trusted release key.
    #>
    [CmdletBinding()]
    param([string]$ArtifactDirectory, [string]$TrustedPublicKeyPath, [string]$InstallerName)
    $manifest = [IO.File]::ReadAllBytes((Join-Path $ArtifactDirectory install.sha256))
    $signature = [IO.File]::ReadAllBytes((Join-Path $ArtifactDirectory install.sha256.sig))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem([IO.File]::ReadAllText($TrustedPublicKeyPath))
        if (-not $rsa.VerifyData($manifest, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'Prepared installer signature is invalid.' }
    } finally { $rsa.Dispose() }
    $manifestLines = @([Text.Encoding]::UTF8.GetString($manifest) -split '\r?\n' |
        Where-Object { $_ -cmatch ('^[0-9a-f]{64}  (?:install/)?' + [regex]::Escape($InstallerName) + '$') })
    if ($manifestLines.Count -ne 1) { throw 'Signed installer manifest has no unique matching entry.' }
    if ((Get-FileHash -LiteralPath (Join-Path $ArtifactDirectory $InstallerName) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifestLines[0].Substring(0, 64)) {
        throw 'Prepared installer bytes differ from the signed manifest.'
    }
}

function Invoke-GitMirrorNativeCommand {
    <# .SYNOPSIS
        Execute an identified production entry point and retain bounded process evidence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Command, [hashtable]$Context, [string]$OutputDirectory, [int]$Index)
    if ($Command.source -notin @('candidate', 'old', 'installer', 'target') -or
        $Command.path -match '(^|[/\\])\.\.([/\\]|$)' -or [IO.Path]::IsPathRooted($Command.path)) {
        throw 'Native commands must name a relative production entry point in an identified source.'
    }
    $path = Join-Path $Context.roots[$Command.source] $Command.path
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Extension -notin @('.ps1', '.sh')) {
        throw 'Native entry point must be a real PowerShell or shell script.'
    }
    $signatureVerified = $false
    $sourceHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Command.source -ceq 'installer') {
        if ($Command.path -notin @('ubuntu.kvm.sh', 'macos.utm.sh', 'windows.hyper-v.ps1')) { throw 'Unknown installer entry point.' }
        Test-GitMirrorInstallerSignature -ArtifactDirectory $Context.roots.installer `
            -TrustedPublicKeyPath $Context.releasePublicKey -InstallerName $Command.path
        $signatureVerified = $true
    }
    $timeout = [int]$Command.timeoutSeconds
    if ($timeout -lt 1 -or $timeout -gt 7200) { throw 'Native command timeout must be 1..7200 seconds.' }
    $expectedExitCodes = @(0)
    if ($Command.ContainsKey('expectedExitCodes')) {
        $expectedExitCodes = @($Command.expectedExitCodes)
        if (-not $expectedExitCodes.Count -or
            @($expectedExitCodes | Where-Object { $_ -isnot [int] -and $_ -isnot [long] -or $_ -lt 0 -or $_ -gt 255 }).Count -gt 0 -or
            ($Command.ContainsKey('background') -and $Command.background)) {
            throw 'Expected native exit codes must be integers 0..255 on a foreground command.'
        }
    }
    $executable = if ($item.Extension -ceq '.ps1') { (Get-Process -Id $PID).Path } else { (Get-Command bash -CommandType Application).Source }
    $start = [Diagnostics.ProcessStartInfo]::new($executable)
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $Context.variables.TargetRoot
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GIT_ASKPASS', 'SSH_ASKPASS')) { $null = $start.Environment.Remove($name) }
    if ($item.Extension -ceq '.ps1') {
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File')) { $start.ArgumentList.Add($argument) }
    }
    $start.ArgumentList.Add($path)
    foreach ($argument in $Command.arguments) { $start.ArgumentList.Add((Expand-GitMirrorNativeValue ([string]$argument) $Context.variables)) }
    foreach ($entry in $Context.environment.GetEnumerator()) { $start.Environment[$entry.Key] = [string]$entry.Value }
    if ($Command.ContainsKey('environment')) {
        foreach ($entry in $Command.environment.GetEnumerator()) {
            $start.Environment[$entry.Key] = Expand-GitMirrorNativeValue ([string]$entry.Value) $Context.variables
        }
    }
    if ($Command.ContainsKey('frameworkOriginPath')) {
        $origin = [IO.Path]::GetFullPath((Expand-GitMirrorNativeValue $Command.frameworkOriginPath $Context.variables))
        $state = [IO.Path]::GetFullPath($Context.variables.StatePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $origin.StartsWith($state + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'Controlled framework origin must be inside the disposable scenario state.'
        }
        $ancestor = $origin
        while ($ancestor.Length -ge $state.Length) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Controlled framework origin cannot traverse symbolic links.'
            }
            $ancestor = Split-Path -Parent $ancestor
        }
        $bare = @(& git -C $origin rev-parse --is-bare-repository 2>&1)
        if ($LASTEXITCODE -or ($bare -join '').Trim() -cne 'true') { throw 'Controlled framework origin must be a real bare repository.' }
        $originUri = [Uri]::new($origin).AbsoluteUri
        $changed = 0
        for ($i = 0; $i -lt [int]$start.Environment['GIT_CONFIG_COUNT']; $i++) {
            if ($start.Environment["GIT_CONFIG_VALUE_$i"] -in @('https://github.com/alissonsol/yuruna', 'https://github.com/alissonsol/yuruna.git') -and
                $start.Environment["GIT_CONFIG_KEY_$i"] -cmatch '^url\..+\.insteadOf$') {
                $start.Environment["GIT_CONFIG_KEY_$i"] = "url.$originUri.insteadOf"
                $changed++
            }
        }
        if ($changed -lt 2) { throw 'Controlled origin requires both canonical framework rewrite entries.' }
    }
    $stdoutPath = Join-Path $OutputDirectory "command-$Index.stdout.log"
    $stderrPath = Join-Path $OutputDirectory "command-$Index.stderr.log"
    $stdout = [IO.File]::Create($stdoutPath)
    $stderr = [IO.File]::Create($stderrPath)
    $process = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [Diagnostics.Process]::Start($start)
        $outCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errCopy = $process.StandardError.BaseStream.CopyToAsync($stderr)
        if ($Command.ContainsKey('background') -and $Command.background) {
            $Context.background.Add(@{ process = $process; stdout = $stdout; stderr = $stderr; outCopy = $outCopy; errCopy = $errCopy })
            $result = @{
                source = $Command.source; path = $Command.path; sourceHash = $sourceHash
                arguments = @($start.ArgumentList); processId = $process.Id; startUtc = $process.StartTime.ToUniversalTime().ToString('o')
                exitCode = $null; timedOut = $false; background = $true
                expectedExitCodes = @(0)
                installerSignatureVerified = $signatureVerified; stdout = $stdoutPath; stderr = $stderrPath
            }
            $process = $null
            $stdout = $null
            $stderr = $null
            return $result
        }
        $timedOut = -not $process.WaitForExit($timeout * 1000)
        if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
        $outCopy.GetAwaiter().GetResult()
        $errCopy.GetAwaiter().GetResult()
        return @{
            source = $Command.source; path = $Command.path
            sourceHash = $sourceHash
            arguments = @($start.ArgumentList); processId = $process.Id
            exitCode = $process.ExitCode; timedOut = $timedOut; durationSeconds = $clock.Elapsed.TotalSeconds
            expectedExitCodes = $expectedExitCodes
            installerSignatureVerified = $signatureVerified
            stdout = $stdoutPath; stderr = $stderrPath
        }
    } finally {
        $clock.Stop()
        if ($process) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        if ($stdout) { $stdout.Dispose() }
        if ($stderr) { $stderr.Dispose() }
    }
}

function Get-GitMirrorNativeObservation {
    <# .SYNOPSIS
        Measure actual checkout, process, configuration or runtime provenance.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Observation, [hashtable]$Context)
    $path = Expand-GitMirrorNativeValue ([string]$Observation.path) $Context.variables
    switch ($Observation.kind) {
        'git' {
            $head = @(& git -C $path rev-parse HEAD 2>&1)
            if ($LASTEXITCODE) { throw "Cannot observe native checkout: $path" }
            $tree = @(& git -C $path rev-parse 'HEAD^{tree}' 2>&1)
            if ($LASTEXITCODE) { throw "Cannot observe native tree: $path" }
            return @{ head = ($head -join '').Trim(); tree = ($tree -join '').Trim() }
        }
        'file-preserved' { return @{ hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } }
        'file-absent' { return @{ exists = Test-Path -LiteralPath $path } }
        'text' { return @{ value = [IO.File]::ReadAllText($path) } }
        'process-replaced' {
            $record = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
            $process = Get-Process -Id ([int]$record.pid) -ErrorAction Stop
            return @{ pid = $process.Id; startUtc = $process.StartTime.ToUniversalTime().ToString('o') }
        }
        'json' {
            $value = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
            foreach ($component in ([string]$Observation.property).Split('.')) {
                if ($value -isnot [Collections.IDictionary] -or -not $value.Contains($component)) {
                    throw "Missing native observation property: $($Observation.property)"
                }
                $value = $value[$component]
            }
            return @{ value = $value }
        }
        default { throw "Unsupported native observation kind: $($Observation.kind)" }
    }
}

function Test-GitMirrorNativeObservation {
    <# .SYNOPSIS
        Compare measured observations with candidate-bound scenario expectations.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([hashtable]$Observation, [AllowNull()][hashtable]$Before, [hashtable]$After, [hashtable]$Context)
    switch ($Observation.kind) {
        'git' {
            if ($Observation.expected -ceq 'old') { return $After.head -ceq $Context.fixtureCommit }
            if ($Observation.expected -ceq 'candidate') { return $After.tree -ceq $Context.frameworkTree }
            if ($Observation.expected -ceq 'unchanged') { return $After.head -ceq $Before.head -and $After.tree -ceq $Before.tree }
            throw 'Git observation must select the old fixture, frozen candidate or unchanged tree.'
        }
        'file-preserved' { return $Before.hash -ceq $After.hash }
        'file-absent' { return -not $After.exists }
        'text' { return $After.value -match (Expand-GitMirrorNativeValue ([string]$Observation.expected) $Context.variables) }
        'process-replaced' {
            if ($Before.pid -eq $After.pid -and $Before.startUtc -ceq $After.startUtc) { return $false }
            $previous = Get-Process -Id ([int]$Before.pid) -ErrorAction SilentlyContinue
            return -not $previous -or $previous.StartTime.ToUniversalTime().ToString('o') -cne $Before.startUtc
        }
        'json' {
            return (ConvertTo-Json -InputObject $After.value -Depth 10 -Compress) -ceq
                (ConvertTo-Json -InputObject $Observation.expected -Depth 10 -Compress)
        }
    }
    return $false
}

function Stop-GitMirrorNativeCommand {
    <# .SYNOPSIS
        Close only processes and log streams started by this disposable run.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Context)
    foreach ($job in $Context.background) {
        try {
            if (-not $job.process.HasExited -and $PSCmdlet.ShouldProcess([string]$job.process.Id, 'Stop qualification child')) {
                $job.process.Kill($true)
                $job.process.WaitForExit()
            }
            $job.outCopy.GetAwaiter().GetResult()
            $job.errCopy.GetAwaiter().GetResult()
        } finally { $job.process.Dispose(); $job.stdout.Dispose(); $job.stderr.Dispose() }
    }
    $Context.background.Clear()
}

Export-ModuleMember -Function Expand-GitMirrorNativeValue, Test-GitMirrorInstallerSignature, Invoke-GitMirrorNativeCommand, Stop-GitMirrorNativeCommand, Get-GitMirrorNativeObservation, Test-GitMirrorNativeObservation
