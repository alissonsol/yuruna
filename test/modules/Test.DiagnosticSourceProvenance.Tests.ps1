<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42c69585-1569-4e82-88e0-b6b74d6c4310
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic provenance pester
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
    Verifies standalone guest revision evidence without adjacent modules.
#>

# --- REGION: Test setup
BeforeAll {
    $script:diagnosticPath = Join-Path $PSScriptRoot '../../automation/Get-SystemDiagnostic.ps1'
    $script:ast = [Management.Automation.Language.Parser]::ParseFile($script:diagnosticPath, [ref]$null, [ref]$null)
    foreach ($name in @('Get-DiagnosticSourceFile', 'Get-DiagnosticSourceProvenance', 'Invoke-DiagnosticBoundedCommand')) {
        $node = $script:ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
}

# --- REGION: Test cases
Describe 'Standalone source provenance' {
    BeforeEach {
        $script:checkout = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:checkout 'automation'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:checkout 'project/tools'))
        [IO.File]::WriteAllText((Join-Path $script:checkout 'VERSION'), 'fixture')
    }

    It 'reports archive revisions and exact working source bytes independently of VERSION' {
        [IO.File]::WriteAllText((Join-Path $script:checkout '.yuruna-revision'), ('A' * 40) + "`n")
        [IO.File]::WriteAllText((Join-Path $script:checkout 'project/.yuruna-revision'), 'b' * 64)
        $helper = Join-Path $script:checkout 'project/tools/example-workload.sh'
        [IO.File]::WriteAllText($helper, '# effective local helper')
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.revision | Should -BeExactly ('a' * 40)
        $result.framework.source | Should -Be 'archive'
        $result.project.revision | Should -BeExactly ('b' * 64)
        $result.project.hashes['tools/example-workload.sh'].sha256 | Should -BeExactly (Get-FileHash $helper).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($helper, '# edited helper')
        $changed = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $changed.project.revision | Should -Be $result.project.revision
        $changed.project.hashes['tools/example-workload.sh'].sha256 | Should -Not -Be $result.project.hashes['tools/example-workload.sh'].sha256
    }

    It 'reports absent revisions rather than inheriting a parent Git repository' -Skip:(-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        & git -C $script:checkout init --quiet
        & git -C $script:checkout -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty --quiet -m fixture
        $LASTEXITCODE | Should -Be 0
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.state | Should -Be 'present'
        $result.framework.source | Should -Be 'git'
        $result.framework.revision | Should -Match '^[a-f0-9]{40}$'
        $result.project.source | Should -Be 'none'
        $result.project.revision | Should -BeNullOrEmpty
    }

    It 'uses actual Git HEAD over a stale archive marker' -Skip:(-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        [IO.File]::WriteAllText((Join-Path $script:checkout '.yuruna-revision'), 'a' * 40)
        & git -C $script:checkout init --quiet
        & git -C $script:checkout -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty --quiet -m fixture
        $LASTEXITCODE | Should -Be 0
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.source | Should -Be 'git'
        $result.framework.revision | Should -Not -Be ('a' * 40)
    }

    It 'never emits an invalid revision marker or repository URL' {
        $privateText = 'https://fixture-token@example.invalid/repository'
        [IO.File]::WriteAllText((Join-Path $script:checkout '.yuruna-revision'), $privateText)
        [IO.File]::WriteAllText((Join-Path $script:checkout '.yuruna-origin'), $privateText)
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.state | Should -Be 'invalid'
        ($result | ConvertTo-Json -Depth 6) | Should -Not -Match 'fixture-token|example.invalid'
    }

    It 'rejects oversized markers and source files before hashing' {
        [IO.File]::WriteAllText((Join-Path $script:checkout '.yuruna-revision'), 'a' * 257)
        $file = Join-Path $script:checkout 'automation/fetch-and-execute.sh'
        $stream = [IO.File]::Create($file)
        try { $stream.SetLength(8388609) } finally { $stream.Dispose() }
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.revision | Should -BeNullOrEmpty
        $result.framework.hashes['automation/fetch-and-execute.sh'].state | Should -Be 'unavailable'
    }

    It 'rejects linked source parents and linked revision files' -Skip:($IsWindows) {
        $outside = Join-Path $TestDrive 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'example-workload.sh'), 'outside')
        Remove-Item (Join-Path $script:checkout 'project/tools') -Recurse -Force
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:checkout 'project/tools') -Target $outside
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:checkout '.yuruna-revision') -Target (Join-Path $outside 'example-workload.sh')
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.revision | Should -BeNullOrEmpty
        $result.project.hashes['tools/example-workload.sh'].state | Should -Be 'unavailable'
    }

    It 'rejects named pipes before reading revision markers or hashing helpers' -Skip:($IsWindows) {
        & mkfifo -- (Join-Path $script:checkout '.yuruna-revision') (Join-Path $script:checkout 'automation/fetch-and-execute.sh')
        $LASTEXITCODE | Should -Be 0
        Get-DiagnosticSourceFile -Root $script:checkout -RelativePath '.yuruna-revision' | Should -BeNullOrEmpty
        Get-DiagnosticSourceFile -Root $script:checkout -RelativePath 'automation/fetch-and-execute.sh' | Should -BeNullOrEmpty
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.revision | Should -BeNullOrEmpty
        $result.framework.hashes['automation/fetch-and-execute.sh'].state | Should -Be 'unavailable'
    }

    It 'treats Git timeout and incomplete output as unavailable evidence' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:checkout '.git'))
        Mock Invoke-DiagnosticBoundedCommand {
            return @{ Started = $true; ExitCode = -1; TimedOut = $true; StdOut = ('f' * 40); OutputTruncated = $false; DrainTimedOut = $false }
        }
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot $script:checkout
        $result.framework.state | Should -Be 'unavailable'
        $result.framework.revision | Should -BeNullOrEmpty
        Should -Invoke Invoke-DiagnosticBoundedCommand -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 2 -and $MaxCapturedChars -eq 4096 }
    }

    It 'works without any checkout and remains JSON serializable' {
        $result = Get-DiagnosticSourceProvenance -CheckoutRoot ''
        $result.framework.state | Should -Be 'unavailable'
        $result.project.state | Should -Be 'unavailable'
        { $result | ConvertTo-Json -Depth 6 } | Should -Not -Throw
    }

    It 'collects provenance even when the expensive project gap scans are skipped' {
        $source = Get-Content $script:diagnosticPath -Raw
        $source.IndexOf('Get-DiagnosticSourceProvenance -CheckoutRoot $script:DiagnosticEvidenceRoot') |
            Should -BeLessThan $source.IndexOf('if ($SkipProjectGaps)')
    }
}
