# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Exercise AKS import locally with a fake Azure CLI and real kubectl."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
KUBECTL = Path(os.environ.get('KUBECTL', ROOT / '.test-results/review-2026-09-28/dependency-tools/kubectl'))
SCRIPT = Path(os.environ.get('AKS_IMPORT_SCRIPT', ROOT / 'global/resources/azure/aks-cluster/cluster-import.sh'))


class ContextImport(unittest.TestCase):
    def test_repeat_import_and_equal_names(self):
        for cluster in ('cluster-a', 'destination'):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / 'kubectl').symlink_to(KUBECTL)
                az = root / 'az'
                az.write_text('''#!/bin/bash
set -euo pipefail
[ "$1 $2" = 'aks get-credentials' ]; shift 2
context=''; name=''; overwrite=0
while [ "$#" -gt 0 ]; do
 case "$1" in
 --context) context="$2"; shift 2 ;;
 --name) name="$2"; shift 2 ;;
 --resource-group) shift 2 ;;
 --overwrite-existing) overwrite=1; shift ;;
 *) exit 90 ;;
 esac
done
[ "$overwrite" = 1 ]
context=${context:-$name}
kubectl config set-cluster "$name" --server=https://fixture.invalid >/dev/null
kubectl config set-context "$context" --cluster="$name" >/dev/null
kubectl config use-context "$context" >/dev/null
''')
                az.chmod(0o755)
                env = {**os.environ, 'PATH': str(root) + ':' + os.environ['PATH'], 'KUBECONFIG': str(root / 'config'), 'RESOURCE_GROUP': 'fixture', 'CLUSTER_NAME': cluster, 'DESTINATION_CONTEXT': 'destination'}
                def kube(*args):
                    return subprocess.check_output([str(KUBECTL), 'config', *args], env=env, text=True)
                kube('set-cluster', 'unrelated', '--server=https://unrelated.invalid')
                kube('set-context', 'unrelated', '--cluster=unrelated', '--namespace=untouched')
                kube('set-context', 'destination', '--cluster=old')
                kube('use-context', 'unrelated')
                for _ in range(2):
                    result = subprocess.run(['bash', str(SCRIPT)], env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    config = json.loads(kube('view', '-o', 'json'))
                    contexts = {row['name']: row['context'] for row in config['contexts']}
                    self.assertEqual(contexts['unrelated'], {'cluster': 'unrelated', 'namespace': 'untouched', 'user': ''})
                    self.assertEqual(contexts['destination']['cluster'], cluster)
                    self.assertEqual(config['current-context'], 'destination')


if __name__ == '__main__':
    unittest.main()
