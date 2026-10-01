<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42f92ea6-5c9c-4bf9-bc5d-26645804dc86
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab host-refresh remote authorization credential
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
    Provision the secrets remote host refresh needs: the signing authority and
    operator credential for pool-control, and one verifier key per host.
.DESCRIPTION
    Remote refresh is authorized by secrets of its own, never by the lab
    token, a lab session or the internal authentication key, all of which are
    reachable from the dashboard's enrollment path. This script creates and
    moves them, and prompts for nothing:

      1. -NewAuthority, on the operator's machine: creates authority.key
         (the signing authority) and operator.credential (what callers send
         in X-Yuruna-Refresh-Credential), owner-only, under the private root's
         authority directory. Copy both to pool-control's
         /etc/yuruna/host-refresh/ with owner-only permissions; never copy them
         to a pool host.
      2. -ExportHostKey -HostId <id> -OutputPath <file>, on the same machine:
         derives one host's verifier key and writes it for transport.
      3. -InstallHostKey -KeyPath <file>, on that host: installs the key into
         the host's private root. A host that is also the authority machine
         can use -InstallHostKey -AuthorityDirectory <dir> instead.
      4. -RemoveHostKey on a host withdraws it from remote refresh.

    Without a switch, the script reports the host's key state and the
    authority state. Secrets never reach the output: only tags (non-secret
    names) and paths do. The host id is read from runtime/host.uuid and is
    never minted here. Exit code 0 on success, 1 on a refusal.
.PARAMETER NewAuthority
    Create the signing authority and operator credential.
.PARAMETER Rotate
    With -NewAuthority, replace an existing authority; every installed host
    key must then be exported and installed again.
.PARAMETER AuthorityDirectory
    Where the authority lives. Default: the private root's authority
    directory ($HOME/.yuruna/host-refresh/authority).
.PARAMETER ExportHostKey
    Write one host's verifier key to -OutputPath.
.PARAMETER HostId
    The host whose key -ExportHostKey writes (the id pool-control lists).
.PARAMETER OutputPath
    The key file to create; an existing file is refused.
.PARAMETER InstallHostKey
    Install this host's verifier key, from -KeyPath or derived from
    -AuthorityDirectory.
.PARAMETER KeyPath
    A key file written by -ExportHostKey.
.PARAMETER RuntimeDirectory
    Where this host's host.uuid lives. Default: $env:YURUNA_RUNTIME_DIR, else
    test/status/runtime.
.PARAMETER RemoveHostKey
    Delete this host's verifier key.
.EXAMPLE
    pwsh test/lab/Set-HostRefreshCredential.ps1 -NewAuthority
.EXAMPLE
    pwsh test/lab/Set-HostRefreshCredential.ps1 -ExportHostKey -HostId 42aa...aa -OutputPath ./42aa.key
.EXAMPLE
    pwsh test/lab/Set-HostRefreshCredential.ps1 -InstallHostKey -KeyPath ./42aa.key
.EXAMPLE
    pwsh test/lab/Set-HostRefreshCredential.ps1
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The action switches only select a parameter set; the script dispatches on ParameterSetName.')]
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'NewAuthority', Mandatory)][switch]$NewAuthority,
    [Parameter(ParameterSetName = 'NewAuthority')][switch]$Rotate,
    [Parameter(ParameterSetName = 'NewAuthority')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'InstallFromAuthority', Mandatory)]
    [Parameter(ParameterSetName = 'Status')]
    [ValidateNotNullOrEmpty()][string]$AuthorityDirectory,
    [Parameter(ParameterSetName = 'Export', Mandatory)][switch]$ExportHostKey,
    [Parameter(ParameterSetName = 'Export', Mandatory)]
    [ValidatePattern('\A[0-9A-Fa-f-]{32,36}\z')][string]$HostId,
    [Parameter(ParameterSetName = 'Export', Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter(ParameterSetName = 'InstallFromFile', Mandatory)]
    [Parameter(ParameterSetName = 'InstallFromAuthority', Mandatory)][switch]$InstallHostKey,
    [Parameter(ParameterSetName = 'InstallFromFile', Mandatory)][ValidateNotNullOrEmpty()][string]$KeyPath,
    [Parameter(ParameterSetName = 'InstallFromFile')]
    [Parameter(ParameterSetName = 'InstallFromAuthority')]
    [Parameter(ParameterSetName = 'Remove')]
    [Parameter(ParameterSetName = 'Status')]
    [ValidateNotNullOrEmpty()][string]$RuntimeDirectory,
    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$RemoveHostKey
)

$ErrorActionPreference = 'Stop'
# The preview is this script's own: it is captured here and passed explicitly
# to each state-changing call, so an ambient preference can neither suppress a
# real run nor leak into a helper that creates the private root.
$preview = [bool]$WhatIfPreference
$WhatIfPreference = $false
$ConfirmPreference = 'None'

$repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'test/modules/Test.HostRefreshAuth.psm1') -Global -Force -DisableNameChecking

function Get-HostRefreshCredentialPrivateRoot {
    # The private root for a mutation: created and secured by
    # Get-YurunaPrivateStateRoot, refused unless it resolved. A preview never
    # creates it and works from the computed path.
    [CmdletBinding()]
    [OutputType([string])]
    param([bool]$Preview)
    if ($Preview) { return [IO.Path]::GetDirectoryName((Get-YurunaHostRefreshVerifierKeyPath)) }
    $root = Get-YurunaPrivateStateRoot
    if (-not $root.Resolved) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_private_root_unavailable' -Arguments @{ reason = "$($root.Reason)" })
    }
    return [string]$root.Path
}

function Get-HostRefreshCredentialHostId {
    # This host's id, read only: host.uuid is created by the runner, and an
    # id minted here would name a host the pool has never seen.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RuntimeDirectory, [switch]$AllowMissing)
    $dir = $RuntimeDirectory
    if (-not $dir) { $dir = $env:YURUNA_RUNTIME_DIR }
    if (-not $dir) { $dir = [IO.Path]::Combine($repoRoot, 'test', 'status', 'runtime') }
    $path = [IO.Path]::Combine($dir, 'host.uuid')
    $id = ''
    if ([IO.File]::Exists($path)) {
        $id = ([IO.File]::ReadAllText($path)).Trim().Replace('-', '').ToLowerInvariant()
    }
    if ($id -cnotmatch '\A[0-9a-f]{32}\z') {
        if ($AllowMissing) { return '' }
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_host_id_unavailable' -Arguments @{ path = "$path" })
    }
    return $id
}

foreach ($pathParameter in @('OutputPath', 'KeyPath', 'AuthorityDirectory', 'RuntimeDirectory')) {
    $value = Get-Variable -Name $pathParameter -ValueOnly
    if ($value) { Set-Variable -Name $pathParameter -Value $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($value) }
}
$exitCode = 0
try {
    switch ($PSCmdlet.ParameterSetName) {
        'NewAuthority' {
            $dir = $AuthorityDirectory
            if (-not $dir) { $dir = [IO.Path]::Combine((Get-HostRefreshCredentialPrivateRoot -Preview $preview), 'authority') }
            $r = New-YurunaHostRefreshAuthority -Directory $dir -Rotate:$Rotate -WhatIf:$preview -Confirm:$false
            if ($r.Reason -ceq 'exists') {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_refresh_credential_authority_exists' -Arguments @{ path = "$dir" })
                $exitCode = 1
            } elseif ($r.Created) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_refresh_credential_authority_created' -Arguments @{
                        authorityTag = "$($r.AuthorityTag)"; credentialTag = "$($r.CredentialTag)"; path = "$dir" })
            }
        }
        'Export' {
            $dir = $AuthorityDirectory
            if (-not $dir) { $dir = [IO.Path]::Combine((Get-HostRefreshCredentialPrivateRoot -Preview $true), 'authority') }
            $r = Export-YurunaHostRefreshHostKey -AuthorityDirectory $dir -HostId $HostId -OutputPath $OutputPath -WhatIf:$preview -Confirm:$false
            if ($r.Reason -ceq 'exists') {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_refresh_credential_output_exists' -Arguments @{ path = "$OutputPath" })
                $exitCode = 1
            } elseif ($r.Written) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_refresh_credential_host_key_exported' -Arguments @{
                        hostId = "$($r.HostId)"; keyTag = "$($r.KeyTag)"; path = "$($r.Path)" })
            }
        }
        { $_ -in 'InstallFromFile', 'InstallFromAuthority' } {
            $thisHost = Get-HostRefreshCredentialHostId -RuntimeDirectory $RuntimeDirectory
            if ($PSCmdlet.ParameterSetName -ceq 'InstallFromFile') {
                $info = [IO.FileInfo]::new([IO.Path]::GetFullPath($KeyPath))
                # A key file is one short line; the cap keeps a wrong path from
                # being read whole.
                $unusable = if (-not $info.Exists) { 'absent' } elseif ($info.Length -gt 4096) { 'too-large' } else { '' }
                if ($unusable) {
                    throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_key_unusable' -Arguments @{ path = "$KeyPath"; reason = $unusable })
                }
                $keyText = [IO.File]::ReadAllText($info.FullName)
            } else {
                $authority = Read-YurunaHostRefreshAuthority -Directory $AuthorityDirectory
                [byte[]]$derived = Get-YurunaHostRefreshHostKey -AuthorityKey ([byte[]]$authority.Authority) -HostId $thisHost
                $keyText = ConvertTo-YurunaHostRefreshHostKeyLine -HostId $thisHost -Key $derived
            }
            $root = Get-HostRefreshCredentialPrivateRoot -Preview $preview
            $install = @{ KeyText = $keyText; HostId = $thisHost; PrivateRoot = $root; WhatIf = $preview; Confirm = $false }
            if ($KeyPath) { $install['SourcePath'] = $KeyPath }
            $r = Install-YurunaHostRefreshVerifierKey @install
            if ($r.Installed) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_refresh_credential_host_key_installed' -Arguments @{
                        hostId = "$($r.HostId)"; keyTag = "$($r.KeyTag)" })
            }
        }
        'Remove' {
            $root = Get-HostRefreshCredentialPrivateRoot -Preview $true
            $r = Remove-YurunaHostRefreshVerifierKey -PrivateRoot $root -WhatIf:$preview -Confirm:$false
            if ($r.Removed) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_refresh_credential_host_key_removed')
            }
        }
        default {
            $thisHost = Get-HostRefreshCredentialHostId -RuntimeDirectory $RuntimeDirectory -AllowMissing
            $state = Get-YurunaHostRefreshRemoteState -HostId $thisHost
            $dir = $AuthorityDirectory
            if (-not $dir) { $dir = [IO.Path]::Combine((Get-HostRefreshCredentialPrivateRoot -Preview $true), 'authority') }
            $authorityState = 'absent'
            if ([IO.File]::Exists([IO.Path]::Combine($dir, 'authority.key'))) {
                try { $null = Read-YurunaHostRefreshAuthority -Directory $dir; $authorityState = 'present' } catch { $authorityState = 'unreadable' }
            }
            $shownHost = if ($thisHost) { $thisHost } else { '-' }
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_refresh_credential_status' -Arguments @{
                    hostId = "$shownHost"; state = "$($state.Remote)"; reason = "$($state.Reason)"; authorityState = "$authorityState" })
        }
    }
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    $exitCode = 1
}
exit $exitCode
