import copy
import unittest
from pathlib import Path
import json
from rpm_repository import REQUIRED, validate_lock, distro_versions


class RPMLockTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((Path(__file__).parents[2] / 'versions.json').read_text())
        self.config['rpm_packages'] = [dict(name=name, version='1.0', release='1', architecture='aarch64',
            filename=name + '.rpm', sha256='a'*64, source_revision='b'*40,
            qli_release_revision=self.config['yocto']['revision']) for name in sorted(REQUIRED)]

    def test_rejects_unbuilt_packages(self):
        self.config['rpm_packages'] = []
        with self.assertRaisesRegex(ValueError, 'Build and pin'):
            validate_lock(self.config)

    def test_rejects_wrong_sdk_architecture_or_checksum(self):
        for field, value in [('architecture', 'x86_64'), ('sha256', 'HEAD'), ('source_revision', 'main'),
                             ('qli_release_revision', 'c'*40), ('filename', '../escape.rpm')]:
            config = copy.deepcopy(self.config)
            config['rpm_packages'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_lock(config)

    def test_complete_lock_accepted(self):
        self.assertEqual(validate_lock(self.config), self.config['rpm_packages'])

    def test_accepts_the_qli_reference_image_tune_architecture(self):
        for package in self.config['rpm_packages']:
            package['architecture'] = 'armv8_2a'
        self.assertEqual(validate_lock(self.config), self.config['rpm_packages'])

    def test_metadata_uses_same_image_and_component_pins(self):
        for region in ('NA', 'RoW'):
            result = distro_versions(self.config, region, '1.4.0-dev')
            self.assertEqual(result['distro']['version'], '1.4.0-dev')
            self.assertEqual(result['distro']['region'], region)
            self.assertEqual(result['distro']['distribution'], 'qualcomm-linux')
            self.assertEqual(result['src']['linux-particle'], self.config['kernel_package_version'])
            self.assertEqual(result['src']['particle-linux'], '1.0-1')

    def test_ci_selection_rejects_tampered_outputs(self):
        import hashlib
        import subprocess
        import sys
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts = root / 'artifacts'
            artifacts.mkdir()
            for package in self.config['rpm_packages']:
                content = package['name'].encode()
                package['sha256'] = hashlib.sha256(content).hexdigest()
                (artifacts / package['filename']).write_bytes(content)
            config = root / 'versions.json'
            config.write_text(json.dumps(self.config))
            command = [sys.executable, str(Path(__file__).with_name('select-built-rpms.py')),
                       str(config), str(artifacts), str(root / 'cache')]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list((root / 'cache').glob('*.rpm'))), len(REQUIRED))
            (artifacts / self.config['rpm_packages'][0]['filename']).write_bytes(b'tampered')
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('No checksum-matching built RPM', result.stderr)
