<#PSScriptInfo
.VERSION 2026.07.07
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
        Assert-Equal -Expected 9090 -Actual $d.Port -Because 'configured port honored'
    }
    It 'defaults the port to 8080 when absent' {
        $d = Resolve-StatusServiceStart -Config @{ statusService = @{ isEnabled = $true } }
        Assert-True $d.ShouldStart 'enabled -> ShouldStart'
        Assert-Equal -Expected 8080 -Actual $d.Port -Because 'default port'
    }
    It 'does not start when -NoServer is requested even if enabled' {
        $cfg = @{ statusService = @{ isEnabled = $true; port = 9090 } }
        $d = Resolve-StatusServiceStart -Config $cfg -NoServer
        Assert-True (-not $d.ShouldStart) '-NoServer overrides isEnabled'
        Assert-Equal -Expected 9090 -Actual $d.Port -Because 'port still resolved (for diagnostics)'
    }
    It 'does not start when statusService is disabled, missing, or config is null' {
        Assert-True (-not (Resolve-StatusServiceStart -Config @{ statusService = @{ isEnabled = $false } }).ShouldStart) 'disabled'
        Assert-True (-not (Resolve-StatusServiceStart -Config @{}).ShouldStart) 'no statusService node'
        Assert-True (-not (Resolve-StatusServiceStart -Config $null).ShouldStart) 'null config'
        Assert-Equal -Expected 8080 -Actual (Resolve-StatusServiceStart -Config $null).Port -Because 'null config -> default port'
    }
}

Describe 'Resolve-ConfigServiceStart' {
    It 'defaults to ENABLED on port 8443 when the node/flag is absent' {
        # Backward-compatible: existing configs without configService still serve
        # NAS creds (matches Start-HostConfigService.ps1's in-code defaults).
        $d = Resolve-ConfigServiceStart -Config @{}
        Assert-True $d.ShouldStart 'absent node -> enabled by default'
        Assert-Equal -Expected 8443 -Actual $d.Port -Because 'default config port'
        $dn = Resolve-ConfigServiceStart -Config $null
        Assert-True $dn.ShouldStart 'null config -> enabled by default'
        Assert-Equal -Expected 8443 -Actual $dn.Port -Because 'null config -> default port'
    }
    It 'honors isEnabled and the configured port' {
        $d = Resolve-ConfigServiceStart -Config @{ configService = @{ isEnabled = $true; port = 9443 } }
        Assert-True $d.ShouldStart 'enabled'
        Assert-Equal -Expected 9443 -Actual $d.Port -Because 'configured port honored'
    }
    It 'does not start when explicitly disabled' {
        Assert-True (-not (Resolve-ConfigServiceStart -Config @{ configService = @{ isEnabled = $false } }).ShouldStart) 'isEnabled false -> off'
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

    It 'aborts the entry point when the start script reports a tagged port conflict' {
        # Start-StatusService.ps1 throws a YurunaPortConflict-tagged exception
        # when the status port is held by another user / checkout; the gate must
        # `exit` so the cycle refuses instead of running blind. `exit` cannot be
        # asserted in-process (it would kill the test host), so drive it through
        # a child pwsh and assert on the exit code + the absence of a marker the
        # child writes only if the gate wrongly returned.
        $preludePath = (Resolve-Path (Join-Path $here 'Test.Prelude.psm1')).Path
        Assert-True (Test-Path $preludePath) 'prelude module resolves (guards against a false pass)'

        $tmp           = [System.IO.Path]::GetTempPath()
        $conflictStub  = Join-Path $tmp ("yrn-confstub-"  + [guid]::NewGuid().ToString('N') + ".ps1")
        $childScript   = Join-Path $tmp ("yrn-confchild-" + [guid]::NewGuid().ToString('N') + ".ps1")
        $continuedFlag = Join-Path $tmp ("yrn-continued-" + [guid]::NewGuid().ToString('N'))

        Set-Content -LiteralPath $conflictStub -Value @'
param([int]$Port,[switch]$Restart)
$ex = [System.InvalidOperationException]::new("Status-service port $Port held; refusing to start.")
$ex.Data['YurunaPortConflict'] = $true
throw $ex
'@
        Set-Content -LiteralPath $childScript -Value @"
Import-Module '$preludePath' -Force -DisableNameChecking
`$null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ isEnabled = `$true; port = 8123 } } -StartScript '$conflictStub' -Restart
Set-Content -LiteralPath '$continuedFlag' -Value 'CONTINUED'
"@
        try {
            & pwsh -NoProfile -File $childScript *> $null
            $rc = $LASTEXITCODE
            Assert-True ($rc -ne 0) "gate exits non-zero on conflict (rc=$rc)"
            Assert-True (-not (Test-Path $continuedFlag)) 'gate did not return/continue past the conflict'
        } finally {
            Remove-Item -LiteralPath $conflictStub, $childScript, $continuedFlag -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
}
