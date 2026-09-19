<#PSScriptInfo
.VERSION 2026.09.18
.GUID 428d1b23-c8e7-48f8-a3e7-5ef40beb397d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

function Invoke-ProductGlobalizationCheck {
    <#
    .SYNOPSIS
        Execute the owning product tests and fail when a test process or required row fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Node', 'Go', 'Pester')][string]$Kind,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Argument = @()
    )
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $powerShell = (Get-Process -Id $PID).Path
    $resultPath = $null
    try {
        if ($Kind -eq 'Node') {
            if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node is required for the product browser checks.' }
            $output = & node (Join-Path $root $Path) @Argument 2>&1 | Out-String
        } elseif ($Kind -eq 'Go') {
            $output = & $powerShell -NoProfile -File (Join-Path $root 'tools/Invoke-GoTest.ps1') -Path $Path 2>&1 | Out-String
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
    } finally {
        if ($resultPath -and (Test-Path -LiteralPath $resultPath)) { Remove-Item -LiteralPath $resultPath -Force }
    }
}
Export-ModuleMember -Function Invoke-ProductGlobalizationCheck
