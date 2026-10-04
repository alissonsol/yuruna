#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Collect repository dependency evidence without restoring or downloading packages."""
from __future__ import annotations

import base64
import json
import posixpath
import re
import tomllib
from urllib.parse import quote
import xml.etree.ElementTree as ET


# --- REGION: Component identity and evidence
def component_key(record: dict) -> str:
    """Identify a declared component without assigning an unknown version."""
    key = f"{record['ecosystem']}:{record['name']}"
    return key + (f"@{record['version']}" if record.get('version') else '')


def _line(text: str, needle: str) -> int:
    position = text.find(needle)
    return text.count('\n', 0, position) + 1 if position >= 0 else 1


def _exact(value: str | None) -> str | None:
    if value and re.fullmatch(r'v?\d+(?:\.\d+)*(?:[-+][A-Za-z0-9.+_-]+)?', value):
        return value
    return None


def _purl(ecosystem: str, name: str, version: str | None) -> str | None:
    if not version:
        return None
    package_type = {'go': 'golang', 'cargo': 'cargo', 'npm': 'npm',
                    'nuget': 'nuget', 'pypi': 'pypi', 'pub': 'pub'}.get(ecosystem)
    if not package_type:
        return None
    encoded = '/'.join(quote(part, safe='') for part in name.split('/'))
    return f'pkg:{package_type}/{encoded}' + (f'@{quote(version, safe="")}' if version else '')


def _hashes(integrity: str, sri: bool = True) -> list[dict]:
    results = []
    lengths = {'sha1': 20, 'sha256': 32, 'sha384': 48, 'sha512': 64}
    for token in integrity.split():
        match = re.fullmatch(r'(sha1|sha256|sha384|sha512)[-:]([A-Za-z0-9+/=]+)', token)
        if not match:
            continue
        algorithm, value = match.groups()
        try:
            decoded = base64.b64decode(value, validate=True) if sri else bytes.fromhex(value)
        except (ValueError, base64.binascii.Error):
            continue
        if len(decoded) == lengths[algorithm]:
            results.append({'alg': algorithm.upper(), 'content': decoded.hex()})
    return results


class _Collector:
    def __init__(self, files: dict[str, bytes]):
        self.files = files
        self.text = {path: content.decode('utf-8-sig') for path, content in files.items()
                     if _manifest(path)}
        self.records: dict[str, dict] = {}

    def add(self, name: str, ecosystem: str, path: str, *, version=None,
            kind='library', scope='runtime', detail='', needle=None,
            completeness='declared', notes=(), hashes=(), license=None,
            version_constraint=None) -> dict:
        record = {'name': name, 'kind': kind, 'ecosystem': ecosystem, 'scope': scope,
                  'evidence': [{'path': path, 'line': _line(self.text[path], needle or name),
                                'detail': detail or 'Declared dependency'}],
                  'hashes': list(hashes), 'dependencies': [],
                  'completeness': completeness, 'notes': list(notes)}
        if version:
            record['version'] = str(version)
        if version_constraint:
            record['versionConstraint'] = str(version_constraint)
        if isinstance(license, str) and license:
            record['license'] = license
        purl = _purl(ecosystem, name, version)
        if purl:
            record['purl'] = purl
        key = component_key(record)
        if key not in self.records:
            self.records[key] = record
        else:
            old = self.records[key]
            for field in ('evidence', 'hashes', 'notes'):
                old[field].extend(record[field])
            priorities = {'runtime': 0, 'build': 1, 'test': 2, 'optional': 3}
            if priorities[scope] < priorities[old['scope']]:
                old['scope'] = scope
            rank = {'unresolved': 0, 'declared': 1, 'locked': 2}
            if rank[completeness] > rank[old['completeness']]:
                old['completeness'] = completeness
            if record.get('license') and not old.get('license'):
                old['license'] = record['license']
            if record.get('versionConstraint') and not old.get('versionConstraint'):
                old['versionConstraint'] = record['versionConstraint']
            if kind != 'library':
                old['kind'] = kind
        return self.records[key]

    @staticmethod
    def edge(parent: dict, dependency: dict) -> None:
        parent['dependencies'].append(component_key(dependency))

    def finish(self) -> list[dict]:
        for record in self.records.values():
            for field in ('evidence', 'hashes'):
                unique = {json.dumps(item, sort_keys=True): item for item in record[field]}
                record[field] = [unique[key] for key in sorted(unique)]
            for field in ('dependencies', 'notes'):
                record[field] = sorted(set(record[field]))
        return [self.records[key] for key in sorted(self.records)]


def _manifest(path: str) -> bool:
    base = posixpath.basename(path)
    return (base in {'go.mod', 'go.sum', 'Cargo.toml', 'Cargo.lock', 'package.json',
                     'package-lock.json', 'libman.json', 'pubspec.yaml', 'MODULE.bazel',
                     '.bazelversion', 'pyproject.toml', 'Directory.Packages.props'}
            or base.endswith('.csproj') or base.startswith('Dockerfile')
            or bool(re.fullmatch(r'(?:requirements|constraints)[^/]*\.txt', base)))


# --- REGION: Go modules and recorded checksums
def _go(c: _Collector) -> None:
    for path, text in sorted(c.text.items()):
        if not path.endswith('/go.mod') and path != 'go.mod':
            continue
        module = re.search(r'(?m)^module\s+(\S+)', text)
        if not module:
            continue
        parent = c.add(module[1], 'go', path, kind='application',
                       detail='Go module declaration', notes=['Go dependency graph was not resolved.'])
        toolchain = re.search(r'(?m)^toolchain\s+go(\S+)', text)
        if toolchain:
            c.edge(parent, c.add('Go', 'toolchain', path, version=toolchain[1], kind='platform',
                               scope='build', detail='Declared Go toolchain', needle=toolchain[0]))
        requirements, replacements = [], {}
        block = ''
        for raw in text.splitlines():
            line = raw.split('//', 1)[0].strip()
            if line == ')':
                block = ''
                continue
            start = re.match(r'^(require|replace)\s+\($', line)
            if start:
                block = start[1]
                continue
            directive = re.match(r'^(require|replace)\s+(.+)$', line)
            mode, body = (directive[1], directive[2]) if directive else (block, line)
            if mode == 'require' and body:
                parts = body.split()
                if len(parts) >= 2:
                    requirements.append((parts[0], parts[1]))
            elif mode == 'replace' and '=>' in body:
                original, target = [part.split() for part in body.split('=>', 1)]
                if original and target:
                    replacements[(original[0], original[1] if len(original) > 1 else '')] = target
        sums: dict[tuple[str, str], list[dict]] = {}
        sum_path = posixpath.join(posixpath.dirname(path), 'go.sum')
        if sum_path in c.text:
            for line_number, line in enumerate(c.text[sum_path].splitlines(), 1):
                parts = line.split()
                if len(parts) != 3 or parts[1].endswith('/go.mod'):
                    continue
                name, version, encoded = parts
                hashes = _hashes(encoded.replace('h1:', 'sha256-', 1))
                sums[(name, version)] = hashes
                c.add(name, 'go', sum_path, version=version, hashes=hashes,
                      needle=line, completeness='unresolved',
                      detail='Recorded Go module content checksum',
                      notes=['go.sum records do not establish selected transitive versions or edges.',
                             'Go h1 is a canonical directory hash, not an archive checksum.'])
        for name, version in requirements:
            target = replacements.get((name, version), replacements.get((name, ''), []))
            notes = ['Transitive Go module selection was not resolved.']
            if target and (target[0].startswith('.') or target[0].startswith('/')):
                local = posixpath.normpath(posixpath.join(posixpath.dirname(path), target[0], 'go.mod'))
                notes.append(f'Local replacement: {target[0]} (declared requirement {name}@{version}).')
                if local not in c.files:
                    notes.append('Local replacement is not present at the declared repository path; deployment may stage it.')
                dependency = c.add(name, 'go', path, kind='application', completeness='unresolved',
                                   needle=name + ' ' + version, notes=notes, detail='Locally replaced Go module')
            else:
                effective_name = target[0] if target else name
                effective_version = target[1] if len(target) > 1 else version
                if target:
                    notes.append(f'Replaces declared module {name}@{version}.')
                dependency = c.add(effective_name, 'go', path, version=effective_version,
                                   hashes=sums.get((effective_name, effective_version), []),
                                   needle=name + ' ' + version, notes=notes)
            c.edge(parent, dependency)


# --- REGION: Cargo manifests and lockfile graph
def _ancestor_file(files: dict, path: str, basename: str) -> str | None:
    directory = posixpath.dirname(path)
    while True:
        candidate = posixpath.join(directory, basename)
        if candidate in files:
            return candidate
        if not directory:
            return None
        directory = posixpath.dirname(directory)


def _cargo(c: _Collector) -> None:
    locks = {}
    for path, text in sorted(c.text.items()):
        if posixpath.basename(path) != 'Cargo.lock':
            continue
        packages = tomllib.loads(text).get('package', [])
        package_blocks = list(re.finditer(r'(?ms)^\[\[package\]\].*?(?=^\[\[package\]\]|\Z)', text))
        index = {}
        for position, package in enumerate(packages):
            hashes = []
            checksum = package.get('checksum', '')
            if re.fullmatch(r'[0-9a-fA-F]{64}', checksum):
                hashes = [{'alg': 'SHA256', 'content': checksum.lower()}]
            source = package.get('source', '')
            record = c.add(package['name'], 'cargo', path, version=package['version'],
                           needle=package_blocks[position][0] if position < len(package_blocks) else package['name'],
                           hashes=hashes, completeness='locked',
                           notes=[f'Cargo source: {source}'] if source else ['Internal Cargo workspace package.'])
            index.setdefault(package['name'], []).append((package, record))
        for package in packages:
            parent = c.records[f'cargo:{package["name"]}@{package["version"]}']
            for reference in package.get('dependencies', []):
                parts = reference.split(' ', 2)
                choices = index.get(parts[0], [])
                if len(parts) > 1:
                    choices = [pair for pair in choices if pair[0]['version'] == parts[1]]
                if len(parts) > 2:
                    source = parts[2].strip('()')
                    choices = [pair for pair in choices if pair[0].get('source', '') == source]
                if len(choices) == 1:
                    c.edge(parent, choices[0][1])
                else:
                    parent['notes'].append(f'Unresolved or ambiguous Cargo lock dependency: {reference}.')
        locks[path] = index
    for path, text in sorted(c.text.items()):
        if posixpath.basename(path) != 'Cargo.toml':
            continue
        manifest = tomllib.loads(text)
        package = manifest.get('package', {})
        if not package.get('name'):
            continue
        version = package.get('version')
        version = version if isinstance(version, str) else None
        parent = c.add(package['name'], 'cargo', path, version=version,
                       kind='library' if 'lib' in manifest else 'application',
                       license=package.get('license'), detail='Cargo package manifest')
        lock_path = _ancestor_file(c.files, path, 'Cargo.lock')
        index = locks.get(lock_path, {})
        # Locked package edges select versions; a bare semver range cannot.
        selected = {c.records[key]['name']: c.records[key] for key in parent['dependencies']}
        sections = [(manifest.get('dependencies', {}), 'runtime'),
                    (manifest.get('dev-dependencies', {}), 'test'),
                    (manifest.get('build-dependencies', {}), 'build')]
        for target in manifest.get('target', {}).values():
            sections.extend([(target.get('dependencies', {}), 'optional'),
                             (target.get('build-dependencies', {}), 'build')])
        for dependencies, scope in sections:
            for alias, specification in dependencies.items():
                options = specification if isinstance(specification, dict) else {'version': specification}
                name = options.get('package', alias)
                effective_scope = 'optional' if options.get('optional') else scope
                if name in selected:
                    dependency = selected[name]
                    c.add(name, 'cargo', path, version=dependency.get('version'), scope=effective_scope,
                          needle=alias, detail='Cargo dependency declaration')
                    continue
                local = options.get('path')
                local_path = posixpath.normpath(posixpath.join(posixpath.dirname(path), local, 'Cargo.toml')) if local else ''
                local_package = tomllib.loads(c.text[local_path]).get('package', {}) if local_path in c.text else {}
                requested = str(options.get('version', ''))
                notes = [f'Declared Cargo constraint: {requested or "unspecified"}.',
                         'No lockfile-selected dependency was identified; transitive dependencies are unresolved.']
                if local:
                    notes.append(f'Local Cargo path: {local}.')
                dependency = c.add(local_package.get('name', name), 'cargo', path,
                                   version=local_package.get('version') or (_exact(requested[1:]) if requested.startswith('=') else None),
                                   scope=effective_scope, needle=alias, completeness='unresolved', notes=notes,
                                   version_constraint=requested)
                c.edge(parent, dependency)


# --- REGION: npm manifests and installed lockfile relationships
def _npm_name(location: str, metadata: dict) -> str:
    return metadata.get('name') or location.rsplit('node_modules/', 1)[-1]


def _npm_resolve(index: dict, location: str, name: str, peer=False) -> dict | None:
    current = location
    if peer and current:
        current = current.rsplit('/node_modules/', 1)[0] if '/node_modules/' in current else ''
    while True:
        candidate = posixpath.join(current, 'node_modules', name)
        if candidate in index:
            return index[candidate]
        if not current:
            return None
        current = current.rsplit('/node_modules/', 1)[0] if '/node_modules/' in current else ''


def _npm(c: _Collector) -> None:
    directories = sorted({posixpath.dirname(path) for path in c.text
                          if posixpath.basename(path) in {'package.json', 'package-lock.json'}})
    for directory in directories:
        manifest_path = posixpath.join(directory, 'package.json')
        lock_path = posixpath.join(directory, 'package-lock.json')
        manifest = json.loads(c.text[manifest_path]) if manifest_path in c.text else {}
        lock = json.loads(c.text[lock_path]) if lock_path in c.text else {}
        root_path = manifest_path if manifest_path in c.text else lock_path
        root_data = manifest or lock.get('packages', {}).get('', {}) or lock
        parent = c.add(root_data.get('name', directory or 'npm-project'), 'npm', root_path,
                       version=root_data.get('version'), kind='application',
                       detail='npm project declaration', license=root_data.get('license'))
        packages = lock.get('packages', {})
        index = {'': parent}
        for location, metadata in sorted(packages.items()):
            if not location or metadata.get('link'):
                continue
            name = _npm_name(location, metadata)
            record = c.add(name, 'npm', lock_path, version=metadata.get('version'),
                           scope='optional' if metadata.get('optional') else 'build' if metadata.get('dev') else 'runtime',
                           hashes=_hashes(metadata.get('integrity', '')), completeness='locked',
                           license=metadata.get('license'), needle=json.dumps(location),
                           notes=[f'npm lock location: {location}.'], detail='npm lockfile package')
            index[location] = record
        for location, metadata in sorted(packages.items()):
            if metadata.get('link'):
                target = metadata.get('resolved', '')
                if target in index:
                    index[location] = index[target]
                else:
                    parent['notes'].append(f'Unresolved npm workspace link: {location} -> {target}.')
        for location, metadata in sorted(packages.items()):
            if location not in index:
                continue
            record = index[location]
            for section in ('dependencies', 'optionalDependencies', 'peerDependencies'):
                for name, constraint in metadata.get(section, {}).items():
                    dependency = _npm_resolve(index, location, name, peer=section == 'peerDependencies')
                    if dependency:
                        c.edge(record, dependency)
                    else:
                        record['notes'].append(f'Unresolved npm {section}: {name} ({constraint}).')
        # Lockfile v1 stores a nested dependency tree, rather than install locations.
        def legacy_tree(tree, owner):
            for name, metadata in sorted(tree.items()):
                dependency = c.add(name, 'npm', lock_path, version=metadata.get('version'),
                                   scope='build' if metadata.get('dev') else 'runtime',
                                   hashes=_hashes(metadata.get('integrity', '')), completeness='locked',
                                   detail='npm v1 lockfile package')
                c.edge(owner, dependency)
                legacy_tree(metadata.get('dependencies', {}), dependency)
                if metadata.get('requires'):
                    dependency['notes'].append('npm v1 requires edges outside the nested tree were not resolved.')
        if not packages and lock.get('dependencies'):
            legacy_tree(lock['dependencies'], parent)
        for section, scope in (('dependencies', 'runtime'), ('devDependencies', 'build'),
                               ('optionalDependencies', 'optional')):
            for name, constraint in root_data.get(section, {}).items():
                dependency = _npm_resolve(index, '', name)
                if dependency:
                    c.edge(parent, dependency)
                    c.add(dependency['name'], 'npm', root_path, version=dependency.get('version'),
                          scope=scope, needle=name, detail=f'npm {section} declaration')
                elif not (not packages and lock.get('dependencies')):
                    dependency = c.add(name, 'npm', root_path, version=_exact(str(constraint)),
                                       scope=scope, needle=name, completeness='unresolved',
                                       version_constraint=str(constraint) if not _exact(str(constraint)) else None,
                                       notes=[f'Declared npm constraint: {constraint}.',
                                              'No matching lockfile package; transitive dependencies are unresolved.'])
                    c.edge(parent, dependency)


# --- REGION: .NET and browser library declarations
def _tag(element) -> str:
    return element.tag.rsplit('}', 1)[-1]


def _dotnet(c: _Collector) -> None:
    for path, text in sorted(c.text.items()):
        if not path.endswith('.csproj'):
            continue
        document = ET.fromstring(text)
        parent = c.add(posixpath.basename(path)[:-7], 'dotnet', path, kind='application',
                       scope='test' if re.search(r'(^|/)(?:test|tests)/', path, re.I) else 'runtime',
                       needle='<Project', detail='MSBuild project',
                       notes=['NuGet transitive dependencies are unresolved without tracked restore locks/assets.'])
        central_path = _ancestor_file(c.files, path, 'Directory.Packages.props')
        central = {}
        if central_path:
            central = {item.get('Include') or item.get('Update'): item.get('Version')
                       for item in ET.fromstring(c.text[central_path]).iter() if _tag(item) == 'PackageVersion'}
        for element in document.iter():
            tag = _tag(element)
            if tag not in {'PackageReference', 'FrameworkReference', 'TargetFramework', 'TargetFrameworks'}:
                continue
            if tag.startswith('TargetFramework'):
                if element.text:
                    parent['notes'].append(f'Target framework declaration: {element.text.strip()}.')
                continue
            name = element.get('Include') or element.get('Update')
            if not name:
                continue
            requested = element.get('Version') or next((item.text for item in element if _tag(item) == 'Version'), None) or central.get(name)
            scope = ('build' if element.get('PrivateAssets') == 'all' or name.endswith('.Tools.Targets')
                     else 'test' if re.search(r'(^|/)(?:test|tests)/', path, re.I) else 'runtime')
            notes = ['No transitive NuGet graph was resolved.']
            if requested and not _exact(requested):
                notes.append(f'Declared NuGet constraint: {requested}.')
            dependency = c.add(name, 'nuget' if tag == 'PackageReference' else 'dotnet', path,
                               version=_exact(requested), kind='library' if tag == 'PackageReference' else 'framework',
                               scope=scope, needle=name, notes=notes,
                               version_constraint=requested if not _exact(requested) else None)
            if central_path and name in central:
                dependency['evidence'].append({'path': central_path, 'line': _line(c.text[central_path], name),
                                               'detail': 'Central NuGet package version declaration'})
            c.edge(parent, dependency)
    for path, text in sorted(c.text.items()):
        if posixpath.basename(path) != 'libman.json':
            continue
        manifest = json.loads(text)
        for entry in manifest.get('libraries', []):
            name, separator, version = entry['library'].rpartition('@')
            if not separator:
                name, version = entry['library'], None
            c.add(name, entry.get('provider', manifest.get('defaultProvider', 'libman')), path,
                  version=_exact(version), version_constraint=version if not _exact(version) else None,
                  needle=entry['library'], detail='LibMan browser library',
                  notes=['Provider declaration only; restored browser files are not inventoried.'])


# --- REGION: Flutter and Bazel declarations
def _flutter(c: _Collector) -> None:
    for path, text in sorted(c.text.items()):
        if posixpath.basename(path) != 'pubspec.yaml':
            continue
        name = re.search(r'(?m)^name:\s*["\']?([^\s"\']+)', text)
        version = re.search(r'(?m)^version:\s*["\']?([^\s"\']+)', text)
        if not name:
            continue
        parent = c.add(name[1], 'pub', path, version=version[1] if version else None,
                       kind='application', detail='Flutter/Dart package manifest',
                       notes=['Pub/Gradle transitive packages are unresolved; platform scaffolding is generated.'])
        section, dependency_name = '', ''
        lines = text.splitlines()
        for number, line in enumerate(lines):
            top = re.match(r'^([\w_]+):', line)
            if top:
                section = top[1]
            match = re.match(r'^  ([\w_-]+):\s*(.*?)\s*(?:#.*)?$', line)
            if section not in {'dependencies', 'dev_dependencies'} or not match:
                continue
            dependency_name, requested = match.groups()
            next_line = lines[number + 1] if number + 1 < len(lines) else ''
            sdk = re.match(r'^    sdk:\s*(\S+)', next_line) if not requested else None
            scope = 'test' if section == 'dev_dependencies' else 'runtime'
            dependency = c.add(dependency_name, 'flutter-sdk' if sdk else 'pub', path,
                               version=_exact(requested.strip('"\'')),
                               kind='framework' if sdk else 'library', scope=scope,
                               needle=line, completeness='unresolved',
                               version_constraint=requested.strip('"\'') if requested and not _exact(requested.strip('"\'')) else None,
                               notes=[f'Declared Dart constraint: {requested or "SDK " + sdk[1] if sdk else requested or "map declaration"}.',
                                      'No tracked pub lockfile was resolved.'])
            c.edge(parent, dependency)


def _bazel(c: _Collector) -> None:
    for path, text in sorted(c.text.items()):
        if posixpath.basename(path) == '.bazelversion':
            c.add('Bazel', 'toolchain', path, version=_exact(text.strip()),
                  version_constraint=text.strip() if not _exact(text.strip()) else None, kind='platform', scope='build',
                  needle=text.strip(), detail='Bazel toolchain pin')
        if posixpath.basename(path) != 'MODULE.bazel':
            continue
        clean = re.sub(r'(?m)#.*$', '', text)
        for match in re.finditer(r'\bbazel_dep\s*\((.*?)\)', clean, re.S):
            name = re.search(r'\bname\s*=\s*["\']([^"\']+)', match[1])
            version = re.search(r'\bversion\s*=\s*["\']([^"\']+)', match[1])
            if name:
                c.add(name[1], 'bazel', path, version=version[1] if version else None, scope='build',
                      notes=['Bazel registry transitive dependencies are unresolved without a tracked module lock.'])
        for match in re.finditer(r'\brust\.toolchain\s*\((.*?)\)', clean, re.S):
            versions = re.search(r'\bversions\s*=\s*\[([^\]]*)\]', match[1], re.S)
            for version in re.findall(r'["\']([^"\']+)["\']', versions[1] if versions else ''):
                c.add('Rust', 'toolchain', path, version=version, kind='platform', scope='build',
                      needle=version, detail='Bazel Rust toolchain pin')


# --- REGION: Container base images
def _docker(c: _Collector) -> None:
    for path, text in sorted(c.text.items()):
        if not posixpath.basename(path).startswith('Dockerfile'):
            continue
        arguments, stages = {}, set()
        for line in text.splitlines():
            argument = re.match(r'^\s*ARG\s+([\w]+)=(.+?)\s*$', line, re.I)
            if argument:
                arguments[argument[1]] = argument[2].strip('"\'')
            match = re.match(r'^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?', line, re.I)
            if not match:
                continue
            expression, stage = match.groups()
            image = re.sub(r'\$\{(\w+)\}|\$(\w+)', lambda item: arguments.get(item[1] or item[2], item[0]), expression)
            if image.lower() in stages or image.lower() == 'scratch':
                if stage:
                    stages.add(stage.lower())
                continue
            if stage:
                stages.add(stage.lower())
            notes = ['Container OS/package contents were not scanned; tag-only images are mutable.']
            if expression != image:
                notes.append(f'FROM expression {expression} uses declared ARG defaults; builds can override them.')
            if '$' in image:
                notes.append('Container image expression could not be resolved from declared ARG defaults.')
            name, version, hashes = image, None, []
            if '@sha256:' in image:
                name, digest = image.split('@sha256:', 1)
                if re.fullmatch(r'[0-9a-fA-F]{64}', digest):
                    hashes = [{'alg': 'SHA256', 'content': digest.lower()}]
                    notes.append('Checksum identifies the declared image manifest, not an exported image archive.')
                if ':' in name.rsplit('/', 1)[-1]:
                    name, version = name.rsplit(':', 1)
            elif ':' in image.rsplit('/', 1)[-1]:
                name, version = image.rsplit(':', 1)
            exact_version = _exact(version) if version and len(version.split('.')) >= 3 else None
            c.add(name, 'docker', path, version=exact_version, kind='container',
                  scope='build' if stage and stage.lower() in {'build', 'builder', 'publish'} else 'runtime',
                  needle=line, detail='Dockerfile FROM declaration', hashes=hashes,
                  version_constraint=version if not exact_version else None,
                  completeness='unresolved' if '$' in image else 'declared', notes=notes)


# --- REGION: Python dependency declarations
def _python_requirement(c: _Collector, path: str, requirement: str, scope: str, parent=None) -> None:
    match = re.match(r'^\s*([A-Za-z0-9_.-]+)(?:\[[^\]]*\])?(.*)$', requirement)
    if not match:
        return
    name = re.sub(r'[-_.]+', '-', match[1]).lower()
    tail = match[2].strip()
    pin = re.match(r'^==([^\s;]+)', tail)
    version = _exact(pin[1]) if pin else None
    hashes = []
    for algorithm, digest in re.findall(r'--hash=(sha1|sha256|sha384|sha512):([0-9a-fA-F]+)', tail):
        hashes.extend(_hashes(f'{algorithm}:{digest}', sri=False))
    dependency = c.add(name, 'pypi', path, version=version, scope=scope, needle=requirement,
                       version_constraint=tail if tail and not version else None,
                       hashes=hashes, notes=[f'Declared Python requirement: {requirement}.',
                                            'Transitive Python dependencies were not resolved.'])
    if parent:
        c.edge(parent, dependency)


def _python(c: _Collector) -> None:
    for path, text in sorted(c.text.items()):
        base = posixpath.basename(path)
        if re.fullmatch(r'(?:requirements|constraints)[^/]*\.txt', base):
            scope = 'test' if 'test' in base else 'build' if 'dev' in base else 'runtime'
            for line in text.splitlines():
                line = line.strip()
                if line and not line.startswith(('#', '-')):
                    _python_requirement(c, path, line, scope)
        if base != 'pyproject.toml':
            continue
        manifest = tomllib.loads(text)
        project = manifest.get('project', {}) or manifest.get('tool', {}).get('poetry', {})
        parent = c.add(project.get('name', posixpath.dirname(path) or 'python-project'), 'pypi', path,
                       version=project.get('version'), kind='application', detail='Python project manifest')
        dependencies = project.get('dependencies', [])
        if isinstance(dependencies, list):
            for requirement in dependencies:
                _python_requirement(c, path, requirement, 'runtime', parent)
        else:
            for name, value in dependencies.items():
                if name != 'python':
                    requested = value.get('version', '') if isinstance(value, dict) else value
                    _python_requirement(c, path, name + str(requested), 'runtime', parent)
        for group in project.get('optional-dependencies', {}).values():
            for requirement in group:
                _python_requirement(c, path, requirement, 'optional', parent)
        for requirement in manifest.get('build-system', {}).get('requires', []):
            _python_requirement(c, path, requirement, 'build', parent)


# --- REGION: Repository collection
def collect_dependencies(files: dict[str, bytes], repo_name: str) -> list[dict]:
    """Collect declared/locked components from repository-relative tracked file blobs.

    Paths are normalized to POSIX form. Invalid manifests fail rather than silently
    omitting dependency evidence. ``repo_name`` is reserved for caller provenance;
    component identity follows manifest package names, never guessed repository names.
    """
    normalized = {path.replace('\\', '/'): content for path, content in files.items()}
    collector = _Collector(normalized)
    for parser in (_go, _cargo, _npm, _dotnet, _flutter, _bazel, _docker, _python):
        parser(collector)
    return collector.finish()
