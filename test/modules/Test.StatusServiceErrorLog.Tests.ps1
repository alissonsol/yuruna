<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42cd0b83-20cb-4b99-b723-7848da5d9f53
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service evidence
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:ServicePath = Join-Path $PSScriptRoot '../service/Start-StatusService.ps1'
    $script:ServiceAst = [Management.Automation.Language.Parser]::ParseFile($script:ServicePath, [ref]$null, [ref]$null)
    $definition = $script:ServiceAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-StatusServiceErrorLog'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $text = [IO.File]::ReadAllText($script:ServicePath)
    $writer = [regex]::Match($text, '(?ms)^function Write-ServerErr \{.*?^\}').Value.Replace('`$', '$')
    . ([scriptblock]::Create($writer))
}

Describe 'listener error evidence survives a new launch' {
    BeforeEach {
        $script:Runtime = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Runtime
    }

    It 'leaves an initial start with no prior error logs alone' {
        Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -Confirm:$false
        @(Get-ChildItem -LiteralPath $script:Runtime -Force).Count | Should -Be 0
    }

    It 'preserves explicit errors, their prior rotation and process stderr separately' {
        foreach ($name in 'server.err', 'server.err.old', 'server.stderr') {
            [IO.File]::WriteAllText((Join-Path $script:Runtime $name), "original:$name")
        }
        Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -Confirm:$false
        foreach ($name in 'server.err', 'server.err.old', 'server.stderr') {
            [IO.File]::ReadAllText((Join-Path $script:Runtime "$name.previous.1")) | Should -Be "original:$name"
            (Get-Item -LiteralPath (Join-Path $script:Runtime $name)).Length | Should -Be 0
        }
        # A new listener's stderr and explicit errors cannot overwrite these.
        [IO.File]::WriteAllText((Join-Path $script:Runtime 'server.stderr'), 'new native failure')
        [IO.File]::AppendAllText((Join-Path $script:Runtime 'server.err'), 'new route failure')
        [IO.File]::ReadAllText((Join-Path $script:Runtime 'server.err.previous.1')) | Should -Be 'original:server.err'
        [IO.File]::ReadAllText((Join-Path $script:Runtime 'server.stderr.previous.1')) | Should -Be 'original:server.stderr'
    }

    It 'retains the three most recent generations without unbounded archive growth' {
        foreach ($generation in 1..5) {
            [IO.File]::WriteAllText((Join-Path $script:Runtime 'server.err'), "generation:$generation")
            Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -Confirm:$false
        }
        foreach ($generation in 1..3) {
            [IO.File]::ReadAllText((Join-Path $script:Runtime "server.err.previous.$generation")) | Should -Be "generation:$(6 - $generation)"
        }
        @(Get-ChildItem -LiteralPath $script:Runtime -Filter 'server.err.previous.*').Count | Should -Be 3
    }

    It 'caps preserved bytes while retaining the latest failure at the tail' {
        $text = ('x' * 2048) + 'last-failure'
        [IO.File]::WriteAllText((Join-Path $script:Runtime 'server.stderr'), $text)
        Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -MaximumBytes 1024 -Confirm:$false
        $archive = Join-Path $script:Runtime 'server.stderr.previous.1'
        (Get-Item -LiteralPath $archive).Length | Should -Be 1024
        [IO.File]::ReadAllText($archive) | Should -Be $text.Substring($text.Length - 1024)
    }

    It 'refuses a directory destination before changing any current evidence' {
        [IO.File]::WriteAllText((Join-Path $script:Runtime 'server.err'), 'explicit evidence')
        [IO.File]::WriteAllText((Join-Path $script:Runtime 'server.stderr'), 'native evidence')
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Runtime 'server.stderr.previous.2')
        { Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -Confirm:$false } | Should -Throw '*not a regular file*'
        [IO.File]::ReadAllText((Join-Path $script:Runtime 'server.err')) | Should -Be 'explicit evidence'
        [IO.File]::ReadAllText((Join-Path $script:Runtime 'server.stderr')) | Should -Be 'native evidence'
        Join-Path $script:Runtime 'server.err.previous.1' | Should -Not -Exist
    }

    It 'preserves every original log if an archive cannot be opened' {
        [IO.File]::WriteAllText((Join-Path $script:Runtime 'server.err'), 'explicit evidence')
        $stderr = Join-Path $script:Runtime 'server.stderr'
        [IO.File]::WriteAllText($stderr, 'native evidence')
        $held = [IO.File]::Open($stderr, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -Confirm:$false } | Should -Throw
            [IO.File]::ReadAllText((Join-Path $script:Runtime 'server.err')) | Should -Be 'explicit evidence'
        } finally { $held.Dispose() }
        [IO.File]::ReadAllText($stderr) | Should -Be 'native evidence'
        @(Get-ChildItem -LiteralPath $script:Runtime -Filter '*.tmp').Count | Should -Be 0
    }

    It 'does not change evidence under WhatIf' {
        [IO.File]::WriteAllText((Join-Path $script:Runtime 'server.err'), 'failure')
        Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -WhatIf
        [IO.File]::ReadAllText((Join-Path $script:Runtime 'server.err')) | Should -Be 'failure'
        @(Get-ChildItem -LiteralPath $script:Runtime -Force).Count | Should -Be 1
    }

    It 'rotates explicit errors without changing the native stderr stream' {
        $serverLogFile = Join-Path $script:Runtime 'server.err'
        [IO.File]::WriteAllText($serverLogFile, ('x' * (1MB + 1)))
        $nativePath = Join-Path $script:Runtime 'server.stderr'
        $native = [IO.File]::Open($nativePath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            Write-ServerErr 'route failed'
            $bytes = [Text.Encoding]::UTF8.GetBytes('native failure after route rotation')
            $native.Write($bytes, 0, $bytes.Length)
        } finally { $native.Dispose() }
        [IO.File]::ReadAllText($nativePath) | Should -Be 'native failure after route rotation'
        [IO.File]::ReadAllText($serverLogFile) | Should -Match 'route failed'
        (Get-Item -LiteralPath "$serverLogFile.old").Length | Should -Be (1MB + 1)
    }

    It 'writes an explicit error in a literal runtime path containing brackets' {
        $directory = Join-Path $script:Runtime '[listener]'
        $null = [IO.Directory]::CreateDirectory($directory)
        $serverLogFile = Join-Path $directory 'server.err'
        Write-ServerErr 'literal path evidence'
        [IO.File]::ReadAllText($serverLogFile) | Should -Match 'literal path evidence'
    }

    It 'rejects linked log paths without changing their target' {
        $outside = Join-Path $TestDrive 'unrelated.txt'
        [IO.File]::WriteAllText($outside, 'unrelated evidence')
        $script:LinkedLogPath = Join-Path $script:Runtime 'server.err'
        $expectedOriginal = 'unrelated evidence'
        $modeledLink = $false
        try {
            $null = [IO.File]::CreateSymbolicLink($script:LinkedLogPath, $outside)
        } catch {
            if (-not $IsWindows) { throw }
            # Windows commonly requires a privilege this test account lacks.
            # Model a linked file's metadata while keeping real files on disk,
            # so the rejection and absence of evidence changes still execute.
            $modeledLink = $true
            $expectedOriginal = 'original log evidence'
            [IO.File]::WriteAllText($script:LinkedLogPath, $expectedOriginal)
            Mock Get-Item -ParameterFilter { $LiteralPath -eq $script:LinkedLogPath } -MockWith {
                [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::ReparsePoint }
            }
        }
        { Save-StatusServiceErrorLog -RuntimeDirectory $script:Runtime -Confirm:$false } | Should -Throw '*not a regular file*'
        if ($modeledLink) {
            Should -Invoke Get-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $script:LinkedLogPath }
        }
        [IO.File]::ReadAllText($script:LinkedLogPath) | Should -Be $expectedOriginal
        [IO.File]::ReadAllText($outside) | Should -Be 'unrelated evidence'
        "$script:LinkedLogPath.previous.1" | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $script:Runtime -Filter '*.tmp').Count | Should -Be 0
    }

    It 'preserves logs immediately before launch and redirects native stderr separately on both hosts' {
        $text = [IO.File]::ReadAllText($script:ServicePath)
        $preserve = $text.LastIndexOf('Save-StatusServiceErrorLog -RuntimeDirectory')
        $windowsLaunch = $text.IndexOf('$proc = Start-Process', $preserve)
        $posixLaunch = $text.IndexOf('& bash -c', $preserve)
        $preserve | Should -BeGreaterThan $text.IndexOf('refusing to launch it.')
        $windowsLaunch | Should -BeGreaterThan $preserve
        $posixLaunch | Should -BeGreaterThan $preserve
        $text.Substring($preserve, $posixLaunch - $preserve) | Should -Match '\$serverErrFile = Join-Path \$RuntimeDir "server.stderr"'
        $text.Substring($preserve, $posixLaunch - $preserve) | Should -Match '\$stdErr = Join-Path \$RuntimeDir "server.stderr"'
        $text | Should -Match ([regex]::Escape('err = "$(Join-Path $RuntimeDir ''server.err''), $(Join-Path $RuntimeDir ''server.stderr'')"'))
        $text | Should -Not -Match 'proceeding without it'
    }
}
