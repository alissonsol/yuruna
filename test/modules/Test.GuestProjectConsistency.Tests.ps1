<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42bc0016-f193-426d-a72c-0c102ad1e5f2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest archive project docker pester
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
    Verify guest archive and development-container failures remain failures.
.DESCRIPTION
    Runs extracted Windows guest bootstrap blocks and a temporary copy of the
    project development launcher with mocked network, archive, Git, and Docker
    commands. No VM, network endpoint, or real container is contacted.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeDiscovery {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $projectRoot = Join-Path (Split-Path -Parent $repoRoot) 'yuruna-project'
    $script:ProjectAvailable = Test-Path (Join-Path $projectRoot 'example/website/components/frontend/website/docker-run-dev.ps1')
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Import.Yaml.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SnapshotManifest.psm1') -Force -DisableNameChecking
    $script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
    $script:UpdateSource = Get-Content (Join-Path $script:RepoRoot 'guest/windows.11/windows.11.update.ps1') -Raw
    $script:DevSource = Join-Path $script:ProjectRoot 'example/website/components/frontend/website/docker-run-dev.ps1'
    $nativeExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $script:HadNativeExitCode = $null -ne $nativeExitCode
    $script:InitialNativeExitCode = if ($script:HadNativeExitCode) { $nativeExitCode.Value } else { $null }
    function Get-UpdateBlock {
        param([string]$Start, [string]$End)
        $begin = $script:UpdateSource.IndexOf($Start)
        $finish = $script:UpdateSource.IndexOf($End, $begin + $Start.Length)
        $text = $script:UpdateSource.Substring($begin, $finish - $begin)
        # Inject only fixture paths and coordinates; retain the production control flow.
        $text = $text.Replace('$env:USERPROFILE', '$script:FixtureProfile').Replace('$env:TEMP', '$script:FixtureProfile')
        $text = $text.Replace('$env:YURUNA_STATUS_SERVICE_IP', '$script:FixtureAddress').Replace('$env:YURUNA_STATUS_SERVICE_PORT', '$script:FixturePort')
        $text = $text.Replace('''C:\ProgramData\yuruna\host.env''', '(Join-Path $script:FixtureProfile ''host.env'')')
        [scriptblock]::Create($text)
    }
    function tar.exe { }
    function git { }
    function docker { }
}
Describe 'Windows guest archive failure handling' {
    BeforeEach {
        $script:FixtureProfile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:FixtureProfile
        $script:FixtureAddress = '192.0.2.10'
        $script:FixturePort = '8080'
        $script:yurunaRoot = Join-Path $script:FixtureProfile 'yuruna'
        $script:frameworkVersion = Join-Path $script:yurunaRoot 'VERSION'
        $script:frameworkUrl = 'https://fixture.invalid/framework'
        $script:projectUrl = 'https://fixture.invalid/project'
        Mock Invoke-WebRequest { }
        Mock Start-Sleep { }
        Mock tar.exe {
            $destination = $args[3]
            Set-Content (Join-Path $destination 'partial.txt') 'partial archive'
            $global:LASTEXITCODE = 2
        }
        Mock git {
            $destination = $args[-1]
            $null = New-Item -ItemType Directory $destination -Force
            Set-Content (Join-Path $destination 'complete.txt') 'complete checkout'
            Set-Content (Join-Path $destination 'VERSION') '1.0.0'
            $global:LASTEXITCODE = 0
        }
    }
    It 'cleans a failed early extraction instead of announcing it as available' {
        $block = Get-UpdateBlock '# --- REGION: Early yuruna framework extraction' '# --- REGION: Disable services that may suspend'
        $output = & $block
        Test-Path $yurunaRoot | Should -BeFalse
        ($output -join "`n") | Should -Not -Match 'Yuruna framework available'
    }
    It 'falls back to bounded git after a failed framework extraction' {
        $block = Get-UpdateBlock '# --- REGION: Materialize the yuruna framework and project repos' '$yurunaProject ='
        & $block | Out-Null
        Should -Invoke git -Times 1 -Exactly
        Should -Invoke git -Times 1 -ParameterFilter { $args -contains 'http.lowSpeedLimit=1024' -and $args -contains 'http.lowSpeedTime=60' }
        Test-Path (Join-Path $yurunaRoot 'partial.txt') | Should -BeFalse
    }
    It 'accepts the <Stage> framework archive only with a regular nonempty VERSION (<VersionShape>)' -ForEach @(
        foreach ($stage in 'early', 'materialize') {
            foreach ($shape in 'healthy', 'missing', 'empty', 'directory') {
                @{ Stage = $stage; VersionShape = $shape }
            }
        }
    ) {
        $script:VersionShape = $VersionShape
        Mock tar.exe {
            $destination = $args[3]
            Set-Content (Join-Path $destination 'partial.txt') 'archive payload'
            switch ($script:VersionShape) {
                healthy { Set-Content (Join-Path $destination 'VERSION') '1.0.0' }
                empty { [IO.File]::WriteAllText((Join-Path $destination 'VERSION'), '') }
                directory { $null = New-Item -ItemType Directory (Join-Path $destination 'VERSION') }
            }
            $global:LASTEXITCODE = 0
        }
        $block = if ($Stage -eq 'early') {
            Get-UpdateBlock '# --- REGION: Early yuruna framework extraction' '# --- REGION: Disable services that may suspend'
        } else {
            Get-UpdateBlock '# --- REGION: Materialize the yuruna framework and project repos' '$yurunaProject ='
        }
        $output = & $block
        if ($Stage -eq 'materialize') {
            Test-Path -LiteralPath $frameworkVersion -PathType Leaf | Should -BeTrue
            if ($VersionShape -eq 'healthy') {
                Should -Invoke git -Times 0 -Exactly
                Test-Path (Join-Path $yurunaRoot 'partial.txt') | Should -BeTrue
            } else {
                Should -Invoke git -Times 1 -Exactly
                Test-Path (Join-Path $yurunaRoot 'partial.txt') | Should -BeFalse
            }
        } elseif ($VersionShape -eq 'healthy') {
            Test-Path $yurunaRoot | Should -BeTrue
            ($output -join "`n") | Should -Match 'Yuruna framework available'
        } else {
            Test-Path $yurunaRoot | Should -BeFalse
            ($output -join "`n") | Should -Not -Match 'Yuruna framework available'
        }
        if ($Stage -eq 'early') { Should -Invoke git -Times 0 -Exactly }
    }
    It 'accepts a successful framework clone only with a regular nonempty VERSION (<VersionShape>)' -ForEach @(
        @{ VersionShape = 'healthy' }, @{ VersionShape = 'missing' },
        @{ VersionShape = 'empty' }, @{ VersionShape = 'directory' }
    ) {
        $script:VersionShape = $VersionShape
        Mock git {
            $destination = $args[-1]
            $null = New-Item -ItemType Directory $destination -Force
            Set-Content (Join-Path $destination 'complete.txt') 'checkout payload'
            switch ($script:VersionShape) {
                healthy { Set-Content (Join-Path $destination 'VERSION') '1.0.0' }
                empty { [IO.File]::WriteAllText((Join-Path $destination 'VERSION'), '') }
                directory { $null = New-Item -ItemType Directory (Join-Path $destination 'VERSION') }
            }
            $global:LASTEXITCODE = 0
        }
        $block = Get-UpdateBlock '# --- REGION: Materialize the yuruna framework and project repos' '$yurunaProject ='
        if ($VersionShape -eq 'healthy') {
            & $block | Out-Null
            Should -Invoke git -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
            Test-Path -LiteralPath $frameworkVersion -PathType Leaf | Should -BeTrue
        } else {
            { & $block *>&1 | Out-Null } | Should -Throw
            Should -Invoke git -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 60 }
            Test-Path $yurunaRoot | Should -BeFalse
        }
    }
    It 'rejects partial project extraction before bounded git fallback' {
        $block = Get-UpdateBlock '$yurunaProject =' '# --- REGION: Clean up temporary files'
        $null = New-Item -ItemType Directory $yurunaRoot
        & $block | Out-Null
        Should -Invoke git -Times 1 -Exactly
        Should -Invoke git -Times 1 -ParameterFilter { $args -contains 'http.lowSpeedLimit=1024' -and $args -contains 'http.lowSpeedTime=60' }
        Test-Path (Join-Path $yurunaRoot 'project/partial.txt') | Should -BeFalse
    }
}
Describe 'Development container launch failure handling' -Skip:(-not $script:ProjectAvailable) {
    BeforeEach {
        $script:FixtureScriptFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:FixtureScriptFolder
        $script:FixtureScript = Join-Path $script:FixtureScriptFolder 'docker-run-dev.ps1'
        Copy-Item $script:DevSource $script:FixtureScript
        Set-Content (Join-Path $script:FixtureScriptFolder 'copy-pfx.ps1') 'Write-Output "certificate copied"'
        $script:StartDirectory = (Get-Location).Path
        Mock docker { $global:LASTEXITCODE = 0 }
    }
    AfterEach { Set-Location $script:StartDirectory }
    It 'does not launch an old image after a failed build' {
        Mock docker { $global:LASTEXITCODE = 17 } -ParameterFilter { $args[0] -eq 'build' }
        { & $script:FixtureScript | Out-Null } | Should -Throw '*build*'
        Should -Invoke docker -Times 0 -ParameterFilter { $args[0] -eq 'run' }
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
    It 'restores the caller directory when certificate preparation fails' {
        Set-Content (Join-Path $script:FixtureScriptFolder 'copy-pfx.ps1') 'throw "certificate missing"'
        { & $script:FixtureScript | Out-Null } | Should -Throw '*certificate missing*'
        Should -Invoke docker -Times 0
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
    It 'reports container failure and restores the caller directory' {
        Mock docker { $global:LASTEXITCODE = 19 } -ParameterFilter { $args[0] -eq 'run' }
        { & $script:FixtureScript | Out-Null } | Should -Throw '*run*'
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
    It 'retains the normal build and run flow' {
        & $script:FixtureScript | Out-Null
        Should -Invoke docker -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'build' }
        Should -Invoke docker -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'run' }
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
}

Describe 'Website shell readiness and single build ownership' -Skip:(-not $script:ProjectAvailable) {
    It 'the declared Ubuntu <Version> prompt rejects login text and accepts an OCR-damaged shell prompt' -ForEach @(
        @{ Version = '24' }, @{ Version = '26' }
    ) {
        $sequencePath = Join-Path $script:ProjectRoot "example/website/test/workload.guest.ubuntu.server.$Version.k8s.website.yml"
        $sequence = ConvertFrom-File $sequencePath
        $wait = @($sequence.component | Where-Object { $_.action -eq 'waitForText' })[0]
        $pattern = $wait.pattern.Replace('${username}', $sequence.variables.username).Replace('${hostname}', $sequence.variables.hostname)
        $login = "Ubuntu $Version.04.1 LTS yuhost$Version tty1`nyuhost$Version login:`nyuhost$Version login: yuuser$Version`nPassword:"
        $prompt = "Welcome to Ubuntu`nyuuser$Version@yuh0st$Version : ~ `$"
        $wait.noSegmentMatch | Should -BeTrue
        Test-OCRMatch -Text $login -Pattern $pattern -NoSegmentMatch:$wait.noSegmentMatch | Should -BeFalse
        Test-OCRMatch -Text $prompt -Pattern $pattern -NoSegmentMatch:$wait.noSegmentMatch | Should -BeTrue
        @($sequence.component | Where-Object { $_.snippet -eq 'shellInputPrime' }).Count | Should -Be 1
    }

    It '<Example> Ubuntu <Version> publishes once and stops before deployment when component publishing fails (<FailComponent>)' -ForEach @(
        @{ Example = 'website'; Version = '24'; FailComponent = '0' }, @{ Example = 'website'; Version = '26'; FailComponent = '0' },
        @{ Example = 'website'; Version = '24'; FailComponent = '1' }, @{ Example = 'website'; Version = '26'; FailComponent = '1' },
        @{ Example = 'text-to-sql'; Version = '24'; FailComponent = '0' }, @{ Example = 'text-to-sql'; Version = '24'; FailComponent = '1' }
    ) {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'The guest entrypoint executes Bash on Linux.'; return }
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $toolsFolder = Join-Path $fixture 'yuruna/project/tools'
        $null = New-Item -ItemType Directory -Force $toolsFolder, (Join-Path $fixture "yuruna/project/example/$Example/config/localhost")
        $helper = Get-Content -Raw -LiteralPath (Join-Path $script:ProjectRoot 'tools/example-workload.sh')
        $helper += @'

example_registry_prepare() { printf 'prepare\n' >> "$YURUNA_WEBSITE_CALLS"; }
example_prune_build_cache() { printf 'prune\n' >> "$YURUNA_WEBSITE_CALLS"; }
example_build_and_push() { printf 'duplicate-build\n' >> "$YURUNA_WEBSITE_CALLS"; return 90; }
'@
        Set-Content -LiteralPath (Join-Path $toolsFolder 'example-workload.sh') -Value $helper
        $stubs = @'
function sudo() { return 0; }
function mkcert() { return 0; }
function kubectl() { return 0; }
function getent() {
    [ "$1" = passwd ] || return 93
    printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "$YURUNA_WEBSITE_FIXTURE"
}
function pwsh() {
    case "$1" in
        *Set-Resource.ps1)
            printf 'resource\n' >> "$YURUNA_WEBSITE_CALLS"
            printf 'clusterDnsPrefix: fixture\n' > "$YURUNA_WEBSITE_FIXTURE/yuruna/project/example/$2/config/localhost/resources.output.yml"
            ;;
        *Set-Component.ps1)
            [ "${YURUNA_EXAMPLE_SELF_SIGNED_CERT:-}" = 1 ] || return 91
            printf 'component\n' >> "$YURUNA_WEBSITE_CALLS"
            [ "$YURUNA_WEBSITE_FAIL" = 0 ] || return 42
            ;;
        *Set-Workload.ps1) printf 'workload\n' >> "$YURUNA_WEBSITE_CALLS" ;;
        *) return 92 ;;
    esac
}
'@
        $bashEnvironment = Join-Path $fixture 'stubs.sh'
        Set-Content -LiteralPath $bashEnvironment -Value $stubs
        $source = Get-Content -Raw -LiteralPath (Join-Path $script:ProjectRoot "example/$Example/test/ubuntu.server.$Version/ubuntu.server.$Version.workload.k8s.$Example.sh")
        $entrypoint = Join-Path $fixture 'entrypoint.sh'
        Set-Content -LiteralPath $entrypoint -Value $source
        $callsFile = Join-Path $fixture 'calls.txt'
        $result = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @($entrypoint) -TimeoutSeconds 10 `
            -Environment @{ BASH_ENV = $bashEnvironment; YURUNA_WEBSITE_FIXTURE = $fixture; YURUNA_WEBSITE_CALLS = $callsFile; YURUNA_WEBSITE_FAIL = $FailComponent }
        $calls = @(Get-Content -LiteralPath $callsFile)
        if ($FailComponent -eq '0') {
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            ($calls -join ',') | Should -BeExactly 'prepare,resource,component,prune,workload'
        } else {
            $result.ExitCode | Should -Be 42 -Because $result.StdErr
            ($calls -join ',') | Should -BeExactly 'prepare,resource,component'
        }
        $config = ConvertFrom-File (Join-Path $script:ProjectRoot "example/$Example/config/localhost/components.yml")
        $config.globalVariables.buildCommand | Should -Match '^docker build .*--no-cache'
        $config.globalVariables.pushCommand | Should -Match '^docker push '
    }
}

Describe 'Application image package resolution and compilation' -Skip:(-not $script:ProjectAvailable) {
    It '<Example> restores once and compiles during publish, preserving <Failure> failures' -ForEach @(
        @{ Example='website'; Component='website'; Failure='none' },
        @{ Example='website'; Component='website'; Failure='restore' },
        @{ Example='website'; Component='website'; Failure='compile' },
        @{ Example='text-to-sql'; Component='text-to-sql-ui'; Failure='none' },
        @{ Example='text-to-sql'; Component='text-to-sql-ui'; Failure='restore' },
        @{ Example='text-to-sql'; Component='text-to-sql-ui'; Failure='compile' }
    ) {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'Docker RUN shell commands execute Bash in the Linux SDK image.'; return }
        $dockerfile = Get-Content -Raw -LiteralPath (Join-Path $script:ProjectRoot "example/$Example/components/frontend/$Component/Dockerfile")
        # Run the shipped project commands against a recorder of SDK operations.
        # Implicit restore/build behavior counts too: a successful image must
        # still compile fresh, and a failing restore or compiler must stop it.
        $commands = @([regex]::Matches($dockerfile, '(?m)^RUN (dotnet (?:restore|build|publish) [^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
        $commands.Count | Should -BeGreaterOrEqual 2
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $stub = @'
set -euo pipefail
resolve_packages() {
    printf 'restore\n' >> "$YURUNA_IMAGE_CALLS"
    [ "$YURUNA_IMAGE_FAILURE" != restore ] || return 23
    : > "$YURUNA_IMAGE_ASSETS"
}
compile_application() {
    [ -f "$YURUNA_IMAGE_ASSETS" ] || return 24
    printf 'compile\n' >> "$YURUNA_IMAGE_CALLS"
    [ "$YURUNA_IMAGE_FAILURE" != compile ] || return 29
}
dotnet() {
    local operation="$1" no_restore=0 no_build=0 arg
    shift
    for arg in "$@"; do
        [ "$arg" != --no-restore ] || no_restore=1
        [ "$arg" != --no-build ] || no_build=1
    done
    if [ "$operation" = restore ]; then resolve_packages; return; fi
    # --no-build implies --no-restore in the SDK.
    if [ "$no_restore" = 0 ] && [ "$no_build" = 0 ]; then resolve_packages || return; fi
    if [ "$no_build" = 0 ]; then compile_application || return; fi
    if [ "$operation" = publish ]; then
        printf 'publish\n' >> "$YURUNA_IMAGE_CALLS"
        : > "$YURUNA_IMAGE_OUTPUT"
    fi
}
'@
        $entrypoint = Join-Path $fixture 'image-commands.sh'
        Set-Content -LiteralPath $entrypoint -Value ($stub + "`n" + ($commands -join "`n"))
        $callsFile = Join-Path $fixture 'calls.txt'
        $outputFile = Join-Path $fixture 'published'
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($entrypoint) -TimeoutSeconds 10 `
            -Environment @{ YURUNA_IMAGE_CALLS=$callsFile; YURUNA_IMAGE_FAILURE=$Failure; YURUNA_IMAGE_ASSETS=(Join-Path $fixture 'assets'); YURUNA_IMAGE_OUTPUT=$outputFile }
        $calls = @(Get-Content -LiteralPath $callsFile)
        switch ($Failure) {
            none {
                $result.ExitCode | Should -Be 0 -Because $result.StdErr
                ($calls -join ',') | Should -BeExactly 'restore,compile,publish'
                Test-Path -LiteralPath $outputFile | Should -BeTrue
            }
            restore {
                $result.ExitCode | Should -Be 23 -Because $result.StdErr
                ($calls -join ',') | Should -BeExactly restore
                Test-Path -LiteralPath $outputFile | Should -BeFalse
            }
            compile {
                $result.ExitCode | Should -Be 29 -Because $result.StdErr
                ($calls -join ',') | Should -BeExactly 'restore,compile'
                Test-Path -LiteralPath $outputFile | Should -BeFalse
            }
        }
    }
}

Describe 'Project sequence readiness and entrypoint consistency' -Skip:(-not $script:ProjectAvailable) {
    It '<Cloud> ingress uses the stable Linux node label while retaining its service shape' -ForEach @(
        @{ Cloud = 'aws'; Replicas = 2; ServiceType = 'NodePort' },
        @{ Cloud = 'azure'; Replicas = 1; ServiceType = '' },
        @{ Cloud = 'localhost'; Replicas = 1; ServiceType = 'ClusterIP' }
    ) {
        $config = ConvertFrom-File (Join-Path $script:ProjectRoot "example/website/config/$Cloud/workloads.yml")
        $ingress = @($config.workloads[0].deployments | Where-Object { $_.helm -like '*install nginx-ingress ingress-nginx/ingress-nginx*' })
        $ingress.Count | Should -Be 1
        $ingress[0].helm | Should -Match '--set controller[.]nodeSelector[.]"kubernetes\\[.]io/os"=linux'
        $ingress[0].helm | Should -Not -Match 'nodeSelector[.]"beta\\[.]kubernetes'
        $ingress[0].helm | Should -Match ([regex]::Escape("--set controller.replicaCount=$Replicas"))
        if ($ServiceType) {
            $ingress[0].helm | Should -Match ([regex]::Escape("--set controller.service.type=$ServiceType"))
        } else {
            $ingress[0].helm | Should -Not -Match '--set controller[.]service[.]type='
            $ingress[0].helm | Should -Match '--set controller[.]service[.]loadBalancerIP='
        }
        if ($Cloud -eq 'aws') {
            $ingress[0].helm | Should -Match '--set defaultBackend[.]nodeSelector[.]"kubernetes\\[.]io/os"=linux'
            $ingress[0].helm | Should -Match '--set controller[.]service[.]nodePorts[.]http=30080'
            $ingress[0].helm | Should -Match '--set controller[.]service[.]nodePorts[.]https=30443'
        }
    }

    It 'Ubuntu <Version> snapshot producer and consumer fingerprint shared builders and seed dependencies without Git metadata' -ForEach @(
        @{ Version = '24' }, @{ Version = '26' }
    ) {
        $baseline = ConvertFrom-File (Join-Path $script:ProjectRoot "example/website/test/workload.guest.ubuntu.server.$Version.k8s.website.baseline.ssh.yml")
        $warm = ConvertFrom-File (Join-Path $script:ProjectRoot "example/website/test/workload.guest.ubuntu.server.$Version.k8s.website.warm.ssh.yml")
        ($baseline.snapshotPolicy.sourceFiles -join "`n") | Should -BeExactly ($warm.snapshotPolicy.sourceFiles -join "`n")
        $required = @(
            foreach ($platform in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
                "host/$platform/modules/Get-UbuntuServerImage.ps1"
                "host/$platform/modules/New-UbuntuServerVM.ps1"
                "host/$platform/modules/Yuruna.Host.psm1"
            }
            'host/modules/Yuruna.UbuntuImage.psm1'
            'host/modules/Yuruna.Image.psm1'
            'host/vmconfig/guest-dhcp.network-config'
            "host/macos.utm/guest.ubuntu.server.$Version/config.plist.template"
            'automation/Yuruna.CloudInitTemplate.psm1'
            'automation/Yuruna.Common.psm1'
            'automation/Yuruna.GitHubSource.psm1'
            'automation/Yuruna.GuestSeed.psm1'
            'automation/fetch-and-execute.sh'
            'automation/yuruna-fetch-context.sh'
            'automation/yuruna-network.sh'
            'automation/yuruna-host-locate.sh'
            'automation/yuruna-retry.sh'
            'automation/yuruna-versions.sh'
            'test/modules/Test.Ssh.psm1'
            'test/modules/Test.Config.psm1'
            'test/modules/Test.CachingProxyService.psm1'
        )
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($pattern in $baseline.snapshotPolicy.sourceFiles) {
            $sourceRoot = $script:RepoRoot
            $relativePattern = $pattern
            $prefix = ''
            if ($pattern.StartsWith('project/')) {
                $sourceRoot = $script:ProjectRoot
                $relativePattern = $pattern.Substring('project/'.Length)
                $prefix = 'project/'
            }
            $sources = @(Get-ChildItem -Path (Join-Path $sourceRoot $relativePattern) -File -ErrorAction Stop)
            $sources.Count | Should -BeGreaterThan 0 -Because "snapshot input $pattern must exist"
            foreach ($source in $sources) {
                $relative = $prefix + [IO.Path]::GetRelativePath($sourceRoot, $source.FullName)
                $destination = Join-Path $fixture $relative
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
                Set-Content -LiteralPath $destination -Value 'baseline input'
            }
        }
        $before = Get-SnapshotSourceIdentity -RepoRoot $fixture -GuestKey "ubuntu.server.$Version" -Policy $baseline.snapshotPolicy
        foreach ($relative in $required) {
            $before.files.path | Should -Contain $relative
            $destination = Join-Path $fixture $relative
            Set-Content -LiteralPath $destination -Value 'changed input'
            $after = Get-SnapshotSourceIdentity -RepoRoot $fixture -GuestKey "ubuntu.server.$Version" -Policy $baseline.snapshotPolicy
            $after.identitySha256 | Should -Not -BeExactly $before.identitySha256 -Because "changing $relative must reject the old baseline"
            Set-Content -LiteralPath $destination -Value 'baseline input'
        }
    }

    It 'Ubuntu <Version> SSH HTTP checks preserve helper exit <ExitCode> even when output contains 200' -ForEach @(
        @{ Version = '24'; ExitCode = 0 }, @{ Version = '26'; ExitCode = 0 },
        @{ Version = '24'; ExitCode = 17 }, @{ Version = '26'; ExitCode = 17 }
    ) {
        $sequence = ConvertFrom-File (Join-Path $script:ProjectRoot "example/website/test/workload.guest.ubuntu.server.$Version.k8s.website.ssh.yml")
        $step = @($sequence.workload | Where-Object { $_.command -like '*test/test-localhost.sh*' })
        $step.Count | Should -Be 1
        $step[0].action | Should -BeExactly 'sshFetchAndExecute'
        $step[0].command | Should -BeExactly '/usr/local/lib/yuruna/fetch-and-execute.sh test/test-localhost.sh'
        $step[0].timeoutSeconds | Should -BeGreaterOrEqual 240
        if ($IsWindows) { Set-ItResult -Skipped -Because 'The SSH command executes Bash in the Linux guest.'; return }
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + ' with spaces')
        $null = New-Item -ItemType Directory -Path $fixture
        $helper = Join-Path $fixture 'fetch-and-execute.sh'
        Set-Content -LiteralPath $helper -Value @'
[ "$#" -eq 1 ] && [ "$1" = test/test-localhost.sh ] || exit 23
printf 'HTTP/1.1 200 OK\n'
exit "$YURUNA_HTTP_EXIT"
'@
        $quotedHelper = "'" + $helper.Replace("'", "'\''") + "'"
        $command = $step[0].command.Replace('/usr/local/lib/yuruna/fetch-and-execute.sh', "bash $quotedHelper")
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @('-c', $command) -TimeoutSeconds 10 `
            -Environment @{ YURUNA_HTTP_EXIT = [string]$ExitCode }
        $result.ExitCode | Should -Be $ExitCode -Because $result.StdErr
        $result.StdOut | Should -Match 'HTTP/1.1 200 OK'
    }

    It '<Sequence> verifies a shell before typing without overriding host input pacing' -ForEach @(
        @{ Sequence = 'ch01.website.example.yml' }, @{ Sequence = 'ch01.website.example.no-break.yml' },
        @{ Sequence = 'ch02.website.k8s.dotnet.yml' }, @{ Sequence = 'ch02.website.k8s.dotnet.no-break.yml' }
    ) {
        $sequence = ConvertFrom-File (Join-Path $script:ProjectRoot "book/test/$Sequence")
        $wait = @($sequence.component | Where-Object { $_.action -eq 'waitForText' })[0]
        $pattern = $wait.pattern.Replace('${username}', $sequence.variables.username).Replace('${hostname}', $sequence.variables.hostname)
        $login = "$($sequence.variables.hostname) login: $($sequence.variables.username)`nPassword:"
        $shell = "$($sequence.variables.username)@$($sequence.variables.hostname):~ `$"
        $wait.noSegmentMatch | Should -BeTrue
        Test-OCRMatch -Text $login -Pattern $pattern -NoSegmentMatch | Should -BeFalse
        Test-OCRMatch -Text $shell -Pattern $pattern -NoSegmentMatch | Should -BeTrue
        $sequence.component[-1].snippet | Should -BeExactly 'shellInputPrime'
        foreach ($step in @($sequence.component) + @($sequence.workload)) {
            $step.Keys | Should -Not -Contain 'charDelayMs'
            $step.Keys | Should -Not -Contain 'delaySeconds'
        }
    }

    It '<Sequence> allows HTTP readiness and console delivery without changing character pacing' -ForEach @(
        @{ Sequence = 'book/test/ch02.website.k8s.dotnet.yml' },
        @{ Sequence = 'book/test/ch02.website.k8s.dotnet.no-break.yml' },
        @{ Sequence = 'example/text-to-sql/test/workload.guest.ubuntu.server.24.k8s.text-to-sql.test.yml' }
    ) {
        $sequence = ConvertFrom-File (Join-Path $script:ProjectRoot $Sequence)
        $step = @($sequence.workload | Where-Object { $_.text -like '*test/test-localhost.sh*' })
        $step.Count | Should -Be 1
        $step[0].timeoutSeconds | Should -BeGreaterOrEqual 420
        $step[0].waitPattern | Should -BeExactly '200 OK'
        $step[0].Keys | Should -Not -Contain 'charDelayMs'
        $step[0].Keys | Should -Not -Contain 'delaySeconds'
    }

    It 'nested-host automation uses an existing framework entrypoint' {
        $sequence = ConvertFrom-File (Join-Path $script:ProjectRoot 'example/nested.host/test/nested.host.yml')
        $step = @($sequence.component | Where-Object { $_.command -like '*Enable-TestAutomation.ps1*' })
        $step.Count | Should -Be 1
        $step[0].command | Should -BeExactly 'pwsh ~/git/yuruna/test/lab/Enable-TestAutomation.ps1'
        Join-Path $script:RepoRoot 'test/lab/Enable-TestAutomation.ps1' | Should -Exist
    }

    It '<Config> strips only the ACR hostname suffix from <Registry>' -ForEach @(
        foreach ($config in @(
            'template/config/localhost/workloads.yml',
            'example/website/config/localhost/workloads.yml',
            'example/text-to-sql/config/localhost/workloads.yml',
            'example/website/config/azure/workloads.yml'
        )) {
            foreach ($case in @(
                @{ Registry = 'example.azurecr.io'; Expected = 'example' },
                @{ Registry = 'example.AZURECR.IO'; Expected = 'example' },
                @{ Registry = 'myxazurecrYio.example:5000'; Expected = 'myxazurecrYio.example:5000' },
                @{ Registry = 'host.azurecr.io.example:5000'; Expected = 'host.azurecr.io.example:5000' }
            )) {
                @{ Config = $config; Registry = $case.Registry; Expected = $case.Expected }
            }
        }
    ) {
        $config = ConvertFrom-File (Join-Path $script:ProjectRoot $Config)
        $registryKey = 'YURUNA_CONSISTENCY_REGISTRY.registryLocation'
        $originalName = [Environment]::GetEnvironmentVariable('registryName')
        $originalLocation = [Environment]::GetEnvironmentVariable($registryKey)
        try {
            [Environment]::SetEnvironmentVariable('registryName', 'YURUNA_CONSISTENCY_REGISTRY')
            [Environment]::SetEnvironmentVariable($registryKey, $Registry)
            $ExecutionContext.InvokeCommand.ExpandString($config.globalVariables._registryLocation) | Should -BeExactly $Expected
        } finally {
            [Environment]::SetEnvironmentVariable('registryName', $(if ($null -eq $originalName) { [NullString]::Value } else { $originalName }))
            [Environment]::SetEnvironmentVariable($registryKey, $(if ($null -eq $originalLocation) { [NullString]::Value } else { $originalLocation }))
        }
    }

    It 'Ubuntu 24 script labels agree with every localized script identity in <Sequence>' -ForEach @(
        @{ Sequence = 'workload.guest.ubuntu.server.24.k8s.website.yml' },
        @{ Sequence = 'workload.guest.ubuntu.server.24.k8s.website.ssh.yml' },
        @{ Sequence = 'workload.guest.ubuntu.server.24.k8s.website.baseline.ssh.yml' },
        @{ Sequence = 'workload.guest.ubuntu.server.24.k8s.website.warm.ssh.yml' }
    ) {
        $sequence = ConvertFrom-File (Join-Path $script:ProjectRoot "example/website/test/$Sequence")
        $steps = @($sequence.workload | Where-Object { $_.description -like 'ubuntu.server.24*.sh' })
        $steps.Count | Should -BeGreaterThan 0
        foreach ($step in $steps) {
            foreach ($locale in $step.descriptionLocalized.Keys) {
                $step.descriptionLocalized[$locale] | Should -Match ([regex]::Escape($step.description))
                $step.descriptionLocalized[$locale] | Should -Not -Match 'ubuntu\.server\.26'
            }
        }
    }
}

Describe 'Guest bootstrap account and phase consistency' {
    It 'defines the Windows <Workload> package helper before installation phases with discoverable help' -ForEach @(
        @{ Workload = 'update' }, @{ Workload = 'code' }, @{ Workload = 'k8s' }
    ) {
        $source = Get-Content (Join-Path $script:RepoRoot "guest/windows.11/windows.11.$Workload.ps1") -Raw
        $regions = @([regex]::Matches($source, '(?m)^# --- REGION: ([^\r\n]+)') |
            ForEach-Object { $_.Groups[1].Value })
        ($regions[0..1] -join ',') | Should -BeExactly 'Ensure running as Administrator,Invoke-GuestWingetInstall'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $helper = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GuestWingetInstall'
        }, $true)
        $helper.GetHelpContent().Synopsis.Trim() | Should -BeExactly 'Install a prerequisite or accept its documented already-present outcome.'
    }

    It 'macOS <Stage> restores the login group for an account home with <HomeShape>' -ForEach @(
        @{ Stage = 'early'; HomeShape = 'plain' }, @{ Stage = 'early'; HomeShape = 'spaces and quotes' },
        @{ Stage = 'final'; HomeShape = 'plain' }, @{ Stage = 'final'; HomeShape = 'spaces and quotes' }
    ) {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'The guest bootstrap executes Bash on macOS.'; return }
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if ($HomeShape -eq 'spaces and quotes') { $fixture += " guest's home" }
        $null = New-Item -ItemType Directory -Path $fixture
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/macos.26/macos.26.update.sh') -Raw
        if ($Stage -eq 'early') {
            $start = $source.IndexOf('# --- REGION: Early yuruna framework extraction')
            $end = $source.IndexOf('# --- REGION: Disable services that may suspend the machine', $start)
            $source = $source.Substring($start, $end - $start)
        } else {
            $source = $source.Substring($source.IndexOf('# --- REGION: Restore operator file ownership'))
        }
        $source = $source.Replace('/etc/yuruna/host.env', '"$YURUNA_GUEST_FIXTURE/absent-host.env"')
        $prefix = @'
set -euo pipefail
SUDO_USER=guestuser
USER=root
REAL_USER=guestuser
REAL_GROUP=staff
REAL_HOME="$YURUNA_GUEST_FIXTURE"
YURUNA_STATUS_SERVICE_IP=192.0.2.1
YURUNA_STATUS_SERVICE_PORT=8080
dscl() {
    [ "$*" = '. -read /Users/guestuser NFSHomeDirectory' ] || return 91
    printf 'NFSHomeDirectory: %s\n' "$YURUNA_GUEST_FIXTURE"
}
id() {
    [ "$*" = '-gn guestuser' ] || return 94
    printf 'staff\n'
}
yuruna_host_livecheck() { return 0; }
curl() { printf archive; }
tar() {
    cat >/dev/null
    [ "$1" = -xz ] && [ "$2" = -C ] && [ "$3" = "$YURUNA_GUEST_FIXTURE/yuruna" ] || return 92
    printf '1.0.0\n' > "$3/VERSION"
}
sudo() {
    [ "$#" = 4 ] && [ "$1" = chown ] && [ "$2" = -R ] &&
        [ "$3" = 'guestuser:staff' ] && [ "$4" = "$YURUNA_GUEST_FIXTURE/yuruna" ] || return 93
    printf '%s\n' "$3" "$4" >> "$YURUNA_GUEST_CALLS"
}
'@
        $entrypoint = Join-Path $fixture 'fixture.sh'
        $callsFile = Join-Path $fixture 'calls.txt'
        Set-Content -LiteralPath $entrypoint -Value ($prefix + "`n" + $source)
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($entrypoint) -TimeoutSeconds 10 `
            -Environment @{ YURUNA_GUEST_FIXTURE = $fixture; YURUNA_GUEST_CALLS = $callsFile }
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        @(Get-Content -LiteralPath $callsFile) | Should -HaveCount 2
        (Get-Content -LiteralPath $callsFile)[0] | Should -BeExactly 'guestuser:staff'
        (Get-Content -LiteralPath $callsFile)[1] | Should -BeExactly "$fixture/yuruna"
        if ($Stage -eq 'early') {
            Get-Content -LiteralPath (Join-Path $fixture 'yuruna/VERSION') | Should -BeExactly '1.0.0'
            $result.StdOut | Should -Match 'Yuruna framework available'
        }
    }

    It 'macOS rejects unusable account metadata before touching a checkout (<HomeShape>)' -ForEach @(
        @{ HomeShape = 'empty' }, @{ HomeShape = 'relative' }, @{ HomeShape = 'lookup-error' },
        @{ HomeShape = 'empty-group' }, @{ HomeShape = 'group-lookup-error' }
    ) {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'The guest bootstrap executes Bash on macOS.'; return }
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/macos.26/macos.26.update.sh') -Raw
        $start = $source.IndexOf('# --- REGION: Early yuruna framework extraction')
        $end = $source.IndexOf('# --- REGION: Disable services that may suspend the machine', $start)
        $source = $source.Substring($start, $end - $start).Replace('/etc/yuruna/host.env', '"$YURUNA_GUEST_FIXTURE/absent-host.env"')
        $prefix = @'
set -euo pipefail
SUDO_USER=guestuser
USER=root
dscl() {
    case "$YURUNA_GUEST_HOME_SHAPE" in
        empty) printf 'NFSHomeDirectory: \n' ;;
        relative) printf 'NFSHomeDirectory: relative/home\n' ;;
        lookup-error) return 42 ;;
        *) printf 'NFSHomeDirectory: %s\n' "$YURUNA_GUEST_FIXTURE" ;;
    esac
}
id() {
    [ "$*" = '-gn guestuser' ] || return 94
    [ "$YURUNA_GUEST_HOME_SHAPE" = empty-group ] && return 0
    return 42
}
sudo() { printf sudo >> "$YURUNA_GUEST_CALLS"; return 90; }
mkdir() { printf mkdir >> "$YURUNA_GUEST_CALLS"; return 90; }
curl() { printf curl >> "$YURUNA_GUEST_CALLS"; return 90; }
yuruna_host_livecheck() { printf livecheck >> "$YURUNA_GUEST_CALLS"; return 90; }
'@
        $entrypoint = Join-Path $fixture 'fixture.sh'
        $callsFile = Join-Path $fixture 'calls.txt'
        Set-Content -LiteralPath $entrypoint -Value ($prefix + "`n" + $source)
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($entrypoint) -TimeoutSeconds 10 `
            -Environment @{ YURUNA_GUEST_FIXTURE = $fixture; YURUNA_GUEST_CALLS = $callsFile; YURUNA_GUEST_HOME_SHAPE = $HomeShape }
        $result.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $callsFile | Should -BeFalse
        if ($HomeShape -in @('empty', 'relative')) { $result.StdErr | Should -Match 'Cannot resolve an absolute home directory' }
        if ($HomeShape -eq 'empty-group') { $result.StdErr | Should -Match 'Cannot resolve the primary group' }
    }

    It 'keeps the service seed checkout-promotion helper and its region identical' {
        $expected = $null
        foreach ($service in 'download-agent-service', 'pool-control-service', 'stash-service') {
            $seed = Get-Content (Join-Path $script:RepoRoot "host/vmconfig/$service.base.user-data") -Raw
            $match = [regex]::Match($seed, '(?m)^(?<indent> +)# --- REGION: yuruna_accept_framework\r?\n(?<body>(?:\k<indent>[^\r\n]*\r?\n)+?)\k<indent>OK=0')
            $match.Success | Should -BeTrue -Because "$service preserves a searchable common checkout-promotion block"
            $body = $match.Groups['body'].Value -replace "(?m)^$($match.Groups['indent'].Value)", '' -replace '\r\n', "`n"
            if ($null -eq $expected) { $expected = $body }
            $body | Should -BeExactly $expected
            $body | Should -Match '(?m)^yuruna_accept_framework\(\) \{'
        }
    }
}

AfterAll {
    if ($script:HadNativeExitCode) {
        Set-Variable -Name LASTEXITCODE -Scope Global -Value $script:InitialNativeExitCode
    } else {
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    }
}
