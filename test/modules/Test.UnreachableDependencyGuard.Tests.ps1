<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42c9e2b4-6f1a-4d7e-9a3b-5e8d2f7c1a60
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dependency advisory supply-chain pester
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
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    The stash service must never import the unmaintained openpgp package.
.DESCRIPTION
    WHY THIS EXISTS. golang.org/x/crypto has an open advisory (GO-2026-5932) for
    its openpgp package, which the database lists with no fixed version. The
    stash service pins the module only for its ssh package, so the advisory is
    not reachable today. Nothing stops a later change from adding an openpgp
    import, and that import would make the advisory reachable without anyone
    deciding it should be. This guard fails the moment such an import appears,
    so the reachability question is answered again rather than assumed.
    Scope is every Go file under test/extension (vendor trees excluded), because
    the module graph is shared across those services.
    Run: Invoke-Pester -Path test/modules/Test.UnreachableDependencyGuard.Tests.ps1
#>

BeforeAll {
    # test/modules/<this file> -> test/modules -> test -> repo root.
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:ExtensionRoot = Join-Path $script:RepoRoot 'test/extension'
    $script:GoFiles = @(Get-ChildItem -LiteralPath $script:ExtensionRoot -Recurse -File -Filter '*.go' |
        Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' })
    $script:Importers = @($script:GoFiles | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw) -match '"golang\.org/x/crypto/openpgp(/[^"]*)?"'
    } | ForEach-Object { $_.FullName.Substring($script:RepoRoot.Length + 1) -replace '\\', '/' })
}

Describe 'the unmaintained openpgp package stays unimported (GO-2026-5932)' {
    It 'scans a non-trivial set of Go files, so an empty result cannot pass by accident' {
        $script:GoFiles.Count | Should -BeGreaterThan 100
    }
    It 'no Go file under test/extension imports golang.org/x/crypto/openpgp' {
        $script:Importers | Should -BeNullOrEmpty -Because 'openpgp is unmaintained and unsafe by design; an import makes its advisory reachable'
    }
    It 'the stash service still uses golang.org/x/crypto/ssh, so the module pin stays justified' {
        $ssh = Join-Path $script:RepoRoot 'test/extension/stash-service/server/internal/sshsrv/sshsrv.go'
        (Get-Content -LiteralPath $ssh -Raw) | Should -Match '"golang\.org/x/crypto/ssh"'
    }
}
