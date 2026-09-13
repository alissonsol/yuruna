<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42e220c4-9472-4e35-bf37-59a7e003196b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test consistency host guest seed pester
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
    Verify shared host, guest, and seed contracts without creating a VM.
.DESCRIPTION
    See https://yuruna.link/42e220c4-000a for family boundaries and exceptions.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
    $script:LinkRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna.link'
    $script:SeedRoot = Join-Path $script:RepoRoot 'host/vmconfig'
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force
    Import-Module powershell-yaml

    function Get-NormalizedSource {
        param([string]$Path)
        (Get-Content -LiteralPath $Path -Raw) -replace '\r\n', "`n" -replace
            'ubuntu\.server\.(24|26)', 'ubuntu.server.VERSION'
    }

    function Get-NormalizedUbuntuSequence {
        param([string]$Path, [int]$VersionTimeout = 0, [int]$TimeoutIndent = 0)
        $text = Get-NormalizedSource -Path $Path
        $text = $text -replace '(?m)^sequenceGuid: .+$', 'sequenceGuid: ID'
        $text = $text -replace '(?m)^sequenceRevision: .+$', 'sequenceRevision: REVISION'
        $text = $text -replace 'Ubuntu Server (?:24|26)\.04', 'Ubuntu Server VERSION'
        $text = $text -replace 'Ubuntu (?:24|26)', 'Ubuntu VERSION'
        $text = $text -replace '(yu(?:user|website|host))(?:24|26)', '${1}VERSION'
        $text = $text -replace 'ubuntu(?:24|26)', 'ubuntuVERSION'
        if ($VersionTimeout -gt 0) {
            $indent = ' ' * $TimeoutIndent
            $text = $text -replace ('(?m)^(' + [regex]::Escape($indent) + 'timeoutSeconds: )' + $VersionTimeout + '$'), '${1}VERSION_TIMEOUT'
        }
        return $text
    }

    function Get-ConsistencySourceFile {
        $roots = @(
            'host', 'guest', 'test', 'tools', 'automation', 'install' |
                ForEach-Object { Join-Path $script:RepoRoot $_ }
        )
        if (Test-Path -LiteralPath $script:ProjectRoot) {
            $roots += @('book', 'example', 'template', 'test' |
                ForEach-Object { Join-Path $script:ProjectRoot $_ } |
                Where-Object { Test-Path -LiteralPath $_ })
        }
        if (Test-Path -LiteralPath $script:LinkRoot) {
            $roots += $script:LinkRoot
        }
        $extensions = @('.ps1', '.psm1', '.sh', '.yml', '.yaml', '.user-data',
            '.go', '.js', '.cs', '.py', '.html', '.service', '.cmd')
        foreach ($root in $roots) {
            Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object {
                $_.Extension -in $extensions -and
                $_.FullName -notmatch '[\\/]test[\\/]status[\\/]runtime[\\/]' -and
                $_.FullName -notmatch '[\\/](?:bin|obj|node_modules|globalization)[\\/]'
            }
        }
    }

    function Format-SourceMatch {
        param([IO.FileInfo]$File, [string]$Text, [Text.RegularExpressions.Match]$Match)
        $line = 1 + [regex]::Matches($Text.Substring(0, $Match.Index), "`n").Count
        $root = if ($File.FullName.StartsWith($script:ProjectRoot, [StringComparison]::Ordinal)) {
            $script:ProjectRoot
        } elseif ($File.FullName.StartsWith($script:LinkRoot, [StringComparison]::Ordinal)) {
            $script:LinkRoot
        } else {
            $script:RepoRoot
        }
        return "$(Split-Path -Leaf $root):$($File.FullName.Substring($root.Length + 1)):$line"
    }
}

Describe 'Ubuntu installer parity' {
    It 'keeps the shared <Workload> installer identical across Ubuntu releases' -TestCases @(
        @{ Workload = 'update' }, @{ Workload = 'code' }, @{ Workload = 'k8s' },
        @{ Workload = 'n8n' }, @{ Workload = 'openclaw' }, @{ Workload = 'postgresql' }
    ) {
        param($Workload)
        $first = Get-NormalizedSource (Join-Path $script:RepoRoot "guest/ubuntu.server.24/ubuntu.server.24.$Workload.sh")
        $second = Get-NormalizedSource (Join-Path $script:RepoRoot "guest/ubuntu.server.26/ubuntu.server.26.$Workload.sh")
        $second | Should -BeExactly $first
    }
}

Describe 'Ubuntu test-sequence parity' {
    It 'keeps the <Flow> structure aligned across Ubuntu releases' -TestCases @(
        @{ Flow = 'GUI start'; Path24 = 'start.guest.ubuntu.server.24.yml'; Path26 = 'start.guest.ubuntu.server.26.yml'; Timeout24 = 1800; Timeout26 = 2400; TimeoutIndent = 8 },
        @{ Flow = 'SSH start'; Path24 = 'start.guest.ubuntu.server.24.ssh.yml'; Path26 = 'start.guest.ubuntu.server.26.ssh.yml'; Timeout24 = 0; Timeout26 = 0; TimeoutIndent = 0 },
        @{ Flow = 'GUI workload'; Path24 = 'workload.guest.ubuntu.server.24.yml'; Path26 = 'workload.guest.ubuntu.server.26.yml'; Timeout24 = 1800; Timeout26 = 3000; TimeoutIndent = 4 },
        @{ Flow = 'SSH workload'; Path24 = 'workload.guest.ubuntu.server.24.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.ssh.yml'; Timeout24 = 1800; Timeout26 = 3000; TimeoutIndent = 4 }
    ) {
        param($Flow, $Path24, $Path26, $Timeout24, $Timeout26, $TimeoutIndent)
        $null = $Flow
        $dir = Join-Path $script:RepoRoot 'test/sequences'
        # Ubuntu 26 needs a larger install budget in the two slow flows; every
        # other line remains a release-substituted copy.
        $first = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path24) -VersionTimeout $Timeout24 -TimeoutIndent $TimeoutIndent
        $second = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path26) -VersionTimeout $Timeout26 -TimeoutIndent $TimeoutIndent
        $second | Should -BeExactly $first
    }
}

Describe 'KVM replacement ordering' {
    It 'removes the old domain before replacing files for <Guest>' -TestCases @(
        @{ Guest = 'ubuntu.server.24' }, @{ Guest = 'ubuntu.server.26' },
        @{ Guest = 'amazon.linux.2023' }, @{ Guest = 'windows.11' },
        @{ Guest = 'caching-proxy-service' }, @{ Guest = 'stash-service' },
        @{ Guest = 'pool-control-service' }, @{ Guest = 'download-agent-service' }
    ) {
        param($Guest)
        $path = Join-Path $script:RepoRoot "host/ubuntu.kvm/guest.$Guest/New-VM.ps1"
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $commands = @($ast.FindAll({ param($n)
            $n -is [Management.Automation.Language.CommandAst]
        }, $true))
        $gate = @($commands | Where-Object { $_.GetCommandName() -eq 'Assert-YurunaBaseImage' })[0]
        $destroy = @($commands | Where-Object { $_.Extent.Text -match '^&?\s*virsh .* destroy ' })[0]
        $verify = @($commands | Where-Object { $_.Extent.Text -match '^&?\s*virsh .* list --all --name' })[0]
        $gate | Should -Not -BeNullOrEmpty
        $destroy | Should -Not -BeNullOrEmpty
        $verify | Should -Not -BeNullOrEmpty
        $destroy.Extent.StartOffset | Should -BeGreaterThan $gate.Extent.EndOffset
        $verify.Extent.StartOffset | Should -BeGreaterThan $destroy.Extent.EndOffset
        $writes = @($commands | Where-Object {
            $_.GetCommandName() -in @('Copy-Item', 'Set-Content', 'New-CloudInitUserData') -or
            $_.Extent.Text -match '^&?\s*qemu-img (create|convert|resize)\b'
        })
        $writes.Count | Should -BeGreaterThan 0
        foreach ($write in $writes) {
            $write.Extent.StartOffset | Should -BeGreaterThan $verify.Extent.EndOffset
        }
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?s)\$domainNames = .*?list --all --name.*?if \(\$LASTEXITCODE -ne 0\)\s*\{\s*throw'
    }
}

Describe 'VM seed overlay contracts' {
    It 'orders every overlay like its base and renders valid YAML' {
        foreach ($base in Get-ChildItem -LiteralPath $script:SeedRoot -Filter '*.base.user-data') {
            $baseKeys = @([regex]::Matches((Get-Content $base.FullName -Raw),
                '(?m)^\s*# === YURUNA_OVERLAY_([A-Z0-9_]+) ===$') | ForEach-Object { $_.Groups[1].Value })
            foreach ($platform in 'hyperv', 'kvm', 'utm') {
                $overlay = Join-Path $script:SeedRoot ($base.Name.Replace('.base.user-data', ".$platform.overlay.yml"))
                $sections = Read-OverlaySection -OverlayPath $overlay
                (@($sections.Keys) -join ',') | Should -BeExactly ($baseKeys -join ',')
                $merged = Merge-CloudInitUserData -BasePath $base.FullName -OverlayPath $overlay
                $merged | Should -Not -Match 'YURUNA_OVERLAY_'
                # Substitute the builder's real output, not a single-line stand-in: the
                # value is multi-line, and only a multi-line value exposes a token that
                # was spliced into a comment instead of its own line.
                $merged = $merged.Replace('APT_PROXY_BLOCK_PLACEHOLDER', (New-AptProxyBlock `
                            -PrimaryUri 'http://archive.ubuntu.com/ubuntu' `
                            -CachingProxyServiceUrl 'http://192.0.2.1:3128'))
                { ConvertFrom-Yaml $merged -ErrorAction Stop } | Should -Not -Throw
            }
        }
    }

    It 'never writes a substituted placeholder into a seed comment' {
        $findings = @()
        foreach ($file in Get-ChildItem -LiteralPath $script:SeedRoot -File) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($comment in [regex]::Matches($text, '(?m)^[ \t]*#[^\r\n]*$')) {
                $token = [regex]::Match($comment.Value, '\b[A-Z][A-Z0-9_]*_PLACEHOLDER\b')
                if (-not $token.Success) { continue }
                $location = Format-SourceMatch -File $file -Text $text -Match $comment
                $findings += "${location}: comment names the substituted token '$($token.Value)'"
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'placeholder substitution is substring-based, so a token named in a comment is a second injection site and a multi-line value splices into the comment'
    }

    It 'pairs each persistent KVM service channel with a running guest agent' {
        foreach ($service in 'caching-proxy-service', 'stash-service', 'pool-control-service', 'download-agent-service') {
            $base = Join-Path $script:SeedRoot "$service.base.user-data"
            $overlay = Join-Path $script:SeedRoot "$service.kvm.overlay.yml"
            $seed = ConvertFrom-Yaml (Merge-CloudInitUserData -BasePath $base -OverlayPath $overlay)
            $seed.packages | Should -Contain 'qemu-guest-agent'
            $seed.runcmd | Should -Contain 'systemctl enable qemu-guest-agent.service || true'
            $seed.runcmd | Should -Contain 'systemctl start qemu-guest-agent.service || true'
            $builder = Get-Content (Join-Path $script:RepoRoot "host/ubuntu.kvm/guest.$service/New-VM.ps1") -Raw
            $builder | Should -Match 'org\.qemu\.guest_agent\.0'
        }
    }

    It 'keeps the shared service-agent overlays identical for each provider' {
        foreach ($platform in 'hyperv', 'kvm', 'utm') {
            $expected = $null
            foreach ($service in 'stash-service', 'pool-control-service', 'download-agent-service') {
                $text = (Get-Content (Join-Path $script:SeedRoot "$service.$platform.overlay.yml") -Raw).Replace($service, 'SERVICE')
                if ($null -eq $expected) { $expected = $text }
                $text | Should -BeExactly $expected
            }
        }
    }

    It 'keeps shared service seed files identical after the account name is normalized' {
        $paths = @('/etc/ssh/sshd_config.d/60-yuruna-keepalive.conf', '/etc/yuruna/host.env',
            '/usr/local/lib/yuruna/yuruna-host-locate.sh', '/etc/systemd/system/yuruna-host-locate.service',
            '/etc/systemd/system/yuruna-host-locate.timer')
        foreach ($path in $paths) {
            $expected = $null
            foreach ($service in 'stash-service', 'pool-control-service', 'download-agent-service') {
                $seed = ConvertFrom-Yaml (Merge-CloudInitUserData `
                    -BasePath (Join-Path $script:SeedRoot "$service.base.user-data") `
                    -OverlayPath (Join-Path $script:SeedRoot "$service.kvm.overlay.yml"))
                $entry = @($seed.write_files | Where-Object { $_.path -eq $path })
                $entry.Count | Should -Be 1
                $text = ($entry[0] | ConvertTo-Json -Depth 6 -Compress).Replace($service, 'SERVICE')
                if ($null -eq $expected) { $expected = $text }
                $text | Should -BeExactly $expected
            }
        }
    }
}

Describe 'Project workload parity' {
    It 'keeps the website Ubuntu workload copies identical' {
        if (-not (Test-Path $script:ProjectRoot)) { Set-ItResult -Skipped -Because 'Sibling project checkout is absent'; return }
        $first = Get-NormalizedSource (Join-Path $script:ProjectRoot 'example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh')
        $second = Get-NormalizedSource (Join-Path $script:ProjectRoot 'example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh')
        $second | Should -BeExactly $first
    }

    It 'keeps the website <Flow> sequence aligned across Ubuntu releases' -TestCases @(
        @{ Flow = 'managed baseline'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.baseline.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.baseline.ssh.yml' },
        @{ Flow = 'SSH deployment'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.ssh.yml' },
        @{ Flow = 'warm SSH deployment'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.warm.ssh.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.warm.ssh.yml' },
        @{ Flow = 'GUI deployment'; Path24 = 'workload.guest.ubuntu.server.24.k8s.website.yml'; Path26 = 'workload.guest.ubuntu.server.26.k8s.website.yml' },
        @{ Flow = 'warm plan'; Path24 = 'website.ubuntu24.warm.yml'; Path26 = 'website.ubuntu26.warm.yml' }
    ) {
        param($Flow, $Path24, $Path26)
        $null = $Flow
        if (-not (Test-Path $script:ProjectRoot)) { Set-ItResult -Skipped -Because 'Sibling project checkout is absent'; return }
        $dir = Join-Path $script:ProjectRoot 'example/website/test'
        $first = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path24)
        $second = Get-NormalizedUbuntuSequence -Path (Join-Path $dir $Path26)
        $second | Should -BeExactly $first
    }

    It 'keeps the website and text-to-sql <Family> flow aligned' -TestCases @(
        @{ Family = 'application workload'; Website = 'test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh';
            TextToSql = 'test/ubuntu.server.24/ubuntu.server.24.workload.k8s.text-to-sql.sh' },
        @{ Family = 'certificate copy'; Website = 'components/frontend/website/copy-pfx.ps1';
            TextToSql = 'components/frontend/text-to-sql-ui/copy-pfx.ps1' },
        @{ Family = 'base-image seed'; Website = 'components/frontend/website/seed-base-images.ps1';
            TextToSql = 'components/frontend/text-to-sql-ui/seed-base-images.ps1' }
    ) {
        param($Family, $Website, $TextToSql)
        if (-not (Test-Path $script:ProjectRoot)) { Set-ItResult -Skipped -Because 'Sibling project checkout is absent'; return }
        $first = Get-Content (Join-Path $script:ProjectRoot "example/website/$Website") -Raw
        $second = Get-Content (Join-Path $script:ProjectRoot "example/text-to-sql/$TextToSql") -Raw
        $first = $first.Replace('website', 'PROJECT') -replace '(?m)^\.GUID .*$', '.GUID ID'
        $second = $second.Replace('text-to-sql-ui', 'PROJECT').Replace('text-to-sql', 'PROJECT') -replace '(?m)^\.GUID .*$', '.GUID ID'
        ($second -replace '\r\n', "`n") | Should -BeExactly ($first -replace '\r\n', "`n") -Because "$Family has the same contract in both examples"
    }
}

Describe 'Shared source regions' {
    It 'starts every service lifecycle script with the common regions' {
        foreach ($verb in 'Start', 'Stop') {
            foreach ($service in 'CachingProxy', 'Stash', 'PoolControl', 'DownloadAgent') {
                $path = Join-Path $script:RepoRoot "test/service/${verb}-${service}ServiceVM.ps1"
                $text = Get-Content -LiteralPath $path -Raw
                $confirm = $text.IndexOf('# --- REGION: Confirm the service operation', [StringComparison]::Ordinal)
                $runtime = $text.IndexOf('# --- REGION: Initialize service runtime', [StringComparison]::Ordinal)
                $confirm | Should -BeGreaterOrEqual 0
                $runtime | Should -BeGreaterThan $confirm
            }
        }
    }

    It 'keeps the service VM bring-up phases in the common order' {
        # Service-specific regions may sit between these; the shared phases must
        # still appear once each, in this order, in every VM-backed service.
        $phases = @('Confirm the service operation', 'Initialize service runtime',
            'Storage preflight', 'Resolve the VM builder', 'Start the host status service',
            'Verify the framework source', 'Create the VM', 'Register and start the UTM VM',
            'Verify the VM state', 'Configure Shared NAT forwarding',
            'Probe service readiness', 'Evaluate service readiness')
        foreach ($service in 'Stash', 'PoolControl', 'DownloadAgent') {
            $path = Join-Path $script:RepoRoot "test/service/Start-${service}ServiceVM.ps1"
            $regions = @([regex]::Matches((Get-Content -LiteralPath $path -Raw),
                    '(?m)^[ \t]*# --- REGION: ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
            $observed = @($regions | Where-Object { $_ -in $phases })
            ($observed -join '|') | Should -BeExactly ($phases -join '|') -Because "Start-${service}ServiceVM.ps1 shares the service bring-up order"
        }
    }

    It 'keeps service guest lifecycle regions in the common order' {
        $names = @('Initialize environment', 'Detect architecture', 'Load retry helpers',
            'Service user', 'Service tunables', 'Storage paths', 'Package dependencies',
            'Locate the daemon source', 'Build', 'Install the binary', 'Storage directories',
            'Environment file', 'systemd unit', 'Start the service and wait for readiness')
        foreach ($service in 'download-agent-service', 'pool-control-service', 'stash-service') {
            $path = Join-Path $script:RepoRoot "guest/ubuntu.server.26/ubuntu.server.26.$service.sh"
            $text = Get-Content -LiteralPath $path -Raw
            $regions = @([regex]::Matches($text, '(?m)^# --- REGION: ([^\r\n]+)') |
                ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -in $names })
            $regions.Count | Should -Be $names.Count
            ($regions -join ',') | Should -BeExactly ($names -join ',')
        }
    }

    It 'keeps the provider contract regions in the same order' {
        $names = @('Module setup', 'Image', 'VM lifecycle', 'VM I/O', 'Discovery',
            'Networking', 'Caching-proxy service', 'Host config', 'Exports')
        $expected = $null
        foreach ($hostKind in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
            $text = Get-Content (Join-Path $script:RepoRoot "host/$hostKind/modules/Yuruna.Host.psm1") -Raw
            $regions = @([regex]::Matches($text, '(?m)^# --- REGION: ([^\r\n]+)') |
                ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -in $names })
            $regions.Count | Should -Be $names.Count
            if ($null -eq $expected) { $expected = $regions -join ',' }
            ($regions -join ',') | Should -BeExactly $expected
        }
    }

    It 'leaves no blank line immediately after a REGION marker' {
        $pattern = '(?m)^[ \t]*(?:(?:#|//)[ \t]*---[ \t]+REGION:[^\r\n]*|<!--[ \t]*(?:---[ \t]+)?REGION:[^\r\n]*-->)[ \t]*\r?\n[ \t]*\r?\n'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'a REGION marker belongs directly to the block it names'
    }

    It 'uses only canonical regions in test-sequence YAML' {
        $findings = @()
        $allowed = @('resource', 'component', 'workload')
        $sequenceFiles = @(Get-ChildItem (Join-Path $script:RepoRoot 'test/sequences') -File -Filter '*.yml')
        if (Test-Path -LiteralPath $script:ProjectRoot) {
            $sequenceFiles += @(Get-ChildItem -LiteralPath $script:ProjectRoot -File -Recurse -Filter '*.yml' |
                Where-Object { $_.FullName -match '[\\/]test[\\/]' })
        }
        foreach ($file in $sequenceFiles) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $markers = [regex]::Matches($text, '(?m)^(?<indent>[ \t]*)# --- REGION: (?<name>[^\r\n]+)\r?\n(?:(?:[ \t]*# See https://yuruna\.link/[^\r\n]+)\r?\n)*(?<next>[^\r\n]*)')
            foreach ($marker in $markers) {
                $name = $marker.Groups['name'].Value
                $next = $marker.Groups['next'].Value
                $location = Format-SourceMatch -File $file -Text $text -Match $marker
                if ($marker.Groups['indent'].Value -or $allowed -cnotcontains $name) {
                    $findings += "${location}: invalid sequence region '$name'"
                } elseif ($next -cnotmatch ('^' + [regex]::Escape($name) + ':(?:[ \t].*)?$')) {
                    $findings += "${location}: '$name' must be immediately followed by '${name}:'"
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'sequence regions exist only at resource, component, and workload granularity'
    }

    It 'matches YAML REGION names to the same-indent keys they precede' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.yml', '.yaml', '.user-data')) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $markers = [regex]::Matches($text,
                '(?m)^(?<indent>[ \t]*)# --- REGION: (?<name>[^\r\n]+)\r?\n(?:(?:\k<indent># See https://yuruna\.link/[^\r\n]+)\r?\n)*\k<indent>(?<key>[A-Za-z0-9_.-]+):')
            foreach ($marker in $markers) {
                $name = $marker.Groups['name'].Value
                if ($name -like 'https://*') { continue }
                $key = $marker.Groups['key'].Value
                if ($name -cne $key) {
                    $location = Format-SourceMatch -File $file -Text $text -Match $marker
                    $findings += "${location}: REGION '$name' precedes '$($key):'"
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'a REGION immediately before a same-indent YAML key uses that key exact name and case'
    }

    It 'matches native HTML REGION names to the elements they precede' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -eq '.html') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $markers = [regex]::Matches($text,
                '(?m)^[ \t]*<!--[ \t]*REGION:[ \t]*(?<name>[^\r\n]*?)[ \t]*-->\r?\n(?:(?:[ \t]*<!--[ \t]*See https://yuruna\.link/[^\r\n]*-->)[ \t]*\r?\n)*[ \t]*<(?<element>html|script|style|body)\b',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            foreach ($marker in $markers) {
                $name = $marker.Groups['name'].Value
                if ($name -like 'https://*') { continue }
                $element = $marker.Groups['element'].Value.ToLowerInvariant()
                if ($name -cne $element) {
                    $location = Format-SourceMatch -File $file -Text $text -Match $marker
                    $findings += "${location}: REGION '$name' precedes '<$element>'"
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'native HTML structural regions use the following element exact name and case'
    }

    It 'keeps documentation links as ordinary comments beside named regions' {
        $pattern = '(?m)^[ \t]*(?<comment>#|//)[ \t]*---[ \t]+REGION:[ \t]*(?:https://yuruna\.link/[^\r\n]+\r?\n[ \t]*\k<comment>[ \t]*---[ \t]+REGION:[ \t]*(?!https://)|(?!(?:https://))[^\r\n]+\r?\n[ \t]*\k<comment>[ \t]*---[ \t]+REGION:[ \t]*https://yuruna\.link/)'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'the named REGION is structural and nearby yuruna.link pointers use # See or // See'
    }

    It 'has no legacy decorative structural headers or decorative See markers' {
        $pattern = '(?m)^[ \t]*(?:(?:#|//)[ \t]*-{8,}[ \t]*|(?:#|//)[ \t]*-{2,}[ \t]+(?!REGION:|See\b)[^\r\n]*?[ \t]-{3,}[ \t]*|(?:#|//)[ \t]*---[ \t]+(?!REGION:|See\b)[A-Z][^\r\n]*|(?:#|//)[ \t]*---[ \t]+See[ \t]+https://yuruna\.link/[^\r\n]*|//[ \t]*={2,}[^\r\n]*={2,}[ \t]*|//[ \t]*[\u2500\u2501\u2550]{2,}[^\r\n]*)$'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'structural headers use the canonical REGION syntax without decorative rules'
    }

    It 'uses the canonical recurring REGION vocabulary' {
        $pattern = '(?m)^[ \t]*(?:#|//)[ \t]*---[ \t]+REGION:[ \t]*(?:Install logging|Storage dirs|Cleanup temporary files|Log level from the environment)[ \t]*$'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'recurring blocks use the canonical names documented in source-consistency.md'
    }

    It 'uses native HTML REGION syntax' {
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -eq '.html') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, '(?m)^[ \t]*<!--[ \t]*---[ \t]+REGION:')) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'HTML comments use <!-- REGION: ... --> natively'
    }

    It 'keeps comment-based help inside a function when a REGION precedes it' {
        $pattern = '(?ms)^[ \t]*# --- REGION:[^\r\n]+\r?\n(?:[ \t]*#(?! --- REGION:)[^\r\n]*\r?\n)*[ \t]*<\#(?:(?!#>)[\s\S])*?#>[ \t]*\r?\n[ \t]*function[ \t]+'
        $findings = @()
        foreach ($file in Get-ConsistencySourceFile | Where-Object Extension -in @('.ps1', '.psm1')) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $findings += Format-SourceMatch -File $file -Text $text -Match $match
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'help discovery requires function help before attributes and param inside the function body'
    }

    It 'keeps both short-link entry pages identical' {
        if (-not (Test-Path $script:LinkRoot)) { Set-ItResult -Skipped -Because 'Sibling link checkout is absent'; return }
        (Get-Content (Join-Path $script:LinkRoot 'index.html') -Raw) |
            Should -BeExactly (Get-Content (Join-Path $script:LinkRoot '404.html') -Raw)
    }
}

Describe 'Stable documentation anchors beside legacy aliases' {
    BeforeAll {
        $path = Join-Path $script:RepoRoot 'tools/Invoke-DocAnchor.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Get-ExistingAnchor'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $script:AnchorPattern = '^<a id="(42[0-9a-f]{6})-([0-9a-f]{4})"></a>$'
    }

    It 'preserves the original id when a legacy alias precedes a heading' {
        $lines = @('<a id="42abcdef-0003"></a>', '', '<a id="old-heading"></a>', '', '## Current heading')
        $found = Get-ExistingAnchor -Line $lines -HeadingIndex 4
        $found.File | Should -Be '42abcdef'
        $found.Anchor | Should -Be '0003'
        $found.Index | Should -Be 0
    }

    It 'does not take an id across intervening document content' {
        $lines = @('<a id="42abcdef-0003"></a>', 'A paragraph.', '', '## New heading')
        Get-ExistingAnchor -Line $lines -HeadingIndex 3 | Should -BeNullOrEmpty
    }
}
