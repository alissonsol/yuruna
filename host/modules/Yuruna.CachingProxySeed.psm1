<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42c186c8-2569-4926-a391-ec512ef52ef8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

function Get-CachingProxySeedAcl {
    [CmdletBinding()]
    param([switch]$Directory)
    $acl = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($owner)
    $inherit = if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit,
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    return $acl
}

function New-CachingProxySeedWorkspace {
    <#
    .SYNOPSIS
        Create private, same-filesystem staging for secret-bearing seed media.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates only a new randomly named private staging directory below the explicit VM path.')]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$ParentPath)
    $parent = Get-Item -LiteralPath $ParentPath -Force -ErrorAction Stop
    if (-not $parent.PSIsContainer -or $parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Seed staging parent must be an existing real directory.'
    }
    $path = Join-Path $parent.FullName ('.yuruna-cache-seed-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $path) { throw 'Seed staging path already exists.' }
    if ($IsWindows) {
        $null = [IO.FileSystemAclExtensions]::CreateDirectory((Get-CachingProxySeedAcl -Directory), $path)
    } else {
        $null = [IO.Directory]::CreateDirectory($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    }
    try {
        $source = Join-Path $path source
        $null = [IO.Directory]::CreateDirectory($source)
        return @{ Root = $path; Source = $source; Image = (Join-Path $path seed.iso); Parent = $parent.FullName }
    } catch {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Publish-CachingProxySeedImage {
    <#
    .SYNOPSIS
        Protect a completed ISO before atomically publishing it beside the disk.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Workspace, [Parameter(Mandatory)][string]$Path)
    $destination = [IO.Path]::GetFullPath($Path)
    if ((Split-Path -Parent $destination) -ne [IO.Path]::GetFullPath($Workspace.Parent)) {
        throw 'Seed media publication must remain on its staging filesystem.'
    }
    foreach ($item in @($Workspace.Root, $Workspace.Source, $Workspace.Image)) {
        $entry = Get-Item -LiteralPath $item -Force -ErrorAction Stop
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Seed staging cannot contain symbolic links.' }
    }
    if (Test-Path -LiteralPath $destination) {
        if ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Seed image destination cannot be a symbolic link.'
        }
    }
    if (-not $PSCmdlet.ShouldProcess($destination, 'Publish protected seed media')) { return }
    if ($IsWindows) {
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Workspace.Image), (Get-CachingProxySeedAcl))
    } else {
        [IO.File]::SetUnixFileMode($Workspace.Image, [IO.UnixFileMode]'UserRead, UserWrite')
    }
    [IO.File]::Move($Workspace.Image, $destination, $true)
}

function Grant-CachingProxySeedVmRead {
    <#
    .SYNOPSIS
        Grant only the newly created Hyper-V VM access to its protected ISO.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][guid]$VMId)
    if (-not $IsWindows) { throw 'Hyper-V seed ACLs require Windows.' }
    if (-not $PSCmdlet.ShouldProcess($Path, "Grant seed read access to VM $VMId")) { return }
    $account = [Security.Principal.NTAccount]::new("NT VIRTUAL MACHINE\$VMId")
    $sid = $account.Translate([Security.Principal.SecurityIdentifier])
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::Read, [Security.AccessControl.AccessControlType]::Allow))
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $acl)
}

function Remove-CachingProxySeedWorkspace {
    <#
    .SYNOPSIS
        Remove the owned plaintext source and any incomplete seed media.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowNull()][hashtable]$Workspace)
    if (-not $Workspace -or -not (Test-Path -LiteralPath $Workspace.Root)) { return }
    if ((Split-Path -Parent $Workspace.Root) -ne $Workspace.Parent -or
        (Split-Path -Leaf $Workspace.Root) -cnotmatch '^\.yuruna-cache-seed-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unrecognized seed workspace.'
    }
    if ((Get-Item -LiteralPath $Workspace.Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to remove a substituted seed workspace.'
    }
    if ($PSCmdlet.ShouldProcess($Workspace.Root, 'Remove secret seed staging')) {
        Remove-Item -LiteralPath $Workspace.Root -Recurse -Force -ErrorAction Stop
    }
}

Export-ModuleMember -Function New-CachingProxySeedWorkspace, Publish-CachingProxySeedImage, Grant-CachingProxySeedVmRead, Remove-CachingProxySeedWorkspace
