<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42c6a4b0-7182-4394-8ea5-1a2b3c4d5e6f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test prelude statusservice pester
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
    Pester coverage for Test.Prelude.psm1's shared status-service gate
    (Resolve-StatusServiceStart + Start-YurunaStatusServiceIfEnabled) -- the one
    place the entry-point trio decides whether/how to start the status server.
.DESCRIPTION
    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    Start-YurunaStatusServiceIfEnabled is exercised against a stub start script
    so the gate is verified without launching a real server.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Prelude.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'Resolve-StatusServiceStart' {
    It 'starts on enabled config and resolves the configured port' {
        $cfg = @{ statusService = @{ isEnabled = $true; port = 9090 } }
        $d = Resolve-StatusServiceStart -Config $cfg
        Assert-True $d.ShouldStart 'enabled -> ShouldStart'
        Assert-Equal 9090 $d.Port 'configured port honored'
    }
    It 'defaults the port to 8080 when absent' {
        $d = Resolve-StatusServiceStart -Config @{ statusService = @{ isEnabled = $true } }
        Assert-True $d.ShouldStart 'enabled -> ShouldStart'
        Assert-Equal 8080 $d.Port 'default port'
    }
    It 'does not start when -NoServer is requested even if enabled' {
        $cfg = @{ statusService = @{ isEnabled = $true; port = 9090 } }
        $d = Resolve-StatusServiceStart -Config $cfg -NoServer
        Assert-True (-not $d.ShouldStart) '-NoServer overrides isEnabled'
        Assert-Equal 9090 $d.Port 'port still resolved (for diagnostics)'
    }
    It 'does not start when statusService is disabled, missing, or config is null' {
        Assert-True (-not (Resolve-StatusServiceStart -Config @{ statusService = @{ isEnabled = $false } }).ShouldStart) 'disabled'
        Assert-True (-not (Resolve-StatusServiceStart -Config @{}).ShouldStart) 'no statusService node'
        Assert-True (-not (Resolve-StatusServiceStart -Config $null).ShouldStart) 'null config'
        Assert-Equal 8080 (Resolve-StatusServiceStart -Config $null).Port 'null config -> default port'
    }
}

Describe 'Start-YurunaStatusServiceIfEnabled' {
    # Stub start script records its args to a marker file, so the gate is
    # verified end-to-end without launching a real status server.
    $stub = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-startstub-" + [guid]::NewGuid().ToString('N') + ".ps1")
    $marker = "$stub.invoked"
    Set-Content -Path $stub -Value "param([int]`$Port,[switch]`$Restart) Set-Content -LiteralPath '$marker' -Value (`"port=`$Port restart=`$Restart`")"

    It 'invokes the start script with the resolved port when enabled' {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $d = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ isEnabled = $true; port = 8123 } } -StartScript $stub
        Assert-True $d.ShouldStart 'decision says start'
        Assert-True (Test-Path $marker) 'start script was invoked'
        Assert-True ([bool]((Get-Content $marker -Raw) -match 'port=8123')) 'port forwarded'
        Assert-True ([bool]((Get-Content $marker -Raw) -match 'restart=False')) 'no -Restart by default'
    }
    It 'passes -Restart through when requested' {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ isEnabled = $true } } -StartScript $stub -Restart
        Assert-True ([bool]((Get-Content $marker -Raw) -match 'restart=True')) '-Restart forwarded'
    }
    It 'does NOT invoke the start script when disabled or -NoServer' {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ isEnabled = $false } } -StartScript $stub
        Assert-True (-not (Test-Path $marker)) 'disabled -> not invoked'
        $null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ isEnabled = $true } } -StartScript $stub -NoServer
        Assert-True (-not (Test-Path $marker)) '-NoServer -> not invoked'
    }

    Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
}
