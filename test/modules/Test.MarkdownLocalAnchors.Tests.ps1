<#PSScriptInfo
.VERSION 2026.10.22
.GUID 426b49a6-dfe5-4532-ab37-a68c35084d07
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test docs anchors markdown pester
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
    Hold the local-anchor parser to one fence grammar, one output shape and one
    failure shape, and hold both documentation tools to reading through it.
.DESCRIPTION
    A nonlocalized document is absent from the generated anchor index, so the
    pointer gate and the link-catalog publisher each ask the document itself
    which anchors it carries. An anchor quoted inside a fenced example is text,
    not an address. If the two tools drew that line differently, one would
    publish an id the other rejects, and nothing but a reader following the
    link would find out.

    Every case writes its own Markdown with explicit line endings. A working
    copy carries LF or CRLF depending on the host and the checkout settings,
    and the same document has to yield the same ids under both.

    Run: Invoke-Pester -Path test/modules/Test.MarkdownLocalAnchors.Tests.ps1
#>

BeforeDiscovery {
    $first = '<a id="42abcdef-0001"></a>'
    $second = '<a id="42abcdef-0002"></a>'
    $third = '<a id="42abcdef-0003"></a>'
    $tab = "`t"

    # Line is the document, one entry per line; Expected is what the parser
    # returns for it, in order.
    $grammar = @(
        @{ Name = 'returns an anchor that stands alone on its line'
            Line = @($first, '', '# Inventory'); Expected = @('42abcdef-0001') }
        @{ Name = 'allows spaces and tabs around the anchor'
            Line = @(('   ' + $tab + $first + ' ' + $tab)); Expected = @('42abcdef-0001') }
        @{ Name = 'keeps file order instead of sorting'
            Line = @($second, '# Two', $first, '# One', $third, '# Three')
            Expected = @('42abcdef-0002', '42abcdef-0001', '42abcdef-0003') }
        @{ Name = 'reports a repeated id once for every line that carries it'
            Line = @($first, '# One', $first, '# Again'); Expected = @('42abcdef-0001', '42abcdef-0001') }
        @{ Name = 'returns ids of any file prefix and leaves the prefix check to the caller'
            Line = @('<a id="42aaaaaa-0001"></a>', '<a id="42bbbbbb-00ff"></a>')
            Expected = @('42aaaaaa-0001', '42bbbbbb-00ff') }
        @{ Name = 'ignores an anchor that shares its line with other text'
            Line = @(($first + ' text'), ('# Inventory ' + $second), ('text ' + $third)); Expected = @() }
        @{ Name = 'ignores ids outside the stable shape'
            Line = @('<a id="42ABCDEF-0001"></a>', '<a id="42abcde-0001"></a>', '<a id="41abcdef-0001"></a>',
                '<a id="42abcdef-00001"></a>', '<a id="42abcdef-001"></a>', "<a id='42abcdef-0001'></a>",
                '<a id="42abcdef-0001">', '<a name="42abcdef-0001"></a>', '<a id="installation"></a>')
            Expected = @() }
        @{ Name = 'returns nothing for a document without anchors'
            Line = @('# Inventory', '', 'No anchors here.'); Expected = @() }
        @{ Name = 'excludes a backtick fence'
            Line = @('```', $first, '```'); Expected = @() }
        @{ Name = 'excludes a tilde fence'
            Line = @('~~~', $first, '~~~'); Expected = @() }
        @{ Name = 'excludes a fence that carries an info string'
            Line = @('```markdown title="example"', $first, '```', '~~~ text', $second, '~~~'); Expected = @() }
        @{ Name = 'accepts a backtick in the info string of a tilde fence'
            Line = @('~~~ a`b', $first, '~~~'); Expected = @() }
        @{ Name = 'does not open a fence on a backtick run whose info string holds a backtick'
            Line = @('``` a`b', $first); Expected = @('42abcdef-0001') }
        @{ Name = 'excludes a fence indented up to three spaces'
            Line = @('   ```', $first, '   ```', ' ~~~', $second, '  ~~~'); Expected = @() }
        @{ Name = 'does not read four spaces or a tab before a run as a fence'
            Line = @('    ```', $first, ($tab + '~~~'), $second); Expected = @('42abcdef-0001', '42abcdef-0002') }
        @{ Name = 'closes only on the character that opened the fence'
            Line = @('```', '~~~', $first, '```', $second); Expected = @('42abcdef-0002') }
        @{ Name = 'keeps a shorter inner run inside a longer fence'
            Line = @('````', '```', $first, '```', $second, '````', $third); Expected = @('42abcdef-0003') }
        @{ Name = 'closes on a longer run followed by blanks'
            Line = @('```', $first, ('`````  ' + $tab), $second); Expected = @('42abcdef-0002') }
        @{ Name = 'does not close on a run followed by text'
            Line = @('```', '``` not a closing fence', $first, '```', $second); Expected = @('42abcdef-0002') }
        @{ Name = 'does not close on a run indented four spaces'
            Line = @('```', '    ```', $first, '```', $second); Expected = @('42abcdef-0002') }
        @{ Name = 'excludes everything after a fence that never closes'
            Line = @($second, '```', $first, '# Inventory'); Expected = @('42abcdef-0002') }
        @{ Name = 'returns the anchors before, between and after fences'
            Line = @($first, '```', $second, '```', $third, '~~~', $second, '~~~', $first)
            Expected = @('42abcdef-0001', '42abcdef-0003', '42abcdef-0001') }
    )
    $ending = @(
        @{ Ending = 'LF'; Separator = "`n" }
        @{ Ending = 'CRLF'; Separator = "`r`n" }
    )
    $script:GrammarCase = @(foreach ($style in $ending) {
            foreach ($case in $grammar) {
                @{
                    Name = $case.Name; Line = $case.Line; Expected = $case.Expected
                    Ending = $style.Ending; Separator = $style.Separator
                }
            }
        })
    $script:ToolCase = @(
        @{ Tool = 'tools/Test-RegionAnchors.ps1' }
        @{ Tool = 'tools/Update-LinkCatalog.ps1' }
    )
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:ParserModule = Join-Path $script:RepoRoot 'tools/Markdown.LocalAnchors.psm1'
    Import-Module $script:ParserModule -Force

    $script:First = '<a id="42abcdef-0001"></a>'
    $script:Second = '<a id="42abcdef-0002"></a>'
    $script:Third = '<a id="42abcdef-0003"></a>'

    function Write-AnchorDocument {
        <#
        .SYNOPSIS
            Write one Markdown fixture with exactly the given bytes; return its path.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$Directory,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
            [switch]$ByteOrderMark
        )
        $path = Join-Path $Directory ([guid]::NewGuid().ToString('n') + '.md')
        [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($ByteOrderMark.IsPresent))
        return $path
    }

    function Get-TypeLabel {
        <#
        .SYNOPSIS
            Name the type of a value for a failure message, including no value at all.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Position = 0)][AllowNull()]$Value)
        if ($null -eq $Value) { return 'no value' }
        return $Value.GetType().FullName
    }
}

Describe 'the local-anchor parser reads one fence grammar' {

    It '<Name> (<Ending> line endings)' -ForEach $script:GrammarCase {
        $text = ($Line -join $Separator) + $Separator
        $path = Write-AnchorDocument -Directory $TestDrive -Text $text
        $actual = @(Get-LocalSbomAnchorId -LiteralPath $path)
        Assert-Equal -Expected $Expected.Count -Actual $actual.Count `
            -Because "returned [$($actual -join ', ')]"
        Assert-StringEqual -Expected ($Expected -join ', ') -Actual ($actual -join ', ') `
            -Because 'the ids or their order changed'
    }

    It 'returns nothing for an empty file' {
        $path = Write-AnchorDocument -Directory $TestDrive -Text ''
        Assert-Equal -Expected 0 -Actual ([IO.FileInfo]::new($path)).Length -Because 'the fixture is not empty'
        Assert-Equal -Expected 0 -Actual @(Get-LocalSbomAnchorId -LiteralPath $path).Count
    }

    It 'reads an anchor on a last line that has no line ending' {
        $path = Write-AnchorDocument -Directory $TestDrive -Text ("# Inventory`n`n" + $script:First)
        Assert-StringEqual -Expected '42abcdef-0001' -Actual (@(Get-LocalSbomAnchorId -LiteralPath $path) -join ', ')
    }

    It 'reads an anchor on the first line behind a UTF-8 byte-order mark' {
        $path = Write-AnchorDocument -Directory $TestDrive -Text ($script:First + "`n# Inventory`n") -ByteOrderMark
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-Equal -Expected 0xEF -Actual $bytes[0] -Because 'the fixture carries no byte-order mark'
        Assert-StringEqual -Expected '42abcdef-0001' -Actual (@(Get-LocalSbomAnchorId -LiteralPath $path) -join ', ')
    }

    It 'treats a lone carriage return as a line ending' {
        $path = Write-AnchorDocument -Directory $TestDrive -Text (@($script:First, '```', $script:Second, '```', $script:Third) -join "`r")
        Assert-StringEqual -Expected '42abcdef-0001, 42abcdef-0003' `
            -Actual (@(Get-LocalSbomAnchorId -LiteralPath $path) -join ', ')
    }

    It 'reads a document that mixes line endings' {
        $text = $script:First + "`r`n" + '~~~' + "`n" + $script:Second + "`r`n" + '~~~' + "`n" + $script:Third + "`r`n"
        $path = Write-AnchorDocument -Directory $TestDrive -Text $text
        Assert-StringEqual -Expected '42abcdef-0001, 42abcdef-0003' `
            -Actual (@(Get-LocalSbomAnchorId -LiteralPath $path) -join ', ')
    }
}

Describe 'the parser emits its ids one by one' {
    # Both callers wrap the call in @(), because the function writes its ids
    # to the pipeline: no id is no object, one id is a bare string.

    It 'emits no object for a document without ids' {
        $path = Write-AnchorDocument -Directory $TestDrive -Text "# Inventory`n"
        $direct = Get-LocalSbomAnchorId -LiteralPath $path
        Assert-Null $direct 'an empty result arrived as an object'
        Assert-Equal -Expected 0 -Actual @(Get-LocalSbomAnchorId -LiteralPath $path).Count
    }

    It 'emits one string for one id' {
        $path = Write-AnchorDocument -Directory $TestDrive -Text ($script:First + "`n")
        $direct = Get-LocalSbomAnchorId -LiteralPath $path
        Assert-True ($direct -is [string]) "a single id arrived as $(Get-TypeLabel $direct)"
        Assert-StringEqual -Expected '42abcdef-0001' -Actual $direct
        Assert-Equal -Expected 1 -Actual @(Get-LocalSbomAnchorId -LiteralPath $path).Count
    }

    It 'emits every id as its own string for several ids' {
        $path = Write-AnchorDocument -Directory $TestDrive -Text (@($script:First, $script:Second, $script:Third, '') -join "`n")
        $direct = Get-LocalSbomAnchorId -LiteralPath $path
        Assert-True ($direct -is [array]) 'several ids did not arrive as a collection'
        Assert-Equal -Expected 3 -Actual $direct.Count
        foreach ($id in $direct) {
            Assert-True ($id -is [string]) "an id arrived as $(Get-TypeLabel $id)"
        }
    }
}

Describe 'a document that cannot be read is an error, not a document without anchors' {
    # The publisher calls the parser inside a try block and turns the failure
    # into its own exit code, so the failure has to reach a caller that catches.

    It 'raises the read failure for a path with no file' {
        $missing = Join-Path $TestDrive 'absent.md'
        $caught = $null
        try { $null = Get-LocalSbomAnchorId -LiteralPath $missing } catch { $caught = $_ }
        Assert-NotNull $caught 'a missing document read as a document without anchors'
        Assert-True ($caught.Exception -is [System.Management.Automation.MethodInvocationException]) `
            "raised $(Get-TypeLabel $caught.Exception)"
        Assert-True ($caught.Exception.InnerException -is [System.IO.FileNotFoundException]) `
            "wrapped $(Get-TypeLabel $caught.Exception.InnerException)"
    }

    It 'raises the read failure for a path that is a directory' {
        $directory = Join-Path $TestDrive 'folder.md'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $caught = $null
        try { $null = Get-LocalSbomAnchorId -LiteralPath $directory } catch { $caught = $_ }
        Assert-NotNull $caught 'a directory read as a document without anchors'
        Assert-True ($caught.Exception -is [System.Management.Automation.MethodInvocationException]) `
            "raised $(Get-TypeLabel $caught.Exception)"
        # Which exception a directory raises is the runtime's choice per
        # platform; that the read fails is the contract.
        $inner = $caught.Exception.InnerException
        Assert-True ($inner -is [System.UnauthorizedAccessException] -or $inner -is [System.IO.IOException]) `
            "wrapped $(Get-TypeLabel $inner)"
    }

    It 'refuses an empty path when the parameter binds' {
        Assert-Throw { Get-LocalSbomAnchorId -LiteralPath '' } -Match 'LiteralPath'
    }
}

Describe 'one parser serves both documentation tools' {

    It 'exports the parser and nothing else' {
        $module = Get-Module -Name 'Markdown.LocalAnchors'
        Assert-NotNull $module 'the parser module is not loaded'
        Assert-StringEqual -Expected 'Get-LocalSbomAnchorId' -Actual (@($module.ExportedCommands.Keys) -join ', ')
        Assert-StringEqual -Expected 'Markdown.LocalAnchors' -Actual (Get-Command -Name 'Get-LocalSbomAnchorId').ModuleName
    }

    It 'imports without a warning, so no caller has to silence name checks' {
        $importWarning = @()
        Import-Module $script:ParserModule -Force -WarningVariable importWarning -WarningAction SilentlyContinue
        Assert-Equal -Expected 0 -Actual @($importWarning).Count -Because (@($importWarning) -join '; ')
    }

    It '<Tool> imports the parser before using it and defines no copy of its own' -ForEach $script:ToolCase {
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot $Tool)
        $own = Get-YurunaTestFunctionAst -Ast $ast -Name 'Get-LocalSbomAnchorId'
        Assert-True ($null -eq $own) "$Tool defines the parser itself, so the two tools can drift apart again"

        $import = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Import-Module' -and
                    $node.Extent.Text.Contains('Markdown.LocalAnchors.psm1')
                }, $true))
        Assert-Equal -Expected 1 -Actual $import.Count -Because "$Tool must import the parser module exactly once"

        $use = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Get-LocalSbomAnchorId'
                }, $true))
        Assert-True ($use.Count -ge 1) "$Tool no longer reads local anchors through the parser"
        foreach ($call in $use) {
            Assert-True ($import[0].Extent.StartOffset -lt $call.Extent.StartOffset) `
                "$Tool calls the parser on line $($call.Extent.StartLineNumber), before importing it"
        }
    }
}
