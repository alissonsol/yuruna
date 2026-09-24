<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42fadadf-22f5-4510-87bc-365af8d1047c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host firewall status
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# Cross-platform "make the status-service port reachable from the LAN" helper:
# centralizes the per-OS allow-rule logic used by BOTH the one-time elevated
# host setup and the best-effort self-heal at every status-service start.
# Manages Windows Defender Firewall and Linux ufw; reports (never touches)
# nftables/iptables without ufw and the macOS firewall. See docs/test-harness.md.

function Get-YurunaStatusFirewallRuleName {
    <#
    .SYNOPSIS
        The Windows Defender Firewall rule DisplayName for the status-service port.
    .DESCRIPTION
        Single source of truth for the DisplayName so the setup path and the
        self-heal path address the very same rule (Start-StatusService's own
        reachability warning matches on this string too).
    .PARAMETER Port
        The status-service TCP port (test.config.yml statusService.port, 8080 default).
    .OUTPUTS
        [string] the rule DisplayName.
    .EXAMPLE
        Get-YurunaStatusFirewallRuleName -Port 8080
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)
    "Yuruna: Allow inbound TCP :$Port (Status service)"
}

function Get-YurunaRulePortFilter {
    # Thin wrapper over the pipeline read '$rule | Get-NetFirewallPortFilter' so
    # tests have a direct-call seam to mock (a module-scoped Mock does not reliably
    # intercept a piped cmdlet call). Windows-only; the caller guards on $IsWindows.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)
    return ($Rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)
}

function Test-YurunaHostElevated {
    # True when the current process can change the host firewall: Administrator on
    # Windows, uid 0 (root) elsewhere. Isolated so it is one mockable seam in tests
    # (the WindowsPrincipal role check can't be faked directly).
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($IsWindows) {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]'Administrator')
    }
    return ("$(& id -u 2>$null)".Trim() -eq '0')
}

function Invoke-YurunaFirewallNative {
    # Run a native command (e.g. sudo -n ufw status), capture merged output +
    # exit code, and never throw. Kept tiny + private so the Linux branch reads
    # as intent, not process plumbing.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$CommandLine)
    $exe  = $CommandLine[0]
    $rest = if ($CommandLine.Count -gt 1) { $CommandLine[1..($CommandLine.Count - 1)] } else { @() }
    try {
        $out = & $exe @rest 2>&1 | Out-String
        return @{ ExitCode = $LASTEXITCODE; Output = $out }
    } catch {
        # exe absent / not executable: signal failure without a thrown terminating error.
        return @{ ExitCode = 127; Output = "$($_.Exception.Message)" }
    }
}

function Set-YurunaStatusFirewallRule {
    <#
    .SYNOPSIS
        Ensure inbound TCP on the status-service port is allowed through the host
        firewall so LAN clients can reach http://<host>:<port>/status/.
    .DESCRIPTION
        Idempotent, best-effort, and NEVER throws -- it returns a result object
        so a caller in a start path can log and carry on. Windows: create /
        enable / rebuild the 'Yuruna: Allow inbound TCP :<port> (Status service)'
        Defender rule (inbound TCP Allow, profile Any); needs Administrator.
        Linux: 'ufw allow <port>/tcp' when ufw is present AND active; needs
        root / sudo. macOS: no-op (the port is not filtered by default).
    .PARAMETER Port
        The status-service TCP port (test.config.yml statusService.port, 8080 default).
    .PARAMETER NonInteractive
        Self-heal mode: never prompt for elevation, so a status-service start can
        call this without hanging. Windows -> skip (return unensured) when not
        elevated instead of erroring. Linux -> 'sudo -n' (fail fast, no prompt).
    .OUTPUTS
        [pscustomobject] with Platform; Ensured (inbound :Port is / will be
        allowed); Changed (a rule was created/enabled/rebuilt); Blocked
        (determined to be actively firewalled AND not fixable here -- the caller
        should warn); and Message. Neither Ensured nor Blocked means the state
        was indeterminate (e.g. unprivileged and could not even read it) -- stay
        quiet, host setup owns the durable fix.
    .EXAMPLE
        Set-YurunaStatusFirewallRule -Port 8080                  # host setup (elevated)
        Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive  # self-heal at start
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [switch]$NonInteractive
    )
    $result = [pscustomobject]@{ Platform = 'unknown'; Ensured = $false; Changed = $false; Blocked = $false; Message = '' }
    try {
        if ($IsWindows) {
            $result.Platform = 'Windows'
            $ruleName = Get-YurunaStatusFirewallRuleName -Port $Port
            $desc = "Allow inbound TCP on the yuruna status-service port so LAN clients can reach http://<host>:$Port/status/. Created by Yuruna (test/modules/Test.StatusFirewall.psm1)."
            # Read is admin-free, so even an unprivileged self-heal can DIAGNOSE
            # (and warn) -- only the mutation below needs Administrator.
            $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            $pf = if ($existing) { Get-YurunaRulePortFilter -Rule $existing } else { $null }
            $shapeCorrect = $pf -and ($pf.Protocol -eq 'TCP') -and ($pf.LocalPort -eq "$Port") -and
                ($existing.Direction -eq 'Inbound') -and ($existing.Action -eq 'Allow') -and ("$($existing.Profile)" -eq 'Any')
            if ($shapeCorrect -and $existing.Enabled -eq 'True') {
                $result.Ensured = $true
                $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_b317060ba0e0784f' -Arguments @{ ruleName = "$ruleName" })
                Write-Verbose $result.Message
                return $result
            }
            if (-not (Test-YurunaHostElevated)) {
                # Can't mutate, but we KNOW it's misconfigured -> tell the caller it's blocked.
                $result.Blocked = $true
                $result.Message = if (-not $existing) { (Format-YurunaOperatorMessage -Key 'runner.operator_b9a7825b7bd7c0f8' -Arguments @{ port = "$Port" }) }
                                  elseif ($existing.Enabled -ne 'True') { (Format-YurunaOperatorMessage -Key 'runner.operator_af63446eff94d379' -Arguments @{ ruleName = "$ruleName" }) }
                                  else { (Format-YurunaOperatorMessage -Key 'runner.operator_b9696695949fcb4f' -Arguments @{ ruleName = "$ruleName"; port = "$Port" }) }
                if ($NonInteractive) { Write-Verbose $result.Message } else { Write-Warning $result.Message }
                return $result
            }
            # Admin: bring the rule to the canonical shape. Rebuild on a shape
            # mismatch (wrong port/action/profile from a stale hand-made rule);
            # a lighter Enable when the shape is right but it was just disabled.
            if ($existing -and -not $shapeCorrect) {
                if ($PSCmdlet.ShouldProcess($ruleName, (Format-YurunaOperatorMessage -Key 'runner.operator_7f790a1ce866569c' -Arguments @{ port = "$Port" }))) {
                    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                    $null = New-NetFirewallRule -DisplayName $ruleName -Description $desc `
                        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any
                    $result.Changed = $true
                }
            } elseif ($existing -and $existing.Enabled -ne 'True') {
                if ($PSCmdlet.ShouldProcess($ruleName, (Format-YurunaOperatorMessage -Key 'runner.operator_900c7dfb1e5d32e3'))) {
                    Enable-NetFirewallRule -DisplayName $ruleName
                    $result.Changed = $true
                }
            } elseif (-not $existing) {
                if ($PSCmdlet.ShouldProcess($ruleName, (Format-YurunaOperatorMessage -Key 'runner.operator_e0720d7702cdcf1f' -Arguments @{ port = "$Port" }))) {
                    $null = New-NetFirewallRule -DisplayName $ruleName -Description $desc `
                        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any
                    $result.Changed = $true
                }
            }
            $result.Ensured = $true
            $result.Message = if ($result.Changed) { (Format-YurunaOperatorMessage -Key 'runner.operator_484765f94376e1f7' -Arguments @{ ruleName = "$ruleName" }) }
                              else { (Format-YurunaOperatorMessage -Key 'runner.operator_5cb379d1027f2e31' -Arguments @{ ruleName = "$ruleName" }) }
            Write-Information $result.Message
            return $result
        }

        if ($IsLinux) {
            $result.Platform = 'Linux'
            # ufw is the Ubuntu standard and the only Linux firewall Yuruna manages;
            # a host on raw nftables/iptables is reported (indeterminate), not touched.
            $ufwCmd = Get-Command ufw -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $ufwCmd) {
                $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_169147ae321c1e82' -Arguments @{ port = "$Port" })
                Write-Verbose $result.Message
                return $result
            }
            # Run the ABSOLUTE path under sudo. ufw installs to /usr/sbin, which is
            # on an interactive PATH but not necessarily on sudo's secure_path --
            # and sudo reports a command it cannot resolve as exit 127, which is
            # indistinguishable here from ufw not being installed.
            $ufwExe = if ($ufwCmd.Source) { $ufwCmd.Source } else { 'ufw' }
            # ufw needs root even to READ status. Root -> no prefix; otherwise sudo,
            # and 'sudo -n' in self-heal so an unprivileged runner fails fast (no prompt).
            $uid = "$(& id -u 2>$null)".Trim()
            # @(...) around the if is load-bearing: a bare if-expression yielding a
            # ONE-element array unrolls to a scalar string, and 'sudo' + @('ufw','status')
            # then string-concatenates into the single bogus command 'sudoufw status'
            # instead of extending the argument list.
            $prefix = @(if ($uid -eq '0') { @() } elseif ($NonInteractive) { @('sudo', '-n') } else { @('sudo') })
            $st = Invoke-YurunaFirewallNative -CommandLine ($prefix + @($ufwExe, 'status'))
            if ($st.ExitCode -ne 0) {
                # Unprivileged self-heal can't even read ufw -> INDETERMINATE (not
                # Blocked): the routine state on the unprivileged Linux runner. Stay
                # quiet so a healthy host isn't warned every cycle; host setup owns
                # the durable fix (Enable-TestAutomation runs elevated).
                $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_d5b5d8e0969942b5' -Arguments @{ exitCode = "$($st.ExitCode)"; port = "$Port" })
                Write-Verbose $result.Message
                return $result
            }
            if ($st.Output -notmatch '(?im)^\s*Status:\s*active') {
                # Inactive ufw does not DROP, so there is nothing to open.
                $result.Ensured = $true
                $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_9ba18d5e6791dd85' -Arguments @{ port = "$Port" })
                Write-Verbose $result.Message
                return $result
            }
            if ($st.Output -match "(?im)^\s*$Port/tcp\s+ALLOW") {
                $result.Ensured = $true
                $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_b7a070baef311891' -Arguments @{ port = "$Port" })
                Write-Verbose $result.Message
                return $result
            }
            if ($PSCmdlet.ShouldProcess('ufw', "allow $Port/tcp")) {
                $al = Invoke-YurunaFirewallNative -CommandLine ($prefix + @($ufwExe, 'allow', "$Port/tcp"))
                if ($al.ExitCode -eq 0) {
                    $result.Ensured = $true
                    $result.Changed = $true
                    $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_268e6069d124cd41' -Arguments @{ port = "$Port" })
                    Write-Information $result.Message
                } else {
                    # ufw is active and the port is not allowed, and we could not add
                    # it -> genuinely blocked and unfixable here.
                    $result.Blocked = $true
                    $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_106a8475358e4e82' -Arguments @{ port = "$Port"; exitCode = "$($al.ExitCode)" })
                    if ($NonInteractive) { Write-Verbose $result.Message } else { Write-Warning $result.Message }
                }
            }
            return $result
        }

        if ($IsMacOS) {
            $result.Platform = 'macOS'
            # The macOS application firewall filters by app, not by port, and does
            # not block inbound TCP :<port> by default -- nothing to do.
            $result.Ensured = $true
            $result.Message = (Format-YurunaOperatorMessage -Key 'runner.operator_2bc0c6c200d92473' -Arguments @{ port = "$Port" })
            Write-Verbose $result.Message
            return $result
        }
    } catch {
        # A firewall tweak must never break a start path or a host-setup run.
        $result.Message = "Set-YurunaStatusFirewallRule: $($_.Exception.Message)"
        Write-Verbose $result.Message
    }
    return $result
}

Export-ModuleMember -Function Set-YurunaStatusFirewallRule, Get-YurunaStatusFirewallRuleName
