<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42c8b0e7-91d4-4a36-b5f8-2e7c19d3a640
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization external tools locale pester
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
    Keep decisions off the words an external tool happened to print.
.DESCRIPTION
    virsh and Get-NetAdapter both describe state in the operator's language.
    virsh puts its domain states and field labels through gettext; Windows
    translates an adapter's Status with the install language. Code that decides
    from those words works perfectly on the machine it was written on and
    reports a healthy host broken everywhere else -- and the failure is quiet,
    because a state that matches no branch reads as 'unknown' rather than as an
    error anyone would chase.

    Two shapes of answer are checked here. Where a tool offers a stable value
    next to the display string, the value is what gets read. Where it offers
    only prose, the call pins LC_MESSAGES so the prose is English, and clears
    LC_ALL for the duration because LC_ALL outranks it -- an operator who
    exports LC_ALL would otherwise get translated output regardless.

    The adapter predicate exists twice on purpose: the Hyper-V host module has
    one, and the diagnostic script that has to reach the same verdict cannot
    import a Windows-only module. Two copies drift, so both are run against the
    same table here.

    Run: Invoke-Pester -Path test/modules/Test.ExternalToolOutput.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:KvmHost = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
$script:HyperVHost = Join-Path $script:RepoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
$script:Diagnostic = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'
$script:Ssh = Join-Path $script:RepoRoot 'test/modules/Test.Ssh.psm1'

function Get-NamedFunctionText {
    <#
    .SYNOPSIS
        One function's source, read from the parsed file rather than by regex.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $found = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $found) { return '' }
    return $found.Extent.Text
}

# Both predicates are loaded by their own source text rather than by importing
# the files they live in: one is a Windows-only module and the other is a
# script that would run its whole diagnostic if it were dot-sourced.
$script:HyperVPredicate = Get-NamedFunctionText -Path $script:HyperVHost -Name 'Test-YurunaAdapterUp'
$script:DiagnosticPredicate = Get-NamedFunctionText -Path $script:Diagnostic -Name 'Test-AdapterUp'

# What a record looks like coming out of each source, and what an adapter in
# that state actually is. The display strings are the English ones; a host in
# another language produces the same numbers and different words, which is the
# whole point.
$script:AdapterCases = @(
    @{ Name = 'a live adapter';                    Record = [pscustomobject]@{ Status = 'Up';           ifOperStatus = 1 }; Expect = $true }
    @{ Name = 'an unplugged adapter';              Record = [pscustomobject]@{ Status = 'Disconnected'; ifOperStatus = 2 }; Expect = $false }
    @{ Name = 'a disabled adapter';                Record = [pscustomobject]@{ Status = 'Disabled';     ifOperStatus = 2 }; Expect = $false }
    @{ Name = 'an adapter whose lower layer left'; Record = [pscustomobject]@{ Status = 'Down';         ifOperStatus = 7 }; Expect = $false }
    @{ Name = 'a live adapter on a host in another language';
       Record = [pscustomobject]@{ Status = 'Ativo'; ifOperStatus = 1 }; Expect = $true }
    @{ Name = 'a down adapter on a host in another language';
       Record = [pscustomobject]@{ Status = 'Desconectado'; ifOperStatus = 2 }; Expect = $false }
    @{ Name = 'a record carrying the value under its other name';
       Record = [pscustomobject]@{ Status = 'Ativo'; InterfaceOperationalStatus = 1 }; Expect = $true }
    @{ Name = 'a record with no value at all, in English';
       Record = [pscustomobject]@{ Status = 'Up' }; Expect = $true }
    @{ Name = 'nothing';                           Record = $null; Expect = $false }
)

function Confirm-SshAclOwnerContract {
    param([Parameter(Mandatory)][string]$Text)

    Assert-True ($Text -match '\.SetOwner\(\$currentSid\)') `
        'the private key owner is not set to the current account SID'
    Assert-True ($Text -match '\.GetOwner\(\[System\.Security\.Principal\.SecurityIdentifier\]\)') `
        'the written private-key owner is not read back as a SID'
    Assert-True ($Text -match '\$writtenOwner\.Value\s+-ne\s+\$currentSid\.Value') `
        'the written owner SID is not verified against the current account SID'
}
}

Describe 'an adapter state is read from the value, not the word' {

    It 'defines the predicate in both places that decide an uplink verdict' {
        Assert-True ([bool]$script:HyperVPredicate) `
            'the Hyper-V host module has no Test-YurunaAdapterUp'
        Assert-True ([bool]$script:DiagnosticPredicate) `
            'the diagnostic script has no Test-AdapterUp, so its ladder reads a display string'
    }

    It 'answers the same in both copies for every state' {
        # A copy that drifts turns the diagnostic into a second opinion: an
        # operator reads it to explain a verdict the driver already acted on.
        $hv = [scriptblock]::Create($script:HyperVPredicate + "`nTest-YurunaAdapterUp -Adapter `$args[0]")
        $dg = [scriptblock]::Create($script:DiagnosticPredicate + "`nTest-AdapterUp -Adapter `$args[0]")

        $findings = @()
        foreach ($case in $script:AdapterCases) {
            $a = [bool](& $hv $case.Record)
            $b = [bool](& $dg $case.Record)
            if ($a -ne $case.Expect) { $findings += "$($case.Name): the host module said $a, expected $($case.Expect)" }
            if ($b -ne $case.Expect) { $findings += "$($case.Name): the diagnostic said $b, expected $($case.Expect)" }
            if ($a -ne $b) { $findings += "$($case.Name): the two copies disagree ($a vs $b)" }
        }
        Assert-NoFinding $findings 'the uplink predicates do not agree with each other or with the contract'
    }

    It 'lets the value overrule the word when they disagree' {
        # The case that separates reading the number from reading the string:
        # a record whose display text says one thing and whose IF-MIB value
        # says another. A predicate still keyed to the word answers 'down'.
        $hv = [scriptblock]::Create($script:HyperVPredicate + "`nTest-YurunaAdapterUp -Adapter `$args[0]")
        $dg = [scriptblock]::Create($script:DiagnosticPredicate + "`nTest-AdapterUp -Adapter `$args[0]")
        $contradictory = [pscustomobject]@{ Status = 'Down'; ifOperStatus = 1 }
        Assert-True ([bool](& $hv $contradictory)) 'the host module read the display string instead of the value'
        Assert-True ([bool](& $dg $contradictory)) 'the diagnostic read the display string instead of the value'
    }

    It 'leaves no bare comparison against the English word' {
        # The predicate keeps one such comparison as its last resort, for a
        # record that carries no value at all. Any OTHER site deciding an
        # adapter's state from that word is the defect this closes.
        $findings = @()
        foreach ($rel in @('host/windows.hyper-v/modules/Yuruna.Host.psm1', 'automation/Get-SystemDiagnostic.ps1')) {
            $path = Join-Path $script:RepoRoot $rel
            $lines = [IO.File]::ReadAllLines($path)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -notmatch "\.Status[^-]*-(eq|ne)\s*'Up'") { continue }
                # The predicate's own fallback, and only it.
                if ($line -match 'return \("\$\(\$Adapter\.Status\)" -eq ' + "'Up'\)") { continue }
                $findings += "${rel}:$($i + 1): decides an adapter's state from a translated word"
            }
        }
        Assert-NoFinding $findings 'an adapter state is still being read from the display string'
    }
}

Describe 'a Windows principal is identified by its value, not its display name' {

    It 'rebuilds and verifies the SSH private-key ACL by SID' {
        $text = Get-NamedFunctionText -Path $script:Ssh -Name 'Set-YurunaSshPrivateKeyAcl'
        Assert-True ([bool]$text) 'the SSH module has no private-key ACL boundary'
        Assert-True ($text -match 'WindowsIdentity\]::GetCurrent\(\)\.User') 'the current account is not identified by its language-independent SID'
        Assert-True ($text -match 'SecurityIdentifier') 'the verification does not normalize stored identities to SIDs'
        Assert-True ($text -match 'SetAccessRuleProtection\(\$true,\s*\$false\)') 'inherited access survives on the private key'
        Assert-True ($text -match 'Set-Acl.*-ErrorAction\s+Stop') 'an ACL write failure can still be swallowed'
        Assert-True (([regex]::Matches($text, 'Get-Acl.*-ErrorAction\s+Stop')).Count -ge 2) 'the ACL is not read back after it is written'
        Assert-True ($text -match 'AreAccessRulesProtected') 'the verification does not prove inheritance stayed disabled'
        Assert-True ($text -match 'FileSystemRights\s+-band\s+\$fullControl') 'the verification does not prove the remaining SID has FullControl'
        Confirm-SshAclOwnerContract -Text $text

        $withoutOwnerWrite = $text -replace '(?m)^\s*\$acl\.SetOwner\(\$currentSid\)\s*\r?\n', ''
        Assert-Throw { Confirm-SshAclOwnerContract -Text $withoutOwnerWrite } 'owner' `
            'removing the owner write did not fail the SSH ACL contract test'

        $withoutOwnerReadback = $text -replace '(?m)^\s*\$writtenOwner\s*=.*\.GetOwner\([^\r\n]+\)\s*\r?\n', ''
        Assert-Throw { Confirm-SshAclOwnerContract -Text $withoutOwnerReadback } 'owner' `
            'removing the owner readback did not fail the SSH ACL contract test'
    }

    It 'contains no localized principal allow/removal list for the SSH key' {
        $text = Get-NamedFunctionText -Path $script:Ssh -Name 'Initialize-YurunaSshKey'
        Assert-True ([bool]$text) 'the SSH module has no key initializer'
        foreach ($forbidden in 'icacls', 'Authenticated Users', 'BUILTIN\Users',
                               'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM',
                               'env:USERNAME') {
            Assert-False ($text.Contains($forbidden)) "the SSH key still identifies '$forbidden' by an install-language display name"
        }
        Assert-True ($text -match 'Set-YurunaSshPrivateKeyAcl') 'the key initializer does not use the verified SID-based boundary'
    }

    It 'derives a machine account SID from the machine id' {
        # "NT VIRTUAL MACHINE" is a display name and Windows localizes it, so a
        # lookup by name throws on a host installed in another language. The
        # caller then cannot prove which access entries are stale and skips the
        # cleanup -- safe, and silent, which is why it went unnoticed: the
        # cleanup simply stopped happening, one warning at a time.
        #
        # The SID is computable instead: S-1-5-83-1 followed by the machine
        # GUID's sixteen bytes read as four little-endian unsigned 32-bit
        # values. Pure arithmetic, so it is checkable on any platform even
        # though the code around it is Windows-only.
        $text = Get-NamedFunctionText -Path $script:HyperVHost -Name 'Get-YurunaVMAccountSid'
        Assert-True ([bool]$text) 'the Hyper-V host module has no Get-YurunaVMAccountSid'
        $derive = [scriptblock]::Create($text + "`nGet-YurunaVMAccountSid -VMId ([guid]`$args[0])")

        $cases = @(
            @{ Guid = '00000000-0000-0000-0000-000000000000'; Sid = 'S-1-5-83-1-0-0-0-0' }
            @{ Guid = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
               Sid  = 'S-1-5-83-1-4294967295-4294967295-4294967295-4294967295' }
            # Each group of the GUID lands in its own component, which is what
            # a byte-order mistake would scramble.
            @{ Guid = 'DA4D2F4B-A9C4-4A4A-9C4D-2F4BA9C44A4A'
               Sid  = 'S-1-5-83-1-3662491467-1246407108-1261391260-1246413993' }
        )
        $findings = @()
        foreach ($case in $cases) {
            $got = [string](& $derive $case.Guid)
            if ($got -ne $case.Sid) { $findings += "$($case.Guid): got $got, want $($case.Sid)" }
        }
        Assert-NoFinding $findings 'the SID derivation does not match the documented form'
    }

    It 'does not look a virtual machine account up by name' {
        # The regression this closes. A name lookup here is the localized path.
        $text = Get-NamedFunctionText -Path $script:HyperVHost -Name 'Remove-OrphanedVMFileAccess'
        Assert-True ([bool]$text) 'the Hyper-V host module has no Remove-OrphanedVMFileAccess'
        Assert-True ($text -notmatch '\[System\.Security\.Principal\.NTAccount\]') `
            'the cleanup still translates an account name, which is localized and throws off English'
        Assert-True ($text -match 'Get-YurunaVMAccountSid') `
            'the cleanup should compute the SID from the machine id'
    }
}

Describe 'virsh is asked for its output in a language the code can read' {

    It 'pins the message locale in the wrapper every caller goes through' {
        $text = Get-NamedFunctionText -Path $script:KvmHost -Name 'Invoke-Virsh'
        Assert-True ([bool]$text) 'the KVM host module has no Invoke-Virsh'
        Assert-True ($text -match "LC_MESSAGES\s*=\s*'C'") `
            'Invoke-Virsh does not pin LC_MESSAGES, so a host in another language gets translated states'
        Assert-True ($text -match '\$env:LC_ALL\s*=\s*\$null') `
            'Invoke-Virsh does not clear LC_ALL, which outranks LC_MESSAGES and would translate the output anyway'
        Assert-True ($text -match 'finally') `
            'Invoke-Virsh does not restore the locale, so it leaks the pin into everything the process runs afterward'
    }

    It 'never branches on unpinned virsh output' {
        # Invoke-Virsh is the choke point, but not everything reaches it. What
        # makes a bypass a defect is not calling virsh -- it is deciding from
        # what virsh said. Output that is only shown to an operator, in a
        # -Verbose line or inside a thrown message, carries no branch, so it is
        # left alone: pinning it would trade a real class of bug for nothing.
        #
        # So each unpinned call is followed to the variable it fills, and the
        # finding is raised only where that variable reaches a comparison.
        $nameOnly = @('net-list', 'list', 'dumpxml', 'net-dumpxml', 'domuuid', 'domid')
        $comparison = '-(match|notmatch|eq|ne|ieq|ine|in|notin|like|notlike|contains|notcontains)\b'
        $findings = @()
        $files = Get-ChildItem -Path (Join-Path $script:RepoRoot 'host') -Recurse -Include '*.ps1', '*.psm1' -File
        foreach ($file in $files) {
            $lines = [IO.File]::ReadAllLines($file.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -notmatch '&\s*virsh\b') { continue }
                $rel = $file.FullName.Substring($script:RepoRoot.Length).TrimStart('/', '\')

                if ($nameOnly | Where-Object { $line -match "\b$([regex]::Escape($_))\b" }) { continue }

                # Pinned within the dozen lines above the call, which is as far
                # as a try/finally around one invocation reaches.
                $from = [Math]::Max(0, $i - 12)
                if (($lines[$from..$i] -join "`n") -match "LC_MESSAGES\s*=\s*'C'") { continue }

                $assignment = [regex]::Match($line, '\$(\w+)\s*=\s*\(?\s*&\s*virsh')
                if (-not $assignment.Success) { continue }
                $variable = $assignment.Groups[1].Value

                $to = [Math]::Min($lines.Count - 1, $i + 20)
                $branches = $false
                foreach ($ahead in $lines[($i + 1)..$to]) {
                    if ($ahead -notmatch "\`$$variable\b") { continue }
                    if ($ahead -match $comparison -or $ahead -match 'switch\s*(-\w+\s*)*\(') { $branches = $true; break }
                }
                if (-not $branches) { continue }

                $findings += "${rel}:$($i + 1): branches on unpinned virsh output in `$$variable"
            }
        }
        Assert-NoFinding $findings 'a decision is being made from virsh text in whatever language the host is set to'
    }

    It 'does not decide a rail is down from a translated field' {
        # net-info prints "Active: yes", and both the label and the answer are
        # translated. net-list --name prints network names, which are not.
        $text = Get-NamedFunctionText -Path (Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.GuestRail.psm1') `
            -Name 'Test-GuestRailAvailable'
        Assert-True ([bool]$text) 'the guest-rail module has no Test-GuestRailAvailable'
        # The call, not the prose around it: this function explains in a comment
        # why it does not read net-info, and a check on the bare word would be
        # satisfied by that explanation.
        Assert-True ($text -notmatch '&\s*virsh\s+net-info') `
            'the rail check still reads net-info, whose field label and value are both translated'
        Assert-True ($text -match '&\s*virsh\s+net-list') `
            'the rail check should ask which networks are active by name'
    }
}
