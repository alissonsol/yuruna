<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42d98439-243f-4c94-a7cc-22b4d65803d8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host identity seed
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

function Resolve-SeededHostId {
    <#
    .SYNOPSIS
        Resolve the hardware-derived host identity lazily, or allow a random fallback.
    .DESCRIPTION
        Both runtime and performance identity writers use this policy. Importing
        this module does not read hardware; derivation happens only when a caller
        needs to create host.uuid. Unavailable hardware never prevents startup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:YURUNA_HOST_ID_SEED -eq 'random') { return '' }
    if (-not (Get-Command Get-HostIdentitySeedUuid -ErrorAction SilentlyContinue)) {
        $module = Join-Path $PSScriptRoot 'Test.HostIdentity.psm1'
        if (-not (Test-Path -LiteralPath $module)) { return '' }
        # A forced reload would evict the module from callers that already hold it.
        try { Import-Module $module -ErrorAction Stop } catch {
            Write-Verbose "Resolve-SeededHostId: Test.HostIdentity unavailable: $($_.Exception.Message)"
            return ''
        }
    }
    # Hardware keys may require the primed sudo cache; sudo -n never prompts.
    try { return [string](Get-HostIdentitySeedUuid -AllowSudo) } catch {
        Write-Verbose "Resolve-SeededHostId: derivation failed: $($_.Exception.Message)"
        return ''
    }
}

Export-ModuleMember -Function Resolve-SeededHostId
