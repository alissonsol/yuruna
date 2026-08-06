<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42f9c2b8-3d47-4e51-8a09-b6e7d1c40f52
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab vault credential storage
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

# Lab-level knowledge shared by the lab entry points: what a lab vault records,
# where a machine's labs put their storage, and which credentials the machine
# already holds. One module owns the lab-vault format so a reader and a writer
# cannot drift on it.
#
# The two vaults this module touches are NOT interchangeable:
#   * the LAB vault (lab.<name>.vault.yml) is per-lab and deliberately COPYABLE
#     to the lab's other machines;
#   * the HOST vault (vault.yml) is per-machine and is what the harness reads.
# Where they carry the same credential they must agree, which is the reason
# Get-YurunaMachineCredential exists -- see its description.
#
# Everything here is READ-ONLY. Nothing in this module creates, rotates, or
# stores a credential.

# Turns a lab vault's poolPath ('<root>/yuruna.pool') into the storage root.
# Both separators are handled explicitly rather than via Split-Path, which
# recognizes only the RUNNING platform's separator -- a Windows-written path
# would otherwise collapse to nothing when this is evaluated anywhere else
# (the tests, and a vault copied between machines).
function Get-LabRootFromPoolPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$PoolPath)
    $p = "$PoolPath".Trim().TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $idx = [Math]::Max($p.LastIndexOf('/'), $p.LastIndexOf('\'))
    if ($idx -lt 0) { return '' }        # bare name, no parent to report
    if ($idx -eq 0) { return '/' }       # '/yuruna.pool' -> the filesystem root
    return $p.Substring(0, $idx)
}

<#
.SYNOPSIS
Reduces the pool paths recorded by the labs on a machine to the DISTINCT storage roots they imply. Pure: the caller supplies the paths, so the agreement rule is testable without lab vaults on disk.
.DESCRIPTION
Returns 0, 1, or several roots, and the count is the answer the caller acts on: exactly one means every lab agrees and a new lab can adopt it; several means the machine's labs disagree and the operator has to say which one applies; none means there is nothing to adopt.

Disagreement is reported rather than resolved. Picking one would put a new lab's folders somewhere its siblings are not, which is precisely the mistake an inferred root is supposed to prevent.

WRAP THE CALL IN @(). PowerShell unrolls a single-element array on return, so the common one-lab case arrives as a bare string; an unwrapped `(Select-...)[0]` then indexes the first CHARACTER of the root ('/' or a drive letter) rather than the first root, and `.Count` reads as the string length.
#>
function Select-YurunaLabStorageRoot {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()][string[]]$PoolPath)
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($PoolPath)) {
        $root = Get-LabRootFromPoolPath -PoolPath $p
        if ($root -and -not $roots.Contains($root)) { $roots.Add($root) }
    }
    return $roots.ToArray()
}

<#
.SYNOPSIS
Resolves the vault key a logical user's password is stored under: the users.yml `vaultKey` when it is set, else the user name itself. Pure.
.DESCRIPTION
Mirrors the rule Get-Password applies, so a caller reading the vault directly addresses the very slot the mount path will later read. A blank or whitespace-only mapping counts as unset -- that is the legacy shape where the user name IS its own key.
#>
function Resolve-YurunaLabVaultKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$LogicalUser,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$MappedVaultKey
    )
    if ([string]::IsNullOrWhiteSpace($MappedVaultKey)) { return $LogicalUser }
    return $MappedVaultKey.Trim()
}

<#
.SYNOPSIS
Returns the storage root recorded by a lab already on this machine, or '' when there is none or the machine's labs disagree about it. Warns on disagreement.
.DESCRIPTION
Lets a second lab on a storage machine skip -Root instead of re-deriving a path the first lab already fixed -- where a typo would silently create a second, unshared set of folders beside the shared ones. Unreadable vault files are skipped, not fatal: one corrupt file must not block a machine whose other labs answer the question.
#>
function Get-YurunaLabStorageRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VaultDir)
    if (-not (Test-Path -LiteralPath $VaultDir)) { return '' }
    # Creating a lab needs no YAML at all -- only reading one back does. Without
    # powershell-yaml the discovery is simply unavailable and -Root stays
    # required, which the caller reports; it is not a per-file read failure.
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { return '' }
    $poolPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $VaultDir -Filter 'lab.*.vault.yml' -File -ErrorAction SilentlyContinue)) {
        try {
            $doc = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Yaml -Ordered
            if (-not ($doc -is [System.Collections.IDictionary]) -or -not ($doc['lab'] -is [System.Collections.IDictionary])) { continue }
            $poolPaths.Add([string]$doc['lab']['poolPath'])
        } catch {
            Write-Verbose "Skipping unreadable lab vault $($f.Name): $($_.Exception.Message)"
        }
    }
    $roots = @(Select-YurunaLabStorageRoot -PoolPath $poolPaths.ToArray())
    if ($roots.Count -eq 1) { return $roots[0] }
    if ($roots.Count -gt 1) {
        Write-Warning "Labs on this machine record different storage roots ($($roots -join ', ')); pass -Root to say which one this lab uses."
    }
    return ''
}

<#
.SYNOPSIS
Reads a lab vault written by New-Lab.ps1 and returns its credential name to password map. Returns an empty map when the file is missing or unreadable.
.DESCRIPTION
The lab vault is the copyable half of the credential story: the same passwords have to reach every other machine in the lab, and a DPAPI-bound store would not decrypt after the copy. Reading it is how a caller adopts the values a lab already has instead of minting new ones the rest of the lab has never seen.
#>
function Get-YurunaLabVaultPassword {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)
    $out = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Write-Warning "powershell-yaml is not available; cannot read the lab vault at $Path."
        return $out
    }
    try {
        $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered
        if (-not ($doc -is [System.Collections.IDictionary]) -or -not ($doc['users'] -is [System.Collections.IDictionary])) { return $out }
        foreach ($k in $doc['users'].Keys) {
            $entry = $doc['users'][$k]
            if ($entry -is [System.Collections.IDictionary]) { $out[[string]$k] = [string]$entry['password'] }
        }
    } catch {
        Write-Warning "Could not read the lab vault at ${Path}: $($_.Exception.Message)"
    }
    return $out
}

<#
.SYNOPSIS
Returns the password this machine already holds for a logical user, or '' when it holds none. Strictly read-only -- it never generates, stores, or overwrites anything.
.DESCRIPTION
The share accounts are machine-wide: one `yuruna-pool` OS account serves every lab whose storage lives here. Minting a second password for it would put a value in a new lab vault that the OS account, the SMB server, and the lab's other machines have never seen, and every mount driven from that vault would fail against a share that never had it.

The lookup goes through the same users.yml vaultKey indirection Get-Password uses, so it reads the very slot the mount path later reads. Test-VaultEntry is checked FIRST because Get-Password on a vaultKey-less user with no entry would auto-generate one as a side effect -- silently creating the credential this function is only supposed to report on.

Returns '' when the authentication extension is not loaded, so a caller that runs before (or without) it degrades to generating rather than failing.
#>
function Get-YurunaMachineCredential {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$LogicalUser)
    if (-not (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-Password -ErrorAction SilentlyContinue)) {
        Write-Verbose "Authentication extension not loaded; no stored credential can be read for '$LogicalUser'."
        return ''
    }
    $mapped = ''
    if (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) {
        try {
            $mapped = [string](Get-EffectiveUser -LogicalUser $LogicalUser).vaultKey
        } catch {
            Write-Verbose "Get-EffectiveUser('$LogicalUser') failed: $($_.Exception.Message)"
        }
    }
    $key = Resolve-YurunaLabVaultKey -LogicalUser $LogicalUser -MappedVaultKey $mapped
    try {
        if (-not (Test-VaultEntry -VaultKey $key)) { return '' }
        return [string](Get-Password -Username $LogicalUser)
    } catch {
        Write-Verbose "Reading the stored credential for '$LogicalUser' failed: $($_.Exception.Message)"
        return ''
    }
}

Export-ModuleMember -Function `
    Select-YurunaLabStorageRoot, Resolve-YurunaLabVaultKey, `
    Get-YurunaLabStorageRoot, Get-YurunaLabVaultPassword, Get-YurunaMachineCredential

# Copyright (c) 2019-2026 by Alisson Sol et al.
