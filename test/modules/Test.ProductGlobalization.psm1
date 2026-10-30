<#PSScriptInfo
.VERSION 2026.10.30
.GUID 428d1b23-c8e7-48f8-a3e7-5ef40beb397d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

# Checks that passed in this process, by kind, path and arguments. A product
# check reads the tree and writes nothing to it, so a second identical call in
# the same suite process would repeat the same run to the same verdict. A
# failure is never kept: every call that failed runs again and reports itself.
$script:PassedProductChecks = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

function Invoke-ProductGlobalizationCheck {
    <#
    .SYNOPSIS
        Execute the owning product tests and fail when a test process or required row fails.
    .DESCRIPTION
        A check that already passed in this process with the same kind, path
        and arguments is not run again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Node', 'Go', 'Pester', 'JsTest')][string]$Kind,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Argument = @()
    )
    $passedKey = ConvertTo-Json -InputObject @($Kind, $Path, @($Argument)) -Compress
    if ($script:PassedProductChecks.Contains($passedKey)) { return }
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $powerShell = (Get-Process -Id $PID).Path
    $resultPath = $null
    try {
        if ($Kind -eq 'Node') {
            if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node is required for the product browser checks.' }
            $output = & node (Join-Path $root $Path) @Argument 2>&1 | Out-String
        } elseif ($Kind -eq 'Go') {
            $output = & $powerShell -NoProfile -File (Join-Path $root 'tools/Invoke-GoTest.ps1') -Path $Path 2>&1 | Out-String
        } elseif ($Kind -eq 'JsTest') {
            $output = & $powerShell -NoProfile -File (Join-Path $root 'tools/Invoke-JsTest.ps1') -Path $Path -Quiet 2>&1 | Out-String
        } else {
            $resultPath = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-product-' + [guid]::NewGuid().ToString('N') + '.xml')
            $output = & $powerShell -NoProfile -File (Join-Path $root 'tools/_InvokeOneSuite.ps1') -Suite (Join-Path $root $Path) -Xml $resultPath 2>&1 | Out-String
        }
        if ($LASTEXITCODE -ne 0) { throw "$Kind product check failed ($Path): $output" }
        if ($Kind -eq 'Pester') {
            if (-not (Test-Path -LiteralPath $resultPath)) { throw "Product suite produced no result: $Path" }
            $result = ([xml][IO.File]::ReadAllText($resultPath)).'test-results'
            if ([int]$result.total -le 0 -or [int]$result.failures -ne 0 -or [int]$result.errors -ne 0 -or
                [int]$result.skipped -ne 0 -or [int]$result.ignored -ne 0 -or [int]$result.'not-run' -ne 0) {
                throw "Product suite has failed or unverified rows ($Path): $output"
            }
        }
        [void]$script:PassedProductChecks.Add($passedKey)
    } finally {
        if ($resultPath -and (Test-Path -LiteralPath $resultPath)) { Remove-Item -LiteralPath $resultPath -Force }
    }
}
function Invoke-ProductGlobalizationCheckSet {
    <#
    .SYNOPSIS
        Execute several product checks at once and fail when any of them fails.
    .DESCRIPTION
        Each check already runs in processes of its own, so running them
        together changes no verdict, only how long the set takes. Every check
        runs to its end, and every failure is reported, in the order given.
    .PARAMETER Check
        Hashtables with the Kind and Path of each Invoke-ProductGlobalizationCheck call.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable[]]$Check)
    $module = $PSCommandPath
    $failures = @(0..($Check.Count - 1) | ForEach-Object -ThrottleLimit $Check.Count -Parallel {
            $index = $_
            $item = ($using:Check)[$index]
            # A runspace of this pool starts without the module, so nothing is
            # reloaded and no other importer loses it.
            Import-Module $using:module -DisableNameChecking
            try {
                Invoke-ProductGlobalizationCheck -Kind $item.Kind -Path $item.Path
            } catch { [pscustomobject]@{ Index = $index; Message = $_.Exception.Message } }
        })
    if ($failures.Count -gt 0) {
        throw (($failures | Sort-Object Index | ForEach-Object Message) -join "`n")
    }
}
Export-ModuleMember -Function Invoke-ProductGlobalizationCheck, Invoke-ProductGlobalizationCheckSet
