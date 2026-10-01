<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42a0d2cf-242d-40a3-a0db-67424cfde2ac
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence safety pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:Modules = $PSScriptRoot
    Import-Module (Join-Path $PSScriptRoot 'Test.SequencePlanner.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1') -Force -DisableNameChecking
    function Get-SafetyFunction {
        param([string]$File, [string]$Name)
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Modules $File), [ref]$null, [ref]$null)
        $function = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        if (-not $function) { throw "Missing function $Name" }
        return [scriptblock]::Create($function.Extent.Text)
    }
    . (Get-SafetyFunction -File 'Test.SequenceEngine.psm1' -Name 'Test-RecentOcrFramesMatch')
    . (Get-SafetyFunction -File 'Test.Diagnostic.psm1' -Name 'Reset-GuestTtyPrompt')
}

Describe 'sequence commands keep sensitive failure labels private' {
    It 'does not expand sensitive <Verb> data into a failure label' -ForEach @(
        @{ Verb = 'sshExec' }, @{ Verb = 'sshFetchAndExecute' }, @{ Verb = 'fetchAndExecute' }
    ) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Modules 'Test.SequenceHandler.psm1'), [ref]$null, [ref]$null)
        $registration = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-SequenceAction' -and
            $n.Extent.Text -match ('-Name\s+.' + $Verb + '.')
        }, $true)
        $elements = $registration.CommandElements
        $label = $null
        for ($i = 0; $i -lt $elements.Count; $i++) {
            if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'FailureLabel') {
                $label = [scriptblock]::Create($elements[$i + 1].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
                break
            }
        }
        $label | Should -Not -BeNullOrEmpty
        $ctx = @{ Step = @{ sensitive = $true; command = 'synthetic-token'; text = 'synthetic-token' }; Vars = @{}; ExpandVariable = { throw 'sensitive data must not be expanded' } }
        (& $label $ctx) | Should -Be ($Verb + ': "***"')
        $ctx.Step.sensitive = $false
        $ctx.ExpandVariable = { param($text, $vars) $null = $vars; $text }
        (& $label $ctx) | Should -Be ($Verb + ': "synthetic-token"')
    }
}

Describe 'sequence prerequisite cycles produce catchable plan failures' {
    It 'rejects a <Shape> dependency cycle' -ForEach @(@{ Shape = 'self' }, @{ Shape = 'pair' }) {
        $root = Join-Path $TestDrive $Shape
        $dir = Join-Path $root 'test/sequences'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $next = if ($Shape -eq 'self') { 'a' } else { 'b' }
        Set-Content -LiteralPath (Join-Path $dir 'a.yml') -Value "resource:`n  ubuntu: [$next]`ncomponent: []`nworkload: []"
        Set-Content -LiteralPath (Join-Path $dir 'b.yml') -Value "resource:`n  ubuntu: [a]`ncomponent: []`nworkload: []"
        $failure = $null
        try { $null = Resolve-NamedSequenceChain -RepoRoot $root -SequencesDir $dir -SequenceName a -OsKey ubuntu }
        catch { $failure = $_ }
        $failure | Should -Not -BeNullOrEmpty
        Test-SequencePlannerFailure $failure | Should -BeTrue
        $failure.Exception.Message | Should -Match 'cyclic sequence prerequisites: (a -> a|b -> a -> b)'
    }

    It 'finds the framework snippet library beneath an ancestor named project' {
        $root = Join-Path $TestDrive 'project/framework'
        $null = New-Item -ItemType Directory -Path "$root/test/sequences", "$root/project/demo/test" -Force
        Set-Content -LiteralPath "$root/test/sequences/_snippets.yml" -Value "prime:`n  - action: inputText`n    text: fixture"
        $path = "$root/project/demo/test/sequence.yml"
        Set-Content -LiteralPath $path -Value "component:`n  - snippet: prime`nworkload: []"
        $map = Get-SnippetMap -SequencePath $path
        $map.prime.Steps[0].text | Should -Be 'fixture'
    }
}

Describe 'recent OCR history preserves the configured engine combination' {
    It 'does not turn a single-provider match into an And match' {
        $frames = @{}
        $engines = @{ first = @{ Text = 'login:' }; second = @{ Text = 'booting' } }
        Test-RecentOcrFramesMatch -Frames $frames -EngineResults $engines -EnabledEngines first, second -Pattern 'login:' -CombineMode And | Should -BeFalse
        Test-RecentOcrFramesMatch -Frames @{} -EngineResults $engines -EnabledEngines first, second -Pattern 'login:' -CombineMode Or | Should -BeTrue
    }
    It 'requires evidence from every enabled provider, including short-circuited providers' {
        Test-RecentOcrFramesMatch -Frames @{} -EngineResults @{ first = @{ Text = 'login:' } } -EnabledEngines first, second -Pattern 'login:' -CombineMode And | Should -BeFalse
    }
    It 'accepts matches from both providers without combining their partial words' {
        Test-RecentOcrFramesMatch -Frames @{} -EngineResults @{ first = @{ Text = 'login:' }; second = @{ Text = 'login:' } } -EnabledEngines first, second -Pattern 'login:' -CombineMode And | Should -BeTrue
    }
    It 'preserves ordinary segment matching across frames by default' {
        $frames = @{}
        $arguments = @{ Frames = $frames; EnabledEngines = @('first'); Pattern = 'amisad-core login:'; CombineMode = 'Or' }
        Test-RecentOcrFramesMatch @arguments -EngineResults @{ first = @{ Text = 'passwd --expire amisad-core-admin' } } | Should -BeFalse
        Test-RecentOcrFramesMatch @arguments -EngineResults @{ first = @{ Text = 'sed -i ... /target/etc/login.defs' } } | Should -BeTrue
    }
    It 'rejects scattered installer words until a bounded prompt appears in <Mode> mode' -ForEach @(
        @{ Mode = 'Or' }, @{ Mode = 'And' }
    ) {
        $frames = @{}
        $arguments = @{ Frames = $frames; EnabledEngines = @('first', 'second'); Pattern = 'amisad-core login:'; CombineMode = $Mode; NoSegmentMatch = $true }
        $account = @{ Text = 'passwd --expire amisad-core-admin' }
        $configuration = @{ Text = 'sed -i ... /target/etc/login.defs' }
        Test-RecentOcrFramesMatch @arguments -EngineResults @{ first = $account; second = $account } | Should -BeFalse
        Test-RecentOcrFramesMatch @arguments -EngineResults @{ first = $configuration; second = $configuration } | Should -BeFalse
        Test-RecentOcrFramesMatch @arguments -EngineResults @{ first = @{ Text = 'amisad-core logln: _' }; second = @{ Text = 'amisad-core login: _' } } | Should -BeTrue
    }
    It 'requires bounded evidence from each enabled provider in And mode' {
        $engines = @{
            first = @{ Text = 'amisad-core logln: _' }
            second = @{ Text = "passwd --expire amisad-core-admin`nsed -i ... /target/etc/login.defs" }
        }
        Test-RecentOcrFramesMatch -Frames @{} -EngineResults $engines -EnabledEngines first, second -Pattern 'amisad-core login:' -CombineMode And -NoSegmentMatch | Should -BeFalse
        Test-RecentOcrFramesMatch -Frames @{} -EngineResults $engines -EnabledEngines first, second -Pattern 'amisad-core login:' -CombineMode Or -NoSegmentMatch | Should -BeTrue
        Test-RecentOcrFramesMatch -Frames @{} -EngineResults @{ first = $engines.first } -EnabledEngines first, second -Pattern 'amisad-core login:' -CombineMode And -NoSegmentMatch | Should -BeFalse
    }
}

Describe 'diagnostic console commands retain their original host binding' {
    It 'continues with the captured driver after that driver imports shadowing commands' {
        $calls = [Collections.Generic.List[string]]::new()
        $driver = {
            param($VMName, $Key, $Mechanism)
            if ($VMName -ne 'fixture' -or $Mechanism -ne 'gui') { throw 'incorrect host arguments' }
            $calls.Add($Key)
            function global:Send-Key { throw 'shadow dispatcher was called' }
            return $true
        }.GetNewClosure()
        $prior = Get-Item Function:global:Send-Key -ErrorAction SilentlyContinue
        try {
            Reset-GuestTtyPrompt -VMName fixture -SendKey $driver | Should -BeTrue
            ($calls -join ',') | Should -Be 'CtrlC,Enter'
        } finally {
            Remove-Item Function:Send-Key -ErrorAction SilentlyContinue
            if ($prior) { Set-Item Function:global:Send-Key -Value $prior.ScriptBlock }
        }
    }
}
