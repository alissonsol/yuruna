<#PSScriptInfo
.VERSION 2026.07.24
.GUID 42d7e8f9-a0b1-4c23-8d45-6e7f80912a34
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

# Cross-platform "make the status-service port reachable from the LAN" helper:
# centralizes the per-OS allow-rule logic used by BOTH the one-time elevated
# host setup and the best-effort self-heal at every status-service start.
# Manages Windows Defender Firewall and Linux ufw; reports (never touches)
# nftables/iptables without ufw and the macOS firewall. See docs/test-harness.md.

function Get-YurunaStatusFirewallRuleName {
    # Single source of truth for the Windows rule DisplayName so the setup path
    # and the self-heal path address the very same rule (Start-StatusService's
    # own reachability warning matches on this string too).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)
    "Yuruna: Allow inbound TCP :$Port (Status server)"
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
        enable / rebuild the 'Yuruna: Allow inbound TCP :<port> (Status server)'
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
                $result.Message = "Windows Firewall rule '$ruleName' already present and correct."
                Write-Verbose $result.Message
                return $result
            }
            if (-not (Test-YurunaHostElevated)) {
                # Can't mutate, but we KNOW it's misconfigured -> tell the caller it's blocked.
                $result.Blocked = $true
                $result.Message = if (-not $existing) { "No Windows Firewall rule for inbound TCP :$Port -- LAN clients will time out. Run host\windows.hyper-v\Enable-TestAutomation.ps1 (elevated)." }
                                  elseif ($existing.Enabled -ne 'True') { "Windows Firewall rule '$ruleName' is DISABLED -- LAN clients will time out. Run host\windows.hyper-v\Enable-TestAutomation.ps1 (elevated)." }
                                  else { "Windows Firewall rule '$ruleName' does not match inbound TCP :$Port -- LAN clients will time out. Run host\windows.hyper-v\Enable-TestAutomation.ps1 (elevated)." }
                if ($NonInteractive) { Write-Verbose $result.Message } else { Write-Warning $result.Message }
                return $result
            }
            # Admin: bring the rule to the canonical shape. Rebuild on a shape
            # mismatch (wrong port/action/profile from a stale hand-made rule);
            # a lighter Enable when the shape is right but it was just disabled.
            if ($existing -and -not $shapeCorrect) {
                if ($PSCmdlet.ShouldProcess($ruleName, "Rebuild inbound TCP :$Port allow rule")) {
                    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                    $null = New-NetFirewallRule -DisplayName $ruleName -Description $desc `
                        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any
                    $result.Changed = $true
                }
            } elseif ($existing -and $existing.Enabled -ne 'True') {
                if ($PSCmdlet.ShouldProcess($ruleName, 'Enable existing firewall rule')) {
                    Enable-NetFirewallRule -DisplayName $ruleName
                    $result.Changed = $true
                }
            } elseif (-not $existing) {
                if ($PSCmdlet.ShouldProcess($ruleName, "Create inbound TCP :$Port allow rule (all profiles)")) {
                    $null = New-NetFirewallRule -DisplayName $ruleName -Description $desc `
                        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any
                    $result.Changed = $true
                }
            }
            $result.Ensured = $true
            $result.Message = if ($result.Changed) { "Ensured Windows Firewall rule '$ruleName'." }
                              else { "Windows Firewall rule '$ruleName' not applied (WhatIf)." }
            Write-Information $result.Message
            return $result
        }

        if ($IsLinux) {
            $result.Platform = 'Linux'
            # ufw is the Ubuntu standard and the only Linux firewall Yuruna manages;
            # a host on raw nftables/iptables is reported (indeterminate), not touched.
            if (-not (Get-Command ufw -ErrorAction SilentlyContinue)) {
                $result.Message = "ufw not found; nftables/iptables are not managed. If inbound TCP :$Port is firewalled, allow it manually (e.g. an nft accept rule)."
                Write-Verbose $result.Message
                return $result
            }
            # ufw needs root even to READ status. Root -> no prefix; otherwise sudo,
            # and 'sudo -n' in self-heal so an unprivileged runner fails fast (no prompt).
            $uid = "$(& id -u 2>$null)".Trim()
            $prefix = if ($uid -eq '0') { @() } elseif ($NonInteractive) { @('sudo', '-n') } else { @('sudo') }
            $st = Invoke-YurunaFirewallNative -CommandLine ($prefix + @('ufw', 'status'))
            if ($st.ExitCode -ne 0) {
                # Unprivileged self-heal can't even read ufw -> INDETERMINATE (not
                # Blocked): the routine state on the unprivileged Linux runner. Stay
                # quiet so a healthy host isn't warned every cycle; host setup owns
                # the durable fix (Enable-TestAutomation runs elevated).
                $result.Message = "Could not query ufw (exit $($st.ExitCode)); status-port firewall state unknown. If :$Port is blocked, run elevated: sudo ufw allow $Port/tcp"
                Write-Verbose $result.Message
                return $result
            }
            if ($st.Output -notmatch '(?im)^\s*Status:\s*active') {
                # Inactive ufw does not DROP, so there is nothing to open.
                $result.Ensured = $true
                $result.Message = "ufw is inactive; no inbound DROP to open for TCP :$Port."
                Write-Verbose $result.Message
                return $result
            }
            if ($st.Output -match "(?im)^\s*$Port/tcp\s+ALLOW") {
                $result.Ensured = $true
                $result.Message = "ufw already allows inbound TCP :$Port."
                Write-Verbose $result.Message
                return $result
            }
            if ($PSCmdlet.ShouldProcess('ufw', "allow $Port/tcp")) {
                $al = Invoke-YurunaFirewallNative -CommandLine ($prefix + @('ufw', 'allow', "$Port/tcp"))
                if ($al.ExitCode -eq 0) {
                    $result.Ensured = $true
                    $result.Changed = $true
                    $result.Message = "Added ufw allow $Port/tcp so LAN clients can reach the status server."
                    Write-Information $result.Message
                } else {
                    # ufw is active and the port is not allowed, and we could not add
                    # it -> genuinely blocked and unfixable here.
                    $result.Blocked = $true
                    $result.Message = "ufw is active and inbound TCP :$Port is blocked, but 'ufw allow $Port/tcp' failed (exit $($al.ExitCode)). Run elevated: sudo ufw allow $Port/tcp"
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
            $result.Message = "macOS does not port-filter inbound TCP :$Port by default; no firewall rule needed."
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
