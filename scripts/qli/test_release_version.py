"""Exercise version isolation and tag/retry behavior in real temporary repos."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('release-version.py').resolve()


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cwd = self.tmp.name
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.cwd, text=True).strip()

    def commit(self):
        self.git('commit', '--allow-empty', '-qm', 'fixture')

    def resolve(self, *args, check=True):
        return subprocess.run(['python3', str(SCRIPT), *args], cwd=self.cwd,
                              capture_output=True, text=True, check=check)

    def test_first_release_ignores_all_ubuntu_tags(self):
        self.git('tag', '1.2.99')
        self.git('tag', '26.04/1.3.99')
        self.git('tag', '99.0.0')
        self.assertEqual(self.resolve('next').stdout.strip(), '1.4.0')
        self.assertTrue(self.resolve('prerelease').stdout.startswith('1.4.0-dev+build.'))

    def test_next_patch_and_idempotent_merge_rerun(self):
        self.git('tag', 'qli-2.0/1.4.0')
        self.assertEqual(self.resolve('next').stdout.strip(), '1.4.0')
        self.commit()
        self.assertEqual(self.resolve('next').stdout.strip(), '1.4.1')

    def test_minor_and_major_stay_in_qli_stream(self):
        self.git('tag', 'qli-2.0/1.4.9')
        self.commit()
        self.assertEqual(self.resolve('next', '--bump', 'minor').stdout.strip(), '1.5.0')
        self.assertEqual(self.resolve('next', '--bump', 'major').stdout.strip(), '2.0.0')

    def test_release_requires_correct_stream_and_commit(self):
        self.git('tag', 'qli-2.0/1.4.0')
        self.git('tag', '1.2.99')
        self.assertEqual(self.resolve('current', '--ref', 'refs/tags/qli-2.0/1.4.0').stdout.strip(), '1.4.0')
        self.assertNotEqual(self.resolve('current', '--ref', 'refs/tags/1.2.99', check=False).returncode, 0)
        self.commit()
        self.assertNotEqual(self.resolve('current', '--ref', 'refs/tags/qli-2.0/1.4.0', check=False).returncode, 0)

    def test_previous_version_excludes_ubuntu_and_handles_first_release(self):
        first = self.git('rev-parse', 'HEAD')
        self.git('tag', '1.2.99')
        self.commit()
        self.assertEqual(self.resolve('previous').stdout.strip(), first)
        self.git('tag', 'qli-2.0/1.4.0')
        self.commit()
        self.git('tag', '26.04/1.3.99')
        self.assertEqual(self.resolve('previous').stdout.strip(), 'qli-2.0/1.4.0')


if __name__ == '__main__':
    unittest.main()
