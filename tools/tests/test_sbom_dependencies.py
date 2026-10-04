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
