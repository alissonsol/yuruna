<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42bab3ac-38fb-4688-a3a4-990903db1a23
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Yuruna.SeedMedia.psm1') -Force
    $script:Parent = Join-Path $TestDrive vm
    $null = New-Item -ItemType Directory -Path $script:Parent
}

Describe 'Seed media secrets remain protected throughout construction' {
    It 'creates distinct empty staging directories without reusing prior builds' {
        $first = New-SeedMediaWorkspace $script:Parent
        $second = New-SeedMediaWorkspace $script:Parent
        try {
            $first.Root | Should -Not -Be $second.Root
            @(Get-ChildItem $first.Source).Count | Should -Be 0
            (Split-Path -Parent $first.Root) | Should -Be $script:Parent
        } finally {
            Remove-SeedMediaWorkspace $first -Confirm:$false
            Remove-SeedMediaWorkspace $second -Confirm:$false
        }
    }

    It 'refuses a colliding staging name without reusing its contents' {
        $collision = Join-Path $script:Parent ('.yuruna-seed-' + ('a' * 32))
        $null = New-Item -ItemType Directory -Path $collision
        [IO.File]::WriteAllText((Join-Path $collision sentinel), 'existing')
        InModuleScope Yuruna.SeedMedia -Parameters @{ Parent = $script:Parent; Collision = $collision } {
            param($Parent, $Collision)
            $script:CollisionParent = $Parent
            $script:CollisionPath = $Collision
            Mock Join-Path { $script:CollisionPath } -ParameterFilter { $ChildPath -like '.yuruna-seed-*' }
            { New-SeedMediaWorkspace $script:CollisionParent } | Should -Throw '*already exists*'
        }
        [IO.File]::ReadAllText((Join-Path $collision sentinel)) | Should -Be 'existing'
    }

    It 'cleans plaintext and an incomplete image after a generator failure' {
        $workspace = New-SeedMediaWorkspace $script:Parent
        $oldImage = Join-Path $script:Parent seed.iso
        [IO.File]::WriteAllText($oldImage, 'previous image')
        try {
            try {
                [IO.File]::WriteAllText((Join-Path $workspace.Source user-data), 'sentinel-secret')
                [IO.File]::WriteAllText($workspace.Image, 'partial-secret-image')
                throw 'generator failed'
            } finally { Remove-SeedMediaWorkspace $workspace -Confirm:$false }
        } catch { $_.Exception.Message | Should -Be 'generator failed' }
        Test-Path $workspace.Root | Should -BeFalse
        [IO.File]::ReadAllText($oldImage) | Should -Be 'previous image'
    }

    It 'publishes complete protected bytes and removes the temporary source' {
        $workspace = New-SeedMediaWorkspace $script:Parent
        $image = Join-Path $script:Parent seed.iso
        try {
            [IO.File]::WriteAllText($workspace.Image, 'complete image')
            Publish-SeedMediaImage $workspace $image -Confirm:$false
            [IO.File]::ReadAllText($image) | Should -Be 'complete image'
            Test-Path $workspace.Image | Should -BeFalse
        } finally { Remove-SeedMediaWorkspace $workspace -Confirm:$false }
        Test-Path $workspace.Root | Should -BeFalse
    }

    It 'refuses publication outside the staging filesystem directory' {
        $workspace = New-SeedMediaWorkspace $script:Parent
        try {
            [IO.File]::WriteAllText($workspace.Image, 'secret')
            { Publish-SeedMediaImage $workspace (Join-Path $TestDrive outside.iso) -Confirm:$false } |
                Should -Throw '*staging filesystem*'
            Test-Path (Join-Path $TestDrive outside.iso) | Should -BeFalse
        } finally { Remove-SeedMediaWorkspace $workspace -Confirm:$false }
    }

    It 'refuses to clean an unrelated directory described as a workspace' {
        { Remove-SeedMediaWorkspace @{ Root = $script:Parent; Parent = $TestDrive } -Confirm:$false } |
            Should -Throw '*unrecognized*'
        Test-Path $script:Parent | Should -BeTrue
    }

    # Every builder that renders seed media writes it through the protected
    # workspace: the test-guest seeds carry a password hash, a plaintext password
    # or a repository token just as the service seeds carry the admin password, so
    # a builder that staged them anywhere else would leave them readable, and
    # behind, after a failed build.
    It 'wires protected staging and finally cleanup into every builder that renders seed media' {
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $builders = @(Get-ChildItem -Path (Join-Path $root 'host') -Recurse -File -Include 'New-VM.ps1', 'New-UbuntuServerVM.ps1' |
                Where-Object { [IO.File]::ReadAllText($_.FullName) -match '(?m)^\s*(&\s*genisoimage|&\s*hdiutil makehybrid|CreateIso -SourceDir)' })
        $builders.Count | Should -BeGreaterOrEqual 21 -Because 'twelve service builders and nine test-guest builders render seed media'
        foreach ($builder in $builders) {
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($builder.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $builder.FullName
            $protected = @($ast.FindAll({ param($node)
                        $node -is [Management.Automation.Language.TryStatementAst] -and
                        $node.Body.Extent.Text -match '\$seedWorkspace = New-SeedMediaWorkspace' -and
                        $node.Finally.Extent.Text -match 'Remove-SeedMediaWorkspace -Workspace \$seedWorkspace'
                    }, $true))
            $protected.Count | Should -Be 1 -Because "$($builder.FullName) stages its seed in one protected workspace"
            $body = $protected[0].Body.Extent.Text
            $body | Should -Match 'Publish-SeedMediaImage -Workspace \$seedWorkspace' -Because $builder.FullName
            $generators = @([regex]::Matches([IO.File]::ReadAllText($builder.FullName), '(?m)^\s*(&\s*genisoimage|&\s*hdiutil makehybrid|CreateIso -SourceDir)[^\r\n]*'))
            $insideBody = @([regex]::Matches($body, '(?m)^\s*(&\s*genisoimage|&\s*hdiutil makehybrid|CreateIso -SourceDir)[^\r\n]*'))
            $insideBody.Count | Should -Be $generators.Count -Because "$($builder.FullName) renders seed media only inside the protected try"
            foreach ($call in $insideBody) {
                $call.Value | Should -Match '(\$\()?\$seedWorkspace\.Image\b' -Because "$($builder.FullName) writes the image into the workspace: $($call.Value.Trim())"
            }
            if ($builder.FullName -match 'windows\.hyper-v') {
                $body | Should -Match 'Grant-SeedMediaVmRead -Path \$SeedIso' -Because "$($builder.FullName) lets the new VM read its protected image"
            }
        }
    }
}

if (-not $IsWindows) {
    Describe 'Unix seed filesystem boundaries' {
        It 'sets private staging before writing and private ISO mode before publication' {
            $workspace = New-SeedMediaWorkspace $script:Parent
            $parentMode = [IO.File]::GetUnixFileMode($script:Parent)
            try {
                [int][IO.File]::GetUnixFileMode($workspace.Root) | Should -Be 448
                [IO.File]::WriteAllText($workspace.Image, 'secret')
                $image = Join-Path $script:Parent protected.iso
                Publish-SeedMediaImage $workspace $image -Confirm:$false
                [int][IO.File]::GetUnixFileMode($image) | Should -Be 384
                [IO.File]::GetUnixFileMode($script:Parent) | Should -Be $parentMode
            } finally { Remove-SeedMediaWorkspace $workspace -Confirm:$false }
        }

        It 'refuses symlink parents and destinations without changing their targets' {
            $link = Join-Path $TestDrive linked-parent
            $null = New-Item -ItemType SymbolicLink -Path $link -Target $script:Parent
            { New-SeedMediaWorkspace $link } | Should -Throw '*real directory*'
            $workspace = New-SeedMediaWorkspace $script:Parent
            try {
                $target = Join-Path $TestDrive unrelated
                [IO.File]::WriteAllText($target, 'unrelated')
                $destination = Join-Path $script:Parent linked.iso
                $null = New-Item -ItemType SymbolicLink -Path $destination -Target $target
                [IO.File]::WriteAllText($workspace.Image, 'secret')
                { Publish-SeedMediaImage $workspace $destination -Confirm:$false } | Should -Throw '*symbolic link*'
                [IO.File]::ReadAllText($target) | Should -Be 'unrelated'
            } finally { Remove-SeedMediaWorkspace $workspace -Confirm:$false }
        }
    }
} else {
    Describe 'Windows seed ACL boundaries' {
        It 'protects staging at creation and grants no ordinary-user inherited access' {
            $workspace = New-SeedMediaWorkspace $script:Parent
            try {
                $acl = Get-Acl -LiteralPath $workspace.Root
                $acl.AreAccessRulesProtected | Should -BeTrue
                $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
                foreach ($rule in $acl.Access) {
                    $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value | Should -BeIn $allowed
                }
            } finally { Remove-SeedMediaWorkspace $workspace -Confirm:$false }
        }

        It 'retains an explicit protected ISO ACL after atomic publication' {
            $workspace = New-SeedMediaWorkspace $script:Parent
            try {
                [IO.File]::WriteAllText($workspace.Image, 'secret')
                $image = Join-Path $script:Parent protected.iso
                Publish-SeedMediaImage $workspace $image -Confirm:$false
                (Get-Acl -LiteralPath $image).AreAccessRulesProtected | Should -BeTrue
                @((Get-Acl -LiteralPath $image).Access | Where-Object IsInherited).Count | Should -Be 0
            } finally { Remove-SeedMediaWorkspace $workspace -Confirm:$false }
        }
    }
}
