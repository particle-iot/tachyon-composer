import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from assets import fetch
from runtime_bundle import PREFIX, stage_runtime


class RuntimeBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.server = self.root / 'public'
        self.cache = self.root / 'cache'
        self.content = b'RPM fixture: selected dependency'
        self.row = dict(name='jq', version='1.0', release='r0', architecture='armv8_2a',
                        filename='jq.rpm', sha256=hashlib.sha256(self.content).hexdigest(),
                        source_revision='a'*40, qli_release_revision='a'*40, runtime_bundle=True)
        self.config = dict(yocto=dict(revision='a'*40))
        self.members = [('jq.rpm', self.content), ('unselected.rpm', b'not selected')]
        self.publish()
        self.addCleanup(patch.stopall)
        patch('runtime_bundle.BASE_URL', self.server.as_uri() + '/').start()

    def publish(self, inventory=None):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            for name, content in self.members:
                entry = tarfile.TarInfo(name)
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
        manifest = dict(inputs=dict(yocto=self.config['yocto']), files={})
        for name, content in [('runtime-rpms.tar.gz', data.getvalue()),
                              ('packages.json', json.dumps(inventory or [self.row]).encode())]:
            checksum = hashlib.sha256(content).hexdigest()
            path = self.server / PREFIX / 'objects' / checksum / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            manifest['files'][name] = checksum
        key = PREFIX + '/' + 'b'*64 + '/manifest.json'
        path = self.server / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(manifest))
        self.config['qli_runtime'] = dict(manifest_key=key, sha256=hashlib.sha256(path.read_bytes()).hexdigest())

    def test_selects_only_locked_packages_and_can_reuse_downloads(self):
        stage_runtime(self.config, self.cache, [self.row])
        self.assertEqual((self.cache / 'jq.rpm').read_bytes(), self.content)
        self.assertFalse((self.cache / 'unselected.rpm').exists())
        with patch('assets.subprocess.run', side_effect=AssertionError('download on cache hit')):
            stage_runtime(self.config, self.cache, [self.row])

    def test_rejects_corrupt_download(self):
        (self.server / self.config['qli_runtime']['manifest_key']).write_text('{}')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            stage_runtime(self.config, self.cache, [self.row])
        self.assertFalse((self.cache / 'jq.rpm').exists())

    def test_rejects_inventory_identity_mismatch(self):
        self.publish([dict(self.row, version='2.0')])
        with self.assertRaisesRegex(ValueError, 'does not match image lock'):
            stage_runtime(self.config, self.cache, [self.row])

    def test_rejects_member_tampering_even_when_bundle_is_pinned(self):
        self.members[0] = ('jq.rpm', b'tampered')
        self.publish()
        with self.assertRaisesRegex(ValueError, 'RPM checksum mismatch'):
            stage_runtime(self.config, self.cache, [self.row])
        self.assertFalse((self.cache / 'jq.rpm').exists())

    def test_rejects_missing_member(self):
        self.members = self.members[1:]
        self.publish()
        with self.assertRaisesRegex(ValueError, 'missing from archive'):
            stage_runtime(self.config, self.cache, [self.row])

    def test_rejects_traversal_and_duplicates_before_publishing(self):
        for name in ('../escape', 'jq.rpm'):
            with self.subTest(name=name):
                self.members = [('jq.rpm', self.content), (name, self.content)]
                self.publish()
                with self.assertRaisesRegex(ValueError, 'Unsafe or duplicate'):
                    stage_runtime(self.config, self.cache, [self.row])
                self.assertFalse((self.cache / 'jq.rpm').exists())

    def test_rejects_wrong_qli_release(self):
        self.config['yocto'] = dict(revision='c'*40)
        with self.assertRaisesRegex(ValueError, 'source lock mismatch'):
            stage_runtime(self.config, self.cache, [self.row])
