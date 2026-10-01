<#PSScriptInfo
.VERSION 2026.09.30
.GUID 429c71be-5e60-4677-bd16-7463fc916f8d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kubeconfig permissions pester
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

BeforeAll {
    $script:Repo = Split-Path (Split-Path $PSScriptRoot)
    $script:FixtureCommands = @{}
    foreach ($name in @('bash', 'python3', 'cat', 'grep', 'mktemp', 'rm', 'mv')) {
        $script:FixtureCommands[$name] = (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    # The fixture runs context-copy.sh with HOME pointed at a scratch directory, so
    # a PyYAML installed only under the user's home is invisible to it, and PATH
    # may list an interpreter without PyYAML ahead of one that has it. Take the
    # first python3 that imports yaml with a scratch HOME; with none, keep the
    # first so the failure names the missing module.
    if (-not $IsWindows) {
        foreach ($candidate in @(Get-Command python3 -CommandType Application -All -ErrorAction SilentlyContinue)) {
            $probe = [Diagnostics.ProcessStartInfo]::new($candidate.Source)
            foreach ($arg in @('-c', 'import yaml')) { $probe.ArgumentList.Add($arg) }
            $probe.UseShellExecute = $false
            $probe.RedirectStandardOutput = $true
            $probe.RedirectStandardError = $true
            $probe.Environment['HOME'] = [IO.Path]::GetTempPath()
            $process = [Diagnostics.Process]::Start($probe)
            try {
                if (-not $process.WaitForExit(15000)) { $process.Kill(); continue }
                if ($process.ExitCode -eq 0) { $script:FixtureCommands['python3'] = $candidate.Source; break }
            } finally { $process.Dispose() }
        }
    }
}

Describe 'context copy keeps embedded kubeconfig credentials private' {
    It 'retains 0600 permissions under permissive umask <Mask>' -ForEach @(
        @{ Mask = '000' }
        @{ Mask = '002' }
        @{ Mask = '022' }
    ) {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'Unix file permissions'; return }
        $root = Join-Path $TestDrive "context-$Mask"
        $bin = Join-Path $root 'bin'
        $kube = Join-Path $root '.kube'
        $null = New-Item -ItemType Directory -Path $bin, $kube -Force
        foreach ($name in $script:FixtureCommands.Keys) {
            if (-not $script:FixtureCommands[$name]) { throw "Required fixture command absent: $name" }
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $bin $name) -Target $script:FixtureCommands[$name]
        }
        $config = Join-Path $kube 'config'
        $document = @'
apiVersion: v1
kind: Config
current-context: source
users:
- name: source
  user:
    token: synthetic-fixture-token
clusters:
- name: source
  cluster:
    server: https://127.0.0.1:1
contexts:
- name: source
  context:
    cluster: source
    user: source
'@
        [IO.File]::WriteAllText($config, $document)
        [IO.File]::SetUnixFileMode($config, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        $stub = @'
#!/usr/bin/env bash
case "$*" in
  *get-contexts*) printf 'source\n' ;;
  *current-context*) printf 'source\n' ;;
  *--minify*) cat "$FIXTURE_DOCUMENT" ;;
  *--flatten*) cat "${KUBECONFIG##*:}" ;;
  *) exit 0 ;;
esac
'@
        $kubectl = Join-Path $bin 'kubectl'
        [IO.File]::WriteAllText($kubectl, $stub + "`n")
        [IO.File]::SetUnixFileMode($kubectl, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        $psi = [Diagnostics.ProcessStartInfo]::new($script:FixtureCommands['bash'])
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment['HOME'] = $root
        $psi.Environment['PATH'] = $bin
        $psi.Environment['FIXTURE_DOCUMENT'] = $config
        foreach ($arg in @('-c', 'umask "$1"; exec bash "$2"', 'fixture', $Mask, (Join-Path $script:Repo 'global/resources/localhost/context-copy/context-copy.sh'))) { $psi.ArgumentList.Add($arg) }
        $child = [Diagnostics.Process]::Start($psi)
        try {
            $child.StandardInput.WriteLine('{"sourceContext":"source","destinationContext":"copied"}')
            $child.StandardInput.Close()
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(10000)) { $child.Kill(); throw 'context-copy fixture timed out' }
            $child.ExitCode | Should -Be 0 -Because $stderr.GetAwaiter().GetResult()
            ($stdout.GetAwaiter().GetResult() | ConvertFrom-Json).destinationContext | Should -Be 'copied'
            [int][IO.File]::GetUnixFileMode($config) | Should -Be 384
            [IO.File]::ReadAllText($config) | Should -Match 'synthetic-fixture-token'
            @(Get-ChildItem -LiteralPath $kube -Filter 'config.yuruna.*' -Force).Count | Should -Be 0
        } finally { $child.Dispose() }
    }
}
