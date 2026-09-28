<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42d968d1-5bd9-4d9e-af91-6b555ef299de
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test eks context pester
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
    Check the EKS context import with a recording AWS command and the template's
    output contract. No cloud CLI, credentials, or kubeconfig is used.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $repo = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:Template = Join-Path $repo 'global/resources/aws/eks-cluster'
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-eks-contract'
    $script:Bash = (Get-Command bash -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $stub = Join-Path $script:Work 'aws'
    [IO.File]::WriteAllText($stub, 'printf ''%s\n'' "$@" > "$CAPTURE"' + "`n" + 'exit "${AWS_EXIT:-0}"' + "`n")
    if (-not $IsWindows) { & chmod +x $stub }

    function Invoke-EksImportFixture {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([int]$ExitCode = 0, [switch]$MissingContext)
        $capture = Join-Path $script:Work ('args-' + [guid]::NewGuid().ToString('n'))
        $psi = [Diagnostics.ProcessStartInfo]::new($script:Bash)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.ArgumentList.Add((Join-Path $script:Template 'cluster-import.sh'))
        # An exclusive fixture PATH makes it impossible to fall through to a
        # real AWS CLI if the recording command cannot execute.
        $psi.Environment['PATH'] = $script:Work
        $psi.Environment['CAPTURE'] = $capture
        $psi.Environment['AWS_EXIT'] = [string]$ExitCode
        $psi.Environment['RESOURCE_REGION'] = 'us-west-2'
        $psi.Environment['CLUSTER_NAME'] = 'fixture-cluster'
        $psi.Environment['DESTINATION_CONTEXT'] = if ($MissingContext) { '' } else { 'fixture context' }
        $child = [Diagnostics.Process]::Start($psi)
        try {
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            if (-not $child.WaitForExit(5000)) { $child.Kill(); throw 'fixture import exceeded its deadline' }
            $arguments = if (Test-Path -LiteralPath $capture) { @([IO.File]::ReadAllLines($capture)) } else { @() }
            return [pscustomobject]@{ ExitCode = $child.ExitCode; Arguments = $arguments
                Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
        } finally { $child.Dispose() }
    }
}

AfterAll { Remove-YurunaTestTempDir $script:Work }

Describe 'EKS resource context and outputs' {
    It 'imports directly under the requested context alias, preserving argument boundaries' {
        $result = Invoke-EksImportFixture
        Assert-Equal 0 $result.ExitCode $result.Output
        Assert-StringEqual 'eks|--region|us-west-2|update-kubeconfig|--name|fixture-cluster|--alias|fixture context' ($result.Arguments -join '|')
    }

    It 'propagates an AWS failure and refuses a missing destination context before invoking AWS' {
        Assert-Equal 17 (Invoke-EksImportFixture -ExitCode 17).ExitCode
        $missing = Invoke-EksImportFixture -MissingContext
        Assert-NotEqual 0 $missing.ExitCode
        Assert-Equal 0 @($missing.Arguments).Count
    }

    It 'runs the import after cluster creation and again when the requested alias changes' {
        $context = [IO.File]::ReadAllText((Join-Path $script:Template 'context.tf'))
        Assert-Match 'depends_on\s*=\s*\[module\.eks\]' $context
        Assert-Match '(?s)triggers\s*=\s*\{[^}]*destination_context\s*=\s*var\.destinationContext' $context
        Assert-Match 'command\s*=\s*"\./cluster-import\.sh"' $context
        Assert-Match 'DESTINATION_CONTEXT\s*=\s*var\.destinationContext' $context
    }

    It 'publishes real cluster outputs without claiming the API endpoint is workload ingress' {
        $outputs = [IO.File]::ReadAllText((Join-Path $script:Template 'outputs.tf'))
        foreach ($name in @('clusterName', 'clusterEndpoint', 'destinationContext')) {
            Assert-Match ('output\s+"' + $name + '"') $outputs
        }
        Assert-Match 'module\.eks\.cluster_endpoint' $outputs
        $ingress = [IO.File]::ReadAllText((Join-Path $script:Template 'endpoints.tf'))
        Assert-Match '(?s)output\s+"hostname"\s*\{[^}]*aws_lb\.ingress\.dns_name' $ingress
        Assert-Match '(?s)output\s+"frontendIp"\s*\{[^}]*aws_eip\.frontend\[0\]\.public_ip' $ingress
        Assert-False ($ingress -match 'module\.eks\.cluster_endpoint') 'application ingress never uses the control-plane endpoint'
    }
}
