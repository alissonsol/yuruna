<#PSScriptInfo
.VERSION 2026.10.30
.GUID 420c75e4-0495-40be-af73-bb59295bcb3b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ocr known-answer pester
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
    The cycle-start known-answer read of a committed frame through the enabled
    OCR providers.
.DESCRIPTION
    OCR readiness was the presence of the engine. An installed engine that
    could not read returned empty text, every wait then timed out as if the
    guest were slow, and the failure was filed against a guest and its repair.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Force -DisableNameChecking
    $script:Fixture = Join-Path $PSScriptRoot '../fixtures/ocr/selftest.png'
    $script:AllWords = "YURUNA OCR SELF TEST`nlogin: operator`nPassword check 2468"
    $script:SavedCombine = Save-YurunaTestEnvironment -Name 'YURUNA_OCR_COMBINE'
}
AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:SavedCombine
}

Describe 'The known-answer read of a committed frame' {
    BeforeEach {
        Remove-Item Env:\YURUNA_OCR_COMBINE -ErrorAction SilentlyContinue
        $script:Answers = @{}
        Mock -ModuleName Test.OcrEngine Get-EnabledOcrProvider { @($script:Answers.Keys | Sort-Object) }
        Mock -ModuleName Test.OcrEngine Invoke-OcrProvider {
            param($Name)
            $answer = $script:Answers[$Name]
            if ($answer -is [scriptblock]) { return (& $answer) }
            return $answer
        }
    }
    It 'passes a provider that reads the frame, whatever the case or line breaks' {
        $script:Answers['tesseract'] = ($script:AllWords.ToLowerInvariant() -replace "`n", '  ')
        $r = Test-OcrKnownAnswer
        Assert-True $r.Passed $r.Detail
        Assert-False $r.Degraded 'one provider, and it read the frame'
        Assert-Equal -Expected 1 -Actual $r.Providers[0].Recall
    }
    It 'reports degraded, not failed, when one provider fails beside one that reads under Or' {
        $script:Answers['a-reads'] = $script:AllWords
        $script:Answers['b-empty'] = ''
        $r = Test-OcrKnownAnswer
        Assert-True $r.Passed 'a wait still reads through the provider that works'
        Assert-True $r.Degraded 'the failing provider is named'
        Assert-Match -Pattern 'b-empty read 0 of 9 known words \(missing: YURUNA' -Actual $r.Detail
    }
    It 'fails when no provider reads the frame, and names an engine that threw' {
        $script:Answers['a-empty'] = ''
        $script:Answers['b-throws'] = { throw 'language data not found' }
        $r = Test-OcrKnownAnswer
        Assert-False $r.Passed $r.Detail
        Assert-Match -Pattern 'b-throws read 0 of 9 known words .*\(error: language data not found\)' -Actual $r.Detail
    }
    It 'fails a provider that reads less than 80% of the words' {
        $script:Answers['partial'] = 'YURUNA OCR SELF TEST login operator Password'
        $r = Test-OcrKnownAnswer
        Assert-False $r.Passed 'seven of nine words is below the bar'
        Assert-Equal -Expected 0.78 -Actual $r.Providers[0].Recall
        Assert-Match -Pattern 'missing: check, 2468' -Actual $r.Detail
    }
    It 'requires every provider under And, because a wait then needs all of them' {
        $env:YURUNA_OCR_COMBINE = 'And'
        $script:Answers['a-reads'] = $script:AllWords
        $script:Answers['b-empty'] = ''
        $r = Test-OcrKnownAnswer
        Assert-False $r.Passed 'one failing provider fails every wait'
        Assert-Equal -Expected 'And' -Actual $r.CombineMode
    }
    It 'fails with no enabled provider and with no frame to read' {
        $none = Test-OcrKnownAnswer
        Assert-False $none.Passed 'nothing can read'
        Assert-Match -Pattern 'no OCR provider' -Actual $none.Detail
        $script:Answers['tesseract'] = $script:AllWords
        $missing = Test-OcrKnownAnswer -FixturePath (Join-Path $TestDrive 'absent.png')
        Assert-False $missing.Passed 'a missing frame proves nothing'
        Assert-Match -Pattern 'missing' -Actual $missing.Detail
    }
}

# The frame and its word list are one fixture: an engine that reads the frame
# must read every word the check expects.
Describe 'The committed frame matches its word list' {
    It 'reads every expected word with tesseract' -Skip:(-not (Get-Command tesseract -ErrorAction SilentlyContinue)) {
        $text = Invoke-OcrProvider -Name tesseract -ImagePath $script:Fixture | Out-String
        $r = Test-OcrKnownAnswer
        Assert-True $r.Passed "tesseract read: $text"
        Assert-Equal -Expected 1 -Actual @($r.Providers | Where-Object { $_.Name -eq 'tesseract' })[0].Recall
    }
}

# The check runs inside the cycle, beside the hypervisor control gate, and its
# failure is the host's instrumentation, never a guest's.
Describe 'The cycle reads the known answer before any guest' {
    It 'fails the cycle as the host''s instrumentation_failure, after the control gate and before the status service' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1'), [ref]$null, [ref]$null)
        $cycle = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-RunnerInnerCycle' }, $true)
        $commands = @($cycle.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $check = @($commands | Where-Object { $_.GetCommandName() -eq 'Test-OcrKnownAnswer' })
        Assert-Equal -Expected 1 -Actual $check.Count -Because 'one known-answer read per cycle'
        $control = @($commands | Where-Object { $_.GetCommandName() -eq 'Test-RunnerHypervisorControlGate' })[0]
        $service = @($commands | Where-Object { $_.GetCommandName() -eq 'Start-YurunaStatusServiceIfEnabled' })[0]
        Assert-True ($check[0].Extent.StartOffset -gt $control.Extent.StartOffset -and $check[0].Extent.StartOffset -lt $service.Extent.StartOffset) 'between the control gate and the cycle body'
        $record = @($commands | Where-Object { $_.GetCommandName() -eq 'Write-CycleInfraFailure' -and $_.Extent.Text -match "-Stage 'OcrKnownAnswer'" })
        Assert-Equal -Expected 1 -Actual $record.Count -Because 'a failed read is recorded'
        Assert-Match -Pattern "-FailureClass 'instrumentation_failure'" -Actual $record[0].Extent.Text
        Assert-Match -Pattern "-GuestKey '\(host\)'" -Actual $record[0].Extent.Text
    }
}
