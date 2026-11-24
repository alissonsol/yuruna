<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42f92ea6-5c9c-4bf9-bc5d-26645804dc86
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab host-repair remote authorization credential
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
    Provision what remote host repair and remote host update need: the
    signing authority, the update signing key and the operator credential for
    pool-control, one verifier key per host, and each host's pool-control
    record.
.DESCRIPTION
    See https://yuruna.link/42010605-007c.
.PARAMETER NewAuthority
    Create the signing authority and operator credential.
.PARAMETER Rotate
    With -NewAuthority, replace an existing authority; every installed host
    key must then be exported and installed again.
.PARAMETER AuthorityDirectory
    Where the authority lives. Default: the private root's authority
    directory ($HOME/.yuruna/host-repair/authority).
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
.PARAMETER NewUpdateSigningKey
    Create pool-control's host update signing key in -AuthorityDirectory and
    print the public key line each host installs.
.PARAMETER InstallPoolControlRecord
    Install this host's pool-control record: -PoolControlUrl and the public
    key, from -PublicKey or derived from -AuthorityDirectory.
.PARAMETER PoolControlUrl
    Pool-control's base URL, the address a Diagnostics page on another
    machine sends its operator to.
.PARAMETER PublicKey
    The yupk1 line -NewUpdateSigningKey printed.
.PARAMETER RemovePoolControlRecord
    Delete this host's pool-control record.
.EXAMPLE
    pwsh test/lab/Set-HostRepairCredential.ps1 -NewAuthority
.EXAMPLE
    pwsh test/lab/Set-HostRepairCredential.ps1 -ExportHostKey -HostId 42aa...aa -OutputPath ./42aa.key
.EXAMPLE
    pwsh test/lab/Set-HostRepairCredential.ps1 -InstallHostKey -KeyPath ./42aa.key
.EXAMPLE
    pwsh test/lab/Set-HostRepairCredential.ps1 -NewUpdateSigningKey
.EXAMPLE
    pwsh test/lab/Set-HostRepairCredential.ps1 -InstallPoolControlRecord -PoolControlUrl http://192.0.2.10 -PublicKey yupk1.MIIB...
.EXAMPLE
    pwsh test/lab/Set-HostRepairCredential.ps1
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The action switches only select a parameter set; the script dispatches on ParameterSetName.')]
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'NewAuthority', Mandatory)][switch]$NewAuthority,
    [Parameter(ParameterSetName = 'NewAuthority')]
    [Parameter(ParameterSetName = 'NewUpdateSigningKey')][switch]$Rotate,
    [Parameter(ParameterSetName = 'NewAuthority')]
    [Parameter(ParameterSetName = 'NewUpdateSigningKey')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'InstallFromAuthority', Mandatory)]
    [Parameter(ParameterSetName = 'InstallRecordFromAuthority', Mandatory)]
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
    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$RemoveHostKey,
    [Parameter(ParameterSetName = 'NewUpdateSigningKey', Mandatory)][switch]$NewUpdateSigningKey,
    [Parameter(ParameterSetName = 'InstallRecord', Mandatory)]
    [Parameter(ParameterSetName = 'InstallRecordFromAuthority', Mandatory)][switch]$InstallPoolControlRecord,
    [Parameter(ParameterSetName = 'InstallRecord', Mandatory)]
    [Parameter(ParameterSetName = 'InstallRecordFromAuthority', Mandatory)]
    [ValidateNotNullOrEmpty()][string]$PoolControlUrl,
    [Parameter(ParameterSetName = 'InstallRecord', Mandatory)][ValidateNotNullOrEmpty()][string]$PublicKey,
    [Parameter(ParameterSetName = 'RemoveRecord', Mandatory)][switch]$RemovePoolControlRecord
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
Import-Module (Join-Path $repoRoot 'test/modules/Test.HostRepairAuth.psm1') -Global -Force -DisableNameChecking

# --- REGION: Get-HostRepairCredentialPrivateRoot
function Get-HostRepairCredentialPrivateRoot {
    # The private root for a mutation: created and secured by
    # Get-YurunaPrivateStateRoot, refused unless it resolved. A preview never
    # creates it and works from the computed path.
    [CmdletBinding()]
    [OutputType([string])]
    param([bool]$Preview)
    if ($Preview) { return [IO.Path]::GetDirectoryName((Get-YurunaHostRepairVerifierKeyPath)) }
    $root = Get-YurunaPrivateStateRoot
    if (-not $root.Resolved) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_private_root_unavailable' -Arguments @{ reason = "$($root.Reason)" })
    }
    return [string]$root.Path
}

# --- REGION: Get-HostRepairCredentialHostId
function Get-HostRepairCredentialHostId {
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
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_host_id_unavailable' -Arguments @{ path = "$path" })
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
            if (-not $dir) { $dir = [IO.Path]::Combine((Get-HostRepairCredentialPrivateRoot -Preview $preview), 'authority') }
            $r = New-YurunaHostRepairAuthority -Directory $dir -Rotate:$Rotate -WhatIf:$preview -Confirm:$false
            if ($r.Reason -ceq 'exists') {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_repair_credential_authority_exists' -Arguments @{ path = "$dir" })
                $exitCode = 1
            } elseif ($r.Created) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_repair_credential_authority_created' -Arguments @{
                        authorityTag = "$($r.AuthorityTag)"; credentialTag = "$($r.CredentialTag)"; path = "$dir" })
            }
        }
        'Export' {
            $dir = $AuthorityDirectory
            if (-not $dir) { $dir = [IO.Path]::Combine((Get-HostRepairCredentialPrivateRoot -Preview $true), 'authority') }
            $r = Export-YurunaHostRepairHostKey -AuthorityDirectory $dir -HostId $HostId -OutputPath $OutputPath -WhatIf:$preview -Confirm:$false
            if ($r.Reason -ceq 'exists') {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_repair_credential_output_exists' -Arguments @{ path = "$OutputPath" })
                $exitCode = 1
            } elseif ($r.Written) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_repair_credential_host_key_exported' -Arguments @{
                        hostId = "$($r.HostId)"; keyTag = "$($r.KeyTag)"; path = "$($r.Path)" })
            }
        }
        { $_ -in 'InstallFromFile', 'InstallFromAuthority' } {
            $thisHost = Get-HostRepairCredentialHostId -RuntimeDirectory $RuntimeDirectory
            if ($PSCmdlet.ParameterSetName -ceq 'InstallFromFile') {
                $info = [IO.FileInfo]::new([IO.Path]::GetFullPath($KeyPath))
                # A key file is one short line; the cap keeps a wrong path from
                # being read whole.
                $unusable = if (-not $info.Exists) { 'absent' } elseif ($info.Length -gt 4096) { 'too-large' } else { '' }
                if ($unusable) {
                    throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_key_unusable' -Arguments @{ path = "$KeyPath"; reason = $unusable })
                }
                $keyText = [IO.File]::ReadAllText($info.FullName)
            } else {
                $authority = Read-YurunaHostRepairAuthority -Directory $AuthorityDirectory
                [byte[]]$derived = Get-YurunaHostRepairHostKey -AuthorityKey ([byte[]]$authority.Authority) -HostId $thisHost
                $keyText = ConvertTo-YurunaHostRepairHostKeyLine -HostId $thisHost -Key $derived
            }
            $root = Get-HostRepairCredentialPrivateRoot -Preview $preview
            $install = @{ KeyText = $keyText; HostId = $thisHost; PrivateRoot = $root; WhatIf = $preview; Confirm = $false }
            if ($KeyPath) { $install['SourcePath'] = $KeyPath }
            $r = Install-YurunaHostRepairVerifierKey @install
            if ($r.Installed) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_repair_credential_host_key_installed' -Arguments @{
                        hostId = "$($r.HostId)"; keyTag = "$($r.KeyTag)" })
            }
        }
        'NewUpdateSigningKey' {
            $dir = $AuthorityDirectory
            if (-not $dir) { $dir = [IO.Path]::Combine((Get-HostRepairCredentialPrivateRoot -Preview $preview), 'authority') }
            $r = New-YurunaHostUpdateSigningKey -Directory $dir -Rotate:$Rotate -WhatIf:$preview -Confirm:$false
            if ($r.Reason -ceq 'exists') {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_update_credential_signing_key_exists' -Arguments @{ path = "$($r.KeyPath)" })
                $exitCode = 1
            } elseif ($r.Created) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_update_credential_signing_key_created' -Arguments @{
                        keyTag = "$($r.KeyTag)"; path = "$($r.KeyPath)"; publicKey = "$($r.PublicKey)" })
            }
        }
        { $_ -in 'InstallRecord', 'InstallRecordFromAuthority' } {
            $line = if ($PSCmdlet.ParameterSetName -ceq 'InstallRecord') { $PublicKey } else { [string](Read-YurunaHostUpdateSigningKey -Directory $AuthorityDirectory).PublicKey }
            $root = Get-HostRepairCredentialPrivateRoot -Preview $preview
            # Every value the new record replaces is printed before the write,
            # so the previous one stays on record in this output.
            foreach ($change in @(Get-YurunaPoolControlRecordChange -PublicKey $line -PoolControlUrl $PoolControlUrl -PrivateRoot $root)) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_update_credential_record_value_replaced' -Arguments @{
                        key = "$($change.Key)"; previous = "$($change.Previous)"; current = "$($change.Current)" })
            }
            $r = Install-YurunaPoolControlRecord -PublicKey $line -PoolControlUrl $PoolControlUrl -PrivateRoot $root -WhatIf:$preview -Confirm:$false
            if ($r.Installed) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_update_credential_record_installed' -Arguments @{
                        poolControl = "$($r.PoolControl)"; keyTag = "$($r.KeyTag)" })
            }
        }
        'RemoveRecord' {
            $root = Get-HostRepairCredentialPrivateRoot -Preview $true
            $r = Remove-YurunaPoolControlRecord -PrivateRoot $root -WhatIf:$preview -Confirm:$false
            if ($r.Removed) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_update_credential_record_removed')
            }
        }
        'Remove' {
            $root = Get-HostRepairCredentialPrivateRoot -Preview $true
            $r = Remove-YurunaHostRepairVerifierKey -PrivateRoot $root -WhatIf:$preview -Confirm:$false
            if ($r.Removed) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_repair_credential_host_key_removed')
            }
        }
        default {
            $thisHost = Get-HostRepairCredentialHostId -RuntimeDirectory $RuntimeDirectory -AllowMissing
            $state = Get-YurunaHostRepairRemoteState -HostId $thisHost
            $dir = $AuthorityDirectory
            if (-not $dir) { $dir = [IO.Path]::Combine((Get-HostRepairCredentialPrivateRoot -Preview $true), 'authority') }
            $authorityState = 'absent'
            if ([IO.File]::Exists([IO.Path]::Combine($dir, 'authority.key'))) {
                try { $null = Read-YurunaHostRepairAuthority -Directory $dir; $authorityState = 'present' } catch { $authorityState = 'unreadable' }
            }
            $shownHost = if ($thisHost) { $thisHost } else { '-' }
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_repair_credential_status' -Arguments @{
                    hostId = "$shownHost"; state = "$($state.Remote)"; reason = "$($state.Reason)"; authorityState = "$authorityState" })
            $record = Get-YurunaHostUpdateRemoteState
            $signingKeyState = 'absent'
            if ([IO.File]::Exists([IO.Path]::Combine($dir, 'update-signing.key'))) {
                try { $null = Read-YurunaHostUpdateSigningKey -Directory $dir; $signingKeyState = 'present' } catch { $signingKeyState = 'unreadable' }
            }
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.host_update_credential_status' -Arguments @{
                    state = "$($record.Remote)"; reason = "$($record.Reason)"; poolControl = $(if ($record.PoolControl) { "$($record.PoolControl)" } else { '-' })
                    keyTag = $(if ($record.KeyTag) { "$($record.KeyTag)" } else { '-' }); signingKeyState = "$signingKeyState" })
        }
    }
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    $exitCode = 1
}
exit $exitCode
