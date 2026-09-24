import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from rpm_repository import REQUIRED, distro_versions

spec = importlib.util.spec_from_file_location('verify_rpms', Path(__file__).with_name('verify-rpms.py'))
verify_rpms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_rpms)


class InstalledPackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = json.loads((Path(__file__).parents[2] / 'versions.json').read_text())
        self.config['rpm_packages'] = [dict(name=name, version='1.0', release='1', architecture='aarch64',
            filename=name + '.rpm', sha256='a'*64, source_revision='b'*40,
            qli_release_revision=self.config['yocto']['revision']) for name in sorted(REQUIRED)]
        self.metadata = self.root / 'etc/particle/distro_versions.json'
        self.metadata.parent.mkdir(parents=True)
        self.metadata.write_text(json.dumps(distro_versions(self.config, 'NA', '1.4.0-test')))
        self.report = {'checks': []}
        timezone_check = patch.object(verify_rpms, 'verify_timezone_data', return_value=400)
        self.timezone_check = timezone_check.start()
        self.addCleanup(timezone_check.stop)

    def target(self, args, **kwargs):
        command = args[2:]
        output = ''
        if command[:2] == ['rpm', '-q']:
            output = '1.0-1.aarch64'
        elif command[0] == '/usr/bin/particlectl':
            output = '1.0\n'
        elif command[:2] == ['/usr/bin/systemctl', 'is-enabled']:
            output = 'enabled\n'
        elif command[:2] == ['/usr/bin/env', 'TZ=America/Denver']:
            output = '-0700' if '2026-01-' in command[-2] else '-0600'
        return subprocess.CompletedProcess(args, 0, output)

    def test_full_check_records_packages_and_enabled_units(self):
        with patch.object(verify_rpms.subprocess, 'run', side_effect=self.target):
            verify_rpms.verify(self.root, self.config, self.report, 'NA', '1.4.0-test')
        self.assertTrue(all(row['passed'] for row in self.report['checks']))
        self.assertEqual(self.report['packages'], self.config['rpm_packages'])
        self.assertEqual(sum(row['name'].startswith('enabled:') for row in self.report['checks']), 5)

    def fail_command(self, predicate, output, returncode):
        def target(args, **kwargs):
            if predicate(args[2:]):
                return subprocess.CompletedProcess(args, returncode, output)
            return self.target(args, **kwargs)
        with patch.object(verify_rpms.subprocess, 'run', side_effect=target):
            with self.assertRaises(ValueError):
                verify_rpms.verify(self.root, self.config, self.report, 'NA', '1.4.0-test')
        self.assertFalse(self.report['checks'][-1]['passed'])

    def test_rejects_wrong_installed_version(self):
        self.fail_command(lambda c: c[:2] == ['rpm', '-q'], '0.9-1.aarch64', 0)

    def test_rejects_modified_package_payload(self):
        self.fail_command(lambda c: c[:2] == ['rpm', '-V'], 'S.5....T. /usr/bin/particlectl', 1)

    def test_rejects_missing_target_library(self):
        self.fail_command(lambda c: '--list' in c, 'libparticle_ril.so: cannot open shared object', 127)

    def test_rejects_wrong_packaged_cli_version(self):
        self.fail_command(lambda c: c[0] == '/usr/bin/particlectl', '0.9', 0)

    def test_rejects_disabled_service_even_with_zero_exit(self):
        self.fail_command(lambda c: c[:2] == ['/usr/bin/systemctl', 'is-enabled'], 'disabled', 0)

    def test_rejects_missing_timezone_data(self):
        self.timezone_check.side_effect = ValueError('Missing or invalid timezone: America/Denver')
        with patch.object(verify_rpms.subprocess, 'run', side_effect=self.target):
            with self.assertRaisesRegex(ValueError, 'America/Denver'):
                verify_rpms.verify(self.root, self.config, self.report, 'NA', '1.4.0-test')

    def test_rejects_silent_utc_fallback(self):
        self.fail_command(lambda c: 'TZ=America/Denver' in c, '+0000', 0)

    def test_rejects_stale_image_metadata(self):
        metadata = json.loads(self.metadata.read_text())
        metadata['src']['particle-linux'] = 'old'
        self.metadata.write_text(json.dumps(metadata))
        with patch.object(verify_rpms.subprocess, 'run', side_effect=self.target):
            with self.assertRaisesRegex(ValueError, 'does not match'):
                verify_rpms.verify(self.root, self.config, self.report, 'NA', '1.4.0-test')

    def test_rejects_wrong_image_region_or_version(self):
        for key, value in [('region', 'RoW'), ('version', '1.4.0-old')]:
            with self.subTest(key=key):
                metadata = distro_versions(self.config, 'NA', '1.4.0-test')
                metadata['distro'][key] = value
                self.metadata.write_text(json.dumps(metadata))
                with patch.object(verify_rpms.subprocess, 'run', side_effect=self.target):
                    with self.assertRaisesRegex(ValueError, 'does not match'):
                        verify_rpms.verify(self.root, self.config, self.report, 'NA', '1.4.0-test')

    def test_failure_report_survives_and_never_claims_hardware_success(self):
        config = self.root / 'versions.json'
        config.write_text(json.dumps(self.config))
        report = self.root / 'failed.json'
        argv = ['verify-rpms.py', str(self.root), str(config), '--report', str(report), '--region', 'NA', '--version', '1.4.0-test']
        with patch.object(sys, 'argv', argv), patch.object(verify_rpms, 'verify', side_effect=RuntimeError('missing library')):
            with self.assertRaisesRegex(RuntimeError, 'missing library'):
                verify_rpms.main()
        result = json.loads(report.read_text())
        self.assertFalse(result['passed'])
        self.assertEqual(result['hardware_tests'], 'not_run')
        self.assertEqual(result['error'], 'missing library')


if __name__ == '__main__':
    unittest.main()
