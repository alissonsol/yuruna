<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42faf294-753d-4723-9aad-fda38cd33eb2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Route a disposable proxy worker to exact prepared public Git origins.
.DESCRIPTION
    Transfers bounded Git bundles through verified SSH, verifies their commits
    and trees in the VM, and installs a private temporary systemd environment.
    The original unit settings remain intact. Restore in finally; an independent
    three-hour systemd timer also restores after controller failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Restore')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.@:-]+$')][string]$ProxyHost,
    [Parameter(Mandatory)][string]$SshKeyPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
    [string]$UpstreamsPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$DisposableTarget
)
$ErrorActionPreference = 'Stop'
if (-not $DisposableTarget) { throw 'Controlled origins require an explicitly disposable proxy.' }
Import-Module (Join-Path $PSScriptRoot ../automation/Yuruna.Common.psm1) -Force -DisableNameChecking
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'Keep previous native origin evidence immutable.' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-native-origins-' + [guid]::NewGuid().ToString('N'))
$request = @{action=$Action;runId=$RunId;repositories=@()}
$archive = $null
$process = $null
$inputFile = $null
try {
    if ($Action -ceq 'Prepare') {
        $null = New-Item -ItemType Directory -Path $work
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($work,[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) }
        $fixtures = Get-Content -LiteralPath $UpstreamsPath -Raw | ConvertFrom-Json -AsHashtable
        if (@($fixtures.repositories).Count -ne 2) { throw 'Exactly two prepared public origins are required.' }
        foreach ($repository in $fixtures.repositories) {
            if ($repository.name -notin @('framework','project')) { throw 'Unexpected native origin name.' }
            $canonical = 'https://github.com/alissonsol/yuruna' + $(if($repository.name -ceq 'project'){'-project'}else{''}) + '.git'
            if ($repository.canonicalUrl -cne $canonical) { throw 'Unexpected native origin authority.' }
            $head = [string](& git -C $repository.localPath rev-parse refs/heads/main)
            $tree = [string](& git -C $repository.localPath rev-parse 'refs/heads/main^{tree}')
            if ($LASTEXITCODE -or $head.Trim() -cne $repository.candidateCommit -or $tree.Trim() -cnotmatch '^[0-9a-f]{40}$') { throw 'The prepared origin changed.' }
            $bundle = Join-Path $work ($repository.name+'.bundle')
            $native = Invoke-BoundedNativeCommand -FilePath git -ArgumentList @('-C',$repository.localPath,'bundle','create',$bundle,'refs/heads/main') -TimeoutSeconds 120
            if ($native.ExitCode -or -not (Test-BoundedNativeResultComplete $native)) { throw 'Cannot bundle the frozen public origin.' }
            if ((Get-Item $bundle).Length -gt 256MB) { throw 'The native origin bundle exceeds 256 MiB.' }
            $request.repositories += @{name=$repository.name;canonicalUrl=$canonical;commit=$head.Trim();tree=$tree.Trim()}
        }
        $archive = Join-Path $work origins.tar
        $native = Invoke-BoundedNativeCommand -FilePath tar -ArgumentList @('-cf',$archive,'-C',$work,'framework.bundle','project.bundle') -TimeoutSeconds 120
        if ($native.ExitCode -or -not (Test-BoundedNativeResultComplete $native)) { throw 'Cannot package the prepared Git bundles.' }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 8 -Compress)))
    $program = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot git_mirror_native_origins.py)))
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command ssh -CommandType Application).Source)
    foreach ($argument in @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',
            '-i',[IO.Path]::GetFullPath($SshKeyPath),$ProxyHost,
            "sudo -n python3 -c 'import base64; exec(compile(base64.b64decode(`"$program`"),`"native-origins`",`"exec`"),{`"__name__`":`"__main__`",`"_PROGRAM`":base64.b64decode(`"$program`").decode()})' $encoded")) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute=$false; $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process = [Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    $copy=$null
    if ($archive) { $inputFile=[IO.File]::OpenRead($archive); $copy=$inputFile.CopyToAsync($process.StandardInput.BaseStream) }
    else { $process.StandardInput.Close() }
    $deadline=[DateTimeOffset]::UtcNow.AddMinutes(5)
    while ($copy -and -not $copy.IsCompleted -and -not $process.HasExited -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if ($copy -and $copy.IsCompleted) { $copy.GetAwaiter().GetResult(); $process.StandardInput.Close() }
    $remaining=[Math]::Max(0,[int]($deadline-[DateTimeOffset]::UtcNow).TotalMilliseconds)
    if (-not $process.WaitForExit($remaining)) { $process.Kill($true); throw 'Native origin setup timed out; automatic restoration remains armed.' }
    if ($process.ExitCode) { throw "Native origin control failed: $($stderr.GetAwaiter().GetResult())" }
    $result=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
    [IO.File]::WriteAllText($output,($result | ConvertTo-Json -Depth 12)+"`n")
    if (-not $result.passed) { throw 'Native origin control did not confirm its observations.' }
} finally {
    if ($process) { if (-not $process.HasExited) { $process.Kill($true); $null=$process.WaitForExit(5000) }; $process.Dispose() }
    if ($inputFile) { $inputFile.Dispose() }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
