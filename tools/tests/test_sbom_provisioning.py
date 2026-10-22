"""Source-only provisioning inventory regressions.

LICENSEURI https://yuruna.link/license
Copyright (c) 2019-2026 by Alisson Sol et al.
"""

import importlib.util
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "sbom_provisioning.py"
SPEC = importlib.util.spec_from_file_location("sbom_provisioning", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


# --- REGION: Provisioning inventories
class ProvisioningTests(unittest.TestCase):
    def collect(self, **files):
        return MODULE.collect_provisioning({p: t.encode("utf-8") for p, t in files.items()}, "example")

    @staticmethod
    def names(result, bucket):
        return {record["name"] for record in result[bucket]}

    def test_a_long_script_scans_in_linear_time(self):
        # Whether a file is a cloud-config is decided once per file. Testing the
        # whole text on every logical line made the 5,600-line caching-proxy
        # seed alone cost most of a half-minute pre-commit SBOM refresh.
        body = "".join("echo line %d\n" % number for number in range(30000))
        started = time.monotonic()
        result = self.collect(**{"automation/long.sh": body, "host/vmconfig/long.base.user-data": "#cloud-config\n" + body})
        self.assertLess(time.monotonic() - started, 20)
        self.assertIn("hosts", result)

    def test_host_requirements_preserve_decorated_floors_without_install_claims(self):
        result = self.collect(**{"automation/Yuruna.Requirement.yml": '''requirements:
  - tool: "PowerShell"
    version: "7.6.4 (Core)"
  - tool: "Kubernetes"
    version: "v1.36.3"
  - tool: "curl"
    version: "curl 8.18.0" # Ubuntu package floor
''', "install/ubuntu.kvm.sh": "apt-get install curl\n"})
        floors = {row["name"]: row for row in result["hosts"] if row["ecosystem"] == "generic"}
        self.assertEqual({name: row["versionConstraint"] for name, row in floors.items()},
                         {"PowerShell": ">=7.6.4", "Kubernetes": ">=1.36.3", "curl": ">=8.18.0"})
        self.assertTrue(all("version" not in row for row in result["hosts"]))
        self.assertEqual(floors["curl"]["evidence"][0]["line"], 7)
        self.assertFalse(result["guests"])

    def test_guest_manifest_separates_exact_pins_and_release_channels(self):
        result = self.collect(**{"automation/yuruna-versions.sh": '''export YURUNA_K8S_MINOR=1.37
export YURUNA_OPENTOFU_VERSION=1.13.1
export YURUNA_HELM_VERSION=4.3.0
export YURUNA_NVM_VERSION=0.40.8
export YURUNA_NODE_MAJOR=24
''', "guest/shared/install.sh": 'nvm install "$YURUNA_NODE_MAJOR"\n'})
        rows = {row["name"]: row for row in result["guests"]}
        self.assertEqual(set(rows), {"Kubernetes", "OpenTofu", "Helm", "nvm-sh/nvm", "node"})
        for name, version in (("OpenTofu", "1.13.1"), ("Helm", "4.3.0"), ("nvm-sh/nvm", "0.40.8")):
            self.assertEqual(rows[name]["version"], version)
        for name, channel in (("Kubernetes", "1.37"), ("node", "24")):
            self.assertNotIn("version", rows[name])
            self.assertEqual(rows[name]["versionConstraint"], channel)
        self.assertFalse(result["hosts"])

    def test_host_requirements_accept_bare_yaml_scalars(self):
        result = self.collect(**{"automation/Yuruna.Requirement.yml": '''requirements:
  - tool: curl
    version: curl 8.18.0 # distribution floor
  - tool: Helm
    version: 'v4.3.0'
'''})
        rows = {row["name"]: row for row in result["hosts"]}
        self.assertEqual(rows["curl"]["versionConstraint"], ">=8.18.0")
        self.assertEqual(rows["Helm"]["versionConstraint"], ">=4.3.0")
        self.assertTrue(all("version" not in row for row in rows.values()))

    def test_manifests_report_unresolved_versions_and_ignore_comment_examples(self):
        result = self.collect(**{"automation/yuruna-versions.sh": '''# export YURUNA_HELM_VERSION=99.0.0
export YURUNA_OPENTOFU_VERSION=$SELECTED_VERSION
export YURUNA_NODE_MAJOR=24
''', "automation/Yuruna.Requirement.yml": '''requirements:
  - tool: "Example"
    version: "dynamic"
'''})
        self.assertEqual(self.names(result, "guests"), {"node"})
        self.assertFalse(result["hosts"])
        self.assertEqual(len(result["coverage"]), 2)
        self.assertTrue(all(row["status"] == "unresolved" for row in result["coverage"]))

    def test_only_canonical_manifests_declare_requirement_floors(self):
        result = self.collect(**{"example/Yuruna.Requirement.yml": 'tool: "Example"\nversion: "9.0.0"\n',
                                 "docs/yuruna-versions.sh": "export YURUNA_HELM_VERSION=99.0.0\n"})
        self.assertFalse(result["hosts"])
        self.assertFalse(result["guests"])

    def test_hosts_guests_package_arrays_and_conditional_architectures(self):
        result = self.collect(**{
            "install/ubuntu.kvm.sh": """# apt-get install fake-comment
PKGS=(qemu-utils libvirt-clients)
PKGS+=(ovmf)
sudo apt-get install -y --no-install-recommends "${PKGS[@]}" curl \\
  git
""",
            "guest/amazon.linux.2023/update.sh": "sudo dnf -y install postgresql17-server libicu\n",
        })
        self.assertEqual(self.names(result, "hosts"), {"qemu-utils", "libvirt-clients", "ovmf", "curl", "git"})
        self.assertEqual(self.names(result, "guests"), {"postgresql17-server", "libicu"})
        self.assertTrue(all("version" not in row for row in result["hosts"]))
        self.assertIn("target=ubuntu-kvm", result["hosts"][0]["evidence"][0]["detail"])

    def test_cloud_init_packages_and_guest_agent_overlay(self):
        result = self.collect(**{
            "host/vmconfig/stash-service.base.user-data": """packages:
  - curl
  - [git, '1:2.43.0-1ubuntu7']
write_files:
  - path: /usr/local/bin/setup
    content: |
      apt-get install -y libcap2-bin
""",
            "host/vmconfig/ubuntu.server.kvm.overlay.yml": "late-commands:\n  - curtin in-target --target=/target -- apt-get install -y qemu-guest-agent\n",
        })
        self.assertEqual(self.names(result, "guests"), {"curl", "git", "libcap2-bin", "qemu-guest-agent"})
        git = next(row for row in result["guests"] if row["name"] == "git")
        self.assertEqual(git["version"], "1:2.43.0-1ubuntu7")
        self.assertFalse(result["hosts"])

    def test_rejects_comment_help_catalog_and_test_fixture_commands(self):
        result = self.collect(**{
            "host/modules/Setup.ps1": """<#
Install-Module help-only
#>
# winget install --id fake.comment
Write-Warning 'Try Install-Module advice-only'
Install-Module -Name actual-module -Scope CurrentUser
""",
            "docs/readme.md": "apt-get install doc-only\n",
            "globalization/catalogs/en-US/host.json": '{"message":"brew install catalog-only"}',
            "host/modules/Yuruna.Image.Tests.ps1": "Install-Module test-fixture\n",
            "test/modules/Fixture.psm1": "npm install fake-test\n",
        })
        self.assertEqual(self.names(result, "hosts"), {"actual-module"})

    def test_printed_heredoc_is_not_an_executable_installer(self):
        result = self.collect(**{"install/linux.sh": """cat <<'HELP'
sudo apt-get install example-advice
HELP
cat > /usr/local/bin/guest-setup.sh <<'SCRIPT'
apt-get install real-installer
SCRIPT
"""})
        self.assertEqual(self.names(result, "hosts"), {"real-installer"})

    def test_quoted_text_here_strings_and_arithmetic_shifts_do_not_open_heredocs(self):
        for extension, text, install, name in (
            ("ps1", 'Write-Output "<<< Installation complete."', "Invoke-GuestWingetInstall -PackageId 'Git.Git'", "Git.Git"),
            ("ps1", 'Write-Output "<< NotAHereDoc"', "Invoke-GuestWingetInstall -PackageId 'Git.Git'", "Git.Git"),
            ("sh", "echo '<< NotAHereDoc'", "apt-get install curl", "curl"),
            ("sh", "cat <<< 'not-a-heredoc'", "apt-get install curl", "curl"),
            ("sh", "shifted=$((1 << SHIFT))", "apt-get install curl", "curl"),
            ("sh", "(( shifted = 1 << SHIFT ))", "apt-get install curl", "curl"),
        ):
            with self.subTest(text=text):
                result = self.collect(**{f"guest/shared/update.{extension}": f"{text}\n{install}\n"})
                self.assertEqual(self.names(result, "guests"), {name})
                self.assertFalse(result["coverage"])

    def test_executable_shell_heredoc_and_nested_guest_installers(self):
        result = self.collect(**{"poc/test/ubuntu.server.24/guest-tools.sh": """bash <<'SCRIPT'
apt-get install curl;
npm install -g n8n
SCRIPT
"""})
        self.assertEqual(self.names(result, "guests"), {"curl", "n8n"})
        self.assertFalse(result["hosts"])

    def test_brew_winget_helpers_and_psresource_versions(self):
        result = self.collect(**{
            "install/macos.utm.sh": "brew_ensure_formula qemu\nbrew_ensure_cask utm /Applications/UTM.app\n",
            "install/windows.hyper-v.ps1": "Install-WingetPackage -Id 'Git.Git' -FriendlyName 'Git'\nInstall-PSResource -Name Pester -Version 5.7.1\n",
        })
        self.assertEqual(self.names(result, "hosts"), {"qemu", "utm", "Git.Git", "Pester"})
        self.assertEqual(next(row for row in result["hosts"] if row["name"] == "Pester")["version"], "5.7.1")

    def test_guest_winget_helper_tracks_literal_package_ids_and_evidence(self):
        result = self.collect(**{
            "guest/windows.11/windows.11.code.ps1": "Invoke-GuestWingetInstall -PackageId 'Git.Git'\n",
            "guest/windows.11/windows.11.k8s.ps1": "Invoke-GuestWingetInstall -PackageId 'Git.Git'\nInvoke-GuestWingetInstall -PackageId 'Docker.DockerDesktop'\n",
            "guest/windows.11/windows.11.update.ps1": 'invoke-guestwingetinstall -packageid "Microsoft.PowerShell"\n',
        })
        self.assertEqual(self.names(result, "guests"), {"Git.Git", "Docker.DockerDesktop", "Microsoft.PowerShell"})
        self.assertTrue(all(row["ecosystem"] == "winget" for row in result["guests"]))
        git = next(row for row in result["guests"] if row["name"] == "Git.Git")
        self.assertEqual({item["path"] for item in git["evidence"]}, {
            "guest/windows.11/windows.11.code.ps1", "guest/windows.11/windows.11.k8s.ps1",
        })
        self.assertFalse(result["coverage"])

    def test_guest_winget_helper_diagnostic_and_quoted_advice_are_not_installations(self):
        result = self.collect(**{"guest/windows.11/update.ps1": '''# Invoke-GuestWingetInstall -PackageId 'Comment.Package'
Write-Warning "Try Invoke-GuestWingetInstall -PackageId 'Warning.Package'"
if ($failed) { Write-Error "Invoke-GuestWingetInstall -PackageId 'Error.Package' failed" }
$advice = "Invoke-GuestWingetInstall -PackageId 'String.Package'"
'Invoke-GuestWingetInstall -PackageId Quoted.Package'
Invoke-GuestWingetInstall -PackageId 'Actual.Package'
'''})
        self.assertEqual(self.names(result, "guests"), {"Actual.Package"})
        self.assertFalse(result["coverage"])

    def test_guest_winget_helper_declarations_are_not_installations(self):
        result = self.collect(**{"guest/windows.11/update.ps1": '''function Invoke-GuestWingetInstall {
}
function global:Invoke-GuestWingetInstall {
}
'''})
        self.assertFalse(result["guests"])
        self.assertFalse(result["coverage"])

    def test_guest_winget_helper_keeps_dynamic_package_coverage(self):
        result = self.collect(**{"guest/windows.11/update.ps1": "Invoke-GuestWingetInstall -PackageId $RequestedPackage\n"})
        self.assertFalse(result["guests"])
        self.assertTrue(any("unresolved package expression $RequestedPackage" in note["detail"] for note in result["coverage"]))
        self.assertTrue(all(note["status"] == "unresolved" and note["line"] == 1 for note in result["coverage"]))

    def test_guest_winget_helper_body_retains_unresolved_native_install_coverage(self):
        result = self.collect(**{"guest/windows.11/update.ps1": '''function Invoke-GuestWingetInstall {
    param([string]$PackageId)
    & winget install --id $PackageId --silent
}
Invoke-GuestWingetInstall -PackageId 'Microsoft.PowerShell'
'''})
        self.assertEqual(self.names(result, "guests"), {"Microsoft.PowerShell"})
        self.assertTrue(any("unresolved package expression $PackageId" in note["detail"] for note in result["coverage"]))
        self.assertTrue(all(note["line"] == 3 for note in result["coverage"]))

    def test_npm_pip_and_cargo_pins_are_not_floaters(self):
        result = self.collect(**{"guest/ubuntu.server.24/code.sh": """npm install -g @scope/tool@1.2.3 openclaw@latest
python3 -m pip install --index-url https://example.invalid/simple requests==2.32.3 flask>=3.0
cargo install ripgrep --version 14.1.1
"""})
        indexed = {row["name"]: row for row in result["guests"]}
        self.assertEqual(indexed["@scope/tool"]["version"], "1.2.3")
        self.assertEqual(indexed["requests"]["version"], "2.32.3")
        self.assertEqual(indexed["ripgrep"]["version"], "14.1.1")
        self.assertNotIn("version", indexed["openclaw"])
        self.assertEqual(indexed["openclaw"]["versionConstraint"], "latest")
        self.assertNotIn("version", indexed["flask"])

    def test_dynamic_packages_are_notes_not_fabricated_names(self):
        result = self.collect(**{"guest/amazon.linux.2023/code.sh": 'sudo dnf install -y "$CORRETTO_PKG" libicu\n'})
        self.assertEqual(self.names(result, "guests"), {"libicu"})
        self.assertTrue(any("CORRETTO_PKG" in note["detail"] for note in result["coverage"]))

    def test_common_release_pins_and_download_artifacts(self):
        result = self.collect(**{
            "automation/yuruna-versions.sh": "export YURUNA_NVM_VERSION=0.40.8\nexport YURUNA_NODE_MAJOR=24\n",
            "guest/shared/ubuntu.n8n.sh": 'wget_try -qO- "https://raw.githubusercontent.com/nvm-sh/nvm/v${YURUNA_NVM_VERSION}/install.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | bash\nnvm install "${YURUNA_NODE_MAJOR}"\nnpm install -g n8n\n',
        })
        indexed = {row["name"]: row for row in result["guests"]}
        self.assertEqual(indexed["nvm-sh/nvm"]["version"], "0.40.8")
        self.assertNotIn("version", indexed["node"])
        self.assertEqual(indexed["node"]["versionConstraint"], "24")

    def test_paired_homebrew_checksum_does_not_leak_to_other_downloads(self):
        digest = "a" * 64
        commit = "b" * 40
        result = self.collect(**{"install/macos.utm.sh": f"""  HOMEBREW_INSTALL_COMMIT='{commit}'
  HOMEBREW_INSTALL_SHA256='{digest}'
curl -fsSL "https://raw.githubusercontent.com/Homebrew/install/${{HOMEBREW_INSTALL_COMMIT}}/install.sh" -o /tmp/install.sh
curl -fsSL https://example.invalid/tool.tar.gz -o /tmp/tool.tar.gz
"""})
        indexed = {row["name"]: row for row in result["hosts"]}
        self.assertEqual(indexed["Homebrew/install"]["hashes"], [{"alg": "SHA-256", "content": digest}])
        self.assertEqual(indexed["tool.tar.gz"]["hashes"], [])

    def test_docker_base_stage_aliases_and_pinned_image_digest(self):
        digest = "1" * 64
        result = self.collect(**{"poc/components/service/Dockerfile": f"""ARG REGISTRY=mcr.microsoft.com/
FROM ${{REGISTRY}}dotnet/sdk:10.0 AS build
RUN dotnet tool install -g Microsoft.Web.LibraryManager.Cli
FROM build AS publish
FROM debian@sha256:{digest}
"""})
        self.assertEqual(self.names(result, "guests"), {"mcr.microsoft.com/dotnet/sdk", "debian", "Microsoft.Web.LibraryManager.Cli"})
        debian = next(row for row in result["guests"] if row["name"] == "debian")
        self.assertEqual(debian["hashes"], [{"alg": "SHA-256", "content": digest}])
        self.assertNotIn("version", debian)

    def test_repeated_evidence_is_deterministic_and_cache_probes_are_excluded(self):
        files = {"install/z.sh": b"apt-get install -y curl\n", "install/a.sh": b"apt-get install --simulate curl\napt-get install --download-only git\napt-get install curl\n"}
        first = MODULE.collect_provisioning(files, "example")
        second = MODULE.collect_provisioning(dict(reversed(list(files.items()))), "example")
        self.assertEqual(first, second)
        self.assertEqual(self.names(first, "hosts"), {"curl"})
        curl = next(row for row in first["hosts"] if row["name"] == "curl")
        self.assertEqual(len(curl["evidence"]), 2)

    def test_ps_command_body_is_installed_but_diagnostic_string_is_not(self):
        result = self.collect(**{"guest/windows.11/update.ps1": """$yamlInstall = "Install-Module -Name powershell-yaml -Scope AllUsers"
pwsh -Command $yamlInstall
Write-Warning 'Try: Install-Module diagnostic'
"""})
        self.assertEqual(self.names(result, "guests"), {"powershell-yaml"})

    def test_inline_and_multiline_operator_advice_never_becomes_software(self):
        result = self.collect(**{"install/windows.hyper-v.ps1": '''if ($failed) { Write-Die "winget install Microsoft.PowerShell exited. Re-run after fixing the source." }
Write-Die @"
winget install failed. Open a NEW console.
"@
winget install --id Microsoft.PowerShell --exact --source winget @scopeArg
'''})
        self.assertEqual(self.names(result, "hosts"), {"Microsoft.PowerShell"})

    def test_shell_package_filename_assignment_is_not_an_apt_package_table(self):
        result = self.collect(**{"guest/shared/update.sh": 'package="powershell-${version}-linux-${arch}.tar.gz"\napt-get install curl\n'})
        self.assertEqual(self.names(result, "guests"), {"curl"})

    def test_extensionless_pinned_release_and_rust_toolchain(self):
        result = self.collect(**{"poc/test/ubuntu.server.24/tools.sh": '''RUSTUP_VERSION=1.29.1
target=x86_64-unknown-linux-gnu
curl -fsSL "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${target}/rustup-init" -o /tmp/rustup-init
"/tmp/rustup-init" -y --default-toolchain 1.96.1
curl -fsSL https://github.com/bazelbuild/bazelisk/releases/download/v1.29.0/bazelisk-linux-amd64 -o /tmp/bazelisk
'''})
        indexed = {row["name"]: row for row in result["guests"]}
        self.assertEqual(indexed["rustup-init"]["version"], "1.29.1")
        self.assertEqual(indexed["rust"]["version"], "1.96.1")
        self.assertEqual(indexed["bazelbuild/bazelisk"]["version"], "1.29.0")

    def test_vm_image_target_is_guest_not_hypervisor_os(self):
        result = self.collect(**{"host/windows.hyper-v/guest.ubuntu.server.24/Get-Image.ps1": "Save-UbuntuServerImage -ReleaseCodename 'noble' -Arch $hostArch\n"})
        self.assertFalse(result["hosts"])
        self.assertIn("ubuntu-server-24", result["guests"][0]["group"])

    def test_quoted_cloud_init_commands_are_installed_inputs(self):
        result = self.collect(**{"host/vmconfig/service.hyperv.overlay.yml": '''runcmd:
  - 'apt-get install -y hyperv-daemons || echo "failed"'
  - "apt-get install -y curl"
'''})
        self.assertEqual(self.names(result, "guests"), {"hyperv-daemons", "curl"})

    def test_deployed_mock_service_is_not_a_test_fixture(self):
        result = self.collect(**{"poc/workloads/services/identity-mock/values.yaml": "image: localhost:5000/amisad/identity-mock:latest\n"})
        self.assertEqual(self.names(result, "guests"), {"localhost:5000/amisad/identity-mock"})

    def test_shipped_workload_helper_and_container_flags(self):
        result = self.collect(**{"tools/example-workload.sh": '''REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
docker pull --platform linux/amd64 "$REGISTRY_IMAGE"
docker run -d -p 5000:5000 --restart=always --name registry "$REGISTRY_IMAGE"
podman run --rm --mount type=bind,source=/tmp,target=/data -e LANG=C --label test=yes quay.io/example/tool:1.2 command ignored-argument
Write-Warning 'Try docker run --name advice false-image:latest'
'''})
        self.assertEqual(self.names(result, "guests"), {"registry", "quay.io/example/tool"})
        registry = next(row for row in result["guests"] if row["name"] == "registry")
        self.assertEqual(registry["versionConstraint"], "2")
        self.assertEqual(len(registry["evidence"]), 2)

    def test_installer_test_module_helper_is_host_provisioning(self):
        result = self.collect(**{
            "tools/Install-TestModule.ps1": '''Install-Module -Name Pester -RequiredVersion "$($newest.Version)" -Repository PSGallery -Scope CurrentUser `
    -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
Install-Module -Name PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
''',
            "tools/Invoke-TestSuite.ps1": "Install-Module -Name maintenance-only -Scope CurrentUser\n",
        })
        self.assertEqual(self.names(result, "hosts"), {"Pester", "PSScriptAnalyzer"})
        self.assertFalse(result["guests"])

    def test_dynamic_container_images_are_coverage_notes(self):
        result = self.collect(**{"guest/ubuntu.server.24/setup.sh": 'docker run --name dynamic "$IMAGE"\n'})
        self.assertFalse(result["guests"])
        self.assertTrue(any("unresolved image reference $IMAGE" in note["detail"] for note in result["coverage"]))


# --- REGION: SBOM
class SbomHookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shell = shutil.which("sh")
        if not cls.shell:
            installed = pathlib.Path("C:/Program Files/Git/bin/sh.exe")
            if installed.is_file():
                cls.shell = str(installed)
        if not cls.shell:
            raise unittest.SkipTest("A POSIX shell is required to exercise pre-commit integration.")
        cls.hook = MODULE_PATH.parent / "githooks" / "pre-commit"
        workspace = MODULE_PATH.parents[2]
        cls.hooks = {"yuruna": cls.hook}
        for name, root in (("yuruna-project", workspace / "yuruna-project"),
                           ("yuruna.link", workspace / "yuruna.link"),
                           ("amisad.dev", workspace / "alius-git" / "amisad.dev")):
            hook = root / "tools" / "githooks" / "pre-commit"
            if hook.is_file():
                cls.hooks[name] = hook

    def invoke_hook(self, *, generator=True, python=True, supported=True, updater_exit=0, ascii_gate=False, hook=None):
        with tempfile.TemporaryDirectory(prefix="yuruna-sbom-hook-") as temporary:
            base = pathlib.Path(temporary)
            root = base / "repository with spaces"
            scripts = base / "bin"
            scripts.mkdir()
            (root / "tools").mkdir(parents=True)
            log = base / "updater-arguments.txt"
            if generator:
                (root / "tools" / "Sync-Sbom.py").write_text("# Isolated fake updater.\n", encoding="utf-8")
            if ascii_gate:
                (root / "tools" / "Test-AsciiNoBom.ps1").write_text("# Isolated gate.\n", encoding="utf-8")
            fake_git = scripts / "git"
            fake_git.write_text(
                "#!/bin/sh\nif [ \"$1\" = rev-parse ]; then printf '%s\\n' "
                + shlex.quote(root.as_posix()) + "; fi\nexit 0\n", encoding="utf-8")
            fake_git.chmod(0o700)
            if python:
                for name in ("python3", "python"):
                    fake_python = scripts / name
                    fake_python.write_text(
                        "#!/bin/sh\nif [ \"$1\" = -c ]; then exit " + ("0" if supported else "1")
                        + "; fi\nprintf '%s\\n' \"$@\" > " + shlex.quote(log.as_posix())
                        + "\nexit " + str(updater_exit) + "\n", encoding="utf-8")
                    fake_python.chmod(0o700)
            shell_path = scripts.as_posix()
            if scripts.drive:
                shell_path = "/" + scripts.drive[0].lower() + shell_path[2:]
            environment = dict(os.environ, PATH=shell_path, YURUNA_FRAMEWORK_ROOT=(base / "absent-framework").as_posix())
            # Git for Windows prepends its own binaries at shell startup. Reset
            # PATH inside the shell so every process remains an isolated stub.
            result = subprocess.run(
                [self.shell, "-c", 'PATH=$1; export PATH; . "$2"', "sbom-hook-test", shell_path, (hook or self.hook).as_posix()],
                env=environment, capture_output=True, text=True)
            arguments = log.read_text(encoding="utf-8").splitlines() if log.is_file() else []
            return result, arguments, (root / "tools" / "Sync-Sbom.py").as_posix()

    def test_sbom_runs_when_ascii_gate_is_missing_and_preserves_path_spaces(self):
        result, arguments, generator = self.invoke_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(arguments, [generator, "--staged", "--stage"])

    def test_sbom_runs_when_powershell_is_missing(self):
        result, arguments, generator = self.invoke_hook(ascii_gate=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pwsh not found", result.stderr)
        self.assertEqual(arguments, [generator, "--staged", "--stage"])

    def test_missing_generator_blocks_commit(self):
        result, arguments, _ = self.invoke_hook(generator=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SBOM generator is missing", result.stderr)
        self.assertFalse(arguments)

    def test_missing_or_old_python_blocks_commit(self):
        for options in ({"python": False}, {"supported": False}):
            with self.subTest(**options):
                result, arguments, _ = self.invoke_hook(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Python 3.11 or newer is required", result.stderr)
                self.assertFalse(arguments)

    def test_updater_failure_blocks_commit(self):
        result, arguments, generator = self.invoke_hook(updater_exit=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SBOM refresh failed; the commit is blocked", result.stderr)
        self.assertEqual(arguments, [generator, "--staged", "--stage"])

    def test_workspace_hooks_share_fail_closed_sbom_execution(self):
        for name, hook in self.hooks.items():
            for options, message in (({}, None), ({"generator": False}, "SBOM generator is missing"),
                                     ({"python": False}, "Python 3.11 or newer is required"),
                                     ({"supported": False}, "Python 3.11 or newer is required"),
                                     ({"updater_exit": 2}, "SBOM refresh failed; the commit is blocked")):
                with self.subTest(repository=name, **options):
                    result, arguments, generator = self.invoke_hook(hook=hook, **options)
                    if message:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(message, result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(arguments, [generator, "--staged", "--stage"])


if __name__ == "__main__":
    unittest.main()
