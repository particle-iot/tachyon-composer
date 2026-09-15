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

    def test_metadata_uses_same_image_and_component_pins(self):
        for region in ('NA', 'RoW'):
            result = distro_versions(self.config, region, '1.4.0-dev')
            self.assertEqual(result['distro']['version'], '1.4.0-dev')
            self.assertEqual(result['distro']['region'], region)
            self.assertEqual(result['distro']['distribution'], 'qualcomm-linux')
            self.assertEqual(result['src']['linux-particle'], self.config['kernel_package_version'])
            self.assertEqual(result['src']['particle-linux'], '1.0-1')
