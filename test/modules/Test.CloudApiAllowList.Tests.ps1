<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42faf937-cf2f-4788-a4ba-1f8288da77c8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cloud allowlist pester
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

BeforeAll {
    $script:Repo = Split-Path (Split-Path $PSScriptRoot)
    $script:Tofu = Get-Command tofu, terraform -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

Describe 'public Kubernetes API CIDR input rejects an empty allow-list' {
    It 'declares nonempty and CIDR validation for <Template>' -ForEach @(
        @{ Template = 'aws/eks-cluster' }
        @{ Template = 'azure/aks-cluster' }
    ) {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:Repo "global/resources/$Template/variables.tf")
        $block = [regex]::Match($text, '(?s)variable "apiServerAuthorizedCidrs"\s*\{.*$').Value
        $block | Should -Match 'validation\s*\{'
        $block | Should -Match 'length\(\[for c in split\(",", var.apiServerAuthorizedCidrs\).*\]\) > 0'
        $block | Should -Match 'alltrue\(\[for c .*can\(cidrhost\(trimspace\(c\), 0\)\)'
    }

    It 'rejects empty and malformed values and accepts valid CIDRs in a provider-free plan for <Template>' -ForEach @(
        @{ Template = 'aws/eks-cluster' }
        @{ Template = 'azure/aks-cluster' }
    ) {
        if (-not $script:Tofu) { Set-ItResult -Skipped -Because 'OpenTofu/Terraform is not installed'; return }
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:Repo "global/resources/$Template/variables.tf")
        $block = [regex]::Match($text, '(?s)variable "apiServerAuthorizedCidrs"\s*\{.*$').Value
        $root = Join-Path $TestDrive ($Template -replace '/', '-')
        $null = New-Item -ItemType Directory -Path $root
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Value ($block + "`n" + 'output "allowlist" { value = var.apiServerAuthorizedCidrs }')
        foreach ($case in @(
            @{ Value = ''; Valid = $false }, @{ Value = ' , '; Valid = $false },
            @{ Value = '203.0.113.5'; Valid = $false }, @{ Value = '203.0.113.5/33'; Valid = $false },
            @{ Value = '203.0.113.5/32, broken'; Valid = $false },
            @{ Value = '203.0.113.5/32'; Valid = $true }, @{ Value = ' 203.0.113.5/32, 198.51.100.0/24 '; Valid = $true }
        )) {
            $psi = [Diagnostics.ProcessStartInfo]::new($script:Tofu.Source)
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.Environment['TF_IN_AUTOMATION'] = '1'
            foreach ($arg in @("-chdir=$root", 'plan', '-input=false', '-lock=false', '-no-color', "-var=apiServerAuthorizedCidrs=$($case.Value)")) { $psi.ArgumentList.Add($arg) }
            $child = [Diagnostics.Process]::Start($psi)
            try {
                $stdout = $child.StandardOutput.ReadToEndAsync()
                $stderr = $child.StandardError.ReadToEndAsync()
                if (-not $child.WaitForExit(10000)) { $child.Kill(); throw 'provider-free plan timed out' }
                $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
                if ($case.Valid) { $child.ExitCode | Should -Be 0 -Because $output }
                else { $child.ExitCode | Should -Not -Be 0; $output | Should -Match 'apiServerAuthorizedCidrs must contain at least one valid CIDR' }
            } finally { $child.Dispose() }
        }
    }
}
