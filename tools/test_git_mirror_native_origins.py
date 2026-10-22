#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Origin transfer and restoration regression tests without a live proxy VM."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('origins', Path(__file__).with_name('git_mirror_native_origins.py'))
origins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(origins)


def archive_bytes(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as archive:
        for name, content, kind in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    stream.seek(0)
    return stream


class OriginTests(unittest.TestCase):
    def test_prepares_actual_git_bundles_and_checks_received_commits_and_trees(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary); source=base/'source'; source.mkdir()
            def git(*args):
                return subprocess.run(['git',*args],check=True,capture_output=True,text=True,timeout=30).stdout.strip()
            git('-C',str(source),'init','--quiet','--initial-branch','main')
            (source/'VERSION').write_text('prepared candidate\n')
            git('-C',str(source),'add','VERSION')
            git('-C',str(source),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','candidate')
            commit=git('-C',str(source),'rev-parse','HEAD'); tree=git('-C',str(source),'rev-parse','HEAD^{tree}')
            bundle=base/'candidate.bundle'; git('-C',str(source),'bundle','create',str(bundle),'refs/heads/main')
            repositories=[{'name':name,'canonicalUrl':'https://github.com/alissonsol/yuruna'+('-project' if name=='project' else '')+'.git','commit':commit,'tree':tree} for name in ('framework','project')]
            state=base/'state'; published=base/'origins'; dropins=base/'dropins'; run_id='c'*32
            state.mkdir(); published.mkdir()
            real_read=Path.read_bytes
            reads=0
            def read_bytes(path):
                nonlocal reads
                if str(path)=='/proc/123/environ':
                    reads+=1
                    if reads==1: return b''
                    expected=[dict(entry,path=str(published/run_id/(entry['name']+'.git'))) for entry in repositories]
                    values=origins.environment_assignments(b'',expected)
                    return b'\0'.join((key+'='+value).encode() for key,value in values.items())+b'\0'
                return real_read(path)
            real_command=origins.command
            calls=[]
            def command(*args,**kwargs):
                calls.append(args)
                if args[0]=='git': return real_command(*args,**kwargs)
                return '123' if args[:2]==('systemctl','show') else ''
            with patch.object(origins,'BASE',published),patch.object(origins,'STATE',state),patch.object(origins,'DROPINS',dropins),patch.object(origins,'command',side_effect=command),patch.object(origins.os,'chown'),patch.object(origins.pwd,'getpwnam') as user,patch.object(origins.grp,'getgrnam') as group,patch.object(Path,'read_bytes',read_bytes):
                user.return_value.pw_uid=os.getuid(); group.return_value.gr_gid=os.getgid()
                result=origins.prepare({'runId':run_id,'repositories':repositories},archive_bytes([('framework.bundle',bundle.read_bytes(),tarfile.REGTYPE),('project.bundle',bundle.read_bytes(),tarfile.REGTYPE)]))
            self.assertTrue(result['passed'])
            self.assertEqual(reads,2)
            for entry in result['repositories']:
                self.assertEqual(git('-C',entry['path'],'rev-parse','HEAD'),commit)
                self.assertEqual(git('-C',entry['path'],'rev-parse','HEAD^{tree}'),tree)
            self.assertTrue(any(args[:1]==('systemd-run',) and '--on-active=3h' in args for args in calls))

    def test_preserves_settings_but_replaces_existing_exact_origin_rewrite(self):
        raw = b'GIT_CONFIG_COUNT=2\0GIT_CONFIG_KEY_0=http.version\0GIT_CONFIG_VALUE_0=HTTP/1.1\0GIT_CONFIG_KEY_1=url.file:///previous.insteadOf\0GIT_CONFIG_VALUE_1=https://github.com/alissonsol/yuruna.git\0'
        repositories = [{'path':'/private/framework.git','canonicalUrl':'https://github.com/alissonsol/yuruna.git'}]
        values = origins.environment_assignments(raw, repositories)
        self.assertEqual(values['GIT_CONFIG_KEY_0'], 'http.version')
        self.assertEqual(values['GIT_CONFIG_VALUE_0'], 'HTTP/1.1')
        self.assertEqual(values['GIT_CONFIG_KEY_1'], 'url.file:///private/framework.git.insteadOf')
        self.assertEqual(values['GIT_CONFIG_COUNT'], '6')
        self.assertEqual(values['GIT_CONFIG_KEY_2'], 'protocol.file.allow')
        self.assertEqual(values['GIT_CONFIG_VALUE_2'], 'always')
        self.assertEqual(values['GIT_CONFIG_KEY_3'], 'credential.helper')
        self.assertEqual(values['GIT_CONFIG_VALUE_3'], '')

    def test_rejects_invalid_counts_and_multiline_unit_values(self):
        for count in ('invalid','-1','1025'):
            with self.assertRaises(ValueError):
                origins.environment_assignments(('GIT_CONFIG_COUNT='+count+'\0').encode(), [])
        with self.assertRaises(ValueError):
            origins.environment_file({'GIT_CONFIG_VALUE_0':'injected\nEnvironment=OTHER=bad'})

    def test_receives_only_the_two_declared_regular_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            stream = archive_bytes([('framework.bundle',b'one',tarfile.REGTYPE),('project.bundle',b'two',tarfile.REGTYPE)])
            origins.receive_bundles(stream,directory)
            self.assertEqual((directory/'framework.bundle').read_bytes(),b'one')
            self.assertEqual((directory/'project.bundle').read_bytes(),b'two')

    def test_rejects_traversal_symlinks_duplicates_and_missing_bundle(self):
        invalid = [
            [('../outside',b'x',tarfile.REGTYPE)],
            [('framework.bundle',b'',tarfile.SYMTYPE)],
            [('framework.bundle',b'x',tarfile.REGTYPE),('framework.bundle',b'x',tarfile.REGTYPE)],
            [('framework.bundle',b'x',tarfile.REGTYPE)],
        ]
        for entries in invalid:
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as temporary:
                with self.assertRaises(ValueError):
                    origins.receive_bundles(archive_bytes(entries),Path(temporary))

    def test_restore_restarts_without_override_before_removing_owned_origins(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary); state=base/'state'; published=base/'origins'; dropins=base/'dropins'
            run_id='a'*32
            for path in (state/run_id,published/run_id,dropins): path.mkdir(parents=True)
            owned=dropins/('zz-qualification-origins-'+run_id+'.conf'); owned.write_text('fixture')
            other=dropins/'operator.conf'; other.write_text('keep')
            (published/'other-run').mkdir()
            def command(*args,**_kwargs):
                if args[:2]==('systemctl','restart'):
                    self.assertFalse(owned.exists())
                    self.assertTrue((published/run_id).exists())
            with patch.object(origins,'BASE',published),patch.object(origins,'STATE',state),patch.object(origins,'DROPINS',dropins),patch.object(origins,'command',side_effect=command):
                result=origins.restore({'runId':run_id})
            self.assertTrue(result['restored'])
            self.assertFalse((published/run_id).exists())
            self.assertTrue((published/'other-run').exists())
            self.assertEqual(other.read_text(),'keep')

    def test_failed_restart_keeps_origin_files_for_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary); state=base/'state'; published=base/'origins'; dropins=base/'dropins'; run_id='b'*32
            for path in (state/run_id,published/run_id,dropins): path.mkdir(parents=True)
            with patch.object(origins,'BASE',published),patch.object(origins,'STATE',state),patch.object(origins,'DROPINS',dropins),patch.object(origins,'command',side_effect=RuntimeError('restart failed')):
                with self.assertRaisesRegex(RuntimeError,'restart failed'):
                    origins.restore({'runId':run_id})
            self.assertTrue((state/run_id).exists())
            self.assertTrue((published/run_id).exists())


if __name__=='__main__':
    unittest.main()
