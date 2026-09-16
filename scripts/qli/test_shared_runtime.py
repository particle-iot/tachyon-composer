"""Test shared runtime RPM integrity, pinning and concurrent publication without AWS."""
import importlib.util
import json
import os
import base64
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sdk', Path(__file__).with_name('shared-runtime.py'))
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class ObjectStore:
    bucket = 'test-package-bucket'

    def __init__(self):
        self.objects = {}
        self.writes = []

    def get(self, key, path):
        if key not in self.objects:
            return False
        path.write_bytes(self.objects[key])
        return True

    def put_blob(self, key, path):
        self.objects[key] = path.read_bytes()
        self.writes.append(key)

    def create_manifest(self, key, path):
        if key in self.objects:
            return False
        self.objects[key] = path.read_bytes()
        self.writes.append(key)
        return True


class SharedRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.composer = self.root / 'composer'
        scripts = self.composer / 'scripts/qli'
        scripts.mkdir(parents=True)
        for name in ('build-runtime-rpms.sh', 'prepare-yocto.sh', 'checkout.py', 'check-runtime-graph.py', 'record-runtime-rpms.py'):
            (scripts / name).write_text('pinned builder fixture')
        self.versions = dict(yocto=dict(repository='https://example.test/yocto.git',
                                       revision='a' * 40, lock_sha256='b' * 64))
        self.write_versions()
        self.bundle = self.root / 'producer'
        self.bundle.mkdir()
        (self.bundle / 'runtime-rpms.tar.gz').write_text('runtime RPM fixture, not executable compiler output')
        (self.bundle / 'build-versions.json').write_bytes(sdk.encoded(self.versions))
        (self.bundle / 'kas-config.yml').write_text('pinned kas configuration fixture')
        (self.bundle / 'runtime-graph.json').write_text('{"fixture": true}')
        (self.bundle / 'packages.json').write_text('[]')
        (self.bundle / 'source-revisions.json').write_text('{}')
        self.checksums()
        self.s3 = ObjectStore()
        self.consumer = self.root / 'consumer'

    def write_versions(self):
        (self.composer / 'versions.json').write_bytes(sdk.encoded(self.versions))

    def checksums(self):
        (self.bundle / 'SHA256SUMS').write_text(''.join(
            f'{sdk.digest(self.bundle / name)}  {name}\n' for name in sdk.FILES))

    def publish(self):
        sdk.publish(self.composer, self.bundle, self.s3)

    def pin(self):
        self.versions.update(json.loads((self.bundle / 'runtime-pin.json').read_text()))
        self.write_versions()

    def test_one_publisher_shared_by_independent_consumers(self):
        self.publish()
        for name in ('ril', 'syscon', 'linux'):
            target = self.root / name
            self.assertTrue(sdk.restore(self.composer, target, self.s3))
            for file in sdk.FILES:
                self.assertEqual((target / file).read_bytes(), (self.bundle / file).read_bytes())
        self.assertEqual(len(self.s3.writes), 7)
        self.assertTrue(self.s3.writes[-1].endswith('/manifest.json'))

    def test_unrelated_image_and_component_pins_reuse_sdk(self):
        self.publish()
        self.versions.update(kernel_package_version='new', components={'ril': 'new'}, rpm_packages=[])
        self.write_versions()
        self.assertTrue(sdk.restore(self.composer, self.consumer, self.s3))

    def test_yocto_or_builder_changes_require_different_sdk(self):
        self.publish()
        original = sdk.input_key(sdk.inputs(self.composer))
        self.versions['yocto']['revision'] = 'c' * 40
        self.write_versions()
        self.assertNotEqual(original, sdk.input_key(sdk.inputs(self.composer)))
        self.assertFalse(sdk.restore(self.composer, self.consumer, self.s3))
        self.versions['yocto']['revision'] = 'a' * 40
        self.write_versions()
        (self.composer / 'scripts/qli/build-runtime-rpms.sh').write_text('changed runtime RPM configuration')
        self.assertFalse(sdk.restore(self.composer, self.consumer, self.s3))

    def test_corrupt_artifact_does_not_replace_existing_installer(self):
        self.publish()
        key = next(key for key in self.s3.objects if key.endswith('/runtime-rpms.tar.gz'))
        self.s3.objects[key] = b'corruption'
        self.consumer.mkdir()
        (self.consumer / 'runtime-rpms.tar.gz').write_text('existing installer')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            sdk.restore(self.composer, self.consumer, self.s3)
        self.assertEqual((self.consumer / 'runtime-rpms.tar.gz').read_text(), 'existing installer')

    def test_missing_artifact_fails_instead_of_cache_miss(self):
        self.publish()
        del self.s3.objects[next(key for key in self.s3.objects if key.endswith('/runtime-rpms.tar.gz'))]
        with self.assertRaisesRegex(ValueError, 'artifact missing'):
            sdk.restore(self.composer, self.consumer, self.s3)

    def test_manifest_input_mismatch_fails(self):
        self.publish()
        key = sdk.manifest_key(sdk.inputs(self.composer))
        manifest = json.loads(self.s3.objects[key])
        manifest['inputs']['kas'] = 'wrong'
        self.s3.objects[key] = sdk.encoded(manifest)
        with self.assertRaisesRegex(ValueError, 'inputs or inventory'):
            sdk.restore(self.composer, self.consumer, self.s3)

    def test_manifest_path_traversal_fails(self):
        self.publish()
        key = sdk.manifest_key(sdk.inputs(self.composer))
        manifest = json.loads(self.s3.objects[key])
        manifest['files']['../escape'] = manifest['files'].pop('runtime-rpms.tar.gz')
        self.s3.objects[key] = sdk.encoded(manifest)
        with self.assertRaisesRegex(ValueError, 'inputs or inventory'):
            sdk.restore(self.composer, self.consumer, self.s3)

    def test_invalid_local_checksum_inventory_never_uploads(self):
        for content in ('', '0' * 64 + '  ../runtime-rpms.tar.gz\n', (self.bundle / 'SHA256SUMS').read_text() * 2):
            with self.subTest(content=content):
                (self.bundle / 'SHA256SUMS').write_text(content)
                with self.assertRaises(ValueError):
                    self.publish()
                self.assertEqual(self.s3.writes, [])

    def test_corrupt_local_bundle_never_uploads(self):
        (self.bundle / 'runtime-rpms.tar.gz').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.publish()
        self.assertEqual(self.s3.writes, [])

    def test_concurrent_publishers_keep_first_manifest_and_use_winning_sdk(self):
        self.publish()
        key = sdk.manifest_key(sdk.inputs(self.composer))
        original = self.s3.objects[key]
        installer = (self.bundle / 'runtime-rpms.tar.gz').read_bytes()
        (self.bundle / 'runtime-rpms.tar.gz').write_text('different build of the same source inputs')
        self.checksums()
        self.publish()
        self.assertEqual(self.s3.objects[key], original)
        self.assertEqual((self.bundle / 'runtime-rpms.tar.gz').read_bytes(), installer)

    def test_exact_pin_download_and_tampering_rejection(self):
        self.publish()
        self.pin()
        self.assertTrue(sdk.restore(self.composer, self.consumer, self.s3))
        key = self.versions['qli_runtime']['manifest_key']
        self.s3.objects[key] += b' '
        with self.assertRaisesRegex(ValueError, 'manifest checksum mismatch'):
            sdk.restore(self.composer, self.consumer, self.s3)

    def test_missing_pin_never_permits_bootstrap(self):
        self.publish()
        self.pin()
        self.s3.objects.clear()
        with self.assertRaisesRegex(ValueError, 'refusing to rebuild'):
            sdk.restore(self.composer, self.consumer, self.s3)

    def test_pin_for_other_inputs_rejected(self):
        self.publish()
        self.pin()
        self.versions['yocto']['revision'] = 'd' * 40
        self.write_versions()
        with self.assertRaisesRegex(ValueError, 'current runtime RPM build inputs'):
            sdk.restore(self.composer, self.consumer, self.s3)

    def test_pinned_sdk_cannot_be_published(self):
        self.publish()
        self.pin()
        with self.assertRaisesRegex(ValueError, 'never republished'):
            self.publish()

    def test_s3_auth_failure_is_not_a_cache_miss(self):
        with patch.object(sdk.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 1, '', 'An error occurred (AccessDenied) when calling GetObject')):
            with self.assertRaisesRegex(RuntimeError, 'AccessDenied'):
                sdk.S3(self.s3.bucket).get('key', self.root / 'download')

    def test_only_no_such_key_is_a_cache_miss(self):
        with patch.object(sdk.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 1, '', 'An error occurred (NoSuchKey) when calling GetObject')):
            self.assertFalse(sdk.S3(self.s3.bucket).get('key', self.root / 'download'))

    def test_conditional_manifest_write_and_conflict(self):
        with patch.object(sdk.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 1, '', 'An error occurred (PreconditionFailed) when calling PutObject')) as run:
            self.assertFalse(sdk.S3(self.s3.bucket).create_manifest('key', self.root / 'manifest'))
            self.assertIn('--if-none-match', run.call_args.args[0])
            self.assertIn('*', run.call_args.args[0])


if __name__ == '__main__':
    unittest.main()
