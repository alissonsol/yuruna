<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42d8859c-5a2b-4588-bb92-96eeed824f57
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest node nvm pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeDiscovery {
    $script:CanRunBash = -not $IsWindows -and $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

    # --- REGION: Invoke-NodeWorkflowFixture
    function Invoke-NodeWorkflowFixture {
        <# Runs shipped exposure or summary code against private Node installations. #>
        param([string]$Workload, [string]$Mode = 'healthy', [switch]$Summary, [switch]$InstallNode)
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $nvmRoot = Join-Path $fixture 'home/.nvm'
        $selected = Join-Path $nvmRoot 'versions/node/v24.1.0/bin'
        $default = Join-Path $nvmRoot 'versions/node/v22.1.0/bin'
        $exposed = Join-Path $fixture 'exposed'
        $null = New-Item -ItemType Directory -Path $selected, $default, $exposed -Force
        foreach ($version in @{ 'selected'=$selected; 'old-default'=$default }.GetEnumerator()) {
            foreach ($command in 'node', 'npm', $Workload) {
                $path = Join-Path $version.Value $command
                Set-Content -LiteralPath $path -Value "#!/bin/bash`nprintf '%s\n' '$($version.Key)-$command'`n" -Encoding utf8NoBOM
                & chmod +x $path
            }
        }
        $mockNvm = @'
if [ "${1:-}" != --no-use ]; then
    export PATH="$HOME/.nvm/versions/node/v22.1.0/bin:$PATH"
fi
nvm() {
    printf '%s\n' "$*" >> "$FIXTURE_ROOT/nvm-calls"
    case "$1" in
        install)
            [ "$2" = "$YURUNA_NODE_MAJOR" ] || return 93
            [ "$FIXTURE_MODE" != install-failure ] || { echo 'fixture Node install failed' >&2; return 19; }
            ;;
        alias)
            [ "$2" = default ] && [ "$3" = "$YURUNA_NODE_MAJOR" ] || return 94
            [ "$FIXTURE_MODE" != alias-failure ] || { echo 'fixture Node alias failed' >&2; return 20; }
            printf '%s' "$3" > "$FIXTURE_ROOT/default-major"
            ;;
        which)
            [ "$2" = "$YURUNA_NODE_MAJOR" ] || return 90
            [ "$FIXTURE_MODE" != lookup-failure ] || { echo 'fixture Node lookup failed' >&2; return 17; }
            printf '%s\n' "$HOME/.nvm/versions/node/v24.1.0/bin/node"
            ;;
        use)
            [ "$2" = --silent ] && [ "$3" = "$YURUNA_NODE_MAJOR" ] || return 91
            [ "$FIXTURE_MODE" != activation-failure ] || { echo 'fixture Node activation failed' >&2; return 18; }
            export PATH="$HOME/.nvm/versions/node/v24.1.0/bin:$PATH"
            ;;
        *) return 92 ;;
    esac
}
'@
        if ($Mode -ne 'missing-nvm') {
            Set-Content -LiteralPath (Join-Path $nvmRoot 'nvm.sh') -Value $mockNvm -Encoding utf8NoBOM
        }
        if ($Mode -in 'missing-node', 'missing-npm', 'missing-workload', 'nonexecutable-node') {
            $command = switch ($Mode) { missing-npm { 'npm' }; missing-workload { $Workload }; default { 'node' } }
            $path = Join-Path $selected $command
            if ($Mode -eq 'nonexecutable-node') { & chmod -x $path } else { Remove-Item -LiteralPath $path }
        }
        $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot "guest/shared/ubuntu.$Workload.sh"))
        $start = $source.IndexOf('# --- REGION: Expose installed commands', [StringComparison]::Ordinal)
        $end = $source.IndexOf('# --- REGION: Installation summary', $start, [StringComparison]::Ordinal)
        if ($Summary) { $body = $source.Substring($end) } else { $body = $source.Substring($start, $end - $start) }
        if ($InstallNode) {
            $start = $source.IndexOf('nvm install "${YURUNA_NODE_MAJOR}"', [StringComparison]::Ordinal)
            $end = $source.IndexOf('# --- REGION: Install ', $start, [StringComparison]::Ordinal)
            $body = '. "$HOME/.nvm/nvm.sh" --no-use' + "`n" + $source.Substring($start, $end - $start)
        }
        foreach ($command in 'node', 'npm', $Workload) {
            $body = $body.Replace("/usr/local/bin/$command", '"$FIXTURE_ROOT/exposed/' + $command + '"')
        }
        $prefix = @'
set -euo pipefail
export HOME="$FIXTURE_ROOT/home"
export YURUNA_NODE_MAJOR=24
export PATH="$HOME/.nvm/versions/node/v22.1.0/bin:$PATH"
sudo() { "$@"; }
'@
        $entry = Join-Path $fixture 'workflow.sh'
        Set-Content -LiteralPath $entry -Value ($prefix + "`n" + $body + "`nprintf 'downstream-workload\n'`n") -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Command bash -ErrorAction Stop).Source -ArgumentList @($entry) -TimeoutSeconds 10 `
            -Environment @{ FIXTURE_ROOT=$fixture; FIXTURE_MODE=$Mode }
        $aliasPath = Join-Path $fixture 'default-major'
        $callsPath = Join-Path $fixture 'nvm-calls'
        [pscustomobject]@{
            Process=$result
            Exposed=$exposed
            DefaultMajor=$(if (Test-Path -LiteralPath $aliasPath) { [IO.File]::ReadAllText($aliasPath) })
            Calls=$(if (Test-Path -LiteralPath $callsPath) { @(Get-Content -LiteralPath $callsPath) })
        }
    }
}

Describe 'Ubuntu <Workload> exposes the selected Node installation' -ForEach @(
    @{ Workload='n8n' }, @{ Workload='openclaw' }
) -Skip:(-not $script:CanRunBash) {
    It 'sets the future shell default only after installing the manifest major' {
        $result = Invoke-NodeWorkflowFixture -Workload $Workload -InstallNode
        $result.Process.ExitCode | Should -Be 0 -Because $result.Process.StdErr
        $result.DefaultMajor | Should -BeExactly '24'
        ($result.Calls -join '|') | Should -BeExactly 'install 24|alias default 24'
        $result.Process.StdOut | Should -Match 'downstream-workload'
    }

    It 'stops before installing the workload when <Mode>' -ForEach @(
        @{ Mode='install-failure'; Calls='install 24' },
        @{ Mode='alias-failure'; Calls='install 24|alias default 24' }
    ) {
        $result = Invoke-NodeWorkflowFixture -Workload $Workload -Mode $Mode -InstallNode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.DefaultMajor | Should -BeNullOrEmpty
        ($result.Calls -join '|') | Should -BeExactly $Calls
        $result.Process.StdOut | Should -Not -Match 'downstream-workload'
    }

    It 'links every executable from the manifest major despite an older NVM default' {
        $result = Invoke-NodeWorkflowFixture -Workload $Workload
        $result.Process.ExitCode | Should -Be 0 -Because $result.Process.StdErr
        $result.Process.StdOut | Should -Match 'downstream-workload'
        foreach ($command in 'node', 'npm', $Workload) {
            $path = Join-Path $result.Exposed $command
            (Get-Item -LiteralPath $path).LinkTarget | Should -Match '/v24\.1\.0/bin/'
            (& $path).Trim() | Should -BeExactly "selected-$command"
        }
    }

    It 'fails before exposing any command when <Mode>' -ForEach @(
        @{ Mode='missing-nvm' }, @{ Mode='lookup-failure' }, @{ Mode='missing-node' },
        @{ Mode='nonexecutable-node' }, @{ Mode='missing-npm' }, @{ Mode='missing-workload' }
    ) {
        $result = Invoke-NodeWorkflowFixture -Workload $Workload -Mode $Mode
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'missing|lookup failed'
        $result.Process.StdOut | Should -Not -Match 'downstream-workload'
        @(Get-ChildItem -LiteralPath $result.Exposed -Force) | Should -BeNullOrEmpty
    }

    It 'reports the selected major in its installation summary' {
        $result = Invoke-NodeWorkflowFixture -Workload $Workload -Summary
        $result.Process.ExitCode | Should -Be 0 -Because $result.Process.StdErr
        $result.Process.StdOut | Should -Match 'Node.js: selected-node'
        $result.Process.StdOut | Should -Match 'npm: selected-npm'
        $result.Process.StdOut | Should -Match "selected-$Workload"
        $result.Process.StdOut | Should -Not -Match 'old-default'
    }

    It 'stops the summary rather than reporting an older major when activation fails' {
        $result = Invoke-NodeWorkflowFixture -Workload $Workload -Mode activation-failure -Summary
        $result.Process.ExitCode | Should -Not -Be 0
        $result.Process.StdErr | Should -Match 'Node activation failed'
        $result.Process.StdOut | Should -Not -Match 'Node.js:|old-default|downstream-workload'
    }
}
