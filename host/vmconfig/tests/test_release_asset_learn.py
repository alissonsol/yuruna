# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42e1c7a4-5b39-4d6f-9a8e-2f6c0b7d1e53
"""The release asset learner against stand-in squid logs, rules and a stand-in squid.

Runs the script exactly as the seed ships it, read out of the seed the way
tools/Test-ZotRelease.py reads it, so neither squid nor a network is needed.
The store ID helper is applied the way squid's stock storeid_file_rewrite
applies its rules, and its answer is %-decoded the way squid decodes it.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import types
import unittest
import urllib.parse

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('test_zot_release', ROOT / 'tools/Test-ZotRelease.py')
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)
SEED_LINES = TOOL.SEED.read_text(encoding='utf-8').replace('\r\n', '\n').split('\n')
LEARN = types.ModuleType('release_asset_learn')
exec(compile(TOOL.seed_file_body(SEED_LINES, '/usr/local/bin/yuruna-release-asset-learn.py'), 'yuruna-release-asset-learn.py', 'exec'), LEARN.__dict__)



def seed_scalar(path):
    """A write_files body the seed holds as one double-quoted scalar, decoded."""
    at = SEED_LINES.index('  - path: ' + path)
    while not SEED_LINES[at].startswith('    content: "'):
        at += 1
    # Its escapes (\\, \t, \n) read the same in JSON.
    return json.loads(SEED_LINES[at][len('    content: '):])


STATIC = seed_scalar('/etc/squid/yuruna-store-id.static.rules')
RELEASE = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/hashes.sha256'
# The shape GitHub answers with: a signed query full of %-escapes and a +.
CDN = ('https://release-assets.githubusercontent.com/github-production-release-asset/49609581/d53e4ccf-c010-4877-89e4-ad7a86deb821'
       '?sp=r&sv=2018-11-09&se=2026-11-08T16%3A40%3A55Z&rscd=attachment%3B+filename%3Dhashes.sha256&sig=Zm9v%2Bbar%3D'
       '&response-content-disposition=attachment%3B%20filename%3Dhashes.sha256')
# What squid appends after the URL on the line it sends the helper.
EXTRAS = ' 192.168.7.181/- - GET myip=192.168.7.42 myport=3129'


def log_line(stamp, status, url, location):
    return '{0} {1} {2} {3}\n'.format(stamp, status, url, location)


def store_id(rules_text, line):
    """What storeid_file_rewrite answers, as squid decodes it; None for ERR."""
    for rule in rules_text.split('\n'):
        match = re.match(r'^\s*([^\t]+?)\s*\t+\s*([^\t]+?)\s*$', rule)
        if not match:
            continue
        found = re.search(match.group(1), line)
        if not found:
            continue
        answer = match.group(2)
        # Perl substitutes $1..$n for as many values as the match returned; a
        # pattern without captures returns one value, 1.
        values = found.groups() or ('1',)
        for i, value in enumerate(values, start=1):
            answer = answer.replace('$' + str(i), value or '')
        return urllib.parse.unquote(answer)
    return None


class Workspace:
    """The files one run reads and writes, under a temporary directory."""

    def __init__(self, root):
        self.root = root
        self.log = os.path.join(root, 'yuruna_release_redirects.log')
        self.map = os.path.join(root, 'state', 'release-asset-map.tsv')
        self.static = os.path.join(root, 'yuruna-store-id.static.rules')
        self.rules = os.path.join(root, 'yuruna-store-id.rules')
        self.calls = os.path.join(root, 'squid.calls')
        self.squid = os.path.join(root, 'squid')
        with open(self.static, 'w', encoding='utf-8') as handle:
            handle.write(STATIC)
        self.squid_exits(0)

    def squid_exits(self, code):
        with open(self.squid, 'w', encoding='utf-8') as handle:
            handle.write('#!/bin/sh\necho "$@" >> "{0}"\nexit {1}\n'.format(self.calls, code))
        os.chmod(self.squid, stat.S_IRWXU)

    def write_log(self, *lines, suffix=''):
        with open(self.log + suffix, 'w', encoding='utf-8') as handle:
            handle.writelines(lines)

    def run(self, *extra):
        self.output = io.StringIO()
        with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            return LEARN.main(['--log', self.log, '--map', self.map, '--static-rules', self.static,
                               '--rules', self.rules, '--squid', self.squid] + list(extra))

    def rules_text(self):
        with open(self.rules, encoding='utf-8') as handle:
            return handle.read()

    def reconfigures(self):
        try:
            with open(self.calls, encoding='utf-8') as handle:
                return handle.read().split('\n')[:-1]
        except FileNotFoundError:
            return []


class ReleaseAssetLearner(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.ws = Workspace(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_files_a_learned_release_url_under_the_cdn_url_it_was_redirected_to(self):
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.assertEqual(self.ws.run(), 0)
        self.assertIn('has 1 learned release download(s)', self.ws.output.getvalue())
        rules = self.ws.rules_text()
        self.assertTrue(STATIC.startswith('^(https?)://www\\.powershellgallery\\.com/'), STATIC)
        self.assertTrue(rules.startswith(STATIC), 'the static rules come first, unchanged')
        self.assertEqual(store_id(rules, RELEASE + EXTRAS), CDN, 'squid decodes the answer to the exact key the asset is stored under')
        self.assertEqual(store_id(rules, RELEASE), CDN)
        self.assertEqual(self.ws.reconfigures(), ['-k reconfigure'])

    def test_keeps_the_gallery_rule_working_beside_learned_rules(self):
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.ws.run()
        self.assertEqual(store_id(self.ws.rules_text(), 'https://www.powershellgallery.com/api/v2/package/powershell-yaml/0.4.12' + EXTRAS),
                         'https://cdn.powershellgallery.com/packages/powershell-yaml.0.4.12.nupkg')

    def test_leaves_the_url_unmapped_when_it_is_not_exactly_the_learned_one(self):
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.ws.run()
        rules = self.ws.rules_text()
        for url in (RELEASE + '?nocache=7', RELEASE + 'x', RELEASE.replace('v7.6.9', 'v7.6.8'),
                    'https://github.com/PowerShell/PowerShell/releases/latest', CDN):
            self.assertIsNone(store_id(rules, url + EXTRAS), url)

    def test_rewrites_nothing_and_does_not_reconfigure_when_nothing_changed(self):
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.ws.run()
        before = os.stat(self.ws.rules).st_mtime_ns
        self.assertEqual(self.ws.run(), 0)
        self.assertEqual(os.stat(self.ws.rules).st_mtime_ns, before)
        self.assertEqual(len(self.ws.reconfigures()), 1)

    def test_learns_only_redirects_it_can_serve_safely(self):
        other = 'https://github.com/opentofu/opentofu/releases/download/v1.11.2/tofu_1.11.2_linux_amd64.tar.gz'
        self.ws.write_log(
            log_line('1794126603.1', '504', RELEASE, '-'),
            log_line('1794126603.2', '-', RELEASE, '-'),
            log_line('1794126603.3', '302', RELEASE + '?nocache=7', CDN),
            log_line('1794126603.4', '302', RELEASE, 'https://example.com/elsewhere'),
            log_line('1794126603.5', '302', RELEASE, 'http://release-assets.githubusercontent.com/x'),
            log_line('1794126603.6', '302', RELEASE, CDN + '$1'),
            log_line('1794126603.7', '302', 'https://github.com/PowerShell/PowerShell/releases/latest',
                     'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.9'),
            'not a squid line at all\n',
            log_line('not-a-time', '302', other, CDN),
        )
        self.assertEqual(self.ws.run(), 0)
        self.assertEqual(self.ws.rules_text(), STATIC, 'nothing in that log is learnable')
        self.assertFalse(os.path.exists(self.ws.map), 'no mapping, no map file')

    def test_the_newest_redirect_of_a_url_replaces_the_mapping(self):
        newer = CDN.replace('sig=Zm9v', 'sig=bmV3')
        self.ws.write_log(log_line('1794126603.000', '302', RELEASE, CDN))
        self.ws.run()
        self.ws.write_log(log_line('1794126603.000', '302', RELEASE, CDN), log_line('1794130000.000', '302', RELEASE, newer))
        self.ws.run()
        self.assertEqual(store_id(self.ws.rules_text(), RELEASE), newer)
        # Once the log rotates away, an older line read again cannot bring the old one back.
        self.ws.write_log(log_line('1794126603.000', '302', RELEASE, CDN))
        self.ws.run()
        self.assertEqual(store_id(self.ws.rules_text(), RELEASE), newer)

    def test_keeps_what_it_learned_after_the_log_rotates_away(self):
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.ws.run()
        self.ws.write_log()
        os.remove(self.ws.rules)
        self.assertEqual(self.ws.run(), 0)
        self.assertEqual(store_id(self.ws.rules_text(), RELEASE), CDN)

    def test_reads_the_rotated_logs_beside_the_live_one(self):
        self.ws.write_log()
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN), suffix='.0')
        self.ws.run()
        self.assertEqual(store_id(self.ws.rules_text(), RELEASE), CDN)

    def test_drops_the_oldest_mappings_past_its_bound(self):
        saved = LEARN.MAX_LEARNED
        LEARN.MAX_LEARNED = 2
        try:
            urls = [RELEASE.replace('hashes.sha256', 'asset{0}'.format(i)) for i in range(3)]
            self.ws.write_log(*[log_line('17941266{0}0.000'.format(i), '302', url, CDN) for i, url in enumerate(urls)])
            self.ws.run()
        finally:
            LEARN.MAX_LEARNED = saved
        rules = self.ws.rules_text()
        self.assertIsNone(store_id(rules, urls[0]), 'the oldest mapping went first')
        self.assertEqual(store_id(rules, urls[2]), CDN)

    def test_writes_only_the_rules_before_squid_first_starts(self):
        self.assertEqual(self.ws.run('--no-reconfigure'), 0)
        self.assertEqual(self.ws.rules_text(), STATIC, 'the build gets the static rules before any log exists')
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.assertEqual(self.ws.run('--no-reconfigure'), 0)
        self.assertEqual(self.ws.reconfigures(), [])

    def test_says_when_squid_refused_the_reconfigure(self):
        self.ws.squid_exits(1)
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.assertEqual(self.ws.run(), 1)
        self.assertIn('squid -k reconfigure exited 1; the new rules apply when squid next starts its helpers', self.ws.output.getvalue())
        self.assertEqual(store_id(self.ws.rules_text(), RELEASE), CDN, 'the rules stay written for the next helper start')

    def test_replaces_the_rules_file_without_leaving_a_partial_one(self):
        self.ws.write_log(log_line('1794126603.577', '302', RELEASE, CDN))
        self.ws.run()
        leftovers = [name for name in os.listdir(self.temp.name) if name.startswith('.')]
        self.assertEqual(leftovers, [])
        self.assertEqual(stat.S_IMODE(os.stat(self.ws.rules).st_mode), 0o644)


if __name__ == '__main__':
    unittest.main()
