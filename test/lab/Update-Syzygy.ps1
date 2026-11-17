<#PSScriptInfo
.VERSION 2026.11.16
.GUID 42e8a9c1-7b3d-4f5a-8e12-9c4b0d6a3e71
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab syzygy service vm
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
    Wait for a new upstream commit, pull it, then run Start-Syzygy.ps1.
.DESCRIPTION
    Asks first for everything Start-Syzygy.ps1 would ask at its start: the
    optional GitHub token, and the sudo password on macOS and Linux. Windows
    has no password to ask for, so an unelevated session stops here. Only then
    does it watch the upstream of this checkout's current branch, so the wait
    and the start that follows it need nobody at the keyboard.

    The start runs in a new PowerShell process, which loads the pulled scripts
    and modules instead of the ones this process read before the pull. It runs
    with YURUNA_NONINTERACTIVE=1, because its questions were already answered.
.PARAMETER IntervalSeconds
    Seconds between checks of the upstream branch.
.EXAMPLE
    pwsh test/lab/Update-Syzygy.ps1
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Progress dots share one console line, which only Write-Host -NoNewline provides.')]
[CmdletBinding()]
param(
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$repoRoot = $paths.RepoRoot
Initialize-YurunaEntryPointModuleSet -For CachingProxyService -ModulesDir $paths.ModulesDir

# --- REGION: Take the start's authorization before the wait
# Each answer below is one Start-Syzygy.ps1 would otherwise ask for when the
# commit arrives, which can be hours after the operator has left.
if (-not (Assert-Elevation -HostType (Get-HostType))) { exit 1 }

# The token is stored in the authentication vault, where the proxy start reads
# it. The rebuild a new token calls for needs no forwarding: Start-Syzygy.ps1
# always rebuilds the proxy.
$null = Initialize-CachingProxyGitMirrorToken -Confirm:$false

if (-not (Initialize-SudoCache -Reasons @('start the Syzygy service VMs once the repository changes'))) {
    Write-Error 'sudo authorization was not granted, so the service VMs could not be started unattended. Nothing was changed.'
    exit 1
}
$refreshSudo = ($IsLinux -or $IsMacOS) -and "$(& /usr/bin/id -u)".Trim() -ne '0'

# --- REGION: Wait for an upstream commit
$upstream = & git -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}'
if ($LASTEXITCODE -ne 0) {
    Write-Error "The current branch of $repoRoot has no upstream to watch. Nothing was changed."
    exit 1
}
Write-Host "Watching $upstream for new commits..." -ForegroundColor Cyan

$savedTerminalPrompt = $env:GIT_TERMINAL_PROMPT
try {
    while ($true) {
        & git -C $repoRoot fetch --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to fetch $upstream. Nothing was started."
            exit 1
        }
        # The first fetch may ask for a credential while the operator is still
        # here; a later one that asks would stall the watch with nobody to answer.
        $env:GIT_TERMINAL_PROMPT = '0'

        $incoming = [int](& git -C $repoRoot rev-list --count 'HEAD..@{u}')
        if ($incoming -gt 0) {
            $remoteHash = & git -C $repoRoot rev-parse --short '@{u}'
            Write-Host "`nNew commit detected ($remoteHash). Pulling changes..." -ForegroundColor Green
            break
        }

        # sudo forgets a password after a few idle minutes; validating on every
        # check keeps the authorization taken above alive until the start uses it.
        if ($refreshSudo) {
            & sudo -n -v 2>$null
            if ($LASTEXITCODE -ne 0) {
                $refreshSudo = $false
                Write-Warning 'sudo no longer holds the authorization taken at the start (the sudoers policy may not cache it). The service start will not prompt, so its privileged steps may fail.'
            }
        }

        Write-Host '.' -NoNewline
        Start-Sleep -Seconds $IntervalSeconds
    }

    & git -C $repoRoot pull
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'Git pull failed. Nothing was started.'
        exit 1
    }
} finally {
    # Removed rather than emptied when it was unset: git reads an empty value
    # as false, which would leave the caller's shell unable to prompt.
    if ($null -eq $savedTerminalPrompt) { Remove-Item -LiteralPath Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $savedTerminalPrompt }
}

# --- REGION: Start the services from the pulled checkout
Write-Host 'Running Start-Syzygy.ps1' -ForegroundColor Cyan
$savedNonInteractive = $env:YURUNA_NONINTERACTIVE
try {
    $env:YURUNA_NONINTERACTIVE = '1'
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot 'Start-Syzygy.ps1')
    $startExitCode = $LASTEXITCODE
} finally {
    if ($null -eq $savedNonInteractive) { Remove-Item -LiteralPath Env:YURUNA_NONINTERACTIVE -ErrorAction SilentlyContinue } else { $env:YURUNA_NONINTERACTIVE = $savedNonInteractive }
}
exit $startExitCode
