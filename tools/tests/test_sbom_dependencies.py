#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Verify offline dependency identity, graph and checksum evidence collection."""
import base64
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sbom_dependencies import collect_dependencies, component_key


# --- REGION: Manifest fixtures
def collect(files):
    records = collect_dependencies({path: text.encode('utf-8') for path, text in files.items()}, 'fixture')
    return {component_key(record): record for record in records}


def npm_lock(packages):
    return json.dumps({'lockfileVersion': 3, 'packages': packages}, indent=2)


# --- REGION: Repository dependency regressions
class DependencyTests(unittest.TestCase):
    def test_go_replacement_precedence_and_sum_selection(self):
        digest = base64.b64encode(bytes(range(32))).decode()
        records = collect({
            'go.mod': 'module fixture\nrequire original v1.2.0\nreplace original => unused v2.0.0\n'
                      'replace original v1.2.0 => effective v3.0.0\n',
            'go.sum': f'effective v3.0.0 h1:{digest}\neffective v3.0.0/go.mod h1:{digest}\n'
                      f'old v0.1.0 h1:{digest}\n',
        })
        self.assertEqual(records['go:fixture']['dependencies'], ['go:effective@v3.0.0'])
        self.assertNotIn('go:unused@v2.0.0', records)
        self.assertEqual(records['go:effective@v3.0.0']['hashes'],
                         [{'alg': 'SHA256', 'content': bytes(range(32)).hex()}])
        self.assertEqual(records['go:old@v0.1.0']['completeness'], 'unresolved')
        self.assertTrue(any('not an archive' in note for note in records['go:effective@v3.0.0']['notes']))

    def test_local_go_replacement_does_not_invent_version_or_checksum(self):
        records = collect({'service/server/go.mod': 'module fixture\nrequire sdk v0.0.0\nreplace sdk => ../sdk\n'})
        dependency = records['go:sdk']
        self.assertNotIn('version', dependency)
        self.assertEqual(dependency['hashes'], [])
        self.assertTrue(any('not present' in note for note in dependency['notes']))

    def test_cargo_qualified_versions_and_internal_edges(self):
        records = collect({
            'Cargo.toml': '[package]\nname="app"\nversion="0.1.0"\n[dependencies]\nwasi="0.14"\n',
            'Cargo.lock': 'version=4\n[[package]]\nname="app"\nversion="0.1.0"\n'
                          'dependencies=["wasi 0.14.7+wasi-0.2.4"]\n'
                          '[[package]]\nname="wasi"\nversion="0.11.1+wasi-snapshot-preview1"\n'
                          '[[package]]\nname="wasi"\nversion="0.14.7+wasi-0.2.4"\n'
                          'checksum="' + 'ab' * 32 + '"\n',
        })
        self.assertEqual(records['cargo:app@0.1.0']['dependencies'], ['cargo:wasi@0.14.7+wasi-0.2.4'])
        self.assertEqual(records['cargo:app@0.1.0']['kind'], 'application')
        self.assertNotIn('cargo:wasi', records)
        self.assertEqual(records['cargo:wasi@0.14.7+wasi-0.2.4']['hashes'][0]['content'], 'ab' * 32)

    def test_npm_alias_nested_dependency_and_missing_peer(self):
        records = collect({
            'package.json': json.dumps({'name': 'app', 'version': '1.0.0', 'dependencies': {'compat': 'npm:real@1.0.0', 'a': '1.0.0'}}),
            'package-lock.json': npm_lock({
                '': {'name': 'app', 'version': '1.0.0'},
                'node_modules/compat': {'name': 'real', 'version': '1.0.0'},
                'node_modules/a': {'version': '1.0.0', 'dependencies': {'dep': '^1'},
                                   'peerDependencies': {'missing-peer': '^2'}},
                'node_modules/a/node_modules/dep': {'version': '1.2.0'},
                'node_modules/dep': {'version': '2.0.0'},
            }),
        })
        self.assertIn('npm:real@1.0.0', records['npm:app@1.0.0']['dependencies'])
        self.assertEqual(records['npm:a@1.0.0']['dependencies'], ['npm:dep@1.2.0'])
        self.assertFalse(any('missing-peer' in key for key in records))
        self.assertTrue(any('missing-peer' in note for note in records['npm:a@1.0.0']['notes']))

    def test_integrity_validates_algorithm_and_digest_length(self):
        sha256 = base64.b64encode(b'\x01' * 32).decode()
        sha512 = base64.b64encode(b'\x02' * 64).decode()
        records = collect({'package-lock.json': npm_lock({
            '': {'name': 'app', 'version': '1.0.0'},
            'node_modules/dep': {'version': '1.0.0', 'integrity': f'sha256-{sha256} sha512-{sha512} sha512-YQ== sha256-!'},
        })})
        self.assertEqual(records['npm:dep@1.0.0']['hashes'], [
            {'alg': 'SHA256', 'content': '01' * 32}, {'alg': 'SHA512', 'content': '02' * 64}])

    def test_unlocked_ranges_do_not_become_versions_or_purls(self):
        records = collect({'package.json': json.dumps({'name': 'app', 'dependencies': {'dep': '^1.2.0'}})})
        self.assertNotIn('version', records['npm:dep'])
        self.assertNotIn('purl', records['npm:dep'])
        self.assertEqual(records['npm:dep']['versionConstraint'], '^1.2.0')
        self.assertEqual(records['npm:dep']['completeness'], 'unresolved')

    def test_nuget_central_version_and_libman_provider(self):
        records = collect({
            'Directory.Packages.props': '<Project><ItemGroup><PackageVersion Include="Npgsql" Version="10.0.3" /></ItemGroup></Project>',
            'app/app.csproj': '<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>'
                             '<ItemGroup><PackageReference Include="Npgsql" /><FrameworkReference Include="Microsoft.AspNetCore.App" /></ItemGroup></Project>',
            'app/libman.json': json.dumps({'defaultProvider': 'cdnjs', 'libraries': [{'library': 'twitter-bootstrap@5.3.8'}]}),
        })
        self.assertIn('nuget:Npgsql@10.0.3', records['dotnet:app']['dependencies'])
        self.assertEqual(len(records['nuget:Npgsql@10.0.3']['evidence']), 2)
        self.assertNotIn('version', records['dotnet:Microsoft.AspNetCore.App'])
        self.assertIn('cdnjs:twitter-bootstrap@5.3.8', records)

    def test_docker_arg_defaults_stage_references_and_floating_tag(self):
        records = collect({'Dockerfile': 'ARG REGISTRY=mcr.microsoft.com/\nFROM ${REGISTRY}dotnet/sdk:10.0 AS build\n'
                            'FROM build AS publish\nFROM debian:bookworm-slim\n'})
        self.assertEqual(len(records), 2)
        image = records['docker:mcr.microsoft.com/dotnet/sdk']
        self.assertEqual(image['scope'], 'build')
        self.assertEqual(image['versionConstraint'], '10.0')
        self.assertNotIn('version', image)
        self.assertIn('docker:debian', records)

    def test_flutter_bazel_and_python_constraints(self):
        records = collect({
            'pubspec.yaml': 'name: app\nversion: 0.1.0\ndependencies:\n  flutter:\n    sdk: flutter\n'
                            'dev_dependencies:\n  flutter_lints: ^4.0.0\n',
            'MODULE.bazel': 'bazel_dep(name="rules_rust", version="0.71.3")\nrust.toolchain(versions=["1.96.1"])',
            '.bazelversion': '7.7.1\n',
            'pyproject.toml': '[project]\nname="py-app"\nversion="1.0.0"\ndependencies=["my_pkg>=2", "other==1.2.3"]\n',
        })
        self.assertEqual(records['pub:flutter_lints']['scope'], 'test')
        self.assertEqual(records['pub:flutter_lints']['versionConstraint'], '^4.0.0')
        self.assertIn('toolchain:Rust@1.96.1', records)
        self.assertIn('bazel:rules_rust@0.71.3', records)
        self.assertIn('pypi:other@1.2.3', records)
        self.assertEqual(records['pypi:my-pkg']['versionConstraint'], '>=2')

    def test_hcl_nested_providers_engine_floor_and_module_constraints(self):
        records = collect({'global/resources/aws/versions.tf': '''terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.54"
      configuration_aliases = [aws.peer]
    }
    local = { source = "hashicorp/local", version = "= 2.9.1" }
  }
}
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"
  addons = { inner = { version = "99.0.0" } }
}
'''})
        provider = records['terraform-provider:hashicorp/aws']
        self.assertEqual(provider['versionConstraint'], '~> 6.54')
        self.assertNotIn('version', provider)
        self.assertNotIn('purl', provider)
        self.assertEqual(provider['evidence'][0]['line'], 4)
        self.assertIn('terraform-provider:hashicorp/local@2.9.1', records)
        module = records['terraform-module:terraform-aws-modules/eks/aws']
        self.assertEqual(module['versionConstraint'], '~> 21.24')
        self.assertEqual(module['evidence'][0]['line'], 12)
        self.assertEqual(records['toolchain:OpenTofu/Terraform']['versionConstraint'], '>= 1.13.0')
        self.assertEqual(len(records['opentofu-config:global/resources/aws']['dependencies']), 4)

    def test_hcl_comment_and_heredoc_examples_are_not_dependencies(self):
        records = collect({'main.tf': '''# module "fake" { source = "fake/comment/aws" }
/* terraform { required_providers { fake = { source = "fake/block" } } } */
locals {
  sample = <<-HCL
module "fake" { source = "fake/heredoc/aws" }
HCL
  quoted = "terraform { required_version = \\\"99.0.0\\\" }"
}
module "real" {
  source = "git::https://example.test/modules.git//nested?ref=v1.2.3" // literal URL
}
'''})
        self.assertEqual(set(records), {'opentofu-config:.',
                         'terraform-module:git::https://example.test/modules.git//nested?ref=v1.2.3'})
        record = records['terraform-module:git::https://example.test/modules.git//nested?ref=v1.2.3']
        self.assertNotIn('version', record)
        self.assertEqual(record['evidence'][0]['line'], 9)

    def test_hcl_exact_registry_versions_and_local_modules_remain_distinct(self):
        records = collect({'global/cluster/main.tf': '''module "remote" {
 source = "registry.example.test/team/cluster/aws"
 version = "2.3.4"
}
module "local" { source = "../shared" }
'''})
        self.assertIn('terraform-module:registry.example.test/team/cluster/aws@2.3.4', records)
        local = records['terraform-module:global/shared']
        self.assertNotIn('version', local)
        self.assertTrue(any('Local configuration' in note for note in local['notes']))

    def test_hcl_dynamic_and_implicit_sources_do_not_invent_registry_addresses(self):
        records = collect({'main.tf': '''terraform {
 required_providers {
  old = "~> 1.0"
  selected = { source = "${var.registry}/team/pkg", version = "~> 2.0" }
 }
}
module "dynamic" { source = local.module_source }
'''})
        self.assertEqual(records['terraform-provider:old']['versionConstraint'], '~> 1.0')
        self.assertIn('terraform-provider:selected', records)
        self.assertIn('terraform-module:.:dynamic', records)
        self.assertFalse(any('hashicorp' in key or '${' in key for key in records))
        self.assertEqual(records['terraform-module:.:dynamic']['completeness'], 'unresolved')

    def test_hcl_test_fixtures_and_downloaded_modules_are_excluded(self):
        snippet = 'terraform { required_version = "99.0.0" }'
        records = collect({path: snippet for path in (
            'global/tests/fixtures/main.tf', 'global/test/main.tf', 'testdata/main.tf',
            '.terraform/modules/download/main.tf', 'vendor/main.tf', 'docs/main.tf')})
        self.assertEqual(records, {})

    def test_hcl_combines_provider_constraints_without_discarding_evidence(self):
        records = collect({
            'one/main.tf': 'terraform { required_providers { aws = { source="hashicorp/aws" version="~> 6.54" } } }',
            'two/main.tf': 'terraform { required_providers { alias = { source="hashicorp/aws" version=">= 6.60, < 7.0" } } }',
        })
        provider = records['terraform-provider:hashicorp/aws']
        self.assertEqual(provider['versionConstraints'], ['>= 6.60, < 7.0', '~> 6.54'])
        self.assertNotIn('versionConstraint', provider)
        self.assertEqual(len(provider['evidence']), 2)

    def test_hcl_unterminated_blocks_and_heredocs_fail_closed(self):
        for text in ('terraform { required_version="1.13.0"', 'locals { sample = <<EOF\nmissing',
                     '/* terraform { required_version="99.0.0" }'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                collect({'main.tf': text})

    def test_hcl_windows_paths_and_crlf_preserve_source_lines(self):
        records = collect({'global\\resources\\main.tf': '# declaration\r\nterraform {\r\n'
                           '  required_version = ">= 1.13.0"\r\n}\r\n'})
        record = records['toolchain:OpenTofu/Terraform']
        self.assertEqual(record['evidence'][0]['path'], 'global/resources/main.tf')
        self.assertEqual(record['evidence'][0]['line'], 3)

    def test_helm_folded_workload_actions_keep_repository_and_chart_evidence(self):
        path = 'example/website/config/localhost/workloads.yml'
        records = collect({path: '''workloads:
- context: "${env:context}"
  deployments:
    - helm: "repo add ingress-nginx https://kubernetes.github.io/ingress-nginx"
    - helm: "repo update"
    - helm: >
        install nginx-ingress ingress-nginx/ingress-nginx
        --namespace ingress-ns
        --create-namespace
        --set controller.ingressClass=${env:ingressClass}
'''})
        key = 'helm:https://kubernetes.github.io/ingress-nginx#ingress-nginx'
        chart = records[key]
        self.assertEqual({entry['line'] for entry in chart['evidence']}, {4, 6})
        self.assertEqual(chart['completeness'], 'unresolved')
        self.assertNotIn('version', chart)
        self.assertNotIn('purl', chart)
        self.assertEqual(records['helm-config:' + path]['dependencies'], [key])

    def test_helm_exact_range_and_dynamic_versions_remain_distinct(self):
        records = collect({'example/config/azure/workloads.yml': '''globalVariables:
  certManagerLatest: "v1.21.2"
workloads:
  - helm: 'repo add jetstack https://charts.jetstack.io'
  - helm: >-
      install cert-manager jetstack/cert-manager --version ${env:certManagerLatest}
  - helm: 'upgrade --install --namespace services release jetstack/operator --version="1.2.3"'
  - helm: 'upgrade release jetstack/operator --version ">=1.2.0 <2.0.0"'
'''})
        dynamic = records['helm:https://charts.jetstack.io#cert-manager']
        self.assertEqual(dynamic['versionConstraint'], '${env:certManagerLatest}')
        self.assertNotIn('version', dynamic)
        self.assertTrue(any('no runtime value' in note for note in dynamic['notes']))
        self.assertIn('helm:https://charts.jetstack.io#operator@1.2.3', records)
        self.assertEqual(records['helm:https://charts.jetstack.io#operator']['versionConstraint'], '>=1.2.0 <2.0.0')

    def test_helm_direct_repo_oci_and_archive_references_are_not_resolved(self):
        records = collect({'config/aws/workloads.yaml': '''workloads:
  - helm: install release operator --repo https://charts.example.test/ --version v2.3.4
  - helm: 'install --generate-name=true oci://registry.example.test/team/chart --version 3.4.5'
  - helm: 'upgrade release https://charts.example.test/chart-4.5.6.tgz'
'''})
        self.assertIn('helm:https://charts.example.test#operator@v2.3.4', records)
        self.assertIn('helm:oci://registry.example.test/team/chart@3.4.5', records)
        archive = records['helm:https://charts.example.test/chart-4.5.6.tgz']
        self.assertNotIn('version', archive)
        self.assertTrue(any('not resolved' in note for note in archive['notes']))

    def test_helm_alias_identity_is_scoped_by_file_and_repository_url(self):
        records = collect({
            'one/config/local/workloads.yml': '''- helm: repo add charts https://one.example.test
- helm: repo add charts https://one.example.test/
- helm: install release charts/operator
''',
            'two/config/local/workloads.yml': '''- helm: repo add charts https://two.example.test
- helm: install release charts/operator
''',
        })
        charts = {key for key in records if key.startswith('helm:')}
        self.assertEqual(charts, {'helm:https://one.example.test#operator', 'helm:https://two.example.test#operator'})

    def test_helm_local_dynamic_and_ambiguous_sources_have_no_fabricated_chart(self):
        records = collect({'config/local/workloads.yml': '''- helm: repo add charts https://one.example.test
- helm: repo add charts https://two.example.test
- helm: install release charts/operator
- helm: install release ./local-chart
- helm: install release ../local-chart
- helm: install release workloads/frontend
- helm: install release ${env:chart}
- helm: repo add runtime ${env:repository}
- helm: install release runtime/chart
'''})
        self.assertFalse(any(key.startswith('helm:') for key in records))
        notes = records['helm-config:config/local/workloads.yml']['notes']
        self.assertEqual(len(notes), 4)
        self.assertTrue(any('line 3:' in note and 'ambiguous' in note for note in notes))

    def test_helm_comments_other_scalar_bodies_and_fixtures_are_excluded(self):
        text = '''# - helm: install fake https://example.test/fake.tgz
- shell: |
    helm: install printed https://example.test/printed.tgz
- helm: "repo add actual https://charts.example.test" # literal declaration
- helm: >
    install release actual/chart
    # --debug
'''
        records = collect({'config/local/workloads.yml': text,
                           'tests/config/local/workloads.yml': '- helm: install fake https://fake.test/a.tgz',
                           'docs/config/local/workloads.yml': '- helm: install fake https://fake.test/b.tgz'})
        self.assertEqual({key for key in records if key.startswith('helm:')}, {'helm:https://charts.example.test#chart'})

    def test_helm_unknown_option_arity_and_shell_chains_fail_closed(self):
        records = collect({'config/local/workloads.yml': '''- helm: "install bad https://example.test/chart.tgz --future-option value"
- helm: "install bad https://example.test/chart.tgz; echo done"
- helm: *reused_action
- helm: "unterminated
'''})
        self.assertEqual(set(records), {'helm-config:config/local/workloads.yml'})
        self.assertEqual(len(records['helm-config:config/local/workloads.yml']['notes']), 4)

    def test_helm_repository_removal_and_partial_versions_stay_unresolved(self):
        records = collect({'config/local/workloads.yml': '''- helm: repo add charts https://example.test
- helm: install release charts/chart --version 1.2
- helm: repo remove charts
- helm: install release charts/absent
'''})
        self.assertEqual(records['helm:https://example.test#chart']['versionConstraint'], '1.2')
        self.assertNotIn('version', records['helm:https://example.test#chart'])
        self.assertNotIn('helm:https://example.test#absent', records)

    def test_helm_folded_comment_does_not_create_a_version_from_trailing_text(self):
        records = collect({'config/local/workloads.yml': '''- helm: repo add charts https://example.test
- helm: >
    install release charts/chart
    # disabled argument
    --version 9.9.9
'''})
        chart = records['helm:https://example.test#chart']
        self.assertNotIn('version', chart)
        self.assertNotIn('versionConstraint', chart)

    def test_determinism_and_source_exclusions(self):
        files = {'package.json': json.dumps({'name': 'app', 'dependencies': {'x': '1.2.3'}}),
                 'docs/sbom/repository.spdx.json': '{not parsed}', 'tools/sbom-policy.json': '{not parsed}'}
        first = collect(files)
        second = collect(dict(reversed(list(files.items()))))
        self.assertEqual(first, second)
        self.assertEqual(len(first), 2)
        for record in first.values():
            self.assertTrue(all(item['line'] >= 1 for item in record['evidence']))


if __name__ == '__main__':
    unittest.main()
