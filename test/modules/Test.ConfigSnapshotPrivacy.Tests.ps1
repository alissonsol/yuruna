<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42ec7f23-19ab-4f5f-9dc3-533d820895fa
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config privacy pester
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

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Force
}

Describe 'config reads do not publish credential snapshots' {
    It 'keeps synthetic tokens in memory on cache misses, hits and forced reads' -ForEach @(
        @{ RuntimeEnabled = $true }
        @{ RuntimeEnabled = $false }
    ) {
        $savedRuntime = $env:YURUNA_RUNTIME_DIR
        $savedUsername = $env:USERNAME
        $fakeUser = 'snapshot-fixture-' + [guid]::NewGuid().ToString('n')
        $fallback = Join-Path ([IO.Path]::GetTempPath()) "yuruna-$fakeUser"
        $runtime = Join-Path $TestDrive 'runtime'
        $config = Join-Path $TestDrive 'config.yml'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        Set-Content -LiteralPath $config -Value "repositories:`n  ghToken: fixture-token`nsecrets:`n  password: fixture-password"
        try {
            $env:USERNAME = $fakeUser
            $env:YURUNA_RUNTIME_DIR = if ($RuntimeEnabled) { $runtime } else { '' }
            Clear-TestConfigCache -Confirm:$false
            foreach ($force in @($false, $false, $true)) {
                $doc = Read-TestConfig -Path $config -NoCache:$force -ThrowOnError
                $doc.repositories.ghToken | Should -Be 'fixture-token'
                $doc.secrets.password | Should -Be 'fixture-password'
            }
            @(Get-ChildItem -LiteralPath $runtime -Force).Count | Should -Be 0
            Test-Path -LiteralPath $fallback | Should -BeFalse
        } finally {
            $env:YURUNA_RUNTIME_DIR = $savedRuntime
            $env:USERNAME = $savedUsername
            Clear-TestConfigCache -Confirm:$false
            if (Test-Path -LiteralPath $fallback) { Remove-Item -LiteralPath $fallback -Recurse -Force }
        }
    }
}
